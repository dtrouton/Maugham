import Foundation

/// Stateless re-find of a SpanAnchor within a paragraph's *display* text.
/// Recomputed on every derive/render; never persisted-and-mutated.
public enum SpanAnchorResolver {
    /// Returns a grapheme-offset range into `text`, or nil if the span is lost (stale).
    public static func resolve(anchor: SpanAnchor, in text: String) -> Range<Int>? {
        guard !anchor.quote.isEmpty else { return nil } // empty == paragraph-level

        let rawCount = text.count
        let (nChars, rawIndexForNormalized) = SpanText.normalizeWithMap(text)
        let nQuote = Array(SpanText.normalize(anchor.quote))
        guard !nQuote.isEmpty else { return nil }

        // Tier 1: exact (normalized) occurrences.
        let occ = occurrences(of: nQuote, in: nChars)
        if !occ.isEmpty {
            let best = disambiguate(occ, anchor: anchor, normalized: nChars)
            return mapNormalizedRangeToRaw(best, map: rawIndexForNormalized, rawCount: rawCount)
        }
        // Tier 2: fuzzy window (lenient). Reuse ShingleMatcher bigram overlap.
        if let fuzzy = fuzzyWindow(quote: nQuote, in: nChars, anchor: anchor) {
            return mapNormalizedRangeToRaw(fuzzy, map: rawIndexForNormalized, rawCount: rawCount)
        }
        return nil
    }

    /// Build an anchor for a selected grapheme range in `text`.
    public static func capture(in text: String, range: Range<Int>, contextLength: Int = 24) -> SpanAnchor {
        let chars = Array(text)
        let lo = max(0, min(range.lowerBound, chars.count))
        let hi = max(lo, min(range.upperBound, chars.count))
        let quote = String(chars[lo..<hi])
        let preLo = max(0, lo - contextLength)
        let sufHi = min(chars.count, hi + contextLength)
        let prefix = String(chars[preLo..<lo])
        let suffix = String(chars[hi..<sufHi])
        return SpanAnchor(quote: quote, prefix: prefix, suffix: suffix, posHint: lo)
    }

    static let fuzzyThreshold = 0.6
    static let fuzzyMargin = 0.1

    static func fuzzyWindow(quote: [Character], in hay: [Character], anchor: SpanAnchor) -> Range<Int>? {
        guard !quote.isEmpty, hay.count >= 2 else { return nil }
        let qBigrams = ShingleMatcher.bigrams(of: String(quote))
        let qLen = quote.count
        let lengths = Set([qLen, max(1, qLen - 1), qLen + 1, max(1, qLen - 2), qLen + 2]).sorted()
        var scored: [(range: Range<Int>, score: Double)] = []
        for len in lengths where len <= hay.count {
            for start in 0...(hay.count - len) {
                let window = String(hay[start..<start+len])
                let score = ShingleMatcher.bigramOverlap(ShingleMatcher.bigrams(of: window), qBigrams)
                scored.append((start..<start+len, score))
            }
        }
        let ranked = scored.sorted { $0.score > $1.score }
        guard let best = ranked.first, best.score >= fuzzyThreshold else { return nil }
        if let runnerUp = ranked.dropFirst().first(where: { !$0.range.overlaps(best.range) }),
           best.score - runnerUp.score < fuzzyMargin {
            let nearBest = ranked.filter { best.score - $0.score < fuzzyMargin }
            return nearBest.min(by: { abs($0.range.lowerBound - anchor.posHint) < abs($1.range.lowerBound - anchor.posHint) })?.range
        }
        return best.range
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
    ///
    /// Context matching is whitespace-tolerant: both the text-side slice and the
    /// stored prefix/suffix are run through `SpanText.normalize` (the SAME
    /// function), so their internal spaces align and a boundary space that
    /// `normalize` trims from the prefix/suffix can no longer defeat the match.
    /// The prefix is scored by the longest common SUFFIX between the normalized
    /// text-before-occurrence and the normalized prefix; the suffix by the
    /// longest common PREFIX between the normalized text-after-occurrence and the
    /// normalized suffix.
    static func disambiguate(_ occ: [Range<Int>], anchor: SpanAnchor, normalized: [Character]) -> Range<Int> {
        if occ.count == 1 { return occ[0] }
        let nPrefix = Array(SpanText.normalize(anchor.prefix))
        let nSuffix = Array(SpanText.normalize(anchor.suffix))
        func longestCommonSuffix(_ a: [Character], _ b: [Character]) -> Int {
            var s = 0, i = a.count - 1, j = b.count - 1
            while i >= 0 && j >= 0 && a[i] == b[j] { s += 1; i -= 1; j -= 1 }
            return s
        }
        func longestCommonPrefix(_ a: [Character], _ b: [Character]) -> Int {
            var s = 0, i = 0, j = 0
            while i < a.count && j < b.count && a[i] == b[j] { s += 1; i += 1; j += 1 }
            return s
        }
        func contextScore(_ r: Range<Int>) -> Int {
            // Re-normalize the boundary slices so collapsed/trimmed whitespace on
            // the stored prefix/suffix aligns with the live text's whitespace.
            // Slice a window at least as long as the stored context (plus slack
            // for whitespace that normalize may collapse) so the full prefix/
            // suffix can match.
            let preWindow = max(nPrefix.count + 2, 1)
            let sufWindow = max(nSuffix.count + 2, 1)
            let beforeLo = max(0, r.lowerBound - preWindow)
            let before = Array(SpanText.normalize(String(normalized[beforeLo..<r.lowerBound])))
            let afterHi = min(normalized.count, r.upperBound + sufWindow)
            let after = Array(SpanText.normalize(String(normalized[r.upperBound..<afterHi])))
            return longestCommonSuffix(before, nPrefix) + longestCommonPrefix(after, nSuffix)
        }
        return occ.max(by: { a, b in
            let sa = contextScore(a), sb = contextScore(b)
            if sa != sb { return sa < sb }
            return abs(a.lowerBound - anchor.posHint) > abs(b.lowerBound - anchor.posHint)
        })!
    }

    /// Map a range found in normalized space back to exact raw grapheme offsets
    /// using the normalized→raw index correspondence from `normalizeWithMap`.
    ///
    /// `map[k]` is the raw index that normalized char `k` came from. The raw
    /// lower bound is `map[r.lowerBound]`. The raw upper bound is one past the
    /// raw source of the LAST included normalized char (`map[r.upperBound - 1]`);
    /// multi-char expansions (`…`→`...`) all share that single raw index, so
    /// `+1` correctly spans the whole source grapheme regardless of where inside
    /// the expansion the range happens to end. Robust to length-changing
    /// normalization — no re-search of the verbatim quote is performed.
    static func mapNormalizedRangeToRaw(_ r: Range<Int>, map: [Int], rawCount: Int) -> Range<Int>? {
        guard !r.isEmpty, r.lowerBound >= 0, r.upperBound <= map.count else { return nil }
        let rawLo = map[r.lowerBound]
        let rawHi = map[r.upperBound - 1] + 1
        guard rawLo >= 0, rawHi <= rawCount, rawLo < rawHi else { return nil }
        return rawLo..<rawHi
    }
}
