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
        // ADR 0018: op log is the sole source of truth. Reading the .md as a
        // fallback is forbidden — it would silently surface stale file content
        // instead of the canonical op-log state.
        let text = DerivedManuscript.materialize(forDocId: item.id, in: projectStore.url)
        return ProjectASTBuilder.PieceRef(
            pieceID: item.id,
            title: item.title,
            mode: mode,
            displayText: text)
    }
}
