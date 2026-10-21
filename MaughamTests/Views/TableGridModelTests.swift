// MaughamTests/Views/TableGridModelTests.swift
import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// The table grid editor's model (report foundations plan 3b Task 5): every
/// verb the sheet offers is a pure mutation here, so the sheet itself is a
/// thin view and no test presses its buttons (tripwire 33). Plus the presenter
/// that hands the sheet's answer back to the coordinator.
@MainActor
final class TableGridModelTests: XCTestCase {

    private static func request(_ block: String, taken: Set<String> = [],
                                mayWrite: Bool = true) -> TableGridRequest {
        TableGridRequest(table: TableText(parsing: block)!,
                         takenLabels: Set(taken.compactMap(ManuscriptLabel.init(reference:))),
                         mayWrite: mayWrite)
    }

    nonisolated private static let fruit = """
        | Name | Qty |
        |:--|--:|
        | Apple | 3 |
        | Kiwi | 12 |
        Table: Fruit {#tbl:fruit}
        """

    private func model(_ block: String = fruit, taken: Set<String> = [],
                       mayWrite: Bool = true) -> TableGridModel {
        TableGridModel(Self.request(block, taken: taken, mayWrite: mayWrite))
    }

    private func grid(_ m: TableGridModel) -> [[String]] {
        (0...m.bodyRowCount).map { r in (0..<m.columnCount).map { m.cell(r, $0) } }
    }

    // MARK: - Opening

    func test_opensOnTheTableAndSavesItBackUnchanged() {
        let m = model()
        XCTAssertEqual(grid(m), [["Name", "Qty"], ["Apple", "3"], ["Kiwi", "12"]])
        XCTAssertEqual(m.caption, "Fruit")
        XCTAssertEqual(m.labelName, "fruit")
        XCTAssertEqual(m.table, TableText(parsing: Self.fruit))
        XCTAssertTrue(m.canSave)
    }

    /// A long body row widens the grid: every cell typed is kept, under an
    /// empty header cell.
    func test_aRaggedTableOpensAsARectangle() {
        let m = model("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |")
        XCTAssertEqual(grid(m), [["a", "b", ""], ["1", "", ""], ["1", "2", "3"]])
        XCTAssertEqual(m.table.alignments.count, 3)
    }

    // MARK: - Rows

    func test_addRemoveAndMoveRows() {
        var m = model()
        m.addRow(after: 1)
        XCTAssertEqual(grid(m), [["Name", "Qty"], ["Apple", "3"], ["", ""], ["Kiwi", "12"]])
        XCTAssertEqual(m.selection, .init(row: 2, column: 0), "the caret goes into the new row")
        m.addRow(after: 0)
        XCTAssertEqual(grid(m)[1], ["", ""], "after the header is the first body row")

        m.removeRow(1)
        m.removeRow(2)
        XCTAssertEqual(grid(m), [["Name", "Qty"], ["Apple", "3"], ["Kiwi", "12"]])
        m.removeRow(0)
        XCTAssertEqual(grid(m)[0], ["Name", "Qty"], "the header is never removed")

        m.selection = .init(row: 2, column: 1)
        m.moveRow(2, by: -1)
        XCTAssertEqual(grid(m), [["Name", "Qty"], ["Kiwi", "12"], ["Apple", "3"]])
        XCTAssertEqual(m.selection, .init(row: 1, column: 1), "the selection follows the row")
        m.moveRow(1, by: -1)
        XCTAssertEqual(grid(m)[0], ["Name", "Qty"], "a body row never moves into the header")
        XCTAssertFalse(m.canMoveRow(1, by: -1))
        XCTAssertFalse(m.canMoveRow(2, by: 1))
        XCTAssertTrue(m.canMoveRow(1, by: 1))
    }

    func test_removingTheLastBodyRowLeavesAHeaderOnlyTable() throws {
        var m = model("| a |\n|---|\n| 1 |")
        m.selection = .init(row: 1, column: 0)
        m.removeRow(1)
        XCTAssertEqual(m.bodyRowCount, 0)
        XCTAssertEqual(m.selection, .init(row: 0, column: 0))
        XCTAssertEqual(TableText(parsing: m.table.formatted()), m.table)
    }

    // MARK: - Columns

    func test_addRemoveAndMoveColumnsCarryTheirAlignments() {
        var m = model()
        m.addColumn(after: 0)
        XCTAssertEqual(grid(m), [["Name", "", "Qty"], ["Apple", "", "3"], ["Kiwi", "", "12"]])
        XCTAssertEqual(m.table.alignments, [.leading, .none, .trailing])
        XCTAssertEqual(m.selection?.column, 1)

        m.setCell(0, 1, to: "Colour")
        m.moveColumn(2, by: -1)
        XCTAssertEqual(grid(m)[0], ["Name", "Qty", "Colour"])
        XCTAssertEqual(m.table.alignments, [.leading, .trailing, .none], "the alignment moves with it")
        XCTAssertFalse(m.canMoveColumn(2, by: 1))
        XCTAssertFalse(m.canMoveColumn(0, by: -1))

        m.removeColumn(1)
        XCTAssertEqual(grid(m), [["Name", "Colour"], ["Apple", ""], ["Kiwi", ""]])
        XCTAssertEqual(m.table.alignments, [.leading, .none])
        m.removeColumn(1)
        m.removeColumn(0)
        XCTAssertEqual(m.columnCount, 1, "a table keeps one column")
    }

    func test_setAlignmentWritesTheDelimiterRow() {
        var m = model("| a | b |\n|---|---|")
        m.setAlignment(.center, ofColumn: 0)
        m.setAlignment(.trailing, ofColumn: 1)
        XCTAssertEqual(m.table.formatted(), "| a   | b   |\n| :-: | --: |")
    }

    // MARK: - Header, caption and cells

    func test_theHeaderIsEditedLikeAnyRowAndANewlineInACellIsASpace() {
        var m = model()
        m.setCell(0, 0, to: "Fruit name")
        m.setCell(1, 1, to: "three\nor four")
        XCTAssertEqual(m.table.header, ["Fruit name", "Qty"])
        XCTAssertEqual(m.table.rows[0], ["Apple", "three or four"])
        m.setCell(9, 9, to: "nowhere")
        XCTAssertEqual(m.cell(9, 9), "", "a cell that is not there reads empty and takes nothing")
    }

    func test_captionAndLabel() {
        var m = model()
        m.caption = "  Fruit\nsold  "
        m.labelName = "tbl:sales"
        XCTAssertEqual(m.table.caption, "Fruit sold")
        XCTAssertEqual(m.table.label, ManuscriptLabel(reference: "tbl:sales"),
                       "a typed tbl: prefix is not doubled")
        m.caption = ""
        XCTAssertNil(m.table.caption)
        XCTAssertTrue(m.table.formatted().hasSuffix("\nTable: {#tbl:sales}"),
                      "a label with no caption survives (review focus 3)")
        m.labelName = ""
        XCTAssertNil(m.table.label)
        XCTAssertFalse(m.table.formatted().contains("Table:"))
    }

    // MARK: - The label's validation

    func test_theLabelMustBeAValidName() {
        var m = model()
        for bad in ["-lead", "has space", "ünï", "a.b", "tbl:x y"] {
            m.labelName = bad
            XCTAssertNotNil(m.labelProblem, bad)
            XCTAssertFalse(m.canSave, bad)
        }
        for good in ["sales", "Q3-2026", "a_b", "9lives", ""] {
            m.labelName = good
            XCTAssertNil(m.labelProblem, good)
            XCTAssertTrue(m.canSave, good)
        }
    }

    /// Unique against the project (the index's labels and this document's),
    /// excluding this table's own label — which `takenLabels` never holds.
    func test_theLabelMustNotRepeatAnotherInTheProject() {
        var m = model(taken: ["tbl:other", "fig:map"])
        XCTAssertNil(m.labelProblem, "its own label, fruit, is free")
        m.labelName = "other"
        XCTAssertEqual(m.labelProblem, "tbl:other is already a label in this project.")
        XCTAssertFalse(m.canSave)
        m.labelName = "map"
        XCTAssertNil(m.labelProblem, "fig:map is another kind's name")
    }

    func test_aReadOnlyGridCannotSave() {
        let m = model(mayWrite: false)
        XCTAssertFalse(m.mayWrite)
        XCTAssertFalse(m.canSave, "the read-only posture disables Save")
    }

    // MARK: - Paste Cells

    /// Review focus 3: pasted cells with tabs and quotes land in the right
    /// cells, filling from the selected one and growing the table.
    func test_pastedCellsFillFromTheSelectionAndGrowTheTable() {
        var m = model()
        m.selection = .init(row: 2, column: 1)
        m.pasteCells(tabSeparated: "\"12\t(dozen)\"\tlocal\r\n\"say \"\"ripe\"\"\"\t\"two\nlines\"\r\n")
        XCTAssertEqual(grid(m), [
            ["Name", "Qty", ""],
            ["Apple", "3", ""],
            ["Kiwi", "12\t(dozen)", "local"],
            ["", "say \"ripe\"", "two lines"],
        ])
        XCTAssertEqual(m.table.alignments, [.leading, .trailing, .none])
        XCTAssertEqual(m.selection, .init(row: 2, column: 1))
        let back = TableText(parsing: m.table.formatted())
        XCTAssertEqual(back?.rows[1], ["Kiwi", "12\t(dozen)", "local"], "a tab inside a cell stays in it")
    }

    func test_pasteWithNoSelectionFillsFromTheHeader() {
        var m = model("| a |\n|---|")
        m.pasteCells(tabSeparated: "Region\tSales\nNorth\t10\nSouth\t7\n")
        XCTAssertEqual(grid(m), [["Region", "Sales"], ["North", "10"], ["South", "7"]])
    }

    func test_pastingNothingChangesNothing() {
        var m = model()
        let before = m
        m.pasteCells(tabSeparated: "")
        XCTAssertEqual(m, before)
    }

    /// Paste Cells reads the spreadsheet's tab-separated flavour first, plain
    /// text otherwise.
    func test_theClipboardTextPrefersTheTabSeparatedFlavour() {
        let board = NSPasteboard(name: NSPasteboard.Name("maugham.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("plain", forType: .string)
        XCTAssertEqual(TableGridModel.clipboardText(from: board), "plain")
        board.clearContents()
        board.declareTypes([TableGridModel.tabSeparatedType, .string], owner: nil)
        board.setString("a\tb", forType: TableGridModel.tabSeparatedType)
        board.setString("a b", forType: .string)
        XCTAssertEqual(TableGridModel.clipboardText(from: board), "a\tb")
    }

    // MARK: - The presenter

    func test_thePresenterHandsTheSheetsAnswerBack() async {
        let presenter = TableGridPresenter()
        let request = Self.request(Self.fruit)
        let edited = TableText(header: ["x"], alignments: [.none], rows: [])
        let answer = Task { await presenter.present(request) }
        while presenter.session == nil { await Task.yield() }
        XCTAssertEqual(presenter.session?.request, request, "the sheet is up on the request")
        presenter.finish(edited)
        let result = await answer.value
        XCTAssertEqual(result, edited)
        XCTAssertNil(presenter.session, "and down")
    }

    func test_aSecondPresentCancelsTheFirstAndFinishIsIdempotent() async {
        let presenter = TableGridPresenter()
        let first = Task { await presenter.present(Self.request(Self.fruit)) }
        while presenter.session == nil { await Task.yield() }
        let second = Task { await presenter.present(Self.request("| a |\n|---|")) }
        let firstResult = await first.value
        XCTAssertNil(firstResult, "the first is cancelled")
        while presenter.session?.request.table.header != ["a"] { await Task.yield() }
        presenter.finish(nil)
        presenter.finish(nil)
        let secondResult = await second.value
        XCTAssertNil(secondResult)
    }
}
