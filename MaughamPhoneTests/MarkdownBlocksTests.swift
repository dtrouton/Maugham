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
}
