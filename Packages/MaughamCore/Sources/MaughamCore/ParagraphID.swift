import Foundation

public enum ParagraphID {
    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

    public static func mint() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        var value = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        value = (value &* 0x5D3A1) &+ UInt32(bitPattern: Int32(bytes[0]))
        var chars = [Character](repeating: "0", count: 4)
        for i in stride(from: 3, through: 0, by: -1) {
            chars[i] = alphabet[Int(value & 0x1F)]
            value >>= 5
        }
        return String(chars)
    }

    public static func formatComment(_ id: String) -> String {
        return "<!-- ¶\(id) -->"
    }

    public static func parseComment(_ line: String) -> String? {
        let pattern = "^<!--\\s*¶([0-9abcdefghjkmnpqrstvwxyz]{4})\\s*-->$"
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let m = regex.firstMatch(in: trimmed, range: range),
              m.numberOfRanges == 2,
              let idRange = Range(m.range(at: 1), in: trimmed) else { return nil }
        return String(trimmed[idRange])
    }
}
