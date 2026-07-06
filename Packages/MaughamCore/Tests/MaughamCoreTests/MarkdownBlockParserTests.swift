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
}
