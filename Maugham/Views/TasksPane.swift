import SwiftUI

// MARK: - Pure drop classifier
//
// Extracted from the SwiftUI view so the single-level-nesting guard,
// reorder-as-sibling, and child-of-child fallback can be unit-tested
// without a render. Mirrors the shape of `DropIntent` in BinderView; the
// `TaskDropIntent.classify(...)` function is the test entry point.

/// Result of classifying a drag-drop gesture against a TasksPane row.
public enum TaskDropIntent: Equatable, Sendable {
    /// Place the dragged task above the target (same parent as target).
    case reorderAbove(targetId: String, parentTaskId: String?)
    /// Place the dragged task below the target (same parent as target).
    case reorderBelow(targetId: String, parentTaskId: String?)
    /// Nest the dragged task under the target as a child. Only emitted when
    /// the target is itself a top-level task (parentTaskId == nil); for a
    /// target that's already a child, a center-drop is reclassified as
    /// `reorderBelow` (spec §11: strictly one level of nesting).
    case nestUnder(parentId: String)
}

extension TaskDropIntent {

    /// Vertical position within the target row.
    public enum Position: Equatable, Sendable {
        case top, middle, bottom
    }

    /// Classify a drop. `target` is the row that received the gesture.
    /// `targetParentTaskId` is `target.parentTaskId` (nil = top-level).
    ///
    /// Single-level nesting guard: a center-drop onto a child becomes a
    /// reorder-below (treat as a sibling of the child, NOT as creating a
    /// grandchild). The dragged task's own parent doesn't matter for the
    /// classification; the caller decides whether to additionally emit a
    /// `.taskParentChange` to detach the dragged task from a prior parent
    /// when the new placement implies a different parent.
    public static func classify(
        position: Position,
        targetId: String,
        targetParentTaskId: String?
    ) -> TaskDropIntent {
        switch position {
        case .top:
            return .reorderAbove(
                targetId: targetId, parentTaskId: targetParentTaskId)
        case .bottom:
            return .reorderBelow(
                targetId: targetId, parentTaskId: targetParentTaskId)
        case .middle:
            if targetParentTaskId == nil {
                return .nestUnder(parentId: targetId)
            } else {
                // Strict one-level cap: dropping on a child reorders as
                // sibling of the child, not as grandchild of its parent.
                return .reorderBelow(
                    targetId: targetId, parentTaskId: targetParentTaskId)
            }
        }
    }

    /// Map a normalized y-fraction (0.0 = top, 1.0 = bottom) to a Position.
    /// Thirds match BinderRow.swift's classification.
    public static func position(yFraction: Double) -> Position {
        if yFraction < 1.0 / 3.0 { return .top }
        if yFraction > 2.0 / 3.0 { return .bottom }
        return .middle
    }
}

// MARK: - Filter item (status)

enum TaskStatusFilterItem: String, CaseIterable, Identifiable, FilterRowItem {
    case open, done, archived

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open:     return "Open"
        case .done:     return "Done"
        case .archived: return "Archive"
        }
    }

    var symbolName: String {
        switch self {
        case .open:     return "circle"
        case .done:     return "checkmark.circle"
        case .archived: return "archivebox"
        }
    }

    var status: TaskStatus {
        switch self {
        case .open:     return .open
        case .done:     return .done
        case .archived: return .archived
        }
    }
}

// MARK: - TasksPane

@MainActor
struct TasksPane: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let activeDocId: String?
    let projectURL: URL?

    enum ScopeChoice: Hashable {
        case document
        case project
    }

    @State private var scope: ScopeChoice = .document
    @State private var statusFilter: TaskStatusFilterItem = .open
    @State private var selectedTaskId: String?
    @State private var showCreateSheet: Bool = false
    @State private var newTaskBody: String = ""
    @State private var newTaskScope: ScopeChoice = .document

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { coerceScopeIfNoActiveDoc() }
        .onChange(of: activeDocId) { _, _ in coerceScopeIfNoActiveDoc() }
        .sheet(isPresented: $showCreateSheet) {
            NewTaskSheet(
                taskBody: $newTaskBody,
                scope: $newTaskScope,
                canPickDocumentScope: activeDoc() != nil,
                onCommit: { commitNewTask() },
                onCancel: {
                    showCreateSheet = false
                    newTaskBody = ""
                })
        }
    }

    // MARK: Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 6) {
            Picker("Scope", selection: $scope) {
                Text("Doc").tag(ScopeChoice.document)
                Text("Project").tag(ScopeChoice.project)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()

            Spacer(minLength: 4)

            AdaptiveFilterRow(
                items: TaskStatusFilterItem.allCases,
                selection: $statusFilter)
                .layoutPriority(1)

            Spacer(minLength: 4)

            Button {
                presentCreateSheet()
            } label: {
                Image(systemName: "plus")
            }
            .help("New task")
            .disabled(newTaskButtonDisabled)

            Menu {
                Button("Archive all done") {
                    archiveAllDone(in: scope)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Bulk actions")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var newTaskButtonDisabled: Bool {
        // Disabled only when doc-scope is selected and there's no active doc.
        scope == .document && activeDoc() == nil
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        // Observe both version tokens so any mutation re-renders us.
        let docVersion = activeDoc()?.tasksVersion ?? 0
        let projectVersion = store.projectTasksVersion
        let tasks = visibleTasks(docVersion: docVersion, projectVersion: projectVersion)
        if tasks.isEmpty {
            ContentUnavailableView(
                "No tasks",
                systemImage: "checklist",
                description: Text("Type `- [ ]` in any paragraph, or press +."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // `.draggable` + per-row `.dropDestination` mirroring BinderRow.
            // Earlier attempt to use `ForEach.onMove` didn't actually fire
            // on macOS in `List(.sidebar)` — even though SwiftUI documents
            // it as the canonical reorder gesture. BinderRow proves the
            // older `.draggable`/`.dropDestination` pattern works inside
            // this exact list style. The trade-off is that row-internal
            // interactive controls (Toggle on the left, Menu on the right)
            // capture pointer events in their immediate area; the writer
            // initiates drag from the body-text region or the row padding.
            List(tasks, id: \.id, selection: $selectedTaskId) { task in
                row(for: task)
                    .tag(task.id)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func row(for task: WriterTask) -> some View {
        TaskRow(
            task: task,
            onToggle: { toggleStatus(task) },
            onJump:   { jumpToParagraph(task) },
            onArchive: { archive(task) },
            onDelete: { deleteIfPaneCreated(task) })
            .padding(.leading, task.parentTaskId == nil ? 0 : 18)
            .draggable(task.id) {
                Text(task.body)
                    .padding(6)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 4))
            }
            .dropDestination(for: String.self) { ids, location in
                guard let draggedId = ids.first else { return false }
                // Row height varies with body length + theme; 28 is a
                // sensible default close to the typical sidebar row.
                let rowHeight: CGFloat = 28
                let yFrac = Double(
                    min(max(location.y, 0), rowHeight) / rowHeight)
                let position = TaskDropIntent.position(yFraction: yFrac)
                let intent = TaskDropIntent.classify(
                    position: position,
                    targetId: task.id,
                    targetParentTaskId: task.parentTaskId)
                handleDrop(draggedId: draggedId, intent: intent)
                return true
            }
    }

    // MARK: - Visible tasks

    private func visibleTasks(
        docVersion _: Int, projectVersion _: Int
    ) -> [WriterTask] {
        let statuses: Set<TaskStatus> = [statusFilter.status]
        switch scope {
        case .document:
            guard let doc = activeDoc() else { return [] }
            return doc.tasks(filter: TaskFilter(
                scope: .document(docId: doc.docId),
                statuses: statuses))
        case .project:
            return store.listTasksAcrossProject(filter: TaskFilter(
                scope: .project,
                statuses: statuses))
        }
    }

    // MARK: - Active document

    private func activeDoc() -> Document? {
        guard let id = activeDocId,
              id != "__no-selection__" else { return nil }
        return documentStore.document(forDocId: id)
    }

    /// Find the Document that owns a task, by anchor docId. The anchor
    /// always names a real doc except for project-scope tasks (where the
    /// anchor docId is `__project__` — handled by the caller).
    private func ownerDoc(of task: WriterTask) -> Document? {
        guard let anchor = task.anchor,
              anchor.docId != ProjectStore.projectTasksDocId else { return nil }
        return documentStore.document(forDocId: anchor.docId)
    }

    private func coerceScopeIfNoActiveDoc() {
        if scope == .document && activeDoc() == nil {
            scope = .project
        }
    }

    // MARK: - Actions

    private func toggleStatus(_ task: WriterTask) {
        let nextStatus: TaskStatus = task.status == .done ? .open : .done
        switch task.kind {
        case .paneCreated:
            // Project-scope pane-created tasks have anchor.docId == __project__
            // and there is no Document to mutate. For doc-scope pane-created
            // tasks, mutate the owning Document.
            if let doc = ownerDoc(of: task) {
                doc.setTaskStatus(id: task.id, status: nextStatus)
            }
            // Project-scope status change isn't shipped in this milestone.
            // (Spec §11: pane edits for inline tasks are out of scope; the
            // project pane tasks DO support status toggle via the future
            // ProjectStore mutation API. For now we leave it as a NOP and
            // surface the tooltip / no-op.)
        case .inlineMarkdown:
            // Markdown: flip the `[ ]` ↔ `[x]` bracket in the paragraph.
            guard let doc = ownerDoc(of: task),
                  let pid = task.anchor?.paragraphId,
                  let current = doc.paragraph(id: pid) else { return }
            let flipped = flipInlineCheckbox(current)
            guard flipped != current else { return }
            doc.setParagraph(id: pid, text: flipped)
        case .fountainBoneyard:
            // Fountain: flip the specific `[[todo:` / `[[done:` segment
            // whose closing anchor matches this task's id. Paragraphs
            // may contain multiple inline Fountain todos; we MUST flip
            // only the one tied to this task's anchor.
            guard let doc = ownerDoc(of: task),
                  let pid = task.anchor?.paragraphId,
                  let current = doc.paragraph(id: pid),
                  let anchorId = extractAnchorId(from: task.id)
            else { return }
            let flipped = flipFountainTodoDone(in: current, anchorId: anchorId)
            guard flipped != current else { return }
            doc.setParagraph(id: pid, text: flipped)
        }
    }

    /// Extract the 6-char anchor id from a task synth-id
    /// `inline:<docId>:<anchorId>`. Returns nil for pane-created task
    /// ids (which are op-ids, not synth-ids with the `inline:` prefix).
    private func extractAnchorId(from taskId: String) -> String? {
        guard taskId.hasPrefix("inline:") else { return nil }
        let parts = taskId.split(separator: ":")
        guard parts.count >= 3 else { return nil }
        return String(parts.last!)
    }

    private func archive(_ task: WriterTask) {
        guard let doc = ownerDoc(of: task) else { return }
        doc.archiveTask(id: task.id)
    }

    private func deleteIfPaneCreated(_ task: WriterTask) {
        // For pane-created tasks, "Delete" is the destructive end-state —
        // it's modeled as an archive op in this milestone (no separate
        // delete op kind), per spec §11 simplification.
        guard task.kind == .paneCreated,
              let doc = ownerDoc(of: task) else { return }
        doc.archiveTask(id: task.id)
    }

    /// Archive every Done task currently visible in the given scope.
    /// Snapshots the done list before iterating so cache invalidations
    /// on each `archiveTask` call don't mutate the iteration set.
    /// Project-scope: tasks in closed (unregistered) documents are skipped
    /// with a console log — open the document to archive them individually.
    internal func archiveAllDone(in scopeChoice: ScopeChoice) {
        // Snapshot now; archiveTask invalidates the cache on each call.
        let allVisible: [WriterTask]
        switch scopeChoice {
        case .document:
            guard let doc = activeDoc() else { return }
            allVisible = doc.tasks(filter: TaskFilter(
                scope: .document(docId: doc.docId),
                statuses: [.done]))
        case .project:
            allVisible = store.listTasksAcrossProject(filter: TaskFilter(
                scope: .project,
                statuses: [.done]))
        }

        var skippedCount = 0
        for task in allVisible {
            guard let anchor = task.anchor else { continue }
            if anchor.docId == ProjectStore.projectTasksDocId {
                // Project pane-created task: emit .taskArchive op directly
                // via the project op log (no Document actor involved).
                let op = Op(
                    opId: ULID.generate(),
                    docId: ProjectStore.projectTasksDocId,
                    at: Date(),
                    device: store.projectOpDevice,
                    session: store.projectOpSession,
                    kind: .taskArchive,
                    changes: [], sequence: nil,
                    provenance: Op.Provenance(
                        sessionId: store.projectOpSession,
                        taskId: task.id))
                store.appendProjectTaskOp(op)
            } else if let doc = documentStore.document(forDocId: anchor.docId) {
                doc.archiveTask(id: task.id)
            } else {
                // Closed document — skip for V1.
                skippedCount += 1
            }
        }
        if skippedCount > 0 {
            print("[TasksPane] Skipping \(skippedCount) Done task(s) in closed documents — open them to archive individually.")
        }
    }

    // MARK: - Navigation

    private func jumpToParagraph(_ task: WriterTask) {
        guard let anchor = task.anchor,
              let pid = anchor.paragraphId,
              anchor.docId != ProjectStore.projectTasksDocId
        else { return }
        NotificationCenter.default.post(
            name: .maughamNavigateToParagraph,
            object: projectURL,
            userInfo: [
                "doc_id": anchor.docId,
                "paragraph_id": pid,
            ])
    }

    // MARK: - Drag-and-drop

    /// SwiftUI `.onMove` handler. `source` indexes into `visible` (the
    /// in-pane list order); `destination` is the slot index the dragged
    /// row should occupy AFTER the move. SwiftUI uses the "insert
    /// before" convention — destination N means "drop just before the
    /// task currently at index N", so when N == visible.count the drop
    /// lands at the end.
    ///
    /// Only same-parent reorders are dispatched. Cross-parent moves via
    /// drag aren't supported by `.onMove` (it's a flat-list gesture)
    /// and are explicitly out of scope until a follow-up adds a kebab
    /// "Move under …" affordance.
    /// Internal access so integration tests can drive the SwiftUI
    /// `.onMove` semantics without a render harness.
    func handleListMove(
        from source: IndexSet, to destination: Int, in visible: [WriterTask]
    ) {
        guard let from = source.first,
              from >= 0, from < visible.count else { return }
        let dragged = visible[from]
        guard let doc = ownerDoc(of: dragged) else { return }

        let intent: TaskDropIntent
        if destination == visible.count {
            // Dropped past the last row — reorder below the current
            // bottom row.
            let last = visible[visible.count - 1]
            intent = .reorderBelow(
                targetId: last.id, parentTaskId: last.parentTaskId)
        } else if destination == from || destination == from + 1 {
            // No-op move (dropped onto self).
            return
        } else if destination < from {
            // Moving upward: target is the row currently at destination.
            let target = visible[destination]
            intent = .reorderAbove(
                targetId: target.id, parentTaskId: target.parentTaskId)
        } else {
            // Moving downward: SwiftUI's destination accounts for the
            // dragged row being removed first, so the row currently at
            // (destination - 1) is the new "above" — reorder below that.
            let aboveIdx = destination - 1
            let target = visible[aboveIdx]
            intent = .reorderBelow(
                targetId: target.id, parentTaskId: target.parentTaskId)
        }

        apply(intent: intent, dragged: dragged, in: doc, allTasks: visible)
    }

    /// Apply a classified drop intent: emit `.taskPriorityChange` and/or
    /// `.taskParentChange` ops on the appropriate Document. Project-scope
    /// reorder of project-pane tasks is not shipped in this milestone (the
    /// project op log accepts task ops generally, but the doc-scope path
    /// covers the common case used by integration tests).
    private func handleDrop(draggedId: String, intent: TaskDropIntent) {
        // Find the dragged task in the current visible list.
        let docVersion = activeDoc()?.tasksVersion ?? 0
        let projectVersion = store.projectTasksVersion
        let pool = visibleTasks(
            docVersion: docVersion, projectVersion: projectVersion)
        guard let dragged = pool.first(where: { $0.id == draggedId }) else {
            return
        }
        guard let doc = ownerDoc(of: dragged) else { return }
        apply(intent: intent, dragged: dragged, in: doc, allTasks: pool)
    }

    /// Compute and append the ops implied by a drop. Public-ish (internal
    /// access) so integration tests can call it directly without trying
    /// to fake a SwiftUI drop gesture.
    func apply(
        intent: TaskDropIntent,
        dragged: WriterTask,
        in doc: Document,
        allTasks: [WriterTask]
    ) {
        switch intent {
        case .reorderAbove(let targetId, let parentTaskId):
            guard let target = allTasks.first(where: { $0.id == targetId }) else { return }
            // Find the task immediately above `target` at the same parent
            // level. New priority = halfway between that and target.priority.
            let siblings = allTasks
                .filter { $0.parentTaskId == parentTaskId }
                .sorted { $0.priority < $1.priority }
            let targetIdx = siblings.firstIndex { $0.id == targetId }
            let above: WriterTask? = targetIdx.flatMap { idx in
                idx > 0 ? siblings[idx - 1] : nil
            }
            let newPriority: Double
            if let above {
                newPriority = (above.priority + target.priority) / 2.0
            } else {
                newPriority = target.priority - 1.0
            }
            if dragged.parentTaskId != parentTaskId {
                doc.setTaskParent(id: dragged.id, parentTaskId: parentTaskId)
            }
            doc.setTaskPriority(id: dragged.id, priority: newPriority)

        case .reorderBelow(let targetId, let parentTaskId):
            guard let target = allTasks.first(where: { $0.id == targetId }) else { return }
            let siblings = allTasks
                .filter { $0.parentTaskId == parentTaskId }
                .sorted { $0.priority < $1.priority }
            let targetIdx = siblings.firstIndex { $0.id == targetId }
            let below: WriterTask? = targetIdx.flatMap { idx in
                idx + 1 < siblings.count ? siblings[idx + 1] : nil
            }
            let newPriority: Double
            if let below {
                newPriority = (target.priority + below.priority) / 2.0
            } else {
                newPriority = target.priority + 1.0
            }
            if dragged.parentTaskId != parentTaskId {
                doc.setTaskParent(id: dragged.id, parentTaskId: parentTaskId)
            }
            doc.setTaskPriority(id: dragged.id, priority: newPriority)

        case .nestUnder(let parentId):
            // The classifier guarantees parentId names a top-level task.
            // If the dragged task already has this parent, no parent op
            // needed; just leave it where it is.
            if dragged.parentTaskId != parentId {
                doc.setTaskParent(id: dragged.id, parentTaskId: parentId)
            }
        }
    }

    // MARK: - New task sheet

    private func presentCreateSheet() {
        newTaskBody = ""
        newTaskScope = (activeDoc() == nil) ? .project : scope
        showCreateSheet = true
    }

    private func commitNewTask() {
        let trimmed = newTaskBody.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showCreateSheet = false
            newTaskBody = ""
            return
        }
        switch newTaskScope {
        case .document:
            if let doc = activeDoc() {
                _ = doc.createPaneTask(body: trimmed, parentTaskId: nil)
            } else {
                // Defensive fallback: doc-scope but no active doc → project.
                _ = store.createProjectPaneTask(body: trimmed)
            }
        case .project:
            _ = store.createProjectPaneTask(body: trimmed)
        }
        showCreateSheet = false
        newTaskBody = ""
    }
}

// MARK: - Inline checkbox flip helper

/// Flip the leading checkbox marker of an inline-task paragraph.
/// Operates only on the first occurrence of `- [ ]` / `- [x]` / `- [X]`
/// at the start of the trimmed paragraph (per Fountain/markdown).
@MainActor
func flipInlineCheckbox(_ text: String) -> String {
    var t = text
    if let range = t.range(of: "- [ ]") {
        t.replaceSubrange(range, with: "- [x]")
        return t
    }
    if let range = t.range(of: "- [x]") ?? t.range(of: "- [X]") {
        t.replaceSubrange(range, with: "- [ ]")
        return t
    }
    return t
}

/// Flip the Fountain `[[todo:` / `[[done:` segment whose closing
/// `<!--t-XXXXXX-->` anchor matches `anchorId`. Returns the paragraph
/// text with that specific segment's prefix toggled. Other Fountain
/// todo/done segments in the same paragraph are left untouched —
/// critical for paragraphs that carry multiple inline tasks.
@MainActor
func flipFountainTodoDone(in text: String, anchorId: String) -> String {
    let anchorSpan = "<!--t-\(anchorId)-->"
    let ns = text as NSString
    let anchorRange = ns.range(of: anchorSpan)
    guard anchorRange.location != NSNotFound else { return text }
    // Walk backward from the anchor to find the matching `[[todo:` or
    // `[[done:` opening. The closing `]]` must immediately precede the
    // anchor (no whitespace per the spec format).
    let beforeAnchor = ns.substring(to: anchorRange.location)
    let beforeAnchorNS = beforeAnchor as NSString
    // Find the leftmost `[[(todo|done):` that's followed by `]]` right
    // before the anchor location. Easiest: regex over `beforeAnchor`
    // looking for the last bracketed segment.
    guard let regex = try? NSRegularExpression(
        pattern: #"\[\[(todo|done):"#)
    else { return text }
    let openMatches = regex.matches(
        in: beforeAnchor,
        range: NSRange(location: 0, length: beforeAnchorNS.length))
    // We want the closing `]]` to be flush against the anchor — so the
    // last open match before the anchor whose body closes at
    // (anchorRange.location - 2) is the one to flip.
    guard let lastMatch = openMatches.last else { return text }
    let prefixRange = lastMatch.range(at: 1)  // "todo" or "done"
    let prefix = beforeAnchorNS.substring(with: prefixRange)
    let flippedPrefix = (prefix == "todo") ? "done" : "todo"
    let result = NSMutableString(string: text)
    result.replaceCharacters(in: prefixRange, with: flippedPrefix)
    return result as String
}

// MARK: - New task sheet

@MainActor
private struct NewTaskSheet: View {
    @Binding var taskBody: String
    @Binding var scope: TasksPane.ScopeChoice
    let canPickDocumentScope: Bool
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New task")
                .font(.headline)
            TextField("Task body", text: $taskBody)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Scope", selection: $scope) {
                    Text("Document")
                        .tag(TasksPane.ScopeChoice.document)
                        .disabled(!canPickDocumentScope)
                    Text("Project").tag(TasksPane.ScopeChoice.project)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(!canPickDocumentScope)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Add", action: onCommit)
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(taskBody.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
