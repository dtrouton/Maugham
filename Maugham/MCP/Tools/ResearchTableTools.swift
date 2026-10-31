import Foundation
import MaughamCore

/// `write_research_cells(project_id, item_id, cells, header_rows?, total_row?)`
/// — the assistant writes cells into a Research table (report plan 9d Task 4,
/// spec §10.1 "Research tables are writable by the AI"). **A write tool**:
/// its destination is Research, which is unsigned; "assistant" is a label on
/// the save, never a signature.
///
/// The write goes through the table's one door: `DocumentStore.openResearchTable`
/// (the open grid's own host when one is open, so it shows the change live),
/// then `ResearchTableHost.assistantEdit`, which saves the writer's pending
/// edits first as the writer's, keeps the version before the write, and
/// stamps the save `.assistant`; then the host is let go. A figure pinning
/// the table goes "changed" as after any save (the host invalidates the
/// cards). Each `value` is the machine form `add_suggested_change` takes
/// (`FigureAnnotationOps.suggestedCell`: `.` decimal, no grouping, `'` for
/// text, `=` formulas by A1, empty clears); each `format` is the `CellFormat`
/// JSON `read_figure` emits. A cell past the edge grows the table; nothing
/// here deletes a row or column (the plan's ruling). Every cell is checked
/// before anything is written: one bad address or value refuses the whole
/// call.
public enum WriteResearchCellsTool: MCPTool {
    public static let method = "write_research_cells"
    public static let description = """
        Write cells into a Research table (a CSV in the project's Research, \
        by its item_id from list_research). cells: [{a1, value?, format?}] — \
        a1 like "B3"; value in machine form: numbers with "." for the decimal \
        and no grouping (1500, 1234.5; a comma in a number is refused), text \
        as is (prefix ' to force text), "=" formulas with A1 references \
        (=SUM(B2:B4)), an empty string clears the cell; format is the format \
        object read_figure / read_research_table return for a cell. Each cell \
        needs a value or a format. A cell past the table's edge adds the rows \
        and columns it needs; rows and columns are never deleted. \
        header_rows (0 or 1) and total_row (true/false) set the table's \
        header and total row. The writer's unsaved edits are saved first, and \
        the version before your write is kept in the table's version history, \
        marked as written by the assistant, so the writer can restore it. \
        Refused, writing nothing, for an unknown item, an item that is not a \
        table, an invalid A1 address or a value that does not read.
        """
    public static let inputSchemaJSON = #"""
        {"type":"object","properties":{"project_id":{"type":"string"},"item_id":{"type":"string","description":"The Research table's item id (list_research)."},"cells":{"type":"array","items":{"type":"object","properties":{"a1":{"type":"string","description":"The cell, e.g. B3."},"value":{"type":"string","description":"Machine form: 1234.5, text, 'text, =SUM(B2:B4); empty clears."},"format":{"type":"object","description":"A cell format as read_figure returns it."}},"required":["a1"]}},"header_rows":{"type":"integer","enum":[0,1]},"total_row":{"type":"boolean"}},"required":["project_id","item_id","cells"]}
        """#

    public struct Params: Codable {
        public let project_id: String
        public let item_id: String
        public let cells: [ResearchTableCellParam]
        public let header_rows: Int?
        public let total_row: Bool?
    }

    struct Result: Codable, Equatable {
        let item_id: String
        let title: String
        let rows: Int
        let columns: Int
        let cells_written: Int
        let rows_added: Int
        let columns_added: Int
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try ResearchTableToolSupport.decode(Params.self, from: paramsJSON, method: method)
        let entry = try resolveProject(params.project_id, in: registry)
        let ds = try ResearchTableToolSupport.documentStore(of: entry)
        let item = try ResearchTableToolSupport.tableItem(params.item_id, in: entry.store)
        let edits = try ResearchTableToolSupport.edits(params.cells)
        if let header = params.header_rows, !(0...1).contains(header) {
            throw MCPError.invalidArgument("header_rows must be 0 or 1.")
        }
        guard !edits.isEmpty || params.header_rows != nil || params.total_row != nil else {
            throw MCPError.invalidArgument("Nothing to write: pass cells, header_rows or total_row.")
        }
        let names = try await ResearchTableToolSupport.formulaNames(ds)
        let host = try await ResearchTableToolSupport.open(item, in: ds)
        let before = (rows: host.state.table.rows.count, columns: host.state.table.columns.count)
        do {
            try await host.assistantEdit { table in
                try ResearchTableToolSupport.apply(edits, to: &table, names: names)
                if let header = params.header_rows { table.headerRows = header }
                if let total = params.total_row { table.hasTotalRow = total }
            }
        } catch {
            await ds.releaseResearchTable(host)
            throw ResearchTableToolSupport.mcpError(error)
        }
        let after = host.state.table
        await ds.releaseResearchTable(host)
        return try JSONEncoder().encode(Result(
            item_id: item.id, title: item.title, rows: after.rows.count, columns: after.columns.count,
            cells_written: edits.count, rows_added: max(after.rows.count - before.rows, 0),
            columns_added: max(after.columns.count - before.columns, 0)))
    }
}

/// One cell of `write_research_cells` / `create_research_table`: its A1
/// address, a value in machine form, a `CellFormat` as `read_figure` emits.
public struct ResearchTableCellParam: Codable {
    public let a1: String
    public let value: String?
    public let format: CellFormat?
}

/// What the Research table tools share: the decoding that names a bad field,
/// the item lookup, the cell checks and the edit itself.
enum ResearchTableToolSupport {

    /// One checked cell: its 0-based position and what it sets.
    struct Edit {
        let a1: String
        let row: Int
        let column: Int
        let value: String?
        let format: CellFormat?
    }

    /// The params, or a refusal naming the field that would not read (a
    /// `format` that is not `read_figure`'s shape, say).
    static func decode<P: Decodable>(_ type: P.Type, from json: Data?, method: String) throws -> P {
        guard let json else { throw MCPError.invalidArgument("missing parameters for \(method)") }
        do {
            return try JSONDecoder().decode(P.self, from: json)
        } catch let error as DecodingError {
            let (path, why): ([CodingKey], String) = {
                switch error {
                case .keyNotFound(let key, let c): return (c.codingPath + [key], "is missing")
                case .typeMismatch(_, let c): return (c.codingPath, "has the wrong type")
                case .valueNotFound(_, let c): return (c.codingPath, "is missing")
                case .dataCorrupted(let c): return (c.codingPath, "does not read")
                @unknown default: return ([], "does not read")
                }
            }()
            let field = path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            let named = field.hasPrefix(".") ? String(field.dropFirst()) : field
            throw MCPError.invalidArgument(
                "malformed parameters for \(method): \(named.isEmpty ? "the request" : named) \(why)"
                    + (named.contains("format") ? " (pass a cell's format exactly as read_figure returns it)" : "")
                    + ".")
        } catch {
            throw MCPError.invalidArgument("malformed parameters for \(method)")
        }
    }

    @MainActor
    static func documentStore(of entry: ProjectRegistry.Entry) throws -> DocumentStore {
        guard let ds = entry.store.documentStore else {
            throw MCPError.invalidArgument("The project's window is not ready for a Research table.")
        }
        return ds
    }

    /// The Research table `itemId` names; an unknown id, or an item that is
    /// not a table, is refused (tools fail loudly on unknown ids).
    @MainActor
    static func tableItem(_ itemId: String, in store: ProjectStore) throws -> ResearchItem {
        guard let item = store.findResearchItem(id: itemId, in: store.manifest.research) else {
            throw MCPError.invalidArgument("No Research item with id '\(itemId)'. Use list_research for the ids.")
        }
        guard item.type == .asset, item.kind == .table, item.path != nil else {
            throw MCPError.invalidArgument(
                "'\(item.title)' (\(itemId)) is not a Research table; only a CSV or TSV table in Research takes cells.")
        }
        return item
    }

    /// The names a Research table's formulas resolve through (the grid's).
    @MainActor
    static func formulaNames(_ ds: DocumentStore) async throws -> FormulaNames {
        do {
            return try await ds.formulaNamesForUse()
        } catch {
            throw MCPError.invalidArgument("The book's figures could not be read: \(error.localizedDescription)")
        }
    }

    /// The table's host (the open grid's, when one is open); the caller lets it go.
    @MainActor
    static func open(_ item: ResearchItem, in ds: DocumentStore) async throws -> ResearchTableHost {
        do {
            return try await ds.openResearchTable(itemId: item.id)
        } catch let tooLarge as ResearchTableHost.TooLarge {
            throw MCPError.invalidArgument(
                "'\(item.title)' has \(tooLarge.cells) cells, more than a Research table edits "
                    + "(\(TableCSV.figureCellLimit)); read it with read_document instead.")
        } catch {
            throw mcpError(error)
        }
    }

    /// A host's refusal in the caller's words.
    static func mcpError(_ error: Error) -> Error {
        if error is MCPError { return error }
        return MCPError.invalidArgument(error.localizedDescription)
    }

    /// Each cell checked: a valid A1 address, written once, with a value or a
    /// format. Nothing is written when one fails.
    static func edits(_ cells: [ResearchTableCellParam]) throws -> [Edit] {
        var seen: [String: String] = [:]
        return try cells.map { cell in
            guard let a = A1.parse(cell.a1.trimmingCharacters(in: .whitespaces)) else {
                throw MCPError.invalidArgument(
                    "'\(cell.a1)' is not an A1 cell address; use a form like \"B3\" (one cell, no range).")
            }
            let at = A1.columnLetters(a.column) + String(a.row + 1)
            if let first = seen[at] {
                throw MCPError.invalidArgument("\(at) is written twice ('\(first)' and '\(cell.a1)'); write each cell once.")
            }
            seen[at] = cell.a1
            guard cell.value != nil || cell.format != nil else {
                throw MCPError.invalidArgument("\(at) has neither a value nor a format.")
            }
            return Edit(a1: at, row: a.row, column: a.column, value: cell.value, format: cell.format)
        }
    }

    /// **`edits` made in `table`**: rows and columns added at the end until
    /// every cell is inside (never past `TableCSV.figureCellLimit` cells in
    /// all), then each value read in machine form against the grown table —
    /// so a formula may name a cell this call added — and each format laid
    /// on. Throws, changing nothing the caller keeps, on a value that does
    /// not read.
    static func apply(_ edits: [Edit], to table: inout FigureTable, names: FormulaNames) throws {
        let rows = max(table.rows.count, (edits.map(\.row).max() ?? -1) + 1)
        let columns = max(table.columns.count, (edits.map(\.column).max() ?? -1) + 1)
        if rows > table.rows.count || columns > table.columns.count, rows * columns > TableCSV.figureCellLimit {
            throw MCPError.invalidArgument(
                "Writing there would grow the table to \(rows) rows × \(columns) columns, "
                    + "past the \(TableCSV.figureCellLimit) cells a Research table edits.")
        }
        while table.rows.count < rows { _ = table.insertRow(after: table.rows.last) }
        while table.columns.count < columns { _ = table.insertColumn(after: table.columns.last) }
        for edit in edits {
            let key = CellKey(row: table.rows[edit.row], column: table.columns[edit.column])
            var cell = table[key]
            if let value = edit.value {
                switch FigureAnnotationOps.suggestedCell(from: value, at: key, table: table, names: names) {
                case .success(let made): cell = made
                case .failure(let error):
                    throw MCPError.invalidArgument(
                        "\(edit.a1): '\(value)' does not read: \(error.message). Use machine form: 1234.5, text, 'text, =SUM(B2:B4).")
                }
            }
            if let format = edit.format {
                var formatted = cell ?? Cell(content: .value(.empty))
                formatted.format = format
                // An empty cell with nothing to keep is no cell.
                let bare = formatted.content == .value(.empty) && format == CellFormat()
                    && formatted.alignment == .automatic
                cell = bare ? nil : formatted
            }
            table.setCell(cell, at: key)
        }
    }
}
