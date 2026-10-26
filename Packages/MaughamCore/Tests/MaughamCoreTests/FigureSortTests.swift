import XCTest
@testable import MaughamCore

/// **Sort by column** (report plan 7c Task 1, ruling R7c-7): stable;
/// numbers < dates < text < booleans < errors < empty ascending, the empty
/// cells last either way; the header and total rows stay put.
final class FigureSortTests: XCTestCase {

    private let column = ColumnID("cccccccc")

    /// A one-column table whose rows are `ids`, the values keyed by row id.
    private func table(_ ids: [String], header: Int = 0, total: Bool = false) -> FigureTable {
        var t = FigureTable(rows: 0, columns: 0)
        t.insertColumn(column, after: nil)
        var prev: RowID?
        for s in ids { t.insertRow(RowID(s), after: prev); prev = RowID(s) }
        t.headerRows = header
        t.hasTotalRow = total
        return t
    }

    private func order(
        _ t: FigureTable, _ values: [String: CellValue], ascending: Bool = true
    ) -> [String] {
        FigureSort.order(
            table: t, values: { values[$0.row.raw] ?? .empty }, column: column, ascending: ascending
        ).map(\.raw)
    }

    func test_numbersSortByValue_bothWays() {
        let t = table(["a", "b", "c"])
        let v: [String: CellValue] = ["a": .number(3), "b": .number(1), "c": .number(2)]
        XCTAssertEqual(order(t, v), ["b", "c", "a"])
        XCTAssertEqual(order(t, v, ascending: false), ["a", "c", "b"])
    }

    func test_kindsRankNumbersDatesTextBooleansErrorsThenEmpty() {
        let t = table(["e", "t", "b", "d", "n", "x", "r"])
        let v: [String: CellValue] = [
            "e": .empty, "t": .text("x"), "b": .bool(false), "d": .date(45_000), "n": .number(9_999_999),
            "r": .error(.ref),
        ]
        XCTAssertEqual(order(t, v), ["n", "d", "t", "b", "r", "e", "x"],
            "numbers < dates < text < booleans < errors < empty (a missing value is empty)")
        XCTAssertEqual(order(t, v, ascending: false), ["r", "b", "t", "d", "n", "e", "x"],
            "descending reverses the kinds, and the empty cells stay last")
    }

    func test_textIsCaseInsensitiveAndNumericAware() {
        let t = table(["a", "b", "c", "d"])
        let v: [String: CellValue] = [
            "a": .text("item 10"), "b": .text("Item 2"), "c": .text("apple"), "d": .text("Banana"),
        ]
        XCTAssertEqual(order(t, v), ["c", "d", "b", "a"])
    }

    func test_booleansFalseBeforeTrue() {
        let t = table(["a", "b"])
        XCTAssertEqual(order(t, ["a": .bool(true), "b": .bool(false)]), ["b", "a"])
    }

    func test_equalValuesKeepTheirOrder_bothWays() {
        let t = table(["a", "b", "c", "d"])
        let v: [String: CellValue] = ["a": .number(1), "b": .number(2), "c": .number(1), "d": .number(2)]
        XCTAssertEqual(order(t, v), ["a", "c", "b", "d"])
        XCTAssertEqual(order(t, v, ascending: false), ["b", "d", "a", "c"],
            "stable descending: ties keep their order, they are not reversed")
    }

    func test_theHeaderAndTotalRowsStayPut() {
        let t = table(["h", "a", "b", "c", "t"], header: 1, total: true)
        let v: [String: CellValue] = [
            "h": .text("Year"), "a": .number(3), "b": .number(1), "c": .number(2), "t": .number(6),
        ]
        XCTAssertEqual(order(t, v), ["h", "b", "c", "a", "t"])
        XCTAssertEqual(order(t, v, ascending: false), ["h", "a", "c", "b", "t"])
    }

    func test_tombstonedRowsAreNotInTheOrder() {
        var t = table(["a", "b", "c"])
        t.deleteRow(RowID("b"))
        XCTAssertEqual(order(t, ["a": .number(2), "c": .number(1)]), ["c", "a"])
    }

    func test_aHeaderAndTotalOnTheSameOneRowLeaveNothingToSort() {
        let t = table(["h"], header: 1, total: true)
        XCTAssertEqual(order(t, [:]), ["h"])
        XCTAssertEqual(order(table([]), [:]), [])
    }
}
