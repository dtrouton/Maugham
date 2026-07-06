import Foundation
import MaughamCore

/// Parses a single block of PROSE text into a tree of `ProjectAST.Inline` runs.
/// A thin adapter over the shared `InlineEmphasisScanner` (via
/// `EmphasisRunConverter`): it pre-extracts the grammar features the scanner
/// doesn't own — inline code, wiki links, and hard line breaks — as protected
/// spans, then lets the scanner resolve all asterisk emphasis and GFM
/// strikethrough. Underscore carries no emphasis in prose (spec ledger: prose
/// publish aligns to the editor's asterisk-only rule).
public enum InlineParser {

    public static func parse(_ text: String) -> [ProjectAST.Inline] {
        EmphasisRunConverter.inlines(for: text,
                                     options: [.strikethrough],
                                     protected: protectedSpans(text as NSString))
    }

    // MARK: - protected-span pre-extraction

    private static let backtick: unichar   = 96   // `
    private static let openBracket: unichar = 91  // [
    private static let closeBracket: unichar = 93 // ]
    private static let space: unichar      = 32
    private static let newline: unichar    = 10
    private static let backslash: unichar  = 92

    /// Mirrors `InlineEmphasisScanner`'s escapable set (`* ~ _ \`` `/`\`).
    /// A backslash before one of these — including another backslash — is an
    /// escape pair the scanner neutralizes on its own; recognizing the pair
    /// here (without protecting it) means we skip past BOTH chars before
    /// asking "is this backslash followed by a newline", so the second `\` of
    /// an escaped `\\` pair can't be misread as opening its own hard break.
    private static let escapableAfterBackslash: Set<unichar> = [42, 126, 95, 96, 92]

    /// Left-to-right scan collecting inline code, wiki links, and hard breaks.
    /// Order at any index is unambiguous (each starts with a distinct char);
    /// unbalanced openers degrade to literal text (left for the converter).
    private static func protectedSpans(_ ns: NSString) -> [ProtectedSpan] {
        let n = ns.length
        var spans: [ProtectedSpan] = []
        var i = 0
        while i < n {
            let ch = ns.character(at: i)

            // Inline code `…` — literal content, first-close match.
            if ch == backtick {
                if let close = findChar(backtick, ns, i + 1, n) {
                    let content = ns.substring(with: NSRange(location: i + 1, length: close - i - 1))
                    spans.append(ProtectedSpan(range: NSRange(location: i, length: close - i + 1),
                                               node: .code(content)))
                    i = close + 1
                    continue
                }
                i += 1
                continue
            }

            // Wiki link [[target|display]] or [[target]].
            if ch == openBracket, i + 1 < n, ns.character(at: i + 1) == openBracket {
                if let close = findSeq([closeBracket, closeBracket], ns, i + 2, n) {
                    let inner = ns.substring(with: NSRange(location: i + 2, length: close - i - 2))
                    let (target, display) = splitWikiLink(inner)
                    spans.append(ProtectedSpan(range: NSRange(location: i, length: close + 2 - i),
                                               node: .wikiLink(target: target, display: display)))
                    i = close + 2
                    continue
                }
                i += 1
                continue
            }

            // Hard line break: two spaces followed by a newline.
            if ch == space, i + 2 < n,
               ns.character(at: i + 1) == space, ns.character(at: i + 2) == newline {
                spans.append(ProtectedSpan(range: NSRange(location: i, length: 3), node: .lineBreak))
                i += 3
                continue
            }

            if ch == backslash {
                // Escape pair takes priority: `\` before an escapable char
                // (including another `\`) is left UNPROTECTED — the scanner's
                // own escape pre-pass renders it — but both chars are skipped
                // here so the second char never reaches the hard-break check
                // below as if it were an unescaped backslash.
                if i + 1 < n, escapableAfterBackslash.contains(ns.character(at: i + 1)) {
                    i += 2
                    continue
                }
                // Hard line break, second spelling: a backslash immediately
                // before a newline. Must be claimed HERE, before
                // `EmphasisRunConverter` masks this span and hands the rest to
                // `InlineEmphasisScanner`'s own escape pre-pass — that
                // pre-pass only neutralizes a backslash before `* ~ _ \``/`\`,
                // so newline (not in that set) would leave the backslash to
                // survive as literal text otherwise.
                if i + 1 < n, ns.character(at: i + 1) == newline {
                    spans.append(ProtectedSpan(range: NSRange(location: i, length: 2), node: .lineBreak))
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            i += 1
        }
        return spans
    }

    // MARK: - matching helpers

    private static func findChar(_ target: unichar, _ ns: NSString,
                                 _ from: Int, _ n: Int) -> Int? {
        var i = from
        while i < n {
            if ns.character(at: i) == target { return i }
            i += 1
        }
        return nil
    }

    private static func findSeq(_ seq: [unichar], _ ns: NSString,
                                _ from: Int, _ n: Int) -> Int? {
        guard !seq.isEmpty else { return nil }
        var i = from
        while i + seq.count <= n {
            var match = true
            for k in 0..<seq.count where ns.character(at: i + k) != seq[k] { match = false; break }
            if match { return i }
            i += 1
        }
        return nil
    }

    /// `target|display` → (target, display); `target` alone → (target, target).
    private static func splitWikiLink(_ inner: String) -> (String, String) {
        if let pipe = inner.firstIndex(of: "|") {
            let target = String(inner[..<pipe])
            let display = String(inner[inner.index(after: pipe)...])
            return (target, display)
        }
        return (inner, inner)
    }
}
