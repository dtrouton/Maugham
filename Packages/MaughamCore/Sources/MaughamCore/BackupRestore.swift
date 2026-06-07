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

    /// The relative paths in `gen` that don't match its manifest (empty == intact).
    /// Throws nothing — an unreadable manifest yields `[]` (treated as can't-verify;
    /// `newestIntact` therefore won't pick a generation whose manifest is gone — see
    /// note). Use for an integrity badge in the restore list.
    public static func verify(_ gen: RestoreGeneration) -> [String] {
        ((try? BackupWriter.verifyGeneration(id: gen.id, at: gen.destination)) ?? ["<unverifiable>"])
    }

    /// The newest generation across `destinations` that verifies intact, or nil if
    /// none do — the "auto-bisect-to-good" path for recovering from corruption.
    public static func newestIntact(across destinations: [URL]) -> RestoreGeneration? {
        listGenerations(across: destinations).first { verify($0).isEmpty }
    }

    /// Restore `gen` into a NEW folder at `target` — never into the live project.
    /// Refuses if `target` exists or the generation fails integrity. Strips the
    /// backup sidecars (manifest + signature) so the result is a clean project.
    /// Returns `target`.
    @discardableResult
    public static func restoreBeside(_ gen: RestoreGeneration, to target: URL) throws -> URL {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path) else {
            throw RestoreError.targetAlreadyExists(target)
        }
        let mismatches = verify(gen)
        guard mismatches.isEmpty else {
            throw RestoreError.generationCorrupt(mismatchedPaths: mismatches)
        }
        // Copy the whole generation (APFS CoW where possible), then drop the sidecars.
        try fm.copyItem(at: gen.directory, to: target)
        for sidecar in [BackupWriter.manifestName, BackupSignature.signatureName] {
            try? fm.removeItem(at: target.appendingPathComponent(sidecar))
        }
        return target
    }
}
