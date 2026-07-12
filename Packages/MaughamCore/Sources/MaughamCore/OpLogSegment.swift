import Foundation
import CryptoKit

/// Sealed, compressed, checksummed container for a closed op-log segment
/// (ADR 0016 / growth spec §5.1). The payload is the byte-exact JSONL tail
/// content at seal time; the digest is over the UNCOMPRESSED bytes so a
/// verified segment parses with the same JSONL parser as a live tail.
///
/// Layout (little-endian):
///   magic "MZS1" (4) | algorithm (1) | reserved zeros (3)
///   | uncompressedByteCount u64 (8) | sha256 of uncompressed JSONL (32)
///   | compressed payload (…)
///
/// The distinct `.mzseg` extension is deliberate: `.jsonl` recognizers
/// (conflict-twin regex, pending-buffer exclusion) skip segments by
/// construction. Recognition lives ONLY in `OpLogStore`'s single-source
/// helpers — never hand-roll segment filenames (grep tripwires enforce).
public enum OpLogSegment {

    public static let fileExtension = "mzseg"
    static let magic = Data("MZS1".utf8)
    static let headerLength = 4 + 1 + 3 + 8 + 32

    public enum Algorithm: UInt8, Sendable {
        case lzfse = 1
        case lzma = 2

        var nsAlgorithm: NSData.CompressionAlgorithm {
            switch self {
            case .lzfse: return .lzfse
            case .lzma: return .lzma
            }
        }
    }

    public enum SegmentError: Error, Equatable, Sendable {
        case truncatedHeader
        case badMagic
        case unknownAlgorithm(UInt8)
        case compressionFailed
        case decompressionFailed
        case lengthMismatch(expected: UInt64, actual: UInt64)
        case checksumMismatch
        case expectedByteCountTooLarge(UInt64)
    }

    /// Ceiling on the header's claimed uncompressed byte count, checked
    /// BEFORE decompression runs. Real segments seal well under 512 KB
    /// (the growth spec's `segmentSealThreshold`); 64 MB is generous
    /// headroom for a burst of ops landing before the next seal check
    /// while still refusing to let a tampered/corrupt header (e.g. a tiny
    /// compressed payload claiming a multi-GB inflated size — a
    /// decompression-bomb shape) drive `NSData.decompressed` to exhaust
    /// memory. Proportionate corrupt-file robustness, not a security gate.
    static let maxExpectedByteCount: UInt64 = 64 * 1024 * 1024

    /// Decode outcome. `jsonl` carries the decompressed bytes whenever
    /// decompression succeeded — even on checksum mismatch — so callers can
    /// best-effort salvage (parse what decodes) while still quarantining
    /// the failure (spec §5.3). `isVerified == false` ⇒ corruption.
    public struct DecodeResult: Sendable {
        public let jsonl: Data?
        public let failure: SegmentError?
        public var isVerified: Bool { failure == nil }
    }

    /// Encode raw JSONL bytes into a sealed container.
    public static func encode(
        jsonl: Data, algorithm: Algorithm = .lzfse
    ) throws -> Data {
        // NSData.compressed throws on empty input on some OS versions; an
        // empty tail seals to an empty payload deterministically.
        let compressed: Data
        if jsonl.isEmpty {
            compressed = Data()
        } else {
            guard let c = try? (jsonl as NSData).compressed(
                using: algorithm.nsAlgorithm) as Data else {
                throw SegmentError.compressionFailed
            }
            compressed = c
        }
        var out = Data(capacity: headerLength + compressed.count)
        out.append(magic)
        out.append(algorithm.rawValue)
        out.append(contentsOf: [0, 0, 0])
        var count = UInt64(jsonl.count).littleEndian
        withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
        out.append(Data(SHA256.hash(data: jsonl)))
        out.append(compressed)
        return out
    }

    /// Decode + verify. Never throws — corruption is a data condition the
    /// read path must route to quarantine, not a control-flow surprise.
    public static func decodeVerifying(_ container: Data) -> DecodeResult {
        guard container.count >= headerLength else {
            return DecodeResult(jsonl: nil, failure: .truncatedHeader)
        }
        // Re-base: slices keep their parent's indices.
        let bytes = Data(container)
        guard bytes.prefix(4) == magic else {
            return DecodeResult(jsonl: nil, failure: .badMagic)
        }
        guard let algorithm = Algorithm(rawValue: bytes[4]) else {
            return DecodeResult(jsonl: nil, failure: .unknownAlgorithm(bytes[4]))
        }
        let expected = bytes.subdata(in: 8..<16).withUnsafeBytes {
            UInt64(littleEndian: $0.load(as: UInt64.self))
        }
        let storedDigest = bytes.subdata(in: 16..<48)
        let payload = bytes.subdata(in: 48..<bytes.count)

        let jsonl: Data
        if payload.isEmpty {
            // An empty payload can only legitimately decode to empty bytes.
            // expected == 0 → empty round-trip; expected > 0 → the stored
            // length contradicts the (absent) payload: fail closed rather
            // than poke an empty NSData through decompression (whose
            // behavior on empty input is OS-version-dependent).
            guard expected == 0 else {
                return DecodeResult(
                    jsonl: Data(),
                    failure: .lengthMismatch(expected: expected, actual: 0))
            }
            jsonl = Data()
        } else {
            // Pre-check: refuse to inflate a payload whose header claims an
            // unreasonable size, so a lying/corrupt header can't drive
            // decompression itself into an OOM before the post-inflate
            // actual-vs-expected check below ever runs.
            guard expected <= maxExpectedByteCount else {
                return DecodeResult(
                    jsonl: nil, failure: .expectedByteCountTooLarge(expected))
            }
            guard let d = try? (payload as NSData).decompressed(
                using: algorithm.nsAlgorithm) as Data else {
                return DecodeResult(jsonl: nil, failure: .decompressionFailed)
            }
            jsonl = d
        }
        guard UInt64(jsonl.count) == expected else {
            return DecodeResult(
                jsonl: jsonl,
                failure: .lengthMismatch(expected: expected,
                                         actual: UInt64(jsonl.count)))
        }
        guard Data(SHA256.hash(data: jsonl)) == storedDigest else {
            return DecodeResult(jsonl: jsonl, failure: .checksumMismatch)
        }
        return DecodeResult(jsonl: jsonl, failure: nil)
    }
}
