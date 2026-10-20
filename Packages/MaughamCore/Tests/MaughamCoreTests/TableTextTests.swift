import XCTest
@testable import MaughamCore

/// `TableText`, the one pipe-table formatter (report foundations plan 3a
/// Task 5): what the editor's Tab, Return and leave-the-table tidy write, and
/// what plan 3b's grid editor will write.
final class TableTextTests: XCTestCase {

    // MARK: - Parsing

    func test_parsesHeaderAlignmentsRowsCaptionAndLabel() throws {
        let t = try XCTUnwrap(TableText(parsing: """
            | A | B | C | D |
            |:--|:-:|--:|---|
            | 1 | 2 | 3 | 4 |
            Table: Sales {#tbl:sales}
            """))
        XCTAssertEqual(t.header, ["A", "B", "C", "D"])
        XCTAssertEqual(t.alignments, [.leading, .center, .trailing, .none])
        XCTAssertEqual(t.rows, [["1", "2", "3", "4"]])
        XCTAssertEqual(t.caption, "Sales")
        XCTAssertEqual(t.label, ManuscriptLabel(reference: "tbl:sales"))
    }

    func test_aBlockThatIsNotOneTableIsNil() {
        XCTAssertNil(TableText(parsing: "Just prose."))
        XCTAssertNil(TableText(parsing: "| a | b |\nno delimiter"))
        XCTAssertNil(TableText(parsing: "| a |\n|---|\n\nAfter."), "a table and a paragraph")
        XCTAssertNil(TableText(parsing: ""))
    }

    func test_aShortRowIsPaddedToTheHeaderAndALongRowKeepsItsCells() throws {
        let t = try XCTUnwrap(TableText(parsing: "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |"))
        XCTAssertEqual(t.rows, [["1", "", ""], ["1", "2", "3", "4"]],
                       "no cell the writer typed is dropped")
    }

    // MARK: - Formatting

    func test_formatsColumnAlignedPipesAndTheDelimiterFromTheAlignments() throws {
        let t = try XCTUnwrap(TableText(parsing: """
            |Name|Qty|Price|Note|
            |:-|:-:|-:|-|
            |Apple|3|1.20|fresh|
            |Kiwi|12|0.5||
            Table: Fruit {#tbl:fruit}
            """))
        XCTAssertEqual(t.formatted(), """
            | Name  | Qty | Price | Note  |
            | :---- | :-: | ----: | ----- |
            | Apple | 3   | 1.20  | fresh |
            | Kiwi  | 12  | 0.5   |       |
            Table: Fruit {#tbl:fruit}
            """)
    }

    func test_aCaptionWithoutALabelAndALabelWithAnEmptyCaption() throws {
        let plain = try XCTUnwrap(TableText(parsing: "| a |\n|---|\nTable: Just words"))
        XCTAssertEqual(plain.formatted(), "| a   |\n| --- |\nTable: Just words")
        let bare = try XCTUnwrap(TableText(parsing: "| a |\n|---|\nTable: {#tbl:x}"))
        XCTAssertEqual(bare.caption, "")
        XCTAssertEqual(bare.formatted(), "| a   |\n| --- |\nTable: {#tbl:x}")
        XCTAssertEqual(TableText(parsing: bare.formatted()), bare)
    }

    func test_formattedNeverHoldsABlankLine() throws {
        let t = try XCTUnwrap(TableText(parsing: "| a | b |\n|---|---|\n| | |\n|  |  |"))
        XCTAssertFalse(t.formatted().contains("\n\n"))
        XCTAssertFalse(t.formatted().split(separator: "\n", omittingEmptySubsequences: false)
                        .contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// The display width is the grapheme count: an emoji family and an
    /// accented letter written as two scalars are one column each.
    func test_unicodeCellsPadByGraphemeCount() throws {
        let t = try XCTUnwrap(TableText(parsing: "| 👨‍👩‍👧 | e\u{301}té |\n|---|---|\n| ab | x |"))
        XCTAssertEqual(t.formatted(), "| 👨‍👩‍👧   | e\u{301}té |\n| --- | --- |\n| ab  | x   |")
    }

    func test_anEscapedPipeStaysOneCellAndIsWrittenEscaped() throws {
        let t = try XCTUnwrap(TableText(parsing: "| a \\| b | c |\n|---|---|\n| x | y |"))
        XCTAssertEqual(t.header, ["a | b", "c"])
        XCTAssertEqual(t.formatted(), "| a \\| b | c   |\n| ------ | --- |\n| x      | y   |")
        XCTAssertEqual(TableText(parsing: t.formatted()), t)
    }

    /// Core's row splitter does not know code spans: a `|` inside backticks
    /// splits the cell. The formatter re-reads through the same parser, so it
    /// keeps exactly the cells the parser (and so publishing) sees — never one
    /// more, never one fewer.
    func test_aPipeInsideBackticksSplitsExactlyAsTheParserSplitsIt() throws {
        let block = "| code | b |\n|---|---|\n| `a|b` | c |"
        let t = try XCTUnwrap(TableText(parsing: block))
        guard case .table(_, _, let rows, _, _)? = ManuscriptBlocks.parse(block).first?.block else {
            return XCTFail("the block is not a table")
        }
        XCTAssertEqual(t.rows, rows, "the formatter must see the parser's cells")
        XCTAssertEqual(TableText(parsing: t.formatted()), t)
        let escaped = try XCTUnwrap(TableText(parsing: "| code |\n|---|\n| `a\\|b` |"))
        XCTAssertEqual(escaped.rows, [["`a|b`"]])
        XCTAssertEqual(escaped.formatted(), "| code   |\n| ------ |\n| `a\\|b` |")
    }

    func test_footnoteRefsCitationsAndCrossRefsSurviveReAlignment() throws {
        let block = """
            | Claim | Source |
            |---|---|
            | Up[^1] | [@smith2020, p. 4] |
            | See @tbl:other | [@a; @b] |
            Table: Claims {#tbl:claims}
            """
        let formatted = try XCTUnwrap(TableText(parsing: block)).formatted()
        for kept in ["Up[^1]", "[@smith2020, p. 4]", "See @tbl:other", "[@a; @b]",
                     "Table: Claims {#tbl:claims}"] {
            XCTAssertTrue(formatted.contains(kept), "\(kept) did not survive: \(formatted)")
        }
        XCTAssertEqual(ManuscriptInlineScanner.scan(formatted).count,
                       ManuscriptInlineScanner.scan(block).count)
    }

    func test_aRaggedRowFormatsEveryCell() throws {
        let t = try XCTUnwrap(TableText(parsing: "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | extra |"))
        XCTAssertEqual(t.formatted(), """
            | a   | b   |
            | --- | --- |
            | 1   |     |
            | 1   | 2   | extra |
            """)
        XCTAssertEqual(TableText(parsing: t.formatted()), t)
    }

    // MARK: - Round trip

    func test_roundTrip() throws {
        let blocks = [
            "| a |\n|---|",
            "|x|y|\n|:-:|--:|\n|1|2|\nTable: Cap {#tbl:t}",
            "| 👨‍👩‍👧 | é |\n|---|---|\n| \\| | `a|b` |",
            "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |",
            "| h |\n|---|\n| [^1] and [@k] |\nTable: Caption with | pipe",
            "| a\\\\| b |\n|---|---|",
        ]
        for block in blocks {
            let t = try XCTUnwrap(TableText(parsing: block), block)
            XCTAssertEqual(TableText(parsing: t.formatted()), t, block)
            XCTAssertEqual(TableText(parsing: t.formatted())?.formatted(), t.formatted(),
                           "formatting is idempotent: \(block)")
        }
    }

    // MARK: - Cells and offsets

    func test_cellAtAnOffset() {
        let block = "| ab | c |\n| -- | - |\n| d  | e |\nTable: Cap"
        let ns = block as NSString
        func at(_ needle: String) -> (row: Int, column: Int)? {
            TableText.cell(at: ns.range(of: needle).location, in: block)
        }
        XCTAssertEqual(TableText.cell(at: 0, in: block)?.row, 0)
        XCTAssertEqual(TableText.cell(at: 0, in: block)?.column, 0)
        XCTAssertEqual(at("ab")?.column, 0)
        XCTAssertEqual(at("c ")?.column, 1)
        XCTAssertEqual(at("d")?.row, 1)
        XCTAssertEqual(at("e")?.row, 1)
        XCTAssertEqual(at("e")?.column, 1)
        XCTAssertNil(at("--"), "the delimiter row is no cell")
        XCTAssertNil(at("Cap"), "the caption line is no cell")
        // Just after the row's closing pipe (the line's end) is its last cell.
        XCTAssertEqual(TableText.cell(at: ns.range(of: "e |").location + 3, in: block)?.column, 1)
        XCTAssertNil(TableText.cell(at: 0, in: "prose"))
    }

    func test_cellAtSkipsAnEscapedPipeAndCountsUTF16() {
        let block = "| 👨‍👩‍👧 \\| x | y |\n|---|---|"
        let ns = block as NSString
        XCTAssertEqual(TableText.cell(at: ns.range(of: "x").location, in: block)?.column, 0)
        XCTAssertEqual(TableText.cell(at: ns.range(of: "y").location, in: block)?.column, 1)
    }

    func test_offsetOfACellIsTheStartOfItsText() throws {
        let t = try XCTUnwrap(TableText(parsing: "| 👨‍👩‍👧 | é |\n|---|---|\n| ab | |"))
        let f = t.formatted()
        let ns = f as NSString
        XCTAssertEqual(TableText.offset(ofCell: 0, 0, in: f), ns.range(of: "👨‍👩‍👧").location)
        XCTAssertEqual(TableText.offset(ofCell: 0, 1, in: f), ns.range(of: "é").location)
        XCTAssertEqual(TableText.offset(ofCell: 1, 0, in: f), ns.range(of: "ab").location)
        // An empty cell's text starts after the pipe and its one space.
        let rowStart = ns.range(of: "| ab").location
        let secondPipe = ns.range(of: "|", range: NSRange(location: rowStart + 1,
                                                          length: ns.length - rowStart - 1)).location
        XCTAssertEqual(TableText.offset(ofCell: 1, 1, in: f), secondPipe + 2)
        // Every cell's offset reads back as that cell.
        for row in 0...1 {
            for column in 0...1 {
                let o = TableText.offset(ofCell: row, column, in: f)
                XCTAssertEqual(TableText.cell(at: o, in: f)?.row, row)
                XCTAssertEqual(TableText.cell(at: o, in: f)?.column, column)
            }
        }
    }

    func test_textRangeOfACellIsItsTrimmedText() throws {
        let f = try XCTUnwrap(TableText(parsing: "| Name | b |\n|---|---|\n|  | x |")).formatted()
        let ns = f as NSString
        XCTAssertEqual(ns.substring(with: TableText.textRange(ofCell: 0, 0, in: f)), "Name")
        XCTAssertEqual(ns.substring(with: TableText.textRange(ofCell: 1, 1, in: f)), "x")
        XCTAssertEqual(TableText.textRange(ofCell: 1, 0, in: f).length, 0)
        XCTAssertEqual(TableText.textRange(ofCell: 1, 0, in: f).location,
                       TableText.offset(ofCell: 1, 0, in: f))
    }
}
