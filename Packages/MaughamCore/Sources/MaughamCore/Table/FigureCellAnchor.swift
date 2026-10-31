import Foundation

/// **Where on a table figure a note points** (spec §10.1, report plan 9c-1):
/// one cell, or the corners of a range, by row and column id — never by
/// position, so the anchor follows rows and columns inserted around it.
///
/// On the wire it is the creation op's four flat provenance scalars
/// (`figureRowId`, `figureRowEndId`, `figureColId`, `figureColEndId`, fixed by
/// report plan 6a); the figure itself is the stream's `docId`. A note on a
/// figure's stream with no scalars is about the whole figure, and has no
/// anchor at all.
///
/// A range stays by its corner ids (plan 9c-1 ruling): it does not follow
/// sorts or moves, and it is orphaned when any corner's row or column is
/// deleted. A revive brings the id back, and the anchor with it.
public struct FigureCellAnchor: Equatable, Sendable {
    public let row: RowID
    public let rowEnd: RowID?
    public let column: ColumnID
    public let columnEnd: ColumnID?

    public init(row: RowID, rowEnd: RowID? = nil, column: ColumnID, columnEnd: ColumnID? = nil) {
        self.row = row; self.rowEnd = rowEnd
        self.column = column; self.columnEnd = columnEnd
    }

    /// The anchor a creation op's provenance names, or nil when it names no
    /// cell (a whole-figure note, or no figure note at all). A row without a
    /// column, or a column without a row, names no cell either.
    public init?(provenance: Op.Provenance?) {
        guard let row = provenance?.figureRowId, let column = provenance?.figureColId else { return nil }
        self.init(
            row: RowID(row), rowEnd: provenance?.figureRowEndId.map(RowID.init),
            column: ColumnID(column), columnEnd: provenance?.figureColEndId.map(ColumnID.init))
    }

    public enum Resolution: Equatable, Sendable {
        /// The anchor's cells by their live positions: "C3", or "C3:E4".
        case live(a1: String)
        /// A named row or column is deleted, or the table never held it.
        case orphaned
    }

    /// The anchor in `table` as the grid would write it. A missing end corner
    /// on either axis is the start's; a range whose corners land on one cell
    /// reads as that cell.
    public func resolve(in table: FigureTable) -> Resolution {
        let from = CellKey(row: row, column: column)
        let to = CellKey(row: rowEnd ?? row, column: columnEnd ?? column)
        guard let a1 = FigureGridAddress.string(from: from, to: to, in: table) else { return .orphaned }
        return .live(a1: a1)
    }
}
