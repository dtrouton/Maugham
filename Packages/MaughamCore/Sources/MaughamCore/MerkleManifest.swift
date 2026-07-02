import Foundation
import CryptoKit

/// A content manifest over a set of files: per-file SHA-256 plus one root hash
/// computed over the sorted entries. Comparing the root verifies the whole set;
/// `verify` localizes which files changed/disappeared. Used both for live
/// "verify project" and as each backup generation's integrity record.
public struct MerkleManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let relativePath: String
        public let sha256: String
        public let byteCount: Int
        public init(relativePath: String, sha256: String, byteCount: Int) {
            self.relativePath = relativePath
            self.sha256 = sha256
            self.byteCount = byteCount
        }
    }
    public let entries: [Entry]   // sorted by relativePath
    public let rootHash: String
    public let builtAt: Date
    public init(entries: [Entry], rootHash: String, builtAt: Date) {
        self.entries = entries
        self.rootHash = rootHash
        self.builtAt = builtAt
    }
}

public enum MerkleBuilder {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Build a manifest by hashing each file at `root/relativePath`. `builtAt` is
    /// injected (no wall-clock in core). Throws if any listed file can't be read.
    public static func build(root: URL, relativePaths: [String], at builtAt: Date) throws -> MerkleManifest {
        var entries: [MerkleManifest.Entry] = []
        for rel in relativePaths.sorted() {
            let data = try Data(contentsOf: root.appendingPathComponent(rel))  // adr-0018-ok: backup file bytes read for checksum, not manuscript-as-truth
            entries.append(.init(relativePath: rel, sha256: sha256Hex(data), byteCount: data.count))
        }
        let rootLines = entries.map { "\($0.relativePath)\t\($0.sha256)" }.joined(separator: "\n")
        return MerkleManifest(entries: entries, rootHash: sha256Hex(Data(rootLines.utf8)), builtAt: builtAt)
    }

    /// Returns the relative paths whose current bytes don't match the manifest
    /// (mismatched hash, or missing/unreadable). Empty == intact.
    public static func verify(manifest: MerkleManifest, root: URL) -> [String] {
        manifest.entries.compactMap { entry in
            guard let data = try? Data(contentsOf: root.appendingPathComponent(entry.relativePath))  // adr-0018-ok: backup file bytes read for checksum, not manuscript-as-truth
            else { return entry.relativePath }
            return sha256Hex(data) == entry.sha256 ? nil : entry.relativePath
        }
    }
}
