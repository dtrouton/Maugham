// Maugham/Editor/RenderFilter.swift
import Foundation
import MaughamCore

/// Translates between the on-disk markdown (with `<!-- ¶id -->` comments)
/// and the display form (comments hidden). On every editor save we round-
/// trip: parse the prior stored form to know existing IDs, then reattach
/// IDs to the display-edited paragraphs by positional + shingle match.
public enum RenderFilter {
    /// Minimum char-bigram overlap for the third (bigram-fallback) tier to
    /// consider reusing a stored id. (T16 fallback for sub-k-word paragraphs.)
    static let bigramReuseThreshold = 0.6

    /// The best bigram candidate must beat the SECOND-best by at least this
    /// margin before its id is reused — the margin-over-second-best rule that
    /// guards against ambiguous near-duplicate ties (e.g. "Yes." / "Yes?" both
    /// tying a survivor "Yes!" at 0.667). 0.1 ≈ one differing character on a
    /// 5-char string (e.g. "Yes!"→"Yes." flips ~1 of ~3 shared bigrams ⇒ a 0.33
    /// gap, comfortably clearing 0.1) while a genuine tie has gap 0.0 < 0.1 ⇒
    /// mint fresh. Bigram overlaps are coarse-grained on short strings, so the
    /// margin only has to separate "exact tie / near-tie" (mint fresh) from "one
    /// candidate is clearly closer" (reuse) — 0.1 sits well below the smallest
    /// real one-character separation yet above floating-point tie noise.
    static let bigramReuseMargin = 0.1

    /// Strip the manuscript's display anchors (own-line `<!-- ¶id -->`
    /// paragraph anchors + inline `<!--t-XXXXXX-->` task anchors). Delegates to
    /// the shared `MarkdownDisplayFilter` — the single source of truth used by
    /// both this editor and the iOS reader. Kept as a thin forwarder so the
    /// existing editor call sites (Document.displayText etc.) are unchanged.
    public static func stripComments(_ stored: String) -> String {
        MarkdownDisplayFilter.stripAnchors(stored)
    }

    /// Strip inline task anchors from arbitrary text. Forwards to the shared
    /// filter; the save-time `restore…` helpers below rely on it.
    internal static func stripTaskAnchorsInline(_ s: String) -> String {
        MarkdownDisplayFilter.stripTaskAnchorsInline(s)
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
            // Strip task anchors from the prior text before pairing.
            // The displayed text comes in anchor-stripped (the editor
            // surface never carries `<!--t-XXXX-->` in displayText), so
            // comparing raw-anchored prior against anchor-free displayed
            // would push paragraph-pairing into the char-bigram fallback
            // for any anchored paragraph. Symmetric strip → exact-match
            // works again; the anchor itself is re-injected later by
            // `TaskAnchorAlignment`.
            if let id = p.id {
                unmatchedById[id] = stripTaskAnchorsInline(p.text)
            }
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
            //
            // Reuse the best-matching id ONLY when it both clears the 0.6
            // threshold AND beats the second-best candidate by a margin. On a
            // zero- (or sub-) margin tie among 2+ candidates the match is
            // *ambiguous* — the survivor could be inheriting the DELETED
            // sibling's id rather than its own (e.g. dialogue "Yes." / "Yes?"
            // with a survivor "Yes!" that ties both at 0.667). Reattaching one
            // arbitrarily records `prior`/`next` against the wrong identity =
            // silent corruption, so we mint fresh instead. A *single*
            // high-overlap candidate has no competitor, so it is reused (a
            // lightly-edited short paragraph keeps its id — the common minor-edit
            // case, e.g. "First." → "First, edited.").
            let ranked = unmatchedById
                .map { (id: $0.key, score: ShingleMatcher.bigramOverlap(d.text, $0.value)) }
                .sorted { $0.score > $1.score }
            if let best = ranked.first, best.score >= bigramReuseThreshold {
                let secondScore = ranked.count > 1 ? ranked[1].score : 0.0
                if best.score - secondScore >= bigramReuseMargin {
                    pairs.append((best.id, d.text))
                    unmatchedById.removeValue(forKey: best.id)
                    continue
                }
                // Ambiguous within-margin tie → fall through and mint fresh.
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

    // MARK: - Task anchor restore (single-paragraph, Pass 1 of V2 alignment)

    /// Per-paragraph task-anchor restore. Given the prior (anchored) content
    /// of a paragraph and the new displayed (anchor-stripped) content, produce
    /// the new stored form with anchors re-attached.
    ///
    /// Algorithm — single-paragraph Pass 1 of the V2 alignment:
    /// 1. Split both inputs by `\n` into lines.
    /// 2. Pass 1a — body-match (greedy first-match): pair displayed lines
    ///    with unclaimed prior lines whose anchor-stripped body matches
    ///    exactly. Catches reorder and unchanged-body cases.
    /// 3. Pass 1b — LCS over the remaining unclaimed lines: classic
    ///    longest-common-subsequence alignment. Catches body-edit / rename
    ///    where line position is roughly stable.
    /// 4. For each paired (displayed, prior) line: reinject the anchor from
    ///    the prior line at the equivalent position in the displayed line.
    /// 5. Unpaired displayed lines stay as-is (anchor minted later by the
    ///    deriver). Unpaired prior lines are dropped — Task 5's multi-
    ///    paragraph orchestration is responsible for emitting `.taskArchive`.
    ///
    /// `prior` and `displayed` are single paragraph contents — no
    /// `\n\n` paragraph separators. Internally we split by `\n` for
    /// line-level alignment. Cross-paragraph correlation lives in Task 5.
    public static func restoreTaskAnchors(
        prior: String, displayed: String
    ) -> String {
        let priorLines = prior.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let displayedLines = displayed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return restoreLineByLine(priorLines: priorLines, displayedLines: displayedLines)
            .joined(separator: "\n")
    }

    /// Internal Pass 1 alignment over line arrays. Exposed for the
    /// multi-paragraph orchestration in Task 5.
    internal static func restoreLineByLine(
        priorLines: [String], displayedLines: [String]
    ) -> [String] {
        let priorStripped: [String] = priorLines.map(stripTaskAnchorsInline)
        let (pairing, _) = computePass1Pairing(
            priorStripped: priorStripped,
            displayedLines: displayedLines,
            priorCount: priorLines.count)

        // -- Re-inject anchors from paired prior lines. --
        var out: [String] = []
        out.reserveCapacity(displayedLines.count)
        for i in 0..<displayedLines.count {
            let dLine = displayedLines[i]
            let j = pairing[i]
            if j == -1 {
                out.append(dLine)
                continue
            }
            let pLine = priorLines[j]
            guard let (anchorId, positionHint) = extractAnchor(from: pLine) else {
                // Prior had no anchor — displayed line stays anchorless.
                out.append(dLine)
                continue
            }
            out.append(reinjectAnchor(into: dLine, anchorId: anchorId, hint: positionHint))
        }
        return out
    }

    /// Core Pass 1 pairing algorithm shared by `restoreLineByLine` and
    /// `TaskAnchorAlignment`.
    ///
    /// Returns `(pairing, claimedPrior)` where:
    /// - `pairing[i] == j` means `displayedLines[i]` paired with prior
    ///   line `j`, or -1 if unpaired.
    /// - `claimedPrior[j] == true` once prior line `j` has been paired.
    ///
    /// Pass 1a: body-match (greedy first-match) — pairs displayed lines with
    /// unclaimed prior lines whose anchor-stripped body matches exactly.
    /// Pass 1b: positional zip over remaining unclaimed lines — handles
    /// renames where line position is roughly stable.
    internal static func computePass1Pairing(
        priorStripped: [String],
        displayedLines: [String],
        priorCount: Int
    ) -> (pairing: [Int], claimedPrior: [Bool]) {
        var claimedPrior = [Bool](repeating: false, count: priorCount)
        var pairing = [Int](repeating: -1, count: displayedLines.count)

        // -- Pass 1a: body-match (greedy first-match). --
        for i in 0..<displayedLines.count {
            for j in 0..<priorCount where !claimedPrior[j] {
                if priorStripped[j] == displayedLines[i] {
                    pairing[i] = j
                    claimedPrior[j] = true
                    break
                }
            }
        }

        // -- Pass 1b: positional zip over unclaimed lines. --
        // Walk both unclaimed lists in parallel; pair up to the shorter
        // length. This handles renames where line position is preserved.
        let unclaimedDisplayed: [Int] = (0..<displayedLines.count).filter { pairing[$0] == -1 }
        let unclaimedPrior: [Int] = (0..<priorCount).filter { !claimedPrior[$0] }
        let n = min(unclaimedDisplayed.count, unclaimedPrior.count)
        for k in 0..<n {
            let i = unclaimedDisplayed[k]
            let j = unclaimedPrior[k]
            pairing[i] = j
            claimedPrior[j] = true
        }

        return (pairing, claimedPrior)
    }

    /// Position hint for re-injection. `.afterCloseBrackets` for
    /// `[[todo:…]]<!--t-X-->` inline form; `.endOfLine` for
    /// `- [ ] foo <!--t-X-->` markdown checkbox form.
    internal enum AnchorPositionHint {
        case endOfLine
        case afterCloseBrackets(remainderAfter: String)
    }

    /// Extract the first task anchor's id + position hint from a prior line.
    /// Returns nil when the line has no anchor.
    internal static func extractAnchor(
        from line: String
    ) -> (anchorId: String, hint: AnchorPositionHint)? {
        let ns = line as NSString
        // The task-anchor grammar lives once, in the shared MarkdownDisplayFilter.
        guard let (matchRange, anchorId) = MarkdownDisplayFilter.firstTaskAnchor(in: line)
        else { return nil }

        // What's immediately before the matched range? If "]]" the anchor was
        // inline-after-brackets; otherwise the anchor was at end-of-line.
        let priorChunk = ns.substring(with: NSRange(location: 0, length: matchRange.location))
        let afterMatch = ns.substring(
            with: NSRange(
                location: matchRange.location + matchRange.length,
                length: ns.length - (matchRange.location + matchRange.length)))

        if priorChunk.hasSuffix("]]") {
            return (anchorId, .afterCloseBrackets(remainderAfter: afterMatch))
        } else {
            return (anchorId, .endOfLine)
        }
    }

    /// Re-attach an anchor to a displayed line. The hint tells us whether to
    /// place it after the first `]]` (inline-fountain form) or at end-of-line.
    internal static func reinjectAnchor(
        into displayedLine: String, anchorId: String, hint: AnchorPositionHint
    ) -> String {
        let comment = TaskAnchorID.formatComment(anchorId)
        switch hint {
        case .endOfLine:
            return "\(displayedLine) \(comment)"
        case .afterCloseBrackets:
            // Find the first `]]` in the displayed line and insert the
            // anchor immediately after it (no separating space). If `]]`
            // is absent (e.g. the user removed the bracket markup), fall
            // back to end-of-line so the anchor isn't lost.
            if let bracketRange = displayedLine.range(of: "]]") {
                var result = displayedLine
                result.insert(contentsOf: comment, at: bracketRange.upperBound)
                return result
            }
            return "\(displayedLine) \(comment)"
        }
    }
}
