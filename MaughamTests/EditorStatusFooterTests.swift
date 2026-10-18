import XCTest
import MaughamCore
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

    // MARK: - The goal indicator's Collection arm

    private func piece(path: String?) -> StructureItem {
        StructureItem(id: "p1", title: "Piece", type: .document, path: path,
                      wordTarget: 1200, pageTarget: 30, pieceKind: .loose)
    }

    func test_collectionGoalMeasure_fountainPiece_measuresInPages() {
        let m = GoalIndicatorState.collectionGoalMeasure(for: piece(path: "pieces/scene.fountain"))
        XCTAssertTrue(m.isScreenplay)
        XCTAssertNil(m.wordTarget)
        XCTAssertEqual(m.pageTarget, 30)
    }

    func test_collectionGoalMeasure_markdownPiece_measuresInWords() {
        let m = GoalIndicatorState.collectionGoalMeasure(for: piece(path: "pieces/story.md"))
        XCTAssertFalse(m.isScreenplay)
        XCTAssertEqual(m.wordTarget, 1200)
        XCTAssertNil(m.pageTarget)
    }

    func test_collectionGoalMeasure_noPathOrNoPiece_measuresInWords() {
        let pathless = GoalIndicatorState.collectionGoalMeasure(for: piece(path: nil))
        XCTAssertFalse(pathless.isScreenplay)
        XCTAssertEqual(pathless.wordTarget, 1200)
        let absent = GoalIndicatorState.collectionGoalMeasure(for: nil)
        XCTAssertFalse(absent.isScreenplay)
        XCTAssertNil(absent.wordTarget)
        XCTAssertNil(absent.pageTarget)
    }

    /// Exception 1 (plan 7): a hand-imported upper-case `.FOUNTAIN` piece,
    /// which the op log already parses as Fountain, measures in pages too.
    func test_collectionGoalMeasure_upperCaseFountainPiece_measuresInPages() {
        let m = GoalIndicatorState.collectionGoalMeasure(for: piece(path: "pieces/SCENE.FOUNTAIN"))
        XCTAssertTrue(m.isScreenplay)
        XCTAssertEqual(m.pageTarget, 30)
    }
}
