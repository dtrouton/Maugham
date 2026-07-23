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
        "Each entry supplies either `text` (the translated paragraph) or " +
        "`verbatim: true` (copy the current source text unchanged — for chrome " +
        "like sluglines or numerals that don't translate). The server stamps each " +
        "record with a hash of the current source paragraph so downstream reads " +
        "can flag a translation as stale after the source is edited. Paragraph ids " +
        "come from read_document; every id must be current — an unknown id rejects " +
        "the whole batch (nothing is written). Non-verbatim entries are checked for " +
        "structural drift (a dropped **bold** run, changed block shape) and, if the " +
        "translated text is identical to the current source, a reminder to mark it " +
        "`verbatim: true` instead — these are advisory only and never block the write. " +
        "See get_help topic 'translation-pass' for the translation workflow."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"document_id":{"type":"string"},"language":{"type":"string","description":"lowercase tag, e.g. es, pt-br"},"entries":{"type":"array","items":{"type":"object","properties":{"paragraph_id":{"type":"string"},"text":{"type":"string"},"verbatim":{"type":"boolean","description":"copy current source text as the translation (chrome idiom)"}},"required":["paragraph_id"]}}},"required":["project_id","document_id","language","entries"]}"#

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

        // 2. Each entry supplies exactly one of `text` / `verbatim: true`.
        for e in params.entries {
            let hasText = e.text != nil
            let isVerbatim = e.verbatim == true
            if hasText == isVerbatim {
                throw MCPError.invalidArgument(
                    "entry for paragraph \(e.paragraph_id) must supply exactly one of " +
                    "`text` or `verbatim: true`")
            }
        }

        // 2a. Reject intra-batch duplicate paragraph ids (a client bug).
        let ids = params.entries.map(\.paragraph_id)
        let duplicates = Array(Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })).sorted()
        if !duplicates.isEmpty {
            throw MCPError.invalidArgument(
                "duplicate paragraph ids in batch: \(duplicates.joined(separator: ", "))")
        }

        // 3. All-or-nothing: every id must be in the current sequence.
        let known = Set(state.sequence)
        let unknown = params.entries.map(\.paragraph_id).filter { !known.contains($0) }
        if !unknown.isEmpty {
            throw MCPError.invalidArgument(
                "unknown paragraph ids: \(unknown.joined(separator: ", "))")
        }

        // 4-6. Build + append one record per entry; collect drift warnings.
        let deviceSlug = DeviceSlug.make(from: MacDeviceID.current)
        var warnings: [String] = []
        for e in params.entries {
            let source = state.paragraphs[e.paragraph_id] ?? ""
            let isVerbatim = e.verbatim == true
            let text = isVerbatim ? source : (e.text ?? "")
            let record = TranslationRecord(
                paragraphId: e.paragraph_id,
                language: params.language,
                text: text,
                sourceHash: TranslationHash.hash(source),
                verbatim: isVerbatim)
            try await TranslationStore.append(
                record, forDocId: params.document_id,
                deviceSlug: deviceSlug, in: state.projectURL)
            if !isVerbatim {
                warnings.append(contentsOf: ConstructSkeleton.warnings(
                    source: source, translation: text, paragraphId: e.paragraph_id))
                if text == source {
                    warnings.append(
                        "¶\(e.paragraph_id): translated text equals source — mark " +
                        "verbatim: true if deliberate")
                }
            }
        }

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
        "questions raised against that language). " +
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
            // In the project-wide walk, skip resolving (and, for a closed doc,
            // deriving) paragraph state for documents with no translation files —
            // a cheap filename scan. An explicit document_id always resolves so a
            // bad id fails loudly rather than returning empty rows.
            let languages = TranslationStore.languages(forDocId: docId, in: entry.url).sorted()
            if !explicitDoc && languages.isEmpty { continue }
            let state = try currentParagraphState(
                projectId: params.project_id, documentId: docId, registry: registry)

            // Open translator questions for this doc, resolved the same
            // open/closed way list_annotations does so counts match the pane.
            // Fetched once per doc; bucketed by language below.
            let openQueries = try await withAnnotationDocument(
                projectId: params.project_id, documentId: docId, registry: registry
            ) { doc in
                doc.annotations(filter: AnnotationFilter(
                    kinds: [.query], statuses: [.open]))
            }

            for language in languages {
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
                    open_queries: openQueries.filter { $0.language == language }.count))
            }
        }

        return try JSONEncoder().encode(Result(rows: rows))
    }
}
