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
}
