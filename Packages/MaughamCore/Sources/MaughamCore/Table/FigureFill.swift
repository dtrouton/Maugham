import Foundation

/// **Fill Down and Fill Right** (report plan 7d, ⌘D / ⌘R — ruling R7d-1):
/// the cells a fill writes in a table figure's grid, as Excel fills. Pure; the
/// grid hands the answer to the host's one batch write (`setCells`).
public enum FigureFill {

    public enum Direction: Equatable, Sendable {
        /// The selection's top row is copied into every row below it.
        case down
        /// The selection's left column is copied into every column right of it.
        case right
    }

    /// What filling `selection` in `direction` writes, keyed by cell (nil
    /// clears it):
    /// - every other cell of the selection takes the cell at the head of its
    ///   column (down) or row (right) — its value or formula, its format and
    ///   alignment; an empty head clears it;
    /// - a formula is translated from the head to the cell it lands in
    ///   (`FormulaParser.translate`): relative parts move, `$` parts stay, and
    ///   a ref pushed off the grid is `#REF!`;
    /// - a selection one row deep (down) or one column wide (right) fills
    ///   from the row above or the column to its left, as Excel does; at the
    ///   table's top row or first column there is nothing to fill from;
    /// - a cell that would not change is left out, so an empty answer means
    ///   the fill changes nothing.
    public static func edits(
        table: FigureTable, selection: FigureGridSelection, direction: Direction, names: FormulaNames
    ) -> [CellKey: Cell?] {
        guard let ar = table.rowIndex(of: selection.anchor.row), let ac = table.columnIndex(of: selection.anchor.column),
              let fr = table.rowIndex(of: selection.focus.row), let fc = table.columnIndex(of: selection.focus.column)
        else { return [:] }
        var top = min(ar, fr), left = min(ac, fc)
        let bottom = max(ar, fr), right = max(ac, fc)
        switch direction {
        case .down where top == bottom:
            guard top > 0 else { return [:] }
            top -= 1
        case .right where left == right:
            guard left > 0 else { return [:] }
            left -= 1
        default:
            break
        }
        let rows = table.rows, columns = table.columns
        var out: [CellKey: Cell?] = [:]
        for r in top...bottom {
            for c in left...right {
                let head: (row: Int, column: Int)
                switch direction {
                case .down: head = (top, c)
                case .right: head = (r, left)
                }
                guard (r, c) != head else { continue }
                let target = CellKey(row: rows[r], column: columns[c])
                let source = CellKey(row: rows[head.row], column: columns[head.column])
                var cell = table[source]
                if case .formula(let f)? = cell?.content {
                    cell?.content = .formula(FormulaParser.translate(f, from: source, to: target, in: table, names: names))
                }
                if table[target] != cell { out[target] = .some(cell) }
            }
        }
        return out
    }
}
