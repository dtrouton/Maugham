import Foundation

/// Applies a suggested-change replacement to a paragraph. Shared by the Mac
/// (`Document.acceptAnnotation`) and the phone (`AnnotationWriter.makeAccept`)
/// so the accept op's materialised `next` is computed identically on both
/// surfaces (cross-surface contract).
///
/// The op stores the BARE suggested text (so the review UI shows just the
/// replacement, e.g. `→ furious`, not the whole resulting paragraph). The full
/// paragraph is produced HERE, at accept time, by splicing the bare text into
/// the span — so a one-word suggestion replaces one word, not the paragraph.
/// A paragraph-level suggestion (no span) replaces the whole paragraph, which
/// is what the bare text already is.
public enum SuggestionSplice {

    /// The outcome of attempting to apply `bare` to `paragraph`. There is no
    /// String-returning variant: a lost anchor must be impossible to conflate
    /// with a paragraph-level suggestion at the type level, because the old
    /// `apply` did exactly that — its shared fallback returned the bare
    /// span-sized replacement as the WHOLE paragraph, a measured data-loss
    /// path on the writer's prose (M5-AN-049, RULING-5).
    public enum Outcome: Equatable, Sendable {
        /// The full paragraph text after the suggestion is applied.
        case applied(String)
        /// The suggestion carries a span whose quoted phrase can no longer be
        /// found in the paragraph. RULING-5: it MUST NOT be applied — the
        /// caller refuses, tells the writer why, and they may ask again.
        case anchorLost
    }

    /// Attempt to apply `bare` to `paragraph`.
    ///
    /// - Span-anchored (sub-paragraph): the span is re-resolved against
    ///   `paragraph` at call time and only that range is replaced — robust if the
    ///   paragraph was edited between authoring and accept.
    /// - No span / empty quote: the bare text IS the whole paragraph (the
    ///   Claude/MCP `add_suggested_change` contract).
    /// - Span present but no longer resolvable: `.anchorLost` — never a guess.
    /// - Span resolvable but `bare` detected as whole-paragraph grain (it embeds
    ///   the span's surrounding context): `bare` is used verbatim instead of
    ///   spliced — see `isWholeParagraphGrain`.
    public static func attempt(
        suggestion bare: String, span: SpanAnchor?, to paragraph: String
    ) -> Outcome {
        guard let span, !span.quote.isEmpty else { return .applied(bare) }
        guard let range = SpanAnchorResolver.resolve(anchor: span, in: paragraph)
        else { return .anchorLost }
        let chars = Array(paragraph)
        let prefix = String(chars[..<range.lowerBound])
        let suffix = String(chars[range.upperBound...])
        // Grain salvage: a bare text that already carries the paragraph's
        // surrounding context was authored at whole-paragraph grain (the
        // pre-v2 add_suggested_change contract read that way). Splicing it
        // into the span would duplicate the surroundings — use it verbatim.
        if isWholeParagraphGrain(bare: bare, prefix: prefix, suffix: suffix) {
            return .applied(bare)
        }
        return .applied(prefix + bare + suffix)
    }

    /// Minimum context length (in characters, whitespace-trimmed) for a match
    /// to count as whole-paragraph evidence: required of the single side of a
    /// ONE-SIDED match, and of the COMBINED length of a BOTH-SIDES match.
    /// Guards against coincidences like a suffix of "." matching a
    /// replacement that ends in a period — which would silently delete the
    /// rest of the paragraph.
    static let grainContextMinLength = 12

    /// True when `bare` was authored at whole-paragraph grain: it embeds the
    /// text surrounding the span. Trimmed comparison so a trailing newline or
    /// space difference doesn't defeat detection.
    ///
    /// The both-sides branch ALSO requires the combined trimmed context to
    /// reach `grainContextMinLength`: a false positive deletes the
    /// paragraph's surrounding text (worse than the duplication bug this
    /// salvage fixes), and short both-sides coincidences — prefix "She",
    /// suffix "." on a sentence-shaped span replacement — are common in real
    /// prose. When the floor blocks salvage on a genuinely whole-grain short
    /// paragraph, the damage is bounded small duplication — the safer failure.
    static func isWholeParagraphGrain(
        bare: String, prefix: String, suffix: String
    ) -> Bool {
        let b = bare.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixMatches = !p.isEmpty && b.hasPrefix(p)
        let suffixMatches = !s.isEmpty && b.hasSuffix(s)
        if prefixMatches && suffixMatches,
           p.count + s.count >= grainContextMinLength { return true }
        if prefixMatches && p.count >= grainContextMinLength { return true }
        if suffixMatches && s.count >= grainContextMinLength { return true }
        return false
    }

    /// Reconstruct the `SpanAnchor` an annotation op was created with from its
    /// persisted provenance. Returns nil for a paragraph-level annotation (no
    /// span quote).
    public static func spanAnchor(from provenance: Op.Provenance?) -> SpanAnchor? {
        guard let provenance,
              let quote = provenance.spanQuote, !quote.isEmpty else { return nil }
        return SpanAnchor(
            quote: quote,
            prefix: provenance.spanPrefix ?? "",
            suffix: provenance.spanSuffix ?? "",
            posHint: provenance.spanPosHint ?? 0)
    }

    // MARK: - Accept over applied text (R-B, hardening 11-11 Task 5)

    /// What an Accept of a suggested change writes. Asked by the Mac
    /// (`Document.acceptAnnotation`) and the phone (`AnnotationWriter
    /// .makeAccept`) alike, so both surfaces guard the same way (tripwire 19).
    public enum AcceptPlan: Equatable, Sendable {
        /// Splice: the accept carries `prior` = the live paragraph and `next`.
        case splice(next: String)
        /// The suggestion is already in the text: the accept moves the note's
        /// status and carries no change, so no line ever records a before-text
        /// equal to its after-text and the suggestion is never spliced twice.
        case statusOnly
        /// The span's quote is gone and the splice is not in place: refused
        /// (RULING-5).
        case anchorLost
    }

    /// **Accept is guarded at the root** (ruling R-B). The race: this device
    /// accepts, another device's newer archive or stet wins the status (no
    /// RULING-33 repair runs for those), a Reopen leaves the note open over
    /// its own splice, and a second Accept would record the applied text as
    /// its own "before" — or splice a span suggestion a second time — and
    /// leave Revert unable to reach the original. So:
    ///
    /// 1. If the note's splice is still in place (`isAppliedInPlace`), the
    ///    accept is status-only, even where the span's quote no longer
    ///    resolves (the splice itself replaced it).
    /// 2. If the note's own history says its splice is live (`spliceLive`,
    ///    a fold over its honoured lifecycle lines) and the
    ///    replacement already stands where the span resolves
    ///    (`spanAlreadyApplied`), the accept is status-only: the splice is
    ///    not applied a second time after an edit elsewhere in the paragraph.
    /// 3. Otherwise the span is re-resolved as ever (`attempt`); a computed
    ///    paragraph equal to the live one (the writer typed the suggestion
    ///    themselves) is status-only too, since there is nothing to write.
    public static func planAccept(
        annotationId: String, paragraphId: String, suggestion bare: String,
        span: SpanAnchor?, paragraph current: String, ops: [Op],
        amendments: AnnotationAmendments
    ) -> AcceptPlan {
        if isAppliedInPlace(annotationId: annotationId, paragraphId: paragraphId,
                            paragraph: current, ops: ops) {
            return .statusOnly
        }
        // The span reading is gated on the note's OWN history (fix round 2):
        // without it a brand-new suggestion whose surroundings already read
        // as the replacement ("It was dark, very dark." on the SECOND "dark")
        // would be marked accepted and silently not written.
        if let span, spliceLive(annotationId: annotationId, ops: ops, amendments: amendments),
           spanAlreadyApplied(suggestion: bare, span: span, paragraph: current) {
            return .statusOnly
        }
        switch attempt(suggestion: bare, span: span, to: current) {
        case .anchorLost: return .anchorLost
        case .applied(let next): return next == current ? .statusOnly : .splice(next: next)
        }
    }

    /// True iff the note's splice is in the live paragraph `paragraphId`
    /// though its status may say otherwise: the newest accept that carries
    /// text (`newestAppliedAccept`) is for that paragraph and has the live
    /// paragraph as its `next`. This subsumes the RULING-33 repair's own
    /// detection turned round (the newest text-carrying lifecycle op being
    /// such an accept — it is then also the newest text-carrying accept), and
    /// also covers a restore op, which is not a lifecycle op, putting the
    /// splice back after a Revert (RULING-57's travel). Exact text, as the
    /// repair and `Document.acceptedTextDrifted` compare.
    public static func isAppliedInPlace(
        annotationId: String, paragraphId: String, paragraph: String, ops: [Op]
    ) -> Bool {
        func holds(_ op: Op?) -> Bool {
            guard let change = op?.changes.first, change.paragraphId == paragraphId else {
                return false
            }
            return change.next == paragraph
        }
        return holds(newestAppliedAccept(annotationId: annotationId, in: ops))
    }

    /// **The history gate on the span reading** (fix rounds 2 and 3): is
    /// this note's splice in the text, as far as its own log knows? A fold
    /// over the note's HONOURED lifecycle lines (`AnnotationDeriver
    /// .isHonouredLifecycleOp` under `amendments`) in opId order, starting
    /// not live:
    /// - any `claudeAccept` (text-carrying, or status-only: a travel's
    ///   RULING-26/57 re-accept, an earlier guarded accept) → live;
    /// - a text-carrying `claudeAcceptRevert` or `claudeReject` (the writer's
    ///   Revert, the RULING-33 repair) → not live;
    /// - a status-only `claudeAcceptRevert` or `annotationReopen` that
    ///   Maugham's own travel wrote (`isTravelStatusLine`) → not live: the
    ///   travel moved the text with a restore op, which is not a lifecycle
    ///   line;
    /// - every other line leaves the answer as it was — the writer's own
    ///   status-only Revert of a hand-typed accept (their text still
    ///   stands), a peer's archive, stet or reject, the pane's Reopen (the
    ///   race the guard exists for), and ANY archive, a travel's included
    ///   (fix round 4). A travel's archive means the paragraph is gone, and
    ///   nothing can be accepted while it is; what the gate says once the
    ///   paragraph is back is decided by the line that brings the note back:
    ///   a travel's `claudeAccept` (live), a travel's status-only revert or
    ///   reopen (not live: the return journey to before the accept), or the
    ///   unstamped reopen a rewind's ⌘Z writes for a note that was open
    ///   before the rewind (unchanged, which is right: that ⌘Z restores the
    ///   pre-rewind text).
    /// A note never accepted is never live, so its first Accept splices as
    /// written.
    public static func spliceLive(
        annotationId: String, ops: [Op], amendments: AnnotationAmendments
    ) -> Bool {
        var live = false
        for op in ops.filter({
            $0.provenance?.sourceAnnotationId == annotationId
                && AnnotationDeriver.isHonouredLifecycleOp($0, amendments: amendments)
        }).sorted(by: { $0.opId < $1.opId }) {
            switch op.kind {
            case .claudeAccept:
                live = true
            case .claudeAcceptRevert where !op.changes.isEmpty,
                 .claudeReject where !op.changes.isEmpty:
                live = false
            case .claudeAcceptRevert, .annotationReopen:
                if isTravelStatusLine(op) { live = false }
            default:
                break
            }
        }
        return live
    }

    /// **A status-only line Maugham's own travel wrote**, told by what it
    /// carries, the stamps `RewindImpact.momentEnd`'s `trails` reads: a full
    /// rewind's or its undo's lines are `synthesisSource` `.rewind` /
    /// `.undoRewind` (`Document+Rewind` steps 8, 8b, 9;
    /// `Document+RewindUndo`); a checkpoint revert's are stamped with the
    /// checkpoint (`Restore.travelStatusLines`' `sourceCheckpoint`). No line
    /// the writer's own hand writes carries either. (`spliceLive` asks this
    /// of reverts and reopens only: a travel's archive is neutral there.)
    public static func isTravelStatusLine(_ op: Op) -> Bool {
        guard op.changes.isEmpty else { return false }
        let source = op.provenance?.synthesisSource
        return source == .rewind || source == .undoRewind
            || op.provenance?.sourceCheckpoint != nil
    }

    /// **The span-level reading: the replacement already stands where the
    /// anchor resolves.** True iff the quote occurrence the anchor resolves
    /// to in `paragraph` sits inside an occurrence of the replacement,
    /// aligned so the quote is where it is inside the replacement ("dark" at
    /// offset 5 of "very dark" ⇒ "very dark" must start five characters
    /// before the resolved "dark"). Applying the suggestion there would put
    /// the replacement inside itself ("very very dark"). Only a replacement
    /// that contains its own quote can be found this way; one that does not
    /// is caught by `isAppliedInPlace`, or its anchor is lost.
    ///
    /// It never fires for a replacement standing ELSEWHERE in the paragraph:
    /// "It was dark, very dark." anchored on the first "dark" resolves to the
    /// first "dark", and "was dark," is not "very dark", so it splices.
    public static func spanAlreadyApplied(
        suggestion bare: String, span: SpanAnchor, paragraph: String
    ) -> Bool {
        guard !span.quote.isEmpty,
              let resolved = SpanAnchorResolver.resolve(anchor: span, in: paragraph) else {
            return false
        }
        let p = Array(paragraph), b = Array(bare), q = Array(span.quote)
        guard b.count >= q.count else { return false }
        for k in 0...(b.count - q.count) where Array(b[k..<(k + q.count)]) == q {
            let start = resolved.lowerBound - k
            guard start >= 0, start + b.count <= p.count else { continue }
            if Array(p[start..<(start + b.count)]) == b { return true }
        }
        return false
    }

    /// The newest `claudeAccept` for this note, status-only or not (newest by
    /// opId, so every caller agrees after an out-of-order merge). Its reply is
    /// the one the note shows; whether it carried text decides what its ⌘Z
    /// may do.
    public static func newestAccept(annotationId: String, in ops: [Op]) -> Op? {
        ops.filter {
            $0.kind == .claudeAccept && $0.provenance?.sourceAnnotationId == annotationId
        }.max(by: { $0.opId < $1.opId })
    }

    /// The accept a Revert takes back: the newest `claudeAccept` for this
    /// note that CARRIES a change. A status-only accept (this guard's, or a
    /// rewind's re-accept under RULING-26/57) moved no text, so it has no
    /// pre-accept text to restore; reading it made Revert a silent no-op.
    public static func newestAppliedAccept(annotationId: String, in ops: [Op]) -> Op? {
        ops.filter {
            $0.kind == .claudeAccept
                && $0.provenance?.sourceAnnotationId == annotationId
                && !$0.changes.isEmpty
        }.max(by: { $0.opId < $1.opId })
    }

    /// What Revert writes on an accepted suggestion, one answer for the Mac
    /// (`Document.revertAcceptedAnnotation`) and the phone (`AnnotationWriter
    /// .makeAcceptRevert`).
    public enum RevertPlan: Equatable, Sendable {
        /// Restore this accept's pre-accept text (its `changes.first.prior`).
        case restore(accept: Op)
        /// No accept for the note ever carried text (the writer typed the
        /// suggestion themselves, so every accept was status-only): there is
        /// nothing to restore, and Revert writes a status-only
        /// `claudeAcceptRevert` — the note reopens, the writer's text stays
        /// (RULING-29: a resolution is the writer's to reverse from the
        /// surface that shows it).
        case reopenOnly
    }

    public static func revertPlan(annotationId: String, in ops: [Op]) -> RevertPlan {
        if let accept = newestAppliedAccept(annotationId: annotationId, in: ops) {
            return .restore(accept: accept)
        }
        return .reopenOnly
    }
}
