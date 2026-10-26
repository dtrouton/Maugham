import Foundation

/// Why a pipe table could not become a figure table.
public enum FigureTablePipeError: Error, Equatable, Sendable {
    /// More non-empty cells than `TableCSV.figureCellLimit`.
    case tooLarge(cells: Int)
}

extension FigureTable {
    /// **A pipe table as a new figure table** (report plan 7b Task 1, R7b-10): the header row
    /// becomes the figure's one header row (`headerRows = 1`), body rows follow, and every cell
    /// is read by `TableCSV.read(rows:locale:names:)` — the reader a CSV import uses — so `=`
    /// cells become formulas, numbers and dates are typed in `locale`, and an unparseable
    /// formula stays as text. A column's delimiter-row alignment is set on its cells. The
    /// caption and label belong to the manuscript line, not the table, and are ignored here.
    /// Throws `.tooLarge` past `TableCSV.figureCellLimit` non-empty cells.
    public init(pipe: TableText, locale: TableLocale, names: FormulaNames) throws {
        let rows = [pipe.header] + pipe.rows
        let cells = rows.reduce(0) { total, row in
            total + row.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        }
        guard cells <= TableCSV.figureCellLimit else { throw FigureTablePipeError.tooLarge(cells: cells) }
        var table = TableCSV.read(rows: rows, locale: locale, names: names).table
        table.headerRows = 1
        let columns = table.columns
        for (c, alignment) in pipe.alignments.enumerated() where c < columns.count {
            let mapped: CellAlignment
            switch alignment {
            case .none: continue
            case .leading: mapped = .left
            case .center: mapped = .center
            case .trailing: mapped = .right
            }
            for row in table.rows {
                let key = CellKey(row: row, column: columns[c])
                guard var cell = table[key] else { continue }
                cell.alignment = mapped
                table.setCell(cell, at: key)
            }
        }
        self = table
    }
}
