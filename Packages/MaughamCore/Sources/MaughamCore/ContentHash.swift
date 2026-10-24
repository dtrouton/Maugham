import CryptoKit
import Foundation

/// **A file named by its bytes**: the first 16 hex digits of its SHA-256.
/// A figure image's op carries it (`FigureImageRef.contentHash`), both
/// compilers stage the image under it (`build/figures/<hash>.<ext>`,
/// `OEBPS/images/<hash>.<ext>`), and a parked Research copy is compared by
/// it. Shared here so Mac and phone answer alike (tripwire 19). The value is
/// on disk in op logs: the algorithm never changes (`ContentHashTests` pins it).
public enum ContentHash {
    /// The file at `url`, read in 1 MB chunks and never held whole. Throws
    /// when the file can't be read.
    public static func ofFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url) // adr-0018-ok: a figure image or table copy hashed for its name, not manuscript
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
