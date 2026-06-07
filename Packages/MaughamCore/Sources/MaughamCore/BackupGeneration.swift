import Foundation

/// One immutable backup snapshot of a project directory: its id (caller-supplied,
/// typically a ULID for monotonic ordering) and the Merkle manifest of its files.
public struct BackupGeneration: Equatable, Sendable {
    public let id: String
    public let manifest: MerkleManifest
    public init(id: String, manifest: MerkleManifest) {
        self.id = id
        self.manifest = manifest
    }
}

public enum BackupError: Error, Equatable {
    /// The copied generation's bytes did not match the source manifest.
    case verificationFailed(mismatchedPaths: [String])
    /// A generation with this id already exists. Generations are immutable; the
    /// writer refuses to overwrite one (ids are ULIDs, so a collision means a
    /// caller bug, not a legitimate re-write).
    case generationAlreadyExists(id: String)
}
