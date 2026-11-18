import SwiftUI
import MaughamCore
import os

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

    /// The Doc / Project choice — `ResolveTaskScope`, which the moved verbs take.
    typealias ScopeChoice = ResolveTaskScope

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

    /// The toolbar, built from values (`TasksPaneToolbar`, #122) so a test can
    /// measure it against the column's floor without a store.
    private var toolbar: some View {
        TasksPaneToolbar(
            scope: $scope,
            statusFilter: $statusFilter,
            // **Hidden where the posture offers no task anywhere this pane
            // could file one** (P3c Task 8) — never greyed for that reason;
            // the pre-existing "no document for Doc scope" disable is a
            // different fact and stays.
            showsNewTask: creation.offersAny,
            newTaskDisabled: newTaskButtonDisabled,
            showsBulkMenu: mayArchiveInScope,
            onNewTask: { presentCreateSheet() },
            onArchiveAllDone: { taskVerbs.archiveAllDone(in: scope) })
    }

    private var newTaskButtonDisabled: Bool {
        // Disabled only when doc-scope is selected and there's no active doc.
        scope == .document && activeDoc() == nil
    }

    // MARK: - What the posture allows (P3c Task 8)

    /// **This pane's to-do verbs** — `ResolveTaskVerbs`, built per call over
    /// the window's undo manager and never stored. The open piece is
    /// `activeDocId`: a to-do on any other piece reads and offers nothing.
    var taskVerbs: ResolveTaskVerbs {
        ResolveTaskVerbs(store: store, documentStore: documentStore,
                         openDocId: activeDocId, undoManager: undoManager)
    }

    /// The posture of a stream, asked of the window's drawing door.
    private func posture(ofTaskDocument docId: String) -> Posture {
        documentStore.posture(forDocId: docId)
    }

    /// The verbs one row may offer — the posture's, through the gate.
    func verbs(for task: WriterTask) -> TaskRowVerbs {
        taskVerbs.offered(task)
    }

    /// Where New task may file: the shown document, the project, both or
    /// neither.
    var creation: TaskCreationScopes { taskVerbs.creation }

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
            // `.sidebar` stays for drag-to-reorder; its material fill does not
            // — no other right-column pane paints one (#122).
            .scrollContentBackground(.hidden)
            // The List's own primary action: double-click on a row, or
            // Return with one selected, jumps to its paragraph — no tap
            // gesture on the row (tripwire 9). Right-click offers the same.
            .contextMenu(forSelectionType: String.self, menu: { ids in
                if let task = Self.jumpTarget(for: ids, in: currentPool()) {
                    Button("Jump to Source") { jumpToParagraph(task) }
                }
            }, primaryAction: { ids in
                if let task = Self.jumpTarget(for: ids, in: currentPool()) {
                    jumpToParagraph(task)
                }
            })
        }
    }

    @ViewBuilder
    private func row(for task: WriterTask) -> some View {
        let offered = verbs(for: task)
        TaskRow(
            task: task,
            verbs: offered,
            onToggle: { taskVerbs.toggle(task) },
            onJump:   { jumpToParagraph(task) },
            onArchive: { taskVerbs.archive(task) },
            onDelete: { taskVerbs.delete(task) })
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
                      verbs(for: dragged).move,
                      ResolveTaskVerbs.acceptsDrop(of: dragged, onto: task)
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

    private func activeDoc() -> Document? { taskVerbs.activeDoc() }

    private func coerceScopeIfNoActiveDoc() {
        if scope == .document && activeDoc() == nil {
            scope = .project
        }
    }

    // MARK: - Navigation

    /// The task a double-click or Return on the list jumps to: exactly one
    /// selected id, found in `tasks`, of a kind anchored to a paragraph.
    /// Nil for an empty or multiple selection, an unknown id, or a
    /// pane-created task (it has no paragraph).
    static func jumpTarget(for selection: Set<String>, in tasks: [WriterTask]) -> WriterTask? {
        guard selection.count == 1, let id = selection.first,
              let task = tasks.first(where: { $0.id == id }),
              task.anchor?.paragraphId != nil
        else { return nil }
        switch task.kind {
        case .inlineMarkdown, .fountainBoneyard: return task
        case .paneCreated: return nil
        }
    }

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
        guard verbs(for: dragged).move,
              let doc = documentStore.document(
                forDocId: ResolveTaskVerbs.docId(of: dragged)) else { return }

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

        taskVerbs.apply(intent: intent, dragged: dragged, in: doc, allTasks: visible)
    }

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
        guard let doc = documentStore.document(
            forDocId: ResolveTaskVerbs.docId(of: dragged)) else { return }
        taskVerbs.apply(intent: intent, dragged: dragged, in: doc, allTasks: pool)
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
        // Filed only where the posture allows a task (P3c Task 8): the moved
        // act (`ResolveTaskVerbs.createTask`) refuses a scope it may not file in.
        taskVerbs.createTask(body: trimmed, in: newTaskScope)
        showCreateSheet = false
        newTaskBody = ""
    }
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

