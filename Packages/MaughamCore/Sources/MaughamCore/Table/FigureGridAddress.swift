import Foundation

/// **A table figure's cells as the grid shows them** (report plan 7c): "B3"
/// for one cell, "B2:D9" for a range, by each id's live position in the
/// table. The grid's formula bar shows these, and a reference composed with
/// the arrows is written with them. Pure; ids in, text out, and back.
public enum FigureGridAddress {

    /// "B3": the cell's column letters and 1-based row number, or nil when
    /// either id is not live in `table`.
    public static func string(for key: CellKey, in table: FigureTable) -> String? {
        guard let r = table.rowIndex(of: key.row), let c = table.columnIndex(of: key.column) else { return nil }
        return A1.columnLetters(c) + String(r + 1)
    }

    /// "B2:D9": the rectangle between two cells, written top-left to
    /// bottom-right whichever corners it is given; one cell when they are the
    /// same position ("B3"). Nil when any id is not live.
    public static func string(from a: CellKey, to b: CellKey, in table: FigureTable) -> String? {
        guard let ar = table.rowIndex(of: a.row), let ac = table.columnIndex(of: a.column),
              let br = table.rowIndex(of: b.row), let bc = table.columnIndex(of: b.column) else { return nil }
        let top = min(ar, br), bottom = max(ar, br), left = min(ac, bc), right = max(ac, bc)
        let first = A1.columnLetters(left) + String(top + 1)
        guard top != bottom || left != right else { return first }
        return first + ":" + A1.columnLetters(right) + String(bottom + 1)
    }

    /// The cell "B3" names in `table` (case-insensitive, `$` markers and
    /// surrounding spaces allowed), or nil when it is not one address or lies
    /// outside the table's live rows and columns.
    public static func cell(_ text: String, in table: FigureTable) -> CellKey? {
        guard let a = A1.parse(text.trimmingCharacters(in: .whitespaces)),
              a.row < table.rows.count, a.column < table.columns.count else { return nil }
        return CellKey(row: table.rows[a.row], column: table.columns[a.column])
    }

    /// The two cells "B2:D9" names, in the order written (so "D9:B2" answers
    /// D9 then B2); a single address answers the same cell twice. Nil unless
    /// every part is a cell inside the table.
    public static func range(_ text: String, in table: FigureTable) -> (from: CellKey, to: CellKey)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let only = cell(String(parts[0]), in: table) else { return nil }
            return (only, only)
        case 2:
            guard let from = cell(String(parts[0]), in: table), let to = cell(String(parts[1]), in: table) else {
                return nil
            }
            return (from, to)
        default:
            return nil
        }
    }
}
