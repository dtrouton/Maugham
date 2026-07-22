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
        "structural drift (a dropped **bold** run, changed block shape) and any " +
        "warnings are returned. " +
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
            }
        }

        // 7. Response.
        return try JSONEncoder().encode(Result(
            written: params.entries.count,
            language: params.language,
            warnings: warnings))
    }
}
