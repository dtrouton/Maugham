import Foundation
import CommonCrypto

/// Stable, deterministic identifier for a project, derived from its on-disk path.
/// Survives window-title renames; breaks if the folder is moved on disk
/// (acceptable since the user re-opens the moved project in Maugham anyway).
public enum ProjectIdentifier {
    public static func id(for url: URL) -> String {
        let canonical = url.resolvingSymlinksInPath().path
        let data = Data(canonical.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "proj_" + hex
    }
}
