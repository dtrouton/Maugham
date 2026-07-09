import XCTest
import MaughamCore
@testable import Maugham

/// ⌘Z undo of pane-task op mutations (Task 4). Covers:
///  - `TaskInverse` pure inverse-op factory (Mac-side sibling of
///    MaughamCore's `AnnotationInverse`; task types are Mac-only).
///  - Document-level NSUndoManager integration for the six task mutators.
///  - ProjectStore project-scope pane-task create undo.
///
/// See `docs/superpowers/specs/` unified-undo spec + `.superpowers/sdd/task-4-brief.md`.
@MainActor
final class TaskUndoTests: XCTestCase {

    // MARK: - Helpers

    private static let testDate: Date = {
        ISO8601DateFormatter().date(from: "2026-05-23T18:00:00Z")!
    }()

    /// Memberwise `WriterTask` (all fields per `Task.swift`).
    private func makeWriterTask(
        id: String, status: TaskStatus, priority: Double,
        body: String = "body", kind: TaskKind = .paneCreated,
        parentTaskId: String? = nil
    ) -> WriterTask {
        WriterTask(
            id: id, kind: kind,
            anchor: TaskAnchor(docId: "d1", paragraphId: nil),
            body: body, status: status, priority: priority,
            parentTaskId: parentTaskId,
            createdAt: Self.testDate,
            createdBySession: "s1")
    }

    /// Mirrors `TaskDeriverTests.makeOp`.
    private func makeOp(
        opId: String, kind: OpKind, docId: String = "doc_test",
        provenance: Op.Provenance? = nil
    ) -> Op {
        Op(opId: opId, docId: docId, at: Self.testDate,
           device: "test-device", session: "test-session",
           kind: kind, changes: [], sequence: nil, provenance: provenance)
    }

    // Document fixture (mirrors DocumentTasksTests).

    private func makeProject(initialMd: String = "Hello.") throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TASK-UNDO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document, path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    private func makeDocument(initialMd: String = "Hello.") async throws -> Document {
        let (project, path) = try makeProject(initialMd: initialMd)
        return try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
    }

    private func currentStatus(_ doc: Document, _ id: String) -> TaskStatus? {
        doc.tasks(filter: .init(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases))).first { $0.id == id }?.status
    }

    private func currentTask(_ doc: Document, _ id: String) -> WriterTask? {
        doc.tasks(filter: .init(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases))).first { $0.id == id }
    }

    // MARK: - TaskInverse pure factory

    func test_inverse_statusChange_carriesPriorStatus() {
        let prior = makeWriterTask(id: "t1", status: .open, priority: 3.0)
        let op = TaskInverse.inverse(undoing: .taskStatusChange, prior: prior,
                                     docId: "d1", device: "mac", session: "s1", sessionId: "s1")
        XCTAssertEqual(op?.kind, .taskStatusChange)
        XCTAssertEqual(op?.provenance?.taskStatus, "open")
        XCTAssertEqual(op?.provenance?.taskId, "t1")
    }

    func test_inverse_priorityChange_carriesPriorPriority() {
        let prior = makeWriterTask(id: "t1", status: .open, priority: 3.0)
        let op = TaskInverse.inverse(undoing: .taskPriorityChange, prior: prior,
                                     docId: "d1", device: "mac", session: "s1", sessionId: "s1")
        XCTAssertEqual(op?.kind, .taskPriorityChange)
        XCTAssertEqual(op?.provenance?.taskPriority, 3.0)
        XCTAssertEqual(op?.provenance?.taskId, "t1")
    }

    func test_inverse_parentChange_nilPrior_emitsClearSentinel() {
        // TaskDeriver treats "" as clear-parent (Document+Tasks.swift:276 convention).
        let prior = makeWriterTask(id: "t1", status: .open, priority: 3.0, parentTaskId: nil)
        let op = TaskInverse.inverse(undoing: .taskParentChange, prior: prior,
                                     docId: "d1", device: "mac", session: "s1", sessionId: "s1")
        XCTAssertEqual(op?.kind, .taskParentChange)
        XCTAssertEqual(op?.provenance?.taskParentId, "")
    }

    func test_inverse_parentChange_nonNilPrior_carriesPriorParent() {
        let prior = makeWriterTask(id: "t1", status: .open, priority: 3.0, parentTaskId: "p9")
        let op = TaskInverse.inverse(undoing: .taskParentChange, prior: prior,
                                     docId: "d1", device: "mac", session: "s1", sessionId: "s1")
        XCTAssertEqual(op?.provenance?.taskParentId, "p9")
    }

    func test_inverse_bodyEdit_carriesPriorBody() {
        let prior = makeWriterTask(id: "t1", status: .open, priority: 3.0, body: "old body")
        let op = TaskInverse.inverse(undoing: .taskBodyEdit, prior: prior,
                                     docId: "d1", device: "mac", session: "s1", sessionId: "s1")
        XCTAssertEqual(op?.kind, .taskBodyEdit)
        XCTAssertEqual(op?.provenance?.taskBody, "old body")
    }

    func test_inverse_create_isArchive_carryingBodyAndKind() {
        // archiveTask's convention: taskArchive carries taskBody + taskKind.
        let prior = makeWriterTask(id: "t1", status: .open, priority: 3.0,
                                   body: "created", kind: .paneCreated)
        let op = TaskInverse.inverse(undoing: .taskCreate, prior: prior,
                                     docId: "d1", device: "mac", session: "s1", sessionId: "s1")
        XCTAssertEqual(op?.kind, .taskArchive)
        XCTAssertEqual(op?.provenance?.taskKind, "pane_created")
        XCTAssertEqual(op?.provenance?.taskBody, "created")
    }

    func test_inverse_archive_isStatusChange_toPriorStatus() {
        let prior = makeWriterTask(id: "t1", status: .done, priority: 3.0)
        let op = TaskInverse.inverse(undoing: .taskArchive, prior: prior,
                                     docId: "d1", device: "mac", session: "s1", sessionId: "s1")
        XCTAssertEqual(op?.kind, .taskStatusChange)
        XCTAssertEqual(op?.provenance?.taskStatus, "done")
    }

    func test_inverse_unsupportedKind_returnsNil() {
        let prior = makeWriterTask(id: "t1", status: .open, priority: 3.0)
        let op = TaskInverse.inverse(undoing: .typingBurst, prior: prior,
                                     docId: "d1", device: "mac", session: "s1", sessionId: "s1")
        XCTAssertNil(op)
    }

    func test_deriveRoundTrip_forwardPlusInverse_returnsToBaseline() {
        // create op → status op (done) → inverse (open); derive → status .open.
        let create = makeOp(
            opId: "t1", kind: .taskCreate,
            provenance: Op.Provenance(
                sessionId: "s1", taskId: "t1",
                taskBody: "thing", taskPriority: 1.0, taskKind: "pane_created"))
        let toDone = makeOp(
            opId: "op2", kind: .taskStatusChange,
            provenance: Op.Provenance(taskId: "t1", taskStatus: "done"))
        // Inverse restores the PRIOR (open) captured before the toDone mutation.
        let priorOpen = makeWriterTask(id: "t1", status: .open, priority: 1.0)
        let inverse = TaskInverse.inverse(
            undoing: .taskStatusChange, prior: priorOpen,
            docId: "doc_test", device: "d", session: "s", sessionId: "s")!
        let (tasks, _, _) = TaskDeriver.derive(
            ops: [create, toDone, inverse], paragraphs: [:], docId: "doc_test")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, "t1")
        XCTAssertEqual(tasks.first?.status, .open)
    }

    // MARK: - Document-level NSUndoManager integration

    func test_setTaskStatus_undo_restoresPriorStatus() async throws {
        let doc = try await makeDocument()
        let task = doc.createPaneTask(body: "do thing", parentTaskId: nil)
        let um = UndoManager()
        doc.setTaskStatus(id: task.id, status: .done, undoManager: um)
        XCTAssertEqual(currentStatus(doc, task.id), .done)

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(currentStatus(doc, task.id), .open)

        um.redo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(currentStatus(doc, task.id), .done)

        // Re-arm: redo forwards the LIVE undo manager into the forward
        // re-mutation, which registers a FRESH undo pair — ⌘Z/⇧⌘Z cycles
        // indefinitely, not a dead action after one redo (a nil-forwarded
        // manager — the T3 regression — would fail right here). The awaited
        // work task above IS the redo hop that re-registered (async mirror
        // of AnnotationLifecycleUndoTests' pump-then-assert idiom).
        XCTAssertTrue(um.canUndo,
            "redo's forward re-mutation must re-register undo — the cycle re-arms")
        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(currentStatus(doc, task.id), .open,
            "a second ⌘Z after ⇧⌘Z must restore the prior status again")
    }

    func test_setTaskPriority_undo_restoresPriorPriority() async throws {
        let doc = try await makeDocument()
        let task = doc.createPaneTask(body: "prio", parentTaskId: nil)
        let original = currentTask(doc, task.id)?.priority
        let um = UndoManager()
        doc.setTaskPriority(id: task.id, priority: 99.0, undoManager: um)
        XCTAssertEqual(currentTask(doc, task.id)?.priority, 99.0)

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(currentTask(doc, task.id)?.priority, original)
    }

    func test_setTaskParent_undo_restoresNilParent() async throws {
        let doc = try await makeDocument()
        let parent = doc.createPaneTask(body: "parent", parentTaskId: nil)
        let child = doc.createPaneTask(body: "child", parentTaskId: nil)
        let um = UndoManager()
        doc.setTaskParent(id: child.id, parentTaskId: parent.id, undoManager: um)
        XCTAssertEqual(currentTask(doc, child.id)?.parentTaskId, parent.id)

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertNil(currentTask(doc, child.id)?.parentTaskId)
    }

    func test_editPaneTaskBody_undo_restoresPriorBody() async throws {
        let doc = try await makeDocument()
        let task = doc.createPaneTask(body: "old body", parentTaskId: nil)
        let um = UndoManager()
        doc.editPaneTaskBody(id: task.id, body: "new body", undoManager: um)
        XCTAssertEqual(currentTask(doc, task.id)?.body, "new body")

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(currentTask(doc, task.id)?.body, "old body")
    }

    func test_createPaneTask_undo_archives() async throws {
        let doc = try await makeDocument()
        let um = UndoManager()
        let task = doc.createPaneTask(body: "ephemeral", parentTaskId: nil, undoManager: um)
        XCTAssertEqual(currentStatus(doc, task.id), .open)

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(currentStatus(doc, task.id), .archived,
            "undo of create archives the derived task")

        // Redo re-creates. NOTE: redo mints a NEW task id (a fresh .taskCreate
        // op), so the ORIGINAL id stays archived; the redone task is a new row.
        um.redo(); await doc.awaitPendingUndoWork()
        let openTasks = doc.tasks(filter: .init(
            scope: .document(docId: doc.docId), statuses: [.open]))
        XCTAssertEqual(openTasks.count, 1)
        XCTAssertEqual(openTasks.first?.body, "ephemeral")
        let newId = try XCTUnwrap(openTasks.first?.id)
        XCTAssertNotEqual(newId, task.id,
            "redo of create mints a NEW task id (create/destroy semantics)")

        // Re-arm: the redo hop's forward re-create forwarded the LIVE undo
        // manager, registering a fresh undo pair for the NEW id (a nil-
        // forwarded manager — the T3 regression — would fail right here).
        // The second ⌘Z therefore archives the NEW task.
        XCTAssertTrue(um.canUndo,
            "redo's forward re-create must re-register undo — the cycle re-arms")
        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(currentStatus(doc, newId), .archived,
            "a second ⌘Z after ⇧⌘Z archives the redo-minted task")
        let openAfter = doc.tasks(filter: .init(
            scope: .document(docId: doc.docId), statuses: [.open]))
        XCTAssertTrue(openAfter.isEmpty)
    }

    func test_archiveTask_undo_restoresPriorStatus() async throws {
        let doc = try await makeDocument()
        let task = doc.createPaneTask(body: "to archive", parentTaskId: nil)
        let um = UndoManager()
        doc.archiveTask(id: task.id, undoManager: um)
        XCTAssertEqual(currentStatus(doc, task.id), .archived)

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(currentStatus(doc, task.id), .open,
            "undo of pane-task archive restores prior (open) status")
    }

    func test_undo_onVanishedTask_isLoudNoOp() async throws {
        let doc = try await makeDocument()
        let task = doc.createPaneTask(body: "doomed", parentTaskId: nil)
        let um = UndoManager()
        doc.setTaskStatus(id: task.id, status: .done, undoManager: um)
        // Archive the task out from under the pending undo (out of band).
        doc.archiveTask(id: task.id)
        XCTAssertEqual(currentStatus(doc, task.id), .archived)

        let countBefore = doc.opLogMirrorCount
        um.undo(); await doc.awaitPendingUndoWork()
        // Guard declined: the task no longer holds the value the forward wrote,
        // so no compensating op is appended.
        XCTAssertEqual(doc.opLogMirrorCount, countBefore,
            "undo of a status change on a vanished/drifted task is a loud no-op")
        XCTAssertEqual(currentStatus(doc, task.id), .archived)
    }

    // MARK: - ProjectStore project-scope create undo

    func test_createProjectPaneTask_undo_archives() async throws {
        let (url, _) = try makeProject()
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds

        let um = UndoManager()
        let task = store.createProjectPaneTask(body: "project todo", undoManager: um)
        var open = store.listTasksAcrossProject(
            filter: .init(scope: .project, statuses: [.open]))
        XCTAssertTrue(open.contains { $0.id == task.id })

        um.undo(); await store._lastUndoWorkTask?.value
        let all = store.listTasksAcrossProject(
            filter: .init(scope: .project, statuses: Set(TaskStatus.allCases)))
        XCTAssertEqual(all.first { $0.id == task.id }?.status, .archived,
            "undo of project pane-task create archives it")

        // Redo re-creates (new id, per create-undo convention).
        um.redo(); await store._lastUndoWorkTask?.value
        open = store.listTasksAcrossProject(
            filter: .init(scope: .project, statuses: [.open]))
        XCTAssertTrue(open.contains { $0.body == "project todo" })
        _ = ds  // keep the weak documentStore link alive.
    }
}
