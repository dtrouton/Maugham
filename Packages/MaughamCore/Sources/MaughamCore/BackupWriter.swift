import Foundation

/// Writes/verifies/prunes immutable, timestamped full-copy backup generations of a
/// project directory. Pure Foundation: `FileManager.copyItem` performs APFS
/// copy-on-write clones automatically on same-volume destinations, so local
/// generations are space-cheap. Generation ids and timestamps are caller-supplied
/// (no wall-clock here) for deterministic behavior and testability.
public enum BackupWriter {
    /// The file name of the per-generation manifest, stored inside the generation
    /// and excluded from its own entries.
    public static let manifestName = ".maugham-backup-manifest.json"

    /// All file relative paths under `root` (recursive, files only — directories and
    /// symlinks excluded), sorted ascending. Paths use "/" separators.
    public static func relativeFilePaths(under root: URL) throws -> [String] {
        let fm = FileManager.default
        // A throwing error handler is essential: with `errorHandler: nil` the
        // enumerator stops SILENTLY on the first traversal error (e.g. an
        // unreadable subdirectory), which would make a backup quietly omit files
        // with no signal. We surface the error instead.
        var enumerationError: Error?
        guard let en = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var result: [String] = []
        for case let url as URL in en {
            let vals = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard vals.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            result.append(String(full.dropFirst(rootPath.count + 1)))
        }
        if let enumerationError { throw enumerationError }
        return result.sorted()
    }

    /// Write a new generation of `source` into `<destination>/<generationId>/`.
    /// Copies into a hidden `.partial-<id>/` first, embeds a verified Merkle
    /// manifest, then atomically renames into place. Throws (and leaves no
    /// generation dir) on copy/verify failure. Returns the `BackupGeneration`.
    @discardableResult
    public static func write(
        source: URL, to destination: URL, generationId: String, at builtAt: Date
    ) throws -> BackupGeneration {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let partial = destination.appendingPathComponent(".partial-\(generationId)")
        let final = destination.appendingPathComponent(generationId)

        // Generations are immutable — refuse to overwrite an existing one (a ULID
        // collision means a caller bug). Fail fast before the expensive copy.
        guard !fm.fileExists(atPath: final.path) else {
            throw BackupError.generationAlreadyExists(id: generationId)
        }

        // Clean any leftovers from a crashed prior run.
        try? fm.removeItem(at: partial)

        do {
            // Copy the whole source tree (APFS CoW clone on same volume).
            try fm.copyItem(at: source, to: partial)

            // Build the manifest from the SOURCE file set (excludes the manifest
            // file, which doesn't exist in source), then write it into the partial.
            let rels = try relativeFilePaths(under: source)
            let manifest = try MerkleBuilder.build(root: source, relativePaths: rels, at: builtAt)
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(
                to: partial.appendingPathComponent(manifestName), options: .atomic)

            // Verify the copied bytes match the manifest before committing.
            let mismatches = MerkleBuilder.verify(manifest: manifest, root: partial)
            guard mismatches.isEmpty else {
                throw BackupError.verificationFailed(mismatchedPaths: mismatches)
            }

            // Atomic commit (final is guaranteed absent — guarded above).
            try fm.moveItem(at: partial, to: final)
            return BackupGeneration(id: generationId, manifest: manifest)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// Committed generation ids under `destination`, sorted ascending (ULID ids sort
    /// chronologically). Ignores hidden entries (`.partial-*`, `.DS_Store`) and files.
    public static func generationIds(at destination: URL) throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { return [] }
        let entries = try fm.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        return entries.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return isDir ? name : nil
        }.sorted()
    }

    /// Keep the newest `keeping` generations under `destination`; remove the rest.
    /// "Newest" = highest-sorting ids (ULID ids sort chronologically). Negative
    /// `keeping` is treated as 0. Returns the removed ids (ascending). Generations are
    /// immutable, so pruning only ever deletes whole old generation directories.
    ///
    /// **Recency is the ordering, but intactness overrides it.** Retention orders by
    /// id while recovery (`BackupRestore.newestIntact`) orders by *what verifies*, and
    /// nothing used to reconcile the two: a recency-only prune deletes an intact
    /// generation in order to keep a corrupt newer one, so the writer's effective
    /// protection is `retention − (corrupt generations retained)` and prune actively
    /// *prefers* the corrupt ones. Model-checked: `BackupRetention_NoCorruptRetainedOverIntact`
    /// (violated by the recency-only rule) against its partner
    /// `BackupRetention_Fixed_NoCorruptRetainedOverIntact` (green with this one) —
    /// same spec, one constant. See `formal/BackupRetention.tla`.
    ///
    /// The rule: fill the retained slots with the newest generations that VERIFY, and
    /// only top up with corrupt ones once the intact ones run out. An intact
    /// generation can then never be deleted to make room for a corrupt one — if any
    /// intact generation is dropped there were more than `keeping` of them, so every
    /// slot is already taken by an intact one.
    ///
    /// Verification is a Merkle pass per generation, so it is done lazily and in the
    /// order that makes the ordinary case cheap: the newest `keeping` are checked
    /// first, and when they all verify the answer is identical to the recency-only
    /// one and nothing older is read at all.
    @discardableResult
    public static func prune(destination: URL, keeping: Int) throws -> [String] {
        let keep = max(0, keeping)
        let ids = try generationIds(at: destination)
        guard ids.count > keep else { return [] }

        var verified: [String: Bool] = [:]
        func isIntact(_ id: String) -> Bool {
            if let known = verified[id] { return known }
            // An unreadable manifest is not "unknown", it is not-intact: the
            // generation cannot be recovered from, which is the only property
            // retention cares about here.
            let intact = ((try? verifyGeneration(id: id, at: destination)) ?? ["<unverifiable>"]).isEmpty
            verified[id] = intact
            return intact
        }

        let byRecency = Array(ids.suffix(keep))
        let keptIds: [String]
        if byRecency.allSatisfy(isIntact) {
            keptIds = byRecency
        } else {
            let intact = ids.filter(isIntact)
            var kept = Array(intact.suffix(keep))
            if kept.count < keep {
                kept += ids.filter { !isIntact($0) }.suffix(keep - kept.count)
            }
            keptIds = kept
        }

        let keptSet = Set(keptIds)
        let toRemove = ids.filter { !keptSet.contains($0) }
        let fm = FileManager.default
        for id in toRemove {
            try fm.removeItem(at: destination.appendingPathComponent(id))
        }
        return toRemove
    }

    /// Verify a committed generation's files against its embedded manifest. Returns
    /// the relative paths that mismatch or are missing (empty == intact). Throws if
    /// the generation or its manifest can't be read.
    public static func verifyGeneration(id: String, at destination: URL) throws -> [String] {
        let genDir = destination.appendingPathComponent(id)
        let manifestURL = genDir.appendingPathComponent(manifestName)
        let manifest = try JSONDecoder().decode(
            MerkleManifest.self, from: Data(contentsOf: manifestURL))  // adr-0018-ok: backup Merkle manifest read, not manuscript
        return MerkleBuilder.verify(manifest: manifest, root: genDir)
    }
}
