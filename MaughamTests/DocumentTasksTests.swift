import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class DocumentTasksTests: XCTestCase {

    // MARK: - Fixture

    private func makeProject(initialMd: String = "Hello.") throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TASKS-\(UUID().uuidString)")
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
                id: "doc-test", title: "C1", type: .document,
                path: docPath)],
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

    private func firstParagraphId(of doc: Document) async throws -> String {
        let log = try await doc.opLog()
        guard let bootstrap = log.first(where: { $0.kind == .bootstrap }),
              let pid = bootstrap.changes.first?.paragraphId else {
            XCTFail("no bootstrap paragraph")
            throw NSError(domain: "test", code: 0)
        }
        return pid
    }

    // MARK: - Read API

    func test_tasks_emptyByDefault() async throws {
        let doc = try await makeDocument()
        XCTAssertTrue(doc.tasks(filter: .init(scope: .document(docId: doc.docId))).isEmpty)
    }

    func test_createPaneTask_appearsInTasks() async throws {
        let doc = try await makeDocument()
        let task = doc.createPaneTask(body: "draft act 2", parentTaskId: nil)
        let tasks = doc.tasks(filter: .init(scope: .document(docId: doc.docId), statuses: [.open]))
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, task.id)
        XCTAssertEqual(tasks.first?.body, "draft act 2")
        XCTAssertEqual(tasks.first?.kind, .paneCreated)
    }

    func test_inlineCheckbox_appearsViaParagraphMutation() async throws {
        let doc = try await makeDocument(initialMd: "Hello.")
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: "- [ ] inline thing")
        let tasks = doc.tasks(filter: .init(scope: .document(docId: doc.docId)))
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.kind, .inlineMarkdown)
        XCTAssertEqual(tasks.first?.status, .open)
        XCTAssertEqual(tasks.first?.body, "inline thing")
    }

    // MARK: - Mutation API

    func test_setTaskStatus_panecreated_updatesStatus() async throws {
        let doc = try await makeDocument()
        let task = doc.createPaneTask(body: "do thing", parentTaskId: nil)
        doc.setTaskStatus(id: task.id, status: .done)
        let openOnly = doc.tasks(filter: .init(
            scope: .document(docId: doc.docId), statuses: [.open]))
        XCTAssertTrue(openOnly.isEmpty, "open filter should exclude done task")
        let allStatuses = doc.tasks(filter: .init(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        XCTAssertEqual(allStatuses.first?.status, .done)
    }

    func test_setTaskPriority_emitsOp() async throws {
        let doc = try await makeDocument()
        let task = doc.createPaneTask(body: "priority test", parentTaskId: nil)
        let countBefore = doc.opLogMirrorCount
        doc.setTaskPriority(id: task.id, priority: 42.0)
        XCTAssertEqual(doc.opLogMirrorCount, countBefore + 1)
        let tasks = doc.tasks(filter: .init(scope: .document(docId: doc.docId)))
        XCTAssertEqual(tasks.first?.priority, 42.0)
    }

    func test_setTaskParent_emitsOp() async throws {
        let doc = try await makeDocument()
        let parent = doc.createPaneTask(body: "parent", parentTaskId: nil)
        let child = doc.createPaneTask(body: "child", parentTaskId: nil)
        let countBefore = doc.opLogMirrorCount
        doc.setTaskParent(id: child.id, parentTaskId: parent.id)
        XCTAssertEqual(doc.opLogMirrorCount, countBefore + 1)
        let tasks = doc.tasks(filter: .init(scope: .document(docId: doc.docId)))
        let childRefreshed = tasks.first { $0.id == child.id }
        XCTAssertEqual(childRefreshed?.parentTaskId, parent.id)
    }

    func test_setTaskParent_nilClearsParent() async throws {
        let doc = try await makeDocument()
        let parent = doc.createPaneTask(body: "parent", parentTaskId: nil)
        let child = doc.createPaneTask(body: "child", parentTaskId: parent.id)
        doc.setTaskParent(id: child.id, parentTaskId: nil)
        let tasks = doc.tasks(filter: .init(scope: .document(docId: doc.docId)))
        let childRefreshed = tasks.first { $0.id == child.id }
        XCTAssertNil(childRefreshed?.parentTaskId)
    }

    func test_editPaneTaskBody_emitsOp() async throws {
        let doc = try await makeDocument()
        let task = doc.createPaneTask(body: "old body", parentTaskId: nil)
        doc.editPaneTaskBody(id: task.id, body: "new body")
        let tasks = doc.tasks(filter: .init(scope: .document(docId: doc.docId)))
        XCTAssertEqual(tasks.first?.body, "new body")
    }

    func test_archiveTask_emitsArchiveOp() async throws {
        let doc = try await makeDocument()
        let task = doc.createPaneTask(body: "to archive", parentTaskId: nil)
        doc.archiveTask(id: task.id)
        let openOnly = doc.tasks(filter: .init(
            scope: .document(docId: doc.docId), statuses: [.open]))
        XCTAssertTrue(openOnly.isEmpty)
        let allStatuses = doc.tasks(filter: .init(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        XCTAssertEqual(allStatuses.first?.status, .archived)
    }

    // MARK: - Cache + version

    func test_tasksVersion_bumpsOnMutation() async throws {
        let doc = try await makeDocument()
        let v1 = doc.tasksVersion
        _ = doc.createPaneTask(body: "x", parentTaskId: nil)
        XCTAssertGreaterThan(doc.tasksVersion, v1)
    }

    func test_tasksCache_isStableAcrossNoOpReads() async throws {
        let doc = try await makeDocument()
        _ = doc.createPaneTask(body: "x", parentTaskId: nil)
        // Force first build so cache is valid.
        _ = doc.tasks(filter: .init(scope: .document(docId: doc.docId)))
        let v1 = doc.tasksVersion
        _ = doc.tasks(filter: .init(scope: .document(docId: doc.docId)))
        _ = doc.tasks(filter: .init(scope: .document(docId: doc.docId)))
        XCTAssertEqual(doc.tasksVersion, v1,
            "subsequent reads with no mutation must not bump version")
    }

    // MARK: - Inline status invariant

    func test_inlineStatusToggle_viaSetParagraph_doesNotEmitTaskOp() async throws {
        // Toggling - [ ] to - [x] via setParagraph produces .typingBurst,
        // NOT .taskStatusChange. Inline status IS text-is-state per spec.
        let doc = try await makeDocument(initialMd: "Hello.")
        let pid = try await firstParagraphId(of: doc)

        doc.setParagraph(id: pid, text: "- [ ] inline thing")
        try await doc.flushBurstNow()

        let opCountBefore = doc.opLogMirrorCount
        doc.setParagraph(id: pid, text: "- [x] inline thing")
        try await doc.flushBurstNow()

        let kinds = doc.opLogSnapshot.dropFirst(opCountBefore).map(\.kind)
        XCTAssertTrue(kinds.contains(.typingBurst),
            "toggling inline checkbox should produce a typingBurst")
        XCTAssertFalse(kinds.contains(.taskStatusChange),
            "toggling inline checkbox must NOT emit a taskStatusChange op")
    }

    // MARK: - Op.withReplacedOpId helper

    func test_op_withReplacedOpId_replacesOnlyOpId() {
        let original = Op(
            opId: "old_id",
            docId: "doc-x", at: Date(),
            device: "m", session: "s",
            kind: .taskPriorityChange,
            changes: [],
            sequence: nil,
            provenance: Op.Provenance(
                taskId: "tid",
                taskPriority: 2.0))
        let replaced = original.withReplacedOpId("new_id")
        XCTAssertEqual(replaced.opId, "new_id")
        XCTAssertEqual(replaced.docId, original.docId)
        XCTAssertEqual(replaced.kind, original.kind)
        XCTAssertEqual(replaced.provenance?.taskId, "tid")
        XCTAssertEqual(replaced.provenance?.taskPriority, 2.0)
    }
}
