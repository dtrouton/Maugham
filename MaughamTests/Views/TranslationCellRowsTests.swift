import XCTest
@testable import Maugham
@testable import MaughamCore

/// **What the Cells list and the inspector's Translations lines show**
/// (report plan 9e-1 Task 8): pure rows over a derived table.
final class TranslationCellRowsTests: XCTestCase {

    /// Item | Amount / Rent | 100 / Food | 50.
    private func table() -> (FigureTable, item: CellKey, rent: CellKey, food: CellKey, amount: CellKey) {
        var t = FigureTable(rows: 3, columns: 2)
        let k = { (r: Int, c: Int) in CellKey(row: t.rows[r], column: t.columns[c]) }
        t.setCell(Cell(content: .value(.text("Item"))), at: k(0, 0))
        t.setCell(Cell(content: .value(.text("Amount"))), at: k(0, 1))
        t.setCell(Cell(content: .value(.text("Rent"))), at: k(1, 0))
        t.setCell(Cell(content: .value(.number(100))), at: k(1, 1))
        t.setCell(Cell(content: .value(.text("Food"))), at: k(2, 0))
        t.setCell(Cell(content: .value(.number(50))), at: k(2, 1))
        return (t, k(0, 0), k(1, 0), k(2, 0), k(0, 1))
    }

    private func record(_ key: CellKey, _ text: String, source: String) -> TranslationRecord {
        TranslationRecord(paragraphId: FigureCellTranslationKey.paragraphId(for: key), language: "es",
                          text: text, sourceHash: TranslationHash.hash(source))
    }

    /// Each live text cell is a row at its A1 with its chip — fresh, stale
    /// (translated against an older label), missing — and numbers are never
    /// rows.
    func test_theRowsAreTheTextCellsWithTheirStatus() {
        let (t, item, rent, _, _) = table()
        let derived = FigureTranslationDeriver.derive(
            records: [record(item, "Concepto", source: "Item"), record(rent, "Alquiler", source: "Rents")],
            table: t, language: "es")
        let rows = TranslationCellRows.rows(derived, table: t)
        XCTAssertEqual(rows.map(\.address), ["A1", "B1", "A2", "A3"])
        XCTAssertEqual(rows.map(\.status), [.fresh, .missing, .stale, .missing])
        XCTAssertEqual(rows[0].translation, "Concepto")
        XCTAssertNil(rows[1].translation)
        XCTAssertEqual(rows[2].source, "Rent")
    }

    /// An orphan is listed where it stood: a cell still in the table (its
    /// label turned into a number) by its A1, a deleted row's as "Deleted
    /// cell" — both purgeable by key; a key that does not parse is listed
    /// with none.
    func test_orphansSayWhereTheyStood() {
        var (t, item, rent, food, _) = table()
        t.setCell(Cell(content: .value(.number(7))), at: item)   // text → number
        let gone = CellKey(row: RowID("zzzzzzzz"), column: rent.column)
        let junk = TranslationRecord(paragraphId: "nonsense", language: "es", text: "x",
                                     sourceHash: TranslationHash.hash(""))
        let derived = FigureTranslationDeriver.derive(
            records: [record(item, "Concepto", source: "Item"), record(gone, "Viejo", source: "Old"),
                      record(food, "Comida", source: "Food"), junk],
            table: t, language: "es")
        let orphans = TranslationCellRows.orphanRows(derived, table: t)
        XCTAssertEqual(Set(orphans.map(\.address)), ["A1", TranslationCellRows.deletedCell])
        XCTAssertEqual(orphans.first { $0.address == "A1" }?.key, item)
        XCTAssertEqual(orphans.first { $0.text == "Viejo" }?.key, gone)
        XCTAssertNil(orphans.first { $0.id == "nonsense" }?.key, "listed, with nothing to purge by")
        XCTAssertEqual(orphans.count, 3)
        XCTAssertFalse(orphans.contains { $0.text == "Comida" }, "a live cell's translation is a row, not an orphan")
    }

    /// The figure under the caret is the paragraph's first TABLE line that
    /// resolves to a registered table: an image line, a removed table (no
    /// record — inert, R4) and a plain paragraph name none.
    func test_theFigureUnderTheCaretIsARegisteredTablesLine() {
        let cash = FigureRecord(id: "fig-0a1b2c3d", name: "cash", kind: .table, piece: nil, path: "figures/cash.csv")
        let pic = FigureRecord(id: "fig-1a1b2c3d", name: "pic", kind: .image, piece: nil, path: "figures/pic.png")
        let doc = "manuscript/a.md"
        XCTAssertEqual(TranslationCellRows.tableFigure(
            inParagraph: "![Cash flows](../figures/cash.csv){#tbl:cash}", documentPath: doc, records: [cash, pic]), cash)
        XCTAssertNil(TranslationCellRows.tableFigure(
            inParagraph: "![A picture](../figures/pic.png){#fig:pic}", documentPath: doc, records: [cash, pic]))
        XCTAssertNil(TranslationCellRows.tableFigure(
            inParagraph: "![Cash flows](../figures/cash.csv){#tbl:cash}", documentPath: doc, records: [pic]),
                     "a removed table's line names nothing")
        XCTAssertNil(TranslationCellRows.tableFigure(
            inParagraph: "Plain prose.", documentPath: doc, records: [cash]))
    }

    /// A line per language, sorted, counting fresh of all text cells and
    /// saying the stale; a table with nothing to translate has no lines.
    func test_theCoverageLines() {
        let (t, item, rent, _, _) = table()
        let es = FigureTranslationDeriver.derive(
            records: [record(item, "Concepto", source: "Item"), record(rent, "Alquiler", source: "Rents")],
            table: t, language: "es")
        let fr = FigureTranslationDeriver.derive(records: [], table: t, language: "fr")
        let lines = TranslationCellRows.coverage(["fr": fr, "es": es])
        XCTAssertEqual(lines.map(\.language), ["es", "fr"])
        XCTAssertEqual(lines[0].text, "1 of 4 cells, 1 stale")
        XCTAssertEqual(lines[1].text, "0 of 4 cells")
        let numbers = FigureTable(rows: 1, columns: 1)
        XCTAssertEqual(TranslationCellRows.coverage(
            ["es": FigureTranslationDeriver.derive(records: [], table: numbers, language: "es")]), [])
    }
}
