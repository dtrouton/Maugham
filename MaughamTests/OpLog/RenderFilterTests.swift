// MaughamTests/OpLog/RenderFilterTests.swift
import XCTest
import MaughamCore
@testable import Maugham

final class RenderFilterTests: XCTestCase {
    func test_stripComments_removesIdMarkers_keepsParagraphs() {
        let stored = "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n"
        let display = RenderFilter.stripComments(stored)
        XCTAssertEqual(display, "First.\n\nSecond.")
    }

    func test_stripComments_keepsArbitraryHtmlCommentsThatAreNotIds() {
        let stored = "<!-- A real author note -->\n\nFirst.\n"
        XCTAssertEqual(RenderFilter.stripComments(stored),
            "<!-- A real author note -->\n\nFirst.")
    }

    func test_restoreComments_reattachesIdsByContentMatch() {
        let stored = "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n"
        let displayEdited = "First, edited.\n\nSecond."
        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].id, "a3f9")
        XCTAssertEqual(parsed[0].text, "First, edited.")
        XCTAssertEqual(parsed[1].id, "b21c")
        XCTAssertEqual(parsed[1].text, "Second.")
    }

    func test_restoreComments_paragraphInserted_mintsNewIdForIt() {
        let stored = "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n"
        let displayEdited = "First.\n\nMiddle inserted.\n\nSecond."
        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].id, "a3f9")
        XCTAssertNotNil(parsed[1].id)
        XCTAssertNotEqual(parsed[1].id, "a3f9")
        XCTAssertNotEqual(parsed[1].id, "b21c")
        XCTAssertEqual(parsed[2].id, "b21c")
    }

    func test_restoreComments_paragraphRemoved_dropsItsId() {
        let stored = "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n"
        let displayEdited = "First."
        let restored = RenderFilter.restoreComments(
            stored: stored, displayEdited: displayEdited)
        let parsed = ParagraphParser.parse(restored)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, "a3f9")
    }
}
