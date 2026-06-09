import Foundation

/// Process-launch-stable string hashing for on-disk id and filename construction.
///
/// `String.hashValue` / `Hasher` are seed-randomised per process (SE-0206 /
/// Swift stdlib since 5.0), which means they MUST NOT be used to derive any
/// on-disk identifier: a doc-id, an op-log filename, an inbox shard — anything
/// that must survive across app launches. Use `StableHash.fnv1a64Hex` for those.
///
/// `DeviceSlug` uses the 32-bit variant (8-char hex) internally; the suffix is
/// appended to a human-readable slug prefix so 32 bits is fine there. For doc-id
/// fallbacks — where the only discriminator between two documents is the hash
/// itself — 64 bits is safer: a 32-bit collision merges two docs' op logs
/// silently, whereas a 64-bit collision (1-in-4×10¹⁸ per pair) is negligible.
public enum StableHash {

    // MARK: - Public API

    /// Deterministic 16-char hex hash of `s` using FNV-1a 64-bit.
    ///
    /// Cross-launch stable: the same string always produces the same hex string,
    /// regardless of which process, architecture, or Swift version runs the code.
    ///
    /// Use this for any on-disk id or filename component derived from a string.
    /// Do NOT use `String.hashValue` for such purposes — it is randomised per
    /// process and will orphan op logs on every app restart.
    public static func fnv1a64Hex(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - Package-internal 32-bit variant (used by DeviceSlug)

    /// Deterministic 8-char hex hash of `s` using FNV-1a 32-bit.
    ///
    /// Same cross-launch guarantee as `fnv1a64Hex`. Prefer the 64-bit variant
    /// for doc-id construction; this exists so `DeviceSlug` can delegate here
    /// rather than carry its own private copy.
    static func fnv1a32Hex(_ s: String) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(format: "%08x", hash)
    }
}
