import XCTest
@testable import Maugham

/// The decision behind a task row's double-click / Return (the Tasks list's
/// primary action), tested windowless (tripwire 33).
@MainActor
final class TasksPaneJumpTargetTests: XCTestCase {

    private func task(_ id: String, _ kind: TaskKind, paragraph: String?) -> WriterTask {
        WriterTask(
            id: id, kind: kind,
            anchor: TaskAnchor(docId: "d_doc", paragraphId: paragraph),
            body: id, status: .open, priority: 0, parentTaskId: nil,
            createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil)
    }

    private lazy var pool: [WriterTask] = [
        task("t-md", .inlineMarkdown, paragraph: "a2b3"),
        task("t-fn", .fountainBoneyard, paragraph: "c4d5"),
        task("t-pane", .paneCreated, paragraph: nil),
    ]

    func test_aSingleAnchoredMarkdownTask_isTheTarget() {
        XCTAssertEqual(TasksPane.jumpTarget(for: ["t-md"], in: pool)?.id, "t-md")
    }

    func test_aSingleFountainBoneyardTask_isTheTarget() {
        XCTAssertEqual(TasksPane.jumpTarget(for: ["t-fn"], in: pool)?.id, "t-fn")
    }

    func test_aPaneCreatedTask_hasNoTarget() {
        XCTAssertNil(TasksPane.jumpTarget(for: ["t-pane"], in: pool))
    }

    func test_aPaneCreatedTaskCarryingAParagraph_stillHasNoTarget() {
        let promoted = task("t-promoted", .paneCreated, paragraph: "e6f7")
        XCTAssertNil(TasksPane.jumpTarget(for: ["t-promoted"], in: pool + [promoted]),
            "the row's jump matches its badge: a pane-created task's badge is not a button")
    }

    func test_anEmptySelection_hasNoTarget() {
        XCTAssertNil(TasksPane.jumpTarget(for: [], in: pool))
    }

    func test_twoSelectedIds_haveNoTarget() {
        XCTAssertNil(TasksPane.jumpTarget(for: ["t-md", "t-fn"], in: pool))
    }

    func test_anUnknownId_hasNoTarget() {
        XCTAssertNil(TasksPane.jumpTarget(for: ["t-gone"], in: pool))
    }
}
