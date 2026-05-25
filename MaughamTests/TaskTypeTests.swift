import XCTest
@testable import Maugham

final class TaskTypeTests: XCTestCase {

    func test_taskKind_rawValues() {
        XCTAssertEqual(TaskKind.inlineMarkdown.rawValue, "inline_markdown")
        XCTAssertEqual(TaskKind.fountainBoneyard.rawValue, "fountain_boneyard")
        XCTAssertEqual(TaskKind.paneCreated.rawValue, "pane_created")
    }

    func test_taskStatus_caseIterable() {
        XCTAssertEqual(TaskStatus.allCases, [.open, .done, .archived])
    }

    func test_taskAnchor_codable() throws {
        let anchor = TaskAnchor(docId: "doc_a", paragraphId: "abcd")
        let data = try JSONEncoder().encode(anchor)
        let decoded = try JSONDecoder().decode(TaskAnchor.self, from: data)
        XCTAssertEqual(decoded, anchor)
    }

    func test_taskFilter_defaultStatuses() {
        let filter = TaskFilter(scope: .project)
        XCTAssertEqual(filter.statuses, [.open])
    }

    func test_writerTask_identifiable() {
        let t = WriterTask(
            id: "task_001",
            kind: .paneCreated,
            anchor: nil,
            body: "revise act 2",
            status: .open,
            priority: 1.0,
            parentTaskId: nil,
            createdAt: Date.distantPast,
            createdBySession: nil)
        XCTAssertEqual(t.id, "task_001")
        XCTAssertEqual(t.kind, .paneCreated)
        XCTAssertEqual(t.status, .open)
    }
}
