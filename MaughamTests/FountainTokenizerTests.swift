import XCTest
@testable import Maugham

final class FountainTokenizerTests: XCTestCase {
    private let parser = FountainTokenizer()

    // MARK: - Foundations

    func test_emptyText_returnsEmptyScript() {
        XCTAssertEqual(parser.parse(""), .empty)
    }

    func test_singleActionLine_classifiesAsAction() {
        let script = parser.parse("Larry sits at the bar.")
        XCTAssertEqual(script.lines.count, 1)
        XCTAssertEqual(script.lines[0].element, .action)
        XCTAssertEqual(script.lines[0].content, "Larry sits at the bar.")
        XCTAssertEqual(script.lines[0].isForced, false)
        XCTAssertEqual(script.lines[0].sourceCase, .mixed)
    }

    func test_blankLineBetweenActions_producesBlankActionRow() {
        let script = parser.parse("First.\n\nSecond.")
        XCTAssertEqual(script.lines.count, 3)
        XCTAssertEqual(script.lines[0].element, .action)
        XCTAssertEqual(script.lines[1].element, .action)
        XCTAssertEqual(script.lines[1].content, "")
        XCTAssertEqual(script.lines[1].sourceCase, .neutral)
        XCTAssertEqual(script.lines[2].element, .action)
    }

    // MARK: - Scene heading

    func test_sceneHeadingINT_afterBlank_classifiesAsSceneHeading() {
        let script = parser.parse("INT. KITCHEN - DAY")
        XCTAssertEqual(script.lines.count, 1)
        XCTAssertEqual(script.lines[0].element, .sceneHeading)
        XCTAssertEqual(script.lines[0].content, "INT. KITCHEN - DAY")
        XCTAssertEqual(script.lines[0].isForced, false)
    }

    func test_sceneHeadingEXT_afterBlank_classifiesAsSceneHeading() {
        let script = parser.parse("Action one.\n\nEXT. ROOFTOP - NIGHT")
        XCTAssertEqual(script.lines.last?.element, .sceneHeading)
    }

    func test_sceneHeadingEST_afterBlank_classifiesAsSceneHeading() {
        let script = parser.parse("EST. MEADOW - DAWN")
        XCTAssertEqual(script.lines[0].element, .sceneHeading)
    }

    func test_sceneHeadingIE_combined_classifiesAsSceneHeading() {
        let script = parser.parse("I/E. CAR - CONTINUOUS")
        XCTAssertEqual(script.lines[0].element, .sceneHeading)
    }

    func test_sceneHeadingForcedDot_classifiesAsSceneHeading() {
        let script = parser.parse(".barbershop")
        XCTAssertEqual(script.lines[0].element, .sceneHeading)
        XCTAssertEqual(script.lines[0].content, "barbershop")
        XCTAssertEqual(script.lines[0].isForced, true)
        XCTAssertEqual(script.lines[0].sourceCase, .lower)
    }

    func test_intMidParagraph_isNotSceneHeading() {
        // Without a blank line above, "INT." mid-text is just action.
        let script = parser.parse("He yelled.\nINT. ROOM - DAY")
        XCTAssertEqual(script.lines[1].element, .action)
    }

    func test_doubleDotPrefix_isAction_notSceneHeading() {
        // Two dots is NOT a forced scene heading per Fountain spec.
        let script = parser.parse("..ellipsis-ish")
        XCTAssertEqual(script.lines[0].element, .action)
    }
}
