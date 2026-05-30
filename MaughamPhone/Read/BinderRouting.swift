import Foundation
import MaughamCore

/// Pure routing helpers for the binder (E.3) to turn a tapped `StructureItem`
/// into an openable manuscript file. No SwiftUI — trivially unit-testable.
enum BinderRouting {
    enum DocKind: Equatable { case markdown, fountain, other }

    /// A `StructureItem` the reader can open: a `document` node carrying a real,
    /// non-empty path. Groups (and path-less documents) are not readable.
    static func isReadableDocument(_ item: StructureItem) -> Bool {
        guard item.type == .document else { return false }
        guard let path = item.path, !path.isEmpty else { return false }
        return true
    }

    /// Absolute URL of the item's manuscript file under `projectRoot`, or nil
    /// for a group or a path-less document. The stored `path` is project-root
    /// relative; we resolve it against the root.
    static func documentURL(for item: StructureItem, projectRoot: URL) -> URL? {
        guard isReadableDocument(item), let path = item.path else { return nil }
        return projectRoot.appendingPathComponent(path)
    }

    /// Classify a doc URL by extension: `.md` → `.markdown`,
    /// `.fountain` → `.fountain`, everything else → `.other`.
    static func kind(of url: URL) -> DocKind {
        switch url.pathExtension.lowercased() {
        case "md": return .markdown
        case "fountain": return .fountain
        default: return .other
        }
    }
}
