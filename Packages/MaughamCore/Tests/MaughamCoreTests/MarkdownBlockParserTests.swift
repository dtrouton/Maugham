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

    func test_blockquote_recursive_optionalSpace() {
        XCTAssertEqual(MarkdownBlockParser.parse("> quoted *em*\n>second"),
            [.blockquote(blocks: [.paragraph(lines: ["quoted *em*", "second"])])])
    }
    func test_blockquote_endsAtPlainLine() {
        XCTAssertEqual(MarkdownBlockParser.parse("> q\nplain"),
            [.blockquote(blocks: [.paragraph(lines: ["q"])]),
             .paragraph(lines: ["plain"])])
    }
    func test_table_gated_onDelimiterRow() {
        let src = "| a | b |\n|---|:--:|\n| 1 | 2 |"
        let blocks = MarkdownBlockParser.parse(src)
        guard case .table(let h, let r, let raw) = blocks.first else { return XCTFail() }
        XCTAssertEqual(h, ["a", "b"]); XCTAssertEqual(r, [["1", "2"]])
        XCTAssertEqual(raw, ["| a | b |", "|---|:--:|", "| 1 | 2 |"])
    }
    func test_pipeWithoutDelimiter_staysParagraph() {
        XCTAssertEqual(MarkdownBlockParser.parse("costs 3 | 4 either way"),
            [.paragraph(lines: ["costs 3 | 4 either way"])])
    }
    func test_escapedPipe_inCell() {
        let blocks = MarkdownBlockParser.parse("| a \\| b | c |\n|---|---|")
        guard case .table(let h, _, _) = blocks.first else { return XCTFail() }
        XCTAssertEqual(h, ["a | b", "c"])
    }
    func test_soloImage_relativeOnly() {
        XCTAssertEqual(MarkdownBlockParser.parse("![cover](./art/cover.png)"),
            [.soloImage(altText: "cover", path: "./art/cover.png",
                        rawLine: "![cover](./art/cover.png)")])
        XCTAssertEqual(MarkdownBlockParser.parse("![x](https://a/b.png)"),
            [.paragraph(lines: ["![x](https://a/b.png)"])])
    }
    // Pins the public entry point consumers use to detect a solo-image line
    // that ISN'T at a block boundary (e.g. `ResearchNotePreviewPane` re-scanning
    // a `.paragraph` block's embedded lines) — same regex `parse` uses above,
    // exposed directly so there's exactly one copy of the rule.
    func test_matchSoloImage_relativeCapturesAltAndPath_remoteIsNil() {
        let match = MarkdownBlockParser.matchSoloImage("![cover](./art/cover.png)")
        XCTAssertEqual(match?.altText, "cover")
        XCTAssertEqual(match?.path, "./art/cover.png")
        XCTAssertNil(MarkdownBlockParser.matchSoloImage("![x](https://a/b.png)"))
    }
    // Pins publish parity: table/image require a preceding blank line to
    // start a new block — unlike quote, they do NOT interrupt paragraph
    // accumulation. `text` directly followed by a table with no blank line
    // stays ONE paragraph, matching publish's existing (pre-Task-3) behavior.
    func test_tableWithoutBlankLine_staysInParagraph() {
        XCTAssertEqual(MarkdownBlockParser.parse("text\n| a | b |\n|---|---|"),
            [.paragraph(lines: ["text", "| a | b |", "|---|---|"])])
    }

    // MARK: - line ranges (P3 Task 1: the anchor seam)

    /// Every block kind, so the range assertions below are not pinned on prose
    /// alone. Kept in one place so a new block kind joins both tests at once.
    private static let rangeCorpus: [String] = [
        "line one\nline two\n\npara two",
        "# Title\n\nbody text\n\n## Sub\nmore",
        "---\n\nafter the break",
        "> quoted one\n> quoted two\n\nplain",
        "```swift\nlet x = 1\n\nlet y = 2\n```\n\ntrailing",
        "- one\n- two\n  continued\n\n1. first\n2. second",
        "| a | b |\n|---|---|\n| 1 | 2 |\n\nafter",
        "![cover](./art/cover.png)\n\nprose after",
        "\n\n   \nleading blanks then text\n\n\n",
        "no trailing newline at all",
        "```\nunterminated fence\nstill inside",
    ]

    /// `parse` must remain byte-equivalent to the new range-carrying entry
    /// point's blocks — it IS that entry point's `.map(\.block)`, and this is
    /// the pin that says so over every corpus fixture.
    func test_parseIsExactlyTheBlocksOfParseWithLineRanges() {
        for src in Self.rangeCorpus {
            XCTAssertEqual(
                MarkdownBlockParser.parse(src),
                MarkdownBlockParser.parseWithLineRanges(src).map(\.block),
                "parse must stay the .block projection of parseWithLineRanges for \(src.debugDescription)")
        }
    }

    /// The ranges tile the input: each is non-empty, they are strictly ordered
    /// and non-overlapping, they stay in bounds, and every line NOT covered by
    /// one is whitespace-only (the parser skips blank lines between blocks and
    /// nothing else). Without this the publish anchor map could place a ¶id on
    /// the wrong node and no other test would notice.
    func test_lineRangesTileEveryFixture() {
        for src in Self.rangeCorpus {
            let lineCount = src.components(separatedBy: "\n").count
            let ranges = MarkdownBlockParser.parseWithLineRanges(src).map(\.lines)
            var covered = Set<Int>()
            var previousEnd = 0
            for range in ranges {
                XCTAssertFalse(range.isEmpty,
                    "empty block range in \(src.debugDescription)")
                XCTAssertGreaterThanOrEqual(range.lowerBound, previousEnd,
                    "overlapping/unordered ranges \(ranges) in \(src.debugDescription)")
                XCTAssertLessThanOrEqual(range.upperBound, lineCount,
                    "range \(range) out of bounds (\(lineCount) lines) in \(src.debugDescription)")
                previousEnd = range.upperBound
                covered.formUnion(range)
            }
            let lines = src.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where !covered.contains(i) {
                XCTAssertTrue(
                    line.trimmingCharacters(in: .whitespaces).isEmpty,
                    "line \(i) (\(line.debugDescription)) is uncovered but not blank, in \(src.debugDescription)")
            }
        }
    }

    /// The concrete arithmetic the publish builder depends on, spelled out for
    /// one fixture so a regression names the block rather than the corpus.
    func test_lineRanges_areTheBlocksOwnSourceLines() {
        let ranges = MarkdownBlockParser.parseWithLineRanges(
            "# H\n\nprose one\nprose two\n\n```\nfenced\n```\n\n> quote")
            .map(\.lines)
        XCTAssertEqual(ranges, [0..<1, 2..<4, 5..<8, 9..<10])
    }
}
