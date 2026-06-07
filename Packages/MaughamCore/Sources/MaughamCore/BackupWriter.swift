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
        guard let en = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [], errorHandler: nil) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var result: [String] = []
        for case let url as URL in en {
            let vals = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard vals.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            result.append(String(full.dropFirst(rootPath.count + 1)))
        }
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

            // Atomic commit.
            try? fm.removeItem(at: final)
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
}
