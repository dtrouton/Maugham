import Foundation

/// **A table figure's printed cells** (report plan 9a): every live row and column as
/// formatted strings, split into header, body and total, with each column's alignment
/// resolved. Pure; the PDF, EPUB and Word emitters all read it. Unlike the editor's
/// card (`FigureCardModel`) it never cuts rows short.
public struct FigureTableLayout: Sendable, Equatable {
    /// The first row when the table has a header row.
    public var header: [String]?
    /// Every row between the header and the total.
    public var body: [[String]]
    /// The last row when the table has a total row (and it is not the header).
    public var total: [String]?
    /// One per column, never `.automatic`.
    public var alignments: [CellAlignment]
    /// A1 names (live position) of the cells showing a formula error, in reading order.
    public var errorCells: [String]

    /// - Parameter label: a translated body's text for a cell (report plan 9e-1, spec §8),
    ///   consulted for stored-literal text cells only (`FigureTextCells.isTextCell`): numbers,
    ///   dates and formulas are shared across languages and always print as computed. A cell
    ///   it answers nil for prints its source. Nil (the source body) asks nothing.
    public static func make(
        table: FigureTable, value: (CellKey) -> CellValue, locale: TableLocale,
        label: ((CellKey) -> String?)? = nil
    ) -> FigureTableLayout {
        let rows = table.rows, columns = table.columns
        let headerCount = min(table.headerRows, rows.count)
        let totalIndex = table.hasTotalRow && rows.count > headerCount ? rows.count - 1 : nil
        var errors: [String] = []

        func line(_ i: Int) -> [String] {
            columns.enumerated().map { c, column in
                let key = CellKey(row: rows[i], column: column)
                if let label, FigureTextCells.isTextCell(table[key]), let text = label(key) { return text }
                let v = value(key)
                if case .error = v { errors.append(A1.columnLetters(c) + String(i + 1)) }
                return CellDisplay.string(for: v, format: table[key]?.format ?? CellFormat(), locale: locale)
            }
        }

        let header = headerCount == 1 ? line(0) : nil
        var bodyEnd = rows.count
        if totalIndex != nil { bodyEnd -= 1 }
        let body = (headerCount..<max(bodyEnd, headerCount)).map(line)
        let total = totalIndex.map(line)
        let scanned = Array(rows[headerCount...])
        return FigureTableLayout(
            header: header, body: body, total: total,
            alignments: alignments(table: table, columns: columns, rows: scanned, values: value),
            errorCells: errors)
    }

    /// **The one alignment rule** (the card and the printed table share it): a column's first
    /// filled cell among `rows` decides: its own non-automatic alignment, else numbers and
    /// dates right and anything else left; a column with no filled cell is left.
    static func alignments(
        table: FigureTable, columns: [ColumnID], rows: [RowID], values: (CellKey) -> CellValue
    ) -> [CellAlignment] {
        columns.map { column in
            for row in rows {
                let key = CellKey(row: row, column: column)
                let v = values(key)
                if v == .empty { continue }
                if let a = table[key]?.alignment, a != .automatic { return a }
                switch v { case .number, .date: return .right; default: return .left }
            }
            return .left
        }
    }
}
