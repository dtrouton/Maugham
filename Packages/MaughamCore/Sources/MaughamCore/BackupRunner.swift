import Foundation

/// A configured backup target: where to write and how many generations to keep.
/// Plain URL — security-scoped bookmark resolution and config persistence are the
/// Mac layer's job; this stays pure and testable.
public struct BackupDestination: Equatable, Sendable {
    public let url: URL
    public let retention: Int
    public init(url: URL, retention: Int) {
        self.url = url
        self.retention = retention
    }
}

/// The result of attempting a backup to one destination. `run` returns one per
/// destination; status UI will consume these.
public enum BackupOutcome: Sendable, Equatable {
    case written(destination: URL, generation: BackupGeneration)
    case skippedUnchanged(destination: URL)
    case failed(destination: URL, message: String)

    public var destination: URL {
        switch self {
        case .written(let d, _), .skippedUnchanged(let d), .failed(let d, _): return d
        }
    }
}

public enum BackupRunner {
    /// The content root hash of the newest committed generation at `destination`,
    /// or nil if there are none (or the newest has no readable manifest). Used to
    /// decide whether the source has changed since the last backup.
    public static func latestRootHash(at destination: URL) throws -> String? {
        guard let id = try BackupWriter.generationIds(at: destination).last else { return nil }
        let manifestURL = destination
            .appendingPathComponent(id)
            .appendingPathComponent(BackupWriter.manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let manifest = try JSONDecoder().decode(
            MerkleManifest.self, from: Data(contentsOf: manifestURL))
        return manifest.rootHash
    }
}
