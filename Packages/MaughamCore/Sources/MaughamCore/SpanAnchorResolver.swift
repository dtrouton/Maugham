import Foundation

/// Stateless re-find of a SpanAnchor within a paragraph's *display* text.
/// Recomputed on every derive/render; never persisted-and-mutated.
public enum SpanAnchorResolver {
    /// Returns a grapheme-offset range into `text`, or nil if the span is lost (stale).
    public static func resolve(anchor: SpanAnchor, in text: String) -> Range<Int>? {
        guard !anchor.quote.isEmpty else { return nil } // empty == paragraph-level

        let chars = Array(text)
        let nText = SpanText.normalize(text)
        let nChars = Array(nText)
        let nQuote = Array(SpanText.normalize(anchor.quote))
        guard !nQuote.isEmpty else { return nil }

        // Tier 1: exact (normalized) occurrences.
        let occ = occurrences(of: nQuote, in: nChars)
        if !occ.isEmpty {
            let best = disambiguate(occ, anchor: anchor, normalized: nChars)
            return mapNormalizedRangeToRaw(best, normalized: nChars, raw: chars, text: text, nText: nText, quote: anchor.quote)
        }
        return nil // Tier 2 (fuzzy) added in Task 4.
    }

    static func occurrences(of needle: [Character], in hay: [Character]) -> [Range<Int>] {
        guard needle.count <= hay.count, !needle.isEmpty else { return [] }
        var result: [Range<Int>] = []
        for start in 0...(hay.count - needle.count) {
            if Array(hay[start..<start+needle.count]) == needle {
                result.append(start..<start+needle.count)
            }
        }
        return result
    }

    /// Pick the occurrence whose surrounding context best matches prefix/suffix,
    /// breaking ties by proximity to posHint.
    static func disambiguate(_ occ: [Range<Int>], anchor: SpanAnchor, normalized: [Character]) -> Range<Int> {
        if occ.count == 1 { return occ[0] }
        let nPrefix = Array(SpanText.normalize(anchor.prefix))
        let nSuffix = Array(SpanText.normalize(anchor.suffix))
        func contextScore(_ r: Range<Int>) -> Int {
            var s = 0
            var i = r.lowerBound - 1, j = nPrefix.count - 1
            while i >= 0 && j >= 0 && normalized[i] == nPrefix[j] { s += 1; i -= 1; j -= 1 }
            var k = r.upperBound, m = 0
            while k < normalized.count && m < nSuffix.count && normalized[k] == nSuffix[m] { s += 1; k += 1; m += 1 }
            return s
        }
        return occ.max(by: { a, b in
            let sa = contextScore(a), sb = contextScore(b)
            if sa != sb { return sa < sb }
            return abs(a.lowerBound - anchor.posHint) > abs(b.lowerBound - anchor.posHint)
        })!
    }

    /// Map a range found in normalized space back to raw grapheme offsets.
    static func mapNormalizedRangeToRaw(_ r: Range<Int>, normalized: [Character], raw: [Character], text: String, nText: String, quote: String) -> Range<Int>? {
        if normalized.count == raw.count { return r }
        let rawQuote = Array(quote)
        let rawOcc = occurrences(of: rawQuote, in: raw)
        guard let nearest = rawOcc.min(by: { abs($0.lowerBound - r.lowerBound) < abs($1.lowerBound - r.lowerBound) }) else {
            return nil
        }
        return nearest
    }
}
