import Foundation
import MaughamCore

// MARK: - Collection-Pieces: Reference Resolution

public enum ReferenceResolution: Equatable {
    case resolved(URL)
    case resolvedViaPathFallback(URL)
    case unresolved
}

extension ProjectStore {
    public func resolveReference(_ piece: StructureItem) -> ReferenceResolution {
        guard piece.pieceKind == .reference else { return .unresolved }
        // Bookmark path
        if let bookmark = piece.linkedProjectBookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale) {
                // Validate it still points at a project
                let manifestURL = resolved.appendingPathComponent(ProjectManifest.fileName)
                if FileManager.default.fileExists(atPath: manifestURL.path) {
                    return .resolved(resolved.resolvingSymlinksInPath())
                }
            }
        }
        // Path fallback
        if let pathStr = piece.linkedProjectPath {
            let candidate = URL(fileURLWithPath: pathStr)
            let manifestURL = candidate.appendingPathComponent(ProjectManifest.fileName)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return .resolvedViaPathFallback(candidate)
            }
        }
        return .unresolved
    }

    /// Update an existing reference piece's link target. Rewrites the
    /// .maugham-link.json on disk and refreshes the manifest entry's
    /// path + bookmark. Used by Inspector's Re-link button when the
    /// original reference is unresolved.
    public func relinkReference(pieceId: String, newURL: URL) async throws {
        guard let idx = manifest.structure.firstIndex(where: { $0.id == pieceId }) else {
            throw ProjectStoreError.fileSystemError("Unknown piece: \(pieceId)")
        }
        guard manifest.structure[idx].pieceKind == .reference,
              let relPath = manifest.structure[idx].path else {
            throw ProjectStoreError.fileSystemError("Piece is not a reference")
        }
        let targetManifestURL = newURL.appendingPathComponent(ProjectManifest.fileName)
        guard FileManager.default.fileExists(atPath: targetManifestURL.path) else {
            throw ProjectStoreError.fileSystemError(
                "Selected folder is not a Maugham project")
        }
        let bookmarkData = try newURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        manifest.structure[idx].linkedProjectPath = newURL.path
        manifest.structure[idx].linkedProjectBookmark = bookmarkData

        let linkURL = url.appendingPathComponent(relPath)
        let linkFile = CollectionLinkFile(
            version: 1,
            title: manifest.structure[idx].title,
            path: newURL.path,
            bookmark: bookmarkData.base64EncodedString(),
            linkedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(linkFile).write(to: linkURL, options: .atomic)

        manifest.modified = Date()
        try await saveManifest()
    }
}
