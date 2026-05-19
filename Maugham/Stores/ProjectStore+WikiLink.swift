import Foundation

// MARK: - WikiLinkProject

extension ProjectStore: WikiLinkProject {
    /// Resolve a [[wiki-link]] title to the id of the first manuscript document
    /// whose title matches case-insensitively (after trimming). Used by the
    /// editor's wiki-link click handler to navigate.
    public func resolveDocumentId(forTitle title: String) -> String? {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        return Self.findFirstByTitle(normalized, in: manifest.structure)
    }

    private static func findFirstByTitle(
        _ normalized: String, in items: [StructureItem]
    ) -> String? {
        for item in items {
            if item.type == .document,
               item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                   .lowercased() == normalized {
                return item.id
            }
            if let children = item.children,
               let nested = findFirstByTitle(normalized, in: children) {
                return nested
            }
        }
        return nil
    }
}
