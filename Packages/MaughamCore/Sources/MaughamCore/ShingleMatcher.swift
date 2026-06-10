// Maugham/OpLog/ShingleMatcher.swift
import Foundation

public enum ShingleMatcher {
    public struct Match: Equatable {
        public let id: String
        public let score: Double
    }

    /// Overlap coefficient between two strings using k-word shingles.
    /// Computes |A∩B| / min(|A|,|B|) — intentionally not Jaccard (|A∩B|/|A∪B|)
    /// because overlap is more useful for asymmetric orphan recovery where one
    /// string may be a strict prefix/suffix of the other.
    public static func overlapCoefficient(_ a: String, _ b: String, k: Int) -> Double {
        overlapCoefficient(shingles(of: a, k: k), shingles(of: b, k: k))
    }

    /// Overlap coefficient over PRECOMPUTED shingle sets. The pure-set core of
    /// `overlapCoefficient(_:_:k:)`, exposed so callers that already hold (or
    /// cache) the shingle sets can skip recomputing them. Byte-for-byte the same
    /// arithmetic as the string overload — only the set construction is hoisted
    /// out to the caller.
    public static func overlapCoefficient(_ sa: Set<String>, _ sb: Set<String>) -> Double {
        if sa.isEmpty && sb.isEmpty { return 1.0 }
        if sa.isEmpty || sb.isEmpty { return 0.0 }
        let inter = sa.intersection(sb).count
        let minCount = min(sa.count, sb.count)
        return Double(inter) / Double(minCount)
    }

    /// Find the best-matching candidate above threshold.
    public static func bestMatch(
        needle: String, candidates: [String: String],
        k: Int, threshold: Double
    ) -> Match? {
        bestMatch(
            needle: needle, candidates: candidates, k: k, threshold: threshold,
            candidateShingles: { shingles(of: $0, k: k) })
    }

    /// Best-match overload that resolves each candidate's shingle SET through a
    /// caller-supplied closure — letting the caller MEMOIZE candidate sets across
    /// calls (the candidate texts are stable across keystrokes; only the needle
    /// changes). The needle's set is always computed fresh here (its text just
    /// changed). Selection is byte-for-byte identical to the string overload:
    /// same overlap arithmetic, same `score > best.score` strict-greater tie rule
    /// (first-encountered wins on an exact tie — Dictionary iteration order, as
    /// before), same `>= threshold` gate. `candidateShingles(text)` MUST return
    /// exactly `shingles(of: text, k: k)` for the contract to hold; the cache is
    /// a pure memo of that function.
    public static func bestMatch(
        needle: String, candidates: [String: String],
        k: Int, threshold: Double,
        candidateShingles: (String) -> Set<String>
    ) -> Match? {
        let needleSet = shingles(of: needle, k: k)
        var best: Match? = nil
        for (id, text) in candidates {
            let score = overlapCoefficient(needleSet, candidateShingles(text))
            if score >= threshold {
                if let b = best {
                    if score > b.score { best = Match(id: id, score: score) }
                } else {
                    best = Match(id: id, score: score)
                }
            }
        }
        return best
    }

    /// Character-bigram overlap. Used as a fallback when word-shingle
    /// matching fails for very short texts (< 4 words). Returns a value in
    /// 0...1 indicating how many character bigrams overlap.
    public static func bigramOverlap(_ a: String, _ b: String) -> Double {
        bigramOverlap(bigrams(of: a), bigrams(of: b))
    }

    /// Bigram overlap over PRECOMPUTED bigram sets — the pure-set core of
    /// `bigramOverlap(_:_:)`, exposed so the caller can cache the (stable)
    /// candidate side. Identical arithmetic to the string overload.
    public static func bigramOverlap(_ bigramsA: Set<String>, _ bigramsB: Set<String>) -> Double {
        if bigramsA.isEmpty && bigramsB.isEmpty { return 1.0 }
        if bigramsA.isEmpty || bigramsB.isEmpty { return 0.0 }
        let inter = bigramsA.intersection(bigramsB).count
        let minSize = min(bigramsA.count, bigramsB.count)
        return Double(inter) / Double(minSize)
    }

    /// k-word shingle set of `text`. A pure function of `(text, k)` — exposed
    /// (was private) so a caller can MEMOIZE candidate sets keyed by text. The
    /// matcher itself stays cache-free; ownership of any cache lives outside
    /// MaughamCore (see `RenderFilter.ShingleSetCache`).
    public static func shingles(of text: String, k: Int) -> Set<String> {
        let words = text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard words.count >= k else { return Set(words.isEmpty ? [] : [words.joined(separator: " ")]) }
        var s = Set<String>()
        for i in 0...(words.count - k) {
            s.insert(words[i..<i+k].joined(separator: " "))
        }
        return s
    }

    /// Character-bigram set of `text`. A pure function of `text` — exposed (was
    /// private) so callers can memoize candidate sets keyed by text.
    public static func bigrams(of text: String) -> Set<String> {
        let lower = text.lowercased()
        let chars = Array(lower)
        guard chars.count >= 2 else { return chars.isEmpty ? [] : [lower] }
        var s = Set<String>()
        for i in 0..<(chars.count - 1) {
            s.insert(String(chars[i...i+1]))
        }
        return s
    }
}
