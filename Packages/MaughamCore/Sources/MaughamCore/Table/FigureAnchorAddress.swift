import Foundation

/// **A figure note's address as text** (report plan 9c-1): `tbl:cashflow!C3:E3`
/// is the figure `tbl:cashflow` and the cells `C3:E3` by their current
/// positions. The text is how Claude names an anchor (and how a tool echoes
/// one); the op stores ids, so [`anchor(_:in:)`](#) turns positions into a
/// `FigureCellAnchor` once, at creation.
public enum FigureAnchorAddress {

    /// A cell address that is not one inside the table's live rows and columns.
    public struct NotACell: Error, Equatable, Sendable {
        public let text: String
    }

    /// The figure label and, when given, the cells: `tbl:x` → (`tbl:x`, nil);
    /// `tbl:x!c3:e3` → (`tbl:x`, `c3:e3`, as written). Nil unless the text is a
    /// `tbl:`/`fig:` label with a name, and, if there is a `!`, something after
    /// it. The cells are not checked here — the table decides that.
    public static func parse(_ text: String) -> (label: String, cells: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = parts.first else { return nil }
        let label = String(head).trimmingCharacters(in: .whitespaces)
        guard let colon = label.firstIndex(of: ":"),
              ["tbl", "fig"].contains(label[..<colon].lowercased()),
              !label[label.index(after: colon)...].trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        guard parts.count == 2 else { return (label, nil) }
        let cells = String(parts[1]).trimmingCharacters(in: .whitespaces)
        return cells.isEmpty ? nil : (label, cells)
    }

    /// The anchor `cells` ("C3" or "C3:E4", by current positions) names in
    /// `table`: row and column ids, with an end corner only on an axis the range
    /// spans. Fails when any part is not a live cell.
    public static func anchor(_ cells: String, in table: FigureTable) -> Result<FigureCellAnchor, Error> {
        guard let (from, to) = FigureGridAddress.range(cells, in: table) else {
            return .failure(NotACell(text: cells))
        }
        return .success(FigureCellAnchor(
            row: from.row, rowEnd: to.row == from.row ? nil : to.row,
            column: from.column, columnEnd: to.column == from.column ? nil : to.column))
    }
}
