import Foundation

/// A verified shadow copy of `project.maugham.json` under `.maugham/`, so a
/// corrupted or truncated manifest can be recovered **without** a full backup
/// restore. The manifest is a single, critical, un-regenerable file (it carries
/// the minted project id and the whole binder structure) — losing it means "can't
/// open the project." The shadow is written on every manifest save and read back
/// only if the live manifest fails to decode.
///
/// The shadow carries its own SHA-256 sidecar; `recover` returns the shadow only
/// if that checksum still validates, so a corrupt shadow is never trusted over a
/// corrupt original.
public enum ManifestShadow {
    static let shadowName = "manifest.shadow.json"
    static let checksumName = "manifest.shadow.json.sha256"

    private static func dir(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham", isDirectory: true)
    }

    /// Write `manifestData` (the bytes just persisted to `project.maugham.json`) to
    /// the shadow + its checksum. Best-effort — callers ignore failures (a missing
    /// shadow just means no fallback, never a broken save).
    public static func write(_ manifestData: Data, in projectURL: URL) throws {
        let d = dir(in: projectURL)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try manifestData.write(to: d.appendingPathComponent(shadowName), options: .atomic)
        let sha = MerkleBuilder.sha256Hex(manifestData)
        try Data(sha.utf8).write(to: d.appendingPathComponent(checksumName), options: .atomic)
    }

    /// The shadow manifest bytes, but only if the shadow + checksum both exist and
    /// the checksum validates. Returns nil otherwise (no shadow, or a corrupt one).
    public static func recover(in projectURL: URL) -> Data? {
        let d = dir(in: projectURL)
        guard let data = try? Data(contentsOf: d.appendingPathComponent(shadowName)),  // adr-0018-ok: manifest shadow bytes read, not manuscript
              let shaBytes = try? Data(contentsOf: d.appendingPathComponent(checksumName)),  // adr-0018-ok: manifest shadow checksum read, not manuscript
              let sha = String(data: shaBytes, encoding: .utf8) else { return nil }
        return MerkleBuilder.sha256Hex(data) == sha ? data : nil
    }
}
