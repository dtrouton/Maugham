import XCTest
@testable import MaughamCore

final class SuggestionSpliceTests: XCTestCase {

    private func span(_ quote: String, in text: String) -> SpanAnchor {
        let chars = Array(text)
        let lo = String(chars).range(of: quote).map {
            text.distance(from: text.startIndex, to: $0.lowerBound)
        } ?? 0
        return SpanAnchorResolver.capture(in: text, range: lo..<(lo + quote.count))
    }

    /// Sub-paragraph span suggestion: only the span is replaced.
    func test_apply_spliceReplacesOnlyTheSpan() {
        let para = "She was very angry."
        let s = span("very angry", in: para)
        XCTAssertEqual(
            SuggestionSplice.attempt(suggestion: "furious", span: s, to: para),
            .applied("She was furious."))
    }

    /// A one-word span change in a long paragraph leaves the rest intact (the
    /// case that motivated splicing at accept rather than storing the whole
    /// paragraph as the suggestion).
    func test_apply_longParagraph_onlySpanChanges() {
        let para = "The quick brown fox jumped over the lazy sleeping dog by the river."
        let s = span("lazy sleeping", in: para)
        XCTAssertEqual(
            SuggestionSplice.attempt(suggestion: "alert", span: s, to: para),
            .applied("The quick brown fox jumped over the alert dog by the river."))
    }

    /// Paragraph-level suggestion (no span): the bare text is the whole paragraph.
    func test_apply_noSpan_replacesWholeParagraph() {
        XCTAssertEqual(
            SuggestionSplice.attempt(suggestion: "Her jaw clenched.", span: nil,
                                   to: "She was angry."),
            .applied("Her jaw clenched."))
    }

    /// Lost anchor (quote not present): REFUSED (RULING-5, 2026-08-09). The
    /// old whole-paragraph fallback was the M5-AN-049 data-loss path.
    func test_attempt_unresolvableSpan_isRefused() {
        let s = SpanAnchor(quote: "not here", prefix: "", suffix: "", posHint: 0)
        XCTAssertEqual(
            SuggestionSplice.attempt(suggestion: "x", span: s, to: "abc def"),
            .anchorLost)
    }

    /// Provenance round-trip: a span-bearing provenance reconstructs its anchor;
    /// an empty/absent quote yields nil (paragraph-level).
    func test_spanAnchor_fromProvenance() {
        let prov = Op.Provenance(
            sessionId: "s",
            spanQuote: "very angry", spanPrefix: "She was ",
            spanSuffix: ".", spanPosHint: 8)
        let anchor = SuggestionSplice.spanAnchor(from: prov)
        XCTAssertEqual(anchor?.quote, "very angry")
        XCTAssertEqual(anchor?.prefix, "She was ")
        XCTAssertEqual(anchor?.posHint, 8)

        XCTAssertNil(SuggestionSplice.spanAnchor(from: nil))
        let noQuote = Op.Provenance(sessionId: "s")
        XCTAssertNil(SuggestionSplice.spanAnchor(from: noQuote))
    }

    // MARK: - planAccept / newestAppliedAccept (R-B, hardening 11-11 Task 5)

    private func line(_ opId: String, _ kind: OpKind, prior: String? = nil, next: String? = nil) -> Op {
        Op(opId: opId, docId: "doc-0f677d7e", at: Date(timeIntervalSince1970: 0),
           device: "mac", session: "s", kind: kind,
           changes: next.map { [Op.ParagraphChange(paragraphId: "k7m3", prior: prior, next: $0)] } ?? [],
           provenance: Op.Provenance(sessionId: "s", sourceAnnotationId: "01NOTE"))
    }

    func test_planAccept_splicesWhenNothingIsApplied() {
        XCTAssertEqual(
            SuggestionSplice.planAccept(annotationId: "01NOTE", paragraphId: "k7m3", suggestion: "B.", span: nil,
                                        paragraph: "A.", ops: [],
                                        amendments: .honourEverything),
            .splice(next: "B."))
    }

    /// The race: accepted, archived on another device, reopened. The splice is
    /// in the text, so a second accept is status-only — even for a span whose
    /// quote the splice replaced (it would otherwise refuse as anchor lost).
    func test_planAccept_isStatusOnlyWhileTheNotesSpliceIsInPlace() {
        let para = "The night was very dark and cold."
        let s = span("very dark", in: para)
        let applied = "The night was pitch black and cold."
        let ops = [
            line("01A", .claudeAccept, prior: para, next: applied),
            line("01B", .claudeArchive),
            line("01C", .annotationReopen),
        ]
        XCTAssertEqual(SuggestionSplice.attempt(suggestion: "pitch black", span: s, to: applied),
                       .anchorLost, "premise: the quote is gone")
        XCTAssertEqual(
            SuggestionSplice.planAccept(annotationId: "01NOTE", paragraphId: "k7m3", suggestion: "pitch black",
                                        span: s, paragraph: applied, ops: ops,
                                        amendments: .honourEverything),
            .statusOnly)
    }

    /// Not in place: the newest text-carrying line is a revert or a RULING-33
    /// repair, or the writer has typed over the accept's text.
    func test_planAccept_splicesOrRefusesOnceTheSpliceIsNoLongerInPlace() {
        let reverted = [line("01A", .claudeAccept, prior: "A.", next: "B."),
                        line("01B", .claudeAcceptRevert, prior: "B.", next: "A.")]
        XCTAssertEqual(SuggestionSplice.planAccept(annotationId: "01NOTE", paragraphId: "k7m3", suggestion: "B.",
                                                   span: nil, paragraph: "A.", ops: reverted,
                                        amendments: .honourEverything),
                       .splice(next: "B."))
        let repaired = [line("01A", .claudeAccept, prior: "A.", next: "B."),
                        line("01B", .claudeReject, prior: "B.", next: "A.")]
        XCTAssertEqual(SuggestionSplice.planAccept(annotationId: "01NOTE", paragraphId: "k7m3", suggestion: "B.",
                                                   span: nil, paragraph: "A.", ops: repaired,
                                        amendments: .honourEverything),
                       .splice(next: "B."))
        let para = "The night was very dark and cold."
        let s = span("very dark", in: para)
        let accepted = [line("01A", .claudeAccept, prior: para,
                             next: "The night was pitch black and cold.")]
        XCTAssertEqual(SuggestionSplice.planAccept(annotationId: "01NOTE", paragraphId: "k7m3", suggestion: "pitch black",
                                                   span: s, paragraph: "Rain fell.", ops: accepted,
                                        amendments: .honourEverything),
                       .anchorLost, "the writer rewrote it: RULING-5's refusal stands")
    }

    func test_planAccept_isStatusOnlyWhenTheParagraphAlreadyReadsAsTheSuggestion() {
        XCTAssertEqual(
            SuggestionSplice.planAccept(annotationId: "01NOTE", paragraphId: "k7m3", suggestion: "B.", span: nil,
                                        paragraph: "B.", ops: [],
                                        amendments: .honourEverything),
            .statusOnly)
    }

    /// A status-only accept moved no text: Revert reads the newest accept that did.
    func test_newestAppliedAccept_skipsStatusOnlyAccepts_andOtherNotes() {
        let ops = [
            line("01A", .claudeAccept, prior: "A.", next: "B."),
            line("01B", .claudeArchive),
            line("01C", .claudeAccept),
            Op(opId: "01D", docId: "doc-0f677d7e", at: Date(timeIntervalSince1970: 0),
               device: "mac", session: "s", kind: .claudeAccept,
               changes: [Op.ParagraphChange(paragraphId: "k7m3", prior: "x", next: "y")],
               provenance: Op.Provenance(sessionId: "s", sourceAnnotationId: "01OTHER")),
        ]
        XCTAssertEqual(SuggestionSplice.newestAppliedAccept(annotationId: "01NOTE", in: ops)?.opId, "01A")
        XCTAssertNil(SuggestionSplice.newestAppliedAccept(annotationId: "01NOTE", in: [line("01C", .claudeAccept)]))
    }

    // MARK: - Fix round 1: never spliced twice; Revert of a hand-typed accept

    /// A restore op (not a lifecycle op) put the splice back after a Revert:
    /// the newest lifecycle line is the Revert, but the newest accept that
    /// carried text has the live paragraph as its `next`.
    func test_planAccept_readsTheNewestAppliedAcceptToo() {
        let para = "The night was very dark and cold."
        let s = span("very dark", in: para)
        let applied = "The night was pitch black and cold."
        let ops = [
            line("01A", .claudeAccept, prior: para, next: applied),
            line("01B", .claudeAcceptRevert, prior: applied, next: para),
            line("01C", .claudeAccept),
            line("01D", .claudeArchive),
            line("01E", .annotationReopen),
        ]
        XCTAssertEqual(
            SuggestionSplice.planAccept(annotationId: "01NOTE", paragraphId: "k7m3",
                                        suggestion: "pitch black", span: s,
                                        paragraph: applied, ops: ops,
                                        amendments: .honourEverything),
            .statusOnly)
    }

    /// The accept's change names ANOTHER paragraph: not this note's splice.
    func test_isAppliedInPlace_checksTheParagraphId() {
        let ops = [line("01A", .claudeAccept, prior: "A.", next: "B.")]
        XCTAssertTrue(SuggestionSplice.isAppliedInPlace(
            annotationId: "01NOTE", paragraphId: "k7m3", paragraph: "B.", ops: ops))
        XCTAssertFalse(SuggestionSplice.isAppliedInPlace(
            annotationId: "01NOTE", paragraphId: "q2w8", paragraph: "B.", ops: ops))
    }

    /// The span-level reading: the writer edited elsewhere in the paragraph,
    /// so it is no longer the accept's text, but "very dark" still stands
    /// where "dark" resolves — never "very very dark".
    func test_planAccept_isStatusOnlyWhereTheReplacementAlreadyStandsAtTheSpan() {
        let original = "The night was dark and cold."
        let s = span("dark", in: original)
        let edited = "The night was very dark and bitter cold."
        let ops = [line("01A", .claudeAccept, prior: original,
                        next: "The night was very dark and cold.")]
        XCTAssertEqual(SuggestionSplice.attempt(suggestion: "very dark", span: s, to: edited),
                       .applied("The night was very very dark and bitter cold."),
                       "premise: a plain splice would apply it twice")
        XCTAssertTrue(SuggestionSplice.spanAlreadyApplied(suggestion: "very dark", span: s,
                                                          paragraph: edited))
        XCTAssertEqual(
            SuggestionSplice.planAccept(annotationId: "01NOTE", paragraphId: "k7m3",
                                        suggestion: "very dark", span: s,
                                        paragraph: edited, ops: ops,
                                        amendments: .honourEverything),
            .statusOnly)
    }

    /// The negative: the replacement standing ELSEWHERE in the paragraph is
    /// not the suggestion applied.
    func test_spanAlreadyApplied_doesNotFireForTheReplacementElsewhere() {
        let para = "It was dark, very dark."
        let first = SpanAnchorResolver.capture(in: para, range: 7..<11)
        XCTAssertEqual(first.quote, "dark", "premise")
        XCTAssertFalse(SuggestionSplice.spanAlreadyApplied(suggestion: "very dark", span: first,
                                                           paragraph: para))
        XCTAssertEqual(
            SuggestionSplice.planAccept(annotationId: "01NOTE", paragraphId: "k7m3",
                                        suggestion: "very dark", span: first,
                                        paragraph: para, ops: [],
                                        amendments: .honourEverything),
            .splice(next: "It was very dark, very dark."))
        // A replacement that does not contain its quote is never found here.
        XCTAssertFalse(SuggestionSplice.spanAlreadyApplied(
            suggestion: "pitch black", span: span("very dark", in: "was very dark and"),
            paragraph: "was very dark and"))
    }

    func test_revertPlan_restoresTheNewestAppliedAccept_orReopensOnly() {
        let ops = [line("01A", .claudeAccept, prior: "A.", next: "B."), line("01C", .claudeAccept)]
        XCTAssertEqual(SuggestionSplice.revertPlan(annotationId: "01NOTE", in: ops),
                       .restore(accept: ops[0]))
        XCTAssertEqual(SuggestionSplice.revertPlan(annotationId: "01NOTE", in: [line("01C", .claudeAccept)]),
                       .reopenOnly)
    }

    func test_newestAccept_isByOpIdWhateverTheOrderOfTheLog() {
        let ops = [line("01C", .claudeAccept), line("01A", .claudeAccept, prior: "A.", next: "B.")]
        XCTAssertEqual(SuggestionSplice.newestAccept(annotationId: "01NOTE", in: ops)?.opId, "01C")
    }

    // MARK: - Fix round 2: the span reading is gated on the note's own history

    /// A brand-new note whose surroundings already read as the replacement:
    /// "dark" → "very dark" on the SECOND "dark" of "It was dark, very dark."
    /// asks for "…dark, very very dark." and gets it.
    func test_planAccept_aNeverAcceptedNote_splicesAsWritten_whateverItsSurroundings() {
        let para = "It was dark, very dark."
        let second = SpanAnchorResolver.capture(in: para, range: 18..<22)
        XCTAssertEqual(second.quote, "dark", "premise")
        XCTAssertTrue(SuggestionSplice.spanAlreadyApplied(suggestion: "very dark", span: second,
                                                          paragraph: para),
                      "premise: the span reading alone would fire")
        XCTAssertEqual(
            SuggestionSplice.planAccept(annotationId: "01NOTE", paragraphId: "k7m3",
                                        suggestion: "very dark", span: second,
                                        paragraph: para, ops: [],
                                        amendments: .honourEverything),
            .splice(next: "It was dark, very very dark."))
    }

    private func live(_ ops: [Op], _ amendments: AnnotationAmendments = .honourEverything) -> Bool {
        SuggestionSplice.spliceLive(annotationId: "01NOTE", ops: ops, amendments: amendments)
    }

    private func stamped(_ opId: String, _ kind: OpKind, source: SynthesisSource? = nil,
                         checkpoint: String? = nil) -> Op {
        Op(opId: opId, docId: "doc-0f677d7e", at: Date(timeIntervalSince1970: 0),
           device: "mac", session: "s", kind: kind, changes: [],
           provenance: Op.Provenance(sessionId: "s", sourceCheckpoint: checkpoint,
                                     synthesisSource: source, sourceAnnotationId: "01NOTE"))
    }

    func test_spliceLive_followsTheNotesOwnHistory() {
        XCTAssertFalse(live([]), "never accepted")
        let accept = line("01A", .claudeAccept, prior: "A.", next: "B.")
        XCTAssertTrue(live([accept]))
        let revert = line("01B", .claudeAcceptRevert, prior: "B.", next: "A.")
        XCTAssertFalse(live([accept, revert]), "taken out by Revert")
        let repair = line("01B", .claudeReject, prior: "B.", next: "A.")
        XCTAssertFalse(live([accept, repair]), "taken out by the RULING-33 repair")
        XCTAssertTrue(live([accept, revert, line("01C", .claudeAccept)]),
                      "a travel's status-only re-accept after the Revert")
        XCTAssertTrue(live([accept, line("01B", .claudeAcceptRevert)]),
                      "the writer's own status-only Revert (hand-typed) takes no text out")
        XCTAssertFalse(live([line("01B", .claudeArchive)]), "no accept at all")
        XCTAssertTrue(live([accept, line("01B", .claudeArchive), line("01C", .annotationReopen)]),
                      "a peer's archive and the pane's Reopen: the race")
        XCTAssertTrue(live([accept, line("01B", .annotationStet), line("01C", .claudeReject)]),
                      "a peer's stet or status-only reject")
    }

    /// Fix round 3: Maugham's own travel takes the text out with a restore op
    /// and writes STATUS-ONLY lines, told by their stamps.
    func test_spliceLive_aTravelsStatusOnlyLinesCloseIt() {
        let accept = line("01A", .claudeAccept, prior: "A.", next: "B.")
        XCTAssertFalse(live([accept, stamped("01B", .claudeAcceptRevert, source: .rewind)]),
                       "a rewind's step-8 revert")
        XCTAssertFalse(live([accept, stamped("01B", .claudeArchive, source: .rewind),
                             stamped("01C", .annotationReopen, source: .rewind)]),
                       "step 8's archive, then the return journey's reopen")
        XCTAssertFalse(live([accept, stamped("01B", .claudeAcceptRevert, source: .undoRewind)]),
                       "an undo-rewind's line")
        XCTAssertFalse(live([accept, stamped("01B", .claudeAcceptRevert, checkpoint: "ckpt")]),
                       "a checkpoint revert's line")
        XCTAssertTrue(live([accept, stamped("01B", .claudeAcceptRevert, source: .rewind),
                            stamped("01C", .claudeAccept, source: .rewind)]),
                      "a later travel that returns it (RULING-26) opens it again")
        XCTAssertTrue(SuggestionSplice.isTravelStatusLine(stamped("01B", .annotationReopen, source: .rewind)))
        XCTAssertFalse(SuggestionSplice.isTravelStatusLine(line("01B", .annotationReopen)),
                       "the writer's own Reopen carries no stamp")
        XCTAssertFalse(SuggestionSplice.isTravelStatusLine(
            line("01B", .claudeAcceptRevert, prior: "B.", next: "A.")), "text-carrying")
    }

    /// Fix round 4: a travel-written ARCHIVE is neutral. It means the
    /// paragraph is gone; what the gate says when the paragraph comes back is
    /// decided by the line that brings the note back.
    func test_spliceLive_aTravelsArchiveIsNeutral() {
        let accept = line("01A", .claudeAccept, prior: "A.", next: "B.")
        for (name, archive) in [
            ("rewind", stamped("01B", .claudeArchive, source: .rewind)),
            ("undo-rewind", stamped("01B", .claudeArchive, source: .undoRewind)),
            ("checkpoint", stamped("01B", .claudeArchive, checkpoint: "ckpt")),
        ] {
            XCTAssertTrue(live([accept, archive]), "\(name): the archive alone leaves it live")
            XCTAssertFalse(live([accept, archive, stamped("01C", .annotationReopen, source: .rewind)]),
                           "\(name): the return journey's travel reopen closes it")
            XCTAssertFalse(live([accept, archive, stamped("01C", .claudeAcceptRevert, source: .rewind)]),
                           "\(name): a travel's status-only revert closes it")
            XCTAssertTrue(live([accept, archive, line("01C", .annotationReopen)]),
                          "\(name): an unstamped reopen (the rewind's ⌘Z, the pane) leaves it live")
            XCTAssertTrue(live([accept, archive, stamped("01C", .claudeAccept, source: .undoRewind)]),
                          "\(name): the rewind's ⌘Z returning it accepted")
            XCTAssertFalse(live([archive]), "\(name): never accepted, never live")
            XCTAssertFalse(live([accept, line("01A5", .claudeAcceptRevert, prior: "B.", next: "A."), archive,
                                 line("01C", .annotationReopen)]),
                           "\(name): a note not live before the archive is not live after it")
        }
    }

    /// The gate reads honoured lifecycle lines only: a reopen the deriver
    /// does not honour never happened as far as the fold goes.
    func test_spliceLive_readsHonouredLinesOnly() {
        let accept = line("01A", .claudeAccept, prior: "A.", next: "B.")
        let travelReopen = stamped("01C", .annotationReopen, source: .rewind)
        let ops = [accept, travelReopen]
        XCTAssertFalse(live(ops), "honoured, the travel reopen closes it")
        let refuseReopens = AnnotationAmendments(honours: { _, _ in true }, disposing: { _ in false })
        XCTAssertFalse(AnnotationDeriver.isHonouredLifecycleOp(travelReopen, amendments: refuseReopens),
                       "premise: the deriver sets that reopen aside")
        XCTAssertTrue(live(ops, refuseReopens), "unhonoured, it is not read")
    }

    /// Accepted then Reverted: the splice is out, so the span reading is off
    /// and Accept splices again.
    func test_planAccept_afterARevert_splicesAgain() {
        let para = "It was dark, very dark."
        let second = SpanAnchorResolver.capture(in: para, range: 18..<22)
        let ops = [line("01A", .claudeAccept, prior: para, next: "It was dark, very very dark."),
                   line("01B", .claudeAcceptRevert, prior: "It was dark, very very dark.", next: para)]
        XCTAssertEqual(
            SuggestionSplice.planAccept(annotationId: "01NOTE", paragraphId: "k7m3",
                                        suggestion: "very dark", span: second,
                                        paragraph: para, ops: ops,
                                        amendments: .honourEverything),
            .splice(next: "It was dark, very very dark."))
    }
}
