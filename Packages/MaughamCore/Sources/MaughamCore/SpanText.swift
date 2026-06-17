import Foundation

/// Canonicalization for span matching. Smart-typography-insensitive and
/// whitespace-insensitive, so a span captured pre-curl still matches post-curl.
public enum SpanText {
    public static func normalize(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\u{2018}", with: "'")
                 .replacingOccurrences(of: "\u{2019}", with: "'")
                 .replacingOccurrences(of: "\u{201C}", with: "\"")
                 .replacingOccurrences(of: "\u{201D}", with: "\"")
        out = out.replacingOccurrences(of: "\u{2014}", with: "-")
                 .replacingOccurrences(of: "\u{2013}", with: "-")
        out = out.replacingOccurrences(of: "\u{2026}", with: "...")
        let collapsed = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed
    }
}
