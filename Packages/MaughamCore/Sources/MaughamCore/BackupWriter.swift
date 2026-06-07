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
}
