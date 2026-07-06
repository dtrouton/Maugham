import XCTest
@testable import MaughamCore

final class MarkdownBlockParserTests: XCTestCase {
    func test_paragraph_keepsRawLines() {
        XCTAssertEqual(MarkdownBlockParser.parse("line one\nline two\n\npara two"),
            [.paragraph(lines: ["line one", "line two"]),
             .paragraph(lines: ["para two"])])
    }
    func test_heading_requiresSpace() {
        XCTAssertEqual(MarkdownBlockParser.parse("# Title"),
                       [.heading(level: 1, text: "Title")])
        XCTAssertEqual(MarkdownBlockParser.parse("#notaheading"),
                       [.paragraph(lines: ["#notaheading"])])
    }
    func test_heading_capsAtSix() {
        XCTAssertEqual(MarkdownBlockParser.parse("###### six"),
                       [.heading(level: 6, text: "six")])
        XCTAssertEqual(MarkdownBlockParser.parse("####### seven"),
                       [.paragraph(lines: ["####### seven"])])
    }
    func test_headingSplitsParagraphWithoutBlank() {
        XCTAssertEqual(MarkdownBlockParser.parse("prose\n# H\nmore"),
            [.paragraph(lines: ["prose"]), .heading(level: 1, text: "H"),
             .paragraph(lines: ["more"])])
    }
    func test_thematicBreak_forms() {
        XCTAssertEqual(MarkdownBlockParser.parse("---"), [.thematicBreak])
        XCTAssertEqual(MarkdownBlockParser.parse("----"), [.thematicBreak])
        XCTAssertEqual(MarkdownBlockParser.parse("***"), [.thematicBreak])
        XCTAssertEqual(MarkdownBlockParser.parse("###"), [.thematicBreak])
        XCTAssertEqual(MarkdownBlockParser.parse("****"),
                       [.paragraph(lines: ["****"])])
        XCTAssertEqual(MarkdownBlockParser.parse("####"),
                       [.paragraph(lines: ["####"])])
    }
    func test_breakBeforeHeadingPrecedence() {
        // bare ### is an ornament, not an H3 (publish + editor rule)
        XCTAssertEqual(MarkdownBlockParser.parse("text\n\n###\n\ntext2"),
            [.paragraph(lines: ["text"]), .thematicBreak,
             .paragraph(lines: ["text2"])])
    }

    func test_unorderedList_flat() {
        XCTAssertEqual(MarkdownBlockParser.parse("- one\n- two"),
            [.list(ordered: false, items: [["one"], ["two"]])])
    }
    func test_orderedList_bothDelimiters_firstMarkerWins() {
        XCTAssertEqual(MarkdownBlockParser.parse("1. a\n2) b"),
            [.list(ordered: true, items: [["a"], ["b"]])])
        XCTAssertEqual(MarkdownBlockParser.parse("- a\n2. b"),
            [.list(ordered: false, items: [["a"], ["b"]])])
    }
    func test_list_indentedContinuation_staysInItem() {
        XCTAssertEqual(MarkdownBlockParser.parse("- item\n  continued"),
            [.list(ordered: false, items: [["item", "  continued"]])])
    }
    func test_list_unindentedLine_endsList_reprocessed() {
        XCTAssertEqual(MarkdownBlockParser.parse("- item\n***"),
            [.list(ordered: false, items: [["item"]]), .thematicBreak])
        XCTAssertEqual(MarkdownBlockParser.parse("- item\n# H"),
            [.list(ordered: false, items: [["item"]]), .heading(level: 1, text: "H")])
    }
    func test_starListMarker_vsThematicBreak() {
        XCTAssertEqual(MarkdownBlockParser.parse("* item"),
            [.list(ordered: false, items: [["item"]])])
        XCTAssertEqual(MarkdownBlockParser.parse("***"), [.thematicBreak])
    }
    func test_fence_verbatim_infoString_unclosed() {
        XCTAssertEqual(MarkdownBlockParser.parse("```swift\nlet *x* = 1\n```"),
            [.fence(lines: ["let *x* = 1"], info: "swift")])
        XCTAssertEqual(MarkdownBlockParser.parse("```\n  raw indent kept"),
            [.fence(lines: ["  raw indent kept"], info: nil)])
    }
}
