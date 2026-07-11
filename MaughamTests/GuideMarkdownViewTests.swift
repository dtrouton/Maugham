import XCTest
@testable import Maugham

final class GuideMarkdownViewTests: XCTestCase {
    /// Blank lines separate the paragraph from the list and the list from
    /// the fence: the shared `MarkdownBlockParser`'s paragraph loop only
    /// breaks accumulation on a blank line / heading / thematic break /
    /// quote, so (unlike the old per-line local parser) a bullet or fence
    /// glued directly onto a preceding text line with no blank line would be
    /// swallowed into that paragraph — the same class of bug fixed in
    /// `docs/guide/claude-desktop.md`'s "Read:"/"Write:" sections.
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

    /// Grammar upgrade (audit section E row 6): a blockquote used to render as
    /// unstyled paragraph text; it now gets its own `.quote` case (leading
    /// accent bar in the renderer), matching the phone reader's treatment.
    func test_blockquoteBecomesQuoteBlock() {
        let md = """
        > Quoted line one
        > quoted line two.
        """
        let blocks = GuideMarkdownView.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .quote(let q) = blocks[0] else { return XCTFail("expected quote, got \(blocks)") }
        XCTAssertEqual(q, "Quoted line one quoted line two.")
    }

    func test_orderedListItemsDoNotReflowIntoOneParagraph() {
        let md = "1. Install\n2. Open"
        let blocks = GuideMarkdownView.parse(md)
        XCTAssertEqual(blocks.count, 2, "each ordered line is its own block, not reflowed")
        guard case .orderedItem(let n1, let t1) = blocks[0] else { return XCTFail("expected orderedItem") }
        XCTAssertEqual(n1, "1"); XCTAssertEqual(t1, "Install")
        guard case .orderedItem(let n2, let t2) = blocks[1] else { return XCTFail("expected orderedItem") }
        XCTAssertEqual(n2, "2"); XCTAssertEqual(t2, "Open")
    }

    /// The shared `MarkdownBlockParser` recognizes a multi-digit paren marker
    /// as an ordered item but does not retain its source digits (`.list`
    /// items carry no number). The adapter regenerates numbers sequentially
    /// from list position, so a source marker that starts mid-sequence (as
    /// this one deliberately does, to probe that case) no longer round-trips
    /// — this is a known, reviewer-flagged fidelity loss (see task-7 report),
    /// not a bug in this test.
    func test_orderedListAcceptsParenMarkerAndMultiDigit() {
        let md = "10) Tenth step"
        let blocks = GuideMarkdownView.parse(md)
        guard case .orderedItem(let n, let t) = blocks[0] else { return XCTFail("expected orderedItem") }
        XCTAssertEqual(n, "1", "sequential renumbering, not source-number preservation — see task-7 report")
        XCTAssertEqual(t, "Tenth step")
    }

    func test_literalPipeWithoutDelimiterRowStaysParagraph() {
        let md = "Cost is $5 | $10 depending on plan."
        let blocks = GuideMarkdownView.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let p) = blocks[0] else { return XCTFail("expected paragraph, got \(blocks)") }
        XCTAssertEqual(p, "Cost is $5 | $10 depending on plan.")
    }

    func test_parsesPipeTable() {
        let md = """
        | Key | Action |
        |---|---|
        | `⌘N` | New project |
        | `⌘O` | Open project |
        """
        let blocks = GuideMarkdownView.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case .table(let header, let rows) = blocks[0] else { return XCTFail("expected table, got \(blocks)") }
        XCTAssertEqual(header, ["Key", "Action"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["`⌘N`", "New project"])
        XCTAssertEqual(rows[1], ["`⌘O`", "Open project"])
    }

    /// Parses the actual shipped `docs/guide/reference.md` — the corpus this
    /// bug was filed against (audit A3). Reads it straight from the repo the
    /// way `GuideDocsDriftTests` does, not a synthetic fixture.
    func test_parsesRealReferenceDocKeyboardShortcutTable() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
        let md = try String(contentsOf: repoRoot.appendingPathComponent("docs/guide/reference.md"), encoding: .utf8)
        let blocks = GuideMarkdownView.parse(md)

        let tables = blocks.compactMap { block -> ([String], [[String]])? in
            if case .table(let header, let rows) = block { return (header, rows) }
            return nil
        }
        XCTAssertEqual(tables.count, 1, "expected exactly one table in reference.md")
        let (header, rows) = try XCTUnwrap(tables.first)
        XCTAssertEqual(header, ["Shortcut", "Action"], "reference.md's shortcut table now has real header text (audit C-item follow-up)")
        XCTAssertEqual(rows.count, 22, "one row per documented shortcut")
        XCTAssertEqual(rows.first, ["`⌘N`", "New project"])
        XCTAssertTrue(rows.contains(["`⌘/`", "Syntax + keyboard reference"]))
    }
}
