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

    /// Mint an id GUARANTEED absent from `used`. Plain `mint()` is 4 random
    /// chars over a ~1.05M space — at manuscript scale collisions are LIKELY,
    /// not rare: minting ~650 paste paragraphs into a ~1,300-paragraph doc
    /// has ≈60% odds of colliding with an existing id (birthday bound), which
    /// is exactly how the 2026-06-10 paste crash happened (duplicate ids fed
    /// `Dictionary(uniqueKeysWithValues:)` downstream — and a collision that
    /// misses the trap silently merges two paragraphs under one identity in
    /// the op log). EVERY mint site that introduces an id into an existing
    /// population MUST use this, seeding `used` with that population and
    /// inserting each result before the next call.
    ///
    /// Termination: documents hold hundreds-to-thousands of paragraphs
    /// against a 1,048,576-id space, so the expected retry count is ~1.001.
    public static func mintUnique(excluding used: Set<String>) -> String {
        var id = mint()
        while used.contains(id) { id = mint() }
        return id
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
