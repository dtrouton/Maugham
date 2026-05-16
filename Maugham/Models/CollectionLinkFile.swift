import Foundation

/// `.maugham-link.json` — the on-disk representation of a Collection's
/// reference to a standalone Maugham project. Lives at
/// `pieces/<NN>-<slug>/.maugham-link.json`.
///
/// `path` is the absolute path at link-time; used for display + best-effort
/// fallback when the bookmark fails (e.g., cross-Mac via iCloud).
/// `bookmark` is base64-encoded NSURL.bookmarkData with .withSecurityScope.
public struct CollectionLinkFile: Codable, Equatable, Sendable {
    public var version: Int
    public var title: String
    public var path: String
    public var bookmark: String
    public var linkedAt: Date

    public init(version: Int, title: String, path: String, bookmark: String, linkedAt: Date) {
        self.version = version
        self.title = title
        self.path = path
        self.bookmark = bookmark
        self.linkedAt = linkedAt
    }
}
