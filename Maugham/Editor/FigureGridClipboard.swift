import AppKit
import MaughamCore

/// **The table grid's clipboard** (report plan 7d Task 3, rulings R7d-2 and
/// R7d-3): what a copy out of the grid writes on a pasteboard, and what a
/// paste reads back as a block of cells. Writes nothing to a figure — the
/// controller hands the block to `FigurePaste` and the host.
///
/// - **A copy writes three flavours**: Maugham's own type (`cellsType`, the
///   cells with their formulas, the figure they came from and the copied
///   block's top-left position), and the cells' display text as
///   tab-separated text and as an HTML table, for Numbers, Excel, Sheets or
///   a mail.
/// - **A paste reads the first it finds, in that order**: Maugham's own type,
///   then an HTML table, then tab-separated text, then plain text. Cells from
///   the SAME figure keep their formulas, moved by how far the paste moved
///   them (`FigurePaste.Block.copiedFrom`); from ANOTHER figure a formula
///   pastes as the value it showed (the controller's ruling — a reference
///   into another table is not carried across). A CUT pasted into the same
///   figure moves its formulas as they are, references unchanged (Excel,
///   Numbers and Sheets move on a cut; review I1) — other cells' references
///   to the cut cells do not follow them. Text from another app is
///   read the way typing is (`FigureCellEntry`).
/// - The pasteboard is the controller's (`FigureGridController.pasteboard`):
///   the general one in the app, a private one in a test.
enum FigureGridClipboard {

    /// Maugham's own pasteboard type, spelled in `BuildVariant` (tripwire 13).
    static let cellsType = NSPasteboard.PasteboardType(BuildVariant.figureCellsPasteboardType)

    /// The flavours a paste reads, in the order it prefers them.
    static let readableTypes: [NSPasteboard.PasteboardType] = [cellsType, .html, .tabularText, .string]

    /// **Maugham's own copy**: the cells as stored (formulas included), the
    /// values they showed, the figure they came from and where.
    struct Cells: Codable, Equatable {
        var figureId: String
        /// The copied block's top-left cell's live position at copy time.
        var originRow: Int
        var originColumn: Int
        /// Row by row; nil is an empty cell.
        var cells: [[Cell?]]
        /// The value each cell showed (a formula's computed result), row by row.
        var values: [[CellValue]]
        /// A cut, not a copy: pasted into the same figure its formulas keep
        /// their references (a move), never translated.
        var isCut = false
    }

    /// What a paste found on the pasteboard.
    enum Source: Equatable {
        case cells(Cells)
        /// Rows of text from another app (or a copy whose own flavour is gone).
        case text([[String]])
    }

    // MARK: Copy

    /// **Write a copy**: the own flavour, and `display` (the cells' display
    /// strings, row by row) as tab-separated and HTML text.
    static func write(_ cells: Cells, display: [[String]], to pasteboard: NSPasteboard) {
        pasteboard.declareTypes([cellsType, .tabularText, .string, .html], owner: nil)
        if let data = try? JSONEncoder().encode(cells) { pasteboard.setData(data, forType: cellsType) }
        let tabSeparated = TableClipboard.tabSeparated(display)
        pasteboard.setString(tabSeparated, forType: .tabularText)
        pasteboard.setString(tabSeparated, forType: .string)
        pasteboard.setString(TableHTML.html(rows: display), forType: .html)
    }

    // MARK: Paste

    /// Whether the pasteboard holds a flavour a paste reads.
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: readableTypes) != nil
    }

    /// **What a paste reads**, in preference order: the own flavour, an HTML
    /// table, tab-separated text, plain text. Nil when none reads (an HTML
    /// fragment without a table and no text, a picture).
    static func read(from pasteboard: NSPasteboard) -> Source? {
        if let data = pasteboard.data(forType: cellsType),
           let cells = try? JSONDecoder().decode(Cells.self, from: data) {
            return .cells(cells)
        }
        if let html = pasteboard.string(forType: .html), let rows = TableHTML.rows(fromHTML: html) {
            return .text(rows)
        }
        if let tsv = pasteboard.string(forType: .tabularText) {
            let rows = TableClipboard.rows(fromTabSeparated: tsv)
            if !rows.isEmpty { return .text(rows) }
        }
        if let text = pasteboard.string(forType: .string) {
            // A spreadsheet's copy (Excel, Sheets) is tab-separated text with
            // its quoting; text without a tab is the writer's own, its quotes kept.
            let rows = TableClipboard.rows(fromTabSeparated: text, quoting: text.contains("\t"))
            if !rows.isEmpty { return .text(rows) }
        }
        return nil
    }

    /// **The block `source` pastes as into `figureId`'s `table`**: the same
    /// figure's cells as copied, with where they came from (their formulas
    /// move with the paste) — a cut's as they are, references kept; another figure's with each formula as the value
    /// it showed, its format kept; text read as typing reads it, a formula
    /// that will not read here kept as its text.
    static func block(from source: Source, into figureId: String, table: FigureTable,
                      names: FormulaNames, locale: TableLocale) -> FigurePaste.Block {
        switch source {
        case .cells(let copied) where copied.figureId == figureId && copied.isCut:
            return FigurePaste.Block(cells: copied.cells)
        case .cells(let copied) where copied.figureId == figureId:
            return FigurePaste.Block(
                cells: copied.cells,
                copiedFrom: FigurePaste.Position(row: copied.originRow, column: copied.originColumn))
        case .cells(let copied):
            let cells = copied.cells.enumerated().map { r, row in
                row.enumerated().map { c, cell -> Cell? in
                    guard var cell, case .formula = cell.content else { return cell }
                    let row = r < copied.values.count ? copied.values[r] : []
                    let value = c < row.count ? row[c] : .empty
                    cell.content = .value(value)
                    return cell
                }
            }
            return FigurePaste.Block(cells: cells)
        case .text(let rows):
            let cells = rows.map { row in
                row.map { text -> Cell? in
                    switch FigureCellEntry.cell(from: text, prior: nil, table: table, names: names, locale: locale) {
                    case .success(let cell): return cell
                    case .failure: return Cell(content: .value(.text(text)))
                    }
                }
            }
            return FigurePaste.Block(cells: cells)
        }
    }
}
