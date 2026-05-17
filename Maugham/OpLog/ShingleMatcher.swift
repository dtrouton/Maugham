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
}
