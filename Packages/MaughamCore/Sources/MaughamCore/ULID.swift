import Foundation
import Security

/// Pure-Swift ULID (Universally Unique Lexicographically Sortable Identifier).
/// 26 chars, Crockford base32. First 10 chars encode the unix-millis timestamp
/// (sortable); last 16 chars encode 80 bits of randomness.
///
/// MONOTONIC within the process (ULID spec §"Monotonicity"): two `generate()`
/// calls in the same millisecond increment the previous random part instead of
/// re-rolling it, so generation order == lexicographic order even within one
/// millisecond. This matters because `Deriver.derive` sorts ops by opId for
/// last-write-wins — without monotonicity, two bursts flushed in the same
/// millisecond had a ~50% chance of deriving in reverse order, letting the
/// OLDER paragraph text win (caught by SequenceKeyframingTests T5 flaking on
/// its fresh-reload assertion). Cross-device ordering is unchanged (still
/// timestamp + randomness); this only pins same-process generation order.
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let alphabetIndex: [Character: Int] = {
        var d = [Character: Int]()
        for (i, c) in alphabet.enumerated() { d[c] = i }
        return d
    }()

    /// Monotonicity state, guarded by `stateLock`. `lastMillis == 0` means
    /// "no ULID generated yet this process".
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var lastMillis: UInt64 = 0
    nonisolated(unsafe) private static var lastRandom = [UInt8](repeating: 0, count: 10)

    public static func generate() -> String {
        let nowMillis = UInt64(Date().timeIntervalSince1970 * 1000)

        stateLock.lock()
        defer { stateLock.unlock() }

        var millis = nowMillis
        var randomBytes: [UInt8]
        if nowMillis > lastMillis {
            // New millisecond: fresh randomness.
            randomBytes = [UInt8](repeating: 0, count: 10)
            _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        } else {
            // Same millisecond (or clock stepped backwards — treat identically
            // so process-local monotonicity survives skew): increment the
            // previous 80-bit random part as a big-endian integer.
            millis = lastMillis
            randomBytes = lastRandom
            var i = randomBytes.count - 1
            while i >= 0 {
                if randomBytes[i] == 0xFF {
                    randomBytes[i] = 0
                    i -= 1
                } else {
                    randomBytes[i] += 1
                    break
                }
            }
            if i < 0 {
                // 80-bit overflow (needs 2^80 same-ms calls — effectively
                // unreachable, but don't silently wrap to a SMALLER id):
                // borrow the next millisecond and re-roll.
                millis += 1
                randomBytes = [UInt8](repeating: 0, count: 10)
                _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
            }
        }
        lastMillis = millis
        lastRandom = randomBytes

        return encode(millis, length: 10) + encodeBytes(randomBytes, length: 16)
    }

    public static func timestampMillis(of ulid: String) -> UInt64? {
        guard ulid.count == 26 else { return nil }
        let prefix = String(ulid.prefix(10))
        var value: UInt64 = 0
        for ch in prefix {
            guard let idx = alphabetIndex[ch] else { return nil }
            value = (value << 5) | UInt64(idx)
        }
        return value
    }

    private static func encode(_ value: UInt64, length: Int) -> String {
        var v = value
        var chars = [Character](repeating: "0", count: length)
        for i in stride(from: length - 1, through: 0, by: -1) {
            chars[i] = alphabet[Int(v & 0x1F)]
            v >>= 5
        }
        return String(chars)
    }

    private static func encodeBytes(_ bytes: [UInt8], length: Int) -> String {
        var bits: UInt64 = 0
        var bitsHeld = 0
        var out = ""
        var byteIdx = 0
        while out.count < length {
            if bitsHeld < 5 {
                bits = (bits << 8) | UInt64(byteIdx < bytes.count ? bytes[byteIdx] : 0)
                bitsHeld += 8
                byteIdx += 1
            }
            let shift = bitsHeld - 5
            let chunk = (bits >> UInt64(shift)) & 0x1F
            out.append(alphabet[Int(chunk)])
            bits &= (1 << UInt64(shift)) - 1
            bitsHeld -= 5
        }
        return out
    }
}
