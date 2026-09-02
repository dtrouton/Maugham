import XCTest
import SwiftUI
import AppKit
@testable import Maugham
import MaughamCore

/// **The round cockpit — Review's strip** (M4 P2 Task 3).
///
/// The queue is where a reviewer lives, and until this task the loop that
/// fills it was invisible from there: which pass the piece is being read
/// through, which editor reads it, which round they are on, and how to ask
/// for the next one. The cockpit says all four in a strip below the toolbar
/// and above the notes.
///
/// Three kinds of test, on this suite's house rules:
///
/// - **Pure**, for every decision the strip makes — the lane line, the lane
///   picker's label and its checkmark truth table, the docId-scoped run phase,
///   the report line's mutual exclusion, the empty queue's teaching. None of
///   them needs a window.
/// - **Mounted**, for what a reviewer actually sees and presses.
///   `accessibilityPerformPress` is the delivery path here, as it is in
///   `DiagnosticsPaneTests` — the same action a click runs, without the
///   active-app premise a synthetic `mouseDown` needs.
/// - **Census**, for what a mount cannot see: that the pane feeds the strip
///   the *unfiltered* queue; that the picker's write is the window's one
///   writer rather than a second spelling of it; that the picker's own menu
///   item calls the verb the mounted tests drive in its place; and that the
///   strip is mounted below the toolbar rather than inside it.
///
/// The strip's WIDTH is measured where the column's other width claims live —
/// `AnnotationsQueueToolbarWidthTests`, which owns the instrument.
@MainActor
final class ReviewRoundCockpitTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var roots: [URL] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private static let copyedit = ReviewPass(
        id: "copyedit", name: "Copyedit", brief: "b", editorName: "Gould")
    private static let line = ReviewPass(
        id: "line", name: "Line", brief: "b", editorName: "Lish")
    /// A pass a writer named themselves and never gave an editor — its
    /// `effectiveEditorName` falls back to its own name.
    private static let betaRead = ReviewPass(id: "beta", name: "Beta Read")
    /// The coach, as the pane hands her over: `ProjectManifest.effectiveCoach`,
    /// which is `ReviewPass.coachPreset` while the seat is held and nil once
    /// it has been vacated.
    private static let coach = ReviewPass.coachPreset

    // MARK: - The lane line

    /// **"<Pass> · <Editor> · round N"** — the whole of what a reviewer needs
    /// to know about where they are before they press anything.
    func test_theLaneLineNamesThePassItsEditorAndTheRound() {
        XCTAssertEqual(
            ReviewRoundCockpit.laneLine(pass: Self.copyedit, round: 3),
            "Copyedit \u{00b7} Gould \u{00b7} round 3",
            "the lane line must name the pass, the editor reading it, and the "
            + "round \u{2014} an editor by name is the whole personification")
    }

    /// **"round —" before any round has run**, never "round 0" and never a
    /// silent omission: a piece with a pass set and no round yet is exactly
    /// the state the Run button is for, and the line must say so.
    func test_theLaneLineSaysRoundDashBeforeAnyRoundHasRun() {
        XCTAssertEqual(
            ReviewRoundCockpit.laneLine(pass: Self.copyedit, round: nil),
            "Copyedit \u{00b7} Gould \u{00b7} round \u{2014}")
    }

    /// A pass with no editor of its own falls back to its own NAME
    /// (`ReviewPass.effectiveEditorName`), so the naive line would read
    /// "Beta Read · Beta Read · round 1". The line collapses it.
    func test_theLaneLineDoesNotSayACustomPassNameTwice() {
        XCTAssertEqual(
            ReviewRoundCockpit.laneLine(pass: Self.betaRead, round: 1),
            "Beta Read \u{00b7} round 1",
            "a pass whose editor IS its name must not be named twice")
    }

    /// The editor is resolved through `effectiveEditorName`, never the raw
    /// field: a customized manifest can store a preset-id pass that predates
    /// the field, and reading `pass.editorName` would put nothing on screen.
    func test_theLaneLineResolvesAPresetIdPassThatCarriesNoEditorOfItsOwn() {
        let stored = ReviewPass(id: "copyedit", name: "Copyedit")
        XCTAssertEqual(
            ReviewRoundCockpit.laneLine(pass: stored, round: 2),
            "Copyedit \u{00b7} Gould \u{00b7} round 2",
            "`effectiveEditorName` is the ONE spelling of the resolution")
    }

    // MARK: - The run phase is scoped to THIS document

    /// **The falsification this task's second reader exists for.** The run
    /// state is per WINDOW; the cockpit is per DOCUMENT. Drop the
    /// `runDocId == docId` scope and a run on chapter 2 makes chapter 1's
    /// cockpit claim it is being checked and refuse its own Run button.
    func test_anotherDocumentsRunLeavesThisCockpitIdle() {
        let elsewhere = CompilerOrchestrator.RunState.running(
            docId: "ch-2", checking: CompilerOrchestrator.DeltaCounts(new: 4, revised: 1))

        XCTAssertEqual(
            ReviewRoundCockpit.phase(runState: elsewhere, docId: "ch-1"), .idle,
            "a run on ANOTHER document must leave this cockpit idle \u{2014} the "
            + "run state is per window, the cockpit is per document")
    }

    func test_thePhaseCarriesThisDocumentsDelta() {
        let counts = CompilerOrchestrator.DeltaCounts(new: 4, revised: 1)
        XCTAssertEqual(
            ReviewRoundCockpit.phase(
                runState: .running(docId: "ch-1", checking: counts), docId: "ch-1"),
            .running(counts))
    }

    /// A run that worked and had nothing to read is idle here: `.nothingNew`
    /// says the key worked, which is what the report line under it already
    /// carries, and the strip must offer its buttons again the moment it lands.
    func test_aRunThatFoundNothingNewReadsIdle() {
        for state: CompilerOrchestrator.RunState in [
            .idle,
            .nothingNew(docId: "ch-1", at: Date()),
        ] {
            XCTAssertEqual(ReviewRoundCockpit.phase(runState: state, docId: "ch-1"), .idle,
                           "\(state) is not a run in flight and not a failure")
        }
    }

    /// **The blind spot Denver's 2026-08-18 smoke cost three misread rounds.**
    ///
    /// `.failed` used to collapse into `.idle` here, on the argument that a
    /// failure describes a run that is over — true, and it made a round that
    /// died at the session budget render EXACTLY like a clean idle. Two of
    /// Denver's rounds (Structural, then Line) timed out and he read both as
    /// "returned nothing"; the failure was legible only in Author's Diagnostics
    /// pane, a persona away from the button he pressed.
    ///
    /// Every failure kind, because the strip must not be honest about some of
    /// them: a `sessionDied` that was NOT the writer's own doing is exactly as
    /// invisible as a timeout was.
    func test_aFailedRunOnThisDocumentIsItsOwnPhase() {
        let at = Date(timeIntervalSince1970: 1_750_000_000)
        for failure: CompilerRunFailure in [
            .timedOut, .unusableOutput, .cliNotFound, .disabledByToggle,
            .sessionDied(detail: "the CLI exited"),
        ] {
            XCTAssertEqual(
                ReviewRoundCockpit.phase(
                    runState: .failed(docId: "ch-1", failure: failure, at: at),
                    docId: "ch-1"),
                .failed(failure, at: at),
                "a run that ended without an answer must reach the strip as a "
                + "failure \u{2014} \(failure) collapsed into `.idle` is a "
                + "cockpit that looks clean over a round that died")
        }
    }

    /// **The falsification for the failure arm's scope.** The run state is per
    /// WINDOW; the strip is per DOCUMENT. Drop the `runDocId == docId` clause
    /// from the `.failed` case and chapter 1 wears a red line about a death in
    /// chapter 2 — indefinitely, since the state only moves on the next run —
    /// and the writer answers it by pressing Run on a document that never
    /// failed.
    func test_anotherDocumentsFailureLeavesThisCockpitIdle() {
        XCTAssertEqual(
            ReviewRoundCockpit.phase(
                runState: .failed(docId: "ch-2", failure: .timedOut, at: Date()),
                docId: "ch-1"),
            .idle,
            "a failure on ANOTHER document must leave this cockpit idle")
    }

    /// **The writer's own doing never reaches this strip, and the filter is
    /// upstream rather than here.** Cancel, the AI toggle, project close and a
    /// second run arriving mid-flight all end a turn through `.sessionDied`,
    /// and `CompilerOrchestrator.finish` routes every one of them to `.idle`
    /// before the run state is ever set (`CompilerRunFailure.isTheWritersOwnDoing`).
    ///
    /// So this test pins the PREMISE the cockpit relies on rather than a second
    /// filter inside it: a copy of that rule here would be a rule with nothing
    /// keeping the two spellings in step. If this goes red the orchestrator
    /// changed, and the strip's honesty about Cancel changed with it.
    func test_theWritersOwnActionsAreFilteredOutBeforeTheStripEverSeesThem() {
        for detail in [CompilerRunFailure.Detail.cancelled,
                       CompilerRunFailure.Detail.sessionShutDown,
                       CompilerRunFailure.Detail.runInFlight] {
            XCTAssertTrue(
                CompilerRunFailure.sessionDied(detail: detail).isTheWritersOwnDoing,
                "\u{201C}\(detail)\u{201D} is the writer's own action coming "
                + "back at them \u{2014} the orchestrator must keep it out of "
                + "`.failed`, so the cockpit never paints a red line over a "
                + "Cancel the writer pressed themselves")
        }
        XCTAssertFalse(
            CompilerRunFailure.timedOut.isTheWritersOwnDoing,
            "\u{2026}and a timeout is not, which is why it reaches the strip")
    }

    // MARK: - The report line

    /// The strip carries ONE line after a round, and the two candidates are
    /// mutually exclusive by construction (`RoundNarrative`): a cold read was
    /// briefed on no prior findings, so a comparison drawn over it would name
    /// a difference the run never made.
    func test_theReportLineIsTheFreshEyesHeaderForAColdRead() {
        let run = makeRun(round: 3, passId: "copyedit", freshEyes: true)
        XCTAssertEqual(
            ReviewRoundCockpit.reportLine(
                history: [makeRecord(round: 2, passId: "copyedit")],
                run: run, annotations: []),
            "Fresh eyes \u{00b7} round 3",
            "a fresh-eyes round says what it IS, in the slot the comparison "
            + "would have taken")
    }

    func test_theReportLineIsTheComparisonForAWarmRound() {
        let run = makeRun(round: 3, passId: "copyedit", freshEyes: nil)
        let line = ReviewRoundCockpit.reportLine(
            history: [makeRecord(round: 2, passId: "copyedit")],
            run: run, annotations: [])
        XCTAssertEqual(line, "Since round 2: 0 resolved \u{00b7} 0 persisting \u{00b7} 0 new")
    }

    /// A passless ⌘R is an ordinary M2 run — no round, nothing to be *since*,
    /// and no line at all rather than an empty one.
    func test_theReportLineIsSilentForAPasslessRun() {
        XCTAssertNil(ReviewRoundCockpit.reportLine(
            history: [], run: makeRun(round: nil, passId: nil, freshEyes: nil),
            annotations: []))
        XCTAssertNil(ReviewRoundCockpit.reportLine(
            history: [], run: nil, annotations: []))
    }

    // MARK: - The empty queue teaches the loop

    /// **The Review copy carry.** An empty queue used to say only "ask Claude
    /// for editorial feedback" — which is one of the two ways it fills, and no
    /// longer the one the persona is built around.
    func test_theEmptyQueueNamesBothWaysItFills() {
        let withPass = ReviewRoundCockpit.emptyQueueTeaching(editorName: "Gould")
        XCTAssertTrue(withPass.contains("Run Gould\u{2019}s round (\u{2318}R)"),
                      "the round is the first way, and it is named for the "
                      + "editor who reads it \u{2014} got: \(withPass)")
        XCTAssertTrue(withPass.contains("Claude Desktop"),
                      "and asking Claude is the second \u{2014} got: \(withPass)")

        let withoutPass = ReviewRoundCockpit.emptyQueueTeaching(editorName: nil)
        XCTAssertTrue(withoutPass.contains("\u{2318}R"),
                      "with no pass set there is no editor to name, and the "
                      + "keystroke still is \u{2014} got: \(withoutPass)")
        XCTAssertTrue(withoutPass.contains("Claude Desktop"))
    }

    // MARK: - The empty queue names the piece's own reader (Task 6 fix round)

    /// **An unassigned piece under a held seat offers HER round**, not "ask
    /// Claude in Claude Desktop".
    ///
    /// The teaching's whole job is to name the loop the writer is one
    /// keystroke from. Over a coached piece \u{2318}R runs Le Guin's round and
    /// signs her name to what comes back, so an empty state that names nobody
    /// describes an app the writer is not in.
    ///
    /// Driven through the real pane on a document with no notes, so it is the
    /// wiring under test and not `emptyQueueTeaching`'s own truth table (which
    /// `test_theEmptyQueueNamesBothWaysItFills` owns).
    func test_theEmptyQueueOffersTheCoachsRoundOverAnUnassignedPiece() async throws {
        let fx = try await makeHarness()
        XCTAssertEqual(fx.store.manifest.effectiveCoach, ReviewPass.coachPreset,
                       "premise: the seat is held")

        let window = mountPane(fx, scope: .document, orchestrator: fx.orchestrator)
        let labels = allLabels(in: window)
        XCTAssertTrue(
            labels.contains { $0.contains(
                RoundNarrative.runRoundTitle(editorName: "Le Guin")) },
            "the empty queue must offer the round \u{2318}R would actually run "
            + "\u{2014} got \(labels)")
    }

    /// **Control: an assigned piece names its own stage's editor.** The seat
    /// governs pieces nobody was assigned, and a teaching that named her over
    /// a piece handed to Gould would be naming the wrong editor entirely.
    func test_theEmptyQueueNamesTheStagesEditorOnAnAssignedPiece() async throws {
        let fx = try await makeHarness()
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: fx.document.docId, passId: "copyedit")
        }

        let window = mountPane(fx, scope: .document, orchestrator: fx.orchestrator)
        let labels = allLabels(in: window)
        XCTAssertTrue(
            labels.contains { $0.contains(
                RoundNarrative.runRoundTitle(editorName: "Gould")) },
            "got \(labels)")
        XCTAssertFalse(labels.contains { $0.contains("Le Guin") },
                       "the seat must not speak over a piece with a stage set. "
                       + "Got \(labels)")
    }

    /// **Control: a vacated seat is M2's sentence again.** Nobody reads this
    /// piece, so there is no editor to name and the teaching falls back to the
    /// keystroke alone \u{2014} never to "Claude", which is the byline a
    /// passless run signs with and not a personification to invite.
    func test_theEmptyQueueNamesNobodyWhenTheSeatIsVacantAndNoPassIsSet() async throws {
        let fx = try await makeHarness()
        try await fx.store.setCoachVacated(true)
        XCTAssertNil(fx.store.manifest.effectiveCoach, "premise: the seat is vacant")

        let window = mountPane(fx, scope: .document, orchestrator: fx.orchestrator)
        let labels = allLabels(in: window)
        XCTAssertTrue(labels.contains { $0.contains("\u{2318}R") },
                      "the keystroke is still named \u{2014} got \(labels)")
        XCTAssertFalse(labels.contains { $0.contains("Le Guin") },
                       "and nobody is. Got \(labels)")
        XCTAssertFalse(
            labels.contains { $0.contains(
                RoundNarrative.runRoundTitle(editorName: "Claude")) },
            "\u{2026}least of all \u{201C}Claude\u{201D}, which is a byline "
            + "and not an editor to invite. Got \(labels)")
    }

    /// The pane asks the ONE reader resolution, and asks it for the arm that
    /// can be nil. `editorName` is never nil — it falls back to "Claude" — so
    /// a site reading it instead would invent "Run Claude's round" for a piece
    /// nobody reads, which is exactly the sentence the vacated case avoids.
    func test_theEmptyStateReadsTheOneResolutionAndItsNilableArm() throws {
        let pane = try Self.source(of: "Views/AnnotationsPane.swift")
        let reader = try XCTUnwrap(
            Self.declaration(named: "private var cockpitReader: PieceReader? {", in: pane),
            "the pane must resolve the piece's reader in one readable place")
        XCTAssertTrue(reader.contains("store.manifest.reader(forPiece:"),
                      "through the one resolution and never a second derivation. "
                      + "Got:\n\(reader)")
        XCTAssertTrue(pane.contains("editorName: cockpitReader?.activePass?.editorName"),
                      "and the offer reads the arm that is nil for nobody")
    }

    /// **The Run button's tooltip names the round the press would produce** —
    /// the shared offer plus its number, which is the one thing the empty
    /// state's copy and the board chip's verb do not carry.
    ///
    /// Pinned when `runHelp` was recomposed onto `RoundNarrative.runRoundTitle`
    /// (M4 P2 Task 4's review): three hand-built spellings of "Run X's round"
    /// across two files is how one act comes to be worded three ways, and
    /// nothing asserted this string at all before the consolidation.
    func test_theRunTooltipNamesTheOfferAndTheRoundItWouldProduce() {
        XCTAssertEqual(ReviewRoundCockpit.runHelp(pass: Self.copyedit, round: 2),
                       "Run Gould\u{2019}s round 3 (\u{2318}R)")
        XCTAssertTrue(
            ReviewRoundCockpit.runHelp(pass: Self.copyedit, round: 2)
                .hasPrefix(RoundNarrative.runRoundTitle(editorName: "Gould")),
            "\u{2026}through the one spelling the empty state and the board "
            + "chip's verb read")
        XCTAssertEqual(ReviewRoundCockpit.runHelp(pass: Self.copyedit, round: nil),
                       "Run Gould\u{2019}s round 1 (\u{2318}R)",
                       "the first round is 1, not 0")
        XCTAssertEqual(ReviewRoundCockpit.runHelp(pass: nil, round: nil),
                       "Check this piece now (\u{2318}R)",
                       "with no pass there is no lane to number and no editor "
                       + "to name")
    }

    // MARK: - Mounted: what a reviewer sees

    func test_theCockpitShowsThePassItsEditorAndTheRound() throws {
        let window = mountCockpit(activePassId: "copyedit", round: 3)
        let labels = allLabels(in: window)

        XCTAssertTrue(labels.contains("Copyedit \u{00b7} Gould \u{00b7} round 3"),
                      "the lane line never reached the strip \u{2014} got \(labels)")
        XCTAssertNotNil(findButton(labelled: ReviewRoundCockpit.runTitle, in: window),
                        "the strip must offer the round")
        XCTAssertNotNil(findButton(labelled: ReviewRoundCockpit.freshEyesTitle, in: window),
                        "\u{2026}and the cold read beside it")
    }

    /// **The lane row is the picker in BOTH states** (Denver's 2026-08-18
    /// smoke). It used to be a picker only when no pass was active, so a piece
    /// already in a lane could be moved to another one only by going back to
    /// the board and clicking a different chip — the undiscoverability the
    /// cockpit was built to end, one step further in.
    ///
    /// The two states differ in what the control SAYS, never in whether it is
    /// one: the invitation before a pass is chosen, the lane line after.
    func test_theLaneRowIsThePickerInBothStates() throws {
        let unassigned = mountCockpit(activePassId: nil, round: nil)
        XCTAssertTrue(
            allLabels(in: unassigned).contains {
                $0.contains(ReviewRoundCockpit.setAPassTitle)
            },
            "a piece with no active pass must be offered one \u{2014} "
            + "got \(allLabels(in: unassigned))")
        XCTAssertNotNil(
            pressableLanePicker(
                labelled: ReviewRoundCockpit.setAPassTitle, in: unassigned),
            "\u{2026}and the invitation must be the pressable control, not a "
            + "caption. Pressable elements: \(pressableLabels(in: unassigned))")

        let assigned = mountCockpit(activePassId: "copyedit", round: 1)
        XCTAssertFalse(
            allLabels(in: assigned).contains {
                $0.contains(ReviewRoundCockpit.setAPassTitle)
            },
            "a piece already in a lane is not being asked to set one \u{2014} "
            + "its label is the lane. Got \(allLabels(in: assigned))")
        let lane = ReviewRoundCockpit.laneLine(pass: Self.copyedit, round: 1)
        XCTAssertTrue(allLabels(in: assigned).contains(lane),
                      "premise: the lane line reached the tree at all \u{2014} "
                      + "got \(allLabels(in: assigned))")
        XCTAssertNotNil(
            pressableLanePicker(labelled: lane, in: assigned),
            "the lane line itself must be pressable once a pass is active "
            + "\u{2014} otherwise the only lane-switcher left is another board "
            + "chip click. Pressable elements: \(pressableLabels(in: assigned))")
    }

    /// **Mounted: an unassigned piece under a held seat names the coach**,
    /// and the row is still the picker rather than a caption — the writer can
    /// hand the piece to a stage from exactly where they read who has it.
    func test_theMountedStripNamesTheCoachOverAnUnassignedPiece() throws {
        let window = mountCockpit(activePassId: nil, round: nil, coach: Self.coach)
        let expected = ReviewRoundCockpit.laneLabel(
            pass: nil, round: nil, coach: Self.coach)
        XCTAssertEqual(expected, "Le Guin reads this piece", "premise")
        XCTAssertTrue(
            allLabels(in: window).contains { $0.contains(expected) },
            "the strip must say who is reading this piece \u{2014} got "
            + "\(allLabels(in: window))")
        XCTAssertFalse(
            allLabels(in: window).contains {
                $0 == ReviewRoundCockpit.setAPassTitle
            },
            "\u{2026}and must NOT say the piece has no reader while she holds "
            + "the seat. Got \(allLabels(in: window))")
        XCTAssertNotNil(
            pressableLanePicker(labelled: expected, in: window),
            "her line must still be the pressable picker, so the piece can be "
            + "handed to a stage from here. Pressable elements: "
            + "\(pressableLabels(in: window))")
    }

    /// **Mounted control: a vacated seat is the invitation again.** The same
    /// unassigned piece, the same mount, one value different.
    func test_theMountedStripSaysSetAPassWhenTheSeatIsVacant() throws {
        let window = mountCockpit(activePassId: nil, round: nil, coach: nil)
        XCTAssertTrue(
            allLabels(in: window).contains {
                $0.contains(ReviewRoundCockpit.setAPassTitle)
            },
            "with nobody in the seat the invitation returns \u{2014} got "
            + "\(allLabels(in: window))")
        XCTAssertFalse(
            allLabels(in: window).contains { $0.contains("Le Guin") },
            "and her name must not survive her absence. Got "
            + "\(allLabels(in: window))")
    }

    /// **Mounted: her round number shows.** A coached round is numbered like
    /// any pass's, and the strip is where the writer reads it.
    func test_theMountedStripCountsTheCoachsRounds() throws {
        let window = mountCockpit(activePassId: nil, round: 3, coach: Self.coach)
        XCTAssertTrue(
            allLabels(in: window).contains { $0.contains("Le Guin \u{00b7} round 3") },
            "got \(allLabels(in: window))")
    }

    /// The label the picker carries in each state, without a window — the
    /// arms `laneLabel` chooses between.
    func test_theLaneLabelIsTheLaneLineOrTheInvitation() {
        XCTAssertEqual(
            ReviewRoundCockpit.laneLabel(pass: Self.copyedit, round: 3, coach: nil),
            ReviewRoundCockpit.laneLine(pass: Self.copyedit, round: 3),
            "with a pass active the picker's label IS the lane line \u{2014} a "
            + "second spelling here is a strip that can name one lane and "
            + "change another")
        XCTAssertEqual(
            ReviewRoundCockpit.laneLabel(pass: nil, round: nil, coach: nil),
            ReviewRoundCockpit.setAPassTitle,
            "and with no pass and a VACATED seat it is the invitation")
    }

    // MARK: - Pure: the seat (editorial letter P1, Task 6)

    /// **An unassigned piece with the seat held is hers, and the strip says
    /// her name** (spec §4.1 "Where the seat is seen").
    ///
    /// "Set a pass" over a coached piece is not merely terse, it is wrong:
    /// the piece already has a reader, ⌘R already files a numbered round in
    /// her lane, and the notes already arrive signed by her. A strip that
    /// says nobody is reading it describes a state the app is not in.
    func test_theLaneLabelNamesTheCoachOverAnUnassignedPiece() {
        XCTAssertEqual(
            ReviewRoundCockpit.laneLabel(pass: nil, round: nil, coach: Self.coach),
            "Le Guin reads this piece",
            "before her first round the line is an introduction, not a count")
        XCTAssertEqual(
            ReviewRoundCockpit.laneLabel(pass: nil, round: 3, coach: Self.coach),
            "Le Guin \u{00b7} round 3",
            "after one it is the lane line's own shape \u{2014} her rounds are "
            + "numbered like any pass's")
    }

    /// **A stage beats the seat.** The coach reads what nobody was assigned;
    /// hand the piece to Lish and the strip must name Lish, whatever the seat
    /// says. Without this the label would answer the project's question
    /// rather than the piece's.
    func test_aStageBeatsTheSeat() {
        XCTAssertEqual(
            ReviewRoundCockpit.laneLabel(pass: Self.copyedit, round: 3, coach: Self.coach),
            ReviewRoundCockpit.laneLine(pass: Self.copyedit, round: 3),
            "an assigned piece reads through its own pass")
    }

    /// **A vacated seat is "Set a pass" again**, and the coach's name must
    /// not survive her absence: with no coach and no pass, nobody is reading
    /// this piece and the invitation is the honest line.
    func test_aVacatedSeatRestoresTheInvitation() {
        let label = ReviewRoundCockpit.laneLabel(pass: nil, round: nil, coach: nil)
        XCTAssertEqual(label, ReviewRoundCockpit.setAPassTitle)
        XCTAssertFalse(label.contains("Le Guin"),
                       "a vacated seat names nobody")
        XCTAssertEqual(
            ReviewRoundCockpit.laneLabel(pass: nil, round: 4, coach: nil),
            ReviewRoundCockpit.setAPassTitle,
            "and a round number left over from before she was vacated names "
            + "nobody either \u{2014} the lane line needs a reader to be about")
    }

    /// **The picker still offers exactly the stages.** She is not a lane a
    /// piece can be moved into: putting her in the menu would be a control
    /// that writes her id into `ActivePassMemory`, where `validatedActivePass`
    /// refuses it — a menu item that does nothing.
    func test_thePickerStillOffersExactlyTheStages() {
        let items = ReviewRoundCockpit.lanePickerItems(
            passes: [Self.line, Self.copyedit], current: nil)
        XCTAssertEqual(items.map(\.id), ["line", "copyedit"])
        XCTAssertFalse(items.contains { $0.id == ReviewPass.coachPreset.id },
                       "the coach is not a selectable lane")
    }

    /// The picker's truth table cannot SEE the seat — the census half of the
    /// rule above, because the drawn menu is headless-unreachable (see the
    /// type doc). `lanePickerItems` takes the ladder and nothing else, so
    /// there is no argument through which the coach could reach the menu.
    func test_thePickersTruthTableCannotSeeTheSeat() throws {
        let source = try Self.source(of: "Views/Review/ReviewRoundCockpit.swift")
        let items = try XCTUnwrap(
            Self.declaration(named: "static func lanePickerItems(", in: source),
            "the picker's item list must still be a readable declaration for "
            + "this census to have a subject")
        XCTAssertFalse(items.contains("coach"),
                       "the seat must not reach the lane picker \u{2014} she is "
                       + "not a lane a piece can be moved into, and an item "
                       + "writing her id would be refused by validatedActivePass. "
                       + "Got:\n\(items)")
        let picker = try XCTUnwrap(
            Self.declaration(named: "private var lanePicker:", in: source))
        XCTAssertTrue(
            picker.contains("Self.lanePickerItems(") && picker.contains("passes: passes"),
            "and the drawn menu iterates exactly that list, over the ladder it "
            + "was handed. Got:\n\(picker)")
    }

    // MARK: - Pure: the picker's checkmark truth table

    /// **Exactly one item is checked, and it is the active lane.** The drawn
    /// menu is headless-unreachable (`InspectorPassLadderTests`), so this is
    /// where the rule is asserted; the census above is what keeps the drawn
    /// menu equal to it.
    func test_theActiveLaneIsTheCheckedItem() {
        let items = ReviewRoundCockpit.lanePickerItems(
            passes: [Self.line, Self.copyedit, Self.betaRead], current: "copyedit")

        XCTAssertEqual(items.map(\.pass.id), ["line", "copyedit", "beta"],
                       "the picker offers the ladder in the project's own order")
        XCTAssertEqual(items.filter(\.isCurrent).map(\.id), ["copyedit"],
                       "exactly the active lane is checked \u{2014} got "
                       + "\(items.map { ($0.id, $0.isCurrent) })")
    }

    func test_noLaneIsCheckedBeforeAPassIsChosen() {
        let items = ReviewRoundCockpit.lanePickerItems(
            passes: [Self.line, Self.copyedit], current: nil)

        XCTAssertEqual(items.count, 2, "every pass is still offered")
        XCTAssertTrue(items.allSatisfy { !$0.isCurrent },
                      "a piece in no lane must not have one ticked")
    }

    /// A recorded id the manifest no longer names leaves NOTHING checked
    /// rather than ticking some other lane — the same honesty
    /// `chipMenuItems` keeps about an `.unknown` state.
    func test_aPassTheProjectNoLongerNamesChecksNothing() {
        let items = ReviewRoundCockpit.lanePickerItems(
            passes: [Self.line, Self.copyedit], current: "structural")

        XCTAssertTrue(items.allSatisfy { !$0.isCurrent },
                      "an id the ladder does not contain is not evidence that "
                      + "the piece is in any of the lanes it does")
    }

    /// **The picker's choice records through the window's ONE writer.**
    ///
    /// The item's action is `setPass(_:)` — the same call the mounted menu
    /// item makes (a SwiftUI `Menu`'s items do not exist until the writer
    /// opens it, measured in `InspectorPassLadderTests`, so this is the
    /// closest a test can get to the item and it is the identical code path).
    /// What it is wired to here is exactly what `ProjectWindow.recordActivePass`
    /// does, and the census below pins that the production mount wires it
    /// there and nowhere else.
    func test_thePickersChoiceRecordsThroughTheWindowsOneWriter() async throws {
        let fx = try await makeHarness()
        let cockpit = ReviewRoundCockpit(
            passes: [Self.line, Self.copyedit],
            activePassId: nil,
            round: nil,
            coach: nil,
            phase: .idle,
            reportLine: nil,
            onRun: { _ in },
            onSetActivePass: { passId in
                fx.documentStore.updateUIState {
                    $0.activePassMemory.record(piece: "ch-1", passId: passId)
                }
            },
            onCancel: {},
            compilerModel: .standard,
            onCompilerModelChange: { _ in })

        cockpit.setPass("copyedit")

        XCTAssertEqual(
            fx.documentStore.uiState.activePassMemory.activePass(forPiece: "ch-1"),
            "copyedit",
            "choosing a pass in the cockpit must record it as the piece's "
            + "active pass \u{2014} the value the RUN reads to mint its lane")
    }

    /// **The cockpit's own gear menu calls through the SAME
    /// `onCompilerModelChange` the pane threads it — never a second
    /// spelling.** `changeModel(_:)` is `setPass`'s own substitution
    /// (`test_thePickersChoiceRecordsThroughTheWindowsOneWriter`'s reason):
    /// `CompilerModelMenu`'s `onChange` closure IS `onCompilerModelChange`,
    /// so this is the identical call a mounted menu item would make, minus
    /// AppKit's menu ever opening.
    ///
    /// Editorial letter P1, Task 8: `ProjectWindow`'s one handler
    /// (`compilerModel`'s own `@State`, `documentStore.updateUIState`) is
    /// already pinned end-to-end by `DiagnosticsPaneTests.
    /// test_modelChoicePersistsPerProject` and `test_theGearMenusChoiceReaches
    /// TheCLI_bySpawningAFreshSession` — what THIS test proves is that the
    /// cockpit reaches that exact closure rather than one of its own.
    func test_theCockpitsGearMenuCallsThroughTheOneHandler() {
        var received: [CompilerModelChoice] = []
        let cockpit = ReviewRoundCockpit(
            passes: [Self.line, Self.copyedit],
            activePassId: nil,
            round: nil,
            coach: nil,
            phase: .idle,
            reportLine: nil,
            onRun: { _ in },
            onSetActivePass: { _ in },
            onCancel: {},
            compilerModel: .standard,
            onCompilerModelChange: { received.append($0) })

        cockpit.changeModel(.exhaustive)

        XCTAssertEqual(received, [.exhaustive],
                       "the cockpit's gear menu must reach the same handler "
                       + "the pane's own gear menu reaches")
    }

    /// **CONTROL for the census below**, and the same substitution risk
    /// `test_thePickersItemCallsTheVerbTheTestsDriveItThrough` guards against:
    /// nothing a mounted test can reach proves `lanePicker` actually wires
    /// `CompilerModelMenu` to `changeModel`'s own closure, so a rewire to a
    /// second spelling would leave `test_theCockpitsGearMenuCallsThroughThe
    /// OneHandler` green over a control that no longer does what it claims.
    func test_theModelMenuIsWiredToOnCompilerModelChangeInTheLanePicker() throws {
        let source = try Self.source(of: "Views/Review/ReviewRoundCockpit.swift")
        let picker = try XCTUnwrap(
            Self.declaration(named: "private var lanePicker:", in: source),
            "the picker must still be a readable declaration for this census "
            + "to have a subject")

        XCTAssertTrue(
            picker.contains(
                "CompilerModelMenu(choice: compilerModel, onChange: onCompilerModelChange)"),
            "the lane row's gear menu must be the shared `CompilerModelMenu`, "
            + "constructed with the cockpit's own stored properties \u{2014} "
            + "not a second `Menu` reimplementing the same choices. Got:\n"
            + picker)
    }

    /// While this document is being checked the strip says what is being read
    /// — `RoundNarrative.checkingCopy`, the pane's own copy and not a second
    /// spelling — and both buttons refuse with a reason (RULING-35).
    func test_whileRunningTheStripSaysWhatItIsCheckingAndBothButtonsRefuse() throws {
        let counts = CompilerOrchestrator.DeltaCounts(new: 14, revised: 2)
        let window = mountCockpit(
            activePassId: "copyedit", round: 2, phase: .running(counts))

        XCTAssertTrue(allLabels(in: window).contains(RoundNarrative.checkingCopy(counts)),
                      "the wait must be legible \u{2014} got \(allLabels(in: window))")
        for title in [ReviewRoundCockpit.runTitle, ReviewRoundCockpit.freshEyesTitle] {
            let button = try XCTUnwrap(findButton(labelled: title, in: window),
                                       "\(title) must still be drawn while running")
            XCTAssertEqual(axEnabled(button), false,
                           "\(title) must refuse while this document is being "
                           + "checked \u{2014} a second turn is what the NEXT "
                           + "keystroke does")
        }
    }

    /// The control for the refusal above: idle, both buttons are pressable.
    /// Without it a strip that never enabled them at all would pass the test
    /// this pair exists for.
    func test_whenNothingIsRunningBothButtonsArePressable() throws {
        let window = mountCockpit(activePassId: "copyedit", round: 2)
        for title in [ReviewRoundCockpit.runTitle, ReviewRoundCockpit.freshEyesTitle] {
            let button = try XCTUnwrap(findButton(labelled: title, in: window))
            XCTAssertEqual(axEnabled(button), true,
                           "premise: \(title) is live when no run is in flight")
        }
    }

    /// **The tracked follow-up from the failure-visibility review, absence
    /// half.** Cancel only means anything while a run is in flight, so it must
    /// not be drawn in the two states that have nothing to cancel — idle (no
    /// run) and failed (the run is already over; the remedy is another round,
    /// not cancelling the one that already ended).
    func test_theCancelButtonIsAbsentWhenIdleAndWhenFailed() {
        let idle = mountCockpit(activePassId: "copyedit", round: 2)
        XCTAssertNil(findButton(labelled: ReviewRoundCockpit.cancelTitle, in: idle),
                     "idle has no run to cancel")

        let failed = mountCockpit(
            activePassId: "copyedit", round: 2,
            phase: .failed(.timedOut, at: Date()))
        XCTAssertNil(findButton(labelled: ReviewRoundCockpit.cancelTitle, in: failed),
                     "a failed round has already ended \u{2014} the remedy is "
                     + "another round, not cancelling the one that is over")
    }

    /// The presence half, pure and mounted: the strip draws Cancel exactly
    /// where it draws the busy Run/Fresh Eyes pair.
    func test_theCancelButtonIsPresentWhileRunning() throws {
        let counts = CompilerOrchestrator.DeltaCounts(new: 3, revised: 1)
        let window = mountCockpit(
            activePassId: "copyedit", round: 2, phase: .running(counts))
        XCTAssertNotNil(findButton(labelled: ReviewRoundCockpit.cancelTitle, in: window),
                        "a run in flight must offer a way out")
    }

    /// **The end-to-end pin, driven for real.** The real `AnnotationsPane`,
    /// the real strip, a run that genuinely hangs mid-turn (`nextEvent = nil`
    /// makes `SpyRunner.send` await a continuation, so `orchestrator.runState`
    /// is a live `.running` rather than a value set by hand), a Cancel press
    /// through the same `accessibilityPerformPress` path a click takes, and
    /// then the assertion this task is about: the strip returns to idle, Run
    /// is pressable again, and — because `cancel()` routes through
    /// `.sessionDied(detail: .cancelled)` and `isTheWritersOwnDoing` — NO
    /// failure line is drawn. Asserting `orchestrator.runState == .idle`
    /// directly would prove the orchestrator's own mapping, which
    /// `test_theWritersOwnActionsAreFilteredOutBeforeTheStripEverSeesThem`
    /// already pins; this proves the button reaches it.
    func test_pressingCancelReturnsTheStripToIdleWithNoFailureLine() async throws {
        let fx = try await makeHarness()
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: "copyedit")
        }
        fx.runner.nextEvent = nil

        let window = mountPane(fx, scope: .document, orchestrator: fx.orchestrator)
        let run = try button(labelled: ReviewRoundCockpit.runTitle, in: window)
        _ = run.perform(NSSelectorFromString("accessibilityPerformPress"))

        await awaitRunning(on: fx.orchestrator)
        pump(0.3)

        let cancel = try button(labelled: ReviewRoundCockpit.cancelTitle, in: window)
        _ = cancel.perform(NSSelectorFromString("accessibilityPerformPress"))

        await awaitIdleRun(on: fx.orchestrator)
        pump(0.3)

        XCTAssertEqual(fx.orchestrator.runState, .idle,
                       "cancel's writer-caused mapping must land the strip back "
                       + "at idle \u{2014} the same state any other finished run "
                       + "leaves it in")

        let again = try button(labelled: ReviewRoundCockpit.runTitle, in: window)
        XCTAssertEqual(axEnabled(again), true,
                       "Run must be pressable again once cancel has landed")
        let fresh = try button(labelled: ReviewRoundCockpit.freshEyesTitle, in: window)
        XCTAssertEqual(axEnabled(fresh), true)

        XCTAssertNil(findButton(labelled: ReviewRoundCockpit.cancelTitle, in: window),
                     "\u{2026}and Cancel itself must be gone \u{2014} nothing is "
                     + "running any more")
        let labels = allLabels(in: window)
        for failure: CompilerRunFailure in [
            .timedOut, .unusableOutput, .cliNotFound, .disabledByToggle,
        ] {
            XCTAssertFalse(
                labels.contains(RoundNarrative.failureCopy(failure)),
                "a cancel the writer pressed themselves must never read as a "
                + "failure \u{2014} got \(labels)")
        }
    }

    /// **The end-to-end pin: the cockpit's Run button drives a real round, and
    /// the notes it lands are signed by the pass's own editor.**
    ///
    /// The whole delivery path, in one test: the real `AnnotationsPane`, the
    /// real strip inside it, the button pressed the way a click presses it,
    /// the real `CompilerOrchestrator.runRequested`, the real mint — and
    /// "Gould", not "Claude", on the notes at the end of it.
    func test_theRunButtonDrivesARealRoundWhoseNotesTheEditorSigns() async throws {
        let fx = try await makeHarness()
        let pid = try XCTUnwrap(fx.document.sequence.first)
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: "copyedit")
        }
        fx.runner.nextEvent = .resultText(Self.questionAndReport(about: pid))

        let window = mountPane(fx, scope: .document, orchestrator: fx.orchestrator)
        let run = try button(labelled: ReviewRoundCockpit.runTitle, in: window)
        _ = run.perform(NSSelectorFromString("accessibilityPerformPress"))

        await awaitOpenNotes(2, on: fx.document)
        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
        XCTAssertEqual(notes.count, 2,
                       "the cockpit's Run button must reach the same run \u{2318}R "
                       + "takes \u{2014} got \(notes.map(\.body))")
        for note in notes {
            XCTAssertEqual(note.author?.displayName, "Gould",
                           "the Copyedit pass's editor signs its round's notes")
            XCTAssertEqual(note.reviewPassId, "copyedit",
                           "and the round's lane stamps what it wrote")
        }
    }

    /// **The fix, on the delivery path: a round that dies says so in the strip
    /// that launched it, and the Run button stays pressable.**
    ///
    /// The real `AnnotationsPane`, the real strip, the real
    /// `CompilerOrchestrator.runRequested`, and a runner that answers
    /// `.failed(.timedOut)` — the exact death Denver's Structural and Line
    /// rounds hit at the session budget. Before this the strip drew the same
    /// thing it draws for a clean idle and the only account of the failure was
    /// in Author's Diagnostics pane.
    ///
    /// **Both halves matter.** The words, because a red strip that says nothing
    /// is the same blind spot with a colour; and the button, because the remedy
    /// for a timed-out round is another round — a strip that reports a failure
    /// and then withholds the control that answers it is RULING-35's dead
    /// control with a red line over it.
    func test_aFailedRoundSaysSoInTheStripAndTheRunButtonStaysPressable() async throws {
        let fx = try await makeHarness()
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: "copyedit")
        }
        fx.runner.nextEvent = .failed(.timedOut)

        let window = mountPane(fx, scope: .document, orchestrator: fx.orchestrator)
        let run = try button(labelled: ReviewRoundCockpit.runTitle, in: window)
        _ = run.perform(NSSelectorFromString("accessibilityPerformPress"))

        await awaitFailedRun(on: fx.orchestrator)
        // The state is set off the run's own task; the strip redraws on the
        // next pass of the hosted view.
        pump(0.3)

        let expected = RoundNarrative.failureCopy(.timedOut)
        XCTAssertTrue(
            allLabels(in: window).contains(expected),
            "a round that died must say so where it was launched \u{2014} "
            + "expected \u{201C}\(expected)\u{201D}, got \(allLabels(in: window))")

        let again = try button(labelled: ReviewRoundCockpit.runTitle, in: window)
        XCTAssertEqual(
            axEnabled(again), true,
            "\u{2026}and Run must stay pressable, because another round is the "
            + "remedy for a failed one")
        let fresh = try button(labelled: ReviewRoundCockpit.freshEyesTitle, in: window)
        XCTAssertEqual(axEnabled(fresh), true,
                       "\u{2026}as must Fresh Eyes")
    }

    /// **The failure REPLACES the report line rather than sitting beside it.**
    ///
    /// Both describe a round, and the report line describes an OLDER one — the
    /// last that finished. Drawn together, the comparison reads as the dead
    /// round's own result and tells the writer a run that produced nothing
    /// resolved two things.
    func test_theFailureLineStandsAloneAndTheReportLineDoesNotCoRender() throws {
        let report = "Since round 1: 2 resolved \u{00b7} 1 persisting \u{00b7} 3 new"
        let window = mountCockpit(
            activePassId: "copyedit", round: 2,
            phase: .failed(.timedOut, at: Date()), reportLine: report)

        let labels = allLabels(in: window)
        XCTAssertTrue(labels.contains(RoundNarrative.failureCopy(.timedOut)),
                      "premise: the failure is drawn \u{2014} got \(labels)")
        XCTAssertFalse(
            labels.contains(report),
            "the last finished round's comparison must not be drawn under a "
            + "failure \u{2014} it would read as the dead round's own result")
    }

    /// **Project scope renders no cockpit.** The strip is a statement about
    /// ONE piece's pass, round and next run; across the project every section
    /// is a different piece with a different answer, and a single strip there
    /// could only be wrong.
    func test_projectScopeRendersNoCockpit() async throws {
        let fx = try await makeHarness()
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: "copyedit")
        }

        let window = mountPane(fx, scope: .project(focusPiece: nil),
                               orchestrator: fx.orchestrator)

        XCTAssertNil(findButton(labelled: ReviewRoundCockpit.runTitle, in: window),
                     "the cockpit is a piece's, and project scope has no piece")
        XCTAssertFalse(allLabels(in: window).contains {
            $0.contains("Copyedit \u{00b7} Gould")
        }, "\u{2026}and no lane line either")
    }

    /// **A host with no compiler behind it draws no strip.** The pane is
    /// registered in Review and reachable by ⌘⌥A in every persona, and the
    /// probe mounts pass neither store — a Run button over a `nil`
    /// orchestrator would be a control with nothing to call, which is a crash
    /// at best and RULING-35's dead control at worst.
    ///
    /// Asserted against the SAME fixture that draws the strip in
    /// `test_theRunButtonDrivesARealRoundWhoseNotesTheEditorSigns`, so the one
    /// difference between the two is the store.
    func test_aHostWithNoCompilerDrawsNoStrip() async throws {
        let fx = try await makeHarness()
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: "copyedit")
        }

        let window = mountPane(fx, scope: .document, orchestrator: nil)

        XCTAssertNil(findButton(labelled: ReviewRoundCockpit.runTitle, in: window),
                     "a nil orchestrator must draw no Run button \u{2014} there "
                     + "is nothing for it to call")
        XCTAssertNil(findButton(labelled: ReviewRoundCockpit.freshEyesTitle, in: window))
        XCTAssertFalse(allLabels(in: window).contains {
            $0.contains("Copyedit \u{00b7} Gould")
        }, "\u{2026}and no lane line, however much the pass memory knows")
    }

    /// **The filtered-empty state names the filter, not a missing round**
    /// (M4 P2 Task 8, T3 carry). Before this the pane's document-scope empty
    /// state taught the round-running loop even when a note WAS there —
    /// stamped for a pass this piece is not currently being reviewed
    /// through, so the pass filter hides it while the kind/status pool still
    /// holds it — telling the writer to ask for a round that had, in truth,
    /// already answered.
    func test_theFilteredEmptyStateNamesTheFilterRatherThanTeachingARound() async throws {
        let fx = try await makeHarness()
        let pid = try XCTUnwrap(fx.document.sequence.first)
        // In the pool (kind/status pass it) but not in the rows (the pass
        // filter below excludes it): stamped "structural", read through "line".
        _ = try await fx.document.addAnnotation(
            kind: .comment, paragraphId: pid, body: "A structural note.",
            reviewPassId: "structural")
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: "line")
        }

        let window = mountPane(fx, scope: .document, orchestrator: fx.orchestrator)
        let labels = allLabels(in: window)

        XCTAssertTrue(
            labels.contains { $0.contains("No notes match your filters") },
            "a hidden note must be named as hidden, not as absent \u{2014} got \(labels)")
        XCTAssertFalse(
            labels.contains { $0.contains("No annotations") },
            "the genuinely-empty title must not also draw over a filtered pool")
    }

    /// **Control: a genuinely empty document still teaches the round**
    /// (M4 P2 Task 8 review, Minor 2) — the filtered-empty arm reads a wider
    /// pool than before (every kind, every status), and a wider pool is
    /// exactly the kind of change that can quietly swallow the ordinary case.
    /// Nothing added to this document at all, so both the pool and the rows
    /// are empty and `documentQueueIsGenuinelyEmpty` must say so.
    func test_aGenuinelyEmptyDocumentStillDrawsTheRoundTeaching() async throws {
        let fx = try await makeHarness()

        let window = mountPane(fx, scope: .document, orchestrator: fx.orchestrator)
        let labels = allLabels(in: window)

        XCTAssertTrue(
            labels.contains { $0.contains("No annotations") },
            "an empty document must still read as empty \u{2014} got \(labels)")
        XCTAssertFalse(
            labels.contains { $0.contains("No notes match your filters") },
            "\u{2026}and never claim a filter is hiding something that was "
            + "never there")
    }

    /// **The widened pool also catches a KIND mismatch** (M4 P2 Task 8
    /// review, Minor 1). Before the widening, the filtered-empty check read
    /// `kindStatusAnnotations` — already narrowed by the kind filter — so
    /// narrowing Kind to a kind the document holds none of made a filter
    /// look like an empty document. The pool is now the document's raw,
    /// unfiltered read (`AnnotationFilter(statuses: nil)`), so this drives
    /// the REAL kind-filter control (not the data-only trick the pass-filter
    /// test above uses, since kind starts at `.all` and needs an actual
    /// press to narrow) and checks the same distinction survives it.
    func test_theFilteredEmptyStateAlsoCatchesAKindMismatch() async throws {
        let fx = try await makeHarness()
        let pid = try XCTUnwrap(fx.document.sequence.first)
        _ = try await fx.document.addAnnotation(
            kind: .comment, paragraphId: pid, body: "Only a comment here.")

        let window = mountPane(
            fx, scope: .document, orchestrator: fx.orchestrator, width: 900)
        let suggestionsFilter = try button(labelled: "Suggestions", in: window)
        _ = suggestionsFilter.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.2)

        let labels = allLabels(in: window)
        XCTAssertTrue(
            labels.contains { $0.contains("No notes match your filters") },
            "the Kind filter hid the document's only note \u{2014} that must "
            + "read as hidden, not absent; got \(labels)")
        XCTAssertFalse(labels.contains { $0.contains("No annotations") })
    }

    /// **The Critical the whole-branch review found: a queue where every
    /// note is settled must NOT read as filtered** (M4 P2 Task 8 whole-branch
    /// review). Before this, `pool` counted every status — a writer who
    /// resolved their last open note had zero open rows and one resolved
    /// note still sitting in `pool`, so the pane claimed Kind/Author/Triage/
    /// the pass filter was hiding a note that only the show-resolved toggle
    /// can reveal, over a queue that was genuinely, correctly empty. This is
    /// the loop's own SUCCESS state — the same moment Author's Diagnostics
    /// pane says "You've handled this check's notes." — and it must draw the
    /// round teaching, never the filter copy.
    func test_aQueueWhereEveryNoteIsSettledDrawsTheRoundTeachingNotTheFilterCopy() async throws {
        let fx = try await makeHarness()
        let pid = try XCTUnwrap(fx.document.sequence.first)
        let noteId = try await fx.document.addAnnotation(
            kind: .comment, paragraphId: pid, body: "A note the writer settles.")
        try await fx.document.archiveAnnotation(id: noteId)

        let window = mountPane(fx, scope: .document, orchestrator: fx.orchestrator)
        let labels = allLabels(in: window)

        XCTAssertTrue(
            labels.contains { $0.contains("No annotations") },
            "a fully-settled queue is the ordinary empty case, not a "
            + "filtered one \u{2014} got \(labels)")
        XCTAssertFalse(
            labels.contains { $0.contains("No notes match your filters") },
            "no named filter (Kind/Author/Triage/the pass) can reveal a "
            + "resolved note \u{2014} only show-resolved can, and it is not "
            + "one of the four this copy names")
    }

    // MARK: - Pure: the filtered-empty predicate

    /// **`documentQueueIsGenuinelyEmpty` pinned directly, both cases** (M4 P2
    /// Task 8 review, Minor 2). The mounted tests above exercise it
    /// end-to-end but assert nothing about the function itself — a change
    /// that broke the predicate while leaving both mounted scenarios'
    /// numbers accidentally aligned would still pass every mounted test.
    func test_documentQueueIsGenuinelyEmpty_bothPoolAndRowsEmpty_isTrue() {
        XCTAssertTrue(
            AnnotationsPane.documentQueueIsGenuinelyEmpty(pool: [], visibleRows: []),
            "no notes anywhere on the document is the genuinely-empty case")
    }

    func test_documentQueueIsGenuinelyEmpty_poolNonEmptyRowsEmpty_isFalse() {
        XCTAssertFalse(
            AnnotationsPane.documentQueueIsGenuinelyEmpty(
                pool: [Self.fixtureAnnotation()], visibleRows: []),
            "a non-empty pool with nothing visible is a FILTER hiding notes, "
            + "not an empty document")
    }

    // MARK: - Census: the seams a mount cannot see

    /// **Whole-branch seam (a).** `sinceLastRoundLine` counts the writer's
    /// QUEUE — what they settled, what persists, what is new — and the pane's
    /// visible rows are filtered by author, status, triage and pass. Feeding
    /// it those would make "resolved" permanently zero under the default
    /// `[.open]` filter and would skew every count under any other.
    func test_theStripIsFedTheUnfilteredQueueAndNotTheVisibleRows() throws {
        let source = try Self.source(of: "Views/AnnotationsPane.swift")
        let read = try XCTUnwrap(
            Self.declaration(named: "private var cockpitAnnotations:", in: source),
            "the strip's annotation read must be a readable declaration")

        XCTAssertTrue(read.contains("AnnotationFilter(statuses: nil)"),
                      "the strip counts the queue in EVERY state \u{2014} a "
                      + "`[.open]` filter here reports zero resolved forever")
        XCTAssertTrue(read.contains("annotationsVersion"),
                      "\u{2026}and observes the document's version, so a note "
                      + "stetted in the queue moves the line")
        for filtered in ["visibleAnnotations", "kindStatusPool", "passesRowFilters"] {
            XCTAssertFalse(read.contains(filtered),
                           "the strip must not read the pane's FILTERED rows "
                           + "(`\(filtered)`)")
        }
    }

    /// The picker's write stays `ProjectWindow.recordActivePass` — the one
    /// writer of `UIState.activePassMemory`. A second spelling in the pane or
    /// in the mount is two places that can disagree about which pass a piece
    /// is in, and the RUN reads only one of them.
    func test_theProductionMountWiresThePickerToTheWindowsOneWriter() throws {
        let window = try Self.source(of: "Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains("onSetActivePass:"),
                      "the window must supply the strip's pass writer")
        let arm = try XCTUnwrap(
            window.range(of: "onSetActivePass:"),
            "the mount must name the closure")
        let after = String(window[arm.upperBound...].prefix(320))
        XCTAssertTrue(after.contains("recordActivePass(forPiece:"),
                      "\u{2026}and it must be the existing private writer, not a "
                      + "second `updateUIState` in the mount \u{2014} got: \(after)")

        let pane = try Self.source(of: "Views/AnnotationsPane.swift")
        XCTAssertFalse(pane.contains("activePassMemory.record("),
                       "the queue advises about passes; it never rules on one "
                       + "\u{2014} the write belongs to the window")
    }

    /// **The pane threads its OWN `compilerModel`/`onCompilerModelChange`
    /// through to the cockpit, rather than a fresh literal** (editorial
    /// letter P1, Task 8). A hardcoded `.standard` or a `{ _ in }` here would
    /// compile, mount, and quietly show the wrong choice or drop every change
    /// on the floor — nothing a mounted test can see, since the cockpit's own
    /// gear menu draws whatever it was constructed with either way.
    func test_theAnnotationsPaneThreadsItsOwnCompilerModelToTheCockpit() throws {
        let pane = try Self.source(of: "Views/AnnotationsPane.swift")
        let call = try XCTUnwrap(
            pane.range(of: "ReviewRoundCockpit("),
            "the pane must still construct the cockpit for this census to "
            + "have a subject")
        let after = String(pane[call.upperBound...].prefix(1600))
        XCTAssertTrue(after.contains("compilerModel: compilerModel"),
                      "the pane's own stored `compilerModel` must reach the "
                      + "cockpit \u{2014} got:\n\(after)")
        XCTAssertTrue(after.contains("onCompilerModelChange: onCompilerModelChange"),
                      "\u{2026}and its own closure, not a no-op \u{2014} got:\n\(after)")
    }

    /// **One hop up: `DetailPaneToggle` already held `compilerModel`/
    /// `onCompilerModelChange` for the Diagnostics segment (M2 Task 8) — this
    /// pins that it hands the SAME pair to the Annotations segment too**,
    /// rather than defaulting it to `.standard`/no-op for the segment that
    /// gained the control second.
    func test_theDetailPaneToggleThreadsCompilerModelToTheAnnotationsSegment() throws {
        let toggle = try Self.source(of: "Views/DetailPaneToggle.swift")
        let call = try XCTUnwrap(
            toggle.range(of: "AnnotationsPane("),
            "the toggle must still construct the annotations segment for this "
            + "census to have a subject")
        let after = String(toggle[call.upperBound...].prefix(1600))
        XCTAssertTrue(after.contains("compilerModel: compilerModel"),
                      "got:\n\(after)")
        XCTAssertTrue(after.contains("onCompilerModelChange: onCompilerModelChange"),
                      "got:\n\(after)")
    }

    /// **The link the mounted tests borrow, pinned.**
    ///
    /// `test_thePickersChoiceRecordsThroughTheWindowsOneWriter` drives
    /// `setPass(_:)` directly, because a SwiftUI `Menu` builds its items only
    /// when the writer opens it and the item itself is unreachable from a
    /// hosted view (measured in `InspectorPassLadderTests`). That substitution
    /// is honest only while the item actually calls `setPass` — and nothing
    /// mounted can see whether it does. Rewiring `lanePicker`'s button to a
    /// local `@State`, or to `onSetActivePass` under a second spelling, leaves
    /// every other test in this file green over a picker that no longer
    /// records anything.
    ///
    /// So the link is a census over the picker's own declaration. It is the
    /// weakest seam in this task and it is the one the review found. **It moved
    /// with the picker** (2026-08-18): `passPicker` — the passless arm — became
    /// `lanePicker`, the whole lane row in both states, and the census follows
    /// it by name.
    ///
    /// Its second half is new and answers a defect this unification could
    /// introduce: `lanePickerItems` is the checkmark truth table, and the tests
    /// below drive it directly. A drawn menu built off its own `ForEach(passes)`
    /// would leave those green over a picker that ticks nothing.
    func test_thePickersItemCallsTheVerbTheTestsDriveItThrough() throws {
        let source = try Self.source(of: "Views/Review/ReviewRoundCockpit.swift")
        let picker = try XCTUnwrap(
            Self.declaration(named: "private var lanePicker:", in: source),
            "the picker must still be a readable declaration for this census "
            + "to have a subject")

        XCTAssertTrue(picker.contains("setPass(item.pass.id)"),
                      "the picker's menu item must call `setPass(item.pass.id)` "
                      + "\u{2014} the verb `test_thePickersChoiceRecordsThroughThe"
                      + "WindowsOneWriter` drives in its place. Anything else "
                      + "here and that test proves nothing about this control. "
                      + "Got:\n\(picker)")
        XCTAssertTrue(
            picker.contains("Self.lanePickerItems(")
                && picker.contains("current: activePassId"),
            "\u{2026}once per item of `lanePickerItems(passes:current:)`, asked "
            + "about the piece's OWN active pass \u{2014} a second list built "
            + "here is a checkmark rule the truth-table tests below cannot see. "
            + "Got:\n\(picker)")
        XCTAssertTrue(picker.contains("item.isCurrent"),
                      "\u{2026}and the drawn item must read the truth table's "
                      + "verdict rather than recomputing one")
    }

    /// **ONE spelling of a failure, read by every surface that draws one.**
    ///
    /// Author's Diagnostics pane, Review's cockpit and — since publish-department
    /// P4 Task 3 — Publish's department desk all say something about the same
    /// death, because the compiler's session and the translator's are one
    /// `ClaudeCLISession` machinery under different owners. A writer who checks
    /// another pane to understand the first must not find a differently-worded
    /// account of it. The sentence lives in `RoundNarrative` — where
    /// `checkingCopy` and the round lines already went, and for the same reason —
    /// and every surface calls it.
    ///
    /// **The desk passes `session: .translation`, and that is not a second
    /// spelling**: the switch is still `RoundNarrative`'s, and the parameter
    /// supplies only the nouns two of its arms take. "The compiler's session
    /// ended" over a Spanish round is one account applied to the wrong work,
    /// which is a different defect from two accounts of one death — and the
    /// remedy for it is a parameter, not a copy.
    ///
    /// A census rather than a value comparison because the defect this guards
    /// is a RESTATEMENT: a second `switch failure` in any of these files would
    /// keep every equality test green on the day it was written and drift the
    /// first time one arm is reworded. `failureCopy` was `DiagnosticsPane`'s own
    /// static until 2026-08-18; a reviewer reinstating it there would be
    /// reopening exactly that.
    ///
    /// **What is forbidden is the ARMS, not the name.** The by-name check this
    /// used to carry stopped being a detector when the desk grew a
    /// `failureCopy` of its own over `TranslatorOrchestrator.Failure` — a
    /// two-case call-through, not a restatement. A restated switch over
    /// `CompilerRunFailure`, whatever it were called, cannot avoid its own
    /// cases; those are what is scanned for.
    ///
    /// The verdict itself is `oneSpellingViolations(in:)` — **shared with the
    /// planted-offender self-test below**, which is `TripwireGrepTests`'
    /// convention (its `adr0018ReadPatterns` note names the duplication finding
    /// that made it one): a self-test that re-implements the scan is a self-test
    /// of itself.
    func test_everySurfaceReadsTheOneFailureSpelling() throws {
        XCTAssertFalse(
            RoundNarrative.failureCopy(.timedOut).isEmpty,
            "premise: the shared spelling exists and answers")

        for path in Self.oneSpellingSurfaces {
            let violations = Self.oneSpellingViolations(in: try Self.source(of: path))
            XCTAssertEqual(
                violations, [],
                "\(path) \(violations.joined(separator: "; ")) \u{2014} a second "
                + "switch over `CompilerRunFailure` is a second account of one "
                + "death, whatever it is called")
        }
    }

    /// Every surface that draws a dead run. A file earns its place here by
    /// drawing one; nothing enforces the converse, which is why the list sits
    /// beside the rule rather than in prose somewhere else.
    static let oneSpellingSurfaces = [
        "Views/DiagnosticsPane.swift",
        "Views/Review/ReviewRoundCockpit.swift",
        "Views/Publish/DepartmentRunState.swift",
        "Views/Publish/DepartmentDesignRow.swift",
    ]

    /// The arms a restated `switch` over `CompilerRunFailure` cannot avoid
    /// carrying. SHARED between the census and its self-test.
    static let restatedFailureArms = [
        "case .cliNotFound", "case .unusableOutput", "case .sessionDied(",
    ]

    /// **What is wrong with one surface's account of a dead run**, as sentences.
    /// Empty means the file reads the one spelling and restates nothing.
    static func oneSpellingViolations(in source: String) -> [String] {
        var violations: [String] = []
        if !source.contains("RoundNarrative.failureCopy(") {
            violations.append("does not read the shared failure spelling")
        }
        for arm in restatedFailureArms where source.contains(arm) {
            violations.append("restates `\(arm)`")
        }
        return violations
    }

    /// **The self-check: the census fires on a restatement it has never seen.**
    ///
    /// Written to disk and read back rather than asserted against the literal in
    /// hand — `TripwireGrepTests`' planted-offender shape — so what runs is the
    /// real scan over a real file, down the path the production test takes. The
    /// version this replaces asserted `planted.contains(arm)` on the string it
    /// had just built, which is true by construction and would have stayed green
    /// over a census that detected nothing at all.
    ///
    /// The control is the second half: a file that DELEGATES must come back
    /// clean, or the scan is one that condemns everything and the green
    /// production run above says nothing either.
    func test_theOneSpellingCensusFiresOnAPlantedRestatement() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("one-spelling-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let offender = tmp.appendingPathComponent("RestatingPane.swift")
        try """
        enum RestatingPane {
            static func describe(_ failure: CompilerRunFailure) -> String {
                switch failure {
                case .cliNotFound: return "Claude Code isn't installed."
                case .disabledByToggle: return "Claude access is off."
                case .timedOut: return "It took too long."
                case .sessionDied(let detail): return "It died: \\(detail)."
                case .unusableOutput: return "Unreadable."
                }
            }
        }
        """.write(to: offender, atomically: true, encoding: .utf8)

        let caught = Self.oneSpellingViolations(
            in: try String(contentsOf: offender, encoding: .utf8))
        XCTAssertEqual(caught.count, Self.restatedFailureArms.count + 1,
                       "the census must catch every restated arm AND the missing "
                       + "delegation \u{2014} got \(caught)")
        for arm in Self.restatedFailureArms {
            XCTAssertTrue(caught.contains("restates `\(arm)`"),
                          "`\(arm)` went unseen \u{2014} got \(caught)")
        }

        let clean = tmp.appendingPathComponent("DelegatingPane.swift")
        try """
        enum DelegatingPane {
            static func describe(_ failure: CompilerRunFailure) -> String {
                RoundNarrative.failureCopy(failure, session: .translation)
            }
        }
        """.write(to: clean, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            Self.oneSpellingViolations(
                in: try String(contentsOf: clean, encoding: .utf8)), [],
            "the control must come back clean, or the scan condemns everything")
    }

    /// **The strip is not in the toolbar.** `AnnotationsQueueToolbar`'s one
    /// job is fitting a 240pt column, and its width census
    /// (`AnnotationsQueueToolbarWidthTests`) measures the row as declared —
    /// a control added there would inflate the pane's layout width and centre
    /// every annotation body against a width the column does not have.
    /// **The pane hands the strip the seat, and counts HER lane.** Two
    /// wirings a mount cannot see, and each fails silently on its own: with
    /// no `coach:` the strip says "Set a pass" over a piece Le Guin has read
    /// three times, and with `passId: pass?.id` alone `latestRound` is asked
    /// about no lane at all and reports no round over those same three.
    func test_theProductionMountFeedsTheStripTheSeatAndHerLane() throws {
        let pane = try Self.source(of: "Views/AnnotationsPane.swift")
        let cockpit = try XCTUnwrap(
            Self.declaration(named: "private var roundCockpit: some View {", in: pane),
            "the strip's mount must still be a readable declaration")
        XCTAssertTrue(cockpit.contains("store.manifest.effectiveCoach"),
                      "the mount reads the seat through `effectiveCoach` "
                      + "\u{2014} the one spelling of \u{201C}is the seat "
                      + "held\u{201D}. Got:\n\(cockpit)")
        XCTAssertTrue(cockpit.contains("coach: coach"),
                      "\u{2026}and threads it into the strip. Got:\n\(cockpit)")
        XCTAssertTrue(cockpit.contains("pass?.id ?? coach?.id"),
                      "\u{2026}and asks `latestRound` about the lane the piece "
                      + "actually files in: its stage, else hers. Got:\n\(cockpit)")
    }

    func test_theStripLivesBelowTheToolbarAndNotInsideIt() throws {
        let toolbar = try Self.source(of: "Views/Review/AnnotationsQueueToolbar.swift")
        XCTAssertFalse(toolbar.contains("ReviewRoundCockpit"),
                       "the cockpit must not be drawn inside the toolbar")

        let pane = try Self.source(of: "Views/AnnotationsPane.swift")
        let body = try XCTUnwrap(Self.declaration(named: "var body: some View {", in: pane))
        guard let toolbarLine = body.range(of: "toolbar"),
              let cockpitLine = body.range(of: "roundCockpit") else {
            return XCTFail("the body must mount the toolbar and then the strip")
        }
        XCTAssertTrue(toolbarLine.lowerBound < cockpitLine.lowerBound,
                      "the strip wraps BELOW the toolbar's divider")
    }

    // MARK: - The letter (editorial letter P1 Task 9)

    nonisolated private static func letter(
        oneThing: String?, about: String = "A ghost story told through weather."
    ) -> Letter {
        Letter(about: about, oneThing: oneThing, working: [],
               habits: [Letter.Habit(
                    name: "Every speech sounds like the same person", refs: [],
                    cost: "The cast blurs.", lesson: nil, exercise: nil)],
               questions: [], scenes: nil, scenePosition: nil)
    }

    /// **The one thing, else the say-back.** The cockpit's line is one line,
    /// and `one_thing` is the letter's own answer to "if you fix one thing" —
    /// `about` stands in only when the letter had nothing to fix.
    func test_theLetterLineIsTheOneThingElseTheSayBack() {
        XCTAssertEqual(
            ReviewRoundCockpit.letterLine(
                Self.letter(oneThing: "Give the reader the dock before the fire.")),
            "Give the reader the dock before the fire.")
        XCTAssertEqual(
            ReviewRoundCockpit.letterLine(Self.letter(oneThing: nil)),
            "A ghost story told through weather.",
            "a letter with nothing to fix still says what it read")
        XCTAssertNil(
            ReviewRoundCockpit.letterLine(nil),
            "no letter is no line \u{2014} never an empty caption")
        XCTAssertNil(
            ReviewRoundCockpit.letterLine(Letter(
                about: "A ghost story.", oneThing: nil, working: [], habits: [],
                questions: [], scenes: nil, scenePosition: nil)),
            "a letter with only its say-back in it is empty (`Letter.isEmpty`), and "
            + "an empty letter has no section to disclose")
    }

    /// **A blank one thing is not a line.** `one_thing` is `<string|null>` on
    /// the wire and a model writing `""` is well within it; taken literally it
    /// drew an empty caption with a disclosure triangle beside it.
    func test_aBlankOneThingFallsBackToTheSayBack() {
        XCTAssertEqual(
            ReviewRoundCockpit.letterLine(Self.letter(oneThing: "")),
            "A ghost story told through weather.",
            "an empty one thing is nothing to say, not something to draw")
        XCTAssertEqual(
            ReviewRoundCockpit.letterLine(Self.letter(oneThing: "   \n ")),
            "A ghost story told through weather.",
            "and whitespace is the same blank")
        XCTAssertEqual(
            ReviewRoundCockpit.letterLine(
                Self.letter(oneThing: "  Give the reader the dock.  ")),
            "Give the reader the dock.",
            "the line is trimmed either way \u{2014} a leading newline in a caption "
            + "pushes the strip's own layout around")
        XCTAssertNil(
            ReviewRoundCockpit.letterLine(Self.letter(oneThing: "", about: "  ")),
            "a letter whose every line is blank has no line at all")
    }

    /// The line draws under the status line, and the disclosure opens the
    /// host's own `LetterSection`.
    func test_theCockpitDrawsTheLetterLineAndDisclosesTheSection() throws {
        let window = mountCockpit(
            activePassId: "copyedit", round: 2, reportLine: "Since round 1: 1 new",
            letterLine: "Give the reader the dock before the fire.",
            letterDisclosure: { AnyView(Text("THE-LETTER-BODY")) })

        let texts = allLabels(in: window)
        let status = try XCTUnwrap(
            texts.firstIndex(of: "Since round 1: 1 new"),
            "the status line went missing. Read: \(texts)")
        let letter = try XCTUnwrap(
            texts.firstIndex(of: "Give the reader the dock before the fire."),
            "the letter line never reached the strip. Read: \(texts)")
        XCTAssertLessThan(
            status, letter,
            "the letter sits UNDER the status line, not over it. Read: \(texts)")

        let disclosure = try XCTUnwrap(
            pressableLanePicker(
                labelled: "Give the reader the dock before the fire.", in: window)
                ?? disclosureElement(
                    labelled: "Give the reader the dock before the fire.", in: window),
            "the letter line must be a disclosure control, not a caption. "
            + "Pressables: \(pressableLabels(in: window))")
        press(disclosure)
        pump(0.3)
        XCTAssertTrue(
            allLabels(in: window).contains("THE-LETTER-BODY"),
            "opening the disclosure must reveal the host's own section. "
            + "Read: \(allLabels(in: window))")
    }

    /// No letter, no line and nothing to open — never an empty disclosure
    /// triangle over a strip with nothing behind it.
    func test_noLetterDrawsNoLineAndNoDisclosure() throws {
        let window = mountCockpit(
            activePassId: "copyedit", round: 2, reportLine: "Since round 1: 1 new")
        let texts = allLabels(in: window)
        XCTAssertFalse(
            texts.contains("Give the reader the dock before the fire."),
            "Read: \(texts)")
        XCTAssertFalse(
            texts.contains(LetterSection.title),
            "and no section header either. Read: \(texts)")
    }

    /// **The pane feeds the strip its own document's letter.** Mounted
    /// through `AnnotationsPane` rather than the strip directly, because the
    /// claim is about the derivation the pane makes — a strip fed by hand
    /// proves nothing about what the queue shows.
    func test_theQueuesStripShowsTheOpenDocumentsLetter() async throws {
        let fx = try await makeHarness()
        fx.diagnostics.replace(
            run: CompilerRun(
                id: "r-1", at: Date(), model: "test-model", lastOpId: "op-1",
                deltaSummary: "1 new", intentSnapshot: nil, passId: nil, round: 1,
                freshEyes: nil,
                letter: Self.letter(oneThing: "Give the reader the dock before the fire.")),
            diagnostics: [], docId: fx.document.docId)

        let window = mountPane(fx, scope: .document, orchestrator: fx.orchestrator)
        pump(0.3)
        XCTAssertTrue(
            allLabels(in: window).contains("Give the reader the dock before the fire."),
            "the queue's strip must carry the letter the open piece's last run left. "
            + "Read: \(allLabels(in: window))")
    }

    /// **The census the mount cannot make**: the pane derives the line through
    /// the one static above and builds the disclosure from the same
    /// `LetterSection` Author draws, rather than a second view of its own.
    func test_thePaneDerivesTheLineAndDisclosesTheSharedSection() throws {
        let source = try readSource("Maugham/Views/AnnotationsPane.swift")
        let cockpit = try XCTUnwrap(
            source.range(of: "ReviewRoundCockpit(").map {
                String(source[$0.upperBound...].prefix(1800))
            },
            "the cockpit's mount is where the two inputs are fed")
        XCTAssertTrue(
            cockpit.contains("letterLine: ReviewRoundCockpit.letterLine("),
            "the line must come from the one static the test above pins, never from a "
            + "second `oneThing ?? about` spelled here: \(cockpit)")
        XCTAssertTrue(
            cockpit.contains("letterDisclosure:"),
            "and the disclosure must be fed: \(cockpit)")
        XCTAssertTrue(
            source.contains("LetterSection("),
            "Review discloses the SAME view Author draws \u{2014} a second letter view "
            + "would be two letters that could disagree about one run")
    }

    // MARK: - Mounting

    private func mountCockpit(
        activePassId: String?,
        round: Int?,
        phase: ReviewRoundCockpit.RunPhase = .idle,
        reportLine: String? = nil,
        coach: ReviewPass? = nil,
        onCancel: @escaping () -> Void = {},
        compilerModel: CompilerModelChoice = .standard,
        onCompilerModelChange: @escaping (CompilerModelChoice) -> Void = { _ in },
        letterLine: String? = nil,
        letterDisclosure: (() -> AnyView)? = nil
    ) -> NSWindow {
        mount(AnyView(ReviewRoundCockpit(
            passes: [Self.line, Self.copyedit],
            activePassId: activePassId,
            round: round,
            coach: coach,
            phase: phase,
            reportLine: reportLine,
            onRun: { _ in },
            onSetActivePass: { _ in },
            onCancel: onCancel,
            compilerModel: compilerModel,
            onCompilerModelChange: onCompilerModelChange,
            letterLine: letterLine,
            letterDisclosure: letterDisclosure)))
    }

    /// `orchestrator` is explicit and **undefaulted** so the no-compiler host
    /// can be mounted off the same fixture with the store as the ONLY
    /// difference — and so a default could never quietly turn the run-button
    /// test into a test of a strip that was never drawn.
    private func mountPane(
        _ fx: Harness, scope: AnnotationScope,
        orchestrator: CompilerOrchestrator?, width: CGFloat = 320
    ) -> NSWindow {
        mount(AnyView(AnnotationsPane(
            document: fx.document,
            store: fx.store,
            documentStore: fx.documentStore,
            scope: .constant(scope),
            onTravel: { _ in },
            orchestrator: orchestrator,
            diagnostics: fx.diagnostics,
            onSetActivePass: { _, _ in })
            .environment(UserPreferences(
                defaults: UserDefaults(suiteName: "Cockpit-\(UUID())")!))),
            width: width)
    }

    /// `width` is 320 by default (this suite's usual column) and overridable —
    /// the kind-filter mismatch test widens it to 900pt so the toolbar's own
    /// `ViewThatFits` lands on the one-row TEXT variant
    /// (`AnnotationsQueueToolbarWidthTests`'s "roomy" measurement), because the
    /// icon fallback's `Image(systemName:)` labels are not asserted anywhere to
    /// read as their filter's word and a test built on that would be fragile.
    private func mount(_ view: AnyView, width: CGFloat = 320) -> NSWindow {
        let window = TestWindow.mount(view, size: CGSize(width: width, height: 700))
        windows.append(window)
        pump()
        return window
    }

    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Accessibility (mirrors DiagnosticsPaneTests' readers)

    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so SwiftUI "
                + "never built the tree this test reads")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    private func button(labelled label: String, in window: NSWindow) throws -> NSObject {
        var lastAll: [AnyObject] = []
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            lastAll = try axTree(in: window)
                .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            if let match = lastAll.first(
                where: { (axAttribute($0, "accessibilityLabel") as? String) == label }
            ) as? NSObject {
                return match
            }
            pump(0.05)
        }
        return try XCTUnwrap(
            lastAll.first { (axAttribute($0, "accessibilityLabel") as? String) == label }
                as? NSObject,
            "no button labelled \u{201C}\(label)\u{201D} reached the hosted view. "
            + "Buttons found: "
            + "\(lastAll.map { axAttribute($0, "accessibilityLabel") as? String ?? "nil" })")
    }

    /// The non-recording sibling, for a "must NOT be present" assertion.
    private func findButton(labelled label: String, in window: NSWindow) -> NSObject? {
        guard let tree = try? axTree(in: window) else { return nil }
        return tree
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .first { (axAttribute($0, "accessibilityLabel") as? String) == label } as? NSObject
    }

    /// **The roles a hosted SwiftUI `Menu` can arrive under.**
    ///
    /// A borderless-button `Menu` is **not** an `AXButton` — measured
    /// 2026-08-18 on macOS 26.6.1, both cockpit states report `AXMenuButton`
    /// ("AXMenuButton: Copyedit · Gould · round 1" and "AXMenuButton: Set a
    /// pass", beside the run row's two real `AXButton`s) — which is why this
    /// suite's `findButton` cannot see the lane picker and it needs a reader of
    /// its own. The set is deliberately wider than the one role observed: the
    /// claim is "this is a control, not a caption", and a future macOS spelling
    /// it `AXPopUpButton` should not turn that claim into a false red.
    private static let menuRoles: Set<String> = [
        "AXMenuButton", "AXPopUpButton", "AXButton",
    ]

    /// The lane picker, found by the EXACT label it draws in whichever state
    /// the cockpit is in. `nil` means the row reached the tree as a caption —
    /// the defect this fix is about.
    ///
    /// **Exact, and the equality is what makes it discriminating.** A
    /// `contains` reader here matched the run row's own "Run round" button
    /// against the lane's "round" and passed over a planted plain-`Text` lane
    /// (falsified 2026-08-18 — the plant went green until this became `==`).
    private func pressableLanePicker(
        labelled label: String, in window: NSWindow
    ) -> AnyObject? {
        guard let tree = try? axTree(in: window) else { return nil }
        return tree.first { element in
            guard let role = axAttribute(element, "accessibilityRole") as? String,
                  Self.menuRoles.contains(role) else { return false }
            let drawn = (axAttribute(element, "accessibilityLabel") as? String)
                ?? (axAttribute(element, "accessibilityValue") as? String) ?? ""
            return drawn == label
        }
    }

    /// Every pressable element's role and label — the failure message for the
    /// reader above, so a red test says what the tree actually held.
    private func pressableLabels(in window: NSWindow) -> [String] {
        guard let tree = try? axTree(in: window) else { return [] }
        return tree.compactMap { element in
            guard let role = axAttribute(element, "accessibilityRole") as? String,
                  Self.menuRoles.contains(role) else { return nil }
            let label = (axAttribute(element, "accessibilityLabel") as? String)
                ?? (axAttribute(element, "accessibilityValue") as? String) ?? "nil"
            return "\(role): \(label)"
        }
    }

    /// A `DisclosureGroup`'s own control, which arrives under its own role
    /// rather than any of `menuRoles`. Deliberately role-agnostic on the
    /// label: the claim is "this is pressable", not which AppKit spelling
    /// macOS picked for a disclosure this year.
    private func disclosureElement(
        labelled label: String, in window: NSWindow
    ) -> AnyObject? {
        guard let tree = try? axTree(in: window) else { return nil }
        return tree.first { element in
            guard let object = element as? NSObject,
                  object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
            else { return false }
            let drawn = (axAttribute(element, "accessibilityLabel") as? String)
                ?? (axAttribute(element, "accessibilityValue") as? String) ?? ""
            return drawn == label
        }
    }

    private func press(_ element: AnyObject) {
        _ = (element as? NSObject)?.perform(
            NSSelectorFromString("accessibilityPerformPress"))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func allLabels(in window: NSWindow) -> [String] {
        guard let tree = try? axTree(in: window) else { return [] }
        return tree.compactMap {
            axAttribute($0, "accessibilityValue") as? String
                ?? axAttribute($0, "accessibilityLabel") as? String
        }
    }

    // MARK: - Fixtures

    /// A minimal, otherwise-irrelevant annotation — the pure predicate test
    /// only cares that the pool array is non-empty.
    private static func fixtureAnnotation() -> Annotation {
        Annotation(
            id: "note-1", kind: .comment, paragraphId: "a1b2",
            body: "A note.", suggestedText: nil, priorText: nil,
            createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false)
    }

    private func makeRun(round: Int?, passId: String?, freshEyes: Bool?) -> CompilerRun {
        CompilerRun(id: "r-\(round ?? 0)", at: Date(), model: "test-model",
                    lastOpId: "op-1", deltaSummary: "1 new", intentSnapshot: nil,
                    passId: passId, round: round, freshEyes: freshEyes)
    }

    private func makeRecord(round: Int, passId: String?) -> RoundRecord {
        RoundRecord(runId: "r-\(round)", at: Date().addingTimeInterval(-600),
                    passId: passId, round: round, freshEyes: nil, fingerprints: [])
    }

    private static func questionAndReport(about paragraphId: String) -> String {
        """
        {"section":"conformance","checks":[]}
        {"section":"continuity","questions":[{"cites":"the fog","refs":["\(paragraphId)"],"question":"Has anyone said how long yet?"}]}
        {"section":"reader","reports":[{"kind":"belief","refs":["\(paragraphId)"],"report":"The reader stopped believing the fog."}]}
        {"section":"facts","candidates":[]}
        """
    }

    /// Wait for the orchestrator to record a failure. Bounded on
    /// `awaitOpenNotes`' idiom — the run resolves off its own task, so a
    /// straight-line read after the press would race it.
    private func awaitFailedRun(on orchestrator: CompilerOrchestrator) async {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if case .failed = orchestrator.runState { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Wait for the orchestrator to reach `.running` — used with
    /// `SpyRunner.nextEvent = nil`, which hangs `send` on a live continuation
    /// rather than answering synchronously, so the cancel test presses a real
    /// in-flight run and not a value set by hand.
    private func awaitRunning(on orchestrator: CompilerOrchestrator) async {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if case .running = orchestrator.runState { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Wait for the orchestrator to return to `.idle` — cancel's writer-caused
    /// mapping resolves off the runner's continuation, on a later tick.
    private func awaitIdleRun(on orchestrator: CompilerOrchestrator) async {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if orchestrator.runState == .idle { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func awaitOpenNotes(_ count: Int, on document: Document) async {
        let deadline = Date().addingTimeInterval(8)
        while document.annotations(filter: AnnotationFilter(statuses: [.open])).count < count,
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private struct Harness {
        let orchestrator: CompilerOrchestrator
        let diagnostics: DiagnosticsStore
        let document: Document
        let store: ProjectStore
        let documentStore: DocumentStore
        let runner: SpyRunner
        let root: URL
    }

    /// A real project on disk with one chapter open, and a compiler whose only
    /// substitution is the subprocess — production would spawn a billing
    /// `claude -p` here. Mirrors `CompilerRunCommandTests.makeLiveDocumentHarness`.
    private func makeHarness() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewRoundCockpit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let docPath = "manuscript/ch1.md"
        try "The fog came.\n".write(
            to: root.appendingPathComponent(docPath), atomically: true, encoding: .utf8)
        let chapter = StructureItem(id: "ch-1", title: "Chapter 1", type: .document,
                                    path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [chapter], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest)
            .write(to: root.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        store.documentStore = documentStore
        let document = try await Document.load(
            url: root.appendingPathComponent(docPath),
            device: "test-mac", session: "s", presenter: nil)
        documentStore.register(document: document, for: docPath)

        let device = DeviceSlug.make(from: "test-mac")
        let diagnostics = DiagnosticsStore(projectRoot: root, device: device)
        let declaredWorld = DeclaredWorldStore(projectRoot: root, device: device)
        let configURL = root.appendingPathComponent("compiler-mcp.json")
        let runner = SpyRunner()
        var environment = CompilerOrchestrator.Environment.production(
            store: store, documentStore: documentStore, projectURL: root,
            declaredWorld: declaredWorld,
            bible: BibleStore(projectRoot: root, device: device),
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "CockpitHarness-\(UUID())")!),
            onRunAcknowledged: { _ in })
        environment.writeMCPConfig = {
            try Data("{}".utf8).write(to: configURL, options: .atomic)
            return configURL
        }
        environment.makeRunner = { _, _ in runner }
        let orchestrator = CompilerOrchestrator()
        orchestrator.configure(environment: environment, diagnostics: diagnostics)

        return Harness(orchestrator: orchestrator, diagnostics: diagnostics,
                       document: document, store: store, documentStore: documentStore,
                       runner: runner, root: root)
    }

    /// A runner that answers what the test says. Mirrors
    /// `CompilerRunCommandTests.SpyRunner`.
    @MainActor
    final class SpyRunner: CompilerRunner {
        var isRunning = false
        var sessionEpoch = 1
        var nextEvent: CompilerRunEvent? = .resultText(#"{"section":"conformance","checks":[]}"#)
        private(set) var sendCount = 0
        private var held: CheckedContinuation<CompilerRunEvent, Never>?
        private var partialHandler: (@MainActor (String) -> Void)?

        func setPartialHandler(_ handler: (@MainActor (String) -> Void)?) {
            partialHandler = handler
        }

        func send(message: String, systemPreamble: String?) async -> CompilerRunEvent {
            sendCount += 1
            if let nextEvent { return nextEvent }
            isRunning = true
            return await withCheckedContinuation { held = $0 }
        }

        func release(_ event: CompilerRunEvent) {
            isRunning = false
            let continuation = held
            held = nil
            continuation?.resume(returning: event)
        }

        func cancelCurrentRun() {
            release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.cancelled)))
        }

        func shutdown() {
            release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.sessionShutDown)))
        }
    }

    // MARK: - Source access

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent("Maugham/\(relativePath)"),
            encoding: .utf8)
    }

    /// The text from `name` to the end of its brace-balanced body.
    private static func declaration(named name: String, in source: String) -> String? {
        guard let start = source.range(of: name) else { return nil }
        var depth = 0
        var index = start.lowerBound
        var seenOpen = false
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1; seenOpen = true }
            if character == "}" {
                depth -= 1
                if seenOpen && depth == 0 {
                    return String(source[start.lowerBound...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
