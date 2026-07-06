import Foundation
import MaughamCore

/// Parses Fountain inline emphasis into `ProjectAST.Inline` runs. A thin adapter
/// over the shared `InlineEmphasisScanner` (via `EmphasisRunConverter`).
/// Fountain's one divergence from prose is `_x_` = UNDERLINE (not italic), so it
/// pre-extracts `_…_` spans as protected `.underline` nodes — whose inner text
/// runs through the converter too, preserving nested emphasis — then delegates
/// asterisks and backslash escapes to the converter with NO strikethrough
/// option (`~` is a lyric marker in Fountain, so tildes stay literal).
public enum FountainInline {

    public static func parse(_ text: String) -> [ProjectAST.Inline] {
        let ns = text as NSString
        return EmphasisRunConverter.inlines(for: text,
                                            options: [],
                                            protected: underlineSpans(ns))
    }

    // MARK: - underline pre-extraction

    private static let backslash: unichar  = 92   // \
    private static let underscore: unichar = 95   // _
    // Chars a backslash can neutralize — mirrors the scanner's escapable set so
    // escape accounting agrees: an escaped `_` is not an underline delimiter.
    private static let escapable: Set<unichar> = [42, 126, 95, 96, 92] // * ~ _ ` \

    private static func underlineSpans(_ ns: NSString) -> [ProtectedSpan] {
        let n = ns.length
        var spans: [ProtectedSpan] = []
        var i = 0
        while i < n {
            let ch = ns.character(at: i)

            // Skip an escape pair so the following char isn't read as a delimiter.
            if ch == backslash, i + 1 < n, escapable.contains(ns.character(at: i + 1)) {
                i += 2
                continue
            }

            if ch == underscore, let close = findUnescapedUnderscore(ns, i + 1, n) {
                let innerRange = NSRange(location: i + 1, length: close - i - 1)
                let inner = EmphasisRunConverter.inlines(for: ns.substring(with: innerRange),
                                                         options: [],
                                                         protected: [])
                spans.append(ProtectedSpan(range: NSRange(location: i, length: close + 1 - i),
                                           node: .underline(inner)))
                i = close + 1
                continue
            }

            i += 1
        }
        return spans
    }

    /// Next `_` that is not backslash-escaped, skipping over escape pairs.
    private static func findUnescapedUnderscore(_ ns: NSString, _ from: Int, _ n: Int) -> Int? {
        var i = from
        while i < n {
            let ch = ns.character(at: i)
            if ch == backslash, i + 1 < n, escapable.contains(ns.character(at: i + 1)) {
                i += 2
                continue
            }
            if ch == underscore { return i }
            i += 1
        }
        return nil
    }
}
