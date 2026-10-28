import AppKit
import UniformTypeIdentifiers
import MaughamCore

/// **Format ▸ Table ▸ Import from CSV…'s open panel, as a value** (report
/// plan 7d Task 4). A test pins this struct and never allocates a panel
/// (CLAUDE.md; `FigureImagePanelConfiguration` is the shape).
struct FigureCSVImportPanelConfiguration: Equatable {
    let allowedContentTypes: [UTType]
    let canChooseFiles: Bool
    let canChooseDirectories: Bool
    let allowsMultipleSelection: Bool
    let prompt: String
    let message: String

    func apply(to panel: NSOpenPanel) {
        panel.allowedContentTypes = allowedContentTypes
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.prompt = prompt
        panel.message = message
    }
}

/// **Import from CSV… into an expanded table grid** (report plan 7d Task 4,
/// R7d-8): the file's cells replace the table's, matched as a Research
/// return matches (`FigureReturnDiff.changes` with the table as both base and
/// current) — a column keeps its id where its header matches, a row where its
/// values do — so another figure's reference to a kept row or column
/// survives. The controller writes the answer as one visit and one ⌘Z
/// (`applyChanges`). Pure apart from the file read.
enum FigureGridImport {

    /// One file of comma-, semicolon- or tab-separated text.
    static let panelConfiguration = FigureCSVImportPanelConfiguration(
        allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText],
        canChooseFiles: true, canChooseDirectories: false, allowsMultipleSelection: false,
        prompt: "Import", message: "The file's cells replace the table's.")

    /// The undo step's name.
    static let actionName = "Import from CSV"

    /// **The file's text**: UTF-16 with its byte-order mark (Excel's
    /// "Unicode text"), else UTF-8, else Windows-1252 — as a Research table
    /// is read. The URL is the one the writer chose in the panel, not a
    /// synced path.
    nonisolated static func readText(of url: URL) throws -> String {
        let data = try Data(contentsOf: url) // adr-0018-ok: a CSV the writer chose to import into a table figure; not manuscript
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? ""
    }

    /// **A file, read for import** — off the main actor: its text, its
    /// non-empty cells counted (refused past `TableCSV.figureCellLimit`
    /// before anything is parsed), then parsed with the book's locale and
    /// names (T4 review M1).
    enum Outcome: Sendable {
        case tooManyCells(Int)
        case noCells
        case read(FigureTable, [CSVReadProblem])
    }

    /// What `read` parsed: the table and the cells it kept as text.
    struct Read {
        let table: FigureTable
        let problems: [CSVReadProblem]
    }

    nonisolated static func read(_ url: URL, locale: TableLocale, names: FormulaNames) throws -> Outcome {
        let text = try readText(of: url)
        let cells = TableCSV.nonEmptyCellCount(text)
        guard cells <= TableCSV.figureCellLimit else { return .tooManyCells(cells) }
        let read = TableCSV.read(text, locale: locale, names: names)
        guard !read.table.rows.isEmpty, !read.table.columns.isEmpty else { return .noCells }
        return .read(read.table, read.problems)
    }

    // MARK: What the writer is told

    static func tooManyCellsSentence(_ file: String, cells: Int) -> String {
        "Couldn't import “\(file)” — \(cells.formatted()) cells are more than a table can hold "
            + "(\(TableCSV.figureCellLimit.formatted()))."
    }

    static func noCellsSentence(_ file: String) -> String {
        "Couldn't import “\(file)” — it holds no cells."
    }

    /// The file holds exactly what the table does: nothing to write (T4 M3).
    static func unchangedSentence(_ file: String) -> String {
        "“\(file)” matches the table already — nothing changed."
    }

    /// The table's total row was switched off by the import (a file has none).
    static func totalRowOffSentence(_ file: String) -> String {
        "Imported “\(file)”; the total row was switched off — a file has none, so its last row stays data."
    }

    /// The grid closed (folded, or its window closed) before the import ran.
    static func closedSentence(_ file: String) -> String {
        "Couldn't import “\(file)” — the table was closed first."
    }

    /// **The header rows the imported table takes** (R7d-8, `TableCSV`'s
    /// detection): a header when the read found one (a text-only first row
    /// over numbers); none when the file's first row holds anything but text
    /// — a number, a date, a formula — so it is data; otherwise (every row
    /// text) the read cannot tell, and the table keeps what it had.
    static func headerRows(read: FigureTable, current: Int) -> Int {
        if read.headerRows > 0 { return read.headerRows }
        guard let first = read.rows.first else { return current }
        let allText = read.columns.allSatisfy { column in
            switch read[CellKey(row: first, column: column)]?.content {
            case nil, .value(.text)?, .value(.empty)?: return true
            default: return false
            }
        }
        return allText ? current : 0
    }

    /// **What the import appends onto `state`**: the matched return's ops,
    /// then the header setting when it changes, then a total row switched
    /// off — a file has none, and its last row is data, never silently made
    /// the table's total (final review M7). Every change states what it
    /// replaces, so its ⌘Z puts the table back as it was.
    static func changes(onto state: FigureState, read: FigureTable, names: FormulaNames,
                        problems: [CSVReadProblem]) -> FigureReturnDiff.Changes {
        var used = Set(state.table.rowSlots.map(\.id.raw)).union(state.table.columnSlots.map(\.id.raw))
        var changes = FigureReturnDiff.changes(
            from: state, onto: state, to: read, sidecar: nil, names: names, problems: problems,
            mintRow: { let id = TableID.mint(excluding: used); used.insert(id); return RowID(id) },
            mintColumn: { let id = TableID.mint(excluding: used); used.insert(id); return ColumnID(id) })
        let applied = FigureReturnDiff.applied(changes.ops, onto: state)?.table ?? state.table
        let header = headerRows(read: read, current: state.table.headerRows)
        if header != applied.headerRows {
            changes.ops.append(FigureReturnDiff.Change(
                kind: .figureSettings,
                payload: FigureOpPayload(settings: .headerRows(header, prior: applied.headerRows))))
        }
        if applied.hasTotalRow {
            changes.ops.append(FigureReturnDiff.Change(
                kind: .figureSettings, payload: FigureOpPayload(settings: .totalRow(false, prior: true))))
        }
        return changes
    }
}
