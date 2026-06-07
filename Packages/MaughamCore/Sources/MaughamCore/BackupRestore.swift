import Foundation

/// One restorable generation: which destination holds it, its id, and when it was
/// written (read from the embedded manifest, nil if unreadable).
public struct RestoreGeneration: Equatable, Sendable {
    public let destination: URL
    public let id: String
    public let builtAt: Date?
    public init(destination: URL, id: String, builtAt: Date?) {
        self.destination = destination
        self.id = id
        self.builtAt = builtAt
    }
    /// The generation directory `<destination>/<id>`.
    public var directory: URL { destination.appendingPathComponent(id) }
}

public enum RestoreError: Error, Equatable {
    case targetAlreadyExists(URL)
    case generationCorrupt(mismatchedPaths: [String])
}

public enum BackupRestore {
    /// All generations across `destinations`, newest-first (ULID ids sort
    /// chronologically). `builtAt` is read from each generation's manifest.
    public static func listGenerations(across destinations: [URL]) -> [RestoreGeneration] {
        var all: [RestoreGeneration] = []
        for dest in destinations {
            let ids = (try? BackupWriter.generationIds(at: dest)) ?? []
            for id in ids {
                let manifestURL = dest.appendingPathComponent(id)
                    .appendingPathComponent(BackupWriter.manifestName)
                let builtAt = (try? JSONDecoder().decode(
                    MerkleManifest.self, from: Data(contentsOf: manifestURL)))?.builtAt
                all.append(RestoreGeneration(destination: dest, id: id, builtAt: builtAt))
            }
        }
        return all.sorted { $0.id > $1.id }
    }
}
