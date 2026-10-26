import XCTest
@testable import MaughamCore

/// **The grid's keys** (report plan 7c Task 2, spec §6.3): every row of the
/// keys table, table-driven, on a 4×3 fixture whose first row is the header
/// and last the total row, plus the empty table, a single cell, and a table
/// changed under the selection.
final class FigureGridModelTests: XCTestCase {

    // MARK: Fixture

    /// Rows r0…r(rows-1), columns c0…c(columns-1).
    private static func table(rows: Int, columns: Int, header: Int = 0, total: Bool = false) -> FigureTable {
        var t = FigureTable(rows: 0, columns: 0)
        var prevRow: RowID?
        for r in 0..<rows { t.insertRow(RowID("r\(r)"), after: prevRow); prevRow = RowID("r\(r)") }
        var prevColumn: ColumnID?
        for c in 0..<columns { t.insertColumn(ColumnID("c\(c)"), after: prevColumn); prevColumn = ColumnID("c\(c)") }
        t.headerRows = header
        t.hasTotalRow = total
        return t
    }

    /// Four rows (r0 the header, r3 the total) by three columns.
    private static let fixture = table(rows: 4, columns: 3, header: 1, total: true)

    private static func k(_ r: Int, _ c: Int) -> CellKey { CellKey(row: RowID("r\(r)"), column: ColumnID("c\(c)")) }
    private func k(_ r: Int, _ c: Int) -> CellKey { Self.k(r, c) }

    /// A cell's own contents as the model asks for them: "r1c2".
    private static let contents: (CellKey) -> String = { $0.row.raw + $0.column.raw }

    private static func model(_ t: FigureTable = fixture) -> FigureGridModel {
        FigureGridModel(table: t, editText: contents)
    }

    // MARK: Table-driven cases

    enum Start: Equatable {
        case idle
        case typing(String)                 // began by typing over the cell
        case inCell(String)                 // began by F2 / Return / double-click
        case referenced(String, prefix: String, from: CellKey, to: CellKey)
    }

    enum Expect: Equatable {
        case idle
        case editing(CellKey, String, inCell: Bool)
        case composing(CellKey, String, reference: [CellKey]?)   // [anchor, focus]
    }

    struct Case {
        let name: String
        let anchor: CellKey
        var focus: CellKey? = nil
        var start: Start = .idle
        let key: FigureGridKey
        let effects: [FigureGridEffect]
        let anchorAfter: CellKey
        var focusAfter: CellKey? = nil
        var after: Expect = .idle
    }

    private func run(_ cases: [Case], table: FigureTable = fixture, file: StaticString = #filePath, line: UInt = #line) {
        for c in cases {
            var m = Self.model(table)
            m.selection = FigureGridSelection(anchor: c.anchor, focus: c.focus ?? c.anchor)
            switch c.start {
            case .idle: break
            case let .typing(text): m.edit = Self.state(FigureGridEdit(cell: c.anchor, text: text, inCell: false), nil)
            case let .inCell(text): m.edit = Self.state(FigureGridEdit(cell: c.anchor, text: text, inCell: true), nil)
            case let .referenced(text, prefix, from, to):
                m.edit = .composing(FigureGridEdit(cell: c.anchor, text: text, inCell: false),
                                    reference: FigureGridReference(anchor: from, focus: to, prefix: prefix))
            }
            let effects = m.reduce(c.key)
            XCTAssertEqual(effects, c.effects, "\(c.name): effects", file: file, line: line)
            XCTAssertEqual(m.selection?.anchor, c.anchorAfter, "\(c.name): anchor", file: file, line: line)
            XCTAssertEqual(m.selection?.focus, c.focusAfter ?? c.anchorAfter, "\(c.name): focus", file: file, line: line)
            XCTAssertEqual(Self.describe(m.edit), c.after, "\(c.name): edit state", file: file, line: line)
        }
    }

    private static func state(_ e: FigureGridEdit, _ ref: FigureGridReference?) -> FigureGridEditState {
        e.text.hasPrefix("=") ? .composing(e, reference: ref) : .editing(e)
    }

    private static func describe(_ s: FigureGridEditState) -> Expect {
        switch s {
        case .idle: .idle
        case let .editing(e): .editing(e.cell, e.text, inCell: e.inCell)
        case let .composing(e, ref): .composing(e.cell, e.text, reference: ref.map { [$0.anchor, $0.focus] })
        }
    }

    // MARK: ← → ↑ ↓ move between cells

    func test_arrowsMoveBetweenCellsAndStopAtTheEdges() {
        run([
            Case(name: "right", anchor: k(1, 0), key: .arrow(.right, extend: false),
                 effects: [.moveSelection(to: k(1, 1)), .scrollTo(k(1, 1))], anchorAfter: k(1, 1)),
            Case(name: "left", anchor: k(1, 1), key: .arrow(.left, extend: false),
                 effects: [.moveSelection(to: k(1, 0)), .scrollTo(k(1, 0))], anchorAfter: k(1, 0)),
            Case(name: "right at the last column", anchor: k(1, 2), key: .arrow(.right, extend: false),
                 effects: [], anchorAfter: k(1, 2)),
            Case(name: "left at the first column", anchor: k(2, 0), key: .arrow(.left, extend: false),
                 effects: [], anchorAfter: k(2, 0)),
            Case(name: "up from the body into the header row", anchor: k(1, 1), key: .arrow(.up, extend: false),
                 effects: [.moveSelection(to: k(0, 1)), .scrollTo(k(0, 1))], anchorAfter: k(0, 1)),
            Case(name: "up at the header (first) row", anchor: k(0, 1), key: .arrow(.up, extend: false),
                 effects: [], anchorAfter: k(0, 1)),
            Case(name: "down into the total row", anchor: k(2, 1), key: .arrow(.down, extend: false),
                 effects: [.moveSelection(to: k(3, 1)), .scrollTo(k(3, 1))], anchorAfter: k(3, 1)),
            Case(name: "down at the total (last) row", anchor: k(3, 1), key: .arrow(.down, extend: false),
                 effects: [], anchorAfter: k(3, 1)),
            Case(name: "a range collapses, moving from the active cell (its anchor)",
                 anchor: k(1, 0), focus: k(2, 2), key: .arrow(.right, extend: false),
                 effects: [.moveSelection(to: k(1, 1)), .scrollTo(k(1, 1))], anchorAfter: k(1, 1)),
            Case(name: "a range at the edge collapses onto its active cell",
                 anchor: k(1, 2), focus: k(2, 0), key: .arrow(.right, extend: false),
                 effects: [.moveSelection(to: k(1, 2)), .scrollTo(k(1, 2))], anchorAfter: k(1, 2)),
        ])
    }

    // MARK: ⇧ + arrows extend the selection

    func test_shiftArrowsExtendFromTheFocusAndKeepTheAnchor() {
        run([
            Case(name: "⇧right", anchor: k(1, 0), key: .arrow(.right, extend: true),
                 effects: [.extendSelection(to: k(1, 1)), .scrollTo(k(1, 1))], anchorAfter: k(1, 0), focusAfter: k(1, 1)),
            Case(name: "⇧down into the total row", anchor: k(1, 1), focus: k(2, 1), key: .arrow(.down, extend: true),
                 effects: [.extendSelection(to: k(3, 1)), .scrollTo(k(3, 1))], anchorAfter: k(1, 1), focusAfter: k(3, 1)),
            Case(name: "⇧down at the last row", anchor: k(1, 1), focus: k(3, 1), key: .arrow(.down, extend: true),
                 effects: [], anchorAfter: k(1, 1), focusAfter: k(3, 1)),
            Case(name: "⇧left back across the anchor", anchor: k(1, 1), key: .arrow(.left, extend: true),
                 effects: [.extendSelection(to: k(1, 0)), .scrollTo(k(1, 0))], anchorAfter: k(1, 1), focusAfter: k(1, 0)),
            Case(name: "⇧up into the header row", anchor: k(2, 2), focus: k(1, 2), key: .arrow(.up, extend: true),
                 effects: [.extendSelection(to: k(0, 2)), .scrollTo(k(0, 2))], anchorAfter: k(2, 2), focusAfter: k(0, 2)),
        ])
    }

    // MARK: Tab / ⇧Tab

    func test_tabMovesRightAndWrapsToTheNextRow_shiftTabLeftAndWrapsBack() {
        run([
            Case(name: "tab", anchor: k(1, 0), key: .tab(backward: false),
                 effects: [.moveSelection(to: k(1, 1)), .scrollTo(k(1, 1))], anchorAfter: k(1, 1)),
            Case(name: "tab in the last column wraps to the next row's first cell", anchor: k(1, 2), key: .tab(backward: false),
                 effects: [.moveSelection(to: k(2, 0)), .scrollTo(k(2, 0))], anchorAfter: k(2, 0)),
            Case(name: "tab from the header's last column wraps into the body", anchor: k(0, 2), key: .tab(backward: false),
                 effects: [.moveSelection(to: k(1, 0)), .scrollTo(k(1, 0))], anchorAfter: k(1, 0)),
            Case(name: "tab in the table's last cell stays", anchor: k(3, 2), key: .tab(backward: false),
                 effects: [], anchorAfter: k(3, 2)),
            Case(name: "⇧tab", anchor: k(1, 1), key: .tab(backward: true),
                 effects: [.moveSelection(to: k(1, 0)), .scrollTo(k(1, 0))], anchorAfter: k(1, 0)),
            Case(name: "⇧tab in the first column wraps to the previous row's last cell", anchor: k(2, 0), key: .tab(backward: true),
                 effects: [.moveSelection(to: k(1, 2)), .scrollTo(k(1, 2))], anchorAfter: k(1, 2)),
            Case(name: "⇧tab in the first cell stays", anchor: k(0, 0), key: .tab(backward: true),
                 effects: [], anchorAfter: k(0, 0)),
            Case(name: "tab collapses a range, moving from its active cell", anchor: k(1, 0), focus: k(2, 1),
                 key: .tab(backward: false),
                 effects: [.moveSelection(to: k(1, 1)), .scrollTo(k(1, 1))], anchorAfter: k(1, 1)),
        ])
    }

    // MARK: Return / ⇧Return, and Return on a selected cell edits

    func test_returnOnASelectedCellEdits_shiftReturnMovesUp() {
        run([
            Case(name: "return on a selected cell edits inside it", anchor: k(1, 1), key: .returnKey(backward: false),
                 effects: [.beginEdit(cell: k(1, 1), text: "r1c1")], anchorAfter: k(1, 1),
                 after: .editing(k(1, 1), "r1c1", inCell: true)),
            Case(name: "⇧return moves up", anchor: k(2, 1), key: .returnKey(backward: true),
                 effects: [.moveSelection(to: k(1, 1)), .scrollTo(k(1, 1))], anchorAfter: k(1, 1)),
            Case(name: "⇧return at the header row stays", anchor: k(0, 1), key: .returnKey(backward: true),
                 effects: [], anchorAfter: k(0, 1)),
        ])
    }

    func test_returnWhileEditingCommitsAndMovesDown_shiftReturnUp() {
        run([
            Case(name: "return commits and moves down", anchor: k(1, 1), start: .typing("4"), key: .returnKey(backward: false),
                 effects: [.commitEdit(cell: k(1, 1), text: "4"), .moveSelection(to: k(2, 1)), .scrollTo(k(2, 1))],
                 anchorAfter: k(2, 1)),
            Case(name: "return from an in-cell edit commits and moves down", anchor: k(1, 1), start: .inCell("x"),
                 key: .returnKey(backward: false),
                 effects: [.commitEdit(cell: k(1, 1), text: "x"), .moveSelection(to: k(2, 1)), .scrollTo(k(2, 1))],
                 anchorAfter: k(2, 1)),
            Case(name: "⇧return commits and moves up into the header", anchor: k(1, 1), start: .typing("4"),
                 key: .returnKey(backward: true),
                 effects: [.commitEdit(cell: k(1, 1), text: "4"), .moveSelection(to: k(0, 1)), .scrollTo(k(0, 1))],
                 anchorAfter: k(0, 1)),
            Case(name: "return in the total row commits and stays", anchor: k(3, 1), start: .typing("4"),
                 key: .returnKey(backward: false),
                 effects: [.commitEdit(cell: k(3, 1), text: "4")], anchorAfter: k(3, 1)),
            Case(name: "return with a range commits the active cell and collapses below it",
                 anchor: k(1, 1), focus: k(2, 2), start: .typing("4"), key: .returnKey(backward: false),
                 effects: [.commitEdit(cell: k(1, 1), text: "4"), .moveSelection(to: k(2, 1)), .scrollTo(k(2, 1))],
                 anchorAfter: k(2, 1)),
        ])
    }

    func test_tabWhileEditingCommitsAndMoves() {
        run([
            Case(name: "tab commits and wraps", anchor: k(1, 2), start: .typing("4"), key: .tab(backward: false),
                 effects: [.commitEdit(cell: k(1, 2), text: "4"), .moveSelection(to: k(2, 0)), .scrollTo(k(2, 0))],
                 anchorAfter: k(2, 0)),
            Case(name: "⇧tab commits and moves left", anchor: k(1, 2), start: .inCell("4"), key: .tab(backward: true),
                 effects: [.commitEdit(cell: k(1, 2), text: "4"), .moveSelection(to: k(1, 1)), .scrollTo(k(1, 1))],
                 anchorAfter: k(1, 1)),
            Case(name: "tab in the last cell commits and stays", anchor: k(3, 2), start: .typing("4"), key: .tab(backward: false),
                 effects: [.commitEdit(cell: k(3, 2), text: "4")], anchorAfter: k(3, 2)),
        ])
    }

    // MARK: typing replaces the cell

    func test_typingReplacesTheActiveCell() {
        run([
            Case(name: "a digit begins an edit holding only it", anchor: k(1, 1), key: .type("4"),
                 effects: [.beginEdit(cell: k(1, 1), text: "4")], anchorAfter: k(1, 1),
                 after: .editing(k(1, 1), "4", inCell: false)),
            Case(name: "typing in the header row", anchor: k(0, 2), key: .type("Year"),
                 effects: [.beginEdit(cell: k(0, 2), text: "Year")], anchorAfter: k(0, 2),
                 after: .editing(k(0, 2), "Year", inCell: false)),
            Case(name: "= starts a formula", anchor: k(3, 1), key: .type("="),
                 effects: [.beginEdit(cell: k(3, 1), text: "=")], anchorAfter: k(3, 1),
                 after: .composing(k(3, 1), "=", reference: nil)),
            Case(name: "typing over a range edits its active cell and keeps the range",
                 anchor: k(2, 2), focus: k(1, 0), key: .type("x"),
                 effects: [.beginEdit(cell: k(2, 2), text: "x")], anchorAfter: k(2, 2), focusAfter: k(1, 0),
                 after: .editing(k(2, 2), "x", inCell: false)),
            Case(name: "nothing typed is no edit", anchor: k(1, 1), key: .type(""),
                 effects: [], anchorAfter: k(1, 1)),
            Case(name: "typing during an edit is the field editor's", anchor: k(1, 1), start: .typing("4"), key: .type("5"),
                 effects: [.fieldEditorKeeps], anchorAfter: k(1, 1), after: .editing(k(1, 1), "4", inCell: false)),
        ])
    }

    // MARK: F2 / double-click edit inside the cell

    func test_f2AndDoubleClickEditInsideTheCell() {
        run([
            Case(name: "F2 edits the active cell with its contents", anchor: k(2, 0), key: .editInPlace,
                 effects: [.beginEdit(cell: k(2, 0), text: "r2c0")], anchorAfter: k(2, 0),
                 after: .editing(k(2, 0), "r2c0", inCell: true)),
            Case(name: "F2 while typing switches the arrows to the text caret", anchor: k(1, 1), start: .typing("4"),
                 key: .editInPlace, effects: [], anchorAfter: k(1, 1), after: .editing(k(1, 1), "4", inCell: true)),
            Case(name: "double-click on another cell selects and edits it", anchor: k(1, 1), key: .doubleClick(k(2, 2)),
                 effects: [.moveSelection(to: k(2, 2)), .scrollTo(k(2, 2)), .beginEdit(cell: k(2, 2), text: "r2c2")],
                 anchorAfter: k(2, 2), after: .editing(k(2, 2), "r2c2", inCell: true)),
            Case(name: "double-click on the selected cell edits it", anchor: k(2, 2), key: .doubleClick(k(2, 2)),
                 effects: [.beginEdit(cell: k(2, 2), text: "r2c2")],
                 anchorAfter: k(2, 2), after: .editing(k(2, 2), "r2c2", inCell: true)),
            Case(name: "double-click on another cell during an edit commits it first", anchor: k(1, 1), start: .typing("4"),
                 key: .doubleClick(k(2, 2)),
                 effects: [.commitEdit(cell: k(1, 1), text: "4"), .moveSelection(to: k(2, 2)), .scrollTo(k(2, 2)),
                           .beginEdit(cell: k(2, 2), text: "r2c2")],
                 anchorAfter: k(2, 2), after: .editing(k(2, 2), "r2c2", inCell: true)),
            Case(name: "double-click in the cell being edited is the field editor's", anchor: k(1, 1), start: .inCell("4"),
                 key: .doubleClick(k(1, 1)), effects: [.fieldEditorKeeps], anchorAfter: k(1, 1),
                 after: .editing(k(1, 1), "4", inCell: true)),
        ])
    }

    // MARK: Arrows during an edit

    func test_arrowsDuringAnEdit_commitWhenTyped_moveTheCaretWhenInCell() {
        run([
            Case(name: "arrow after typing commits and moves", anchor: k(1, 1), start: .typing("4"),
                 key: .arrow(.right, extend: false),
                 effects: [.commitEdit(cell: k(1, 1), text: "4"), .moveSelection(to: k(1, 2)), .scrollTo(k(1, 2))],
                 anchorAfter: k(1, 2)),
            Case(name: "⇧arrow after typing commits and extends", anchor: k(1, 1), start: .typing("4"),
                 key: .arrow(.down, extend: true),
                 effects: [.commitEdit(cell: k(1, 1), text: "4"), .extendSelection(to: k(2, 1)), .scrollTo(k(2, 1))],
                 anchorAfter: k(1, 1), focusAfter: k(2, 1)),
            Case(name: "arrow at the edge after typing commits and stays", anchor: k(1, 2), start: .typing("4"),
                 key: .arrow(.right, extend: false),
                 effects: [.commitEdit(cell: k(1, 2), text: "4")], anchorAfter: k(1, 2)),
            Case(name: "arrow in an in-cell edit is the text caret's", anchor: k(1, 1), start: .inCell("4"),
                 key: .arrow(.right, extend: false), effects: [.fieldEditorKeeps], anchorAfter: k(1, 1),
                 after: .editing(k(1, 1), "4", inCell: true)),
        ])
    }

    // MARK: Esc cancels the cell edit; a second Esc folds

    func test_escCancelsAnEditThenFolds() {
        run([
            Case(name: "esc with no edit folds", anchor: k(1, 1), key: .escape, effects: [.fold], anchorAfter: k(1, 1)),
            Case(name: "esc cancels a typed edit", anchor: k(1, 1), start: .typing("4"), key: .escape,
                 effects: [.cancelEdit], anchorAfter: k(1, 1)),
            Case(name: "esc cancels an in-cell edit", anchor: k(1, 1), start: .inCell("4"), key: .escape,
                 effects: [.cancelEdit], anchorAfter: k(1, 1)),
            Case(name: "esc cancels a formula with a reference", anchor: k(2, 1),
                 start: .referenced("=B2", prefix: "=", from: k(1, 1), to: k(1, 1)), key: .escape,
                 effects: [.cancelEdit], anchorAfter: k(2, 1)),
        ])
        var m = Self.model()
        m.select(k(1, 1))
        XCTAssertEqual(m.reduce(.type("4")), [.beginEdit(cell: k(1, 1), text: "4")])
        XCTAssertEqual(m.reduce(.escape), [.cancelEdit], "the first Esc cancels")
        XCTAssertEqual(m.reduce(.escape), [.fold], "the second Esc folds")
    }

    // MARK: ⌫ clears the selected cells

    func test_deleteClearsTheSelectedCells() {
        run([
            Case(name: "one cell", anchor: k(1, 1), key: .deleteBackward, effects: [.clear([k(1, 1)])], anchorAfter: k(1, 1)),
            Case(name: "a range, row by row, whichever corner is the anchor", anchor: k(2, 2), focus: k(1, 1),
                 key: .deleteBackward, effects: [.clear([k(1, 1), k(1, 2), k(2, 1), k(2, 2)])],
                 anchorAfter: k(2, 2), focusAfter: k(1, 1)),
            Case(name: "the header and total rows clear like any other", anchor: k(0, 0), focus: k(3, 0),
                 key: .deleteBackward, effects: [.clear([k(0, 0), k(1, 0), k(2, 0), k(3, 0)])],
                 anchorAfter: k(0, 0), focusAfter: k(3, 0)),
            Case(name: "⌫ during an edit is the field editor's", anchor: k(1, 1), start: .typing("45"), key: .deleteBackward,
                 effects: [.fieldEditorKeeps], anchorAfter: k(1, 1), after: .editing(k(1, 1), "45", inCell: false)),
        ])
    }

    // MARK: ⌘A selects the whole table

    func test_selectAllSelectsTheWholeTable() {
        run([
            Case(name: "⌘A", anchor: k(1, 1), key: .selectAll,
                 effects: [.moveSelection(to: k(0, 0)), .extendSelection(to: k(3, 2))],
                 anchorAfter: k(0, 0), focusAfter: k(3, 2)),
            Case(name: "⌘A when it is already selected", anchor: k(0, 0), focus: k(3, 2), key: .selectAll,
                 effects: [], anchorAfter: k(0, 0), focusAfter: k(3, 2)),
            Case(name: "⌘A during an edit selects the field's text", anchor: k(1, 1), start: .typing("45"), key: .selectAll,
                 effects: [.fieldEditorKeeps], anchorAfter: k(1, 1), after: .editing(k(1, 1), "45", inCell: false)),
        ])
    }

    // MARK: ⌘⌥ arrows insert a row above/below, a column left/right

    func test_commandOptionArrowsInsertRowsAndColumns() {
        let r = { (i: Int) in RowID("r\(i)") }, c = { (i: Int) in ColumnID("c\(i)") }
        run([
            Case(name: "row above a body row", anchor: k(2, 1), key: .insert(.up),
                 effects: [.insertRow(after: r(1))], anchorAfter: k(2, 1)),
            Case(name: "row below a body row", anchor: k(1, 1), key: .insert(.down),
                 effects: [.insertRow(after: r(1))], anchorAfter: k(1, 1)),
            Case(name: "row above the header goes below it (the header stays first)", anchor: k(0, 1), key: .insert(.up),
                 effects: [.insertRow(after: r(0))], anchorAfter: k(0, 1)),
            Case(name: "row below the total goes above it (the total stays last)", anchor: k(3, 1), key: .insert(.down),
                 effects: [.insertRow(after: r(2))], anchorAfter: k(3, 1)),
            Case(name: "row above the total row", anchor: k(3, 1), key: .insert(.up),
                 effects: [.insertRow(after: r(2))], anchorAfter: k(3, 1)),
            Case(name: "column left of the first", anchor: k(1, 0), key: .insert(.left),
                 effects: [.insertColumn(after: nil)], anchorAfter: k(1, 0)),
            Case(name: "column left of a middle one", anchor: k(1, 1), key: .insert(.left),
                 effects: [.insertColumn(after: c(0))], anchorAfter: k(1, 1)),
            Case(name: "column right of the last", anchor: k(1, 2), key: .insert(.right),
                 effects: [.insertColumn(after: c(2))], anchorAfter: k(1, 2)),
            Case(name: "a range inserts at its active cell", anchor: k(2, 0), focus: k(1, 2), key: .insert(.down),
                 effects: [.insertRow(after: r(2))], anchorAfter: k(2, 0), focusAfter: k(1, 2)),
            Case(name: "during an edit the edit commits first", anchor: k(1, 1), start: .typing("4"), key: .insert(.down),
                 effects: [.commitEdit(cell: k(1, 1), text: "4"), .insertRow(after: r(1))], anchorAfter: k(1, 1)),
        ])
    }

    func test_insertingWithoutAHeaderOrTotalRowCanReachEitherEnd() {
        let plain = Self.table(rows: 2, columns: 2)
        run([
            Case(name: "row above the first", anchor: k(0, 0), key: .insert(.up),
                 effects: [.insertRow(after: nil)], anchorAfter: k(0, 0)),
            Case(name: "row below the last", anchor: k(1, 0), key: .insert(.down),
                 effects: [.insertRow(after: RowID("r1"))], anchorAfter: k(1, 0)),
        ], table: plain)
    }

    // MARK: `=` + arrows or clicks insert and move a reference

    func test_composingAFormula_arrowsInsertAndMoveAReference() {
        run([
            Case(name: "= then ↑ references the cell above", anchor: k(2, 1), start: .typing("="),
                 key: .arrow(.up, extend: false),
                 effects: [.insertReference("B2", editText: "=B2"), .scrollTo(k(1, 1))], anchorAfter: k(2, 1),
                 after: .composing(k(2, 1), "=B2", reference: [k(1, 1), k(1, 1)])),
            Case(name: "after an open bracket ← references the cell left", anchor: k(2, 1), start: .typing("=SUM("),
                 key: .arrow(.left, extend: false),
                 effects: [.insertReference("A3", editText: "=SUM(A3"), .scrollTo(k(2, 0))], anchorAfter: k(2, 1),
                 after: .composing(k(2, 1), "=SUM(A3", reference: [k(2, 0), k(2, 0)])),
            Case(name: "after an operator and a space", anchor: k(2, 1), start: .typing("=B1 + "),
                 key: .arrow(.right, extend: false),
                 effects: [.insertReference("C3", editText: "=B1 + C3"), .scrollTo(k(2, 2))], anchorAfter: k(2, 1),
                 after: .composing(k(2, 1), "=B1 + C3", reference: [k(2, 2), k(2, 2)])),
            Case(name: "⇧arrow first references a range from the cell being edited", anchor: k(2, 1), start: .typing("=SUM("),
                 key: .arrow(.up, extend: true),
                 effects: [.insertReference("B2:B3", editText: "=SUM(B2:B3"), .scrollTo(k(1, 1))], anchorAfter: k(2, 1),
                 after: .composing(k(2, 1), "=SUM(B2:B3", reference: [k(2, 1), k(1, 1)])),
            Case(name: "a second arrow moves the reference into the header row", anchor: k(2, 1),
                 start: .referenced("=B2", prefix: "=", from: k(1, 1), to: k(1, 1)), key: .arrow(.up, extend: false),
                 effects: [.insertReference("B1", editText: "=B1"), .scrollTo(k(0, 1))], anchorAfter: k(2, 1),
                 after: .composing(k(2, 1), "=B1", reference: [k(0, 1), k(0, 1)])),
            Case(name: "⇧arrow on a reference extends it to a range", anchor: k(2, 1),
                 start: .referenced("=SUM(B1", prefix: "=SUM(", from: k(0, 1), to: k(0, 1)), key: .arrow(.down, extend: true),
                 effects: [.insertReference("B1:B2", editText: "=SUM(B1:B2"), .scrollTo(k(1, 1))], anchorAfter: k(2, 1),
                 after: .composing(k(2, 1), "=SUM(B1:B2", reference: [k(0, 1), k(1, 1)])),
            Case(name: "a plain arrow on a range reference collapses it and moves", anchor: k(3, 1),
                 start: .referenced("=SUM(B1:B2", prefix: "=SUM(", from: k(0, 1), to: k(1, 1)),
                 key: .arrow(.right, extend: false),
                 effects: [.insertReference("C2", editText: "=SUM(C2"), .scrollTo(k(1, 2))], anchorAfter: k(3, 1),
                 after: .composing(k(3, 1), "=SUM(C2", reference: [k(1, 2), k(1, 2)])),
            Case(name: "a reference at the edge stays", anchor: k(2, 1),
                 start: .referenced("=B1", prefix: "=", from: k(0, 1), to: k(0, 1)), key: .arrow(.up, extend: false),
                 effects: [], anchorAfter: k(2, 1), after: .composing(k(2, 1), "=B1", reference: [k(0, 1), k(0, 1)])),
            Case(name: "= in the first row then ↑ has nowhere to point", anchor: k(0, 1), start: .typing("="),
                 key: .arrow(.up, extend: false), effects: [], anchorAfter: k(0, 1),
                 after: .composing(k(0, 1), "=", reference: nil)),
            Case(name: "a formula not at an operator commits on an arrow", anchor: k(1, 1), start: .typing("=1"),
                 key: .arrow(.down, extend: false),
                 effects: [.commitEdit(cell: k(1, 1), text: "=1"), .moveSelection(to: k(2, 1)), .scrollTo(k(2, 1))],
                 anchorAfter: k(2, 1)),
            Case(name: "a formula edited in the cell keeps its arrows for the caret", anchor: k(1, 1), start: .inCell("=SUM("),
                 key: .arrow(.down, extend: false), effects: [.fieldEditorKeeps], anchorAfter: k(1, 1),
                 after: .composing(k(1, 1), "=SUM(", reference: nil)),
            Case(name: "return commits the formula with its reference", anchor: k(2, 1),
                 start: .referenced("=B2", prefix: "=", from: k(1, 1), to: k(1, 1)), key: .returnKey(backward: false),
                 effects: [.commitEdit(cell: k(2, 1), text: "=B2"), .moveSelection(to: k(3, 1)), .scrollTo(k(3, 1))],
                 anchorAfter: k(3, 1)),
        ])
    }

    func test_composingAFormula_clicksInsertAndMoveAReference() {
        run([
            Case(name: "a click after = references the clicked cell", anchor: k(3, 1), start: .typing("="),
                 key: .click(k(1, 2), extend: false),
                 effects: [.insertReference("C2", editText: "=C2"), .scrollTo(k(1, 2))], anchorAfter: k(3, 1),
                 after: .composing(k(3, 1), "=C2", reference: [k(1, 2), k(1, 2)])),
            Case(name: "a click moves an inserted reference", anchor: k(3, 1),
                 start: .referenced("=SUM(B1", prefix: "=SUM(", from: k(0, 1), to: k(0, 1)), key: .click(k(0, 2), extend: false),
                 effects: [.insertReference("C1", editText: "=SUM(C1"), .scrollTo(k(0, 2))], anchorAfter: k(3, 1),
                 after: .composing(k(3, 1), "=SUM(C1", reference: [k(0, 2), k(0, 2)])),
            Case(name: "a ⇧click (or drag) stretches the reference to a range", anchor: k(3, 1),
                 start: .referenced("=SUM(B1", prefix: "=SUM(", from: k(0, 1), to: k(0, 1)), key: .click(k(2, 1), extend: true),
                 effects: [.insertReference("B1:B3", editText: "=SUM(B1:B3"), .scrollTo(k(2, 1))], anchorAfter: k(3, 1),
                 after: .composing(k(3, 1), "=SUM(B1:B3", reference: [k(0, 1), k(2, 1)])),
            Case(name: "a double-click while composing is a click", anchor: k(3, 1), start: .typing("=SUM("),
                 key: .doubleClick(k(1, 0)),
                 effects: [.insertReference("A2", editText: "=SUM(A2"), .scrollTo(k(1, 0))], anchorAfter: k(3, 1),
                 after: .composing(k(3, 1), "=SUM(A2", reference: [k(1, 0), k(1, 0)])),
            Case(name: "a click when the formula is not at an operator commits and selects", anchor: k(3, 1), start: .typing("=1"),
                 key: .click(k(1, 2), extend: false),
                 effects: [.commitEdit(cell: k(3, 1), text: "=1"), .moveSelection(to: k(1, 2)), .scrollTo(k(1, 2))],
                 anchorAfter: k(1, 2)),
        ])
    }

    func test_typingAfterAReferenceFixesItAndTheNextArrowStartsAnother() {
        var m = Self.model()
        m.select(k(2, 1))
        _ = m.reduce(.type("="))
        XCTAssertEqual(m.reduce(.arrow(.up, extend: false)), [.insertReference("B2", editText: "=B2"), .scrollTo(k(1, 1))])
        XCTAssertEqual(m.reduce(.editTextChanged("=B2+")), [])
        XCTAssertEqual(Self.describe(m.edit), .composing(k(2, 1), "=B2+", reference: nil), "typing fixed the reference")
        XCTAssertEqual(m.reduce(.arrow(.left, extend: false)),
                       [.insertReference("A3", editText: "=B2+A3"), .scrollTo(k(2, 0))],
                       "the next reference starts again from the cell being edited")
    }

    func test_editTextChangesMoveBetweenEditingAndComposing() {
        var m = Self.model()
        m.select(k(1, 1))
        _ = m.reduce(.type("4"))
        XCTAssertEqual(m.reduce(.editTextChanged("=")), [])
        XCTAssertEqual(Self.describe(m.edit), .composing(k(1, 1), "=", reference: nil))
        XCTAssertEqual(m.reduce(.editTextChanged("12")), [])
        XCTAssertEqual(Self.describe(m.edit), .editing(k(1, 1), "12", inCell: false))
        // An unchanged text keeps a reference it holds.
        _ = m.reduce(.editTextChanged("="))
        _ = m.reduce(.arrow(.up, extend: false))
        XCTAssertEqual(m.reduce(.editTextChanged("=B1")), [])
        XCTAssertEqual(Self.describe(m.edit), .composing(k(1, 1), "=B1", reference: [k(0, 1), k(0, 1)]))
        // With no edit open, a text change is nothing.
        var idle = Self.model()
        idle.select(k(1, 1))
        XCTAssertEqual(idle.reduce(.editTextChanged("x")), [])
        XCTAssertEqual(Self.describe(idle.edit), .idle)
    }

    // MARK: Clicks (and drag) select

    func test_clicksSelectAndExtend() {
        run([
            Case(name: "click", anchor: k(1, 1), key: .click(k(2, 2), extend: false),
                 effects: [.moveSelection(to: k(2, 2)), .scrollTo(k(2, 2))], anchorAfter: k(2, 2)),
            Case(name: "⇧click or drag extends", anchor: k(1, 1), key: .click(k(3, 2), extend: true),
                 effects: [.extendSelection(to: k(3, 2)), .scrollTo(k(3, 2))], anchorAfter: k(1, 1), focusAfter: k(3, 2)),
            Case(name: "a click on the selected cell changes nothing", anchor: k(1, 1), key: .click(k(1, 1), extend: false),
                 effects: [], anchorAfter: k(1, 1)),
            Case(name: "a click on a cell not in the table is nothing", anchor: k(1, 1),
                 key: .click(CellKey(row: RowID("gone"), column: ColumnID("c0")), extend: false),
                 effects: [], anchorAfter: k(1, 1)),
            Case(name: "a click during a plain edit commits it and selects", anchor: k(1, 1), start: .typing("4"),
                 key: .click(k(2, 0), extend: false),
                 effects: [.commitEdit(cell: k(1, 1), text: "4"), .moveSelection(to: k(2, 0)), .scrollTo(k(2, 0))],
                 anchorAfter: k(2, 0)),
        ])
    }

    // MARK: Edges: the empty table, a single cell

    func test_anEmptyTableHasNoSelection_onlyEscAndInsertDoAnything() {
        for t in [Self.table(rows: 0, columns: 0), Self.table(rows: 0, columns: 2), Self.table(rows: 2, columns: 0)] {
            var m = Self.model(t)
            XCTAssertNil(m.selection)
            let keys: [FigureGridKey] = [
                .arrow(.up, extend: false), .arrow(.right, extend: true), .tab(backward: false), .tab(backward: true),
                .returnKey(backward: false), .returnKey(backward: true), .type("4"), .editInPlace, .deleteBackward,
                .selectAll, .editTextChanged("x"), .click(k(0, 0), extend: false), .doubleClick(k(0, 0)),
            ]
            for key in keys {
                XCTAssertEqual(m.reduce(key), [], "\(key) on a \(t.rows.count)×\(t.columns.count) table")
            }
            XCTAssertEqual(m.reduce(.escape), [.fold])
            XCTAssertEqual(Self.describe(m.edit), .idle)
        }
        var none = Self.model(Self.table(rows: 0, columns: 0))
        XCTAssertEqual(none.reduce(.insert(.down)), [.insertRow(after: nil)])
        XCTAssertEqual(none.reduce(.insert(.up)), [.insertRow(after: nil)])
        XCTAssertEqual(none.reduce(.insert(.right)), [.insertColumn(after: nil)])
        XCTAssertEqual(none.reduce(.insert(.left)), [.insertColumn(after: nil)])
        // Rows but no columns: a row inserts at the body's end, a column first.
        var rowsOnly = Self.model(Self.table(rows: 2, columns: 0))
        XCTAssertEqual(rowsOnly.reduce(.insert(.down)), [.insertRow(after: RowID("r1"))])
        XCTAssertEqual(rowsOnly.reduce(.insert(.up)), [.insertRow(after: nil)])
        XCTAssertEqual(rowsOnly.reduce(.insert(.right)), [.insertColumn(after: nil)])
    }

    func test_aSingleCellTable() {
        let one = Self.table(rows: 1, columns: 1)
        let still: [FigureGridKey] = [
            .arrow(.up, extend: false), .arrow(.down, extend: false), .arrow(.left, extend: false),
            .arrow(.right, extend: false), .arrow(.down, extend: true), .tab(backward: false), .tab(backward: true),
            .returnKey(backward: true), .selectAll, .click(k(0, 0), extend: false),
        ]
        run(still.map { Case(name: "\($0) on one cell", anchor: k(0, 0), key: $0, effects: [], anchorAfter: k(0, 0)) }
            + [
                Case(name: "⌫ on one cell", anchor: k(0, 0), key: .deleteBackward, effects: [.clear([k(0, 0)])],
                     anchorAfter: k(0, 0)),
                Case(name: "return on one cell edits", anchor: k(0, 0), key: .returnKey(backward: false),
                     effects: [.beginEdit(cell: k(0, 0), text: "r0c0")], anchorAfter: k(0, 0),
                     after: .editing(k(0, 0), "r0c0", inCell: true)),
                Case(name: "return during an edit commits and stays", anchor: k(0, 0), start: .typing("4"),
                     key: .returnKey(backward: false), effects: [.commitEdit(cell: k(0, 0), text: "4")], anchorAfter: k(0, 0)),
                Case(name: "= then an arrow has nowhere to point", anchor: k(0, 0), start: .typing("="),
                     key: .arrow(.down, extend: false), effects: [], anchorAfter: k(0, 0),
                     after: .composing(k(0, 0), "=", reference: nil)),
                Case(name: "row above the only row", anchor: k(0, 0), key: .insert(.up),
                     effects: [.insertRow(after: nil)], anchorAfter: k(0, 0)),
            ], table: one)
    }

    func test_aNewModelSelectsTheFirstCell() {
        let m = Self.model()
        XCTAssertEqual(m.selection, FigureGridSelection(anchor: k(0, 0), focus: k(0, 0)))
        XCTAssertEqual(Self.describe(m.edit), .idle)
    }

    // MARK: The table changes under the model (by ids, not indices)

    func test_aRowDeletedElsewhereMovesTheSelectionToTheNextLiveRow() {
        var m = Self.model()
        m.select(k(1, 1))
        var t = Self.fixture
        t.deleteRow(RowID("r1"))
        XCTAssertEqual(m.tableChanged(t), [.moveSelection(to: k(2, 1))])
        XCTAssertEqual(m.selection, FigureGridSelection(anchor: k(2, 1), focus: k(2, 1)))
    }

    func test_theLastRowDeletedMovesTheSelectionUp() {
        var m = Self.model()
        m.select(k(3, 2))
        var t = Self.fixture
        t.deleteRow(RowID("r3"))
        XCTAssertEqual(m.tableChanged(t), [.moveSelection(to: k(2, 2))])
    }

    func test_aColumnDeletedMovesTheSelectionRight_aRangeKeepsBothCorners() {
        var m = Self.model()
        m.selection = FigureGridSelection(anchor: k(1, 1), focus: k(2, 2))
        var t = Self.fixture
        t.deleteColumn(ColumnID("c1"))
        XCTAssertEqual(m.tableChanged(t), [.moveSelection(to: k(1, 2)), .extendSelection(to: k(2, 2))])
    }

    func test_aSortKeepsTheSelectionOnItsRow() {
        var m = Self.model()
        m.selection = FigureGridSelection(anchor: k(1, 1), focus: k(2, 1))
        var t = Self.fixture
        t.moveRow(RowID("r1"), after: RowID("r2"))
        XCTAssertEqual(m.tableChanged(t), [], "selection is by id: the row moved, the selection went with it")
        XCTAssertEqual(m.selection, FigureGridSelection(anchor: k(1, 1), focus: k(2, 1)))
        XCTAssertEqual(m.reduce(.arrow(.up, extend: false)), [.moveSelection(to: k(2, 1)), .scrollTo(k(2, 1))],
                       "navigation reads the new order: r1 now sits below r2")
        XCTAssertEqual(m.reduce(.arrow(.up, extend: false)), [.moveSelection(to: k(0, 1)), .scrollTo(k(0, 1))])
    }

    func test_insertingARowKeepsTheSelectionAndTheControllerSelectsTheNewRow() {
        var m = Self.model()
        m.select(k(1, 1))
        var t = Self.fixture
        t.insertRow(RowID("r9"), after: RowID("r1"))
        XCTAssertEqual(m.tableChanged(t), [])
        XCTAssertEqual(m.select(CellKey(row: RowID("r9"), column: ColumnID("c1"))),
                       [.moveSelection(to: CellKey(row: RowID("r9"), column: ColumnID("c1"))),
                        .scrollTo(CellKey(row: RowID("r9"), column: ColumnID("c1")))])
        XCTAssertEqual(m.select(CellKey(row: RowID("nope"), column: ColumnID("c1"))), [], "a cell not in the table")
    }

    func test_theEditedCellDeletedElsewhereCancelsTheEdit() {
        var m = Self.model()
        m.select(k(1, 1))
        _ = m.reduce(.type("4"))
        var t = Self.fixture
        t.deleteRow(RowID("r1"))
        XCTAssertEqual(m.tableChanged(t), [.cancelEdit, .moveSelection(to: k(2, 1))])
        XCTAssertEqual(Self.describe(m.edit), .idle)
    }

    func test_aReferencedCellDeletedElsewhereDropsTheReferenceAndKeepsTheText() {
        var m = Self.model()
        m.select(k(2, 1))
        _ = m.reduce(.type("="))
        _ = m.reduce(.arrow(.up, extend: false))   // =B2, r1
        var t = Self.fixture
        t.deleteRow(RowID("r1"))
        XCTAssertEqual(m.tableChanged(t), [])
        XCTAssertEqual(Self.describe(m.edit), .composing(k(2, 1), "=B2", reference: nil))
    }

    func test_theTableEmptiedAndRefilled() {
        var m = Self.model()
        m.select(k(1, 1))
        _ = m.reduce(.type("4"))
        var empty = Self.fixture
        for r in 0..<4 { empty.deleteRow(RowID("r\(r)")) }
        XCTAssertEqual(m.tableChanged(empty), [.cancelEdit])
        XCTAssertNil(m.selection)
        var refilled = empty
        refilled.insertRow(RowID("r7"), after: nil)
        XCTAssertEqual(m.tableChanged(refilled), [.moveSelection(to: CellKey(row: RowID("r7"), column: ColumnID("c0")))])
    }

    func test_aWhollyReplacedTableSelectsItsFirstCell() {
        var m = Self.model()
        m.select(k(2, 2))
        let other = Self.table(rows: 2, columns: 2)   // the same ids r0…r1 and c0…c1, so r2 is unknown to it
        XCTAssertEqual(m.tableChanged(other), [.moveSelection(to: k(0, 0))])
    }

    // MARK: Fold and a refused commit

    func test_foldCommitsOrDiscardsAnOpenEdit() {
        var m = Self.model()
        m.select(k(1, 1))
        XCTAssertEqual(m.fold(commit: true), [.fold], "no edit: just the fold")
        _ = m.reduce(.type("4"))
        XCTAssertEqual(m.fold(commit: true), [.commitEdit(cell: k(1, 1), text: "4"), .fold])
        XCTAssertEqual(Self.describe(m.edit), .idle)
        _ = m.reduce(.type("5"))
        XCTAssertEqual(m.fold(commit: false), [.cancelEdit, .fold])
        XCTAssertEqual(Self.describe(m.edit), .idle)
    }

    func test_aRefusedCommitReopensTheEditOnItsCell() {
        var m = Self.model()
        m.select(k(1, 1))
        _ = m.reduce(.type("=SUM("))
        _ = m.reduce(.returnKey(backward: false))   // moved to r2; the controller's parse refuses
        XCTAssertEqual(m.reopenEdit(cell: k(1, 1), text: "=SUM("),
                       [.moveSelection(to: k(1, 1)), .scrollTo(k(1, 1)), .beginEdit(cell: k(1, 1), text: "=SUM(")])
        XCTAssertEqual(Self.describe(m.edit), .composing(k(1, 1), "=SUM(", reference: nil))
        XCTAssertEqual(m.reduce(.arrow(.up, extend: false)), [.fieldEditorKeeps],
                       "a reopened edit is in the cell: the arrows are the caret's")
        XCTAssertEqual(m.reopenEdit(cell: CellKey(row: RowID("gone"), column: ColumnID("c0")), text: "x"), [])
    }

    // MARK: Selection geometry

    func test_theSelectionsCellsAreItsRectangleRowByRow() {
        let s = FigureGridSelection(anchor: k(2, 2), focus: k(1, 0))
        XCTAssertEqual(s.cells(in: Self.fixture), [k(1, 0), k(1, 1), k(1, 2), k(2, 0), k(2, 1), k(2, 2)])
        XCTAssertEqual(FigureGridSelection(anchor: k(9, 9), focus: k(1, 1)).cells(in: Self.fixture), [])
        XCTAssertEqual(s.address(in: Self.fixture), "A2:C3")
    }
}
