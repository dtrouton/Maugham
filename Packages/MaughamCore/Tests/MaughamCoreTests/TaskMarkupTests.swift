import XCTest
@testable import MaughamCore

/// `TaskMarkup.lineContainsTaskMarker` is the single source of truth for
/// "does this text contain inline-task markup", consumed by the OpLog
/// cache-invalidation gate, the anchor-alignment move-detector, and the
/// TasksPane flip helper. Uppercase `- [X]` is the case that had drifted
/// (see A1-Medium in docs/superpowers/notes/2026-07-11-maintainability-review.md §3.1).
final class TaskMarkupTests: XCTestCase {
    func test_lowercaseCheckedBox_isTaskMarker() {
        XCTAssertTrue(TaskMarkup.lineContainsTaskMarker("- [x] done"))
    }

    func test_uppercaseCheckedBox_isTaskMarker() {
        XCTAssertTrue(TaskMarkup.lineContainsTaskMarker("- [X] done"))
    }

    func test_openBox_isTaskMarker() {
        XCTAssertTrue(TaskMarkup.lineContainsTaskMarker("- [ ] open"))
    }

    func test_fountainTodo_isTaskMarker() {
        XCTAssertTrue(TaskMarkup.lineContainsTaskMarker("[[todo: revise scene]]"))
    }

    func test_fountainDone_isTaskMarker() {
        XCTAssertTrue(TaskMarkup.lineContainsTaskMarker("[[done: revise scene]]"))
    }

    func test_markerMidLine_isDetected() {
        XCTAssertTrue(TaskMarkup.lineContainsTaskMarker("Some prose then - [x] a task"))
    }

    func test_plainProse_isNotTaskMarker() {
        XCTAssertFalse(TaskMarkup.lineContainsTaskMarker("Just a normal sentence."))
    }

    func test_emptyString_isNotTaskMarker() {
        XCTAssertFalse(TaskMarkup.lineContainsTaskMarker(""))
    }

    func test_bareBrackets_areNotTaskMarker() {
        XCTAssertFalse(TaskMarkup.lineContainsTaskMarker("[X] not markdown checkbox syntax"))
    }
}
