import Foundation

/// Parses Fountain inline emphasis into `ProjectAST.Inline` runs. Fountain's
/// emphasis set differs from markdown: `_x_` is UNDERLINE (not italic) and
/// `***x***` is bold-italic. Mirrors the editor's `FountainInlineSpan`
/// semantics (italic / bold / underline) so published output matches what the
/// app displays. Recursive-descent with fallback-to-literal and backslash
/// escaping (`\*`, `\_`, `\\`).
public enum FountainInline {

    public static func parse(_ text: String) -> [ProjectAST.Inline] {
        let chars = Array(text)
        return parse(chars, 0, chars.count)
    }

    private static func parse(_ c: [Character], _ lo: Int, _ hi: Int) -> [ProjectAST.Inline] {
        var out: [ProjectAST.Inline] = []
        var text = ""
        var i = lo

        func flush() {
            if !text.isEmpty { out.append(.text(text)); text = "" }
        }

        while i < hi {
            let ch = c[i]

            // Backslash escape: \* \_ \\ → literal next char.
            if ch == "\\", i + 1 < hi, "*_\\".contains(c[i + 1]) {
                text.append(c[i + 1]); i += 2; continue
            }

            // Bold-italic ***…*** (checked before ** and *).
            if starRun(c, i, hi) >= 3 {
                if let close = findSeq(["*", "*", "*"], c, i + 3, hi) {
                    flush()
                    out.append(.strong([.emphasis(parse(c, i + 3, close))]))
                    i = close + 3
                    continue
                }
                text.append(ch); i += 1; continue
            }

            // Bold **…**.
            if starRun(c, i, hi) == 2 {
                if let close = findSeq(["*", "*"], c, i + 2, hi) {
                    flush()
                    out.append(.strong(parse(c, i + 2, close)))
                    i = close + 2
                    continue
                }
                text.append(ch); i += 1; continue
            }

            // Italic *…* — close is a lone star; runs of ** / *** are skipped.
            if ch == "*" {
                if let close = findItalicClose(c, i + 1, hi) {
                    flush()
                    out.append(.emphasis(parse(c, i + 1, close)))
                    i = close + 1
                    continue
                }
                text.append(ch); i += 1; continue
            }

            // Underline _…_.
            if ch == "_" {
                if let close = findChar("_", c, i + 1, hi) {
                    flush()
                    out.append(.underline(parse(c, i + 1, close)))
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

    // MARK: - helpers

    /// Length of the run of `*` starting at `i`.
    private static func starRun(_ c: [Character], _ i: Int, _ hi: Int) -> Int {
        var j = i
        while j < hi, c[j] == "*" { j += 1 }
        return j - i
    }

    private static func findChar(_ target: Character, _ c: [Character],
                                 _ from: Int, _ hi: Int) -> Int? {
        var i = from
        while i < hi {
            if c[i] == target { return i }
            i += 1
        }
        return nil
    }

    /// Find a lone `*` (a star run of length 1). Runs of 2+ stars belong to a
    /// nested bold / bold-italic span and are skipped whole.
    private static func findItalicClose(_ c: [Character], _ from: Int, _ hi: Int) -> Int? {
        var i = from
        while i < hi {
            if c[i] == "*" {
                let run = starRun(c, i, hi)
                if run == 1 { return i }
                i += run
            } else {
                i += 1
            }
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
}
