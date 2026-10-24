import XCTest
@testable import MaughamCore

private struct StubPins: ResearchPinSource {
    var values: [String: [String: CellValue]] = [:]     // research name → "B9" → value
    func pinnedValue(research name: String, row: Int, column: Int) -> CellValue? {
        values[name]?[A1.columnLetters(column) + String(row + 1)]
    }
}

/// A pin source whose values a test can change between recalculations.
private final class MutablePins: ResearchPinSource, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: CellValue] = [:]
    func set(_ a1: String, _ v: CellValue?) { lock.lock(); store[a1] = v; lock.unlock() }
    func pinnedValue(research name: String, row: Int, column: Int) -> CellValue? {
        lock.lock(); defer { lock.unlock() }
        return store[name + "!" + A1.columnLetters(column) + String(row + 1)]
    }
}

final class WorkbookTests: XCTestCase {
    // MARK: helpers

    private func key(_ t: FigureTable, _ a1: String) -> CellKey {
        let p = A1.parse(a1)!
        return CellKey(row: t.rows[p.row], column: t.columns[p.column])
    }

    private func address(_ name: String, _ t: FigureTable, _ a1: String) -> CellAddress {
        CellAddress(table: name, key: key(t, a1))
    }

    /// Sets `a1` to a number, or to a formula when the text starts with "=".
    private func set(_ t: inout FigureTable, _ a1: String, _ text: String, figures: [String: FigureTable] = [:],
                     file: StaticString = #filePath, line: UInt = #line) {
        let k = key(t, a1)
        if text.hasPrefix("=") {
            switch FormulaParser.parse(String(text.dropFirst()), in: t, figures: figures) {
            case .success(let f): t.setCell(Cell(content: .formula(f)), at: k)
            case .failure(let e): XCTFail("unparseable \(text): \(e.message)", file: file, line: line)
            }
        } else {
            t.setCell(Cell(content: .value(.number(Double(text)!))), at: k)
        }
    }

    private func column(_ values: [Double], formulaAt a1: String? = nil, _ formula: String = "") -> FigureTable {
        var t = FigureTable(rows: max(values.count, 6), columns: 6)
        for (i, v) in values.enumerated() { set(&t, "B\(i + 1)", String(v)) }
        if let a1 { set(&t, a1, formula) }
        return t
    }

    // MARK: cross-table and research

    func test_crossTableReference_isLive() {
        var wb = Workbook(pins: StubPins())
        var cash = FigureTable(rows: 6, columns: 6)
        set(&cash, "E5", "100")
        wb.setTable(cash, named: "cashflow")
        var summary = FigureTable(rows: 2, columns: 2)
        set(&summary, "B1", "=cashflow!E5", figures: ["cashflow": cash])
        wb.setTable(summary, named: "summary")
        let b1 = address("summary", summary, "B1")
        XCTAssertEqual(wb.value(at: b1), .number(100))

        set(&cash, "E5", "250")
        let changed = wb.setTable(cash, named: "cashflow")
        XCTAssertTrue(changed.contains(b1))
        XCTAssertTrue(changed.contains(address("cashflow", cash, "E5")))
        XCTAssertEqual(wb.value(at: b1), .number(250))
    }

    /// **Which tables a re-render must follow** (report plan 6a Task 7): every
    /// table whose formulas name the changed one, directly or through another,
    /// never the table itself; a table that names a figure not yet in the
    /// workbook still counts, so it re-renders when that figure arrives.
    func test_tablesReading_followsFormulasTransitively() {
        var wb = Workbook(pins: StubPins())
        var cash = FigureTable(rows: 6, columns: 6)
        set(&cash, "E5", "100")
        wb.setTable(cash, named: "cashflow")
        var summary = FigureTable(rows: 2, columns: 2)
        set(&summary, "B1", "=cashflow!E5", figures: ["cashflow": cash])
        wb.setTable(summary, named: "summary")
        var report = FigureTable(rows: 2, columns: 2)
        set(&report, "A1", "=summary!B1", figures: ["summary": summary])
        wb.setTable(report, named: "report")
        var loose = FigureTable(rows: 2, columns: 2)
        set(&loose, "A1", "=A2")
        wb.setTable(loose, named: "loose")

        XCTAssertEqual(wb.tablesReading("cashflow"), ["summary", "report"])
        XCTAssertEqual(wb.tablesReading("summary"), ["report"])
        XCTAssertEqual(wb.tablesReading("report"), [])
        XCTAssertEqual(wb.tablesReading("loose"), [], "a table reading only itself is nobody's dependant")

        var waiting = FigureTable(rows: 2, columns: 2)
        set(&waiting, "A1", "=later!A1", figures: ["later": FigureTable(rows: 2, columns: 2)])
        wb.setTable(waiting, named: "waiting")
        XCTAssertEqual(wb.tablesReading("later"), ["waiting"], "a missing table's readers are known")
    }

    func test_researchRef_readsPin_andPinsChangedRecalculates() {
        let pins = MutablePins()
        pins.set("model-v3!B9", .number(7))
        var wb = Workbook(pins: pins)
        var t = FigureTable(rows: 2, columns: 2)
        set(&t, "A1", "=research:model-v3!B9*2")
        set(&t, "A2", "=SUM(research:model-v3!B9:B10)")
        pins.set("model-v3!B10", .number(1))
        wb.setTable(t, named: "t")
        let a1 = address("t", t, "A1"), a2 = address("t", t, "A2")
        XCTAssertEqual(wb.value(at: a1), .number(14))
        XCTAssertEqual(wb.value(at: a2), .number(8))

        pins.set("model-v3!B9", .number(10))
        XCTAssertEqual(wb.pinsChanged(research: "other"), [])
        XCTAssertEqual(wb.lastEvaluationCount, 0)
        let changed = wb.pinsChanged(research: "model-v3")
        XCTAssertEqual(changed, [a1, a2])
        XCTAssertEqual(wb.lastEvaluationCount, 2)
        XCTAssertEqual(wb.value(at: a1), .number(20))
        XCTAssertEqual(wb.value(at: a2), .number(11))
    }

    func test_missingResearchPin_isREF() {
        var wb = Workbook(pins: StubPins(values: ["model": ["A1": .number(1)]]))
        var t = FigureTable(rows: 3, columns: 1)
        set(&t, "A1", "=research:model!B9")
        set(&t, "A2", "=SUM(research:model!A1:A2)")      // A2 has no pin
        set(&t, "A3", "=research:model!A1")
        wb.setTable(t, named: "t")
        XCTAssertEqual(wb.value(at: address("t", t, "A1")), .error(.ref))
        XCTAssertEqual(wb.value(at: address("t", t, "A2")), .error(.ref))
        XCTAssertEqual(wb.value(at: address("t", t, "A3")), .number(1))
    }

    func test_missingFigure_isREF() {
        var wb = Workbook(pins: StubPins())
        var other = FigureTable(rows: 2, columns: 2)
        set(&other, "A1", "5")
        var t = FigureTable(rows: 2, columns: 1)
        set(&t, "A1", "=other!A1", figures: ["other": other])
        set(&t, "A2", "=SUM(other!A1:B2)", figures: ["other": other])
        wb.setTable(t, named: "t")
        let a1 = address("t", t, "A1"), a2 = address("t", t, "A2")
        XCTAssertEqual(wb.value(at: a1), .error(.ref))
        XCTAssertEqual(wb.value(at: a2), .error(.ref))

        // The table arriving later makes the refs live; removing it breaks them again.
        XCTAssertEqual(wb.setTable(other, named: "other").intersection([a1, a2]), [a1, a2])
        XCTAssertEqual(wb.value(at: a1), .number(5))
        XCTAssertEqual(wb.value(at: a2), .number(5))
        let changed = wb.setTable(nil, named: "other")
        XCTAssertTrue(changed.isSuperset(of: [a1, a2, address("other", other, "A1")]))
        XCTAssertEqual(wb.value(at: a1), .error(.ref))
        XCTAssertEqual(wb.value(at: address("other", other, "A1")), .empty)
    }

    // MARK: structure

    func test_deleteRangeEdgeRow_shrinksSum() {
        var wb = Workbook(pins: StubPins())
        var t = column([1, 2, 3, 4])
        set(&t, "D1", "=SUM(B1:B4)")
        set(&t, "D2", "=B3")
        set(&t, "D3", "=SUM(B4:B4)")
        wb.setTable(t, named: "t")
        let d1 = address("t", t, "D1"), d2 = address("t", t, "D2"), d3 = address("t", t, "D3")
        XCTAssertEqual(wb.value(at: d1), .number(10))

        let row4 = t.rows[3], row3 = t.rows[2]
        t.deleteRow(row4)
        var changed = wb.setTable(t, named: "t")
        XCTAssertEqual(wb.value(at: d1), .number(6))                   // shrinks, not #REF!
        XCTAssertEqual(wb.value(at: d3), .error(.ref))                  // a wholly deleted range
        XCTAssertTrue(changed.isSuperset(of: [d1, d3]))

        t.deleteRow(row3)                                               // the singly referenced row
        changed = wb.setTable(t, named: "t")
        XCTAssertEqual(wb.value(at: d2), .error(.ref))
        XCTAssertEqual(wb.value(at: d1), .number(3))
        XCTAssertTrue(changed.contains(d2))
    }

    func test_insertRowInsideRange_grows() {
        var wb = Workbook(pins: StubPins())
        var t = column([1, 2, 3, 4])
        set(&t, "D1", "=SUM(B1:B4)")
        wb.setTable(t, named: "t")
        let d1 = address("t", t, "D1")
        let new = t.insertRow(after: t.rows[1])                          // between B2 and B3
        wb.setTable(t, named: "t")
        XCTAssertEqual(wb.value(at: d1), .number(10))
        t.setCell(Cell(content: .value(.number(5))), at: CellKey(row: new, column: t.columns[1]))
        let changed = wb.setTable(t, named: "t")
        XCTAssertEqual(wb.value(at: d1), .number(15))
        XCTAssertTrue(changed.contains(d1))
        XCTAssertEqual(wb.lastEvaluationCount, 1)
    }

    func test_positionalFigureRef_followsLivePosition() {
        var wb = Workbook(pins: StubPins())
        let data = column([1, 2, 3])
        var t = FigureTable(rows: 1, columns: 1)
        guard case .success(let f) = FormulaParser.parsePositional("SUM(data!B2:B3)+data!B1") else { return XCTFail() }
        t.setCell(Cell(content: .formula(f)), at: key(t, "A1"))
        wb.setTable(data, named: "data")
        wb.setTable(t, named: "t")
        let a1 = address("t", t, "A1")
        XCTAssertEqual(wb.value(at: a1), .number(6))
        var moved = data
        moved.deleteRow(moved.rows[0])                                  // B2:B3 now reads 3 and an empty row
        wb.setTable(moved, named: "data")
        XCTAssertEqual(wb.value(at: a1), .number(5))
    }

    func test_positionalRangePartlyOffTheGrid_isREF() {
        var wb = Workbook(pins: StubPins())
        var t = FigureTable(rows: 2, columns: 2)
        set(&t, "A1", "1"); set(&t, "B1", "2")
        guard case .success(let off) = FormulaParser.parsePositional("SUM(A1:C3)"),
              case .success(let on) = FormulaParser.parsePositional("SUM(A1:B1)") else { return XCTFail() }
        t.setCell(Cell(content: .formula(off)), at: key(t, "A2"))
        t.setCell(Cell(content: .formula(on)), at: key(t, "B2"))
        wb.setTable(t, named: "t")
        XCTAssertEqual(wb.value(at: address("t", t, "A2")), .error(.ref))
        XCTAssertEqual(wb.value(at: address("t", t, "B2")), .number(3), "the same grid, wholly inside")
    }

    func test_sumifSumRange_isADependencyAfterResizing() {
        var wb = Workbook(pins: StubPins())
        var t = FigureTable(rows: 3, columns: 4)
        for (i, v) in [1, 5, 9].enumerated() { set(&t, "A\(i + 1)", String(v)) }
        for (i, v) in [10, 20, 30].enumerated() { set(&t, "B\(i + 1)", String(v)) }
        set(&t, "D1", "=SUMIF(A1:A3,\">2\",B1)")
        wb.setTable(t, named: "t")
        let d1 = address("t", t, "D1")
        XCTAssertEqual(wb.value(at: d1), .number(50))
        set(&t, "B3", "100")                                            // outside the written B1, inside the resize
        XCTAssertTrue(wb.setTable(t, named: "t").contains(d1))
        XCTAssertEqual(wb.value(at: d1), .number(120))
    }

    // MARK: cycles

    func test_selfReference_isCIRC() {
        var wb = Workbook(pins: StubPins())
        var t = FigureTable(rows: 1, columns: 1)
        set(&t, "A1", "=A1+1")
        wb.setTable(t, named: "t")
        XCTAssertEqual(wb.value(at: address("t", t, "A1")), .error(.circular))
    }

    func test_twoTableCycle_isCIRC_onBoth() {
        var wb = Workbook(pins: StubPins())
        var one = FigureTable(rows: 2, columns: 2), two = FigureTable(rows: 2, columns: 2)
        set(&one, "A1", "=two!A1+1", figures: ["two": two])
        set(&two, "A1", "=one!A1*2", figures: ["one": one])
        wb.setTable(one, named: "one")
        XCTAssertEqual(wb.value(at: address("one", one, "A1")), .error(.ref))
        let changed = wb.setTable(two, named: "two")
        XCTAssertEqual(wb.value(at: address("one", one, "A1")), .error(.circular))
        XCTAssertEqual(wb.value(at: address("two", two, "A1")), .error(.circular))
        XCTAssertTrue(changed.contains(address("one", one, "A1")))
    }

    func test_cycleThroughUntakenIfBranch_isCIRC() {
        var wb = Workbook(pins: StubPins())
        var t = FigureTable(rows: 2, columns: 1)
        set(&t, "A1", "=IF(TRUE,1,A2)")
        set(&t, "A2", "=A1")
        wb.setTable(t, named: "t")
        XCTAssertEqual(wb.value(at: address("t", t, "A1")), .error(.circular))
        XCTAssertEqual(wb.value(at: address("t", t, "A2")), .error(.circular))
    }

    func test_dependentOfCycle_isCIRC() {
        var wb = Workbook(pins: StubPins())
        var t = FigureTable(rows: 6, columns: 2)
        set(&t, "A1", "=A2")
        set(&t, "A2", "=A1")
        set(&t, "A3", "=A1+1")
        set(&t, "A4", "=IFERROR(A3,0)")                                  // R-P5-12: an ordinary error, caught
        set(&t, "B1", "4")
        set(&t, "A5", "=COUNT(A1:B3)")                                   // COUNT ignores the cycle's errors
        set(&t, "A6", "=SUM(A1:B1)")
        wb.setTable(t, named: "t")
        for a in ["A1", "A2", "A3", "A6"] { XCTAssertEqual(wb.value(at: address("t", t, a)), .error(.circular), a) }
        XCTAssertEqual(wb.value(at: address("t", t, "A4")), .number(0))
        XCTAssertEqual(wb.value(at: address("t", t, "A5")), .number(1))
    }

    func test_cycleBroken_recovers() {
        var wb = Workbook(pins: StubPins())
        var t = FigureTable(rows: 3, columns: 1)
        set(&t, "A1", "=A2")
        set(&t, "A2", "=A1")
        set(&t, "A3", "=A1*2")
        wb.setTable(t, named: "t")
        XCTAssertEqual(wb.value(at: address("t", t, "A1")), .error(.circular))
        set(&t, "A2", "5")
        let changed = wb.setTable(t, named: "t")
        XCTAssertEqual(wb.value(at: address("t", t, "A1")), .number(5))
        XCTAssertEqual(wb.value(at: address("t", t, "A3")), .number(10))
        XCTAssertEqual(changed, [address("t", t, "A1"), address("t", t, "A2"), address("t", t, "A3")])
    }

    // MARK: incremental recalculation

    func test_editOneCell_evaluatesOnlyItsDependents() {
        var t = FigureTable(rows: 1_001, columns: 10)
        let rows = t.rows, columns = t.columns
        for r in 0..<1_000 {
            for c in 0..<9 { t.setCell(Cell(content: .value(.number(1))), at: CellKey(row: rows[r], column: columns[c])) }
            let range = FormulaRange(start: FormulaRef(target: .this, anchor: .id(row: rows[r], column: columns[0])),
                                     end: FormulaRef(target: .this, anchor: .id(row: rows[r], column: columns[8])))
            t.setCell(Cell(content: .formula(Formula(.call(name: "SUM", arguments: [.range(range)])))),
                      at: CellKey(row: rows[r], column: columns[9]))
        }
        set(&t, "J1001", "=SUM(J1:J1000)")
        var wb = Workbook(pins: StubPins())
        wb.setTable(t, named: "t")
        XCTAssertEqual(wb.lastEvaluationCount, 1_001)
        XCTAssertEqual(wb.value(at: address("t", t, "J1001")), .number(9_000))

        set(&t, "A500", "11")
        let changed = wb.setTable(t, named: "t")
        XCTAssertEqual(wb.lastEvaluationCount, 2)                       // J500 and the total
        XCTAssertEqual(changed, [address("t", t, "A500"), address("t", t, "J500"), address("t", t, "J1001")])
        XCTAssertEqual(wb.value(at: address("t", t, "J1001")), .number(9_010))
    }

    func test_formatChange_evaluatesNothing() {
        var wb = Workbook(pins: StubPins())
        var t = column([1, 2])
        set(&t, "D1", "=SUM(B1:B2)")
        wb.setTable(t, named: "t")
        var cell = t[key(t, "B1")]!
        cell.format = CellFormat(number: .percent(decimals: 1))
        cell.alignment = .right
        t.setCell(cell, at: key(t, "B1"))
        var d1 = t[key(t, "D1")]!
        d1.alignment = .center
        t.setCell(d1, at: key(t, "D1"))
        XCTAssertEqual(wb.setTable(t, named: "t"), [])
        XCTAssertEqual(wb.lastEvaluationCount, 0)
    }

    // MARK: notes and markers

    func test_npvFirstFlowNote() {
        var wb = Workbook(pins: StubPins())
        var t = FigureTable(rows: 4, columns: 6)
        for (c, v) in ["B", "C", "D", "E", "F"].enumerated() { set(&t, "\(v)1", String([-100, 30, 40, 50, 60][c])) }
        set(&t, "A2", "=NPV(8%,B1:F1)")
        set(&t, "A3", "=B1+NPV(8%,C1:F1)")
        set(&t, "A4", "=NPV(8%,-100,30)")
        wb.setTable(t, named: "t")
        XCTAssertEqual(wb.notes, [.npvFirstFlowDiscounted(address("t", t, "A2")),
                                  .npvFirstFlowDiscounted(address("t", t, "A4"))])

        set(&t, "B1", "100")                                             // the note goes when the flow turns positive
        wb.setTable(t, named: "t")
        XCTAssertEqual(wb.notes, [.npvFirstFlowDiscounted(address("t", t, "A4"))])
    }

    func test_researchReaders_followsThroughTables() {
        var wb = Workbook(pins: StubPins(values: ["model-v3": ["B9": .number(3)]]))
        var cash = FigureTable(rows: 2, columns: 2)
        set(&cash, "A1", "=research:model-v3!B9")
        set(&cash, "A2", "4")
        wb.setTable(cash, named: "cashflow")
        var summary = FigureTable(rows: 2, columns: 1)
        set(&summary, "A1", "=cashflow!A1*2", figures: ["cashflow": cash])
        set(&summary, "A2", "=cashflow!A2", figures: ["cashflow": cash])
        wb.setTable(summary, named: "summary")
        XCTAssertEqual(wb.value(at: address("summary", summary, "A1")), .number(6))
        XCTAssertEqual(wb.researchReaders(), [
            address("cashflow", cash, "A1"): ["model-v3"],
            address("summary", summary, "A1"): ["model-v3"],
        ])
    }

    func test_deepChain_noStackOverflow() {
        let n = 20_000
        var t = FigureTable(rows: n, columns: 1)
        let rows = t.rows, a = t.columns[0]
        t.setCell(Cell(content: .value(.number(1))), at: CellKey(row: rows[0], column: a))
        for i in 1..<n {
            let previous = FormulaRef(target: .this, anchor: .id(row: rows[i - 1], column: a))
            t.setCell(Cell(content: .formula(Formula(.binary(.add, .ref(previous), .number(1))))),
                      at: CellKey(row: rows[i], column: a))
        }
        var wb = Workbook(pins: StubPins())
        wb.setTable(t, named: "chain")
        XCTAssertEqual(wb.lastEvaluationCount, n - 1)
        XCTAssertEqual(wb.value(at: CellAddress(table: "chain", key: CellKey(row: rows[n - 1], column: a))), .number(Double(n)))

        // A cycle closing the whole chain is #CIRC! everywhere, still without recursion.
        let last = FormulaRef(target: .this, anchor: .id(row: rows[n - 1], column: a))
        t.setCell(Cell(content: .formula(Formula(.ref(last)))), at: CellKey(row: rows[0], column: a))
        wb.setTable(t, named: "chain")
        XCTAssertEqual(wb.value(at: CellAddress(table: "chain", key: CellKey(row: rows[n / 2], column: a))), .error(.circular))
    }
}
