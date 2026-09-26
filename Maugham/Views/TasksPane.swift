import SwiftUI
import MaughamCore
import os

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

    // The window's undo manager — threaded into every task mutation so ⌘Z
    // reverses pane actions (Task 5). Inline toggles register a guarded
    // text flip-back (text-is-state); pane-created mutations register op
    // inverses via `OpUndoRegistrar` / `TaskInverse`.
    @Environment(\.undoManager) private var undoManager

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
                canPickDocumentScope: creation.document,
                canPickProjectScope: creation.project,
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

            // **Hidden where the posture offers no task anywhere this pane
            // could file one** (P3c Task 8) — never greyed for that reason;
            // the pre-existing "no document for Doc scope" disable is a
            // different fact and stays.
            if creation.offersAny {
                Button {
                    presentCreateSheet()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New task")
                .disabled(newTaskButtonDisabled)
            }

            if mayArchiveInScope {
                Menu {
                    Button("Archive all done") {
                        archiveAllDone(in: scope, undoManager: undoManager)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Bulk actions")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var newTaskButtonDisabled: Bool {
        // Disabled only when doc-scope is selected and there's no active doc.
        scope == .document && activeDoc() == nil
    }

    // MARK: - What the posture allows (P3c Task 8)

    /// The posture of the document a task belongs to — its anchor's, where the
    /// project's own tasks are the project stream's (`__project__`). Asked of
    /// the window's drawing door; every task is judged by ITS document, never
    /// by the one the window happens to show.
    private func posture(ofTaskDocument docId: String) -> Posture {
        documentStore.posture(forDocId: docId)
    }

    /// The verbs one row may offer.
    func verbs(for task: WriterTask) -> TaskRowVerbs {
        TaskRowVerbs.decide(
            kind: task.kind,
            posture: posture(ofTaskDocument: task.anchor?.docId
                             ?? ProjectStore.projectTasksDocId))
    }

    /// Where New task may file: the shown document, the project, both or
    /// neither.
    var creation: TaskCreationScopes {
        TaskCreationScopes.decide(
            document: activeDoc().map { posture(ofTaskDocument: $0.docId) },
            project: posture(ofTaskDocument: ProjectStore.projectTasksDocId))
    }

    /// "Archive all done" is drawn where this scope's own tasks may be
    /// archived; the batch itself then skips any task the posture refuses.
    private var mayArchiveInScope: Bool {
        Self.offersArchiveAllDone(
            in: scope,
            document: activeDoc().map { posture(ofTaskDocument: $0.docId) },
            project: posture(ofTaskDocument: ProjectStore.projectTasksDocId))
    }

    /// **Where "Archive all done" is drawn** — the SCOPE's own stream asked
    /// directly (P3c plan 2 Task 9): document scope asks the shown document,
    /// project scope asks the project stream (`__project__`) and never proxies
    /// through whichever document the window happens to show. `document` is
    /// nil where none is shown, which offers nothing in document scope.
    static func offersArchiveAllDone(
        in scope: ScopeChoice, document: Posture?, project: Posture
    ) -> Bool {
        switch scope {
        case .document: return document?.allows(.task) ?? false
        case .project: return project.allows(.task)
        }
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
        let offered = verbs(for: task)
        TaskRow(
            task: task,
            verbs: offered,
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
                // A task the posture may not move is refused by the drop
                // itself, not landed and bounced (P3c Task 8) — nor is a
                // drop onto a row this Mac may not reorder around.
                guard offered.move,
                      let dragged = currentPool().first(where: { $0.id == draggedId }),
                      verbs(for: dragged).move
                else { return false }
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
              id != BinderSubject.noDocumentSubject else { return nil }
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
        // The row draws no toggle where this is false; a stale press (a
        // demotion landing between frames) does nothing rather than write.
        guard verbs(for: task).toggle else { return }
        let nextStatus: TaskStatus = task.status == .done ? .open : .done
        switch task.kind {
        case .paneCreated:
            // Project-scope pane-created tasks have anchor.docId == __project__
            // and there is no Document to mutate. For doc-scope pane-created
            // tasks, mutate the owning Document.
            if let doc = ownerDoc(of: task) {
                doc.setTaskStatus(id: task.id, status: nextStatus,
                                  undoManager: undoManager)
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
            InlineToggleUndo.perform(
                on: doc, paragraphId: pid,
                prior: current, flipped: flipped, undoManager: undoManager)
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
            InlineToggleUndo.perform(
                on: doc, paragraphId: pid,
                prior: current, flipped: flipped, undoManager: undoManager)
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
        guard verbs(for: task).archive, let doc = ownerDoc(of: task) else { return }
        doc.archiveTask(id: task.id, undoManager: undoManager)
    }

    private func deleteIfPaneCreated(_ task: WriterTask) {
        // For pane-created tasks, "Delete" is the destructive end-state —
        // it's modeled as an archive op in this milestone (no separate
        // delete op kind), per spec §11 simplification.
        guard task.kind == .paneCreated, verbs(for: task).delete,
              let doc = ownerDoc(of: task) else { return }
        doc.archiveTask(id: task.id, undoManager: undoManager)
    }

    /// Archive every Done task currently visible in the given scope.
    /// Snapshots the done list before iterating so cache invalidations
    /// on each `archiveTask` call don't mutate the iteration set.
    /// Project-scope: tasks in closed (unregistered) documents are skipped
    /// with a console log — open the document to archive them individually.
    ///
    /// `undoManager` is threaded explicitly (the toolbar passes the window's
    /// environment manager) so tests can drive the real batch path.
    internal func archiveAllDone(
        in scopeChoice: ScopeChoice, undoManager: UndoManager?
    ) {
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

        // Partition BEFORE opening the undo group: the empty batch must not
        // open a group at all (an empty manual group leaves a do-nothing
        // "Archive Done Tasks" ⌘Z entry), and the batch-aware D1 clear below
        // needs to know up front whether any inline task will splice text.
        var projectTasks: [WriterTask] = []
        var docTasks: [(task: WriterTask, doc: Document)] = []
        var skippedCount = 0
        for task in allVisible {
            guard let anchor = task.anchor else { continue }
            // Only what the posture lets this Mac archive (P3c Task 8): an
            // author of some pieces archives her own pieces' and the
            // project's done tasks, and leaves somebody else's.
            guard verbs(for: task).archive else { continue }
            if anchor.docId == ProjectStore.projectTasksDocId {
                projectTasks.append(task)
            } else if let doc = documentStore.document(forDocId: anchor.docId) {
                docTasks.append((task, doc))
            } else {
                // Closed document — skip for V1.
                skippedCount += 1
            }
        }
        if skippedCount > 0 {
            print("[TasksPane] Skipping \(skippedCount) Done task(s) in closed documents — open them to archive individually.")
        }
        guard !projectTasks.isEmpty || !docTasks.isEmpty else { return }

        // Batch-aware D1 clear: an inline-task archive replaces the editor
        // buffer, which makes stale native typing actions unsound — but the
        // per-call `removeAllActions` inside `archiveTask` would fire INSIDE
        // the open group below, which corrupts NSUndoManager (the T5 crash
        // class: unbalanced group, earlier inverses erased). So when the batch
        // contains ≥1 inline task, perform ONE clear here, BEFORE the group
        // opens, and suppress every per-call clear inside the batch.
        let batchHasInlineTask = docTasks.contains {
            Document.extractAnchorId(fromTaskId: $0.task.id) != nil
        }
        if batchHasInlineTask,
           let um = undoManager, !um.isUndoing, !um.isRedoing {
            um.removeAllActions()
        }

        // One undo group so a single ⌘Z reverses the whole batch (Task 5).
        // Each per-task archive registers its own inverse INSIDE the group;
        // NSUndoManager coalesces the group into one action.
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.setActionName("Archive Done Tasks")
            undoManager?.endUndoGrouping()
        }

        for task in projectTasks {
            // Project pane-created task: emit .taskArchive op directly
            // via the project op log (no Document actor involved) and
            // register the status-restore inverse.
            Self.archiveProjectTask(task, store: store, undoManager: undoManager)
        }
        for (task, doc) in docTasks {
            doc.archiveTask(id: task.id, undoManager: undoManager,
                            suppressUndoStackClear: true)
        }
    }

    /// Archive a single project-scope pane task and register its ⌘Z inverse
    /// (target: `store`). The inverse restores the pre-archive status; redo
    /// re-archives, forwarding the LIVE undo manager so the cycle re-arms
    /// (mirrors `Document.archiveTask`). Carried body + kind keep the deriver's
    /// Archived-filter entry intact (archiveTask convention).
    ///
    /// Static, `store` explicit: the undo/redo closures must route through the
    /// registered TARGET (`s`), never a captured view struct — every sibling
    /// registration site does the same, and a captured `self` here would pin a
    /// stale view value (and its store) inside NSUndoManager.
    private static func archiveProjectTask(
        _ task: WriterTask, store: ProjectStore, undoManager: UndoManager?
    ) {
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
                taskId: task.id,
                taskBody: task.body,
                taskKind: task.kind.rawValue))
        // The project stream's door (P3c plan 2 Task 8) refuses and says so;
        // no ⌘Z is registered for an archive that did not happen.
        guard store.appendProjectTaskOp(op) else { return }

        guard let inverse = TaskInverse.inverse(
            undoing: .taskArchive, prior: task,
            docId: ProjectStore.projectTasksDocId,
            device: store.projectOpDevice, session: store.projectOpSession,
            sessionId: store.projectOpSession) else { return }
        OpUndoRegistrar.register(
            undoManager, actionName: "Archive Done Tasks", target: store,
            workTaskSink: { [weak store] in store?._lastUndoWorkTask = $0 },
            undo: { s in
                // Fire-time guard: only restore if still archived — decline as
                // a LOUD no-op (sibling-guard convention).
                let now = s.listTasksAcrossProject(filter: TaskFilter(
                    scope: .project, statuses: Set(TaskStatus.allCases)))
                    .first { $0.id == task.id }
                guard let now, now.status == .archived else {
                    projectStoreLog.error("archiveProjectTask undo: \(task.id, privacy: .public) no longer archived — ignoring")
                    return
                }
                s.appendProjectTaskOp(inverse)
            },
            redo: { [weak undoManager] s in
                Self.archiveProjectTask(task, store: s, undoManager: undoManager)
            })
    }

    // MARK: - Navigation

    private func jumpToParagraph(_ task: WriterTask) {
        guard let anchor = task.anchor,
              let pid = anchor.paragraphId,
              anchor.docId != ProjectStore.projectTasksDocId
        else { return }
        // Key-window scoped (ADR 0021): the old `object: projectURL` scoping was
        // dead — both receivers ignored it — so it's dropped; the doc_id/
        // paragraph_id payload is preserved.
        MaughamEvent.post(
            .maughamNavigateToParagraph, to: .keyWindow,
            payload: [
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
        guard verbs(for: dragged).move, let doc = ownerDoc(of: dragged) else { return }

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
    /// The tasks the pane is showing now.
    private func currentPool() -> [WriterTask] {
        visibleTasks(docVersion: activeDoc()?.tasksVersion ?? 0,
                     projectVersion: store.projectTasksVersion)
    }

    private func handleDrop(draggedId: String, intent: TaskDropIntent) {
        // Find the dragged task in the current visible list.
        let pool = currentPool()
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
            moveTask(dragged, toParent: parentTaskId,
                     priority: newPriority, in: doc)

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
            moveTask(dragged, toParent: parentTaskId,
                     priority: newPriority, in: doc)

        case .nestUnder(let parentId):
            // The classifier guarantees parentId names a top-level task.
            // If the dragged task already has this parent, no parent op
            // needed; just leave it where it is.
            if dragged.parentTaskId != parentId {
                doc.setTaskParent(id: dragged.id, parentTaskId: parentId,
                                  undoManager: undoManager)
            }
        }
    }

    /// Emit the parent + priority ops a reorder drop implies. A reparenting
    /// drag emits BOTH — group them under one "Move Task" action so a single
    /// ⌘Z reverts the whole drag, not half of it.
    private func moveTask(
        _ dragged: WriterTask, toParent parentTaskId: String?,
        priority newPriority: Double, in doc: Document
    ) {
        let reparents = dragged.parentTaskId != parentTaskId
        if reparents { undoManager?.beginUndoGrouping() }
        defer {
            if reparents {
                undoManager?.setActionName("Move Task")
                undoManager?.endUndoGrouping()
            }
        }
        if reparents {
            doc.setTaskParent(id: dragged.id, parentTaskId: parentTaskId,
                              undoManager: undoManager)
        }
        doc.setTaskPriority(id: dragged.id, priority: newPriority,
                            undoManager: undoManager)
    }

    // MARK: - New task sheet

    private func presentCreateSheet() {
        newTaskBody = ""
        // The pane's own scope where the posture takes a task there, else
        // whichever scope it does.
        let offered = creation
        if scope == .document, offered.document {
            newTaskScope = .document
        } else if scope == .project, offered.project {
            newTaskScope = .project
        } else {
            newTaskScope = offered.document ? .document : .project
        }
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
        // Filed only where the posture allows a task (P3c Task 8). The sheet
        // offers no scope it refuses, so this is the stale-press arm: nothing
        // is filed, and the sheet closes as a cancel would.
        let offered = creation
        switch newTaskScope {
        case .document:
            if let doc = activeDoc() {
                if offered.document {
                    _ = doc.createPaneTask(body: trimmed, parentTaskId: nil,
                                           undoManager: undoManager)
                }
            } else if offered.project {
                // Defensive fallback: doc-scope but no active doc → project.
                _ = store.createProjectPaneTask(body: trimmed,
                                                undoManager: undoManager)
            }
        case .project:
            if offered.project {
                _ = store.createProjectPaneTask(body: trimmed,
                                                undoManager: undoManager)
            }
        }
        showCreateSheet = false
        newTaskBody = ""
    }
}

// MARK: - Inline checkbox flip helper

/// Flip the leading checkbox marker of an inline-task paragraph.
/// Operates only on the first occurrence of `- [ ]` / `- [x]` / `- [X]`
/// at the start of the trimmed paragraph (per Fountain/markdown).
/// Detection of "is there a marker to flip at all" is sourced from the
/// shared `TaskMarkup.lineContainsTaskMarker` predicate (MaughamCore);
/// the actual bracket swap stays local since it needs a precise range,
/// which the boolean predicate can't express.
@MainActor
func flipInlineCheckbox(_ text: String) -> String {
    guard TaskMarkup.lineContainsTaskMarker(text) else { return text }
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
    /// Whether the project's own stream takes a task from this Mac (P3c Task
    /// 8) — false only for a posture that files no task there.
    var canPickProjectScope: Bool = true
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
                    if canPickDocumentScope {
                        Text("Document")
                            .tag(TasksPane.ScopeChoice.document)
                    }
                    if canPickProjectScope {
                        Text("Project").tag(TasksPane.ScopeChoice.project)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(!(canPickDocumentScope && canPickProjectScope))
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

// MARK: - What the posture lets the pane offer (P3c Task 8)

/// **Which verbs one task row may offer** — a pure decision over the posture of
/// the task's OWN document (a chapter's, or the project stream's for the
/// project's own tasks), hidden rather than greyed where it refuses.
///
/// A task is `.task` — a task op on that document's stream. **A toggle or an
/// archive of an INLINE task also moves the manuscript**: the toggle flips the
/// `[ ]`/`[x]` bracket in the paragraph (`InlineToggleUndo`) and the archive
/// splices the anchor out of it, so both also need `.writeText`. A pane-created
/// task's toggle and archive are ops alone.
struct TaskRowVerbs: Equatable {
    let toggle: Bool
    let archive: Bool
    /// A pane-created task's Delete (modeled as an archive op).
    let delete: Bool
    let move: Bool

    /// Every verb — the P1 row.
    static let unrestricted = TaskRowVerbs(toggle: true, archive: true, delete: true, move: true)

    static func decide(kind: TaskKind, posture: Posture) -> TaskRowVerbs {
        let task = posture.allows(.task)
        let editsText: Bool
        switch kind {
        case .paneCreated: editsText = false
        case .inlineMarkdown, .fountainBoneyard: editsText = true
        }
        let textIfNeeded = !editsText || posture.allows(.writeText)
        return TaskRowVerbs(
            toggle: task && textIfNeeded,
            archive: task && textIfNeeded,
            delete: task,
            move: task)
    }
}

/// **Where New task may file one** — the shown document, the project's own
/// stream, both or neither. An author of some pieces files on the project and
/// in her own pieces; a reviewer files nowhere, and the + is not drawn.
struct TaskCreationScopes: Equatable {
    let document: Bool
    let project: Bool

    var offersAny: Bool { document || project }

    /// `document` is nil where no document is shown.
    static func decide(document: Posture?, project: Posture) -> TaskCreationScopes {
        TaskCreationScopes(
            document: document?.allows(.task) ?? false,
            project: project.allows(.task))
    }
}
