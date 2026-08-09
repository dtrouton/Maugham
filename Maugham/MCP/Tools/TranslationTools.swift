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
    // Open doc → live Document.
    if let ds = entry.store.documentStore,
       let doc = ds.document(forDocId: documentId) {
        return (doc.sequence, doc.paragraphs, entry.url)
    }
    // Closed doc → op-log-derived state. Verify the id resolves to a manuscript
    // item first so an unknown id fails cleanly rather than deriving empty.
    guard TreeWalk.find(id: documentId, in: entry.store.manifest.structure) != nil else {
        throw MCPError.invalidArgument(
            "document_id not found in project manifest: \(documentId)")
    }
    let state = entry.store.derivedCache.state(forDocId: documentId, in: entry.url)
    return (state.sequence, state.paragraphs, entry.url)
}

// MARK: - write_translation

public enum WriteTranslationTool: MCPTool {
    public struct Entry: Codable {
        public let paragraph_id: String
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
        "Each entry supplies exactly one of `text` (the translated paragraph), " +
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
        "See get_help topic 'translation-pass' for the translation workflow."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"language":{"type":"string","description":"lowercase tag, e.g. es, pt-br"},"entries":{"type":"array","items":{"type":"object","properties":{"paragraph_id":{"type":"string"},"text":{"type":"string"},"verbatim":{"type":"boolean","description":"copy current source text as the translation (chrome idiom)"},"delete":{"type":"boolean","description":"remove this paragraph's translation; exempt from the unknown-id check, so an orphan can be purged"}},"required":["paragraph_id"]}}},"required":["project_id","document_id","language","entries"]}"#

    @MainActor
    public static func handle(
        paramsJSON: Data?, registry: ProjectRegistry
    ) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)

        // 1. Valid language tag.
        guard TranslationRecord.isValidLanguageTag(params.language) else {
            throw MCPError.invalidArgument("invalid language tag: \(params.language)")
        }

        let state = try currentParagraphState(
            projectId: params.project_id,
            documentId: params.document_id,
            registry: registry)

        // 2. Each entry supplies exactly one of `text` / `verbatim: true` /
        // `delete: true`.
        for e in params.entries {
            let forms = [e.text != nil, e.verbatim == true, e.delete == true]
            if forms.filter({ $0 }).count != 1 {
                throw MCPError.invalidArgument(
                    "entry for paragraph \(e.paragraph_id) must supply exactly one of " +
                    "`text`, `verbatim: true` or `delete: true`")
            }
        }

        // 2a. Reject intra-batch duplicate paragraph ids (a client bug).
        let ids = params.entries.map(\.paragraph_id)
        let duplicates = Array(Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })).sorted()
        if !duplicates.isEmpty {
            throw MCPError.invalidArgument(
                "duplicate paragraph ids in batch: \(duplicates.joined(separator: ", "))")
        }

        // 3. All-or-nothing: every id a `text` or `verbatim` entry names must be
        // in the current sequence. A `delete` entry is exempt — an orphaned
        // translation names a paragraph the document no longer has, which is
        // exactly the one a writer needs to purge, and tombstoning an id that
        // was never translated is an idempotent no-op. The exemption is per
        // entry, not per batch: a text entry's unknown id still rejects the
        // whole call, its delete siblings included.
        let known = Set(state.sequence)
        let unknown = params.entries
            .filter { $0.delete != true }
            .map(\.paragraph_id)
            .filter { !known.contains($0) }
        if !unknown.isEmpty {
            throw MCPError.invalidArgument(
                "unknown paragraph ids: \(unknown.joined(separator: ", "))")
        }

        // 4-6. Build every record first, then persist the whole batch in one
        // write, so "nothing is written" holds for an I/O failure and not only
        // for a validation failure. Every record carries `params.language` —
        // one call is one language, the invariant `appendBatch` takes the tag
        // as a parameter for and does not re-check per record.
        let deviceSlug = DeviceSlug.make(from: MacDeviceID.current)
        var warnings: [String] = []
        var records: [TranslationRecord] = []
        for e in params.entries {
            let source = state.paragraphs[e.paragraph_id] ?? ""
            let isVerbatim = e.verbatim == true
            let isDelete = e.delete == true
            // `text == nil` is the tombstone `TranslationStore.latestByParagraph`
            // already honors — the delete form is what finally mints one.
            let text: String? = isDelete ? nil : (isVerbatim ? source : (e.text ?? ""))
            records.append(TranslationRecord(
                paragraphId: e.paragraph_id,
                language: params.language,
                text: text,
                sourceHash: TranslationHash.hash(source),
                verbatim: isVerbatim))
            if !isVerbatim, !isDelete, let translation = text {
                warnings.append(contentsOf: ConstructSkeleton.warnings(
                    source: source, translation: translation, paragraphId: e.paragraph_id))
                // Both sides in display form, normalized through the same
                // stripper the freshness hash normalizes with: against the raw
                // source this comparison could never fire on an anchored
                // paragraph — a slugline or a numeral, the very lines the
                // advisory exists for.
                if MarkdownDisplayFilter.stripAnchors(translation)
                    == MarkdownDisplayFilter.stripAnchors(source) {
                    warnings.append(
                        "¶\(e.paragraph_id): translated text equals source — mark " +
                        "verbatim: true if deliberate")
                }
            }
        }
        try TranslationStore.appendBatch(
            records, forDocId: params.document_id, language: params.language,
            deviceSlug: deviceSlug, in: state.projectURL)

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
    public struct Result: Codable, Equatable {
        public let language: String
        public let entries: [Entry]
        public let orphan_count: Int
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
        "See get_help topic 'translation-pass' for the translation workflow."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"language":{"type":"string","description":"lowercase tag, e.g. es, pt-br"},"status":{"type":"string","description":"optional filter: fresh | stale | missing — omit for all paragraphs"}},"required":["project_id","document_id","language"]}"#

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

        let state = try currentParagraphState(
            projectId: params.project_id,
            documentId: params.document_id,
            registry: registry)

        let records = TranslationStore.loadMerged(
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
}

// MARK: - translation_status

public enum TranslationStatusTool: MCPTool {
    public struct Row: Codable, Equatable {
        public let document_id: String
        public let language: String
        public let fresh: Int
        public let stale: Int
        public let missing: Int
        public let verbatim: Int
        public let orphans: Int
        public let open_queries: Int
    }
    public struct Params: Codable {
        public let project_id: String
        public let document_id: String?
    }
    public struct Result: Codable, Equatable {
        public let rows: [Row]
    }

    public static let method = "translation_status"
    public static let description =
        "Summarise translation progress. With `document_id`, reports one document; " +
        "without it, walks every manuscript document in the project. Each row is one " +
        "(document, language) pair with paragraph counts by freshness — `fresh`, `stale`, " +
        "`missing` — plus `verbatim` (of the translated paragraphs, how many are copied " +
        "unchanged from source rather than actually translated), `orphans` (translations " +
        "whose source paragraph was deleted), and `open_queries` (unresolved translator " +
        "questions raised against that language). A language shows up here as soon as a " +
        "translator asks a query against it, even before any translation file exists for " +
        "it — that row's coverage counts are all zero (nothing to derive yet) with " +
        "`open_queries` real, distinct from a language that has files but nothing missing. " +
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

        // Which documents to report: the named one, or every manuscript leaf
        // (skip collection references, same walk as ProjectStoreASTSource).
        let docIds: [String]
        if let only = params.document_id {
            docIds = [only]
        } else {
            docIds = ProjectStore.collectDocuments(in: entry.store.manifest.structure)
                .filter { $0.pieceKind != .reference }
                .map(\.id)
        }

        let explicitDoc = params.document_id != nil
        var rows: [Row] = []
        for docId in docIds {
            // Languages with an actual translation file — a cheap filename scan.
            let fileLanguages = Set(TranslationStore.languages(forDocId: docId, in: entry.url))

            // Open translator questions for this doc, resolved the same
            // open/closed way list_annotations (and TranslationReviewPane's
            // own filter) do so counts match the pane. Fetched once per doc;
            // also the source of query-first languages (M2) — a translator
            // can ask about a language before any file for it exists, so the
            // row set is the UNION of file languages and languages tagged on
            // an open query, not file languages alone.
            let openQueries = try await withAnnotationDocument(
                projectId: params.project_id, documentId: docId, registry: registry
            ) { doc in
                doc.annotations(filter: AnnotationFilter(
                    kinds: [.query], statuses: [.open]))
            }
            let queryLanguages = Set(openQueries.compactMap(\.language))
            let languages = fileLanguages.union(queryLanguages).sorted()

            // In the project-wide walk, skip documents with neither a
            // translation file nor an open query for any language. An
            // explicit document_id always resolves so a bad id fails loudly
            // rather than returning empty rows.
            if !explicitDoc && languages.isEmpty { continue }

            for language in languages {
                let openQueryCount = openQueries.filter { $0.language == language }.count
                if fileLanguages.contains(language) {
                    let state = try currentParagraphState(
                        projectId: params.project_id, documentId: docId, registry: registry)
                    let records = TranslationStore.loadMerged(
                        forDocId: docId, language: language, in: state.projectURL)
                    let derived = TranslationDeriver.derive(
                        records: records, sequence: state.sequence,
                        paragraphs: state.paragraphs, language: language)
                    rows.append(Row(
                        document_id: docId,
                        language: language,
                        fresh: derived.freshCount,
                        stale: derived.staleCount,
                        missing: derived.missingCount,
                        verbatim: derived.verbatimCount,
                        orphans: derived.orphans.count,
                        open_queries: openQueryCount))
                } else {
                    // Query-only language: no translation file yet, so there
                    // is no coverage to derive — report it zero/absent rather
                    // than "every paragraph missing", which would conflate
                    // "not started" with "started and incomplete".
                    rows.append(Row(
                        document_id: docId,
                        language: language,
                        fresh: 0,
                        stale: 0,
                        missing: 0,
                        verbatim: 0,
                        orphans: 0,
                        open_queries: openQueryCount))
                }
            }
        }

        return try JSONEncoder().encode(Result(rows: rows))
    }
}
