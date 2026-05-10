import XCTest
@testable import Maugham

final class SyntaxHelpSheetParserTests: XCTestCase {
    func testHeadingsAreEmitted() {
        let blocks = SyntaxHelpSheet.parseMarkdownBlocks("# Title\n\nBody.\n")
        XCTAssertEqual(blocks.count, 2)
        if case .heading(let level, let text) = blocks[0] {
            XCTAssertEqual(level, 1)
            XCTAssertEqual(text, "Title")
        } else { XCTFail("expected heading") }
        if case .paragraph = blocks[1] { } else { XCTFail("expected paragraph") }
    }

    func testCodeBlockIsExtracted() {
        let md = """
        Intro.

        ```
        let x = 1
        let y = 2
        ```

        Outro.
        """
        let blocks = SyntaxHelpSheet.parseMarkdownBlocks(md)
        XCTAssertEqual(blocks.count, 3)
        if case .codeBlock(let text) = blocks[1] {
            XCTAssertTrue(text.contains("let x = 1"))
            XCTAssertTrue(text.contains("let y = 2"))
        } else { XCTFail("expected code block") }
    }

    func testParagraphMergesContinuationLines() {
        let md = "First line\nstill same paragraph.\n\nNew paragraph."
        let blocks = SyntaxHelpSheet.parseMarkdownBlocks(md)
        XCTAssertEqual(blocks.count, 2)
    }

    func testBullets() {
        let md = "- one\n- two\n- three"
        let blocks = SyntaxHelpSheet.parseMarkdownBlocks(md)
        XCTAssertEqual(blocks.count, 3)
        for block in blocks {
            if case .bullet = block { } else { XCTFail("expected bullet") }
        }
    }

    func testEmptyInputProducesEmpty() {
        XCTAssertTrue(SyntaxHelpSheet.parseMarkdownBlocks("").isEmpty)
    }
}
