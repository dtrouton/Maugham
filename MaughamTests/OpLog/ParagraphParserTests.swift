// MaughamTests/OpLog/ParagraphParserTests.swift
import XCTest
import MaughamCore
@testable import Maugham

final class ParagraphParserTests: XCTestCase {
    func test_parse_emptyDocument_returnsEmptyArray() {
        XCTAssertEqual(ParagraphParser.parse(""), [])
    }

    func test_parse_singleParagraph_noId_assignsNilId() {
        let para = ParagraphParser.parse("The morning began with toast.")
        XCTAssertEqual(para.count, 1)
        XCTAssertNil(para[0].id)
        XCTAssertEqual(para[0].text, "The morning began with toast.")
    }

    func test_parse_idCommentAttachesToNextParagraph() {
        let md = """
        <!-- ¶a3f9 -->

        The morning began.

        <!-- ¶b21c -->

        She opened the window.
        """
        let p = ParagraphParser.parse(md)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].id, "a3f9")
        XCTAssertEqual(p[0].text, "The morning began.")
        XCTAssertEqual(p[1].id, "b21c")
        XCTAssertEqual(p[1].text, "She opened the window.")
    }

    func test_parse_blankLineSeparatedParagraphs() {
        let md = """
        First paragraph.

        Second paragraph.

        Third paragraph.
        """
        let p = ParagraphParser.parse(md)
        XCTAssertEqual(p.map(\.text),
            ["First paragraph.", "Second paragraph.", "Third paragraph."])
    }

    func test_parse_multiLineParagraphPreservesInternalNewlines() {
        let md = """
        Line one of a paragraph.
        Line two of the same paragraph.

        Second paragraph.
        """
        let p = ParagraphParser.parse(md)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].text,
            "Line one of a paragraph.\nLine two of the same paragraph.")
    }

    func test_parse_strayCommentWithoutFollowingParagraph_isIgnored() {
        let md = """
        First.

        <!-- ¶a3f9 -->
        """
        let p = ParagraphParser.parse(md)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].text, "First.")
    }

    func test_parse_trailingSpacePreserved() {
        let parsed = ParagraphParser.parse("Hello world ")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].text, "Hello world ",
            "trailing space within a single-line paragraph must survive parse")
    }

    func test_parse_leadingSpacePreserved() {
        let parsed = ParagraphParser.parse("  indented line")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].text, "  indented line",
            "leading space within a single-line paragraph must survive parse")
    }
}
