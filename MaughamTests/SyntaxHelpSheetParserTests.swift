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

    // MARK: - Shared-parser mapping (content-audit-found constructs)

    /// Real snippet from `markdown-syntax.md`'s Smart typography section —
    /// the one GFM table the curated content actually uses.
    func testTableIsMappedToTableBlock() {
        let md = """
        | You type | You get |
        |---|---|
        | `--` | `—` (em dash) |
        | `...` | `…` (ellipsis) |
        """
        let blocks = SyntaxHelpSheet.parseMarkdownBlocks(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .table(let header, let rows) = blocks[0] else {
            XCTFail("expected table"); return
        }
        XCTAssertEqual(header, ["You type", "You get"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["`--`", "`—` (em dash)"])
    }

    /// Real snippet from `fountain-syntax.md`'s Notes section, post-fix —
    /// heading + bullet list + prose + fence, none of the curated content's
    /// real constructs. Pins that a bullet list still emits one `.bullet`
    /// per item, unaffected by the table/heading/fence changes.
    func testBulletListFromRealFountainDocSnippet() {
        let md = """
        - **Block notes** — a full standalone line, or spanning multiple lines
        - **Inline notes** — embedded within an action or other line
        """
        let blocks = SyntaxHelpSheet.parseMarkdownBlocks(md)
        XCTAssertEqual(blocks.count, 2)
        for block in blocks {
            if case .bullet = block { } else { XCTFail("expected bullet") }
        }
    }

    /// The curated content has no ordered list, blockquote, thematic break,
    /// or solo image — but the adapter must degrade those block kinds to
    /// visible text rather than drop them silently.
    func testUnmappedBlockKindsDegradeToVisibleTextRatherThanDrop() {
        XCTAssertFalse(SyntaxHelpSheet.parseMarkdownBlocks("1. First\n2. Second").isEmpty)
        XCTAssertFalse(SyntaxHelpSheet.parseMarkdownBlocks("> Quoted line").isEmpty)
        XCTAssertFalse(SyntaxHelpSheet.parseMarkdownBlocks("---\n\nAfter the break.").count == 0)
        XCTAssertFalse(SyntaxHelpSheet.parseMarkdownBlocks("![alt](./local.png)").isEmpty)
    }
}
