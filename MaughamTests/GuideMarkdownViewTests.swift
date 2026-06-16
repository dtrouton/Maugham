import XCTest
@testable import Maugham

final class GuideMarkdownViewTests: XCTestCase {
    func test_parsesHeadingsParagraphsBulletsAndCode() {
        let md = """
        # Title
        Intro line.
        - first
        - second
        ```
        let x = 1
        ```
        """
        let blocks = GuideMarkdownView.parse(md)
        guard case .heading(let level, let text) = blocks[0] else { return XCTFail("expected heading") }
        XCTAssertEqual(level, 1); XCTAssertEqual(text, "Title")
        guard case .paragraph = blocks[1] else { return XCTFail("expected paragraph") }
        guard case .bullet = blocks[2] else { return XCTFail("expected bullet") }
        guard case .bullet = blocks[3] else { return XCTFail("expected bullet") }
        guard case .code(let code) = blocks[4] else { return XCTFail("expected code") }
        XCTAssertEqual(code, "let x = 1")
    }

    func test_reflowsHardWrappedParagraphLines() {
        let md = """
        First line of a paragraph
        wrapped onto a second line.

        Second paragraph.
        """
        let blocks = GuideMarkdownView.parse(md)
        XCTAssertEqual(blocks.count, 2, "two blank-line-separated paragraphs")
        guard case .paragraph(let p1) = blocks[0] else { return XCTFail("expected paragraph") }
        XCTAssertEqual(p1, "First line of a paragraph wrapped onto a second line.",
                       "hard-wrapped lines should reflow into one paragraph joined by spaces")
        guard case .paragraph(let p2) = blocks[1] else { return XCTFail("expected paragraph") }
        XCTAssertEqual(p2, "Second paragraph.")
    }

    func test_blockquoteReflowsWithoutMarker() {
        let md = """
        > Quoted line one
        > quoted line two.
        """
        let blocks = GuideMarkdownView.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let p) = blocks[0] else { return XCTFail("expected paragraph") }
        XCTAssertEqual(p, "Quoted line one quoted line two.")
    }
}
