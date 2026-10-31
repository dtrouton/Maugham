import Foundation
import MaughamCore

/// `list_figures(project_id, kind?)` — the book's figures (report plan 9b
/// Task 7, spec §10.1): what the Figures section of the tree shows, plus the
/// figures parked in Research, which the tree hides. **Read-only**: Claude
/// never edits a figure.
///
/// Rows come from `FigureListingSource` (the window's own numbering, with no
/// window); pins, `changed` and `parked` from `ProjectStore.publishFigures()`.
/// A figure parked in Research is listed with `status: "in_research"`, because
/// Claude reasoning about a `@tbl:` reference needs to know it went there.
public enum ListFiguresTool: MCPTool {
    public static let method = "list_figures"
    public static let description = """
        List the book's figures (tables and images): id, name, kind, number \
        ("Table 2"; "—" when no line uses it), caption, status ("used", \
        "unused", or "in_research" for a figure parked in Research), \
        used_in (each line that places it: document title, document_id, \
        0-based line), reads_research (its formulas read Research or a parked \
        figure), pins_unread (true when it reads Research but its sources \
        would not read, so an empty pins is not \"no pins\"), pins (each source it reads and where it stands: current, \
        source_changed, source_missing, unpinned) and changed (a pinned \
        source or its own Research source has moved on). `kind` filters to \
        "table" or "image". Read-only.
        """
    public static let inputSchemaJSON = #"""
        {"type":"object","properties":{"project_id":{"type":"string"},"kind":{"type":"string","enum":["table","image"],"description":"Only figures of this kind."}},"required":["project_id"]}
        """#

    public struct Params: Codable {
        public let project_id: String
        public let kind: String?
    }

    struct Use: Codable, Equatable {
        let document: String
        let document_id: String
        let line: Int
    }
    struct Pin: Codable, Equatable {
        let source: String
        let source_name: String?
        let status: String
    }
    struct Figure: Codable, Equatable {
        let id: String
        let name: String
        let kind: String
        let number: String
        let caption: String
        let status: String
        let used_in: [Use]
        let reads_research: Bool
        let pins_unread: Bool
        let pins: [Pin]
        let changed: Bool
    }
    struct Result: Codable { let figures: [Figure] }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        if let kind = params.kind, !["table", "image"].contains(kind) {
            throw MCPError.invalidArgument("kind must be \"table\" or \"image\"")
        }
        let store = entry.store
        let rows = await FigureListingSource.rows(store: store)
        let snapshot = await store.publishFigures()
        let titles = Dictionary(
            TreeWalk.collect(in: store.manifest.structure, where: { $0.path != nil }).map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first })
        var figures = entries(rows: rows, snapshot: snapshot, documentTitles: titles) { id in
            TreeWalk.find(id: id, in: store.manifest.research)?.title
        }
        if let kind = params.kind { figures = figures.filter { $0.kind == kind } }

        return try MCPResponseBudget.enforce(
            try JSONEncoder().encode(Result(figures: figures)),
            hint: "The figure list is too large to return in one MCP response. "
                + "Pass `kind` (\"table\" or \"image\") to list one kind at a time.")
    }


    /// The wire entries: the listing's own order (reading order, then unused
    /// by name; the listing registers every record, so a parked figure sits
    /// among the unused with `status: "in_research"`). Records the listing has
    /// no row for but that are parked come last, by name: a guard for a
    /// listing that drops them, which `FigureListing.build` does not. Pure, so
    /// a test can hand it a snapshot the disk cannot easily produce.
    ///
    /// `reads_research` is asked of the figure's own state
    /// (`FigurePins.reads(of:parked:tables:)`, the rule the card uses, which
    /// counts a read of a parked figure too), never of whether its sources
    /// read. A figure that reads Research yet has no `pinStatus` (its sources
    /// would not read, or the registry would not) says `pins_unread: true`,
    /// so an empty `pins` is not taken for "no pins".
    static func entries(
        rows: [FigureListing.Row], snapshot: PublishFigures, documentTitles titles: [String: String],
        researchTitle: (String) -> String?
    ) -> [Figure] {
        let byId = Dictionary(rows.map { ($0.figureId, $0) }, uniquingKeysWith: { first, _ in first })
        let recordsById = Dictionary(snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hidden = snapshot.records.filter { byId[$0.id] == nil && snapshot.parked.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let tables = snapshot.workbook?.tables ?? [:]
        let parkedTables = snapshot.parked.reduce(into: [String: FigureTable]()) { out, id in
            if let table = tables[id] { out[id] = table }
        }

        func figure(_ record: FigureRecord, row: FigureListing.Row?) -> Figure {
            let statuses = snapshot.pinStatus[record.id] ?? [:]
            let pins = statuses.sorted { $0.key < $1.key }.map { source, status in
                Pin(source: source, source_name: researchTitle(source) ?? recordsById[source]?.name,
                    status: wire(status))
            }
            let pinChanged = statuses.values.contains { if case .sourceChanged = $0 { true } else { false } }
            let reads = snapshot.states[record.id].map {
                !FigurePins.reads(of: $0.table, parked: parkedTables, tables: tables).isEmpty
            } ?? false
            let parked = snapshot.parked.contains(record.id)
            return Figure(
                id: record.id, name: record.name, kind: record.kind.rawValue,
                number: row?.number ?? FigureListing.unusedNumber, caption: row?.caption ?? "",
                status: parked ? "in_research" : (row?.isUnused ?? true ? "unused" : "used"),
                used_in: (row?.usedIn ?? []).map {
                    Use(document: titles[$0.docId] ?? $0.docId, document_id: $0.docId, line: $0.lineIndex)
                },
                reads_research: reads, pins_unread: reads && statuses.isEmpty, pins: pins,
                changed: pinChanged || snapshot.sourceChanged.contains(record.id))
        }
        var out: [Figure] = []
        for row in rows {
            guard let record = recordsById[row.figureId] else {
                projectStoreLog.error(
                    "list_figures: the listing has a row for \(row.figureId, privacy: .public) but the registry has no such figure; skipped")
                continue
            }
            out.append(figure(record, row: row))
        }
        return out + hidden.map { figure($0, row: nil) }
    }

    private static func wire(_ status: PinStatus) -> String {
        switch status {
        case .current: return "current"
        case .sourceChanged: return "source_changed"
        case .sourceMissing: return "source_missing"
        case .unpinned: return "unpinned"
        }
    }
}

/// `read_figure(project_id, name, range?, region?, max_dimension?, quality?)` —
/// one figure's content (report plan 9b Task 8, spec §10.1). **Read-only.**
///
/// A table answers its cells by A1 address, each with `value` (the display
/// string in the book's language, as the card and the printed table show it),
/// `raw` (the typed `CellValue`), `formula` (by current names, absent for a
/// value) and `format`, plus `text`, the pipe table of the cells returned. An
/// image answers a JPEG crop on demand (`ImageResponseBuilder`, tripwire 10).
/// Values come from the publish snapshot (op logs through the workbook), never
/// from the rendered `.csv` files under figures/ (tripwire 20). A figure parked in Research reads its
/// parked state.
public enum ReadFigureTool: MCPTool {
    public static let method = "read_figure"
    public static let description = """
        Read one figure by name (its registry name, or its tbl:/fig: label). \
        A table returns {name, kind, rows, columns, range, cells, text}: each \
        cell has a1, value (the display string in the book's language), raw \
        (the typed value, always {type, value}: {type:"number",value:1334.5}, \
        {type:"text",value:"Rent"}, {type:"bool",value:true}, \
        {type:"date",value:<day serial>,iso:"2026-10-31"}, \
        {type:"error",value:"#REF!"} or {type:"empty"} with no value), formula (like "=SUM(B2:B3)", only for a formula cell) \
        and format; text is the cells as a pipe table with column letters as \
        its header. Pass `range` (A1, e.g. "A1:C10" or "B3") to read part of a \
        large table; without it a table too large for one response is refused \
        with a hint naming range. An image returns a downscaled JPEG (default \
        2048 px longest edge, quality 85); use `region` (normalized 0-1, \
        top-left origin) to crop in. A figure parked in Research reads its \
        parked state. Read-only.
        """
    public static let inputSchemaJSON = #"""
        {"type":"object","properties":{"project_id":{"type":"string"},"name":{"type":"string","description":"The figure's name, or its tbl:name / fig:name label."},"range":{"type":"string","description":"Tables only: an A1 range such as A1:C10, or one cell such as B3."},"max_dimension":{"type":"integer","description":"Longest-edge cap for an image figure (256–4096, default 2048). Ignored for tables."},"quality":{"type":"integer","description":"JPEG quality 10–100 for an image figure (default 85). Ignored for tables."},"region":{"type":"object","description":"Optional crop for an image figure, normalized 0–1, top-left origin. e.g. {x:0.3,y:0.5,width:0.2,height:0.1}. Ignored for tables.","properties":{"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"}},"required":["x","y","width","height"]}},"required":["project_id","name"]}
        """#

    public struct Params: Codable {
        public let project_id: String
        public let name: String
        public let range: String?
        public let max_dimension: Int?
        public let quality: Int?
        public let region: ImageResponseBuilder.Region?
    }

    /// A `CellValue` in a JSON-friendly typed form. **One wire shape:**
    /// `{type, value}` (number: a number; text: a string; bool: a boolean;
    /// date: the day serial, plus `iso`; error: its code, e.g. "#REF!"; empty:
    /// no `value`). The stored properties below are the Swift side only.
    struct Raw: Codable, Equatable {
        let type: String
        let number: Double?
        let text: String?
        let bool: Bool?
        let serial: Int?
        let iso: String?

        init(_ value: CellValue) {
            func make(_ type: String, number: Double? = nil, text: String? = nil, bool: Bool? = nil,
                      serial: Int? = nil, iso: String? = nil) -> (String, Double?, String?, Bool?, Int?, String?) {
                (type, number, text, bool, serial, iso)
            }
            let f: (String, Double?, String?, Bool?, Int?, String?)
            switch value {
            case .empty: f = make("empty")
            case .number(let x): f = make("number", number: x)
            case .text(let s): f = make("text", text: s)
            case .bool(let b): f = make("bool", bool: b)
            case .date(let serial): f = make("date", serial: serial, iso: DateSerial.isoString(serial))
            case .error(let e): f = make("error", text: e.rawValue)
            }
            (type, number, text, bool, serial, iso) = f
        }

        private enum CodingKeys: String, CodingKey { case type, value, iso }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(type, forKey: .type)
            switch type {
            case "number": try c.encode(number, forKey: .value)
            case "text", "error": try c.encode(text, forKey: .value)
            case "bool": try c.encode(bool, forKey: .value)
            case "date":
                try c.encode(serial, forKey: .value)
                try c.encode(iso, forKey: .iso)
            default: break
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            number = type == "number" ? try c.decode(Double.self, forKey: .value) : nil
            text = type == "text" || type == "error" ? try c.decode(String.self, forKey: .value) : nil
            bool = type == "bool" ? try c.decode(Bool.self, forKey: .value) : nil
            serial = type == "date" ? try c.decode(Int.self, forKey: .value) : nil
            iso = try c.decodeIfPresent(String.self, forKey: .iso)
        }
    }
    struct Cell: Codable, Equatable {
        let a1: String
        let value: String
        let raw: Raw
        let formula: String?
        let format: CellFormat
    }
    struct TableResult: Codable {
        let name: String
        let kind: String
        let rows: Int
        let columns: Int
        let range: String
        let cells: [Cell]
        let text: String
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let store = entry.store
        let snapshot = await store.publishFigures()
        let record = try find(params.name, in: snapshot.records)
        switch record.kind {
        case .image:
            return try imageEnvelope(record: record, state: snapshot.states[record.id],
                                     params: params, projectURL: entry.url)
        case .table:
            guard let state = snapshot.states[record.id], state.kind == .table else {
                throw MCPError.invalidArgument("Figure '\(record.name)' could not be read (its op log would not fold).")
            }
            let locale = TableLocale(languageTag: await store.bookLanguageTag())
            let result = try table(record: record, state: state, snapshot: snapshot, research: store.manifest.research,
                                   range: params.range, locale: locale)
            return try MCPResponseBudget.enforce(
                try JSONEncoder().encode(result),
                hint: "The table is too large to return in one MCP response. "
                    + "Pass `range` (an A1 range such as \"A1:C50\") to read part of it at a time.")
        case .unknown(let word):
            throw MCPError.invalidArgument("Figure '\(record.name)' is of a kind this build cannot read (\(word)).")
        }
    }

    // MARK: - Finding

    /// The record `name` names: its registry name or its `tbl:`/`fig:` label,
    /// without regard to case. Unknown: the error lists the nearest names.
    static func find(_ name: String, in records: [FigureRecord]) throws -> FigureRecord {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        let bare: String = {
            guard let label = ManuscriptLabel(reference: wanted) else { return wanted }
            return label.name
        }()
        let folded = bare.lowercased()
        let named = records.filter { $0.name.lowercased() == folded }
        if let label = ManuscriptLabel(reference: wanted), label.kind == .tbl || label.kind == .fig {
            // A label names its own kind only: `fig:sales` is never the table `sales`.
            if let hit = named.first(where: { $0.referenceLabel?.kind == label.kind }) { return hit }
            if let other = named.first?.referenceLabel {
                throw MCPError.invalidArgument(
                    "'\(bare)' is \(other.kind == .tbl ? "a table" : "an image"): its label is \(other.reference).")
            }
        } else if let hit = named.first { return hit }
        if let hit = records.first(where: { $0.id == wanted }) { return hit }
        let nearest = records.map(\.name).sorted {
            (distance($0.lowercased(), folded), $0) < (distance($1.lowercased(), folded), $1)
        }.prefix(5)
        let list = nearest.isEmpty ? "the book has no figures" : "nearest: " + nearest.joined(separator: ", ")
        throw MCPError.invalidArgument("No figure named '\(name)' (\(list)). Use list_figures for every name.")
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        if a.contains(b) || b.contains(a) { return abs(a.count - b.count) }
        let x = Array(a), y = Array(b)
        var row = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in 1...max(y.count, 1) where !y.isEmpty {
                let temp = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = temp
            }
        }
        return row[y.count] + 1000
    }

    // MARK: - A table

    /// The cells of `range` (all of the table when nil) and their text table.
    static func table(
        record: FigureRecord, state: FigureState, snapshot: PublishFigures, research: [ResearchItem],
        range: String?, locale: TableLocale
    ) throws -> TableResult {
        let table = state.table
        let rows = table.rows, columns = table.columns
        var book = snapshot.workbook ?? Workbook(pins: FigurePinIndex())
        book.setTable(table, id: record.id)
        let value: (CellKey) -> CellValue = { book.value(at: CellAddress(table: record.id, key: $0)) }

        var rowRange = 0..<rows.count, columnRange = 0..<columns.count
        var rangeText = "all"
        if let range {
            let trimmed = range.trimmingCharacters(in: .whitespaces)
            guard let ends = FigureGridAddress.range(trimmed, in: table),
                  let a = table.rowIndex(of: ends.from.row), let ac = table.columnIndex(of: ends.from.column),
                  let b = table.rowIndex(of: ends.to.row), let bc = table.columnIndex(of: ends.to.column)
            else {
                throw MCPError.invalidArgument(
                    "range '\(range)' is not an A1 range inside this table (\(rows.count) rows, \(columns.count) columns); use a form like \"A1:C10\" or \"B3\".")
            }
            rowRange = min(a, b)..<(max(a, b) + 1)
            columnRange = min(ac, bc)..<(max(ac, bc) + 1)
            rangeText = FigureGridAddress.string(
                from: CellKey(row: rows[rowRange.lowerBound], column: columns[columnRange.lowerBound]),
                to: CellKey(row: rows[rowRange.upperBound - 1], column: columns[columnRange.upperBound - 1]),
                in: table) ?? trimmed
        }

        let layout = FigureTableLayout.make(table: table, value: value, locale: locale)
        let display: [[String]] = (layout.header.map { [$0] } ?? []) + layout.body + (layout.total.map { [$0] } ?? [])
        let names = FormulaNames(
            records: snapshot.records, tables: snapshot.states.mapValues(\.table), research: research)

        var cells: [Cell] = []
        for r in rowRange {
            for c in columnRange {
                let key = CellKey(row: rows[r], column: columns[c])
                let stored = table[key]
                let formula: String? = {
                    guard case .formula(let f)? = stored?.content else { return nil }
                    return "=" + FormulaParser.render(f, in: table, names: names)
                }()
                cells.append(Cell(
                    a1: A1.columnLetters(c) + String(r + 1), value: display[r][c], raw: Raw(value(key)),
                    formula: formula, format: stored?.format ?? CellFormat()))
            }
        }

        let alignments = columnRange.map { c -> TableAlignment in
            switch layout.alignments[c] {
            case .right: return .trailing
            case .center: return .center
            default: return .leading
            }
        }
        let text = TableText(
            header: columnRange.map { A1.columnLetters($0) }, alignments: alignments,
            rows: rowRange.map { r in columnRange.map { display[r][$0] } }).formatted()
        return TableResult(
            name: record.name, kind: "table", rows: rows.count, columns: columns.count,
            range: rangeText, cells: cells, text: text)
    }

    // MARK: - An image

    static func imageEnvelopeForTesting(record: FigureRecord, state: FigureState?, projectURL: URL) throws -> Data {
        try imageEnvelope(record: record, state: state,
                          params: Params(project_id: "", name: record.name, range: nil, max_dimension: nil,
                                         quality: nil, region: nil),
                          projectURL: projectURL)
    }

    private static func imageEnvelope(
        record: FigureRecord, state: FigureState?, params: Params, projectURL: URL
    ) throws -> Data {
        let abs: URL
        do {
            if let image = state?.image {
                abs = try SafeRelativePath.resolveFile(
                    named: image.filename, in: FigurePathRule.figuresFolder, under: projectURL)
            } else {
                abs = try SafeRelativePath.resolve(record.path, under: projectURL)
            }
        } catch {
            throw MCPError.invalidArgument(
                "Figure '\(record.name)' has an unsafe path: \(error.localizedDescription)")
        }
        guard FileManager.default.fileExists(atPath: abs.path) else {
            throw MCPError.invalidArgument("Figure '\(record.name)' has no picture file on this Mac yet.")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: abs.path)
        if let size = attrs?[.size] as? NSNumber, size.intValue > ImageResponseBuilder.maxSourceImageBytes {
            let mb = Double(size.intValue) / (1024 * 1024)
            throw MCPError.invalidArgument(String(
                format: "Image '%@' is %.1f MB on disk; refusing to load. Maugham resizes for MCP delivery but won't open a source over 50 MB.",
                record.name, mb))
        }
        return try ImageResponseBuilder.encodeEnvelope(
            at: abs, region: params.region, maxDimension: params.max_dimension, quality: params.quality)
    }
}
