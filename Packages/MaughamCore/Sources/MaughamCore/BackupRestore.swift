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
    public var directory: URL { destination.appendingPathComponent(id) } // local-path: a generation folder the destination listing returned
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
                let manifestURL = dest.appendingPathComponent(id) // local-path: a generation folder the destination listing returned
                    .appendingPathComponent(BackupWriter.manifestName)
                let builtAt = (try? JSONDecoder().decode(
                    MerkleManifest.self, from: Data(contentsOf: manifestURL)))?.builtAt  // adr-0018-ok: backup Merkle manifest read, not manuscript
                all.append(RestoreGeneration(destination: dest, id: id, builtAt: builtAt))
            }
        }
        return all.sorted { $0.id > $1.id }
    }

    /// The relative paths in `gen` that don't match its manifest (empty == intact).
    /// Throws nothing — an unreadable/missing manifest yields `["<unverifiable>"]`
    /// (non-empty, i.e. treated as *not* intact), so `newestIntact` won't pick a
    /// generation we can't actually check. Use for an integrity badge in the list.
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
        renewIdentity(in: target)
        return target
    }

    /// **A restored copy is its own book** (#92, Denver's ruling): a fresh
    /// `ProjectManifest.id` in the copy's manifest AND its shadow, so its
    /// backups go to their own folder (and are pruned on their own count) and
    /// the phone, which keys captures and recents on the id, never confuses the
    /// two. Nothing in the signed op log, the register or permits names this id.
    ///
    /// Never fails a restore over identity. A manifest this build can't decode
    /// (too new, or damaged in the generation) is left exactly as it was; where
    /// only the shadow decodes, the shadow alone takes the new id, and the
    /// copy's first open repairs the manifest from it.
    static func renewIdentity(in target: URL) {
        let manifestURL = target.appendingPathComponent(ProjectManifest.fileName)
        if let data = try? Data(contentsOf: manifestURL),  // adr-0018-ok: restored copy's manifest JSON, not manuscript
           var manifest = try? ProjectManifest.decodeGuardingSchema(data) {
            manifest.id = ULID.generate()
            guard let fresh = try? ProjectManifest.encodeForDisk(manifest),
                  (try? fresh.write(to: manifestURL, options: .atomic)) != nil else { return }
            try? ManifestShadow.write(fresh, in: target)
            return
        }
        if let shadow = ManifestShadow.recover(in: target),
           var manifest = try? ProjectManifest.decodeGuardingSchema(shadow) {
            manifest.id = ULID.generate()
            if let fresh = try? ProjectManifest.encodeForDisk(manifest) {
                try? ManifestShadow.write(fresh, in: target)
            }
        }
    }
}
