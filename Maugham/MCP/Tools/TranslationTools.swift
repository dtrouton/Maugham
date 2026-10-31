import Foundation
import MaughamCore

// MARK: - Shared paragraph-state resolution

/// Resolve the CURRENT paragraph state for a `(project_id, document_id)` the
/// way tripwire 20 requires: an open doc reads its live `Document` (freshest,
/// ahead of the op log by the typing-burst window); a closed doc reads the
/// op-log-derived state via `DerivedManuscriptCache`. Never reads the on-disk
/// `.md` (ADR 0018/0019). Shared by the translation MCP tools.
///
/// Returns the authoritative `sequence`, the `paragraphs` id→text map, and the
/// project URL (translations are written per-device under `.maugham/`).
@MainActor
func currentParagraphState(
    projectId: String, documentId: String, registry: ProjectRegistry
) throws -> (sequence: [String], paragraphs: [String: String], projectURL: URL) {
    guard let entry = registry.lookup(id: projectId) else {
        throw MCPError.unknownProjectID(projectId)
    }
    return try currentParagraphState(
        documentId: documentId, store: entry.store,
        documentStore: entry.store.documentStore, projectURL: entry.url)
}

/// The same resolution with the project already in hand — what the translator
/// loop's production wiring calls (`TranslatorEnvironment+Project.swift`),
/// which holds its window's stores directly and has no registry to look
/// anything up in.
///
/// **One spelling of tripwire 20's rule**, which is why the registry version
/// above is a two-line wrapper around this one: a second copy of "open doc →
/// live `Document`, closed doc → derived" is a second answer to what the
/// current source text is, and the write pipeline hashes against whatever it
/// is given.
@MainActor
func currentParagraphState(
    documentId: String, store: ProjectStore, documentStore: DocumentStore?, projectURL: URL
) throws -> (sequence: [String], paragraphs: [String: String], projectURL: URL) {
    // Open doc → live Document.
    if let doc = documentStore?.document(forDocId: documentId) {
        return (doc.sequence, doc.paragraphs, projectURL)
    }
    // Closed doc → op-log-derived state. Verify the id resolves to a manuscript
    // item first so an unknown id fails cleanly rather than deriving empty.
    guard TreeWalk.find(id: documentId, in: store.manifest.structure) != nil else {
        throw MCPError.invalidArgument(
            "document_id not found in project manifest: \(documentId)")
    }
    let state = try store.derivedCache.state(forDocId: documentId, in: projectURL)
    return (state.sequence, state.paragraphs, projectURL)
}

// MARK: - Shared figure resolution

/// **A table figure's current table, for its translation** — the figure the
/// `document_id` names, folded from its op log through the publish snapshot
/// (`ProjectStore.publishFigures()`: an open host's fold, else the figure
/// cache; never the rendered `figures/<name>.csv`, tripwire 20), windowless. Its text cells are
/// what a translation is validated and hashed against, and what A1 addresses
/// resolve in. A removed figure is not in the registry, so it is unknown here.
@MainActor
func currentFigureTable(
    projectId: String, figureId: String, registry: ProjectRegistry
) async throws -> (record: FigureRecord, table: FigureTable, projectURL: URL) {
    guard let entry = registry.lookup(id: projectId) else {
        throw MCPError.unknownProjectID(projectId)
    }
    let snapshot = await entry.store.publishFigures()
    guard let record = snapshot.records.first(where: { $0.id == figureId }) else {
        throw MCPError.invalidArgument(
            "document_id \(figureId) is not a figure in this book (list_figures gives each figure's id)")
    }
    switch record.kind {
    case .table:
        guard let table = snapshot.states[record.id]?.table else {
            throw MCPError.invalidArgument(
                "Figure '\(record.name)' could not be read (its op log would not fold).")
        }
        return (record, table, entry.url)
    case .image, .unknown:
        throw MCPError.invalidArgument(
            "Figure '\(record.name)' is not a table; only a table's text cells translate.")
    }
}

// MARK: - write_translation

public enum WriteTranslationTool: MCPTool {
    public struct Entry: Codable {
        /// A document's paragraph.
        public let paragraph_id: String?
        /// A table figure's cell, by its address in the current table ("B3").
        public let a1: String?
        /// A table figure's cell by its stored key (`read_translation`'s
        /// orphan `cell`), for `delete` only: an orphan's row or column may be
        /// gone, so it has no address.
        public let cell: String?
        public let text: String?
        public let verbatim: Bool?
        public let delete: Bool?
    }
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let language: String
        public let entries: [Entry]
    }
    public struct Result: Codable, Equatable {
        public let written: Int
        public let language: String
        public let warnings: [String]
    }

    public static let method = "write_translation"
    public static let description =
        "Record per-paragraph translations of a document into a language, stored " +
        "in a parallel translation layer (the manuscript itself is never mutated). " +
        "Each entry supplies exactly one of `text` (the translated paragraph; " +
        "empty or whitespace-only text is refused — use `verbatim: true` for an " +
        "empty source paragraph), " +
        "`verbatim: true` (copy the current source text unchanged — for chrome " +
        "like sluglines or numerals that don't translate), or `delete: true` " +
        "(remove this paragraph's translation — retracting one, or purging an " +
        "orphan whose source paragraph is gone; deleting a never-translated " +
        "paragraph is a harmless no-op — accepted, and if the language has " +
        "nothing translated in it at all, nothing is recorded, so deletions " +
        "alone can never conjure a language the writer never translated into). " +
        "The server stamps each " +
        "record with a hash of the current source paragraph so downstream reads " +
        "can flag a translation as stale after the source is edited. Paragraph ids " +
        "come from read_document; every id a `text` or `verbatim` entry names must " +
        "be current — an unknown id rejects the whole batch, its `delete` entries " +
        "included. `delete` entries are exempt from that check, since an orphan " +
        "names a paragraph the document no longer has. The batch is all-or-nothing " +
        "for writes as well as validation: every record is built before any is " +
        "persisted, in one append. Non-verbatim entries are checked for " +
        "structural drift (a dropped **bold** run, changed block shape) and, if the " +
        "translated text is identical to the current source, a reminder to mark it " +
        "`verbatim: true` instead — these are advisory only and never block the write. " +
        "A table figure translates too: pass its id (from list_figures) as " +
        "`document_id` and address each entry by `a1` (\"B3\") in the current " +
        "table instead of `paragraph_id`. Only a cell holding typed text " +
        "translates — numbers, dates and formulas are shared by every language, " +
        "so a `text`/`verbatim` entry on one, or on an address outside the " +
        "table, rejects the batch. A `delete` may name a cell orphan by its " +
        "`cell` key from read_translation instead. " +
        "See get_help topic 'translation-pass' for the translation workflow."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string","description":"a manuscript document's id, or a table figure's id"},"language":{"type":"string","description":"lowercase tag, e.g. es, pt-br"},"entries":{"type":"array","items":{"type":"object","properties":{"paragraph_id":{"type":"string","description":"a document's paragraph"},"a1":{"type":"string","description":"a table figure's cell, e.g. B3"},"cell":{"type":"string","description":"a table figure's cell orphan key from read_translation; delete only"},"text":{"type":"string"},"verbatim":{"type":"boolean","description":"copy current source text as the translation (chrome idiom)"},"delete":{"type":"boolean","description":"remove this translation; exempt from the unknown-id check, so an orphan can be purged"}}}}},"required":["project_id","document_id","language","entries"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)

        // 1. Valid language tag — the pipeline's own gate, called here so a
        // malformed tag is refused before the registry is touched.
        try TranslationWritePipeline.validate(language: params.language)

        if DocumentClass.isFigureDocId(params.document_id) {
            return try await writeCells(params, registry: registry)
        }
        if params.entries.contains(where: { $0.a1 != nil || $0.cell != nil }) {
            throw MCPError.invalidArgument(
                "`a1` and `cell` address a table figure's cells; a document's entries use `paragraph_id`")
        }

        let state = try currentParagraphState(
            projectId: params.project_id,
            documentId: params.document_id,
            registry: registry)

        // 2-6. Validation, record building and the single append all belong to
        // the pipeline, which the coming ingest path shares (census:
        // TripwireGrepTests). The tool's job is the wire form on either side.
        let warnings = try await TranslationWritePipeline.perform(
            entries: try params.entries.map {
                guard let paragraphId = $0.paragraph_id else {
                    throw MCPError.invalidArgument("every entry names its `paragraph_id`")
                }
                return TranslationWritePipeline.Entry(
                    paragraphId: paragraphId, text: $0.text,
                    verbatim: $0.verbatim, delete: $0.delete)
            },
            language: params.language,
            documentId: params.document_id,
            state: state,
            // A translation is the translator's, whoever asked for it: this is
            // `write_translation` arriving through MCP, and the assistant's key
            // would say the wrong thing about what wrote these words.
            actor: .translator)

        // 7. Notify any live window on this project so an in-progress
        // translation-review posture re-derives its read-only surface (a
        // retranslation must land live, not stay frozen until exit/re-enter).
        // Project-scoped, mirroring how AddNoteTool posts maughamMCPNoteAdded.
        MaughamEvent.post(
            .maughamTranslationDidUpdate,
            to: .project(for: state.projectURL),
            payload: [
                "document_id": params.document_id,
                "language": params.language
            ])

        // 8. Response.
        return try JSONEncoder().encode(Result(
            written: params.entries.count,
            language: params.language,
            warnings: warnings))
    }

    /// A table figure's batch: each entry's `a1` resolved against the current
    /// table (ruling R8: addresses on the wire, ids stored), then the
    /// pipeline's cell route, which validates, appends once, and announces the
    /// figure.
    @MainActor
    private static func writeCells(
        _ params: Params, registry: ProjectRegistry
    ) async throws -> Data {
        let figure = try await currentFigureTable(
            projectId: params.project_id, figureId: params.document_id, registry: registry)
        let table = figure.table
        var outside: [String] = []
        var entries: [TranslationWritePipeline.CellEntry] = []
        for e in params.entries {
            if let paragraphId = e.paragraph_id {
                throw MCPError.invalidArgument(
                    "entry for paragraph \(paragraphId) names a paragraph, but '\(figure.record.name)' "
                    + "is a table: address each cell by `a1`, e.g. \"B3\"")
            }
            let key: CellKey?
            switch (e.a1, e.cell) {
            case (let a1?, nil):
                key = FigureGridAddress.cell(a1, in: table)
                if key == nil { outside.append(a1) }
            case (nil, let cell?):
                guard e.delete == true else {
                    throw MCPError.invalidArgument(
                        "`cell` names an orphan to delete; address a cell to translate by `a1`")
                }
                guard let parsed = FigureCellTranslationKey.cellKey(fromParagraphId: cell) else {
                    throw MCPError.invalidArgument("not a cell key: \(cell)")
                }
                key = parsed
            default:
                throw MCPError.invalidArgument(
                    "every entry for a table names exactly one of `a1` or `cell`")
            }
            if let key {
                entries.append(.init(key: key, text: e.text, verbatim: e.verbatim, delete: e.delete))
            }
        }
        if !outside.isEmpty {
            throw MCPError.invalidArgument(
                "not cells inside '\(figure.record.name)' (\(table.rows.count) rows, "
                + "\(table.columns.count) columns): \(outside.joined(separator: ", "))")
        }
        let warnings = try await TranslationWritePipeline.performCells(
            entries: entries, language: params.language, figureId: figure.record.id,
            table: table, projectURL: figure.projectURL,
            // The translator's, as a paragraph batch is.
            actor: .translator)
        return try JSONEncoder().encode(Result(
            written: params.entries.count, language: params.language, warnings: warnings))
    }
}

// MARK: - read_translation

public enum ReadTranslationTool: MCPTool {
    public struct Entry: Codable, Equatable {
        public let paragraph_id: String
        public let source_text: String
        public let translated_text: String?
        public let status: String
        public let verbatim: Bool
    }
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String
        public let language: String
        public let status: String?
    }
    /// One text cell of a table figure, by its address in the current table.
    public struct CellEntry: Codable, Equatable {
        public let a1: String
        public let source_text: String
        public let translated_text: String?
        public let status: String
        public let verbatim: Bool
    }
    /// A translation no live text cell answers to: its row or column is
    /// gone, or the cell no longer holds text. `cell` is its stored key
    /// (`write_translation` deletes it by that); `a1` is where it sits when
    /// the cell is still in the table.
    public struct CellOrphan: Codable, Equatable {
        public let cell: String
        public let a1: String?
        public let translated_text: String?
    }
    public struct Result: Codable, Equatable {
        public let language: String
        public let entries: [Entry]
        public let orphan_count: Int
        /// A table figure's text cells, row by row; omitted for a document.
        public var cells: [CellEntry]? = nil
        /// A table figure's cell orphans; omitted for a document.
        public var orphans: [CellOrphan]? = nil
    }

    public static let method = "read_translation"
    public static let description =
        "Read a document's translation into a language, paragraph by paragraph in " +
        "manuscript order. Each entry pairs the current source paragraph with its " +
        "translated text and a freshness `status`: `fresh` (translation matches the " +
        "current source), `stale` (the source was edited after translating — retranslate), " +
        "or `missing` (no translation yet). An unknown language is not an error: every " +
        "paragraph reads as `missing`. Pass `status` (`fresh`|`stale`|`missing`) to return " +
        "only matching entries — the usual way to find retranslation work is `status=stale` " +
        "plus `status=missing`. `orphan_count` reports translations whose paragraph no longer " +
        "exists in the source (dropped after an edit). " +
        "Pass a table figure's id as `document_id` to read its text cells instead: " +
        "`cells` lists each cell holding typed text, row by row, with its `a1`, " +
        "source, translation and `status` (numbers, dates and formulas are shared " +
        "by every language and never listed), and `orphans` lists translations no " +
        "text cell answers to any more (a deleted row or column, or a cell that " +
        "no longer holds text), each with the `cell` key write_translation " +
        "deletes it by; `entries` is then empty. " +
        "See get_help topic 'translation-pass' for the translation workflow."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string","description":"a manuscript document's id, or a table figure's id"},"language":{"type":"string","description":"lowercase tag, e.g. es, pt-br"},"status":{"type":"string","description":"optional filter: fresh | stale | missing — omit for all paragraphs"}},"required":["project_id","document_id","language"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)

        let filter: TranslationStatus?
        if let raw = params.status {
            guard let s = TranslationStatus(rawValue: raw) else {
                throw MCPError.invalidArgument(
                    "invalid status filter: \(raw) (expected fresh, stale, or missing)")
            }
            filter = s
        } else {
            filter = nil
        }

        if DocumentClass.isFigureDocId(params.document_id) {
            return try await readCells(params, filter: filter, registry: registry)
        }

        let state = try currentParagraphState(
            projectId: params.project_id,
            documentId: params.document_id,
            registry: registry)

        // **A present-but-unreadable translation file fails this call by
        // name** (P2a D0). Skipping it would answer with the OTHER actor's
        // file alone — the author's review edits over source paragraphs the
        // pipeline had already translated — and Claude would read that as
        // work still to do.
        let records = try TranslationStore.loadMerged(
            forDocId: params.document_id, language: params.language, in: state.projectURL)
        let derived = TranslationDeriver.derive(
            records: records, sequence: state.sequence,
            paragraphs: state.paragraphs, language: params.language)

        let entries = derived.entries
            .filter { filter == nil || $0.status == filter }
            .map { e in
                // Strip inline task anchors from the source so Claude never
                // echoes a `<!--t-XXXX-->` marker into a translation.
                Entry(paragraph_id: e.paragraphId,
                      source_text: MarkdownDisplayFilter.stripTaskAnchorsInline(e.sourceText),
                      translated_text: e.translatedText,
                      status: e.status.rawValue,
                      verbatim: e.verbatim)
            }

        let encoded = try JSONEncoder().encode(Result(
            language: params.language,
            entries: entries,
            orphan_count: derived.orphans.count))
        return try MCPResponseBudget.enforce(
            encoded, hint: "filter with status=stale or status=missing to reduce payload")
    }

    /// A table figure's text cells and orphans, derived from its current
    /// table and its merged translation files (a present-but-unreadable file
    /// fails the call, as for a document).
    @MainActor
    private static func readCells(
        _ params: Params, filter: TranslationStatus?, registry: ProjectRegistry
    ) async throws -> Data {
        let figure = try await currentFigureTable(
            projectId: params.project_id, figureId: params.document_id, registry: registry)
        let records = try TranslationStore.loadMerged(
            forDocId: figure.record.id, language: params.language, in: figure.projectURL)
        let derived = FigureTranslationDeriver.derive(
            records: records, table: figure.table, language: params.language)
        let cells = derived.entries
            .filter { filter == nil || $0.status == filter }
            .map { e in
                CellEntry(
                    a1: FigureGridAddress.string(for: e.key, in: figure.table)
                        ?? FigureCellTranslationKey.paragraphId(for: e.key),
                    source_text: e.sourceText, translated_text: e.translatedText,
                    status: e.status.rawValue, verbatim: e.verbatim)
            }
        let orphans = derived.orphans.map { record in
            CellOrphan(
                cell: record.paragraphId,
                a1: FigureCellTranslationKey.cellKey(fromParagraphId: record.paragraphId)
                    .flatMap { FigureGridAddress.string(for: $0, in: figure.table) },
                translated_text: record.text)
        }
        let encoded = try JSONEncoder().encode(Result(
            language: params.language, entries: [], orphan_count: orphans.count,
            cells: cells, orphans: orphans))
        return try MCPResponseBudget.enforce(
            encoded, hint: "filter with status=stale or status=missing to reduce payload")
    }
}

// MARK: - translation_status

public enum TranslationStatusTool: MCPTool {
    public struct Row: Codable, Equatable {
        public let document_id: String
        public let language: String
        /// The stored role's `effectiveName`, else the preset for this
        /// language, else omitted — an unlisted, unminted language has no
        /// honest name to report. Never mints (see
        /// `EditionStatus.translatorName(for:in:)`).
        public let translator: String?
        /// The stored role's `effectiveName`, else the preset, else omitted —
        /// `translator`'s rule, applied to the blind reader
        /// (`EditionStatus.readerName(for:in:)`). Never mints.
        public var reader: String? = nil
        /// The stored role's `effectiveName`, else the preset, else omitted —
        /// `translator`'s rule, applied to the collator
        /// (`EditionStatus.collatorName(for:in:)`). Never mints.
        public var collator: String? = nil
        public let fresh: Int
        public let stale: Int
        public let missing: Int
        public let verbatim: Int
        public let orphans: Int
        public let open_queries: Int
        /// The newest pipeline round for this `(document, language)` pair
        /// (`TranslationRoundStore.latest`), or omitted when none has run.
        public var last_round: LastRound? = nil
    }

    public struct LastRound: Codable, Equatable {
        public let number: Int
        public let leg2_verdict: String?
        public let leg4_verdict: String?
        public let notes: Int
        public let departures: Int
        public let declined: Int
        public let summary: String?
        /// The leg a failed or cancelled round stopped at, else omitted.
        public let stopped_at: String?
    }
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String?
    }
    /// **A manuscript document the walk could not open** (issue #43, F-D).
    ///
    /// The rows it would have contributed are genuinely absent from `rows`, and
    /// this is what keeps that absence from reading as "nothing translated
    /// here". `EditionStatus.UnreadableDocument` on the wire; the department
    /// desk draws the same fact as a Couldn't-read line above its rows, off the
    /// same derivation.
    public struct UnreadableDocument: Codable, Equatable {
        public let document_id: String
        public let title: String
        public let reason: String
    }
    /// One (table figure, language) pair: the figure's text-cell counts by
    /// freshness. A figure with no translation file in a language reports its
    /// cells as `missing`, not zero: its edition will not compile until they
    /// are translated.
    public struct FigureRow: Codable, Equatable {
        public let figure_id: String
        public let name: String
        public let language: String
        public let fresh: Int
        public let stale: Int
        public let missing: Int
        public let verbatim: Int
        public let orphans: Int
    }
    public struct Result: Codable, Equatable {
        public let rows: [Row]
        /// The table figures the reported documents use (parked figures
        /// excluded), in reading order, one row per language the reported
        /// documents or the figure itself has. Always present, `[]` when none.
        public let figures: [FigureRow]
        /// Always present, `[]` when every document read cleanly — the
        /// always-present-array precedent `write_translation`'s and `compile`'s
        /// `warnings` set, so a reader never has to tell "absent" from "none".
        public let unreadable_documents: [UnreadableDocument]
    }

    public static let method = "translation_status"
    public static let description =
        "Summarise translation progress. With `document_id`, reports one document; " +
        "without it, walks every manuscript document in the project. Each row is one " +
        "(document, language) pair with paragraph counts by freshness — `fresh`, `stale`, " +
        "`missing` — plus `verbatim` (of the translated paragraphs, how many are copied " +
        "unchanged from source rather than actually translated), `orphans` (translations " +
        "whose source paragraph was deleted), and `open_queries` (unresolved translator " +
        "questions raised against that language, whole-document ones included). A " +
        "language shows up here as soon as a " +
        "translator asks a query against it, even before any translation file exists for " +
        "it — that row's coverage counts are all zero (nothing to derive yet) with " +
        "`open_queries` real, distinct from a language that has files but nothing missing. " +
        "`unreadable_documents` (always present, empty when the whole book read cleanly) " +
        "names every document this call could not open, with the reason — its rows are " +
        "missing from `rows` rather than zero, so read it before concluding a chapter is " +
        "untranslated. " +
        "`reader` and `collator` name the edition's blind reader and collator the same way " +
        "`translator` does. `last_round` (omitted until a pipeline round has run on that " +
        "document) carries the newest round's number, the two readers' verdicts, its " +
        "note/departure/declined counts, its summary, and `stopped_at` for a round that " +
        "failed or was cancelled. " +
        "`figures` (always present) lists the table figures those documents use, one " +
        "row per (figure, language) with text-cell counts — `fresh`, `stale`, `missing`, " +
        "`verbatim`, `orphans`; a language the figure has no translation in yet counts " +
        "its every text cell `missing`. A figure whose translations would not read is " +
        "named in `unreadable_documents` by its figure id. " +
        "Use it to see how much of a book is translated and where retranslation is due. " +
        "See get_help topic 'translation-pass' for the translation workflow."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string","description":"optional — omit to report every manuscript document in the project"}},"required":["project_id"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.unknownProjectID(params.project_id)
        }

        // Which documents to report: the named one, or every manuscript leaf.
        //
        // **An id the manifest does not hold is a CALLER error and still fails
        // loudly** (issue #43, and AREA.md's rule for every tool in the
        // catalogue). The degrade below is for a document the manifest LISTS
        // that will not open; a made-up id is a different thing said in the same
        // field, and answering it with rows: [] plus an entry naming it would
        // tell a caller their typo is a damaged chapter. Checked against the
        // manifest alone, which is one spelling and sufficient: a document the
        // editor has open is in the manifest too. Whole-book walks are
        // unaffected — every id in them came from the manifest.
        let docIds: [String]
        if let documentId = params.document_id {
            guard TreeWalk.find(id: documentId, in: entry.store.manifest.structure) != nil
            else {
                throw MCPError.invalidArgument(
                    "document_id not found in project manifest: \(documentId)")
            }
            docIds = [documentId]
        } else {
            docIds = EditionStatus.manuscriptDocumentIds(in: entry.store.manifest)
        }

        // **The union, the coverage derivation and the open-query filter are
        // `EditionStatus`'s** (publish-department P4 Task 2) — they were this
        // handler's own body until the department desk had to report the same
        // figures, and a desk that derived its own would be a second answer to
        // "how far along is the Spanish edition" with no way for a writer to
        // tell which one is wrong. The tool's job is the wire form on either
        // side, exactly as `write_translation`'s is.
        //
        // **It no longer throws for one document** (issue #43, F-D): a chapter
        // whose history file is present and unreadable used to escape a raw
        // `OpLogStore.ReadError` out of this handler, so a whole book's
        // translation status became one failed call. It now degrades to an
        // entry in `unreadable_documents`, which is the same fact the desk
        // draws — one derivation, one degrade.
        let report = await EditionStatus.documentRows(
            documentIds: docIds, store: entry.store, projectURL: entry.url)
        let rounds = TranslationRoundStore(projectURL: entry.url)

        let figures = await figureRows(
            onlyUsedIn: params.document_id, languages: Set(report.rows.map(\.language)),
            store: entry.store, projectURL: entry.url)

        return try JSONEncoder().encode(Result(rows: report.rows.map {
            Row(document_id: $0.documentId,
                language: $0.language,
                translator: $0.translator,
                reader: EditionStatus.readerName(for: $0.language, in: entry.store.manifest),
                collator: EditionStatus.collatorName(for: $0.language, in: entry.store.manifest),
                fresh: $0.fresh,
                stale: $0.stale,
                missing: $0.missing,
                verbatim: $0.verbatim,
                orphans: $0.orphans,
                open_queries: $0.openQueries,
                last_round: rounds.latest(language: $0.language, docId: $0.documentId).map {
                    LastRound(number: $0.number, leg2_verdict: $0.leg2?.verdict,
                              leg4_verdict: $0.leg4?.verdict, notes: $0.noteCount,
                              departures: $0.departures.count, declined: $0.declinedCount,
                              summary: $0.summary, stopped_at: $0.stoppedAt?.name)
                })
        }, figures: figures.rows, unreadable_documents: report.unreadable.map {
            UnreadableDocument(document_id: $0.documentId,
                               title: $0.title,
                               reason: $0.reason)
        } + figures.unreadable))
    }

    /// The `figures` section: each table figure a reported document uses
    /// (every document when `documentId` is nil), unparked and registered —
    /// a removed figure is not, so its translations are never counted — in
    /// reading order, derived per language over its current table.
    @MainActor
    static func figureRows(
        onlyUsedIn documentId: String?, languages: Set<String>,
        store: ProjectStore, projectURL: URL
    ) async -> (rows: [FigureRow], unreadable: [UnreadableDocument]) {
        let listing = await FigureListingSource.rows(store: store)
        let snapshot = await store.publishFigures()
        let records = Dictionary(
            snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let used = listing.filter { row in
            !snapshot.parked.contains(row.figureId)
                && row.usedIn.contains { documentId == nil || $0.docId == documentId }
        }
        // One trust resolution for every figure, as `EditionStatus` does for
        // the documents; a registry that will not read names each figure.
        let resolved = Swift.Result {
            try TrustResolution.resolve(projectURL: projectURL, identities: .current)
        }
        var rows: [FigureRow] = []
        var unreadable: [UnreadableDocument] = []
        for listed in used {
            guard let record = records[listed.figureId] else { continue }
            switch record.kind {
            case .table: break
            case .image, .unknown: continue
            }
            do {
                guard let table = snapshot.states[record.id]?.table else {
                    throw MCPError.invalidArgument("its op log would not fold")
                }
                let tongues = languages.union(
                    TranslationStore.languages(forDocId: record.id, in: projectURL))
                var perLanguage: [FigureRow] = []
                for language in tongues.sorted() {
                    let derived = FigureTranslationDeriver.derive(
                        records: try TranslationStore.loadMerged(
                            forDocId: record.id, language: language, in: projectURL,
                            trust: try resolved.get()),
                        table: table, language: language)
                    perLanguage.append(FigureRow(
                        figure_id: record.id, name: record.name, language: language,
                        fresh: derived.freshCount, stale: derived.staleCount,
                        missing: derived.missingCount,
                        verbatim: derived.entries.filter(\.verbatim).count,
                        orphans: derived.orphans.count))
                }
                rows += perLanguage
            } catch {
                unreadable.append(UnreadableDocument(
                    document_id: record.id, title: "Table: \(record.name)",
                    reason: error.localizedDescription))
            }
        }
        return (rows, unreadable)
    }
}
