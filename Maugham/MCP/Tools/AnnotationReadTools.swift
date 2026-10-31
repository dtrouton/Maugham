import Foundation
import MaughamCore

// MARK: - list_annotations

public enum ListAnnotationsTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        /// A document's id, or a figure's id (a figure note listing). Absent
        /// when `figure` names the figure.
        public let document_id: String?
        /// A figure's name or `tbl:`/`fig:` label: list that figure's notes.
        public let figure: String?
        public let kinds: [String]?
        public let statuses: [String]?
        public let paragraph_id: String?
    }
    public struct Item: Codable, Equatable {
        public let id: String
        public let kind: String
        public let paragraph_id: String?
        public let body: String
        public let suggested_text: String?
        public let status: String
        public let user_response: String?
        public let created_at: Date
        public let resolved_at: Date?
        public let is_stale: Bool
        /// The writer's triage of this note — `do` / `decline` / `discuss`, or
        /// null for untriaged (M3 P3). Claude never sets it.
        public let triage: String?
        /// The `ReviewPass.id` that was active when the note was written, or
        /// null. **Null means every pass, not no pass**: an unstamped note
        /// appears in every pass's queue.
        public let review_pass_id: String?
        /// The lessons-ledger heading a letter question was raised under
        /// (editorial letter P2), or absent when the note was raised under no
        /// habit — which is nearly every note. **`encodeIfPresent`, unlike the
        /// two fields above**: those emit `null` because absence there carries
        /// a second meaning a reader must not have to guess at, while a note
        /// with no heading simply has none, and a key on every row of every
        /// listing would be payload for a fact that says nothing.
        public let lesson_heading: String?
        /// A figure note's anchor (`tbl:x!C4` by current positions, or the
        /// label alone for a whole-figure note or an orphaned one); absent on
        /// a manuscript note, so paragraph output is byte-identical.
        let figure_anchor: String?
        /// Figure notes only: true when the anchor's row or column was deleted.
        let orphaned: Bool?
        /// A figure suggestion's proposed cell, in `read_figure`'s shapes.
        let suggested_cell: FigureNoteReading.SuggestedCell?

        enum CodingKeys: String, CodingKey {
            case id, kind, paragraph_id, body, suggested_text, status
            case user_response, created_at, resolved_at, is_stale
            case triage, review_pass_id, lesson_heading
            case figure_anchor, orphaned, suggested_cell
        }

        // Hand-written so the two M3 P3 fields emit JSON `null` rather than
        // vanishing: "untriaged" and "belongs to every pass" are FACTS a
        // reader has to be able to read off the wire, and an absent key says
        // "this tool does not report triage" instead. The pre-existing
        // optionals keep `encodeIfPresent` — their shape is a shipped wire
        // contract and changing it is not this widening's business.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(paragraph_id, forKey: .paragraph_id)
            try c.encode(body, forKey: .body)
            try c.encodeIfPresent(suggested_text, forKey: .suggested_text)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(user_response, forKey: .user_response)
            try c.encode(created_at, forKey: .created_at)
            try c.encodeIfPresent(resolved_at, forKey: .resolved_at)
            try c.encode(is_stale, forKey: .is_stale)
            try c.encode(triage, forKey: .triage)
            try c.encode(review_pass_id, forKey: .review_pass_id)
            try c.encodeIfPresent(lesson_heading, forKey: .lesson_heading)
            try c.encodeIfPresent(figure_anchor, forKey: .figure_anchor)
            try c.encodeIfPresent(orphaned, forKey: .orphaned)
            try c.encodeIfPresent(suggested_cell, forKey: .suggested_cell)
        }
    }
    public static let method = "list_annotations"
    public static let description =
        "List annotations on a document (or, with `figure` or a figure id as " +
        "`document_id`, on a table figure). A document's list also carries the notes " +
        "on the figures its text uses; a figure note has `figure_anchor` " +
        "(`tbl:x!C4` by current positions, or the label alone), `orphaned` " +
        "(its row or column was deleted) and, for a suggestion, `suggested_cell` " +
        "({value, formula?, raw} as `read_figure` shows a cell). " +
        "Defaults to status=open. Filter by " +
        "`kinds` (any of comment/suggested_change/query/craft_note), `statuses` " +
        "(open/accepted/rejected/archived/stetted — `stetted` means the writer " +
        "read the note and the words stand), `paragraph_id`. Use this to check " +
        "prior editorial conversation on a paragraph before adding new suggestions. " +
        "`review_pass_id` is the review pass a note was written under; a null one " +
        "belongs to EVERY pass, not to none. `lesson_heading` is the ledger " +
        "heading a letter question was raised under, when it was. " +
        "`review_pass_id` `workshop` WAS the coach's lane (Le Guin's) on notes " +
        "written before the check and the round became two verbs; nothing " +
        "stamps it now, and it is never listed in `get_outline`'s " +
        "`review_passes`. " +
        "`triage` (do/decline/discuss) and " +
        "stetting are the writer's own marks — Claude never sets either."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"kinds":{"type":"array","items":{"type":"string"}},"statuses":{"type":"array","items":{"type":"string"}},"paragraph_id":{"type":"string"},"figure":{"type":"string","description":"A figure name or tbl:name / fig:name label: list that figure's notes (instead of document_id)."}},"required":["project_id"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let kindFilter: Set<AnnotationKind>? = params.kinds.flatMap { raws in
            let set = Set(raws.compactMap(AnnotationKind.init(rawValue:)))
            return set.isEmpty ? nil : set
        }
        // Default = open only. Explicit empty array also collapses to default.
        let statusFilter: Set<AnnotationStatus> = params.statuses.flatMap { raws in
            let set = Set(raws.compactMap(AnnotationStatus.init(rawValue:)))
            return set.isEmpty ? nil : set
        } ?? [.open]
        let filter = AnnotationFilter(
            kinds: kindFilter,
            statuses: statusFilter,
            paragraphId: params.paragraph_id)

        let entry = try resolveProject(params.project_id, in: registry)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601

        // A figure asked for by name, label or id: its notes, no document.
        if let target = try await FigureNoteReading.figureTarget(
            figure: params.figure, documentId: params.document_id, entry: entry) {
            let context = target.context
            let notes = await entry.store.figureNotes(context.record.id)
            let items = notes.filter(filter.matches).map { Item($0, figure: context) }
            return try MCPResponseBudget.enforce(
                try enc.encode(items),
                hint: "Too many figure notes for one response; pass `kinds` or `statuses` to narrow.")
        }
        guard let documentId = params.document_id else {
            throw MCPError.invalidArgument("Pass `document_id` (a document) or `figure` (a table).")
        }

        var items: [Item] = try await withAnnotationDocument(
            projectId: params.project_id,
            documentId: documentId,
            registry: registry
        ) { doc in
            doc.annotations(filter: filter).map { Item($0, figure: nil) }
        }
        // The notes on the figures this document's text uses. The source is
        // `FigureListingSource.rows`, the listing `list_figures` reports
        // (`usedIn` = the figure lines the reference index found in the
        // document), so the two tools agree on which figures a document uses.
        if params.paragraph_id == nil {
            for context in await FigureNoteReading.contexts(usedBy: documentId, entry: entry) {
                let notes = await entry.store.figureNotes(context.record.id)
                items += notes.filter(filter.matches).map { Item($0, figure: context) }
            }
        }
        return try MCPResponseBudget.enforce(
            try enc.encode(items),
            hint: "Too many annotations for one response; pass `kinds`, `statuses` or `paragraph_id` to narrow.")
    }
}

// MARK: - get_annotation

public enum GetAnnotationTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        /// A document's id or a figure's id; absent when `figure` names it.
        public let document_id: String?
        public let figure: String?
        public let annotation_id: String
    }
    public struct Result: Codable, Equatable {
        public let id: String
        public let kind: String
        public let paragraph_id: String?
        public let body: String
        public let suggested_text: String?
        public let prior_text: String?
        public let status: String
        public let user_response: String?
        public let created_at: Date
        public let resolved_at: Date?
        public let is_stale: Bool
        /// See `ListAnnotationsTool.Item.triage` — the same field, so the
        /// pair cannot disagree about a note.
        public let triage: String?
        /// See `ListAnnotationsTool.Item.review_pass_id`.
        public let review_pass_id: String?
        /// See `ListAnnotationsTool.Item.lesson_heading` — the same field
        /// under the same rule, so the pair cannot disagree about a note.
        public let lesson_heading: String?
        /// See `ListAnnotationsTool.Item.figure_anchor`, `.orphaned`, `.suggested_cell`.
        let figure_anchor: String?
        let orphaned: Bool?
        let suggested_cell: FigureNoteReading.SuggestedCell?
        public let history: [HistoryEntry]

        public struct HistoryEntry: Codable, Equatable {
            public let op_id: String
            public let kind: String
            public let at: Date
            public let user_response: String?
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, paragraph_id, body, suggested_text, prior_text
            case status, user_response, created_at, resolved_at, is_stale
            case triage, review_pass_id, lesson_heading, history
            case figure_anchor, orphaned, suggested_cell
        }

        // `ListAnnotationsTool.Item.encode`'s reasoning, applied to the
        // single-record sibling so the two agree key for key.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(paragraph_id, forKey: .paragraph_id)
            try c.encode(body, forKey: .body)
            try c.encodeIfPresent(suggested_text, forKey: .suggested_text)
            try c.encodeIfPresent(prior_text, forKey: .prior_text)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(user_response, forKey: .user_response)
            try c.encode(created_at, forKey: .created_at)
            try c.encodeIfPresent(resolved_at, forKey: .resolved_at)
            try c.encode(is_stale, forKey: .is_stale)
            try c.encode(triage, forKey: .triage)
            try c.encode(review_pass_id, forKey: .review_pass_id)
            try c.encodeIfPresent(lesson_heading, forKey: .lesson_heading)
            try c.encodeIfPresent(figure_anchor, forKey: .figure_anchor)
            try c.encodeIfPresent(orphaned, forKey: .orphaned)
            try c.encodeIfPresent(suggested_cell, forKey: .suggested_cell)
            try c.encode(history, forKey: .history)
        }
    }
    public static let method = "get_annotation"
    public static let description =
        "Return a full annotation record including its lifecycle history " +
        "(creation + accept/reject/archive/stet ops). A note on a table figure " +
        "(pass `figure`, or the figure's id as `document_id`) also has " +
        "`figure_anchor`, `orphaned` and, for a suggestion, `suggested_cell`. " +
        "`review_pass_id` is the " +
        "review pass the note was written under; a null one belongs to EVERY " +
        "pass, not to none. `triage` (do/decline/discuss) and stetting are the " +
        "writer's own marks — Claude never sets either."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"figure":{"type":"string","description":"A figure name or tbl:name / fig:name label (instead of document_id)."},"annotation_id":{"type":"string"}},"required":["project_id","annotation_id"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601

        if let target = try await FigureNoteReading.figureTarget(
            figure: params.figure, documentId: params.document_id, entry: entry) {
            let context = target.context
            let notes = await entry.store.figureNotes(context.record.id)
            guard let ann = notes.first(where: { $0.id == params.annotation_id }) else {
                throw MCPError.invalidArgument("annotation_id not found: \(params.annotation_id)")
            }
            let ops = await entry.store.figureOps(context.record.id)
            return try enc.encode(Result(ann, figure: context, history: history(of: ann.id, in: ops)))
        }
        guard let documentId = params.document_id else {
            throw MCPError.invalidArgument("Pass `document_id` (a document) or `figure` (a table).")
        }
        let result: Result = try await withAnnotationDocument(
            projectId: params.project_id,
            documentId: documentId,
            registry: registry
        ) { doc in
            let all = doc.annotations(filter: .init(statuses: nil))
            guard let ann = all.first(where: { $0.id == params.annotation_id })
            else {
                throw MCPError.invalidArgument(
                    "annotation_id not found: \(params.annotation_id)")
            }
            let ops = try await doc.opLog()
            return Result(ann, figure: nil, history: history(of: ann.id, in: ops))
        }
        return try enc.encode(result)
    }

    private static func history(of annotationId: String, in ops: [Op]) -> [Result.HistoryEntry] {
        ops
            .filter {
                $0.opId == annotationId
                || $0.provenance?.sourceAnnotationId == annotationId
            }
            .map { op in
                Result.HistoryEntry(
                    op_id: op.opId,
                    kind: op.kind.rawValue,
                    at: op.at,
                    user_response: op.provenance?.userResponse)
            }
    }
}

extension GetAnnotationTool.Result {
    init(_ ann: Annotation, figure: FigureNoteReading.Context?, history: [HistoryEntry]) {
        let view = figure?.view(of: ann)
        self.init(
            id: ann.id, kind: ann.kind.rawValue,
            paragraph_id: ann.paragraphId, body: ann.body,
            suggested_text: ann.suggestedText, prior_text: ann.priorText,
            status: ann.status.rawValue, user_response: ann.userResponse,
            created_at: ann.createdAt, resolved_at: ann.resolvedAt,
            is_stale: ann.isStale,
            triage: ann.triage?.rawValue,
            review_pass_id: ann.reviewPassId,
            lesson_heading: ann.lessonHeading,
            figure_anchor: view?.anchor, orphaned: view?.orphaned,
            suggested_cell: view?.suggested,
            history: history)
    }
}

extension ListAnnotationsTool.Item {
    init(_ ann: Annotation, figure: FigureNoteReading.Context?) {
        let view = figure?.view(of: ann)
        self.init(
            id: ann.id, kind: ann.kind.rawValue,
            paragraph_id: ann.paragraphId, body: ann.body,
            suggested_text: ann.suggestedText, status: ann.status.rawValue,
            user_response: ann.userResponse, created_at: ann.createdAt,
            resolved_at: ann.resolvedAt, is_stale: ann.isStale,
            triage: ann.triage?.rawValue, review_pass_id: ann.reviewPassId,
            lesson_heading: ann.lessonHeading,
            figure_anchor: view?.anchor, orphaned: view?.orphaned,
            suggested_cell: view?.suggested)
    }
}

// MARK: - Figure notes (report plan 9c-1 Task 6)

/// How the two read tools show a note on a table figure: where it sits now
/// and what a suggestion proposes. The cell shapes are `read_figure`'s
/// (`ReadFigureTool.Raw`, `CellDisplay`, `FormulaParser.render`), not a copy.
enum FigureNoteReading {

    /// `{ value, formula?, raw, format }` as `read_figure` reports a cell. `value`
    /// is `CellDisplay` under the cell's own format, which is exactly what
    /// `read_figure`'s layout does for that cell once it is written.
    struct SuggestedCell: Codable, Equatable {
        let value: String
        let formula: String?
        let raw: ReadFigureTool.Raw
        let format: CellFormat
    }

    struct View {
        let anchor: String
        let orphaned: Bool
        let suggested: SuggestedCell?
    }

    /// One figure and what is needed to show its notes.
    struct Context {
        let record: FigureRecord
        let table: FigureTable?
        let workbook: Workbook?
        let names: FormulaNames
        let locale: TableLocale

        func view(of ann: Annotation) -> View {
            let label = record.referenceLabel?.reference ?? record.name
            let anchor = ann.figureAddress.map { label + "!" + $0 } ?? label
            return View(anchor: anchor, orphaned: ann.figureOrphaned,
                        suggested: suggestedCell(of: ann))
        }

        private func suggestedCell(of ann: Annotation) -> SuggestedCell? {
            guard let cell = ann.suggestedCell else { return nil }
            var value: CellValue = .empty
            var formula: String?
            if case .value(let v) = cell.content { value = v }
            // A live anchor: the proposal evaluated in place, in the figure's
            // own workbook, so a formula shows what it would read. An
            // orphaned one has no cell to place it in, so a formula has no
            // value (and its references are read against the table as it is).
            if let anchor = ann.figureAnchor, ann.figureAddress != nil, var t = table {
                let key = CellKey(row: anchor.row, column: anchor.column)
                t.setCell(cell, at: key)
                var book = workbook ?? Workbook(pins: FigurePinIndex())
                book.setTable(t, id: record.id)
                value = book.value(at: CellAddress(table: record.id, key: key))
                if case .formula(let f) = cell.content { formula = "=" + FormulaParser.render(f, in: t, names: names) }
            } else if case .formula(let f) = cell.content, let t = table {
                formula = "=" + FormulaParser.render(f, in: t, names: names)
            }
            return SuggestedCell(
                value: CellDisplay.string(for: value, format: cell.format, locale: locale),
                formula: formula, raw: ReadFigureTool.Raw(value), format: cell.format)
        }
    }

    struct Target { let context: Context }

    @MainActor
    private static func context(_ record: FigureRecord, entry: ProjectRegistry.Entry,
                                snapshot: PublishFigures) async -> Context {
        Context(
            record: record, table: snapshot.states[record.id]?.table, workbook: snapshot.workbook,
            names: FormulaNames(
                records: snapshot.records, tables: snapshot.states.mapValues(\.table),
                research: entry.store.manifest.research),
            locale: TableLocale(languageTag: await entry.store.bookLanguageTag()))
    }

    /// The table figure a call asks for: `figure` (name or label, found as
    /// `read_figure` finds it) or a `document_id` that is exactly a figure's
    /// id. Nil when the call is about a document. Throws when both are given
    /// or the figure is an image (images take no notes).
    @MainActor
    static func figureTarget(
        figure: String?, documentId: String?, entry: ProjectRegistry.Entry
    ) async throws -> Target? {
        if let figure {
            guard documentId == nil else {
                throw MCPError.invalidArgument("Pass `figure` (a figure's notes) or `document_id`, not both.")
            }
            let name = figure.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            let snapshot = await entry.store.publishFigures()
            let record = try ReadFigureTool.find(name, in: snapshot.records)
            guard record.kind == .table else {
                throw MCPError.invalidArgument("Figure '\(record.name)' is not a table: only a table takes notes.")
            }
            return Target(context: await context(record, entry: entry, snapshot: snapshot))
        }
        guard let documentId,
              let record = (entry.store.manifest.figures ?? []).first(where: { $0.id == documentId })
        else { return nil }
        let snapshot = await entry.store.publishFigures()
        return Target(context: await context(record, entry: entry, snapshot: snapshot))
    }

    /// The table figures whose lines `documentId` holds, in the listing's order.
    @MainActor
    static func contexts(usedBy documentId: String, entry: ProjectRegistry.Entry) async -> [Context] {
        guard !(entry.store.manifest.figures ?? []).isEmpty else { return [] }
        // Whole-book index, as `list_figures` builds: fine for an MCP read.
        let rows = await FigureListingSource.rows(store: entry.store)
            .filter { $0.kind == .table && $0.usedIn.contains { $0.docId == documentId } }
        guard !rows.isEmpty else { return [] }
        let snapshot = await entry.store.publishFigures()
        let byId = Dictionary(snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [Context] = []
        for row in rows {
            guard let record = byId[row.figureId] else { continue }
            out.append(await context(record, entry: entry, snapshot: snapshot))
        }
        return out
    }
}
