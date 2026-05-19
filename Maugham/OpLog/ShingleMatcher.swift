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
        let sa = shingles(of: a, k: k)
        let sb = shingles(of: b, k: k)
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
        var best: Match? = nil
        for (id, text) in candidates {
            let score = overlapCoefficient(needle, text, k: k)
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
        let bigramsA = bigrams(of: a)
        let bigramsB = bigrams(of: b)
        if bigramsA.isEmpty && bigramsB.isEmpty { return 1.0 }
        if bigramsA.isEmpty || bigramsB.isEmpty { return 0.0 }
        let inter = bigramsA.intersection(bigramsB).count
        let minSize = min(bigramsA.count, bigramsB.count)
        return Double(inter) / Double(minSize)
    }

    private static func shingles(of text: String, k: Int) -> Set<String> {
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

    private static func bigrams(of text: String) -> Set<String> {
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
