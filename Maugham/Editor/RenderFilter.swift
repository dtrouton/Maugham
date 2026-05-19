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
            if let m = unmatchedById.max(by: {
                ShingleMatcher.bigramOverlap(d.text, $0.value)
                    < ShingleMatcher.bigramOverlap(d.text, $1.value)
            }), ShingleMatcher.bigramOverlap(d.text, m.value) >= 0.6 {
                pairs.append((m.key, d.text))
                unmatchedById.removeValue(forKey: m.key)
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

}
