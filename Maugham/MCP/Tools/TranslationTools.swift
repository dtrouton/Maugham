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

        // 1. Valid language tag — the pipeline's own gate, called here so a
        // malformed tag is refused before the registry is touched.
        try TranslationWritePipeline.validate(language: params.language)

        let state = try currentParagraphState(
            projectId: params.project_id,
            documentId: params.document_id,
            registry: registry)

        // 2-6. Validation, record building and the single append all belong to
        // the pipeline, which the coming ingest path shares (census:
        // TripwireGrepTests). The tool's job is the wire form on either side.
        let warnings = try TranslationWritePipeline.perform(
            entries: params.entries.map {
                TranslationWritePipeline.Entry(
                    paragraphId: $0.paragraph_id, text: $0.text,
                    verbatim: $0.verbatim, delete: $0.delete)
            },
            language: params.language,
            documentId: params.document_id,
            state: state,
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current))

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

/// The translator's display name for `language`, read without minting.
///
/// **A read tool must not mint** (the rule stated in
/// `ProjectStore+ProductionRoles.swift`'s doc comment): this is a pure lookup
/// over `manifest.productionRoles` plus the preset table, never
/// `ProjectStore.translatorRole(for:)`, which finds-or-creates and would stamp
/// the manifest merely because `translation_status` was asked. Resolution
/// order: the stored role's `effectiveName` when this language has one
/// already (a rename or a prior mint both count), else the preset name, else
/// nil — an unlisted, unminted language has no honest name to report.
///
/// Matching is `ProjectManifest.storedTranslator(for:)`'s — the one spelling of
/// the case-insensitive tag compare, shared with the mint's own find-half, so
/// no reader can disagree with the writer about which row is this language's.
func translatorName(for language: String, in manifest: ProjectManifest) -> String? {
    if let stored = manifest.storedTranslator(for: language) { return stored.effectiveName }
    return ProductionRole.defaultTranslatorName(language: language)
}

public enum TranslationStatusTool: MCPTool {
    public struct Row: Codable, Equatable {
        public let document_id: String
        public let language: String
        /// The stored role's `effectiveName`, else the preset for this
        /// language, else omitted — an unlisted, unminted language has no
        /// honest name to report. Never mints (see `translatorName(for:in:)`).
        public let translator: String?
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
        "questions raised against that language, whole-document ones included). A " +
        "language shows up here as soon as a " +
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
            //
            // **Craft notes count too.** A whole-document translation
            // question ("tú or usted throughout?") cannot be a `.query` —
            // `addAnnotation` refuses an anchorless one — so it mints as a
            // language-tagged `.craftNote`, and counting only `.query` here
            // reported `open_queries: 0` over a translator who was waiting on
            // an answer. The tag does the discriminating: an untagged craft
            // note has a nil `language` and survives neither the filter below
            // nor `queryLanguages`. The translator's own briefing gather
            // widened the same one way, so what the writer is told and what
            // the next round is briefed on cannot disagree.
            let openQueries = try await withAnnotationDocument(
                projectId: params.project_id, documentId: docId, registry: registry
            ) { doc in
                doc.annotations(filter: AnnotationFilter(
                    kinds: [.query, .craftNote], statuses: [.open]))
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
                let translator = translatorName(for: language, in: entry.store.manifest)
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
                        translator: translator,
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
                        translator: translator,
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
