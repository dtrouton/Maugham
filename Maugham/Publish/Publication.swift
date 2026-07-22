import Foundation

public struct Publication: Codable, Equatable, Sendable {
    public let publicationID: String
    public let version: String
    public let label: String?
    public let format: PublishConfig.Format
    public let outputPath: String           // relative to project root
    public let snapshotID: String
    public let checkpointID: String
    public let republishedFrom: String?     // prior publication version, if any
    public let compiledAt: Date
    public let maughamVersion: String
    public let tectonicVersion: String
    /// The edition's language tag, when this publication is a translated
    /// edition. `nil` for source-language publications (and any record written
    /// before this field existed — synthesized `decodeIfPresent`).
    public let language: String?
    /// Whether the compile that produced this publication ran under
    /// `allow_stale` (translation gaps demoted to warnings with source-text
    /// fallback, rather than blocking). `false` for a strict-gated compile
    /// AND for any record written before this field existed (ADR 0015
    /// additive pattern — `decodeIfPresent ?? false`; see `TranslationRecord
    /// .verbatim` for the template). `Republisher` reads this to decide
    /// whether a republish should re-run the coverage gate in allow-stale
    /// mode (Task 9 F1 round 3) or block unconditionally.
    public let allowStale: Bool

    public init(
        publicationID: String,
        version: String,
        label: String?,
        format: PublishConfig.Format,
        outputPath: String,
        snapshotID: String,
        checkpointID: String,
        republishedFrom: String?,
        compiledAt: Date,
        maughamVersion: String,
        tectonicVersion: String,
        language: String? = nil,
        allowStale: Bool = false
    ) {
        self.publicationID = publicationID
        self.version = version
        self.label = label
        self.format = format
        self.outputPath = outputPath
        self.snapshotID = snapshotID
        self.checkpointID = checkpointID
        self.republishedFrom = republishedFrom
        self.compiledAt = compiledAt
        self.maughamVersion = maughamVersion
        self.tectonicVersion = tectonicVersion
        self.language = language
        self.allowStale = allowStale
    }

    enum CodingKeys: String, CodingKey {
        case publicationID = "publication_id"
        case version, label, format
        case outputPath = "output_path"
        case snapshotID = "snapshot_id"
        case checkpointID = "checkpoint_id"
        case republishedFrom = "republished_from"
        case compiledAt = "compiled_at"
        case maughamVersion = "maugham_version"
        case tectonicVersion = "tectonic_version"
        case language
        case allowStale = "allow_stale"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        publicationID = try c.decode(String.self, forKey: .publicationID)
        version = try c.decode(String.self, forKey: .version)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        format = try c.decode(PublishConfig.Format.self, forKey: .format)
        outputPath = try c.decode(String.self, forKey: .outputPath)
        snapshotID = try c.decode(String.self, forKey: .snapshotID)
        checkpointID = try c.decode(String.self, forKey: .checkpointID)
        republishedFrom = try c.decodeIfPresent(String.self, forKey: .republishedFrom)
        compiledAt = try c.decode(Date.self, forKey: .compiledAt)
        maughamVersion = try c.decode(String.self, forKey: .maughamVersion)
        tectonicVersion = try c.decode(String.self, forKey: .tectonicVersion)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        allowStale = try c.decodeIfPresent(Bool.self, forKey: .allowStale) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(publicationID, forKey: .publicationID)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(format, forKey: .format)
        try c.encode(outputPath, forKey: .outputPath)
        try c.encode(snapshotID, forKey: .snapshotID)
        try c.encode(checkpointID, forKey: .checkpointID)
        try c.encodeIfPresent(republishedFrom, forKey: .republishedFrom)
        try c.encode(compiledAt, forKey: .compiledAt)
        try c.encode(maughamVersion, forKey: .maughamVersion)
        try c.encode(tectonicVersion, forKey: .tectonicVersion)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encode(allowStale, forKey: .allowStale)
    }
}
