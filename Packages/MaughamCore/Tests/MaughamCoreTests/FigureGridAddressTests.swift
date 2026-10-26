import XCTest
@testable import MaughamCore

/// **The grid's A1 text** (report plan 7c Task 2): "B3" and "B2:D9" by live
/// position, and back to ids.
final class FigureGridAddressTests: XCTestCase {

    /// Rows r0…r(rows-1) and columns c0…c(columns-1), in order.
    private func table(rows: Int, columns: Int) -> FigureTable {
        var t = FigureTable(rows: 0, columns: 0)
        var prevRow: RowID?
        for r in 0..<rows { t.insertRow(RowID("r\(r)"), after: prevRow); prevRow = RowID("r\(r)") }
        var prevColumn: ColumnID?
        for c in 0..<columns { t.insertColumn(ColumnID("c\(c)"), after: prevColumn); prevColumn = ColumnID("c\(c)") }
        return t
    }

    private func k(_ r: Int, _ c: Int) -> CellKey { CellKey(row: RowID("r\(r)"), column: ColumnID("c\(c)")) }

    func test_aCellIsItsColumnLettersAndOneBasedRow() {
        let t = table(rows: 30, columns: 28)
        XCTAssertEqual(FigureGridAddress.string(for: k(0, 0), in: t), "A1")
        XCTAssertEqual(FigureGridAddress.string(for: k(2, 1), in: t), "B3")
        XCTAssertEqual(FigureGridAddress.string(for: k(29, 27), in: t), "AB30")
    }

    func test_aCellNotLiveInTheTableHasNoAddress() {
        var t = table(rows: 3, columns: 3)
        t.deleteRow(RowID("r1"))
        XCTAssertNil(FigureGridAddress.string(for: k(1, 0), in: t))
        XCTAssertNil(FigureGridAddress.string(for: CellKey(row: RowID("zz"), column: ColumnID("c0")), in: t))
        // A deleted row shifts the rows below it up.
        XCTAssertEqual(FigureGridAddress.string(for: k(2, 0), in: t), "A2")
    }

    func test_aRangeIsWrittenTopLeftToBottomRightWhicheverCornersItIsGiven() {
        let t = table(rows: 10, columns: 5)
        XCTAssertEqual(FigureGridAddress.string(from: k(1, 1), to: k(8, 3), in: t), "B2:D9")
        XCTAssertEqual(FigureGridAddress.string(from: k(8, 3), to: k(1, 1), in: t), "B2:D9")
        XCTAssertEqual(FigureGridAddress.string(from: k(8, 1), to: k(1, 3), in: t), "B2:D9")
        XCTAssertEqual(FigureGridAddress.string(from: k(2, 1), to: k(2, 1), in: t), "B3")
        XCTAssertNil(FigureGridAddress.string(from: k(2, 1), to: k(20, 1), in: t))
    }

    func test_parsingACellIsCaseInsensitiveAndAllowsDollarsAndSpaces() {
        let t = table(rows: 10, columns: 5)
        XCTAssertEqual(FigureGridAddress.cell("B3", in: t), k(2, 1))
        XCTAssertEqual(FigureGridAddress.cell("b3", in: t), k(2, 1))
        XCTAssertEqual(FigureGridAddress.cell(" $B$3 ", in: t), k(2, 1))
    }

    func test_parsingRefusesAnythingOutsideTheTableOrNotAnAddress() {
        let t = table(rows: 10, columns: 5)
        for text in ["F1", "A11", "A0", "B", "3", "", "B3C", "revenue!B3", "B3:", ":B3", "A1:B2:C3"] {
            XCTAssertNil(FigureGridAddress.range(text, in: t), text)
        }
        XCTAssertNil(FigureGridAddress.cell("B2:D9", in: t))
    }

    func test_parsingARangeKeepsTheOrderWritten() {
        let t = table(rows: 10, columns: 5)
        let r = FigureGridAddress.range("B2:D9", in: t)
        XCTAssertEqual(r?.from, k(1, 1)); XCTAssertEqual(r?.to, k(8, 3))
        let back = FigureGridAddress.range("d9:b2", in: t)
        XCTAssertEqual(back?.from, k(8, 3)); XCTAssertEqual(back?.to, k(1, 1))
        let one = FigureGridAddress.range("C4", in: t)
        XCTAssertEqual(one?.from, k(3, 2)); XCTAssertEqual(one?.to, k(3, 2))
    }

    func test_anEmptyTableHasNoCells() {
        let t = table(rows: 0, columns: 0)
        XCTAssertNil(FigureGridAddress.cell("A1", in: t))
    }

    func test_renderAndParseRoundTrip() {
        let t = table(rows: 12, columns: 30)
        for (r, c) in [(0, 0), (11, 29), (5, 26)] {
            let text = FigureGridAddress.string(for: k(r, c), in: t)!
            XCTAssertEqual(FigureGridAddress.cell(text, in: t), k(r, c), text)
        }
    }
}
