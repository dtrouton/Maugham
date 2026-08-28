import Foundation

public struct PublicationSnapshot: Codable, Equatable, Sendable {

    public struct File: Codable, Equatable, Sendable {
        public let relativePath: String       // relative to .maugham/publish/
        public let textContent: String?       // for *.tex, *.css, *.json
        public let base64Content: String?     // for binary (cover, fonts)

        public init(relativePath: String, textContent: String?, base64Content: String?) {
            self.relativePath = relativePath
            self.textContent = textContent
            self.base64Content = base64Content
        }

        public var isText: Bool { textContent != nil }
        public var isBinary: Bool { base64Content != nil }

        enum CodingKeys: String, CodingKey {
            case relativePath = "relative_path"
            case textContent = "text_content"
            case base64Content = "base64_content"
        }
    }

    public let snapshotID: String
    public let createdAt: Date
    public let publishFiles: [File]
    public let config: PublishConfig
    public let maughamVersion: String
    public let tectonicVersion: String
    /// The languages this snapshot's compile rendered a body for, in order,
    /// with the source body spelled the way the config spells it (P2).
    ///
    /// Optional because every snapshot minted before P2 has no such key, and a
    /// republish reads snapshots the writer already has on disk: absent decodes
    /// as `nil` — "this one does not say" — rather than throwing. Present on
    /// everything captured from now on, single-language compiles included.
    public let languages: [String]?

    public init(
        snapshotID: String, createdAt: Date,
        publishFiles: [File], config: PublishConfig,
        maughamVersion: String, tectonicVersion: String,
        languages: [String]? = nil
    ) {
        self.snapshotID = snapshotID
        self.createdAt = createdAt
        self.publishFiles = publishFiles
        self.config = config
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
        self.languages = languages
    }

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id"
        case createdAt = "created_at"
        case publishFiles = "publish_files"
        case config
        case maughamVersion = "maugham_version"
        case tectonicVersion = "tectonic_version"
        case languages
    }
}
