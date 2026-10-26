import XCTest
@testable import MaughamCore

/// `FigureFill` (report plan 7d Task 1, ⌘D / ⌘R — ruling R7d-1): Excel's
/// Fill Down and Fill Right over a table figure's selection.
final class FigureFillTests: XCTestCase {

    private var table = FigureTable(rows: 4, columns: 3)

    private func key(_ r: Int, _ c: Int) -> CellKey { CellKey(row: table.rows[r], column: table.columns[c]) }
    private func num(_ x: Double) -> Cell { Cell(content: .value(.number(x))) }
    private func formula(_ text: String) throws -> Cell {
        Cell(content: .formula(try FormulaParser.parse(text, in: table).get()))
    }
    private func selection(_ a: (Int, Int), _ b: (Int, Int)) -> FigureGridSelection {
        FigureGridSelection(anchor: key(a.0, a.1), focus: key(b.0, b.1))
    }
    private func rendered(_ cell: Cell??) -> String? {
        guard let edit = cell, let written = edit, case .formula(let f) = written.content else { return nil }
        return FormulaParser.render(f, in: table)
    }

    func test_fillDown_copiesTheTopRowIntoTheRest_translatingFormulas() throws {
        table.setCell(num(7), at: key(0, 0))
        var formatted = try formula("A1*2+$A$1")
        formatted.format.zeroAsDash = true
        formatted.alignment = .right
        table.setCell(formatted, at: key(0, 1))
        let edits = FigureFill.edits(table: table, selection: selection((0, 0), (2, 1)), direction: .down, names: .empty)
        XCTAssertEqual(Set(edits.keys), [key(1, 0), key(2, 0), key(1, 1), key(2, 1)])
        XCTAssertEqual(edits[key(1, 0)], .some(num(7)))
        XCTAssertEqual(rendered(edits[key(1, 1)]), "A2*2+$A$1")
        XCTAssertEqual(rendered(edits[key(2, 1)]), "A3*2+$A$1", "relative parts move, $ parts stay")
        XCTAssertEqual(edits[key(2, 1)]??.format.zeroAsDash, true, "the head's format travels with it")
        XCTAssertEqual(edits[key(2, 1)]??.alignment, .right)
    }

    func test_fillRight_copiesTheLeftColumn() throws {
        table.setCell(try formula("A1+1"), at: key(1, 0))
        let edits = FigureFill.edits(table: table, selection: selection((1, 2), (1, 0)), direction: .right, names: .empty)
        XCTAssertEqual(Set(edits.keys), [key(1, 1), key(1, 2)], "anchor and focus in either order")
        XCTAssertEqual(rendered(edits[key(1, 1)]), "B1+1")
        XCTAssertEqual(rendered(edits[key(1, 2)]), "C1+1")
    }

    /// Excel: a one-row selection fills down from the row above it, a
    /// one-column selection right from the column to its left.
    func test_aOneDeepSelectionFillsFromTheRowAboveOrColumnLeft() throws {
        table.setCell(try formula("B1"), at: key(0, 0))
        table.setCell(num(5), at: key(0, 1))
        let down = FigureFill.edits(table: table, selection: selection((1, 0), (1, 1)), direction: .down, names: .empty)
        XCTAssertEqual(rendered(down[key(1, 0)]), "B2")
        XCTAssertEqual(down[key(1, 1)], .some(num(5)))
        XCTAssertFalse(down.keys.contains(key(0, 0)), "the row above is the source, never written")

        table.setCell(num(9), at: key(2, 0))
        let right = FigureFill.edits(table: table, selection: selection((2, 1), (2, 1)), direction: .right, names: .empty)
        XCTAssertEqual(right, [key(2, 1): .some(num(9))])
    }

    func test_atTheTopRowOrFirstColumn_aOneDeepFillHasNothingToFillFrom() {
        table.setCell(num(1), at: key(0, 0))
        XCTAssertEqual(FigureFill.edits(table: table, selection: selection((0, 0), (0, 2)), direction: .down, names: .empty), [:])
        XCTAssertEqual(FigureFill.edits(table: table, selection: selection((0, 0), (3, 0)), direction: .right, names: .empty), [:])
    }

    func test_anEmptyHeadClears_andAnUnchangedCellIsLeftOut() {
        table.setCell(num(1), at: key(1, 0))
        table.setCell(num(2), at: key(2, 1))
        table.setCell(num(2), at: key(1, 1))
        let edits = FigureFill.edits(table: table, selection: selection((0, 0), (2, 1)), direction: .down, names: .empty)
        XCTAssertEqual(edits[key(1, 0)], .some(nil), "an empty head clears the cell")
        XCTAssertEqual(edits[key(2, 1)], .some(nil))
        XCTAssertEqual(edits[key(1, 1)], .some(nil))
        XCTAssertFalse(edits.keys.contains(key(2, 0)), "already empty: nothing to write")
    }

    func test_aRefPushedOffTheGridIsREF() throws {
        table.setCell(try formula("A4"), at: key(0, 0))
        let edits = FigureFill.edits(table: table, selection: selection((0, 0), (1, 0)), direction: .down, names: .empty)
        XCTAssertEqual(rendered(edits[key(1, 0)]), "#REF!")
    }

    func test_aSelectionCornerNotLiveFillsNothing() {
        table.setCell(num(1), at: key(0, 0))
        let gone = CellKey(row: RowID("zzzzzzzz"), column: table.columns[0])
        XCTAssertEqual(FigureFill.edits(table: table, selection: FigureGridSelection(anchor: key(0, 0), focus: gone),
                                        direction: .down, names: .empty), [:])
    }
}
