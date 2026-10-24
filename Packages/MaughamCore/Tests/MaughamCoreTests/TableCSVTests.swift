import XCTest
@testable import MaughamCore

private struct NoPins: ResearchPinSource {
    func pinnedValue(research name: String, row: Int, column: Int) -> CellValue? { nil }
}

final class TableCSVTests: XCTestCase {
    private let gb = TableLocale(languageTag: "en-GB")

    private func key(_ t: FigureTable, _ a1: String) -> CellKey {
        let p = A1.parse(a1)!
        return CellKey(row: t.rows[p.row], column: t.columns[p.column])
    }

    private func workbookValues(_ t: FigureTable) -> Workbook {
        var wb = Workbook(pins: NoPins())
        wb.setTable(t, named: "t")
        return wb
    }

    private func render(_ t: FigureTable) -> String {
        let wb = workbookValues(t)
        return TableCSV.render(t) { wb.value(at: CellAddress(table: "t", key: $0)) }
    }

    // MARK: render

    func test_render_computedValuesQuotedAndClean() {
        var t = FigureTable(rows: 3, columns: 3)
        func set(_ a1: String, _ c: CellContent) { t.setCell(Cell(content: c), at: key(t, a1)) }
        set("A1", .value(.text("a, \"b\"\nc")))
        set("B1", .value(.number(1)))
        set("C1", .value(.number(2.5)))
        set("A2", .formula(Formula(.binary(.add, .number(0.1), .number(0.2)))))
        set("B2", .value(.date(DateSerial.serial(year: 2026, month: 10, day: 24)!)))
        if case .success(let f) = FormulaParser.parse("B1/0", in: t) { set("C2", .formula(f)) } else { XCTFail() }
        set("A3", .value(.bool(true)))
        set("B3", .value(.text(" padded ")))
        if case .success(let f) = FormulaParser.parse("B1+C1", in: t) { set("C3", .formula(f)) } else { XCTFail() }
        XCTAssertEqual(render(t), "\"a, \"\"b\"\"\nc\",1,2.5\n0.3,2026-10-24,#DIV/0!\nTRUE,\" padded \",3.5\n")
    }

    func test_render_emptyTableIsEmpty() {
        XCTAssertEqual(render(FigureTable(rows: 0, columns: 0)), "")
    }

    // MARK: rows

    func test_rows_bomCrlfAndQuotedNewline() {
        let r = TableCSV.rows("\u{FEFF}a,b\r\n\"x\ny\",\"say \"\"hi\"\"\"\r\n")
        XCTAssertEqual(r.rows, [["a", "b"], ["x\ny", "say \"hi\""]])
        XCTAssertEqual(r.separator, ",")
    }

    func test_rows_separatorDetection() {
        XCTAssertEqual(TableCSV.rows("a;b;c\n1,5;2;3").separator, ";")
        XCTAssertEqual(TableCSV.rows("a\tb\tc\n1\t2\t3").separator, "\t")
        XCTAssertEqual(TableCSV.rows("a,b;c").separator, ",")      // a tie
        XCTAssertEqual(TableCSV.rows("abc").separator, ",")        // none
        XCTAssertEqual(TableCSV.rows("\"a;b;c\",d").separator, ",") // inside quotes doesn't count
    }

    func test_rows_totalOnAwkwardInput() {
        XCTAssertEqual(TableCSV.rows("").rows, [])
        XCTAssertEqual(TableCSV.rows("a,\"unterminated\nx").rows, [["a", "unterminated\nx"]])
        XCTAssertEqual(TableCSV.rows("a,b\rc,d").rows, [["a", "b"], ["c", "d"]])   // a lone CR
        XCTAssertEqual(TableCSV.rows("a,b\n\nc").rows, [["a", "b"], [""], ["c"]])
        XCTAssertEqual(TableCSV.rows("x\"y,z").rows, [["x\"y", "z"]])
        XCTAssertEqual(TableCSV.rows("\"a\"b,c").rows, [["ab", "c"]])
        XCTAssertEqual(TableCSV.rows("\"").rows, [[""]])
    }

    // MARK: read

    func test_read_semicolonFileReadsCommaDecimals() {
        let (t, problems) = TableCSV.read("Item;Cost\nTea;1,5\nCake;2.250,75\n", locale: gb)
        XCTAssertTrue(problems.isEmpty)
        XCTAssertEqual(t.headerRows, 1)
        XCTAssertEqual(t[key(t, "B2")]?.content, .value(.number(1.5)))
        XCTAssertEqual(t[key(t, "B3")]?.content, .value(.number(2250.75)))
    }

    func test_read_unknownFunctionStaysAFormulaAndIsNameError() {
        let (t, problems) = TableCSV.read("1,2\n3,4\n\"=VLOOKUP(A1,B1:C3,2)\",\n", locale: gb)
        XCTAssertTrue(problems.isEmpty)
        guard case .formula = t[key(t, "A3")]?.content else { return XCTFail("expected a formula") }
        let wb = workbookValues(t)
        XCTAssertEqual(wb.value(at: CellAddress(table: "t", key: key(t, "A3"))), .error(.name))
    }

    func test_read_wholeColumnBecomesTextAndOneProblem() {
        let (t, problems) = TableCSV.read("1,\"=SUM(B:B)\"\n", locale: gb)
        XCTAssertEqual(t[key(t, "B1")]?.content, .value(.text("=SUM(B:B)")))
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems.first?.row, 0)
        XCTAssertEqual(problems.first?.column, 1)
    }

    func test_read_headerHeuristicBothWays() {
        XCTAssertEqual(TableCSV.read("Name,Qty\nTea,3\n", locale: gb).table.headerRows, 1)
        XCTAssertEqual(TableCSV.read("1,2\n3,4\n", locale: gb).table.headerRows, 0)
        XCTAssertEqual(TableCSV.read("Name,Qty\nTea,many\n", locale: gb).table.headerRows, 0)   // no number below
        XCTAssertEqual(TableCSV.read("Name,2\nTea,3\n", locale: gb).table.headerRows, 0)        // a number in row one
    }

    func test_read_raggedRowsArePaddedAndEmptyInputIsEmptyTable() {
        let (t, _) = TableCSV.read("a,b,c\n1\n1,2,3,4\n", locale: gb)
        XCTAssertEqual(t.rows.count, 3)
        XCTAssertEqual(t.columns.count, 4)
        XCTAssertNil(t[key(t, "C2")])
        let empty = TableCSV.read("", locale: gb)
        XCTAssertEqual(empty.table.rows.count, 0)
        XCTAssertEqual(empty.table.columns.count, 0)
        XCTAssertTrue(empty.problems.isEmpty)
    }

    func test_read_positionalRefsResolveByBounds() {
        let (t, _) = TableCSV.read("1,2,\"=SUM(A1:B1)\",\"=Z9\",\"=SUM(A1:Z9)\"\n", locale: gb)
        guard case .formula(let f) = t[key(t, "C1")]?.content, case .call(_, let args) = f.expr,
              case .range(let g) = args[0], case .id = g.start.anchor else { return XCTFail("range should resolve to ids") }
        XCTAssertEqual(FormulaParser.render(f, in: t), "SUM(A1:B1)")
        let wb = workbookValues(t)
        let at = { (a1: String) in wb.value(at: CellAddress(table: "t", key: self.key(t, a1))) }
        XCTAssertEqual(at("C1"), .number(3))
        XCTAssertEqual(at("D1"), .error(.ref))                     // outside the bounds: positional, #REF!
        guard case .formula(let d) = t[key(t, "D1")]?.content else { return XCTFail() }
        XCTAssertEqual(FormulaParser.render(d, in: t), "Z9")
        XCTAssertEqual(at("E1"), .error(.ref))
    }

    // MARK: round trips

    func test_researchRoundTrip_formulasAbsoluteRefsAndValues() {
        var t = FigureTable(rows: 4, columns: 3)
        func set(_ a1: String, _ c: CellContent) { t.setCell(Cell(content: c), at: key(t, a1)) }
        set("A1", .value(.text("Item"))); set("B1", .value(.text("Cost")))
        set("A2", .value(.text("Tea"))); set("B2", .value(.number(1.5)))
        set("A3", .value(.text("=odd"))); set("B3", .value(.number(2.25)))
        set("A4", .value(.text("Total")))
        for (a1, text) in [("B4", "SUM(B2:B3)"), ("C2", "$B$2*2"), ("C3", "IF(B3>2,\"big\",\"small\")")] {
            guard case .success(let f) = FormulaParser.parse(text, in: t) else { return XCTFail(text) }
            set(a1, .formula(f))
        }
        let csv = TableCSV.renderResearch(t)
        XCTAssertTrue(csv.contains("=SUM(B2:B3)"))
        let (back, problems) = TableCSV.read(csv, locale: gb)
        XCTAssertTrue(problems.isEmpty)
        XCTAssertEqual(back.headerRows, 1)
        let a = workbookValues(t), b = workbookValues(back)
        for r in 1...4 {
            for c in ["A", "B", "C"] {
                let a1 = "\(c)\(r)"
                XCTAssertEqual(b.value(at: CellAddress(table: "t", key: key(back, a1))),
                               a.value(at: CellAddress(table: "t", key: key(t, a1))), a1)
            }
        }
        guard case .formula(let f) = back[key(back, "B4")]?.content, case .call(_, let args) = f.expr,
              case .range(let g) = args[0], case .id(let row, _) = g.start.anchor else { return XCTFail() }
        XCTAssertEqual(row, back.rows[1])
        XCTAssertEqual(FormulaParser.render(Formula(.ref(FormulaRef(target: .this, anchor: .id(row: back.rows[1], column: back.columns[1]), rowAbsolute: true, columnAbsolute: true))), in: back), "$B$2")
        XCTAssertEqual(back[key(back, "C2")].map { FormulaParser.render(Formula(extract($0.content)), in: back) }, "$B$2*2")
    }

    private func extract(_ c: CellContent) -> FormulaExpr {
        if case .formula(let f) = c { return f.expr }
        return .missing
    }

    func test_readThenRender_isStableForValues() {
        var lines = ["Name,Qty,Price,When,Note"]
        for i in 1...19 {
            let note = i % 3 == 0 ? "\"a, \"\"q\"\"\"" : "plain \(i)"
            lines.append("Item \(i),\(i),\(Double(i) / 4 + 0.1),2026-10-\(String(format: "%02d", min(i, 28))),\(note)")
        }
        lines.append("Total,\"=SUM(B2:B20)\",\"=B2+C2\",TRUE,50%")
        let x = lines.joined(separator: "\n")
        let once = render(TableCSV.read(x, locale: gb).table)
        let twice = render(TableCSV.read(once, locale: gb).table)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.split(separator: "\n").count, 21)
    }
}
