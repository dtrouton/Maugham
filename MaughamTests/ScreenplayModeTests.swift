import XCTest
import MaughamCore
import AppKit
@testable import Maugham

final class ScreenplayModeTests: XCTestCase {
    private let mode = ScreenplayMode()

    func test_tokenize_emptyText_returnsEmpty() {
        XCTAssertEqual(mode.tokenize(""), [])
    }

    func test_smartTypographyTransform_alwaysReturnsNil() {
        XCTAssertNil(mode.smartTypographyTransform(
            currentText: "ah-",
            replacementRange: NSRange(location: 3, length: 0),
            replacement: "-",
            settings: .defaults))
    }

    func test_metrics_countsWordsLikeProse() {
        let metrics = mode.metrics("hello world this is text")
        XCTAssertEqual(metrics.wordCount, 5)
        XCTAssertEqual(metrics.characterCount, 24)
    }

    func test_tokenize_actionLine_producesFountainElementToken() {
        let tokens = mode.tokenize("Larry sits at the bar.")
        XCTAssertEqual(tokens.count, 1)
        if case let .fountainElement(element, isForced) = tokens[0].kind {
            XCTAssertEqual(element, .action)
            XCTAssertEqual(isForced, false)
        } else {
            XCTFail("Expected .fountainElement, got \(tokens[0].kind)")
        }
    }

    func test_tokenize_sceneHeading_producesSceneHeadingToken() {
        let tokens = mode.tokenize("INT. KITCHEN - DAY")
        XCTAssertEqual(tokens.count, 1)
        if case let .fountainElement(element, _) = tokens[0].kind {
            XCTAssertEqual(element, .sceneHeading)
        } else {
            XCTFail("Expected .fountainElement(.sceneHeading)")
        }
    }

    func test_metrics_includesPageCount_forScreenplay() {
        let metrics = mode.metrics("INT. ROOM - DAY\n\nLarry sits.")
        XCTAssertNotNil(metrics.pageCount)
        XCTAssertGreaterThan(metrics.pageCount ?? 0, 0)
    }

    func test_metrics_proseMode_pageCount_isNil() {
        let prose = ProseMode()
        let metrics = prose.metrics("Just a paragraph of prose.")
        XCTAssertNil(metrics.pageCount)
    }

    func test_textColumnWidth_screenplayUsesFixedSixtyChars() {
        // Even if the user sets pageWidthCharacters to 80, screenplay layout
        // stays canonical 60 chars wide.
        var typo: TypographySettings = .screenplayDefaults
        typo.pageWidthCharacters = 80
        let widthAt80 = mode.textColumnWidth(typography: typo)
        typo.pageWidthCharacters = 60
        let widthAt60 = mode.textColumnWidth(typography: typo)
        XCTAssertEqual(widthAt80, widthAt60, accuracy: 0.5)
    }
}
