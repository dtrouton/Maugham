import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// The in-place grid's geometry and drawing plan (report plan 7c Task 4),
/// pure: where a point lands, each cell's frame, the rows a scroll shows,
/// the resize edge, the viewport's height (R7c-2), and what is drawn as
/// rectangles and strings. Clicks are tested here, never synthesised
/// (tripwire 33).
@MainActor
final class FigureGridLayoutTests: XCTestCase {
    /// Gutter 30, band and rows 20, columns 50 / 80 / 60; the body shows five rows.
    private func layout(rows: Int = 40, width: CGFloat = 300, scroll: CGPoint = .zero) -> FigureGridLayout {
        var l = FigureGridLayout(columnWidths: [50, 80, 60], rowCount: rows, rowHeight: 20, gutterWidth: 30,
                                 size: CGSize(width: width, height: 20 + 5 * 20))
        l.scroll = l.clamped(scroll)
        return l
    }

    // MARK: Viewport (R7c-2)

    func test_theViewportShowsMinOfRowsAndFifteenRowsUnderTheLetterBand() {
        XCTAssertEqual(FigureGridLayout.viewportHeight(rows: 0, rowHeight: 20), 20)
        XCTAssertEqual(FigureGridLayout.viewportHeight(rows: 3, rowHeight: 20), 80)
        XCTAssertEqual(FigureGridLayout.viewportHeight(rows: 15, rowHeight: 20), 320)
        XCTAssertEqual(FigureGridLayout.viewportHeight(rows: 40, rowHeight: 20), 320, "constant from 15 rows up")
    }

    func test_columnWidthsComeFromTheTableOrTheDefault() {
        var table = FigureTable(rows: 1, columns: 3)
        table.columnWidths[table.columns[0]] = 150
        table.columnWidths[table.columns[1]] = 5
        XCTAssertEqual(FigureGridLayout.widths(for: table),
                       [150, FigureGridLayout.minColumnWidth, FigureGridLayout.defaultColumnWidth])
    }

    // MARK: Hits

    func test_aPointInTheBodyLandsOnItsCell() throws {
        let l = layout()
        XCTAssertEqual(try XCTUnwrap(l.cell(at: CGPoint(x: 35, y: 25))).row, 0)
        let hit = try XCTUnwrap(l.cell(at: CGPoint(x: 30 + 50 + 80 + 1, y: 20 + 40 + 1)))
        XCTAssertEqual(hit.row, 2)
        XCTAssertEqual(hit.column, 2)
        XCTAssertNil(l.cell(at: CGPoint(x: 35, y: 10)), "the letter band is no cell")
        XCTAssertNil(l.cell(at: CGPoint(x: 10, y: 25)), "the gutter is no cell")
        XCTAssertNil(l.cell(at: CGPoint(x: 30 + 190 + 5, y: 25)), "past the last column")
        XCTAssertNil(layout(rows: 2).cell(at: CGPoint(x: 35, y: 20 + 2 * 20 + 1)), "past the last row")
    }

    func test_aScrolledBodyLandsOnTheRowUnderThePoint() throws {
        let hit = try XCTUnwrap(layout(scroll: CGPoint(x: 0, y: 40)).cell(at: CGPoint(x: 35, y: 25)))
        XCTAssertEqual(hit.row, 2)
        XCTAssertEqual(hit.column, 0)
    }

    func test_cellFramesFollowTheScroll() {
        XCTAssertEqual(layout().cellFrame(row: 1, column: 1), CGRect(x: 80, y: 40, width: 80, height: 20))
        XCTAssertEqual(layout(width: 120, scroll: CGPoint(x: 10, y: 20)).cellFrame(row: 1, column: 1),
                       CGRect(x: 70, y: 20, width: 80, height: 20))
        XCTAssertEqual(layout().rangeFrame((3, 2), (1, 1)), CGRect(x: 80, y: 40, width: 140, height: 60))
        XCTAssertEqual(layout().letterFrame(column: 2), CGRect(x: 160, y: 0, width: 60, height: 20))
        XCTAssertEqual(layout(scroll: CGPoint(x: 0, y: 20)).numberFrame(row: 3),
                       CGRect(x: 0, y: 60, width: 30, height: 20))
    }

    // MARK: Visible range

    func test_theVisibleRowsAreTheOnesTheScrollShows() {
        XCTAssertEqual(layout().visibleRows, 0..<5)
        XCTAssertEqual(layout(scroll: CGPoint(x: 0, y: 30)).visibleRows, 1..<7, "partly shown rows count")
        XCTAssertEqual(layout(scroll: CGPoint(x: 0, y: 10_000)).visibleRows, 35..<40, "clamped to the last rows")
        XCTAssertEqual(layout(rows: 3).visibleRows, 0..<3)
        XCTAssertEqual(layout(rows: 0).visibleRows, 0..<0)
    }

    func test_theVisibleColumnsAreTheOnesTheScrollShows() {
        XCTAssertEqual(layout().visibleColumns, 0..<3)
        XCTAssertEqual(layout(width: 120).visibleColumns, 0..<2)
        XCTAssertEqual(layout(width: 120, scroll: CGPoint(x: 60, y: 0)).visibleColumns, 1..<3)
    }

    func test_theScrollIsHeldInsideTheContent() {
        let l = layout(width: 120)
        XCTAssertEqual(l.clamped(CGPoint(x: -5, y: -5)), .zero)
        XCTAssertEqual(l.clamped(CGPoint(x: 1_000, y: 1_000)), CGPoint(x: 100, y: 700))
        XCTAssertEqual(layout(rows: 3).maxScroll, .zero, "a short table does not scroll")
    }

    func test_revealingACellScrollsAsLittleAsItCan() {
        let l = layout(width: 120)
        XCTAssertEqual(l.scroll(revealing: 10, column: 0), CGPoint(x: 0, y: 120))
        XCTAssertEqual(l.scroll(revealing: 2, column: 0), .zero, "already shown: no move")
        var down = l
        down.scroll = CGPoint(x: 0, y: 120)
        XCTAssertEqual(down.scroll(revealing: 2, column: 0), CGPoint(x: 0, y: 40))
        XCTAssertEqual(l.scroll(revealing: 0, column: 2), CGPoint(x: 100, y: 0))
    }

    /// **A press on a letter selects its column, on a number its row** (the
    /// Task 4 ruling, built in Task 5): the hit, and the key the view sends.
    func test_aLetterIsItsColumn_aNumberItsRow_andTheViewSendsTheirKeys() {
        let l = layout()
        XCTAssertEqual(l.letterColumn(at: CGPoint(x: 31, y: 10)), 0)
        XCTAssertEqual(l.letterColumn(at: CGPoint(x: 30 + 50 + 40, y: 10)), 1)
        XCTAssertNil(l.letterColumn(at: CGPoint(x: 30 + 190 + 5, y: 10)), "past the last column")
        XCTAssertNil(l.letterColumn(at: CGPoint(x: 10, y: 10)), "the corner is no letter")
        XCTAssertNil(l.letterColumn(at: CGPoint(x: 35, y: 25)), "the body is no letter")
        XCTAssertEqual(l.numberRow(at: CGPoint(x: 10, y: 20 + 2 * 20 + 1)), 2)
        XCTAssertEqual(layout(scroll: CGPoint(x: 0, y: 40)).numberRow(at: CGPoint(x: 10, y: 25)), 2, "follows the scroll")
        XCTAssertNil(l.numberRow(at: CGPoint(x: 10, y: 10)), "the corner is no number")
        XCTAssertNil(layout(rows: 2).numberRow(at: CGPoint(x: 10, y: 20 + 2 * 20 + 1)), "past the last row")

        let table = FigureTable(rows: 40, columns: 3)
        XCTAssertEqual(FigureGridView.headerKey(at: CGPoint(x: 30 + 50 + 40, y: 10), in: l, table: table),
                       .selectColumn(table.columns[1]))
        XCTAssertEqual(FigureGridView.headerKey(at: CGPoint(x: 10, y: 20 + 2 * 20 + 1), in: l, table: table),
                       .selectRow(table.rows[2]))
        XCTAssertNil(FigureGridView.headerKey(at: CGPoint(x: 35, y: 25), in: l, table: table), "a cell is a click")
    }

    // MARK: Resize

    func test_aPressNearAColumnsRightEdgeInTheBandResizesIt() {
        let l = layout()
        XCTAssertEqual(l.resizeBoundary(at: CGPoint(x: 80, y: 10)), 0)
        XCTAssertEqual(l.resizeBoundary(at: CGPoint(x: 82, y: 10)), 0)
        XCTAssertNil(l.resizeBoundary(at: CGPoint(x: 84, y: 10)))
        XCTAssertEqual(l.resizeBoundary(at: CGPoint(x: 159, y: 10)), 1)
        XCTAssertNil(l.resizeBoundary(at: CGPoint(x: 80, y: 30)), "the body never resizes")
        XCTAssertEqual(layout(width: 120, scroll: CGPoint(x: 60, y: 0)).resizeBoundary(at: CGPoint(x: 100, y: 5)), 1,
                       "edges follow the sideways scroll")
    }

    func test_aDraggedEdgeGivesTheColumnItsWidthAboveTheFloor() {
        let l = layout()
        XCTAssertEqual(l.width(ofColumn: 1, draggedTo: 200), 120)
        XCTAssertEqual(l.width(ofColumn: 1, draggedTo: 85), FigureGridLayout.minColumnWidth)
    }

    // MARK: Drawing plan

    /// Four rows (a header, two body, a total) × two columns: text then numbers.
    private func smallTable() -> FigureTable {
        var t = FigureTable(rows: 4, columns: 2)
        t.headerRows = 1
        t.hasTotalRow = true
        for (r, row) in t.rows.enumerated() {
            t.setCell(Cell(content: .value(.text("r\(r)"))), at: CellKey(row: row, column: t.columns[0]))
            t.setCell(Cell(content: .value(.number(Double(r)))), at: CellKey(row: row, column: t.columns[1]))
        }
        t.setCell(Cell(content: .value(.text("mid")), alignment: .center),
                  at: CellKey(row: t.rows[1], column: t.columns[1]))
        return t
    }

    private func value(_ table: FigureTable) -> (CellKey) -> CellValue {
        { key in if case .value(let v)? = table[key]?.content { return v }; return .empty }
    }

    func test_thePlanDrawsLettersNumbersAndCellsLikeTheCard() {
        let table = smallTable()
        let l = FigureGridLayout(columnWidths: [50, 80], rowCount: 4, rowHeight: 20, gutterWidth: 30,
                                 size: CGSize(width: 300, height: 100))
        let plan = FigureGridPlan.make(layout: l, table: table, display: { "\(table.rowIndex(of: $0.row)!)" },
                                       value: value(table), selection: nil, reference: nil)
        XCTAssertEqual(plan.letters.map(\.string), ["A", "B"])
        XCTAssertEqual(plan.numbers.map(\.string), ["1", "2", "3", "4"])
        XCTAssertEqual(plan.cells.count, 8)
        XCTAssertEqual(plan.cells.map(\.bold), [true, true] + Array(repeating: false, count: 6), "the header row is bold")
        XCTAssertEqual(plan.cells[0].alignment, .left, "text left")
        XCTAssertEqual(plan.cells[1].alignment, .right, "numbers right")
        XCTAssertEqual(plan.cells[3].alignment, .center, "a cell's own alignment wins")
        XCTAssertEqual(plan.cells[0].rect, CGRect(x: 30 + FigureCardDrawing.cellInset, y: 20,
                                                  width: 50 - 2 * FigureCardDrawing.cellInset, height: 20))
        XCTAssertEqual(plan.rules, [40, 80], "under the header, over the total row")
        XCTAssertNil(plan.scroller, "four rows fit")
        XCTAssertNil(plan.horizontalScroller, "two columns fit")
    }

    /// Columns wider than the viewport draw a horizontal indicator along the
    /// body's foot, moved by the sideways scroll (T4 review minor 6).
    func test_overflowingColumnsDrawAHorizontalIndicator() throws {
        let table = FigureTable(rows: 2, columns: 6)
        var l = FigureGridLayout(columnWidths: Array(repeating: 100, count: 6), rowCount: 2, rowHeight: 20,
                                 gutterWidth: 30, size: CGSize(width: 330, height: 60))
        let first = try XCTUnwrap(FigureGridPlan.make(layout: l, table: table, display: { _ in "" },
                                                      value: { _ in .empty }, selection: nil,
                                                      reference: nil).horizontalScroller)
        XCTAssertEqual(first.minX, l.bodyRect.minX, "at the left edge")
        XCTAssertEqual(first.maxY, l.bodyRect.maxY - 1)
        XCTAssertEqual(first.width, (300 * 300 / 600).rounded(), "its share of the content")
        l.scroll = l.clamped(CGPoint(x: 10_000, y: 0))
        let last = try XCTUnwrap(FigureGridPlan.make(layout: l, table: table, display: { _ in "" },
                                                     value: { _ in .empty }, selection: nil,
                                                     reference: nil).horizontalScroller)
        XCTAssertEqual(last.maxX, l.bodyRect.maxX, accuracy: 0.5, "scrolled right: at the right edge")
    }

    func test_thePlanAsksForTheVisibleRowsOnly() {
        var table = FigureTable(rows: 40, columns: 2)
        table.hasTotalRow = true
        var l = FigureGridLayout(columnWidths: [50, 80], rowCount: 40, rowHeight: 20, gutterWidth: 30,
                                 size: CGSize(width: 300, height: 120))
        l.scroll = l.clamped(CGPoint(x: 0, y: 200))
        var asked = Set<Int>()
        let plan = FigureGridPlan.make(layout: l, table: table,
                                       display: { asked.insert(table.rowIndex(of: $0.row)!); return "" },
                                       value: { _ in .empty }, selection: nil, reference: nil)
        XCTAssertEqual(asked, Set(10..<15))
        XCTAssertEqual(plan.numbers.map(\.string), (11...15).map(String.init))
        XCTAssertEqual(plan.rules, [], "the total row is off screen")
        XCTAssertNotNil(plan.scroller, "forty rows overflow")
    }

    func test_thePlanDrawsTheSelectionItsActiveCellAndAComposedReference() throws {
        let table = smallTable()
        let l = FigureGridLayout(columnWidths: [50, 80], rowCount: 4, rowHeight: 20, gutterWidth: 30,
                                 size: CGSize(width: 300, height: 100))
        let a = CellKey(row: table.rows[2], column: table.columns[1])
        let f = CellKey(row: table.rows[1], column: table.columns[0])
        let plan = FigureGridPlan.make(
            layout: l, table: table, display: { _ in "" }, value: value(table),
            selection: FigureGridSelection(anchor: a, focus: f),
            reference: FigureGridReference(anchor: f, focus: f, prefix: "="))
        XCTAssertEqual(plan.selection, CGRect(x: 30, y: 40, width: 130, height: 40))
        XCTAssertEqual(plan.active, CGRect(x: 80, y: 60, width: 80, height: 20), "the anchor is the active cell")
        XCTAssertEqual(plan.reference, CGRect(x: 30, y: 40, width: 50, height: 20))
    }
}
