import XCTest
@testable import MaughamCore

private struct NoPins: ResearchPinSource {
    func pinnedValue(home: String, research: String, row: Int, column: Int) -> CellValue? { nil }
}

final class TableCSVTests: XCTestCase {
    private let gb = TableLocale(languageTag: "en-GB")

    private func key(_ t: FigureTable, _ a1: String) -> CellKey {
        let p = A1.parse(a1)!
        return CellKey(row: t.rows[p.row], column: t.columns[p.column])
    }

    private func workbookValues(_ t: FigureTable) -> Workbook {
        var wb = Workbook(pins: NoPins())
        wb.setTable(t, id: "t")
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
        let (t, problems) = TableCSV.read("Item;Cost\nTea;1,5\nCake;2.250,75\n", locale: gb, names: .empty)
        XCTAssertTrue(problems.isEmpty)
        XCTAssertEqual(t.headerRows, 1)
        XCTAssertEqual(t[key(t, "B2")]?.content, .value(.number(1.5)))
        XCTAssertEqual(t[key(t, "B3")]?.content, .value(.number(2250.75)))
    }

    /// Report plan 6b Task 6 review M-4: a tab file reads decimals as the book's language
    /// does — a European Excel's "Unicode text" export is tab-separated with decimal commas —
    /// while an English book's tab file still reads a decimal point.
    func test_read_tabFileReadsDecimalsAsTheBooksLanguage() {
        let de = TableLocale(languageTag: "de-DE")
        let (t, problems) = TableCSV.read("Posten\tBetrag\nTee\t1,5\nKuchen\t2.250,75\n", locale: de, names: .empty)
        XCTAssertTrue(problems.isEmpty)
        XCTAssertEqual(t[key(t, "B2")]?.content, .value(.number(1.5)))
        XCTAssertEqual(t[key(t, "B3")]?.content, .value(.number(2250.75)))
        let (e, _) = TableCSV.read("Item\tCost\nTea\t1.5\n", locale: gb, names: .empty)
        XCTAssertEqual(e[key(e, "B2")]?.content, .value(.number(1.5)))
    }

    /// The Use-in-document ceiling counts fields holding anything but whitespace.
    func test_nonEmptyCellCount_countsOnlyFieldsWithContent() {
        XCTAssertEqual(TableCSV.nonEmptyCellCount("a,,b\n , c\n\n"), 3)
        XCTAssertEqual(TableCSV.nonEmptyCellCount(""), 0)
        XCTAssertEqual(TableCSV.figureCellLimit, 10_000)
    }

    func test_read_unknownFunctionStaysAFormulaAndIsNameError() {
        let (t, problems) = TableCSV.read("1,2\n3,4\n\"=VLOOKUP(A1,B1:C3,2)\",\n", locale: gb, names: .empty)
        XCTAssertTrue(problems.isEmpty)
        guard case .formula = t[key(t, "A3")]?.content else { return XCTFail("expected a formula") }
        let wb = workbookValues(t)
        XCTAssertEqual(wb.value(at: CellAddress(table: "t", key: key(t, "A3"))), .error(.name))
    }

    func test_read_wholeColumnBecomesTextAndOneProblem() {
        let (t, problems) = TableCSV.read("1,\"=SUM(B:B)\"\n", locale: gb, names: .empty)
        XCTAssertEqual(t[key(t, "B1")]?.content, .value(.text("=SUM(B:B)")))
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems.first?.row, 0)
        XCTAssertEqual(problems.first?.column, 1)
    }

    func test_read_headerHeuristicBothWays() {
        XCTAssertEqual(TableCSV.read("Name,Qty\nTea,3\n", locale: gb, names: .empty).table.headerRows, 1)
        XCTAssertEqual(TableCSV.read("1,2\n3,4\n", locale: gb, names: .empty).table.headerRows, 0)
        XCTAssertEqual(TableCSV.read("Name,Qty\nTea,many\n", locale: gb, names: .empty).table.headerRows, 0)   // no number below
        XCTAssertEqual(TableCSV.read("Name,2\nTea,3\n", locale: gb, names: .empty).table.headerRows, 0)        // a number in row one
    }

    func test_read_raggedRowsArePaddedAndEmptyInputIsEmptyTable() {
        let (t, _) = TableCSV.read("a,b,c\n1\n1,2,3,4\n", locale: gb, names: .empty)
        XCTAssertEqual(t.rows.count, 3)
        XCTAssertEqual(t.columns.count, 4)
        XCTAssertNil(t[key(t, "C2")])
        let empty = TableCSV.read("", locale: gb, names: .empty)
        XCTAssertEqual(empty.table.rows.count, 0)
        XCTAssertEqual(empty.table.columns.count, 0)
        XCTAssertTrue(empty.problems.isEmpty)
    }

    func test_read_positionalRefsResolveByBounds() {
        let (t, _) = TableCSV.read("1,2,\"=SUM(A1:B1)\",\"=Z9\",\"=SUM(A1:Z9)\"\n", locale: gb, names: .empty)
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
        let csv = TableCSV.renderResearch(t, locale: gb, names: .empty)
        XCTAssertTrue(csv.contains("=SUM(B2:B3)"))
        let (back, problems) = TableCSV.read(csv, locale: gb, names: .empty)
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
        let once = render(TableCSV.read(x, locale: gb, names: .empty).table)
        let twice = render(TableCSV.read(once, locale: gb, names: .empty).table)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.split(separator: "\n").count, 21)
    }

    // MARK: fix round 1

    private func textTable(_ rows: [[String]]) -> FigureTable {
        var t = FigureTable(rows: rows.count, columns: rows.map(\.count).max() ?? 0)
        for (r, line) in rows.enumerated() {
            for (c, v) in line.enumerated() {
                t.setCell(Cell(content: .value(.text(v))), at: CellKey(row: t.rows[r], column: t.columns[c]))
            }
        }
        return t
    }

    func test_researchRoundTrip_keepsTextVerbatim() {
        let odd = ["007", "TRUE", "2026-10-24", "50%", " padded ", " =x", "=x", "'quoted", " 'x", "1.5E+20", "12", "-3"]
        let plain = ["Tea", "hello world", "Q4 plan"]
        let t = textTable([odd + plain])
        let csv = TableCSV.renderResearch(t, locale: gb, names: .empty)
        for v in plain { XCTAssertFalse(csv.contains("'" + v), v) }
        let (back, problems) = TableCSV.read(csv, locale: gb, names: .empty)
        XCTAssertTrue(problems.isEmpty)
        for (c, v) in (odd + plain).enumerated() {
            XCTAssertEqual(back[CellKey(row: back.rows[0], column: back.columns[c])]?.content, .value(.text(v)), v)
        }
    }

    func test_writer_quotesSemicolonsAndTabs_soSniffingCannotMisfire() {
        for rows in [[["a; b; c"], ["x\ty\tz"]], [["a; b; c,d", "e"], ["1", "2"]]] {
            let t = textTable(rows)
            let (back, _) = TableCSV.read(TableCSV.renderResearch(t, locale: gb, names: .empty), locale: gb, names: .empty)
            XCTAssertEqual(back.rows.count, rows.count)
            XCTAssertEqual(back.columns.count, rows[0].count)
            XCTAssertEqual(back[CellKey(row: back.rows[0], column: back.columns[0])]?.content, .value(.text(rows[0][0])))
        }
    }

    /// A "," file reads a decimal point whatever the locale. A tab file used to as well; since
    /// report plan 6b Task 6 review M-4 (controller's ruling) it reads as the locale does —
    /// see `test_read_tabFileReadsDecimalsAsTheBooksLanguage`.
    func test_commaFilesReadDecimalPoint_whateverTheLocale() {
        for tag in ["de-DE", "es-ES"] {
            let l = TableLocale(languageTag: tag)
            let (comma, _) = TableCSV.read("1.234,1.5\n", locale: l, names: .empty)
            XCTAssertEqual(comma[key(comma, "A1")]?.content, .value(.number(1.234)), tag)
            XCTAssertEqual(comma[key(comma, "B1")]?.content, .value(.number(1.5)), tag)
            let (tab, _) = TableCSV.read("1.234\t1,5\t2\n", locale: l, names: .empty)
            XCTAssertEqual(tab[key(tab, "A1")]?.content, .value(.number(1234)), tag)
            XCTAssertEqual(tab[key(tab, "B1")]?.content, .value(.number(1.5)), tag)
            let (semi, _) = TableCSV.read("1,5;1.234,5;2;3\n", locale: l, names: .empty)
            XCTAssertEqual(semi[key(semi, "A1")]?.content, .value(.number(1.5)), tag)
            XCTAssertEqual(semi[key(semi, "B1")]?.content, .value(.number(1234.5)), tag)
            // The writer's own output survives a round trip.
            var t = FigureTable(rows: 1, columns: 1)
            t.setCell(Cell(content: .value(.number(1.234))), at: key(t, "A1"))
            let back = TableCSV.read(render(t), locale: l, names: .empty).table
            XCTAssertEqual(back[key(back, "A1")]?.content, .value(.number(1.234)), tag)
        }
    }

    func test_exponentNumbersRoundTrip() {
        var t = FigureTable(rows: 1, columns: 2)
        t.setCell(Cell(content: .value(.number(1.5e20))), at: key(t, "A1"))
        t.setCell(Cell(content: .value(.number(1e-7))), at: key(t, "B1"))
        let back = TableCSV.read(render(t), locale: gb, names: .empty).table
        XCTAssertEqual(back[key(back, "A1")]?.content, .value(.number(1.5e20)))
        XCTAssertEqual(back[key(back, "B1")]?.content, .value(.number(1e-7)))
    }

    // MARK: final-review fixes

    func test_researchRoundTrip_keepsTextThatTheBooksLocaleWouldReadAsADate() {
        let cases: [(String, [String])] = [
            ("es-ES", ["enero 2026", "3 de marzo de 2026"]),
            ("en-GB", ["13/01/2026"]),
        ]
        for (tag, texts) in cases {
            let l = TableLocale(languageTag: tag)
            // Each would be a date, unescaped, in this book.
            for v in texts {
                guard case .value(.date, _) = CellInput.parse(v, locale: l) else { return XCTFail("\(v) should read as a date in \(tag)") }
            }
            let t = textTable([texts])
            let csv = TableCSV.renderResearch(t, locale: l, names: .empty)
            for v in texts { XCTAssertTrue(csv.contains("'" + v), "\(tag): \(v) escaped") }
            let (back, problems) = TableCSV.read(csv, locale: l, names: .empty)
            XCTAssertTrue(problems.isEmpty)
            for (c, v) in texts.enumerated() {
                XCTAssertEqual(back[CellKey(row: back.rows[0], column: back.columns[c])]?.content, .value(.text(v)), "\(tag): \(v)")
            }
        }
    }

    func test_read_figureRefsResolveToIds_soAnInsertAboveNeverRepointsThem() {
        var revenue = FigureTable(rows: 10, columns: 2)
        for r in 0..<10 {
            revenue.setCell(Cell(content: .value(.number(Double(r + 1) * 100))), at: CellKey(row: revenue.rows[r], column: revenue.columns[1]))
        }
        let names = FormulaNames(figures: [.init(id: "fig-rev00001", name: "revenue", table: revenue)])
        let (t, problems) = TableCSV.read("\"=revenue!B9\",\"=SUM(revenue!B1:B2)\",\"=revenue!B11\",\"=nowhere!A1\"\n",
                                          locale: gb, names: names)
        XCTAssertEqual(problems, [CSVReadProblem(row: 0, column: 3, message: "There is no table named nowhere")],
                       "a name no figure answers to has no id to store")
        func expr(_ a1: String) -> FormulaExpr { extract(t[key(t, a1)]!.content) }
        guard case .ref(let b9) = expr("A1"), case .id(let row, let column) = b9.anchor else { return XCTFail("revenue!B9 should be an id ref") }
        XCTAssertEqual(row, revenue.rows[8]); XCTAssertEqual(column, revenue.columns[1])
        XCTAssertEqual(b9.target, .figure(id: "fig-rev00001"), "the name became the figure's id")
        guard case .call(_, let args) = expr("B1"), case .range(let g) = args[0], case .id = g.start.anchor, case .id = g.end.anchor
        else { return XCTFail("a figure range should resolve to ids") }
        guard case .ref(let off) = expr("C1"), case .position = off.anchor else { return XCTFail("off the figure: positional") }
        XCTAssertEqual(t[key(t, "D1")]?.content, .value(.text("=nowhere!A1")), "kept as the text it was")

        var wb = Workbook(pins: NoPins())
        wb.setTable(revenue, id: "fig-rev00001")
        wb.setTable(t, id: "t")
        let a1 = CellAddress(table: "t", key: key(t, "A1"))
        XCTAssertEqual(wb.value(at: a1), .number(900))
        var grown = revenue
        grown.insertRow(after: nil)
        wb.setTable(grown, id: "fig-rev00001")
        XCTAssertEqual(wb.value(at: a1), .number(900), "still the same cell after a row is inserted above it")
        let grownNames = FormulaNames(figures: [.init(id: "fig-rev00001", name: "revenue", table: grown)])
        XCTAssertEqual(FormulaParser.render(Formula(expr("A1")), in: t, names: grownNames), "revenue!B10")
    }

    /// A research copy is written with each figure's and research item's CURRENT name, and reads
    /// back to the same ids (R-D1); a title two items share is a problem, the cell kept as text.
    func test_researchCopy_writesCurrentNames_andReadsThemBackToIds() throws {
        let revenue = FigureTable(rows: 2, columns: 2)
        let research = [(id: "res-model1", title: "model")]
        let before = FormulaNames(figures: [.init(id: "fig-rev00001", name: "revenue", table: revenue)], research: research)
        let (t, problems) = TableCSV.read("\"=revenue!B2+research:model!C3\"\n", locale: gb, names: before)
        XCTAssertTrue(problems.isEmpty)
        let renamed = FormulaNames(figures: [.init(id: "fig-rev00001", name: "income", table: revenue)],
                                   research: [(id: "res-model1", title: "Forecast")])
        let csv = TableCSV.renderResearch(t, locale: gb, names: renamed)
        XCTAssertEqual(csv, "=income!B2+research:Forecast!C3\n")
        let (back, again) = TableCSV.read(csv, locale: gb, names: renamed)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(extract(try XCTUnwrap(back[key(back, "A1")]).content), extract(try XCTUnwrap(t[key(t, "A1")]).content))

        // Free-text titles and names survive the copy and the return.
        let wild = FormulaNames(figures: [.init(id: "fig-rev00001", name: "Таблица (2), café", table: revenue)],
                                research: [(id: "res-model1", title: "Denver's model, Сербија")])
        let wildCSV = TableCSV.renderResearch(t, locale: gb, names: wild)
        let (wildBack, wildProblems) = TableCSV.read(wildCSV, locale: gb, names: wild)
        XCTAssertTrue(wildProblems.isEmpty, "\(wildCSV): \(wildProblems)")
        XCTAssertEqual(extract(try XCTUnwrap(wildBack[key(wildBack, "A1")]).content), extract(try XCTUnwrap(t[key(t, "A1")]).content))
        // An image figure has no table to read: reported, kept as text.
        let picture = FormulaNames(figures: [.init(id: "fig-pic00001", name: "map", table: nil)])
        XCTAssertEqual(TableCSV.read("=map!A1\n", locale: gb, names: picture).problems,
                       [CSVReadProblem(row: 0, column: 0, message: "There is no table named map")])

        let twins = FormulaNames(research: [(id: "res-a", title: "Forecast"), (id: "res-b", title: "forecast")])
        let (_, refused) = TableCSV.read("=research:forecast!A1\n", locale: gb, names: twins)
        XCTAssertEqual(refused, [CSVReadProblem(row: 0, column: 0, message: "Two Research items are called forecast; rename one.")])
    }


    // MARK: a Research table keeps its separator (report plan 8b Task 7)

    /// **A ";" file, a tab file and a "," file each round-trip in their own
    /// separator**: the separator between fields, decimals as that file reads
    /// them, formulas as `=` cells with their POSIX text, and text that would
    /// read as a number escaped.
    func test_renderResearch_keepsTheFilesSeparator_andItsDecimals() {
        let de = TableLocale(languageTag: "de-DE")
        for (separator, locale, decimal) in [(";" as Character, gb, "3,5"), ("\t", de, "3,5"),
                                             ("\t", gb, "3.5"), (",", de, "3.5")] {
            var t = FigureTable(rows: 2, columns: 3)
            func set(_ a1: String, _ c: CellContent) { t.setCell(Cell(content: c), at: key(t, a1)) }
            set("A1", .value(.text("Name")))
            set("B1", .value(.text("Rate")))
            set("C1", .value(.text("Double")))
            set("A2", .value(.text("1,5")))
            set("B2", .value(.number(3.5)))
            guard case .success(let f) = FormulaParser.parse("B2*2", in: t) else { return XCTFail() }
            set("C2", .formula(f))
            let csv = TableCSV.renderResearch(t, locale: locale, names: .empty, separator: separator)
            let lines = csv.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.first, ["Name", "Rate", "Double"].joined(separator: String(separator)))
            XCTAssertTrue(lines[1].contains(decimal), "\(csv)")
            XCTAssertTrue(lines[1].contains("=B2*2"), "\(csv)")
            XCTAssertEqual(TableCSV.rows(csv).separator, separator, "read back as the same kind of file")
            let (back, problems) = TableCSV.read(csv, locale: locale, names: .empty)
            XCTAssertTrue(problems.isEmpty, "\(csv)")
            XCTAssertEqual(back[key(back, "B2")]?.content, .value(.number(3.5)), "\(csv)")
            XCTAssertEqual(back[key(back, "A2")]?.content, .value(.text("1,5")), "\(csv)")
            XCTAssertEqual(back[key(back, "C2")].map { FormulaParser.render(Formula(extract($0.content)), in: back) },
                           "B2*2")
        }
    }

    /// The default is the "," file every caller wrote before.
    func test_renderResearch_defaultsToAComma() {
        var t = FigureTable(rows: 1, columns: 2)
        t.setCell(Cell(content: .value(.number(2.5))), at: key(t, "A1"))
        t.setCell(Cell(content: .value(.text("x"))), at: key(t, "B1"))
        XCTAssertEqual(TableCSV.renderResearch(t, locale: TableLocale(languageTag: "de-DE"), names: .empty), "2.5,x\n")
        XCTAssertEqual(TableCSV.renderResearch(t, locale: gb, names: .empty, separator: ";"), "\"2,5\";x\n",
                       "a decimal comma is quoted, as every separator character is")
    }

    /// A table of one column has no separator for `read` to find: it is
    /// written as a "," file, so its decimals read back.
    func test_renderResearch_oneColumnIsWrittenAsACommaFile() {
        var t = FigureTable(rows: 1, columns: 1)
        t.setCell(Cell(content: .value(.number(2.5))), at: key(t, "A1"))
        let csv = TableCSV.renderResearch(t, locale: gb, names: .empty, separator: ";")
        XCTAssertEqual(csv, "2.5\n")
        XCTAssertEqual(TableCSV.read(csv, locale: gb, names: .empty).table.cells.values.first?.content,
                       .value(.number(2.5)))
    }

    /// **A file with CRLF rows keeps them**; a newline inside a quoted cell
    /// stays the cell's own.
    func test_renderResearch_keepsCRLFRows_andACellsOwnNewline() {
        var t = FigureTable(rows: 2, columns: 2)
        t.setCell(Cell(content: .value(.text("a\nb"))), at: key(t, "A1"))
        t.setCell(Cell(content: .value(.number(1))), at: key(t, "B1"))
        t.setCell(Cell(content: .value(.number(2))), at: key(t, "B2"))
        let csv = TableCSV.renderResearch(t, locale: gb, names: .empty, lineEnding: "\r\n")
        XCTAssertEqual(csv, "\"a\nb\",1\r\n,2\r\n")
        let back = TableCSV.read(csv, locale: gb, names: .empty).table
        XCTAssertEqual(back[key(back, "A1")]?.content, .value(.text("a\nb")))
    }
}
