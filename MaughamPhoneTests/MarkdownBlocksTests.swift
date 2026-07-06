import XCTest
@testable import MaughamPhone

final class MarkdownBlocksTests: XCTestCase {
    func test_splitsHeadingAndParagraphs() {
        let md = """
        # Chapter 1

        The sun was setting over the harbor.

        She watched the boats return, one by one. *The light* caught the **water**.
        """
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .heading(level: 1, text: "Chapter 1"),
            .paragraph("The sun was setting over the harbor."),
            .paragraph("She watched the boats return, one by one. *The light* caught the **water**."),
        ])
    }

    func test_headingWithoutSurroundingBlankIsItsOwnBlock() {
        // A heading line glued to following prose must still split out, never
        // concatenate (the "Chapter 1The sun…" bug).
        let md = "# Title\nBody starts here."
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .heading(level: 1, text: "Title"),
            .paragraph("Body starts here."),
        ])
    }

    func test_headingLevelsAndMultilineParagraph() {
        let md = "## Sub\n\nLine one\nline two\n\n### Deep"
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .heading(level: 2, text: "Sub"),
            .paragraph("Line one\nline two"),
            .heading(level: 3, text: "Deep"),
        ])
    }

    func test_noAnchorPlainParagraph() {
        XCTAssertEqual(MarkdownBlocks.parse("Just prose."), [.paragraph("Just prose.")])
    }

    func test_fence_becomesCode_noEmphasisInterpretation() {
        let md = "```swift\nlet *x* = 1\n```"
        XCTAssertEqual(MarkdownBlocks.parse(md), [.code("let *x* = 1")])
    }

    func test_unorderedList() {
        XCTAssertEqual(MarkdownBlocks.parse("- a\n- b"),
                       [.list(ordered: false, items: ["a", "b"])])
    }

    func test_orderedList() {
        XCTAssertEqual(MarkdownBlocks.parse("1. x"),
                       [.list(ordered: true, items: ["x"])])
    }

    func test_pipeTable() {
        let md = "| a | b |\n|---|---|\n| 1 | 2 |"
        XCTAssertEqual(MarkdownBlocks.parse(md),
                       [.table(header: ["a", "b"], rows: [["1", "2"]])])
    }

    func test_blockquote() {
        XCTAssertEqual(MarkdownBlocks.parse("> q"), [.quote([.paragraph("q")])])
    }

    func test_hashWithoutSpace_staysParagraph() {
        XCTAssertEqual(MarkdownBlocks.parse("#foo"), [.paragraph("#foo")])
    }

    func test_thematicBreak_becomesDivider() {
        XCTAssertEqual(MarkdownBlocks.parse("***"), [.divider])
    }
}
