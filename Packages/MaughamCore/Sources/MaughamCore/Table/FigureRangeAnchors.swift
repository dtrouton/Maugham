import Foundation

/// **A row reorder keeps every range's positional span** (report plan 7c,
/// the controller's ruling on review C1). A range stored by id covers the live
/// rows between its edges' slots, so moving rows changes what it covers: after
/// a sort, a total row's `SUM(A2:A6)` anchored to the body's old first and
/// last rows would read only the rows still between those two slots. Pure;
/// `FigureDocument.sortRows` applies it inside the same visit, and the grid's
/// row moves may ask it too.
///
/// - **A range** whose covered live positions change is re-anchored to the
///   row ids now at those positions — its columns, `$` flags and direction
///   kept. A range whose span is unchanged, one that covers nothing
///   (`#REF!`), and a positional (research or CSV) range are left alone.
/// - **A one-row range on its own formula's row** moves with that row, as a
///   single-cell reference does (`=SUM(B5:D5)` in E5 still reads its row).
/// - **A single-cell reference** is never rewritten: it moves with its row.
public enum FigureRangeAnchors {

    /// Each formula cell of `old` whose ranges into its own table change span
    /// when the rows are reordered to `new` (the same table after the moves),
    /// with the re-anchored cell. Keys are cell ids, which a move never changes.
    /// `ownId` is the figure's id, so a range naming itself by id counts too.
    public static func reanchoredCells(
        old: FigureTable, new: FigureTable, ownId: String? = nil
    ) -> [CellKey: Cell] {
        var out: [CellKey: Cell] = [:]
        for (key, cell) in old.cells {
            guard case .formula(let f) = cell.content else { continue }
            let mapped = map(f.expr) { range in
                guard readsOwnTable(range, ownId: ownId) else { return nil }
                return reanchored(range, old: old, new: new, formulaRow: key.row)
            }
            if mapped != f.expr {
                var next = cell
                next.content = .formula(Formula(mapped))
                out[key] = next
            }
        }
        return out
    }

    /// Whether `formula` — in ANOTHER figure — holds a range into figure
    /// `figureId` whose span the reorder from `old` to `new` would change.
    /// The sort refuses then: it rewrites no other figure's formulas.
    public static func spanChanges(
        in formula: Formula, readingFigure figureId: String, old: FigureTable, new: FigureTable
    ) -> Bool {
        var changed = false
        _ = map(formula.expr) { range in
            if case .figure(let id) = range.start.target, id == figureId,
               reanchored(range, old: old, new: new, formulaRow: nil) != nil {
                changed = true
            }
            return nil
        }
        return changed
    }

    /// `range` re-anchored so it covers the same live positions in `new` as
    /// it did in `old`, or nil when it needs no change.
    public static func reanchored(
        _ range: FormulaRange, old: FigureTable, new: FigureTable, formulaRow: RowID?
    ) -> FormulaRange? {
        guard case let .id(r0, _) = range.start.anchor, case let .id(r1, _) = range.end.anchor,
              let os0 = old.rowSlotIndex(of: r0), let os1 = old.rowSlotIndex(of: r1),
              let ns0 = new.rowSlotIndex(of: r0), let ns1 = new.rowSlotIndex(of: r1)
        else { return nil }
        let covered = old.liveRows(betweenSlots: os0, os1)
        guard let first = covered.first, let last = covered.last,
              let p0 = old.rowIndex(of: first), let p1 = old.rowIndex(of: last),
              p1 < new.rows.count
        else { return nil }
        if let formulaRow, covered == [formulaRow] { return nil }
        let wanted = Array(new.rows[p0...p1])
        guard new.liveRows(betweenSlots: ns0, ns1) != wanted else { return nil }
        let top = new.rows[p0], bottom = new.rows[p1]
        var out = range
        out.start.anchor = withRow(range.start.anchor, os0 <= os1 ? top : bottom)
        out.end.anchor = withRow(range.end.anchor, os0 <= os1 ? bottom : top)
        return out
    }

    private static func withRow(_ anchor: RefAnchor, _ row: RowID) -> RefAnchor {
        guard case let .id(_, column) = anchor else { return anchor }
        return .id(row: row, column: column)
    }

    private static func readsOwnTable(_ range: FormulaRange, ownId: String?) -> Bool {
        switch range.start.target {
        case .this: return true
        case .figure(let id): return id == ownId
        case .research: return false
        }
    }

    /// `expr` with each range replaced by `transform`'s answer (nil keeps it).
    private static func map(
        _ expr: FormulaExpr, _ transform: (FormulaRange) -> FormulaRange?
    ) -> FormulaExpr {
        switch expr {
        case .range(let g): return .range(transform(g) ?? g)
        case .unary(let op, let x): return .unary(op, map(x, transform))
        case .binary(let op, let l, let r): return .binary(op, map(l, transform), map(r, transform))
        case .call(let name, let arguments): return .call(name: name, arguments: arguments.map { map($0, transform) })
        case .number, .text, .bool, .missing, .ref, .error: return expr
        }
    }
}
