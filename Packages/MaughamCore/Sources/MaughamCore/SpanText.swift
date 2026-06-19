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

    /// Like `normalize`, but also returns, for every normalized grapheme, the
    /// index of the SOURCE (raw) grapheme it originated from. This lets a caller
    /// map a range found in normalized space back to an exact raw range even when
    /// normalization changes length (ellipsis `…`→`...`, whitespace-run collapse).
    ///
    /// Contract: `normalized` is byte-for-byte equal to `Array(normalize(s))`
    /// (the substitutions here never emit or consume whitespace, so interleaving
    /// them with whitespace collapse is equivalent to `normalize`'s substitute-
    /// then-split order), and `rawIndexForNormalized` has the same count. Each
    /// entry is a valid index into `Array(s)`. A multi-character expansion
    /// (`…`→`...`) points every emitted normalized char at the single source
    /// index. A collapsed interior whitespace run emits one space pointing at the
    /// run's FIRST raw character.
    public static func normalizeWithMap(_ s: String) -> (normalized: [Character], rawIndexForNormalized: [Int]) {
        let raw = Array(s)
        var norm: [Character] = []
        var map: [Int] = []
        var pendingWhitespace = false      // a whitespace run is open
        var whitespaceRunStart = 0         // raw index of that run's first char
        var sawNonWhitespace = false       // for leading-whitespace trim

        func flushWhitespace() {
            guard pendingWhitespace else { return }
            // Only emit an interior separator space (leading run is trimmed;
            // trailing run is dropped because nothing follows it).
            if sawNonWhitespace {
                norm.append(" ")
                map.append(whitespaceRunStart)
            }
            pendingWhitespace = false
        }

        for (i, ch) in raw.enumerated() {
            if ch.isWhitespace {
                if !pendingWhitespace {
                    pendingWhitespace = true
                    whitespaceRunStart = i
                }
                continue
            }
            // Non-whitespace: close any open whitespace run as a single space.
            flushWhitespace()
            sawNonWhitespace = true

            // Apply the same character substitutions as `normalize`.
            switch ch {
            case "\u{2018}", "\u{2019}":
                norm.append("'"); map.append(i)
            case "\u{201C}", "\u{201D}":
                norm.append("\""); map.append(i)
            case "\u{2014}", "\u{2013}":
                norm.append("-"); map.append(i)
            case "\u{2026}":
                norm.append("."); map.append(i)
                norm.append("."); map.append(i)
                norm.append("."); map.append(i)
            default:
                norm.append(ch); map.append(i)
            }
        }
        // A trailing whitespace run is dropped (matches split/join), so no flush.
        return (norm, map)
    }
}
