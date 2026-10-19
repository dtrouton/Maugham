import XCTest
@testable import MaughamCore

/// The report block layer over `MarkdownBlockParser`: labels, attribute
/// blocks, captioned tables, figures and footnote definitions.
final class ManuscriptBlocksTests: XCTestCase {

    private func blocks(_ text: String) -> [ManuscriptBlock] {
        ManuscriptBlocks.parse(text).map(\.block)
    }

    private func label(_ kind: ManuscriptLabel.Kind, _ name: String) -> ManuscriptLabel {
        ManuscriptLabel(reference: "\(kind.rawValue):\(name)")!
    }

    // MARK: - ManuscriptLabel

    func test_label_parsesAReferenceAndPrintsItBack() {
        let l = ManuscriptLabel(reference: "fig:revenue")
        XCTAssertEqual(l?.kind, .fig)
        XCTAssertEqual(l?.name, "revenue")
        XCTAssertEqual(l?.reference, "fig:revenue")
        XCTAssertEqual(ManuscriptLabel(reference: "tbl:q3-2026_a")?.reference, "tbl:q3-2026_a")
        XCTAssertEqual(ManuscriptLabel(reference: "sec:9")?.kind, .sec)
    }

    func test_label_kindsAreExactlyFigTblSec() {
        XCTAssertEqual(ManuscriptLabel.Kind.allCases.map(\.rawValue), ["fig", "tbl", "sec"])
    }

    func test_label_refusesInvalidReferences() {
        for bad in ["fig:", ":x", "eq:x", "fig", "fig:-x", "fig:_x", "fig:a b", "fig:a:b",
                    "Fig:x", "fig:a.b", "", "fig:é"] {
            XCTAssertNil(ManuscriptLabel(reference: bad), bad)
        }
    }

    // MARK: - ManuscriptAttributes.split

    func test_split_removesATrailingBlockAndTheWhitespaceBeforeIt() {
        let r = ManuscriptAttributes.split("Results  {#sec:results}")
        XCTAssertEqual(r.text, "Results")
        XCTAssertEqual(r.label, label(.sec, "results"))
    }

    func test_split_withNoSpaceBeforeTheBlock() {
        let r = ManuscriptAttributes.split("![a](x.png){#fig:x}")
        XCTAssertEqual(r.text, "![a](x.png)")
        XCTAssertEqual(r.label, label(.fig, "x"))
    }

    func test_split_leavesInvalidOrMidLineBlocksUntouched() {
        for line in ["Results {#sec:}", "Results {#eq:x}", "Results {#sec:a b}",
                     "see {#fig:x} here", "Results {#sec:x} ", "Results", "{#sec:x"] {
            let r = ManuscriptAttributes.split(line)
            XCTAssertEqual(r.text, line, line)
            XCTAssertNil(r.label, line)
        }
    }

    // MARK: - Headings

    func test_heading_withASectionLabel() {
        XCTAssertEqual(blocks("## Results {#sec:results}"),
                       [.heading(level: 2, text: "Results", label: label(.sec, "results"))])
    }

    func test_heading_withAnEmptyLabelName_isUntouched() {
        XCTAssertEqual(blocks("## Results {#sec:}"),
                       [.heading(level: 2, text: "Results {#sec:}", label: nil)])
    }

    func test_heading_withALabelMidLine_isUntouched() {
        XCTAssertEqual(blocks("# A {#fig:x} heading"),
                       [.heading(level: 1, text: "A {#fig:x} heading", label: nil)])
    }

    func test_heading_withAWrongKindLabel_keepsIt() {
        XCTAssertEqual(blocks("# Revenue {#fig:x}"),
                       [.heading(level: 1, text: "Revenue", label: label(.fig, "x"))])
    }

    // MARK: - Tables

    private let tableSource = "| Quarter | Revenue |\n|---|---|\n| Q3 | 12 |"

    func test_table_withACaptionAndLabel() {
        let parsed = ManuscriptBlocks.parse(tableSource + "\nTable: Q3 revenue {#tbl:q3}")
        XCTAssertEqual(parsed.map(\.block),
                       [.table(header: ["Quarter", "Revenue"], rows: [["Q3", "12"]],
                               caption: "Q3 revenue", label: label(.tbl, "q3"))])
        XCTAssertEqual(parsed.map(\.lines), [0..<4])
    }

    func test_table_withACaptionAndNoLabel() {
        XCTAssertEqual(blocks(tableSource + "\nTable: Q3 revenue"),
                       [.table(header: ["Quarter", "Revenue"], rows: [["Q3", "12"]],
                               caption: "Q3 revenue", label: nil)])
    }

    func test_table_withoutACaption() {
        let parsed = ManuscriptBlocks.parse(tableSource)
        XCTAssertEqual(parsed.map(\.block),
                       [.table(header: ["Quarter", "Revenue"], rows: [["Q3", "12"]],
                               caption: nil, label: nil)])
        XCTAssertEqual(parsed.map(\.lines), [0..<3])
    }

    func test_table_captionAfterABlankLine_isNotAttached() {
        let parsed = ManuscriptBlocks.parse(tableSource + "\n\nTable: Q3 revenue {#tbl:q3}")
        XCTAssertEqual(parsed.map(\.block), [
            .table(header: ["Quarter", "Revenue"], rows: [["Q3", "12"]], caption: nil, label: nil),
            .other(.paragraph(lines: ["Table: Q3 revenue {#tbl:q3}"])),
        ])
        XCTAssertEqual(parsed.map(\.lines), [0..<3, 4..<5])
    }

    /// A caption paragraph that runs onto a second line is not a caption:
    /// consuming it would hide the second line.
    func test_table_multiLineCaptionParagraph_isNotAttached() {
        XCTAssertEqual(blocks(tableSource + "\nTable: Q3 revenue\nmore prose"), [
            .table(header: ["Quarter", "Revenue"], rows: [["Q3", "12"]], caption: nil, label: nil),
            .other(.paragraph(lines: ["Table: Q3 revenue", "more prose"])),
        ])
    }

    func test_table_withAWrongKindLabel_keepsIt() {
        XCTAssertEqual(blocks(tableSource + "\nTable: Q3 {#fig:q3}"),
                       [.table(header: ["Quarter", "Revenue"], rows: [["Q3", "12"]],
                               caption: "Q3", label: label(.fig, "q3"))])
    }

    /// The parser keeps a `|`-bearing caption as a row; the layer takes it
    /// back from the raw line, so `|` and `\|` survive.
    func test_table_captionContainingAPipe_isTheCaptionNotARow() {
        let parsed = ManuscriptBlocks.parse(tableSource + "\nTable: Revenue | EMEA \\| APAC {#tbl:rev}")
        XCTAssertEqual(parsed.map(\.block),
                       [.table(header: ["Quarter", "Revenue"], rows: [["Q3", "12"]],
                               caption: "Revenue | EMEA \\| APAC", label: label(.tbl, "rev"))])
        XCTAssertEqual(parsed.map(\.lines), [0..<4])
    }

    func test_table_unicodeCaption() {
        XCTAssertEqual(blocks(tableSource + "\nTable: Revenue — Q3 ✓ {#tbl:q3}"),
                       [.table(header: ["Quarter", "Revenue"], rows: [["Q3", "12"]],
                               caption: "Revenue — Q3 ✓", label: label(.tbl, "q3"))])
    }

    // MARK: - Figures

    func test_figure_unicodeCaption() {
        XCTAssertEqual(blocks("![Café ✨ chart](../research/a.png){#fig:x}"),
                       [.figure(caption: "Café ✨ chart", path: "../research/a.png",
                                label: label(.fig, "x"))])
    }

    func test_figure_inItsOnDiskForm() {
        let parsed = ManuscriptBlocks.parse("![Revenue by quarter](../research/rev.png){#fig:revenue}")
        XCTAssertEqual(parsed.map(\.block),
                       [.figure(caption: "Revenue by quarter", path: "../research/rev.png",
                                label: label(.fig, "revenue"))])
        XCTAssertEqual(parsed.map(\.lines), [0..<1])
    }

    func test_figure_withoutALabel() {
        XCTAssertEqual(blocks("![Revenue](../research/rev.png)"),
                       [.figure(caption: "Revenue", path: "../research/rev.png", label: nil)])
    }

    func test_figure_fromASoloImage() {
        XCTAssertEqual(blocks("![cover](./art/cover.png)"),
                       [.figure(caption: "cover", path: "./art/cover.png", label: nil)])
    }

    func test_figure_pathWithASpace_isNotAFigure() {
        XCTAssertEqual(blocks("![x](../research/a b.png)"),
                       [.other(.paragraph(lines: ["![x](../research/a b.png)"]))])
    }

    func test_figure_remotePath_isStillAFigure() {
        XCTAssertEqual(blocks("![x](https://example.com/a.png){#fig:x}"),
                       [.figure(caption: "x", path: "https://example.com/a.png",
                                label: label(.fig, "x"))])
    }

    func test_figure_withAWrongKindLabel_keepsIt() {
        XCTAssertEqual(blocks("![x](a.png) {#tbl:x}"),
                       [.figure(caption: "x", path: "a.png", label: label(.tbl, "x"))])
    }

    /// An invalid attribute block is left in the text, and an image followed
    /// by stray text is not a figure, so the line stays prose.
    func test_figure_withAnInvalidAttributeBlock_isNotAFigure() {
        for line in ["![x](a.png){#eq:x}", "![x](a.png){#fig:}", "![x](a.png){.wide}"] {
            XCTAssertEqual(blocks(line), [.other(.paragraph(lines: [line]))], line)
        }
    }

    func test_figure_twoImagesOnALine_isNotAFigure() {
        let line = "![a](a.png) and ![b](b.png)"
        XCTAssertEqual(blocks(line), [.other(.paragraph(lines: [line]))])
    }

    /// The parser takes `![a](./x.png) ![b](./y.png)` as one solo image; the
    /// figure rule refuses it, so it passes through as the parser's block.
    func test_soloImage_twoImagesOnALine_isOtherNotAFigure() {
        let line = "![a](./x.png) ![b](./y.png)"
        let parsed = MarkdownBlockParser.parseWithLineRanges(line).map(\.block)
        guard case .soloImage? = parsed.first, parsed.count == 1 else {
            return XCTFail("premise: the parser reads the line as one solo image, got \(parsed)")
        }
        XCTAssertEqual(blocks(line), parsed.map { .other($0) })
        XCTAssertEqual(blocks("![c](./x.png)"),
                       [.figure(caption: "c", path: "./x.png", label: nil)])
    }

    func test_figure_captionMayContainBrackets() {
        XCTAssertEqual(blocks("![Revenue [2026]](a.png)"),
                       [.figure(caption: "Revenue [2026]", path: "a.png", label: nil)])
    }

    func test_figure_onlyAsAOneLineParagraph() {
        XCTAssertEqual(blocks("![x](a.png)\nmore"),
                       [.other(.paragraph(lines: ["![x](a.png)", "more"]))])
    }

    // MARK: - Footnote definitions

    func test_footnoteDefinition_inItsOnDiskForm() {
        XCTAssertEqual(blocks("[^1]: Source: annual report."),
                       [.footnoteDefinition(label: "1", text: "Source: annual report.")])
    }

    func test_footnoteDefinition_withAContinuationLine() {
        let parsed = ManuscriptBlocks.parse("[^note-a]: First line\n    second line")
        XCTAssertEqual(parsed.map(\.block),
                       [.footnoteDefinition(label: "note-a", text: "First line\nsecond line")])
        XCTAssertEqual(parsed.map(\.lines), [0..<2])
    }

    func test_footnoteDefinitions_stackedWithoutABlankLine_areSeparate() {
        let parsed = ManuscriptBlocks.parse("[^1]: First.\n[^2]: Second.\n  more")
        XCTAssertEqual(parsed.map(\.block), [
            .footnoteDefinition(label: "1", text: "First."),
            .footnoteDefinition(label: "2", text: "Second.\nmore"),
        ])
        XCTAssertEqual(parsed.map(\.lines), [0..<1, 1..<3])
    }

    func test_footnoteDefinition_leadingWhitespaceOfTheTextIsTrimmed() {
        XCTAssertEqual(blocks("[^1]:    Spaced."),
                       [.footnoteDefinition(label: "1", text: "Spaced.")])
    }

    func test_footnoteDefinition_emptyFirstLine_textStartsOnTheNextLine() {
        XCTAssertEqual(blocks("[^1]:\n    Body one\n    body two"),
                       [.footnoteDefinition(label: "1", text: "Body one\nbody two")])
    }

    func test_footnoteLabelRule() {
        for good in ["1", "note-a", "_x", "-", "A_9"] {
            XCTAssertTrue(ManuscriptBlocks.isValidFootnoteLabel(good), good)
        }
        for bad in ["", "a b", "a:b", "é", "a]"] {
            XCTAssertFalse(ManuscriptBlocks.isValidFootnoteLabel(bad), bad)
        }
    }

    func test_footnoteDefinition_insideAListItem_staysOther() {
        XCTAssertEqual(blocks("- [^1]: x"),
                       [.other(.list(ordered: false, items: [["[^1]: x"]]))])
    }

    func test_footnoteDefinition_insideACodeFence_staysOther() {
        XCTAssertEqual(blocks("```\n[^1]: x\n```"),
                       [.other(.fence(lines: ["[^1]: x"], info: nil))])
    }

    func test_footnoteReferenceMidParagraph_isNotADefinition() {
        XCTAssertEqual(blocks("Text with a note.[^1]"),
                       [.other(.paragraph(lines: ["Text with a note.[^1]"]))])
    }

    // MARK: - A whole document

    func test_aMixedDocument_keepsRangesAndOrder() {
        let src = """
        # Report {#sec:intro}

        Some prose.[^1]

        | a | b |
        |---|---|
        | 1 | 2 |
        Table: Numbers {#tbl:nums}

        ![Chart](../research/c.png){#fig:chart}

        [^1]: A note.
        """
        let parsed = ManuscriptBlocks.parse(src)
        XCTAssertEqual(parsed.map(\.block), [
            .heading(level: 1, text: "Report", label: label(.sec, "intro")),
            .other(.paragraph(lines: ["Some prose.[^1]"])),
            .table(header: ["a", "b"], rows: [["1", "2"]], caption: "Numbers", label: label(.tbl, "nums")),
            .figure(caption: "Chart", path: "../research/c.png", label: label(.fig, "chart")),
            .footnoteDefinition(label: "1", text: "A note."),
        ])
        XCTAssertEqual(parsed.map(\.lines), [0..<1, 2..<3, 4..<8, 9..<10, 11..<12])
    }

    // MARK: - Superset of the block parser

    /// Copies the inputs of `MarkdownBlockParityCorpusTests` and the block
    /// parser's range corpus (both private there), plus report inputs. The layer may only re-read blocks; every `.other` must be
    /// exactly what the parser produced over the same lines.
    private static let corpus: [String] = [
        "first line\nsecond line",
        "#foo",
        "```\ntext *not emphasis* here\n```",
        "1. install\n2. open\n3. connect",
        "1) install\n2) open",
        "- alpha\n- beta",
        "| Shortcut | Action |\n|---|---|\n| ⌘N | New project |",
        "a | b, either way",
        "> quoted text",
        ">quoted text",
        "----", "---------", "***", "###", "****",
        "![cover art](./assets/cover.png)",
        "![cover art](https://example.com/cover.png)",
        "text\n- item",
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
        "| a | b |\n|---|---|\n| 1 | 2 |\nTable: Revenue | EMEA {#tbl:rev}",
        "[^1]: First.\n[^2]: Second.\n  more\n\nafter",
        "![a](./x.png) ![b](./y.png)\n\n![c](./x.png)",
    ]

    func test_everyOtherBlockIsTheParsersBlockOverTheSameLines() {
        for src in Self.corpus {
            let base = MarkdownBlockParser.parseWithLineRanges(src)
            for item in ManuscriptBlocks.parse(src) {
                guard case .other(let block) = item.block else { continue }
                let match = base.first { $0.lines == item.lines }
                XCTAssertEqual(match?.block, block, src.debugDescription)
            }
        }
    }

    /// Every source line the parser covered is still covered, by exactly one
    /// block, in order: re-reading never drops or duplicates text.
    func test_rangesCoverTheSameLinesAsTheParser() {
        for src in Self.corpus + [tableSource + "\nTable: x {#tbl:x}"] {
            let baseLines = MarkdownBlockParser.parseWithLineRanges(src)
                .flatMap { Array($0.lines) }
            let ours = ManuscriptBlocks.parse(src).flatMap { Array($0.lines) }
            XCTAssertEqual(ours, baseLines, src.debugDescription)
        }
    }
}
