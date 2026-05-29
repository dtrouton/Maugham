import Foundation

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
        let fileURL = projectStore.url.appendingPathComponent(path)
        let mode: ProjectAST.Mode = path.lowercased().hasSuffix(".fountain")
            ? .fountain
            : .prose
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        return ProjectASTBuilder.PieceRef(
            pieceID: item.id,
            title: item.title,
            mode: mode,
            displayText: text)
    }
}
