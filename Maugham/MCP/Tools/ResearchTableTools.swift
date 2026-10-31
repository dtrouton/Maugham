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
        and columns it needs; rows and columns are never deleted. A table \
        that ends in a total row refuses to grow below it unless the same \
        call passes total_row (set total_row: false to write below it, then \
        true again). \
        header_rows (0 or 1) and total_row (true/false) set the table's \
        header and total row. The writer's unsaved edits are saved first, and \
        the version before your write is kept in the table's version history, \
        marked as written by the assistant, so the writer can restore it. \
        Refused, writing nothing, for an unknown item, an item that is not a \
        table, an invalid A1 address or a value that does not read.
        """
    public static let inputSchemaJSON = #"""
        {"type":"object","properties":{"project_id":{"type":"string"},"item_id":{"type":"string","description":"The Research table's item id (list_research)."},"cells":{"type":"array","items":{"type":"object","properties":{"a1":{"type":"string","description":"The cell, e.g. B3."},"value":{"type":"string","description":"Machine form: 1234.5, text, 'text, =SUM(B2:B4); empty clears."},"format":{"type":"object","description":"A cell format as read_figure returns it."}},"required":["a1"]}},"header_rows":{"type":"integer","enum":[0,1]},"total_row":{"type":"boolean"}},"required":["project_id","item_id"]}
        """#

    public struct Params: Codable {
        public let project_id: String
        public let item_id: String
        public let cells: [ResearchTableCellParam]?
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
        try ResearchTableToolSupport.refuseUnderAViewOnlyShare(entry)
        let ds = try ResearchTableToolSupport.documentStore(of: entry)
        let item = try ResearchTableToolSupport.tableItem(params.item_id, in: entry.store)
        let edits = try ResearchTableToolSupport.edits(params.cells ?? [])
        if let header = params.header_rows, !(0...1).contains(header) {
            throw MCPError.invalidArgument("header_rows must be 0 or 1.")
        }
        guard !edits.isEmpty || params.header_rows != nil || params.total_row != nil else {
            throw MCPError.invalidArgument("Nothing to write: pass cells, header_rows or total_row.")
        }
        let names = try await ResearchTableToolSupport.formulaNames(ds)
        let host = try await ResearchTableToolSupport.open(item, in: ds)
        // Measured in the edit, after the writer's pending edits have landed.
        var before = (rows: 0, columns: 0)
        do {
            try await host.assistantEdit { table in
                before = (table.rows.count, table.columns.count)
                try ResearchTableToolSupport.apply(edits, to: &table, names: names,
                                                   setsTotalRow: params.total_row != nil)
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

/// `create_research_table(project_id, title, scope?, cells?, header_rows?)` —
/// a new Research table made holding the assistant's cells (report plan 9d
/// Task 5). **A write tool** into Research. The table is made with its
/// content (`ProjectStore.createResearchTable(scope:title:content:)`), so
/// there is no blank first version; its sidecar says the assistant wrote it,
/// so the version a later save keeps of it is marked so. Without cells it is
/// New Table's blank four rows by three columns. The cells are checked as
/// `write_research_cells` checks them, before anything is made.
public enum CreateResearchTableTool: MCPTool {
    public static let method = "create_research_table"
    public static let description = """
        Create a Research table (a CSV in the project's Research) titled \
        `title` (deduplicated: "Budget 2" when "Budget" is taken), filled \
        with `cells` ([{a1, value?, format?}] exactly as write_research_cells \
        takes them: machine-form values, "=" formulas with A1 references, \
        read_figure's format objects). The table is as large as the cells \
        need; with no cells it is a blank 4 × 3 table. header_rows is 0 or 1 \
        (default 1). scope is "shared" (default) or a manuscript document's \
        id (the table goes where a new research note for that document \
        would go). Returns the new item_id for write_research_cells and \
        read_research_table.
        """
    public static let inputSchemaJSON = #"""
        {"type":"object","properties":{"project_id":{"type":"string"},"title":{"type":"string"},"scope":{"type":"string","description":"\"shared\" (default) or a manuscript document id."},"cells":{"type":"array","items":{"type":"object","properties":{"a1":{"type":"string"},"value":{"type":"string"},"format":{"type":"object"}},"required":["a1"]}},"header_rows":{"type":"integer","enum":[0,1]}},"required":["project_id","title"]}
        """#

    public struct Params: Codable {
        public let project_id: String
        public let title: String
        public let scope: String?
        public let cells: [ResearchTableCellParam]?
        public let header_rows: Int?
    }

    struct Result: Codable, Equatable {
        let item_id: String
        let title: String
        let path: String
        let rows: Int
        let columns: Int
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try ResearchTableToolSupport.decode(Params.self, from: paramsJSON, method: method)
        let entry = try resolveProject(params.project_id, in: registry)
        try ResearchTableToolSupport.refuseUnderAViewOnlyShare(entry)
        let ds = try ResearchTableToolSupport.documentStore(of: entry)
        let store = entry.store
        let scope: ResearchScope
        switch params.scope?.trimmingCharacters(in: .whitespaces) {
        case nil, "", "shared": scope = .shared
        case let id?:
            guard store.isResearchScopeTarget(id) else {
                throw MCPError.invalidArgument(
                    "scope '\(id)' is neither \"shared\" nor a manuscript document that takes research (get_outline lists the ids).")
            }
            scope = .document(id)
        }
        if let header = params.header_rows, !(0...1).contains(header) {
            throw MCPError.invalidArgument("header_rows must be 0 or 1.")
        }
        let edits = try ResearchTableToolSupport.edits(params.cells ?? [])
        let names = try await ResearchTableToolSupport.formulaNames(ds)
        var table: FigureTable
        if edits.isEmpty {
            table = FigureTable(rows: ProjectStore.blankResearchTableShape.rows,
                                columns: ProjectStore.blankResearchTableShape.columns)
        } else {
            table = FigureTable(rows: 1, columns: 1)
            try ResearchTableToolSupport.apply(edits, to: &table, names: names, setsTotalRow: true)
        }
        table.headerRows = params.header_rows ?? 1
        let content = ProjectStore.ResearchTableContent(
            table: table, locale: TableLocale(languageTag: await store.bookLanguageTag()), names: names,
            writtenBy: .assistant)
        let item: ResearchItem
        do {
            item = try await store.createResearchTable(scope: scope, title: params.title, content: content)
        } catch {
            throw ResearchTableToolSupport.mcpError(error)
        }
        return try JSONEncoder().encode(Result(
            item_id: item.id, title: item.title, path: item.path ?? "",
            rows: table.rows.count, columns: table.columns.count))
    }
}

/// `read_research_table(project_id, item_id, range?)` — a Research table's
/// cells with their computed values (report plan 9d Task 5). **Read-only.**
///
/// The table is the host's (`openResearchTable`: an open grid's unsaved
/// edits included), let go at once; its values are computed as the grid
/// computes them — the book assembled (`DocumentStore.assembledFigures()`)
/// with the table laid over it under its item id (`FigureWorkbook.overlay`)
/// — and rendered by `read_figure`'s own renderer (`ReadFigureTool.table`),
/// so the two tools answer one cell shape. A `research:` reference inside a
/// Research table reads through pins, and a Research table has none, so it
/// reads empty or `#REF!` here (the plan's ruling): `research_reads` names
/// those cells and `note` says why. Past the text budget it is refused with
/// a hint naming `range`.
public enum ReadResearchTableTool: MCPTool {
    public static let method = "read_research_table"
    public static let description = """
        Read a Research table (by item_id from list_research) with computed \
        values. Returns {item_id, name, kind, rows, columns, header_rows, \
        total_row, range, cells, text, research_reads, note}: cells and text \
        exactly as read_figure returns them (a1, value as displayed, raw \
        typed value, formula, format). Pass `range` (A1, e.g. "A1:C10" or \
        "B3") to read part of a large table; without it a table too large \
        for one response is refused with a hint naming range. Formulas that \
        read another Research table (research:name!B2) compute only through \
        a figure's pins, and a Research table has none, so such cells read \
        empty or #REF! here; research_reads lists them and note says so (note \
        also says when the book's figures could not be read, so figure \
        references read #REF!); null when there is nothing to say. \
        Read-only.
        """
    public static let inputSchemaJSON = #"""
        {"type":"object","properties":{"project_id":{"type":"string"},"item_id":{"type":"string","description":"The Research table's item id (list_research)."},"range":{"type":"string","description":"An A1 range such as A1:C10, or one cell such as B3."}},"required":["project_id","item_id"]}
        """#

    public struct Params: Codable {
        public let project_id: String
        public let item_id: String
        public let range: String?
    }

    struct Result: Codable {
        let item_id: String
        let name: String
        let kind: String
        let rows: Int
        let columns: Int
        let header_rows: Int
        let total_row: Bool
        let range: String
        let cells: [ReadFigureTool.Cell]
        let text: String
        let research_reads: [String]
        /// Why some values here are not what the grid would show: cells that
        /// read Research, or a book that would not assemble; `null` when none.
        let note: String?

        private enum CodingKeys: String, CodingKey {
            case item_id, name, kind, rows, columns, header_rows, total_row, range, cells, text, research_reads, note
        }

        /// `note` is a fact: `null` when no cell reads Research, never absent.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(item_id, forKey: .item_id)
            try c.encode(name, forKey: .name)
            try c.encode(kind, forKey: .kind)
            try c.encode(rows, forKey: .rows)
            try c.encode(columns, forKey: .columns)
            try c.encode(header_rows, forKey: .header_rows)
            try c.encode(total_row, forKey: .total_row)
            try c.encode(range, forKey: .range)
            try c.encode(cells, forKey: .cells)
            try c.encode(text, forKey: .text)
            try c.encode(research_reads, forKey: .research_reads)
            try c.encode(note, forKey: .note)
        }
    }

    /// What `note` says when the book's figures would not assemble.
    static let bookUnreadNote = "The book's figures could not be read just now, so a formula that names a "
        + "figure (tbl:…) reads #REF! here though it may compute in the grid."

    /// What `note` says when cells read another Research table.
    static func researchNote(_ cells: [String]) -> String {
        "\(cells.joined(separator: ", ")) \(cells.count == 1 ? "reads" : "read") another Research table "
            + "(research:…). Inside a Research table such a reference computes only through a figure's "
            + "pins, and a Research table has none, so it reads empty or #REF! here. A figure whose "
            + "formula reads the same cells computes them."
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try ResearchTableToolSupport.decode(Params.self, from: paramsJSON, method: method)
        let entry = try resolveProject(params.project_id, in: registry)
        let ds = try ResearchTableToolSupport.documentStore(of: entry)
        let item = try ResearchTableToolSupport.tableItem(params.item_id, in: entry.store)
        let host = try await ResearchTableToolSupport.open(item, in: ds)
        let table = host.state.table
        await ds.releaseResearchTable(host)

        let names = try await ResearchTableToolSupport.formulaNames(ds)
        var book: Workbook
        var notes: [String] = []
        if var assembled = try? await ds.assembledFigures() {
            assembled.overlay(FigureState(kind: .table, table: table), id: item.id)
            book = assembled.workbook
        } else {
            book = Workbook(pins: FigurePinIndex())
            book.setTable(table, id: item.id)
            notes.append(bookUnreadNote)
        }
        let locale = TableLocale(languageTag: await entry.store.bookLanguageTag())
        let rendered = try ReadFigureTool.table(
            id: item.id, name: item.title, table: table, book: book, names: names,
            range: params.range, locale: locale)
        let reads = FigurePins.reads(of: table, parked: [:]).keys
            .compactMap { key -> (Int, Int, String)? in
                guard let r = table.rowIndex(of: key.row), let c = table.columnIndex(of: key.column) else { return nil }
                return (r, c, A1.columnLetters(c) + String(r + 1))
            }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)
        let result = Result(
            item_id: item.id, name: item.title, kind: "table", rows: rendered.rows, columns: rendered.columns,
            header_rows: table.headerRows, total_row: table.hasTotalRow, range: rendered.range,
            cells: rendered.cells, text: rendered.text, research_reads: reads,
            note: (notes + (reads.isEmpty ? [] : [researchNote(reads)])).joined(separator: " ").nilIfEmpty)
        return try MCPResponseBudget.enforce(
            try JSONEncoder().encode(result),
            hint: "The table is too large to return in one MCP response. "
                + "Pass `range` (an A1 range such as \"A1:C50\") to read part of it at a time.")
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

        /// Clears with nothing to keep: no value or an empty one, and no
        /// format or the default.
        var makesNothing: Bool {
            (value ?? "").isEmpty && (format ?? CellFormat()) == CellFormat()
        }
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

    /// A read-only iCloud share takes no Research table write, grid open or
    /// not (the grid's own sentence).
    @MainActor
    static func refuseUnderAViewOnlyShare(_ entry: ProjectRegistry.Entry) throws {
        try MCPShareLock.refuseUnderAViewOnlyShare(entry.url, sentence: FigureGridGate.Reason.viewOnlyShare.sentence)
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
    ///
    /// A cell that makes nothing (no value or an empty one, and no format or
    /// the default) grows nothing: past the edge it is skipped. Rows grown
    /// below a total row would make the new last row the total and push the
    /// old total into the body, so that is refused unless the call sets the
    /// total row itself (`setsTotalRow`).
    static func apply(_ edits: [Edit], to table: inout FigureTable, names: FormulaNames,
                      setsTotalRow: Bool) throws {
        let growing = edits.filter { !$0.makesNothing }
        let rows = max(table.rows.count, (growing.map(\.row).max() ?? -1) + 1)
        let columns = max(table.columns.count, (growing.map(\.column).max() ?? -1) + 1)
        if rows > table.rows.count, table.hasTotalRow, !setsTotalRow {
            throw MCPError.invalidArgument(
                "This table ends in a total row (row \(table.rows.count)) — set total_row: false to write below it, "
                    + "then total_row: true again, or ask the writer to insert rows above the total.")
        }
        if rows > table.rows.count || columns > table.columns.count, rows * columns > TableCSV.figureCellLimit {
            throw MCPError.invalidArgument(
                "Writing there would grow the table to \(rows) rows × \(columns) columns, "
                    + "past the \(TableCSV.figureCellLimit) cells a Research table edits.")
        }
        while table.rows.count < rows { _ = table.insertRow(after: table.rows.last) }
        while table.columns.count < columns { _ = table.insertColumn(after: table.columns.last) }
        for edit in edits where edit.row < table.rows.count && edit.column < table.columns.count {
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
