import XCTest
@testable import MaughamCore

/// `TableClipboard`: cells copied from Excel, Numbers or Google Sheets, as the
/// tab-separated text they put on the pasteboard (report foundations plan 3b
/// Task 5, the grid editor's Paste Cells).
final class TableClipboardTests: XCTestCase {

    func test_tabsSeparateCellsAndLineBreaksSeparateRows() {
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "a\tb\tc\n1\t2\t3"),
                       [["a", "b", "c"], ["1", "2", "3"]])
    }

    /// Excel ends each row with CRLF, the last one included; old Mac text
    /// uses a bare CR. Neither leaves an empty last row or a stray `\r`.
    func test_crlfAndCrEndRowsAndATrailingBreakAddsNoRow() {
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "a\tb\r\n1\t2\r\n"),
                       [["a", "b"], ["1", "2"]])
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "a\tb\r1\t2\r"),
                       [["a", "b"], ["1", "2"]])
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "a\n"), [["a"]])
    }

    func test_nothingIsNoRows() {
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: ""), [])
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "\r\n"), [[""]],
                       "one empty line copied is one empty cell")
    }

    /// Empty cells keep their places, at either end of a row.
    func test_emptyCellsKeepTheirPlaces() {
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "\tb\t\n\t\t"),
                       [["", "b", ""], ["", "", ""]])
    }

    /// Excel quotes a cell holding a tab, a line break or a quote, and
    /// doubles each quote inside it.
    func test_aQuotedCellHoldsTabsLineBreaksAndDoubledQuotes() {
        let tsv = "\"a\tb\"\t\"line one\nline two\"\t\"say \"\"hi\"\"\"\r\nplain\t\"\"\tlast\r\n"
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: tsv), [
            ["a\tb", "line one\nline two", "say \"hi\""],
            ["plain", "", "last"],
        ])
    }

    func test_aCrlfInsideQuotesIsKeptInTheCell() {
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "\"x\r\ny\"\tz"),
                       [["x\r\ny", "z"]])
    }

    /// A quote that does not open the cell is just a character (Excel writes
    /// `5" pipe` unquoted when nothing else needs quoting).
    func test_aQuoteInsideAnUnquotedCellIsLiteral() {
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "5\" pipe\tO\"Brien"),
                       [["5\" pipe", "O\"Brien"]])
    }

    /// Text after a closing quote is kept rather than dropped, and a quote
    /// left open runs to the end — nothing the writer copied is lost.
    func test_malformedQuotingLosesNoText() {
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "\"a\"b\tc"), [["ab", "c"]])
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "\"open\tstill\nopen"),
                       [["open\tstill\nopen"]])
    }

    /// Rows are returned as copied: a ragged row is not padded (the grid
    /// grows to the widest).
    func test_raggedRowsAreReturnedAsCopied() {
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "a\tb\tc\n1\n1\t2"),
                       [["a", "b", "c"], ["1"], ["1", "2"]])
    }

    /// Without the quote rule (plain text, not a spreadsheet's flavour) a
    /// quote is the writer's own character and a tab inside it still splits.
    func test_withoutQuotingEveryQuoteIsKept() {
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "\"a\tb\"\t\"\"x\"\"\r\n", quoting: false),
                       [["\"a", "b\"", "\"\"x\"\""]])
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "\"a\tb\"", quoting: true), [["a\tb"]],
                       "control: the same text, quoted")
    }

    func test_unicodeCellsAreKeptWhole() {
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: "👨‍👩‍👧\te\u{301}\r\nЋ\t\"日本\""),
                       [["👨‍👩‍👧", "e\u{301}"], ["Ћ", "日本"]])
    }
}
