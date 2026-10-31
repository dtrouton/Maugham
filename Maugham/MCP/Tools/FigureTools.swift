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


    /// The wire entries: the listing's order (reading order, then unused by
    /// name), then the parked figures the tree does not list, by name. Pure, so
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
