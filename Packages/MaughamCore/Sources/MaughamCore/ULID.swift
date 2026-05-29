import Foundation
import Security

/// Pure-Swift ULID (Universally Unique Lexicographically Sortable Identifier).
/// 26 chars, Crockford base32. First 10 chars encode the unix-millis timestamp
/// (sortable); last 16 chars encode 80 bits of randomness.
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let alphabetIndex: [Character: Int] = {
        var d = [Character: Int]()
        for (i, c) in alphabet.enumerated() { d[c] = i }
        return d
    }()

    public static func generate() -> String {
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        let timePart = encode(millis, length: 10)
        var randomBytes = [UInt8](repeating: 0, count: 10)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let randomPart = encodeBytes(randomBytes, length: 16)
        return timePart + randomPart
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
