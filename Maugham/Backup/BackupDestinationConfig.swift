import Foundation

/// Persisted configuration for one backup destination. The security-scoped
/// bookmark (resolved to a URL at use time) plus how many generations to keep.
/// `id` is stable so status can be keyed to it across resolves.
public struct BackupDestinationConfig: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    /// The folder's filesystem path at the time it was added, for display only
    /// (the bookmark is the source of truth for resolution). Optional so configs
    /// saved before this field decode cleanly.
    public var path: String?
    public var bookmark: Data
    public var retention: Int
    public init(id: String, displayName: String, path: String? = nil, bookmark: Data, retention: Int) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.bookmark = bookmark
        self.retention = retention
    }
}
