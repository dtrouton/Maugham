import XCTest
@testable import Maugham

/// Regression: archived inline tasks vanished from the pane entirely
/// because the deriver derives inline tasks from paragraph text, and
/// `archiveTask` splices the text away. The Archived filter showed
/// nothing because there was nothing to derive.
///
/// Fix: `archiveTask` captures `body` and `kind` in the `.taskArchive`
/// op's provenance, and `TaskDeriver` synthesizes a stub WriterTask
/// entry with `status = .archived` for each archive op whose synth-id
/// isn't in the live text-derived set.
@MainActor
final class ArchivedInlineTaskVisibilityTests: XCTestCase {

    private func makeDoc(text: String = "") async throws -> Document {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AITV-\(UUID().uuidString)")
        let manuscriptDir = tmp.appendingPathComponent("manuscript")
        try FileManager.default.createDirectory(
            at: manuscriptDir, withIntermediateDirectories: true)
        let mdURL = manuscriptDir.appendingPathComponent("doc.md")
        try text.write(to: mdURL, atomically: true, encoding: .utf8)
        return try await Document.load(
            url: mdURL, device: "test", session: "s", presenter: nil)
    }

    func test_archivedInlineMarkdownTask_surfacesInArchivedFilter() async throws {
        let doc = try await makeDoc(text: "")
        let pid = doc.opLogSnapshot.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "abcd"
        doc.setParagraph(id: pid, text: "- [ ] needs tidying")
        // Warm the cache so mint persists + the task lands in _tasksCache.
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        guard let task = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: [.open])).first else {
            return XCTFail("inline task should have derived")
        }

        // Archive it.
        doc.archiveTask(id: task.id)

        // Open filter: empty.
        let openTasks = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId), statuses: [.open]))
        XCTAssertTrue(openTasks.isEmpty,
            "after archive, no open inline tasks should remain")

        // Archived filter: the archived task surfaces.
        let archivedTasks = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId), statuses: [.archived]))
        XCTAssertEqual(archivedTasks.count, 1,
            "archived inline task must show in Archived filter")
        XCTAssertEqual(archivedTasks.first?.body, "needs tidying")
        XCTAssertEqual(archivedTasks.first?.kind, .inlineMarkdown)
        XCTAssertEqual(archivedTasks.first?.status, .archived)
    }

    func test_archivedFountainInlineTask_surfacesInArchivedFilter() async throws {
        let doc = try await makeDoc(text: "")
        let pid = doc.opLogSnapshot.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "abcd"
        doc.setParagraph(
            id: pid,
            text: "And now I see [[todo: this part]] but not all.")
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        guard let task = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: [.open])).first(where: { $0.kind == .fountainBoneyard })
        else {
            return XCTFail("Fountain todo should have derived")
        }
        doc.archiveTask(id: task.id)
        let archivedTasks = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId), statuses: [.archived]))
        XCTAssertEqual(archivedTasks.count, 1)
        XCTAssertEqual(archivedTasks.first?.body, "this part")
        XCTAssertEqual(archivedTasks.first?.kind, .fountainBoneyard)
    }

    func test_archivedInlineTask_doesNotSurfaceInOpenOrDoneFilters() async throws {
        let doc = try await makeDoc(text: "")
        let pid = doc.opLogSnapshot.first(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "abcd"
        doc.setParagraph(id: pid, text: "- [ ] one")
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let task = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId), statuses: [.open])).first!
        doc.archiveTask(id: task.id)
        let openTasks = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId), statuses: [.open]))
        let doneTasks = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId), statuses: [.done]))
        XCTAssertTrue(openTasks.isEmpty)
        XCTAssertTrue(doneTasks.isEmpty)
    }
}
