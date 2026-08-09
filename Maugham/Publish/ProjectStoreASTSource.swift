import Foundation
import MaughamCore

/// Bridges a live `ProjectStore` to `ProjectASTBuilder.Source`.
///
/// Walks `manifest.structure` in display order, treats every leaf
/// (`StructureItem.type == .document`) as a piece, and resolves
/// `ProjectAST.Mode` from the file extension at `path` (`.fountain` →
/// `.fountain`, everything else → `.prose`).
///
/// Anchor stripping (`<!-- ¶id -->`) happens inside `ProjectASTBuilder.build`
/// so this adapter passes the raw file contents through unchanged.
///
/// Collection references (`pieceKind == .reference`) are skipped in v1 —
/// publishing a project that references other projects produces only the
/// loose pieces' content. Cross-project recursion is a follow-up.
///
/// **The conformance to `ProjectASTBuilder.Source` is itself `@MainActor`,
/// not just the type.** `orderedPieces()` reads `projectStore.manifest` and
/// `projectStore.documentStore` — both `@MainActor`-isolated on `ProjectStore`
/// — synchronously, with no `await`. Marking only the struct `@MainActor`
/// (dropping the isolated-conformance annotation) leaves the *protocol
/// requirement* looking nonisolated from outside, which is unsound: the
/// existential `any ProjectASTBuilder.Source` that `PDFCompiler`/
/// `EPUBCompiler`/`CompileOrchestrator` carry across an `await` (into
/// `CompileJobManager`, itself an `actor`) is not guaranteed to resume on the
/// main actor, so a synchronous call into main-actor state through it would
/// be a real data race. `: @MainActor ProjectASTBuilder.Source` (SE-0470
/// isolated conformances) makes the conformance itself carry the isolation,
/// so the existential enforces it rather than silently permitting an
/// off-actor call — this is why the fix is in the conformance clause and not
/// a `nonisolated` on `orderedPieces()`, which would not type-check against a
/// body that touches `ProjectStore`.
@MainActor
public struct ProjectStoreASTSource: @MainActor ProjectASTBuilder.Source {

    public let projectStore: ProjectStore

    /// When non-nil, `orderedPieces()` substitutes the merged translation
    /// sidecar for this language edition into each piece's display text; when
    /// nil, the source-language materialize path is byte-untouched.
    public let language: String?

    public init(projectStore: ProjectStore, language: String? = nil) {
        self.projectStore = projectStore
        self.language = language
    }

    public func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] {
        let docs = ProjectStore.collectDocuments(in: projectStore.manifest.structure)
        return try docs.compactMap { try pieceRef(for: $0) }
    }

    private func pieceRef(for item: StructureItem) throws -> ProjectASTBuilder.PieceRef? {
        if item.pieceKind == .reference { return nil }
        guard let path = item.path else { return nil }
        let mode: ProjectAST.Mode = path.lowercased().hasSuffix(".fountain")
            ? .fountain
            : .prose
        let text: String
        if let language {
            text = try translatedDisplayText(forDocId: item.id, path: path, language: language)
        } else {
            // ADR 0018 open-doc rule: an OPEN doc's live `Document` is the
            // freshest source — the op log lags an actively-edited doc by the
            // burst window (30s idle / 90s cap), since the 750ms autosave appends
            // no ops. So a compile must take the in-memory anchored form (matching
            // the derived fallback) for open docs, deriving only for closed ones.
            // Reading the `.md` directly stays forbidden — it can be a stale artifact.
            if let ds = projectStore.documentStore, let doc = ds.document(for: path) {
                text = doc.materialize()
            } else {
                text = try projectStore.derivedCache.materialize(forDocId: item.id, in: projectStore.url)
            }
        }
        return ProjectASTBuilder.PieceRef(
            pieceID: item.id,
            title: item.title,
            mode: mode,
            displayText: text)
    }

    /// Display text for a translated edition. Takes the SAME `(sequence,
    /// paragraphs)` source-of-truth split as the nil-language path — open doc →
    /// live `Document`, closed → `derivedCache.state` — never the raw `.md`
    /// (tripwire 20). Overlays the merged translation sidecar and emits, per
    /// paragraph in `sequence` order, `translatedText ?? sourceText`, joined with
    /// the blank-line block separator that `stripAnchors(materialize())` yields.
    /// Consequence: an all-verbatim (identity) translation reproduces the
    /// source-language AST exactly — pinned by `ASTTranslationSubstitutionTests`.
    private func translatedDisplayText(
        forDocId docId: String, path: String, language: String
    ) throws -> String {
        let sequence: [String]
        let paragraphs: [String: String]
        if let ds = projectStore.documentStore, let doc = ds.document(for: path) {
            sequence = doc.sequence
            paragraphs = doc.paragraphs
        } else {
            let state = try projectStore.derivedCache.state(forDocId: docId, in: projectStore.url)
            sequence = state.sequence
            paragraphs = state.paragraphs
        }
        let records = TranslationStore.loadMerged(
            forDocId: docId, language: language, in: projectStore.url)
        let derived = TranslationDeriver.derive(
            records: records, sequence: sequence, paragraphs: paragraphs, language: language)
        // Task 9's coverage gate guards this fallback: a paragraph with no
        // translation (or a stale one) falls back to its source text so the join
        // never drops a block; un-gated stale/missing compiles are refused
        // upstream, so a mixed-language render can only reach here under
        // `allow_stale`.
        return derived.entries
            .map { $0.translatedText ?? $0.sourceText }
            .joined(separator: "\n\n")
    }
}
