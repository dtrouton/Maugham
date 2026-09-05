import XCTest
import MaughamCore
@testable import Maugham

/// **The compiler's narration, in one place** (two loops P1 Task 7).
///
/// `RoundNarrative` says what a run IS and what has changed since the last one
/// in its lane. Those sentences used to be asserted from
/// `DiagnosticsPaneTests`, because Author's Diagnostics pane drew them; it no
/// longer does — a check has no lane and no round number, so the since-line
/// and the fresh-eyes header belong to Review's round cockpit alone. The tests
/// moved here unchanged rather than being deleted: what they pin is the
/// narration itself, which is still live and still has one owner.
///
/// The cockpit's own drawing of these lines is pinned where the cockpit is
/// (`ReviewRoundCockpitTests`); what Author's pane draws INSTEAD of them is
/// pinned where that pane is (`DiagnosticsPaneTests`).
@MainActor
final class RoundNarrativeTests: XCTestCase {

    // MARK: - Fixtures
    //
    // Copies of `DiagnosticsPaneTests`' own, because both suites need a
    // `CompilerRun` and a `DeltaCounts` and neither owns the other. Every
    // field these two build is the narration's input, so a shared fixture
    // would be a third place to look for what a run in these tests is.

    private func counts(new: Int, revised: Int) -> CompilerOrchestrator.DeltaCounts {
        CompilerOrchestrator.DeltaCounts(new: new, revised: revised)
    }

    private func makeRun(model: String = "sonnet", lastOpId: String? = "op1",
                         passId: String? = nil, round: Int? = nil,
                         freshEyes: Bool? = nil,
                         openInOtherLanes: Int? = nil,
                         kind: RunKind? = nil) -> CompilerRun {
        let wholeSecond = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return CompilerRun(id: ULID.generate(), at: wholeSecond, model: model,
                           lastOpId: lastOpId, deltaSummary: "1 new, 0 revised \u{00b6}",
                           intentSnapshot: nil, droppedDangling: 0,
                           clauseStatuses: nil, truncatedReader: nil,
                           passId: passId, round: round, freshEyes: freshEyes,
                           mintedNotes: nil, openInOtherLanes: openInOtherLanes,
                           kind: kind, letter: nil)
    }

    // MARK: - What a run says it is doing

    /// **A round is not counting paragraphs, it is reading the piece** (two
    /// loops P1 Task 3). A round passes `since: nil`, so its counts are the
    /// whole manuscript — "Checking 40 new paragraphs\u{2026}" over one would be
    /// a true number saying a false thing about what the editor is doing.
    ///
    /// Author's pane is the check's home and says the check's sentence; the
    /// cockpit's is pinned where the cockpit is (`ReviewRoundCockpitTests`).
    func test_aRoundSaysItIsReadingTheWholePieceAndACheckCountsTheDelta() {
        XCTAssertEqual(
            RoundNarrative.checkingCopy(counts(new: 40, revised: 2), kind: .round),
            "Reading the whole piece\u{2026}")
        XCTAssertEqual(
            RoundNarrative.checkingCopy(counts(new: 3, revised: 0), kind: .check),
            "Checking 3 new paragraphs\u{2026}")
        XCTAssertEqual(
            DiagnosticsPane.headerCopy(for: .running(checking: counts(new: 3, revised: 0))),
            "Checking 3 new paragraphs\u{2026}",
            "Author's pane is the check's home")
        XCTAssertEqual(
            RoundNarrative.checkingCopy(counts(new: 0, revised: 0), kind: .round),
            "Reading the whole piece\u{2026}",
            "\u{2026}and a round says it over counts a delta cannot have too — "
            + "it never had a number in it to lose")
    }

    // MARK: - Since last round (M3-P3 Task 3, recounted off the queue in M4 P1)
    //
    // The arithmetic itself belongs to `SinceLastRound` (`RoundHistoryTests`);
    // these pin what the PANE decides — when there is a line at all, which
    // record it is measured against, and that it never speaks over a fresh-eyes
    // round.

    private func makeRoundRecord(
        passId: String? = "line", round: Int? = 1,
        freshEyes: Bool? = nil, at: Date = Date(timeIntervalSince1970: 0)
    ) -> RoundRecord {
        RoundRecord(runId: ULID.generate(), at: at,
                    passId: passId, round: round, freshEyes: freshEyes,
                    fingerprints: [])
    }

    /// A compiler-authored note in the queue, in the state the count turns on.
    private func makeCompilerNote(
        lane: String? = "line", round: Int? = 1,
        status: AnnotationStatus = .open, resolvedAt: Date? = nil
    ) -> Annotation {
        Annotation(
            id: ULID.generate(), kind: .query, paragraphId: "a1b2",
            body: "Whose coat is on the chair?", suggestedText: nil, priorText: nil,
            createdAt: Date(timeIntervalSince1970: 10), createdBySession: nil,
            status: status, userResponse: nil, resolvedAt: resolvedAt,
            isStale: false, reviewPassId: lane,
            compilerRunId: "run-1", compilerRound: round,
            compilerFingerprint: "continuity\u{1f}the fog\u{1f}a1b2\u{1f}")
    }

    func test_sinceLastRoundLine_isNilWithoutARoundNumber() {
        XCTAssertNil(RoundNarrative.sinceLastRoundLine(
            history: [makeRoundRecord()], run: nil, annotations: []))
        XCTAssertNil(RoundNarrative.sinceLastRoundLine(
            history: [makeRoundRecord()], run: makeRun(), annotations: []),
            "a passless run is an ordinary M2 run \u{2014} there is no round to be since")
    }

    /// **Round 1 has nothing behind it.** The line is about the distance
    /// travelled, and the first round of a lane has travelled none.
    func test_sinceLastRoundLine_isNilForTheFirstRoundOfALane() {
        XCTAssertNil(RoundNarrative.sinceLastRoundLine(
            history: [], run: makeRun(passId: "line", round: 1), annotations: []))
    }

    func test_sinceLastRoundLine_countsResolvedPersistingAndNew() {
        let filed = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            RoundNarrative.sinceLastRoundLine(
                history: [makeRoundRecord(round: 1, at: filed)],
                run: makeRun(passId: "line", round: 2),
                annotations: [
                    makeCompilerNote(round: 2),
                    makeCompilerNote(round: 1),
                    makeCompilerNote(round: 1, status: .stetted,
                                     resolvedAt: filed.addingTimeInterval(60)),
                ]),
            "Since round 1: 1 resolved \u{00b7} 1 persisting \u{00b7} 1 new")
    }

    /// **Nothing standing in another lane changes nothing** (#42 F-H). Zero and
    /// a record written before the field existed are the same answer, and both
    /// leave the sentence a writer already knows byte-for-byte what it was.
    func test_sinceLastRoundLine_saysNothingAboutOtherLanesWhenThereIsNothingToSay() {
        for run in [makeRun(passId: "line", round: 2),
                    makeRun(passId: "line", round: 2, openInOtherLanes: 0)] {
            XCTAssertEqual(
                RoundNarrative.sinceLastRoundLine(
                    history: [makeRoundRecord(round: 1)], run: run, annotations: []),
                "Since round 1: 0 resolved \u{00b7} 0 persisting \u{00b7} 0 new")
        }
    }

    /// **A finding the writer is holding in another pass is said aloud** (#42
    /// F-H) — the three counts are lane-local, and without the clause a round
    /// that re-raised a question open in the Structural lane read as three
    /// zeroes. Singular and plural, because one is the common case and reading
    /// "1 were already open in other lanes" would make the writer doubt the count.
    func test_sinceLastRoundLine_saysWhatIsOpenInAnotherLane() {
        XCTAssertEqual(
            RoundNarrative.sinceLastRoundLine(
                history: [makeRoundRecord(round: 1)],
                run: makeRun(passId: "line", round: 2, openInOtherLanes: 1),
                annotations: []),
            "Since round 1: 0 resolved \u{00b7} 0 persisting \u{00b7} 0 new "
            + "\u{00b7} 1 was already open in another lane")
        XCTAssertEqual(
            RoundNarrative.sinceLastRoundLine(
                history: [makeRoundRecord(round: 1)],
                run: makeRun(passId: "line", round: 2, openInOtherLanes: 2),
                annotations: []),
            "Since round 1: 0 resolved \u{00b7} 0 persisting \u{00b7} 0 new "
            + "\u{00b7} 2 were already open in other lanes")
    }

    /// **It is appended, not substituted.** The lane-local counts keep their
    /// own meaning beside it: a writer reading "1 persisting · 1 also open in
    /// another lane" is holding two findings, one of them from here.
    func test_sinceLastRoundLine_keepsItsThreeCountsBesideTheOtherLaneClause() {
        let filed = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            RoundNarrative.sinceLastRoundLine(
                history: [makeRoundRecord(round: 1, at: filed)],
                run: makeRun(passId: "line", round: 2, openInOtherLanes: 1),
                annotations: [
                    makeCompilerNote(round: 2),
                    makeCompilerNote(round: 1),
                    makeCompilerNote(round: 1, status: .stetted,
                                     resolvedAt: filed.addingTimeInterval(60)),
                ]),
            "Since round 1: 1 resolved \u{00b7} 1 persisting \u{00b7} 1 new "
            + "\u{00b7} 1 was already open in another lane")
    }

    /// **The record it measures FROM is the record it counts from.** The
    /// resolved half is "settled since the last round finished", and the
    /// instant that means is the ring record's own `at` — read from the wrong
    /// record and every note the writer ever settled in this pass is counted
    /// again, every round.
    func test_sinceLastRoundLine_measuresResolvedFromThatRecordsOwnTime() {
        let filed = Date(timeIntervalSince1970: 1_000)
        let settledBefore = makeCompilerNote(
            round: 1, status: .stetted, resolvedAt: filed.addingTimeInterval(-60))
        XCTAssertEqual(
            RoundNarrative.sinceLastRoundLine(
                history: [makeRoundRecord(round: 1, at: filed)],
                run: makeRun(passId: "line", round: 2),
                annotations: [settledBefore]),
            "Since round 1: 0 resolved \u{00b7} 0 persisting \u{00b7} 0 new")
    }

    /// **It reads only its own lane.** A Proof round filed between two Line
    /// rounds is newer in the ring and is not what the Line round is measured
    /// against — and its NOTES take no part either.
    func test_sinceLastRoundLine_readsOnlyItsOwnLane() {
        let filed = Date(timeIntervalSince1970: 1_000)
        let line = makeRoundRecord(passId: "line", round: 1, at: filed)
        let proof = makeRoundRecord(passId: "proof", round: 1,
                                    at: filed.addingTimeInterval(30))

        XCTAssertEqual(
            RoundNarrative.sinceLastRoundLine(
                history: [line, proof], run: makeRun(passId: "line", round: 2),
                annotations: [
                    makeCompilerNote(lane: "proof", round: 2),
                    makeCompilerNote(lane: "proof", round: 1),
                    makeCompilerNote(lane: "line", round: 1, status: .stetted,
                                     resolvedAt: filed.addingTimeInterval(60)),
                ]),
            "Since round 1: 1 resolved \u{00b7} 0 persisting \u{00b7} 0 new",
            "the Proof round sits newest in the ring and must take no part \u{2014} "
            + "neither its record nor its notes")
    }

    /// **A round still streaming has not filed the round it supersedes.**
    /// Mid-preview the newest same-lane record is N−2, and a line drawn
    /// against it would name the wrong round and then correct itself when the
    /// turn ended. The pane simply says nothing until the answer lands.
    func test_sinceLastRoundLine_isNilWhileTheRoundBeforeItIsStillStanding() {
        let twoBack = makeRoundRecord(round: 1)
        XCTAssertNil(RoundNarrative.sinceLastRoundLine(
            history: [twoBack], run: makeRun(passId: "line", round: 3), annotations: []))
        XCTAssertNotNil(RoundNarrative.sinceLastRoundLine(
            history: [twoBack], run: makeRun(passId: "line", round: 2), annotations: []),
            "control: the record IS round 2's predecessor")
    }

    /// **A fresh-eyes round is not a comparison.** It was read cold and
    /// deliberately briefed on no prior findings (spec §6), so measuring it
    /// against the last round would report a difference the run never made.
    /// Its header says what it is instead (Task 6).
    func test_sinceLastRoundLine_isNilForAFreshEyesRound() {
        let previous = makeRoundRecord(round: 1)
        XCTAssertNotNil(RoundNarrative.sinceLastRoundLine(
            history: [previous], run: makeRun(passId: "line", round: 2), annotations: []),
            "control: an ordinary round 2 does speak")
        XCTAssertNil(RoundNarrative.sinceLastRoundLine(
            history: [previous],
            run: makeRun(passId: "line", round: 2, freshEyes: true), annotations: []))
    }

    // MARK: - Fresh eyes (M3-P3 Task 6)
    //
    // The cold read's header occupies the slot the since-last-round line would
    // have taken, and the two are mutually exclusive by construction: a round
    // that was briefed on no prior findings has no distance to report.

    func test_freshEyesHeader_namesTheRoundWhenThereIsOne() {
        XCTAssertEqual(
            RoundNarrative.freshEyesHeader(
                run: makeRun(passId: "line", round: 3, freshEyes: true)),
            "Fresh eyes \u{00b7} round 3")
    }

    /// A passless cold read is still a cold read — it just has no number to
    /// name, the way an ordinary passless ⌘R has none.
    func test_freshEyesHeader_saysSoWithoutARoundNumber() {
        XCTAssertEqual(
            RoundNarrative.freshEyesHeader(run: makeRun(freshEyes: true)),
            "Fresh eyes")
    }

    func test_freshEyesHeader_isNilForAnOrdinaryRun() {
        XCTAssertNil(RoundNarrative.freshEyesHeader(run: nil))
        XCTAssertNil(RoundNarrative.freshEyesHeader(
            run: makeRun(passId: "line", round: 2)),
            "a run that was never stamped is an ordinary round")
        XCTAssertNil(RoundNarrative.freshEyesHeader(
            run: makeRun(passId: "line", round: 2, freshEyes: false)),
            "…and so is one stamped false by some earlier build")
    }

    /// **A cold read carries the cross-lane clause too** (#42, whole-branch
    /// review I2). Fresh Eyes is one of the states in which the since-line is
    /// silent by construction, so without this the count would be recorded on
    /// the run and drawn nowhere \u{2014} and a cold reread whose every finding was
    /// already open in another pass is exactly the round a writer would
    /// otherwise read as having found nothing.
    func test_freshEyesHeader_saysWhatWasAlreadyOpenInAnotherLane() {
        XCTAssertEqual(
            RoundNarrative.freshEyesHeader(
                run: makeRun(passId: "line", round: 2, freshEyes: true,
                             openInOtherLanes: 1)),
            "Fresh eyes \u{00b7} round 2 \u{00b7} 1 was already open in another lane")
        // Plural, and with no round number to hang it on: a passless cold read
        // still has a lane-crossing to report, and the wording comes from the
        // same helper the since-line reads, so the two cannot disagree about
        // when one becomes many.
        XCTAssertEqual(
            RoundNarrative.freshEyesHeader(
                run: makeRun(freshEyes: true, openInOtherLanes: 3)),
            "Fresh eyes \u{00b7} 3 were already open in other lanes")
    }

    /// The control: zero and nil both leave the header byte-identical to what
    /// it said before the clause existed.
    func test_freshEyesHeader_saysNothingAboutOtherLanesWhenThereIsNothingToSay() {
        for quiet in [makeRun(passId: "line", round: 3, freshEyes: true,
                              openInOtherLanes: 0),
                      makeRun(passId: "line", round: 3, freshEyes: true)] {
            XCTAssertEqual(RoundNarrative.freshEyesHeader(run: quiet),
                           "Fresh eyes \u{00b7} round 3")
        }
    }

    /// **The two lines never co-render.** Task 3's guard refuses the
    /// comparison for a fresh-eyes round; this is the same rule read from the
    /// other end, so a later change to either function cannot quietly put both
    /// sentences on one report.
    func test_theRoundHeaderAndTheSinceLastRoundLineAreMutuallyExclusive() {
        let previous = makeRoundRecord(round: 1)
        for run in [makeRun(passId: "line", round: 2),
                    makeRun(passId: "line", round: 2, freshEyes: true),
                    makeRun(freshEyes: true),
                    makeRun()] {
            let since = RoundNarrative.sinceLastRoundLine(
                history: [previous], run: run, annotations: [makeCompilerNote(round: 1)])
            let fresh = RoundNarrative.freshEyesHeader(run: run)
            XCTAssertFalse(since != nil && fresh != nil,
                           "both lines spoke for one round: \(String(describing: since)) "
                           + "/ \(String(describing: fresh))")
        }
    }
}
