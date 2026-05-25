// Maugham/Editor/RenderFilter.swift
import Foundation

/// Translates between the on-disk markdown (with `<!-- ¶id -->` comments)
/// and the display form (comments hidden). On every editor save we round-
/// trip: parse the prior stored form to know existing IDs, then reattach
/// IDs to the display-edited paragraphs by positional + shingle match.
public enum RenderFilter {
    /// Matches an inline task anchor `<!--t-XXXXXX-->` plus an optional single
    /// preceding whitespace char. Consuming the leading whitespace is what
    /// keeps `[[todo: x]]<!--t-X--> rest` collapsing to `[[todo: x]] rest`
    /// (single space, not double) and `- [ ] foo <!--t-X-->` collapsing to
    /// `- [ ] foo` (no trailing space).
    private static let taskAnchorRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"\s?<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->"#)
    }()

    /// Strip `<!-- ¶id -->` comment lines (paragraph anchors) and any inline
    /// `<!--t-XXXXXX-->` task anchors. Other HTML comments are kept.
    /// Removing a paragraph-anchor line collapses the surrounding blank that
    /// separated it from its paragraph; otherwise stripping
    /// `<!-- ¶id -->\n\nFirst.` would leave a leading blank that becomes a
    /// double-blank between paragraphs.
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
        let paragraphStripped = out.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripTaskAnchorsInline(paragraphStripped)
    }

    /// Strip inline task anchors from arbitrary text. Public for the
    /// single-line-aware helpers in `restoreTaskAnchors`.
    internal static func stripTaskAnchorsInline(_ s: String) -> String {
        let ns = s as NSString
        return taskAnchorRegex.stringByReplacingMatches(
            in: s,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "")
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
        // Strip anchors from prior lines for body comparison (keep originals
        // around to extract anchor + position when re-injecting).
        let priorStripped: [String] = priorLines.map(stripTaskAnchorsInline)

        // claimedPrior[j] == true once prior line j has been paired.
        var claimedPrior = [Bool](repeating: false, count: priorLines.count)
        // pairing[i] == j means displayed[i] paired with prior[j], or -1 unpaired.
        var pairing = [Int](repeating: -1, count: displayedLines.count)

        // -- Pass 1a: body-match (greedy first-match). --
        for i in 0..<displayedLines.count {
            for j in 0..<priorLines.count where !claimedPrior[j] {
                if priorStripped[j] == displayedLines[i] {
                    pairing[i] = j
                    claimedPrior[j] = true
                    break
                }
            }
        }

        // -- Pass 1b: LCS over unclaimed lines. --
        let unclaimedDisplayed: [Int] = (0..<displayedLines.count).filter { pairing[$0] == -1 }
        let unclaimedPrior: [Int] = (0..<priorLines.count).filter { !claimedPrior[$0] }

        if !unclaimedDisplayed.isEmpty && !unclaimedPrior.isEmpty {
            // LCS uses positional alignment as the similarity proxy: a line in
            // unclaimedDisplayed at index a pairs with a line in
            // unclaimedPrior at index b if they sit in the LCS. Equality is
            // softened to "either body equal, or both unique in their
            // respective pools" — but for Pass 1 we approximate with positional
            // best-fit: every remaining displayed line pairs with the
            // corresponding remaining prior line if they exist.
            //
            // We use a "match anything that hasn't matched" strategy: walk in
            // order through both unclaimed lists in parallel; pair them up to
            // the shorter length. This handles renames where line position
            // is preserved.
            let n = min(unclaimedDisplayed.count, unclaimedPrior.count)
            for k in 0..<n {
                let i = unclaimedDisplayed[k]
                let j = unclaimedPrior[k]
                pairing[i] = j
                claimedPrior[j] = true
            }
        }

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
        guard let match = taskAnchorRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }

        let matchRange = match.range
        let matched = ns.substring(with: matchRange)
        // Extract the id from the matched substring (which may include a
        // leading whitespace char).
        let idPattern = #"<!--t-([0123456789abcdefghjkmnpqrstvwxyz]{6})-->"#
        // swiftlint:disable:next force_try
        let idRegex = try! NSRegularExpression(pattern: idPattern)
        let matchedNS = matched as NSString
        guard let idMatch = idRegex.firstMatch(
            in: matched, range: NSRange(location: 0, length: matchedNS.length)),
            let r = Range(idMatch.range(at: 1), in: matched)
        else { return nil }
        let anchorId = String(matched[r])

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
