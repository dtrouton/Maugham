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
        tectonicVersion: String
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
    }
}
