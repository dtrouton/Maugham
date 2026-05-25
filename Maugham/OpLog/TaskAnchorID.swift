import Foundation

public enum TaskAnchorID {
    /// Alphabet chosen to skip homoglyphs (no `i`, `l`, `o`, `u`) so anchors
    /// remain visually distinguishable in raw .md inspection. Matches
    /// ParagraphID's alphabet.
    private static let alphabet: [Character] = Array(
        "0123456789abcdefghjkmnpqrstvwxyz")

    /// Mint a fresh 6-char anchor id. 32^6 = ~1B combinations; birthday
    /// collision risk becomes meaningful only past ~30K anchors per doc.
    public static func mint() -> String {
        String((0..<6).map { _ in alphabet.randomElement()! })
    }

    /// Parse `<!--t-XXXXXX-->` (exact form, no surrounding chars) and return
    /// the inner 6-char id. Returns nil for any non-matching input.
    public static func parseComment(_ s: String) -> String? {
        let pattern = #"^<!--t-([0123456789abcdefghjkmnpqrstvwxyz]{6})-->$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: s,
                  range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range(at: 1), in: s) else { return nil }
        return String(s[range])
    }

    public static func formatComment(_ id: String) -> String {
        "<!--t-\(id)-->"
    }
}
