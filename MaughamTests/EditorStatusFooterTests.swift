import XCTest
@testable import Maugham

final class EditorStatusFooterTests: XCTestCase {

    func test_rightLabel_screenplay_withTarget() {
        let state = GoalIndicatorState(
            pageCount: 0.3, pageTarget: 90, isScreenplay: true)
        XCTAssertEqual(
            EditorStatusFooter.rightLabel(for: state),
            "0.3 / 90 pages (0%)")
    }

    func test_rightLabel_screenplay_noTarget() {
        let state = GoalIndicatorState(
            pageCount: 0.3, isScreenplay: true)
        XCTAssertEqual(
            EditorStatusFooter.rightLabel(for: state),
            "0.3 pages")
    }

    func test_rightLabel_prose_withTarget() {
        let state = GoalIndicatorState(
            docWordCount: 4_320, docWordTarget: 80_000,
            wordsToday: 520)
        let label = EditorStatusFooter.rightLabel(for: state)
        // Trust GoalIndicatorView's existing format; assert key parts:
        XCTAssertTrue(label.contains("4,320"))
        XCTAssertTrue(label.contains("80,000"))
        XCTAssertTrue(label.contains("today: 520"))
    }

    func test_leftLabel_includesSessionWords() {
        let label = EditorStatusFooter.leftLabel(
            sessionWords: 520, sessionStart: nil)
        XCTAssertTrue(label.contains("520"))
        XCTAssertTrue(label.contains("words"))
    }

    func test_centerLabel_screenplay_withElement() {
        XCTAssertEqual(
            EditorStatusFooter.centerLabel(
                paragraphId: "pdyx", elementLabel: "CHAR"),
            "¶ pdyx · CHAR")
    }

    func test_centerLabel_prose_noElement() {
        XCTAssertEqual(
            EditorStatusFooter.centerLabel(
                paragraphId: "pdyx", elementLabel: nil),
            "¶ pdyx")
    }

    func test_centerLabel_noParagraph() {
        XCTAssertEqual(
            EditorStatusFooter.centerLabel(
                paragraphId: nil, elementLabel: nil),
            "")
    }
}
