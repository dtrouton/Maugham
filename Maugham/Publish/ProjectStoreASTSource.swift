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
@MainActor
public struct ProjectStoreASTSource: ProjectASTBuilder.Source {

    public let projectStore: ProjectStore

    public init(projectStore: ProjectStore) {
        self.projectStore = projectStore
    }

    public func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
        let docs = ProjectStore.collectDocuments(in: projectStore.manifest.structure)
        return docs.compactMap(pieceRef(for:))
    }

    private func pieceRef(for item: StructureItem) -> ProjectASTBuilder.PieceRef? {
        if item.pieceKind == .reference { return nil }
        guard let path = item.path else { return nil }
        let mode: ProjectAST.Mode = path.lowercased().hasSuffix(".fountain")
            ? .fountain
            : .prose
        // ADR 0018 open-doc rule: an OPEN doc's live `Document` is the freshest
        // source — the op log lags an actively-edited doc by the burst window
        // (30s idle / 90s cap), since the 750ms autosave appends no ops. So a
        // compile must take the in-memory anchored form (matching the derived
        // fallback) for open docs, deriving only for closed ones. Reading the
        // `.md` directly stays forbidden — it can be a stale artifact.
        let text: String
        if let ds = projectStore.documentStore, let doc = ds.document(for: path) {
            text = doc.materialize()
        } else {
            text = DerivedManuscript.materialize(forDocId: item.id, in: projectStore.url)
        }
        return ProjectASTBuilder.PieceRef(
            pieceID: item.id,
            title: item.title,
            mode: mode,
            displayText: text)
    }
}
