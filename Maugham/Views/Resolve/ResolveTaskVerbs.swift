import SwiftUI
import MaughamCore

/// **Which to-dos a scope-wide verb reaches**: the piece open in the centre,
/// or every to-do the project lists. (The tasks pane's Doc / Project choice.)
enum ResolveTaskScope: Hashable {
    case document
    case project
}

/// **A to-do's verbs** — toggle, archive, delete, reorder, New task's act and
/// Archive all done. Moved out of the tasks pane for To resolve (shell plan 2
/// Task 4), unchanged in what each writes and how it registers ⌘Z, with one
/// rule added: **a to-do acts only on the piece open in the window's centre**
/// (`ResolveVerbGate`), or on the Book's own stream, which needs no
/// `Document`. Today a closed piece's to-do verbs were silent no-ops; now
/// they are not offered (`offered`), and every verb below refuses a to-do
/// whose piece is not the open one before it looks for a document — so no
/// press, stale or otherwise, writes a piece that is not open.
///
/// Built per call by its host and never stored; `undoManager` is the
/// window's, threaded into every mutation so ⌘Z reverses it. Inline toggles
/// register a guarded text flip-back (text-is-state); pane-created mutations
/// register op inverses via `OpUndoRegistrar` / `TaskInverse`.
@MainActor
struct ResolveTaskVerbs {
    let store: ProjectStore
    let documentStore: DocumentStore
    /// The piece open in this window's centre — the only piece whose to-dos act.
    let openDocId: String?
    let undoManager: UndoManager?

    // MARK: - What a row may offer

    /// The posture of the document a task belongs to — its anchor's, where the
    /// project's own tasks are the project stream's (`__project__`). Asked of
    /// the window's drawing door; every task is judged by ITS document, never
    /// by the one the window happens to show.
    private func posture(ofTaskDocument docId: String) -> Posture {
        documentStore.posture(forDocId: docId)
    }

    /// The document a task's verbs would write: its anchor's, else the Book's.
    static func docId(of task: WriterTask) -> String {
        task.anchor?.docId ?? ProjectStore.projectTasksDocId
    }

    /// May this window act on `task`'s piece — the open one, registered?
    private func mayAct(on task: WriterTask) -> Bool {
        ResolveVerbGate.mayAct(
            onDocId: Self.docId(of: task), openDocId: openDocId,
            isRegistered: { documentStore.document(forDocId: $0) != nil })
    }

    /// **The verbs one row may offer**: the posture's (`TaskRowVerbs.decide`)
    /// through the gate — on the open piece or the Book's stream, else none.
    func offered(_ task: WriterTask) -> TaskRowVerbs {
        let docId = Self.docId(of: task)
        return ResolveVerbGate.taskVerbs(
            TaskRowVerbs.decide(kind: task.kind, posture: posture(ofTaskDocument: docId)),
            mayAct: mayAct(on: task),
            isBookLevel: docId == ProjectStore.projectTasksDocId)
    }

    /// The open piece's live document, which New task and document-scope
    /// Archive all done file on.
    func activeDoc() -> Document? {
        guard let id = openDocId,
              id != BinderSubject.noDocumentSubject else { return nil }
        return documentStore.document(forDocId: id)
    }

    /// Where New task may file: the open piece, the project, both or neither.
    var creation: TaskCreationScopes {
        TaskCreationScopes.decide(
            document: activeDoc().map { posture(ofTaskDocument: $0.docId) },
            project: posture(ofTaskDocument: ProjectStore.projectTasksDocId))
    }

    /// **A drop is accepted only within one piece** — a reorder or a nest
    /// reads the target's priority and parent, and a target on another piece
    /// is a task the dragged one's document does not hold. An unanchored
    /// to-do is the Book's.
    static func acceptsDrop(of dragged: WriterTask, onto target: WriterTask) -> Bool {
        docId(of: dragged) == docId(of: target)
    }

    /// Find the Document that owns a task, by anchor docId — only on the open
    /// piece. The anchor always names a real doc except for project-scope
    /// tasks (where the anchor docId is `__project__` — handled by the caller).
    private func ownerDoc(of task: WriterTask) -> Document? {
        guard mayAct(on: task),
              let anchor = task.anchor,
              anchor.docId != ProjectStore.projectTasksDocId else { return nil }
        return documentStore.document(forDocId: anchor.docId)
    }

    // MARK: - Actions

    func toggle(_ task: WriterTask) {
        // The row draws no toggle where this is false; a stale press (a
        // demotion landing between frames, a centre that moved) does nothing
        // rather than write.
        guard offered(task).toggle else { return }
        let nextStatus: TaskStatus = task.status == .done ? .open : .done
        switch task.kind {
        case .paneCreated:
            // Project-scope pane-created tasks have anchor.docId == __project__
            // and there is no Document to mutate. For doc-scope pane-created
            // tasks, mutate the owning Document.
            if Self.docId(of: task) == ProjectStore.projectTasksDocId {
                // The Book's own to-do: its status op on the project stream
                // (no Document), behind the stream's door.
                Self.setProjectTaskStatus(task, to: nextStatus, store: store,
                                          undoManager: undoManager)
            } else if let doc = ownerDoc(of: task) {
                doc.setTaskStatus(id: task.id, status: nextStatus,
                                  undoManager: undoManager)
            }
        case .inlineMarkdown:
            // Markdown: flip the `[ ]` ↔ `[x]` bracket in the paragraph.
            guard let doc = ownerDoc(of: task),
                  let pid = task.anchor?.paragraphId,
                  let current = doc.paragraph(id: pid) else { return }
            let flipped = flipInlineCheckbox(current)
            guard flipped != current else { return }
            InlineToggleUndo.perform(
                on: doc, paragraphId: pid,
                prior: current, flipped: flipped, undoManager: undoManager,
                mayWrite: mayWriteText(of: doc))
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
                prior: current, flipped: flipped, undoManager: undoManager,
                mayWrite: mayWriteText(of: doc))
        }
    }

    /// **The yield-aware `mayWrite` an inline toggle asks** (#74) — at the
    /// press and inside every undo/redo re-entry: the drawing posture's
    /// `.writeText` for the task's own document. Synchronous, fails closed
    /// (`.settling` refuses; a store gone refuses) — `projectTaskRefusal`'s
    /// precedent.
    private func mayWriteText(of doc: Document) -> @MainActor () -> Bool {
        let docId = doc.docId
        return { [weak postureStore = documentStore] in
            postureStore?.posture(forDocId: docId).allows(.writeText) ?? false
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

    func archive(_ task: WriterTask) {
        guard offered(task).archive else { return }
        if Self.docId(of: task) == ProjectStore.projectTasksDocId {
            Self.archiveProjectTask(task, store: store, undoManager: undoManager)
            return
        }
        guard let doc = ownerDoc(of: task) else { return }
        doc.archiveTask(id: task.id, undoManager: undoManager)
    }

    func delete(_ task: WriterTask) {
        // For pane-created tasks, "Delete" is the destructive end-state —
        // it's modeled as an archive op in this milestone (no separate
        // delete op kind), per spec §11 simplification.
        guard task.kind == .paneCreated, offered(task).delete else { return }
        if Self.docId(of: task) == ProjectStore.projectTasksDocId {
            Self.archiveProjectTask(task, store: store, undoManager: undoManager)
            return
        }
        guard let doc = ownerDoc(of: task) else { return }
        doc.archiveTask(id: task.id, undoManager: undoManager)
    }

    // MARK: - Archived to-dos (shell plan 2 Task 7 fix, controller ruling)

    /// **Whether an archived to-do offers Unarchive**: a pane-created one
    /// (an inline to-do's archive spliced its line out of the manuscript, and
    /// a status change cannot put the words back), where this Mac may change
    /// its status (`offered(_:).toggle`, the status door), on the open piece
    /// or the Book. Hidden otherwise — never an enabled no-op.
    static func offersUnarchive(_ task: WriterTask, verbs: TaskRowVerbs) -> Bool {
        task.status == .archived && task.kind == .paneCreated && verbs.toggle
    }

    /// **Unarchive**: the to-do opens again, one ⌘Z step.
    func unarchive(_ task: WriterTask) {
        guard Self.offersUnarchive(task, verbs: offered(task)) else { return }
        if Self.docId(of: task) == ProjectStore.projectTasksDocId {
            Self.setProjectTaskStatus(task, to: .open, store: store, undoManager: undoManager)
            return
        }
        guard let doc = ownerDoc(of: task) else { return }
        doc.setTaskStatus(id: task.id, status: .open, undoManager: undoManager)
    }

    // MARK: - The Book's own to-dos (the project stream; no Document)

    /// The Book's own to-dos, every status, derived from the project stream's
    /// mirror alone — no closed piece is read.
    static func bookTasks(store: ProjectStore) -> [WriterTask] {
        TaskDeriver.derive(
            ops: store.projectTasksOpLog(), paragraphs: [:],
            docId: ProjectStore.projectTasksDocId, maughamDeviceId: nil).0
    }

    /// **Archive all done, on the Book** — every done Book to-do the
    /// posture lets this Mac archive, as one ⌘Z.
    func archiveAllDoneOnTheBook() {
        let done = Self.bookTasks(store: store).filter { $0.status == .done && offered($0).archive }
        // The stream's one door answers for every append in the batch: where
        // it refuses, open no group, so no empty "Archive Done Tasks" ⌘Z step.
        guard Self.opensBookArchiveGroup(doneCount: done.count,
                                         refusal: store.projectTaskRefusal()) else { return }
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.setActionName("Archive Done Tasks")
            undoManager?.endUndoGrouping()
        }
        for task in done {
            Self.archiveProjectTask(task, store: store, undoManager: undoManager)
        }
    }

    /// **Whether Archive all done on the Book opens an undo group**: only
    /// with something done and a stream that takes the appends.
    static func opensBookArchiveGroup(doneCount: Int, refusal: String?) -> Bool {
        doneCount > 0 && refusal == nil
    }

    /// A Book to-do's status, on the project stream, with its ⌘Z inverse
    /// registered only when the op landed (the stream's door may refuse).
    static func setProjectTaskStatus(
        _ task: WriterTask, to status: TaskStatus, store: ProjectStore,
        undoManager: UndoManager?
    ) {
        let op = Op(
            opId: ULID.generate(),
            docId: ProjectStore.projectTasksDocId,
            at: Date(),
            device: store.projectOpDevice,
            session: store.projectOpSession,
            kind: .taskStatusChange,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: store.projectOpSession,
                taskId: task.id,
                taskStatus: status.rawValue))
        guard store.appendProjectTaskOp(op) else { return }
        guard let inverse = TaskInverse.inverse(
            undoing: .taskStatusChange, prior: task,
            docId: ProjectStore.projectTasksDocId,
            device: store.projectOpDevice, session: store.projectOpSession,
            sessionId: store.projectOpSession) else { return }
        OpUndoRegistrar.register(
            undoManager, actionName: "Change Task Status", target: store,
            workTaskSink: { [weak store] in store?._lastUndoWorkTask = $0 },
            undo: { s in
                // Fire-time guard: only revert what this action wrote.
                guard let now = bookTasks(store: s).first(where: { $0.id == task.id }),
                      now.status == status else {
                    projectStoreLog.error("setProjectTaskStatus undo: \(task.id, privacy: .public) drifted — ignoring")
                    return
                }
                s.appendProjectTaskOp(inverse)
            },
            redo: { [weak undoManager] s in
                Self.setProjectTaskStatus(task, to: status, store: s, undoManager: undoManager)
            })
    }

    /// **New task's act** — files `body` on the open piece or the project,
    /// only where the posture allows a task (P3c Task 8). The sheet offers no
    /// scope it refuses, so a refused scope is the stale-press arm: nothing is
    /// filed.
    func createTask(body: String, in scope: ResolveTaskScope) {
        let offered = creation
        switch scope {
        case .document:
            if let doc = activeDoc() {
                if offered.document {
                    _ = doc.createPaneTask(body: body, parentTaskId: nil,
                                           undoManager: undoManager)
                }
            } else if offered.project {
                // Defensive fallback: doc-scope but no active doc → project.
                _ = store.createProjectPaneTask(body: body,
                                                undoManager: undoManager)
            }
        case .project:
            if offered.project {
                _ = store.createProjectPaneTask(body: body,
                                                undoManager: undoManager)
            }
        }
    }

    /// Archive every Done task in the given scope that this window may act on.
    /// Snapshots the done list before iterating so cache invalidations
    /// on each `archiveTask` call don't mutate the iteration set.
    /// A to-do on a piece that is not open is skipped (`offered`): open the
    /// piece to archive it.
    func archiveAllDone(in scope: ResolveTaskScope) {
        // Snapshot now; archiveTask invalidates the cache on each call.
        let allVisible: [WriterTask]
        switch scope {
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
        for task in allVisible {
            guard let anchor = task.anchor else { continue }
            // Only what the posture lets this Mac archive (P3c Task 8), and
            // only on the open piece or the Book's stream: an author of some
            // pieces archives her own pieces' and the project's done tasks,
            // and leaves somebody else's.
            guard offered(task).archive else { continue }
            if anchor.docId == ProjectStore.projectTasksDocId {
                projectTasks.append(task)
            } else if let doc = ownerDoc(of: task) {
                docTasks.append((task, doc))
            }
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
    /// stale value (and its store) inside NSUndoManager.
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

    // MARK: - Drag-and-drop

    /// Compute and append the ops implied by a drop — only on the open piece,
    /// and only within it (`acceptsDrop`). Internal so integration tests can
    /// call it directly without trying to fake a SwiftUI drop gesture.
    func apply(
        intent: TaskDropIntent,
        dragged: WriterTask,
        in doc: Document,
        allTasks: [WriterTask]
    ) {
        guard Self.docId(of: dragged) == doc.docId,
              ResolveVerbGate.mayAct(
                onDocId: doc.docId, openDocId: openDocId,
                isRegistered: { documentStore.document(forDocId: $0) != nil })
        else { return }
        switch intent {
        case .reorderAbove(let targetId, let parentTaskId):
            guard let target = allTasks.first(where: { $0.id == targetId }),
                  Self.acceptsDrop(of: dragged, onto: target) else { return }
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
            guard let target = allTasks.first(where: { $0.id == targetId }),
                  Self.acceptsDrop(of: dragged, onto: target) else { return }
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
            if let parent = allTasks.first(where: { $0.id == parentId }),
               !Self.acceptsDrop(of: dragged, onto: parent) { return }
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
}

// MARK: - Pure drop classifier
//
// Extracted from the SwiftUI view so the single-level-nesting guard,
// reorder-as-sibling, and child-of-child fallback can be unit-tested
// without a render. Mirrors the shape of `DropIntent` in BinderView; the
// `TaskDropIntent.classify(...)` function is the test entry point.

/// Result of classifying a drag-drop gesture against a to-do row.
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
    /// No verb — a to-do on a piece this window may not act on (`ResolveVerbGate`).
    static let none = TaskRowVerbs(toggle: false, archive: false, delete: false, move: false)

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
