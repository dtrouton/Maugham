import Foundation

/// Parses a single block of prose text into a tree of `ProjectAST.Inline`
/// runs. Targets the markdown subset Maugham writers actually use — emphasis,
/// strong, inline code, wiki links, and hard line breaks — not full
/// CommonMark. Recursive-descent with fallback-to-literal: an opening
/// delimiter with no matching close degrades to plain text rather than
/// swallowing the rest of the paragraph.
public enum InlineParser {

    public static func parse(_ text: String) -> [ProjectAST.Inline] {
        let chars = Array(text)
        return parse(chars, 0, chars.count)
    }

    /// Parse `chars[lo..<hi]` into inline runs.
    private static func parse(_ c: [Character], _ lo: Int, _ hi: Int) -> [ProjectAST.Inline] {
        var out: [ProjectAST.Inline] = []
        var text = ""
        var i = lo

        func flush() {
            if !text.isEmpty { out.append(.text(text)); text = "" }
        }

        while i < hi {
            let ch = c[i]

            // Hard line break: two spaces followed by a newline.
            if ch == " ", i + 2 < hi, c[i + 1] == " ", c[i + 2] == "\n" {
                flush()
                out.append(.lineBreak)
                i += 3
                continue
            }

            // Inline code — literal content, never recurses.
            if ch == "`" {
                if let close = findChar("`", c, i + 1, hi) {
                    flush()
                    out.append(.code(String(c[(i + 1)..<close])))
                    i = close + 1
                    continue
                }
                text.append(ch); i += 1; continue
            }

            // Wiki link [[target|display]] or [[target]].
            if ch == "[", i + 1 < hi, c[i + 1] == "[" {
                if let close = findSeq(["]", "]"], c, i + 2, hi) {
                    flush()
                    let inner = String(c[(i + 2)..<close])
                    let (target, display) = splitWikiLink(inner)
                    out.append(.wikiLink(target: target, display: display))
                    i = close + 2
                    continue
                }
                text.append(ch); i += 1; continue
            }

            // Strong: **...**
            if ch == "*", i + 1 < hi, c[i + 1] == "*" {
                if let close = findSeq(["*", "*"], c, i + 2, hi) {
                    flush()
                    out.append(.strong(parse(c, i + 2, close)))
                    i = close + 2
                    continue
                }
                text.append(ch); i += 1; continue
            }

            // Emphasis: *...* — the close scan skips over `**` pairs so a
            // single-star emphasis doesn't snap shut on the first star of a
            // nested **strong** run.
            if ch == "*" {
                if let close = findEmphasisClose("*", c, i + 1, hi) {
                    flush()
                    out.append(.emphasis(parse(c, i + 1, close)))
                    i = close + 1
                    continue
                }
                text.append(ch); i += 1; continue
            }

            // Emphasis: _..._
            if ch == "_" {
                if let close = findChar("_", c, i + 1, hi) {
                    flush()
                    out.append(.emphasis(parse(c, i + 1, close)))
                    i = close + 1
                    continue
                }
                text.append(ch); i += 1; continue
            }

            text.append(ch)
            i += 1
        }

        flush()
        return out
    }

    // MARK: - matching helpers

    private static func findChar(_ target: Character, _ c: [Character],
                                 _ from: Int, _ hi: Int) -> Int? {
        var i = from
        while i < hi {
            if c[i] == target { return i }
            i += 1
        }
        return nil
    }

    /// Find a single `target` that is NOT half of a doubled pair (e.g. a lone
    /// `*` that isn't part of `**`). Lets `*em **strong** em*` close correctly.
    private static func findEmphasisClose(_ target: Character, _ c: [Character],
                                          _ from: Int, _ hi: Int) -> Int? {
        var i = from
        while i < hi {
            if c[i] == target {
                if i + 1 < hi, c[i + 1] == target {
                    i += 2   // doubled — part of a strong run, skip both
                    continue
                }
                return i
            }
            i += 1
        }
        return nil
    }

    private static func findSeq(_ seq: [Character], _ c: [Character],
                                _ from: Int, _ hi: Int) -> Int? {
        guard !seq.isEmpty else { return nil }
        var i = from
        while i + seq.count <= hi {
            var match = true
            for k in 0..<seq.count where c[i + k] != seq[k] { match = false; break }
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
