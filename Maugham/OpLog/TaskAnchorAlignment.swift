import Foundation

/// V2 task-anchor alignment for `Document.setFullText`. Re-injects task
/// anchors per paragraph (Pass 1 — body-match + LCS via `RenderFilter`),
/// then runs a cross-paragraph correlation pass (Pass 2 — cursor-biased
/// cut/paste detection), and finalizes by reporting anchors that couldn't
/// be paired (Pass 3 — Document emits `.taskArchive` ops for these).
///
/// See `docs/superpowers/specs/2026-05-25-task-anchors-and-lifecycle.md`
/// §2.4.1 for the algorithm. Pure projection — no observable surfaces, no
/// I/O. Inputs come from `setFullText`'s parse of the displayed/anchored
/// text.
enum TaskAnchorAlignment {

    /// Result of an alignment pass. `restoredById` maps the new paragraph
    /// id to its task-anchor-restored text (suitable for writing back to
    /// `paragraphs[id]`). `archivedAnchors` lists anchor ids that
    /// disappeared in the edit and which should fire `.taskArchive` ops.
    struct Result {
        let restoredById: [String: String]
        let archivedAnchors: [Archived]

        struct Archived {
            /// The prior paragraph id the anchor was attached to.
            let paragraphId: String
            let anchorId: String
        }
    }

    /// Per-paragraph alignment state captured during Pass 1 and consumed
    /// by Pass 2 / Pass 3.
    private struct ParaState {
        let pid: String
        let priorLines: [String]
        let displayedLines: [String]
        /// pairing[i] == j means displayedLines[i] paired with
        /// priorLines[j], or -1 if unpaired.
        var pairing: [Int]
        /// claimedPrior[j] == true once priorLines[j] has been paired.
        var claimedPrior: [Bool]
    }

    /// Anchored payload for a prior line that didn't get paired in Pass 1.
    /// Used by Pass 2 to attempt cross-paragraph correlation against
    /// unpaired-new lines (orphans).
    private struct UnpairedPrior {
        let pid: String
        let priorLineIndex: Int
        /// Anchor-stripped body of the prior line.
        let body: String
        let anchorId: String
        let hint: RenderFilter.AnchorPositionHint
    }

    /// Unanchored line in a new paragraph that didn't pair in Pass 1.
    /// Used by Pass 2 to attempt cross-paragraph correlation against
    /// unpaired-prior anchored lines.
    private struct UnpairedNew {
        let pid: String
        let displayedLineIndex: Int
        let body: String
    }

    static func align(
        priorById: [String: String],
        nextParagraphs: [(id: String, text: String)],
        priorSequence: [String],
        nextSequence: [String],
        preEditCursor: Int?,
        postEditCursor: Int?
    ) -> Result {

        // -- Pass 1: per-paragraph body-match + LCS. --
        var paraStates: [ParaState] = []
        paraStates.reserveCapacity(nextParagraphs.count)

        for (pid, displayed) in nextParagraphs {
            let prior = priorById[pid] ?? ""
            let priorLines = prior.split(
                separator: "\n", omittingEmptySubsequences: false
            ).map(String.init)
            let displayedLines = displayed.split(
                separator: "\n", omittingEmptySubsequences: false
            ).map(String.init)

            // Strip anchors from prior for body comparison, then delegate
            // Pass 1a (body-match) + Pass 1b (positional zip) to the
            // shared helper in RenderFilter — the single implementation that
            // is also property-tested by RenderFilterTaskAnchorTests.
            let priorStripped = priorLines.map(RenderFilter.stripTaskAnchorsInline)
            let (pairing, claimedPrior) = RenderFilter.computePass1Pairing(
                priorStripped: priorStripped,
                displayedLines: displayedLines,
                priorCount: priorLines.count)

            paraStates.append(ParaState(
                pid: pid,
                priorLines: priorLines,
                displayedLines: displayedLines,
                pairing: pairing,
                claimedPrior: claimedPrior))
        }

        // -- Pass 2: cross-paragraph correlation (cursor-biased). --
        // Surviving paragraphs only contribute their unpaired-prior lines
        // here. Paragraphs that disappeared entirely from `nextSequence`
        // (i.e., the writer deleted a whole paragraph) need their own
        // unpaired-prior collection — those don't appear in `paraStates`
        // because Pass 1 walks `nextParagraphs`.
        var unpairedPriors: [UnpairedPrior] = []
        var unpairedNews: [UnpairedNew] = []

        for state in paraStates {
            for i in 0..<state.displayedLines.count where state.pairing[i] == -1 {
                // Only treat as "unpaired-new" if the line contains a task
                // marker — empty lines or non-task prose shouldn't be
                // candidates for anchor inheritance.
                let displayed = state.displayedLines[i]
                if lineCarriesTaskMarker(displayed) {
                    unpairedNews.append(UnpairedNew(
                        pid: state.pid,
                        displayedLineIndex: i,
                        body: displayed))
                }
            }
            for j in 0..<state.priorLines.count where !state.claimedPrior[j] {
                let priorLine = state.priorLines[j]
                guard let (anchorId, hint) = RenderFilter.extractAnchor(
                    from: priorLine) else { continue }
                let body = RenderFilter.stripTaskAnchorsInline(priorLine)
                unpairedPriors.append(UnpairedPrior(
                    pid: state.pid,
                    priorLineIndex: j,
                    body: body,
                    anchorId: anchorId,
                    hint: hint))
            }
        }

        // Paragraphs that vanished entirely between prior and next:
        // their every anchored line is an unpaired-prior candidate for
        // cross-paragraph correlation (the line might have been moved to
        // another paragraph) before falling through to archive.
        let nextIds = Set(nextSequence)
        let vanishedPids = priorSequence.filter { !nextIds.contains($0) }
        for pid in vanishedPids {
            guard let priorText = priorById[pid] else { continue }
            let priorLines = priorText.split(
                separator: "\n", omittingEmptySubsequences: false
            ).map(String.init)
            for (idx, line) in priorLines.enumerated() {
                guard let (anchorId, hint) = RenderFilter.extractAnchor(
                    from: line) else { continue }
                let body = RenderFilter.stripTaskAnchorsInline(line)
                unpairedPriors.append(UnpairedPrior(
                    pid: pid,
                    priorLineIndex: idx,
                    body: body,
                    anchorId: anchorId,
                    hint: hint))
            }
        }

        // Resolve cursor → source/destination paragraph for cursor-bias.
        let sourcePid = cursorParagraph(
            offset: preEditCursor,
            sequence: priorSequence,
            paragraphsById: priorById)
        let destPid = cursorParagraph(
            offset: postEditCursor,
            sequence: nextSequence,
            paragraphsById: Dictionary(uniqueKeysWithValues:
                nextParagraphs.map { ($0.id, $0.text) }))

        // Pairing: for each unpaired-new line, look for unpaired-prior
        // lines with the same body. If exactly one match exists AND the
        // cursor delta is consistent with the move, pair them. If
        // multiple, prefer the one whose source paragraph matches
        // sourcePid. Otherwise leave unpaired.
        //
        // Only attempt Pass 2 when BOTH cursors are available. nil cursor
        // info degrades to per-paragraph behavior (spec §2.4.3).
        var crossMoves: [(newIdx: Int, priorIdx: Int)] = []
        if preEditCursor != nil && postEditCursor != nil {
            var claimedPriorIdxs = Set<Int>()
            for (newIdx, orphan) in unpairedNews.enumerated() {
                let candidates = unpairedPriors.enumerated()
                    .filter { entry in
                        !claimedPriorIdxs.contains(entry.offset)
                            && entry.element.body == orphan.body
                    }
                // Refine candidates by cursor bias.
                let chosen: Int?
                if candidates.count == 1 {
                    let entry = candidates[0]
                    let prior = entry.element
                    // Validate cursor delta: prior pid must equal sourcePid
                    // OR sourcePid is nil (treat as "any source acceptable"
                    // only when source is unknown). Destination pid must
                    // equal orphan.pid OR destPid == nil.
                    if cursorConsistent(
                        priorPid: prior.pid, destPid: destPid,
                        orphanPid: orphan.pid, sourcePid: sourcePid)
                    {
                        chosen = entry.offset
                    } else {
                        chosen = nil
                    }
                } else if candidates.count > 1 {
                    // Disambiguate: prefer the candidate whose source
                    // paragraph matches the pre-edit cursor's paragraph.
                    let prefer = candidates.first(where: { entry in
                        entry.element.pid == sourcePid && orphan.pid == destPid
                    })
                    chosen = prefer?.offset
                } else {
                    chosen = nil
                }
                if let pIdx = chosen {
                    crossMoves.append((newIdx: newIdx, priorIdx: pIdx))
                    claimedPriorIdxs.insert(pIdx)
                }
            }
        }

        // Apply the cross-paragraph moves: for each (newIdx, priorIdx),
        // re-attach the prior anchor to the new line, and remove the
        // prior from `unpairedPriors` (so it doesn't become an archive).
        // We need to mutate the per-paragraph state map for the new line.
        var statesByPid: [String: ParaState] = Dictionary(
            uniqueKeysWithValues: paraStates.map { ($0.pid, $0) })
        var carriedAnchors: [String: [(lineIdx: Int, anchorId: String, hint: RenderFilter.AnchorPositionHint)]] = [:]
        let claimedPriorSet = Set(crossMoves.map(\.priorIdx))
        for move in crossMoves {
            let orphan = unpairedNews[move.newIdx]
            let prior = unpairedPriors[move.priorIdx]
            carriedAnchors[orphan.pid, default: []].append(
                (lineIdx: orphan.displayedLineIndex,
                 anchorId: prior.anchorId,
                 hint: prior.hint))
        }
        let trulyArchived = unpairedPriors.enumerated()
            .filter { !claimedPriorSet.contains($0.offset) }
            .map(\.element)

        // -- Render restoredById per paragraph. --
        var restoredById: [String: String] = [:]
        for (pid, displayed) in nextParagraphs {
            guard let state = statesByPid[pid] else {
                restoredById[pid] = displayed
                continue
            }
            var lines = state.displayedLines
            // Apply Pass 1 pairings.
            for i in 0..<lines.count {
                let j = state.pairing[i]
                if j == -1 { continue }
                let priorLine = state.priorLines[j]
                guard let (anchorId, hint) = RenderFilter.extractAnchor(
                    from: priorLine) else { continue }
                lines[i] = RenderFilter.reinjectAnchor(
                    into: lines[i], anchorId: anchorId, hint: hint)
            }
            // Apply Pass 2 cross-paragraph carries.
            if let carries = carriedAnchors[pid] {
                for c in carries where c.lineIdx >= 0 && c.lineIdx < lines.count {
                    lines[c.lineIdx] = RenderFilter.reinjectAnchor(
                        into: lines[c.lineIdx],
                        anchorId: c.anchorId, hint: c.hint)
                }
            }
            restoredById[pid] = lines.joined(separator: "\n")
        }

        // -- Pass 3: report archives. --
        let archives = trulyArchived.map {
            Result.Archived(paragraphId: $0.pid, anchorId: $0.anchorId)
        }

        return Result(
            restoredById: restoredById,
            archivedAnchors: archives)
    }

    // MARK: - Cursor helpers

    /// Compute which paragraph id (if any) contains the given doc-wide
    /// UTF-16 offset in the joined `paragraphs[id]` text under the given
    /// sequence. Mirrors `Document.paragraphId(at:)` but operates on the
    /// pure inputs the aligner has — no `Document` reference needed.
    private static func cursorParagraph(
        offset: Int?,
        sequence: [String],
        paragraphsById: [String: String]
    ) -> String? {
        guard let offset else { return nil }
        var running = 0
        for id in sequence {
            guard let text = paragraphsById[id] else { continue }
            let len = (text as NSString).length
            if offset <= running + len {
                return id
            }
            running += len + 2  // "\n\n" separator
        }
        return sequence.last
    }

    /// Whether the cross-paragraph move is consistent with the recorded
    /// cursor positions. The aligner treats a move as valid when (a) the
    /// pre-edit cursor was in the prior paragraph that lost the line, and
    /// (b) the post-edit cursor is in the new paragraph that gained it.
    /// Either nil cursor means "treat that constraint as unknown" — but
    /// the call site already gates Pass 2 on both being non-nil, so this
    /// helper is invoked only when we have concrete answers.
    private static func cursorConsistent(
        priorPid: String, destPid: String?,
        orphanPid: String, sourcePid: String?
    ) -> Bool {
        // Within-paragraph moves shouldn't reach here (Pass 1 handles
        // them), but defensive: same-paragraph is always consistent.
        if priorPid == orphanPid { return true }
        // Source consistency: pre-edit cursor in the prior paragraph.
        if let sourcePid, sourcePid != priorPid { return false }
        // Destination consistency: post-edit cursor in the new paragraph.
        if let destPid, destPid != orphanPid { return false }
        return true
    }

    /// Whether a line text plausibly contains a task marker (markdown
    /// checkbox or Fountain `[[todo:…]]` / `[[done:…]]`). Cheap substring
    /// test; the aligner uses this to avoid treating arbitrary prose as a
    /// move-target during Pass 2.
    private static func lineCarriesTaskMarker(_ line: String) -> Bool {
        return line.contains("- [ ]") || line.contains("- [x]")
            || line.contains("[[todo:") || line.contains("[[done:")
    }
}
