// Maugham/Editor/RenderFilter.swift
import Foundation

/// Translates between the on-disk markdown (with `<!-- ¶id -->` comments)
/// and the display form (comments hidden). On every editor save we round-
/// trip: parse the prior stored form to know existing IDs, then reattach
/// IDs to the display-edited paragraphs by positional + shingle match.
public enum RenderFilter {
    /// Strip only `<!-- ¶id -->` comment lines. Other HTML comments are kept.
    /// Removing a comment line collapses the surrounding blank that separated
    /// it from its paragraph; otherwise stripping `<!-- ¶id -->\n\nFirst.` would
    /// leave a leading blank that becomes a double-blank between paragraphs.
    public static func stripComments(_ stored: String) -> String {
        let lines = stored.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var out: [String] = []
        var skipNextBlank = false
        for line in lines {
            let s = String(line)
            if ParagraphID.parseComment(s) != nil {
                // Drop this line and also any single blank that immediately follows,
                // which was the separator between the comment and its paragraph.
                skipNextBlank = true
                continue
            }
            if skipNextBlank {
                skipNextBlank = false
                if s.trimmingCharacters(in: .whitespaces).isEmpty {
                    continue
                }
            }
            out.append(s)
        }
        return out.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Given the on-disk stored form and the edited display form, produce a
    /// new stored form with IDs reattached. Strategy:
    ///   1. Parse stored to get [(id, text)] ordered.
    ///   2. Parse displayEdited to get [text] ordered.
    ///   3. Walk display order; for each:
    ///      a. exact text match against unmatched stored → reuse id
    ///      b. shingle best-match above 0.6 against unmatched stored → reuse id
    ///         (k=4 word-shingles; falls back to character-bigrams when either
    ///         side has fewer than 4 words — necessary because short paragraphs
    ///         like "First." vs "First, edited." otherwise score 0)
    ///      c. otherwise mint a new id
    ///
    /// "Unmatched stored" = stored paragraphs whose id has not yet been claimed
    /// by an earlier display paragraph in this pass. Each stored id can only
    /// be reused once. This is what makes "insert a middle paragraph" produce
    /// a fresh id for the inserted one rather than stealing an existing id by
    /// shingle match.
    public static func restoreComments(
        stored: String, displayEdited: String
    ) -> String {
        let storedParsed = ParagraphParser.parse(stored)
        let displayParsed = ParagraphParser.parse(displayEdited)

        var unmatchedById: [String: String] = [:]
        for p in storedParsed {
            if let id = p.id { unmatchedById[id] = p.text }
        }

        var pairs: [(String, String)] = []
        for d in displayParsed {
            // Exact match first.
            if let id = unmatchedById.first(where: { $0.value == d.text })?.key {
                pairs.append((id, d.text))
                unmatchedById.removeValue(forKey: id)
                continue
            }
            // Word-shingle match (good for prose-length paragraphs).
            if let m = ShingleMatcher.bestMatch(
                needle: d.text, candidates: unmatchedById,
                k: 4, threshold: 0.6) {
                pairs.append((m.id, d.text))
                unmatchedById.removeValue(forKey: m.id)
                continue
            }
            // Character-bigram fallback for short paragraphs (< k words on
            // either side) where word-shingles collapse to whole-string equality
            // and so can only match exactly.
            if let id = bestCharShingleMatch(needle: d.text, candidates: unmatchedById) {
                pairs.append((id, d.text))
                unmatchedById.removeValue(forKey: id)
                continue
            }
            // Mint fresh.
            pairs.append((ParagraphID.mint(), d.text))
        }

        var paragraphs: [String: String] = [:]
        var sequence: [String] = []
        for (id, text) in pairs {
            paragraphs[id] = text
            sequence.append(id)
        }
        return Materializer.materialize(paragraphs: paragraphs, sequence: sequence)
    }

    // MARK: - Character-bigram fallback

    private static func bestCharShingleMatch(
        needle: String, candidates: [String: String]
    ) -> String? {
        let needleShingles = charBigrams(needle)
        guard !needleShingles.isEmpty else { return nil }
        var best: (id: String, score: Double)? = nil
        for (id, text) in candidates {
            let cand = charBigrams(text)
            if cand.isEmpty { continue }
            let inter = needleShingles.intersection(cand).count
            let denom = min(needleShingles.count, cand.count)
            let score = Double(inter) / Double(denom)
            if score >= 0.6 {
                if let b = best {
                    if score > b.score { best = (id, score) }
                } else {
                    best = (id, score)
                }
            }
        }
        return best?.id
    }

    private static func charBigrams(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        // Strip whitespace runs to single spaces for stability.
        let normalized = lowered.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let chars = Array(normalized)
        guard chars.count >= 2 else {
            return chars.isEmpty ? [] : [String(chars)]
        }
        var out = Set<String>()
        for i in 0..<(chars.count - 1) {
            out.insert(String(chars[i...i+1]))
        }
        return out
    }
}
