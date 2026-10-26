import XCTest
@testable import MaughamCore

/// **A row reorder keeps every range's positional span** (report plan 7c,
/// ruling on review C1): sorting moves rows, so a range stored by id is
/// re-anchored to the rows now at its old positions; a single-cell reference
/// moves with its row.
final class FigureRangeAnchorsTests: XCTestCase {

    private struct NoPins: ResearchPinSource {
        func pinnedValue(home: String, research: String, row: Int, column: Int) -> CellValue? { nil }
    }

    /// Header, five body rows (A = 30, 10, 50, 20, 40) and a total `SUM(A2:A6)`.
    private func fixture() -> FigureTable {
        var t = FigureTable(rows: 7, columns: 2)
        t.headerRows = 1
        t.hasTotalRow = true
        set(&t, 0, 0, .value(.text("Amount")))
        for (i, n) in [30.0, 10, 50, 20, 40].enumerated() { set(&t, i + 1, 0, .value(.number(n))) }
        set(&t, 6, 0, formula("SUM(A2:A6)", t))
        return t
    }

    private func set(_ t: inout FigureTable, _ r: Int, _ c: Int, _ content: CellContent) {
        t.setCell(Cell(content: content), at: CellKey(row: t.rows[r], column: t.columns[c]))
    }

    private func formula(_ text: String, _ t: FigureTable) -> CellContent {
        guard case .success(let f) = FormulaParser.parse(text, in: t) else {
            XCTFail("did not parse: \(text)"); return .value(.empty)
        }
        return .formula(f)
    }

    private func key(_ t: FigureTable, _ r: Int, _ c: Int) -> CellKey {
        CellKey(row: t.rows[r], column: t.columns[c])
    }

    /// The table with its rows moved into `order`, the way the host moves them.
    private func moved(_ t: FigureTable, to order: [RowID]) -> FigureTable {
        var out = t
        for (i, row) in order.enumerated() { out.moveRow(row, after: i == 0 ? nil : order[i - 1]) }
        return out
    }

    private func sortedAscending(_ t: FigureTable) -> FigureTable {
        moved(t, to: FigureSort.order(table: t, values: { key in
            if case .value(let v)? = t[key]?.content { return v }
            return .empty
        }, column: t.columns[0], ascending: true))
    }

    private func applying(_ edits: [CellKey: Cell], to t: FigureTable) -> FigureTable {
        var out = t
        for (k, c) in edits { out.setCell(c, at: k) }
        return out
    }

    private func value(_ t: FigureTable, _ r: Int, _ c: Int) -> CellValue {
        var wb = Workbook(pins: NoPins())
        wb.setTable(t, id: "fig")
        return wb.value(at: CellAddress(table: "fig", key: key(t, r, c)))
    }

    private func text(_ t: FigureTable, _ r: Int, _ c: Int) -> String? {
        guard case .formula(let f)? = t[key(t, r, c)]?.content else { return nil }
        return FormulaParser.render(f, in: t)
    }

    // MARK: -

    /// **The reviewer's fixture**: the total reads 150 before the sort and
    /// after it — and, without the re-anchoring, would read 70.
    func test_aTotalOverTheBodyKeepsItsSumAcrossASort() {
        let old = fixture()
        XCTAssertEqual(value(old, 6, 0), .number(150), "precondition")
        let new = sortedAscending(old)
        XCTAssertEqual(value(new, 6, 0), .number(70), "control: moved rows alone shrink the range")

        let edits = FigureRangeAnchors.reanchoredCells(old: old, new: new)
        XCTAssertEqual(Set(edits.keys), [key(old, 6, 0)], "only the total's range is rewritten")
        let fixed = applying(edits, to: new)
        XCTAssertEqual(value(fixed, 6, 0), .number(150))
        XCTAssertEqual(text(fixed, 6, 0), "SUM(A2:A6)", "it still spans the body by position")
    }

    /// A single-cell reference moves with its row and is never rewritten; a
    /// one-row range on its own formula's row moves with it too.
    func test_singleCellRefsAndAnOwnRowRangeMoveWithTheirRows() {
        var old = fixture()
        set(&old, 2, 1, formula("A3*2", old))       // reads its own row's 10
        set(&old, 3, 1, formula("SUM(A4:A4)", old)) // its own row, as a range
        set(&old, 1, 1, formula("A6", old))         // another body row's 40
        let new = sortedAscending(old)
        let edits = FigureRangeAnchors.reanchoredCells(old: old, new: new)
        XCTAssertNil(edits[key(old, 2, 1)])
        XCTAssertNil(edits[key(old, 3, 1)])
        XCTAssertNil(edits[key(old, 1, 1)])
        let fixed = applying(edits, to: new)
        let b2 = try? XCTUnwrap(fixed.rows.firstIndex(of: old.rows[2]))
        XCTAssertEqual(value(fixed, b2 ?? 0, 1), .number(20), "A3*2 follows its row")
        let b3 = fixed.rows.firstIndex(of: old.rows[3]) ?? 0
        XCTAssertEqual(value(fixed, b3, 1), .number(50), "the own-row range follows its row")
        let b1 = fixed.rows.firstIndex(of: old.rows[1]) ?? 0
        XCTAssertEqual(value(fixed, b1, 1), .number(40), "a ref to another row follows that row")
    }

    /// A range partly inside the reordered block keeps its positions: the
    /// header and the first two body rows, whichever rows those now are.
    func test_aRangePartlyInsideTheBlockKeepsItsPositions() {
        var old = fixture()
        set(&old, 0, 1, formula("SUM(A1:A3)", old))
        XCTAssertEqual(value(old, 0, 1), .number(40), "precondition: 30 + 10")
        let new = sortedAscending(old)
        let fixed = applying(FigureRangeAnchors.reanchoredCells(old: old, new: new), to: new)
        XCTAssertEqual(text(fixed, 0, 1), "SUM(A1:A3)")
        XCTAssertEqual(value(fixed, 0, 1), .number(30), "10 + 20, the two smallest now first")
    }

    /// A range the reorder does not change — the header alone, or a reversed
    /// range over the whole body — is left as it is; a reversed one that must
    /// change keeps its direction.
    func test_anUnchangedSpanIsLeftAlone_andAReversedRangeKeepsItsDirection() {
        var old = fixture()
        // The parser writes a range top-down; a stored one may run either way.
        guard case .formula(let parsed) = formula("SUM(A2:A6)", old),
              case .call(let name, let parsedArgs) = parsed.expr, case .range(let down)? = parsedArgs.first
        else { return XCTFail("not a range") }
        set(&old, 0, 1, .formula(Formula(.call(name: name, arguments: [
            .range(FormulaRange(start: down.end, end: down.start))]))))
        let new = sortedAscending(old)
        let edits = FigureRangeAnchors.reanchoredCells(old: old, new: new)
        let fixed = applying(edits, to: new)
        XCTAssertEqual(value(fixed, 0, 1), .number(150))
        guard case .formula(let f)? = fixed[key(fixed, 0, 1)]?.content,
              case .call(_, let args) = f.expr, case .range(let g)? = args.first,
              case .id(let start, _) = g.start.anchor, case .id(let end, _) = g.end.anchor
        else { return XCTFail("not a range") }
        XCTAssertEqual(start, fixed.rows[5], "the start stays the bottom edge")
        XCTAssertEqual(end, fixed.rows[1])

        var header = fixture()
        set(&header, 0, 1, formula("SUM(A1:A1)", header))
        XCTAssertNil(FigureRangeAnchors.reanchoredCells(old: header, new: sortedAscending(header))[key(header, 0, 1)])
    }

    /// **Another figure's range into the reordered block is reported**, so
    /// the sort can refuse; one outside the block, or a single ref, is not.
    func test_anotherFiguresRangeIntoTheBlockIsReported() {
        let old = fixture()
        let new = sortedAscending(old)
        func elsewhere(_ text: String) -> Formula {
            guard case .formula(let f) = formula(text, old) else { return Formula(.missing) }
            return Formula(retarget(f.expr))
        }
        func retarget(_ e: FormulaExpr) -> FormulaExpr {
            switch e {
            case .range(var g): g.start.target = .figure(id: "fig"); g.end.target = .figure(id: "fig"); return .range(g)
            case .ref(var r): r.target = .figure(id: "fig"); return .ref(r)
            case .call(let n, let a): return .call(name: n, arguments: a.map(retarget))
            default: return e
            }
        }
        XCTAssertTrue(FigureRangeAnchors.spanChanges(
            in: elsewhere("SUM(A2:A6)"), readingFigure: "fig", old: old, new: new))
        XCTAssertTrue(FigureRangeAnchors.spanChanges(
            in: elsewhere("SUM(A1:A3)"), readingFigure: "fig", old: old, new: new), "partly inside")
        XCTAssertFalse(FigureRangeAnchors.spanChanges(
            in: elsewhere("SUM(A7:A7)"), readingFigure: "fig", old: old, new: new), "the total row stays put")
        XCTAssertFalse(FigureRangeAnchors.spanChanges(
            in: elsewhere("A3"), readingFigure: "fig", old: old, new: new), "a single ref moves with its row")
        XCTAssertFalse(FigureRangeAnchors.spanChanges(
            in: elsewhere("SUM(A2:A6)"), readingFigure: "other", old: old, new: new), "another figure's id")
    }
}
