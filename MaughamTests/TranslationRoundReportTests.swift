import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The round report: what the author reads after a pipeline round**
/// (translation pipeline spec §8, Plan 4 Task 3).
///
/// A round is seven legs of machine work over the author's own prose in a
/// language they may not read. `TranslationRound` is the record it leaves; this
/// is where that record faces the writer, in Publish's centre column — the same
/// column the compiled book and the design gate show in, by the same rule
/// (`ProjectWindow.publishCentre` composes `subjectShowsAltitude`).
///
/// **Three instruments, for three different things.**
///
/// - **The rows and the copy.** `TranslationRoundReport` is a pure `enum` over
///   the record, so what a departure row SAYS — the source, the gloss, what the
///   translator did about it — is assertable with no window at all.
/// - **The routing.** `publishCentre` gained a round that outranks the design
///   proposal; the truth table lives in `DesignGateTests` beside the gate's own.
/// - **The surface.** Mounted and read off the accessibility tree, because two
///   of the contracts here are about what a writer can SEE: the six sections in
///   the spec's order, and — the sharp one — that **nothing target-language-only
///   is drawn collapsed**. The author is being asked to judge prose in a
///   language they do not read; what draws is their own words, the collator's
///   gloss and the reader's report, and the translation itself appears only
///   inside a row they open on purpose.
@MainActor
final class TranslationRoundReportTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // The parallel-worker fontd cold-start window (CLAUDE.md): this suite
        // mounts real prose through production typography.
        FontWarmup.ensure()
    }

    static func round() -> TranslationRound {
        var round = TranslationRound(number: 3, language: "es", docId: "doc-1",
                                     startedAt: Date(timeIntervalSince1970: 1_000))
        round.endedAt = Date(timeIntervalSince1970: 2_000)
        round.legs = TranslationRound.Leg.allCases.map { .init(leg: $0, status: .ran, counts: .init()) }
        round.leg2 = .init(verdict: "reads_as_translated", text: "Stiff in places.")
        round.leg4 = .init(verdict: "reads_as_native", text: "Better now.")
        round.collatorOverall = "Holds together."
        round.notes = [
            .init(id: "n1", leg: .read, author: "Ocampo", paragraphId: "a1b2", kind: "rhythm",
                  severity: "minor", text: "Limps.", outcome: .addressed(.init(
                    beforeRecordId: "b", before: "Llegó la niebla.", afterRecordId: "a", after: "La niebla llegó."))),
            .init(id: "n2", leg: .reread, author: "Ocampo", paragraphId: "c3d4", kind: "register",
                  severity: "major", text: "Too formal.", outcome: .declined(reason: "The brief asks for it.", annotationId: "ann-2"))
        ]
        round.departures = [
            .init(id: "d1", paragraphId: "a1b2", verdict: "drifted", kind: "omission", note: "Lost a clause.",
                  gloss: "The fog came.", outcome: .addressed(.init(beforeRecordId: "b", before: "x", afterRecordId: "a", after: "y"))),
            .init(id: "d2", paragraphId: "c3d4", verdict: "holds", kind: "rendering", note: "Split.",
                  gloss: "She shut it. Then left.", outcome: nil),
            .init(id: "d3", paragraphId: "e5f6", verdict: "drifted", kind: "addition", note: "Added.",
                  gloss: "He smiled warmly.", outcome: .declined(reason: "Needed for rhythm.", annotationId: nil))
        ]
        round.summary = "Two repairs, one stand."
        round.glossaryProposals = [.init(term: "fog", rendering: "niebla", reason: "consistency", adopted: false)]
        return round
    }

    func test_departureRowsCarryTheSourceTheGlossAndWhatTheTranslatorDid() {
        let rows = TranslationRoundReport.departureRows(Self.round(), sources: ["a1b2": "The fog came in."])
        XCTAssertEqual(rows.map(\.id), ["d1", "d2", "d3"])
        XCTAssertEqual(rows[0].source, "The fog came in.")
        XCTAssertNil(rows[1].source, "a paragraph the document no longer has draws no source")
        XCTAssertEqual(rows[0].gloss, "The fog came.")
        XCTAssertEqual(rows[0].outcomeLine, TranslationRoundReport.outcomeLine(.addressed(.init(
            beforeRecordId: "b", before: "x", afterRecordId: "a", after: "y"))))
        XCTAssertTrue(rows[0].outcomeLine?.lowercased().contains("rewrote") == true)
        XCTAssertNil(rows[1].outcomeLine, "a holds departure was never work for the translator")
        XCTAssertTrue(rows[2].outcomeLine?.contains("Needed for rhythm.") == true)
        XCTAssertFalse(rows[0].isDismissed)
    }

    /// **The author's "Fine" and the translator's rewrite are two facts, and a
    /// row carries both** (P4 Task 4's fix round). A dismissal used to be
    /// written into `outcome`, which erased the before/after of the very row it
    /// was pressed on; `dismissed` is now its own field and `outcome` is
    /// untouched, so the row still says what the translator did and still opens
    /// on the translation.
    func test_aDismissedRowKeepsWhatTheTranslatorDid() {
        var round = Self.round()
        round.departures[0].dismissed = true
        let rows = TranslationRoundReport.departureRows(round, sources: [:])
        XCTAssertTrue(rows[0].isDismissed)
        XCTAssertEqual(rows[0].before, "x")
        XCTAssertEqual(rows[0].after, "y")
        XCTAssertTrue(rows[0].outcomeLine?.lowercased().contains("rewrote") == true,
                      "the translator's sentence was replaced by the author's")
    }

    /// A `holds` departure the author settled has nothing the translator did to
    /// report, so the author's own act is what the row says happened to it.
    func test_aDismissedRowWithNoOutcomeSaysTheAuthorSettledIt() {
        var round = Self.round()
        round.departures[1].dismissed = true
        let rows = TranslationRoundReport.departureRows(round, sources: [:])
        XCTAssertTrue(rows[1].isDismissed)
        XCTAssertEqual(rows[1].outcomeLine, TranslationRoundReport.dismissedLine)
    }

    /// A round written before the split still draws as dismissed — the legacy
    /// `.dismissed` outcome is read, never written.
    func test_aLegacyDismissedOutcomeStillReadsAsDismissed() {
        var round = Self.round()
        round.departures[1].outcome = .dismissed
        let rows = TranslationRoundReport.departureRows(round, sources: [:])
        XCTAssertTrue(rows[1].isDismissed)
        XCTAssertEqual(rows[1].outcomeLine, TranslationRoundReport.dismissedLine)
    }

    func test_disagreementRowsAreTheDeclinedNotesAndDeparturesWithBothBylines() {
        let rows = TranslationRoundReport.disagreementRows(Self.round(), translatorName: "Cortázar", collatorName: "Borges")
        XCTAssertEqual(rows.map(\.id), ["n2", "d3"])
        XCTAssertEqual(rows[0].noteAuthor, "Ocampo")
        XCTAssertEqual(rows[0].rightVerbTitle, TranslationRoundReport.readersRightTitle)
        XCTAssertEqual(rows[1].noteAuthor, "Borges")
        XCTAssertEqual(rows[1].rightVerbTitle, TranslationRoundReport.collatorsRightTitle)
        XCTAssertEqual(rows[0].translatorName, "Cortázar")
        XCTAssertEqual(rows[0].annotationId, "ann-2")
        XCTAssertNil(rows[1].annotationId)
    }

    func test_theHeaderNamesTheRoundTheChapterAndTheEdition() {
        XCTAssertEqual(TranslationRoundReport.header(Self.round(), chapterTitle: "Chapter 1"),
                       "Round 3 \u{00b7} Chapter 1 \u{00b7} "
                       + TranslationReviewIndicator.displayLabel(forLanguageTag: "es"))
        XCTAssertTrue(TranslationRoundReport.header(Self.round(), chapterTitle: nil).contains("Round 3"))
    }

    func test_theCountsLineAndTheProvenance() {
        let line = TranslationRoundReport.countsLine(Self.round())
        XCTAssertTrue(line.contains("2 notes"), line)
        XCTAssertTrue(line.contains("3 departures"), line)
        XCTAssertTrue(line.contains("2 declined"), line)
        XCTAssertEqual(TranslationRoundReport.provenance(round: Self.round(), verb: "keep mine"), "round 3, keep mine")
    }

    /// **Nothing on the surface is target-language-only** (spec §8, §12): what
    /// draws by default is the record's author-language fields and the source;
    /// the translation's own text appears only inside a row the writer expands.
    func test_theCollapsedSurfaceNeverDrawsTheTranslationItself() async throws {
        let round = Self.round()
        let window = mount(round: round)
        let texts = try axTexts(in: window)
        for translated in ["Llegó la niebla.", "La niebla llegó."] {
            XCTAssertFalse(texts.contains { $0.contains(translated) }, "\(translated) drawn collapsed")
        }
        XCTAssertTrue(texts.contains { $0.contains("The fog came.") }, "the gloss is what the author judges by")
        XCTAssertTrue(texts.contains { $0.contains("Stiff in places.") })
        XCTAssertTrue(texts.contains { $0.contains("Better now.") })
        XCTAssertTrue(texts.contains { $0.contains("Two repairs, one stand.") })
    }

    /// The six sections, in the spec's order, each by its heading.
    func test_theSixSectionsAreDrawnInOrder() async throws {
        let window = mount(round: Self.round())
        let texts = try axTexts(in: window)
        let headings = [TranslationRoundReport.readerHeading, TranslationRoundReport.changedHeading,
                        TranslationRoundReport.disagreementsHeading, TranslationRoundReport.questionsHeading,
                        TranslationRoundReport.proposalsHeading, TranslationRoundReport.summaryHeading]
        let positions = headings.map { heading in texts.firstIndex { $0 == heading } }
        XCTAssertEqual(positions.compactMap { $0 }.count, 6, "\(texts)")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
    }

    /// Every verb reaches the action it names with the row's own ids.
    ///
    /// **Pressed one at a time, each awaited before the next** (the fix
    /// round's own correction): `outstanding` is now armed synchronously on
    /// the press, before the `Task` exists, so the container disables itself
    /// on the very first press rather than a turn later — three presses
    /// fired back to back with no wait between them would have the second and
    /// third land on a disabled container and never reach their actions.
    func test_theVerbsReachTheActionsWithTheirRowsIds() async throws {
        let box = VerbBox()
        var actions = TranslationRoundActions()
        actions.dismiss = { _, id in box.dismissed.append(id); return .done(nil, "ok") }
        actions.translatorsRight = { _, id in box.rights.append(id); return .done(nil, "ok") }
        actions.adopt = { _, i in box.adopted.append(i); return .done(nil, "ok") }
        let window = mount(round: Self.round(), actions: actions)
        press(try axButtons(labelled: TranslationRoundReport.fineLabel(id: "d2"), in: window)[0])
        _ = await pumpUntil(deadline: 3) { box.dismissed.count == 1 }
        press(try axButtons(labelled: TranslationRoundReport.translatorsRightLabel(id: "n2"), in: window)[0])
        _ = await pumpUntil(deadline: 3) { box.rights.count == 1 }
        press(try axButtons(labelled: TranslationRoundReport.adoptLabel(index: 0), in: window)[0])
        _ = await pumpUntil(deadline: 3) { box.adopted.count == 1 }
        XCTAssertEqual(box.dismissed, ["d2"])
        XCTAssertEqual(box.rights, ["ann-2"])
        XCTAssertEqual(box.adopted, [0])
    }

    /// **A settled row stops offering the verb that settled it.**
    /// `RulingPerformer.rule` does not dedupe, so a second press of Reader's
    /// right (or Keep mine, or Make it a rule) after the first has answered
    /// `.done` would file a second, identical dated ruling — this is the fix
    /// round's guard against that, read off the accessibility tree: the
    /// button is gone and the row's outcome sentence stands in its place.
    func test_aSettledDisagreementOffersItsRightVerbOnlyOnce() async throws {
        let box = VerbBox()
        var actions = TranslationRoundActions()
        actions.readersRight = { _, annotationId, _, _, _ in
            box.rights.append(annotationId)
            return .done(nil, "ok")
        }
        let window = mount(round: Self.round(), actions: actions)
        let label = TranslationRoundReport.rightLabel(
            id: "n2", verb: TranslationRoundReport.readersRightTitle)
        press(try axButtons(labelled: label, in: window)[0])
        let ran = await pumpUntil(deadline: 3) { box.rights.count == 1 }
        XCTAssertTrue(ran)
        XCTAssertEqual(try axButtons(labelled: label, in: window).count, 0,
                      "the right verb must not still be offered once it has run")
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains(TranslationRoundReport.ruledOutcomeLine) },
                      "\(texts)")
        // Nothing left to press a second time — the count stays at one.
        XCTAssertEqual(box.rights, ["ann-2"])
    }

    /// A disagreement whose query was never minted offers no Translator's right
    /// — there is nothing to reject — and says so.
    ///
    /// **And it names the verb the row actually has.** `d3` is a declined
    /// DEPARTURE, so the right that still applies is the COLLATOR's; the
    /// sentence hardcoded the reader's until the first review of this task, and
    /// half the rows it drew on were pointing at a button they do not have.
    func test_aDisagreementWithNoQueryOffersNoTranslatorsRight() async throws {
        let window = mount(round: Self.round())
        XCTAssertEqual(try axButtons(labelled: TranslationRoundReport.translatorsRightLabel(id: "d3"), in: window).count, 0)
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains {
            $0.contains(TranslationRoundReport.noQueryForThisNote(
                rightVerb: TranslationRoundReport.collatorsRightTitle))
        }, "\(texts)")
        XCTAssertFalse(texts.contains {
            $0.contains(TranslationRoundReport.noQueryForThisNote(
                rightVerb: TranslationRoundReport.readersRightTitle))
        }, "no row here offers the reader's right")
    }

    /// …and the mirror: a declined READER's note with no query says the
    /// reader's, on the same surface, from the same static.
    func test_aDeclinedReadersNoteWithNoQueryNamesTheReadersRight() async throws {
        var round = Self.round()
        round.notes[1].outcome = .declined(reason: "The brief asks for it.",
                                           annotationId: nil)
        let window = mount(round: round)
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains {
            $0.contains(TranslationRoundReport.noQueryForThisNote(
                rightVerb: TranslationRoundReport.readersRightTitle))
        }, "\(texts)")
    }

    /// **A skipped FIRST read is not the second read's good news.**
    ///
    /// The two silences are opposite facts — the second read is skipped when the
    /// first found nothing to fix, the first is skipped when nothing reached the
    /// reader at all — and one sentence for both put "nothing changed after the
    /// first" in the column for a read that never happened.
    func test_aSkippedFirstReadNeverBorrowsTheSecondReadsSentence() async throws {
        var round = Self.round()
        round.leg2 = nil
        round.leg4 = nil
        round.legs = [.init(leg: .translate, status: .ran, counts: .init()),
                      .init(leg: .read, status: .skipped, reason: "Nothing to read.")]
        XCTAssertEqual(
            TranslationRoundReport.readerColumn(
                nil, leg: .read,
                legRecord: TranslationRoundReport.legRecord(round, .read)).text,
            TranslationRoundReport.firstReadSkippedLine)
        XCTAssertEqual(
            TranslationRoundReport.readerColumn(
                nil, leg: .reread,
                legRecord: TranslationRoundReport.legRecord(round, .reread)).text,
            TranslationRoundReport.roundStoppedLine(before: .reread),
            "a leg the round never recorded is a round that stopped, not a skip")

        let window = mount(round: round)
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0 == TranslationRoundReport.firstReadSkippedLine },
                      "\(texts)")
        XCTAssertFalse(texts.contains { $0.contains(TranslationRoundReport.nothingChangedLine) },
                       "the second read's sentence has no business in this round")
    }

    /// A refused verb lands in the report's one notice slot, in its own words.
    func test_aRefusalIsSaidInTheReportsNoticeSlot() async throws {
        var actions = TranslationRoundActions()
        actions.dismiss = { _, _ in .refused("The ledger is read-only today.") }
        let window = mount(round: Self.round(), actions: actions)
        press(try axButtons(labelled: TranslationRoundReport.fineLabel(id: "d2"), in: window)[0])
        let shown = await pumpUntil(deadline: 3) {
            (try? self.axTexts(in: window).contains { $0.contains("read-only today") }) == true
        }
        XCTAssertTrue(shown)
    }

    /// A verb's updated record is written back to the window only when it is
    /// still the round on screen — `publishSelection`'s rule for the gate.
    func test_theWriteBackOnlyLandsOnTheRoundStillOnScreen() {
        var updated = Self.round()
        updated.departures[1].dismissed = true
        var other = Self.round()
        other = TranslationRound(number: 4, language: "es", docId: "doc-1", startedAt: Date())
        XCTAssertEqual(ProjectWindow.publishSelection(after: updated, showing: Self.round()), updated)
        XCTAssertEqual(ProjectWindow.publishSelection(after: updated, showing: other), other)
        XCTAssertNil(ProjectWindow.publishSelection(after: updated, showing: nil))
    }

    // MARK: - Fixture

    /// What the three verb closures recorded. A reference box rather than three
    /// captured `var`s: the closures are stored on a value that outlives the
    /// method's frame and run from a `Task`, and captured locals mutated from
    /// there are exactly the shape Swift's concurrency checking will one day
    /// refuse.
    private final class VerbBox {
        var dismissed: [String] = []
        var rights: [String] = []
        var adopted: [Int] = []
    }

    private var windows: [NSWindow] = []
    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
    }

    private func mount(round: TranslationRound,
                       actions: TranslationRoundActions = TranslationRoundActions()) -> NSWindow {
        let window: NSWindow = TestWindow.mount(
            AnyView(TranslationRoundReportView(
                round: round, chapterTitle: "Chapter 1",
                sources: ["a1b2": "The fog came in.", "c3d4": "She closed the door."],
                queries: [], translatorName: "Cortázar", collatorName: "Borges",
                actions: actions, onClose: {}, onRoundChanged: { _ in }, onReveal: { _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: 900, height: 900))
        windows.append(window)
        pump(0.2)
        return window
    }
}
