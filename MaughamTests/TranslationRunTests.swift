import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// **What the desk's Run button promises, refuses and reports** (publish-department
/// P4 Task 3).
///
/// Task 2 gave every edition a row and a door; this suite is about the verb. Three
/// promises are ledgered in the plan's Global Constraints and every test here is
/// one of them:
///
/// 1. **A run is for the window's own open chapter** (Constraint 1). The desk is a
///    project-level surface but a translation round is a DOCUMENT's; the button is
///    pressable only while the tree names a manuscript document the window has
///    actually opened, and when it is not, the reason is on screen rather than in
///    a dead control's silence.
/// 2. **Every refused or abandoned click gets words** (Constraint 2). A second run
///    while a session is warm, and a language tag the write pipeline will not
///    accept, are the two ways a click reaches the orchestrator and produces
///    nothing; both are answered here before the click gets that far. The third
///    way — the briefing gather answering `nil` — is *closed by Constraint 1's own
///    gate*, and `test_theBriefingAbandonIsClosedByTheOpenDocumentGate` is what
///    says so rather than a comment claiming it.
/// 3. **A finished run reports itself**: what landed, what was asked, what was
///    refused and which paragraphs the refusal was about.
///
/// **Almost none of this needs a window.** The decisions are pure statics on
/// `TranslationRunState` and `TranslationRunTarget`, so the truth tables are driven
/// from literals; the mounted tests at the end are only about a writer being able
/// to see and press what the tables decide.
@MainActor
final class TranslationRunTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // The parallel-worker fontd cold-start window (CLAUDE.md): this suite
        // mounts real text through production typography.
        FontWarmup.ensure()
    }

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
    }

    // MARK: - Constraint 1: which document a run is for

    private static let structure = [
        StructureItem(id: "grp", title: "Part One", type: .group, path: nil,
                      children: [
                        StructureItem(id: "doc-2", title: "Chapter 2",
                                      type: .document, path: "manuscript/c2.md"),
                      ]),
        StructureItem(id: "doc-1", title: "Chapter 1", type: .document,
                      path: "manuscript/c1.md"),
    ]

    /// **The whole truth table of what the tree can name**, and only one row of it
    /// is a run.
    ///
    /// The desk sits in the right-hand column of a window whose left column can
    /// name the project, a group, a research item, a chapter, or nothing at all. A
    /// translation round is a document's, so five of those six are refusals — and
    /// each one is a refusal with a sentence, never a button that does nothing.
    func test_onlyAnOpenManuscriptDocumentIsSomethingToTranslate() {
        let open: (String) -> Bool = { $0 == "manuscript/c1.md" }

        XCTAssertEqual(
            TranslationRunTarget.resolve(subject: .item("doc-1"),
                                        structure: Self.structure, isOpen: open),
            .ready(docId: "doc-1", title: "Chapter 1"),
            "the tree names an open chapter — that is the run's document")

        for subject: BinderSubject? in [nil, .project, .item("grp"),
                                        .research("r-1"), .item("doc-2"),
                                        .item("nonesuch")] {
            let target = TranslationRunTarget.resolve(
                subject: subject, structure: Self.structure, isOpen: open)
            XCTAssertNil(target.docId,
                         "\(String(describing: subject)) is not a document a round "
                         + "can be run for")
            XCTAssertFalse(target.reason?.isEmpty ?? true,
                           "\(String(describing: subject)) refuses without saying "
                           + "why — a dead control (RULING-35)")
        }
    }

    /// **A document the window has not opened is not a target**, which is what the
    /// `isOpen` half of the resolution is for.
    ///
    /// The disable experiment: drop the openness test and `doc-2` — a real chapter
    /// of this manifest, merely closed — resolves `.ready`, and the run reaches an
    /// orchestrator whose briefing would gather against a document nothing in this
    /// window is holding.
    func test_aChapterTheWindowHasNotOpenedIsNotATarget() {
        let closed = TranslationRunTarget.resolve(
            subject: .item("doc-2"), structure: Self.structure, isOpen: { _ in false })
        XCTAssertNil(closed.docId)

        let opened = TranslationRunTarget.resolve(
            subject: .item("doc-2"), structure: Self.structure,
            isOpen: { $0 == "manuscript/c2.md" })
        XCTAssertEqual(opened, .ready(docId: "doc-2", title: "Chapter 2"),
                       "…and the same chapter IS one once the window holds it")
    }

    /// The refusal tells the writer what to do, in the words the plan's constraint
    /// names. A sentence that only reported the state ("no document selected")
    /// would be a diagnosis where an instruction belongs.
    func test_theRefusalSaysWhatToDoAboutIt() {
        let words = TranslationRunTarget.openAChapter.lowercased()
        XCTAssertTrue(words.contains("open"), TranslationRunTarget.openAChapter)
        XCTAssertTrue(words.contains("chapter"), TranslationRunTarget.openAChapter)
    }

    // MARK: - The run state, scoped to one edition of one chapter

    /// **A run names a PAIR, and the desk draws a row per language**, so a phase
    /// scoped to the document alone would paint every edition of that chapter with
    /// one round's progress.
    ///
    /// The disable experiment is the sharp one: drop `language` from the `where`
    /// and the French row reports "Translating 4 paragraphs…" for a Spanish round.
    func test_thePhaseBelongsToOneLanguageOfOneDocument() {
        let running = TranslatorOrchestrator.RunState.running(
            docId: "doc-1", language: "es", translating: 4)
        let target = TranslationRunTarget.ready(docId: "doc-1", title: "Chapter 1")

        XCTAssertEqual(state("es", target: target, runState: running).phase,
                       .running(.translating(4)))
        XCTAssertEqual(state("fr", target: target, runState: running).phase, .idle,
                       "another edition of the same chapter is not this round")
        XCTAssertEqual(
            state("es", target: .ready(docId: "doc-2", title: "Chapter 2"),
                  runState: running).phase,
            .idle,
            "…and the same edition of another chapter is not this round either")
    }

    /// **The pipeline's leg is what the row draws**, scoped by LANGUAGE alone:
    /// a book queue walks chapters the window is not on, and a row that went
    /// idle whenever the queue left the open chapter would say nothing for
    /// eleven of twelve rounds.
    func test_aPipelineLegIsDrawnOnItsLanguagesRowWhateverChapterTheWindowIsOn() {
        let state = TranslationRunState.resolve(
            language: "es",
            target: .ready(docId: "doc-1", title: "Chapter 1"),
            session: .busy(language: "es"),
            runState: .idle, lastRun: nil,
            pipeline: .running(docId: "doc-9", language: "es", leg: .read,
                               book: .init(position: 4, count: 12)))
        XCTAssertEqual(state.phase,
                       .running(.leg(.read, book: .init(position: 4, count: 12))))
        XCTAssertEqual(state.statusLine, TranslationRunState.legLine(
            .read, book: .init(position: 4, count: 12)))
        XCTAssertTrue(state.statusLine?.contains("4 of 12") == true)
        XCTAssertTrue(state.statusLine?.contains("reading") == true)

        let french = TranslationRunState.resolve(
            language: "fr",
            target: .ready(docId: "doc-1", title: "Chapter 1"),
            session: .busy(language: "es"),
            runState: .idle, lastRun: nil,
            pipeline: .running(docId: "doc-1", language: "es", leg: .read, book: nil))
        XCTAssertEqual(french.phase, .idle, "a Spanish leg is not the French row's")
    }

    /// **A bare translator round keeps its own count line** — the phase the
    /// probe mounts still produce, unchanged in words.
    func test_aBareTranslatorRoundStillSaysHowManyParagraphs() {
        let state = TranslationRunState.resolve(
            language: "es",
            target: .ready(docId: "doc-1", title: "Chapter 1"),
            session: .busy(language: "es"),
            runState: .running(docId: "doc-1", language: "es", translating: 4),
            lastRun: nil)
        XCTAssertEqual(state.phase, .running(.translating(4)))
        XCTAssertEqual(state.statusLine, TranslationRunState.translating(4))
    }

    /// **An idle row with a round says the round, not the translator's own
    /// summary.** The log records every translator LEG's summary, so after a
    /// seven-leg round its newest entry is leg 7's "2 paragraphs translated" —
    /// a sentence about a repair, drawn as if it were the round.
    func test_theRoundLineOutranksTheTranslatorsOwnSummaryWhenARoundExists() {
        var round = TranslationRound(number: 3, language: "es", docId: "doc-1",
                                     startedAt: Date(timeIntervalSinceNow: -300))
        round.endedAt = Date(timeIntervalSinceNow: -120)
        round.legs = TranslationRound.Leg.allCases.map { .init(leg: $0, status: .skipped, reason: "x") }
        let summary = TranslatorOrchestrator.RunSummary(
            runId: "r", docId: "doc-1", language: "es", at: Date(),
            outcome: .ingested(.init(entriesWritten: 2, queriesMinted: 0)))
        let now = Date()
        let state = TranslationRunState.resolve(
            language: "es", target: .ready(docId: "doc-1", title: "Chapter 1"),
            session: .free, runState: .idle, lastRun: summary,
            latestRound: round, trend: [6, 4, 1], now: now)
        XCTAssertEqual(state.statusLine, TranslationRunState.roundLine(round, now: now))
        XCTAssertTrue(state.statusLine?.hasPrefix("Round 3") == true)
        XCTAssertTrue(state.statusLine?.contains("2m ago") == true)
        XCTAssertTrue(state.offersShow)

        let none = TranslationRunState.resolve(
            language: "es", target: .ready(docId: "doc-1", title: "Chapter 1"),
            session: .free, runState: .idle, lastRun: summary)
        XCTAssertEqual(none.statusLine, TranslationRunState.reportLine(summary.outcome),
                       "with no round the translator's summary is still the idle line")
        XCTAssertFalse(none.offersShow)
    }

    func test_aStoppedRoundSaysWhereItStopped() {
        var round = TranslationRound(number: 2, language: "es", docId: "doc-1", startedAt: Date())
        round.endedAt = Date()
        round.legs = [.init(leg: .translate, status: .ran, counts: .init(entries: 1)),
                      .init(leg: .read, status: .cancelled)]
        let line = TranslationRunState.roundLine(round, now: Date())
        XCTAssertTrue(line.contains("Round 2"))
        XCTAssertTrue(line.contains("cancelled"), line)
        XCTAssertTrue(line.contains("reading"), line)

        round.legs[1] = .init(leg: .read, status: .failed, reason: "The reader died.")
        let failed = TranslationRunState.roundLine(round, now: Date())
        XCTAssertTrue(failed.contains("failed"), failed)
        XCTAssertTrue(failed.contains("The reader died."), "the failure's own sentence rides the line")
    }

    func test_agoIsCoarseAndNeverNegative() {
        let now = Date()
        XCTAssertEqual(TranslationRunState.ago(from: now.addingTimeInterval(-5), to: now), "just now")
        XCTAssertEqual(TranslationRunState.ago(from: now.addingTimeInterval(-125), to: now), "2m ago")
        XCTAssertEqual(TranslationRunState.ago(from: now.addingTimeInterval(-7200), to: now), "2h ago")
        XCTAssertEqual(TranslationRunState.ago(from: now.addingTimeInterval(-3 * 86400), to: now), "3d ago")
        XCTAssertEqual(TranslationRunState.ago(from: now.addingTimeInterval(60), to: now), "just now",
                       "a clock skewed into the future is 'just now', not '-1m ago'")
    }

    /// **Pre-flight and trend share one detail line** (spec §8: they share the
    /// row's slot rather than adding a line each), and the line is absent when
    /// neither has anything to say.
    func test_theDetailLineCarriesPreflightAndTrendAndIsAbsentWithNeither() {
        XCTAssertEqual(TranslationRunState.preflightLine(.words(1200)), "7 legs · ~1,200 words briefed")
        XCTAssertNil(TranslationRunState.preflightLine(nil))
        // **A refusal takes the figure's slot and names the file** (P2a D0,
        // fix round 1): the row says why there is no number, rather than
        // dropping the clause and leaving the writer to guess.
        XCTAssertEqual(
            TranslationRunState.preflightLine(.unreadable("“c1.es.maca-1234.jsonl” can't be read.")),
            "“c1.es.maca-1234.jsonl” can't be read.")
        XCTAssertEqual(TranslationRunState.trendLine([6, 4, 1]), "notes per round 6 → 4 → 1")
        XCTAssertEqual(TranslationRunState.trendLine([4]), "notes per round 4")
        XCTAssertNil(TranslationRunState.trendLine([]))

        var state = TranslationRunState()
        XCTAssertNil(state.detailLine)
        state.chapterPreflight = .words(1200)
        state.trend = [6, 4, 1]
        XCTAssertEqual(state.detailLine, "7 legs · ~1,200 words briefed · notes per round 6 → 4 → 1")
        state.phase = .running(.leg(.read, book: nil))
        XCTAssertNil(state.detailLine, "a running row's detail is its leg; the pre-flight is for a click that has not happened")
    }

    /// **Run Whole Book needs no open chapter** — the book is the desk's own
    /// set — but it refuses while a session is busy and when the set is empty.
    func test_theBookVerbRefusesOnlyForBusyAndForAnEmptyBook() {
        let noChapter = TranslationRunState.resolve(
            language: "es", target: .unavailable(TranslationRunTarget.openAChapter),
            session: .free, runState: .idle, lastRun: nil, bookDocumentCount: 12)
        XCTAssertNil(noChapter.bookRefusal)
        XCTAssertTrue(noChapter.canRunBook)
        XCTAssertFalse(noChapter.canRun, "…while the chapter Run still refuses")

        let busy = TranslationRunState.resolve(
            language: "es", target: .unavailable(TranslationRunTarget.openAChapter),
            session: .busy(language: "fr"), runState: .idle, lastRun: nil, bookDocumentCount: 12)
        XCTAssertEqual(busy.bookRefusal, TranslationRunState.busyReason(language: "fr"))

        let empty = TranslationRunState.resolve(
            language: "es", target: .unavailable(TranslationRunTarget.openAChapter),
            session: .free, runState: .idle, lastRun: nil, bookDocumentCount: 0)
        XCTAssertEqual(empty.bookRefusal, TranslationRunState.nothingInTheBook)
    }

    /// The two endings a row draws for itself, scoped the same way.
    func test_aRoundThatEndedSaysWhichEditionItEnded() {
        let target = TranslationRunTarget.ready(docId: "doc-1", title: "Chapter 1")
        let died = TranslatorOrchestrator.RunState.failed(
            docId: "doc-1", language: "es", failure: .run(.timedOut()), at: Date())
        XCTAssertEqual(state("es", target: target, runState: died).phase,
                       .failed(.run(.timedOut())))
        XCTAssertEqual(state("fr", target: target, runState: died).phase, .idle,
                       "a red line across the French row for a Spanish death is a lie")

        let nothing = TranslatorOrchestrator.RunState.nothingToTranslate(
            docId: "doc-1", language: "es", at: Date())
        XCTAssertEqual(state("es", target: target, runState: nothing).phase,
                       .nothingToTranslate)
    }

    /// **"Checked, everything is fresh" must not render as "the button did
    /// nothing"** — the reason `nothingToTranslate` is a state of its own on the
    /// orchestrator, carried through to a line the writer can read.
    func test_aRoundWithNothingToDoSaysSoRatherThanGoingQuiet() {
        let target = TranslationRunTarget.ready(docId: "doc-1", title: "Chapter 1")
        let line = state("es", target: target,
                         runState: .nothingToTranslate(docId: "doc-1", language: "es",
                                                       at: Date())).statusLine
        XCTAssertEqual(line, TranslationRunState.nothingToTranslateLine)
        XCTAssertFalse(TranslationRunState.nothingToTranslateLine.isEmpty)
    }

    // MARK: - Constraint 2: a refused click gets words

    /// **One session, so every Run refuses while one is warm** — and the refusal
    /// names the edition being translated, because a writer with four rows needs to
    /// know which one is holding the session.
    func test_everyRowRefusesWhileTheOneSessionIsBusyAndSaysWhoHasIt() {
        let target = TranslationRunTarget.ready(docId: "doc-1", title: "Chapter 1")
        let busy = TranslationRunSession.busy(language: "es")

        for language in ["es", "fr"] {
            let row = state(language, target: target, session: busy)
            XCTAssertFalse(row.canRun,
                           "\(language)'s Run must refuse — there is one session")
            let refusal = try? XCTUnwrap(row.refusal)
            XCTAssertTrue(refusal?.contains(
                TranslationReviewIndicator.displayLabel(forLanguageTag: "es")) ?? false,
                "the refusal must name the edition holding the session: "
                + "\(row.refusal ?? "nil")")
        }
    }

    /// **The click is refused before the send, too.** `isPreparingRun` counts as
    /// running while the identity is minted and the round gathered, and `runState`
    /// names no pair yet — so the desk must still refuse, in words, without being
    /// able to say which edition.
    func test_theWindowBetweenTheClickAndTheSendRefusesTheSecondClick() {
        let target = TranslationRunTarget.ready(docId: "doc-1", title: "Chapter 1")
        let preparing = TranslationRunSession.read(runState: .idle, isRunning: true)
        XCTAssertEqual(preparing, .busy(language: nil),
                       "a run under way that has not named its pair is still a run")

        let row = state("es", target: target, session: preparing)
        XCTAssertFalse(row.canRun)
        XCTAssertFalse(row.refusal?.isEmpty ?? true,
                       "…and refusing without words is the silent no-op "
                       + "Constraint 2 forbids")
    }

    /// The session reading itself: idle is free, a named run is busy with its
    /// language.
    func test_theSessionReadsBusyFromTheOrchestratorsOwnState() {
        XCTAssertEqual(TranslationRunSession.read(runState: .idle, isRunning: false),
                       .free)
        XCTAssertEqual(
            TranslationRunSession.read(
                runState: .running(docId: "d", language: "pt-BR", translating: 2),
                isRunning: true),
            .busy(language: "pt-BR"))
        XCTAssertEqual(
            TranslationRunSession.read(
                runState: .failed(docId: "d", language: "es",
                                  failure: .run(.timedOut()), at: Date()),
                isRunning: false),
            .free,
            "a round that ended badly is not a session still holding the desk")
    }

    /// The one-round-at-a-time gate is a PIPELINE gate now (spec §5): a cold
    /// leg holds no translator session, so the translator reads free while a
    /// reader is out — and every row must still refuse, naming the edition.
    func test_thePipelineHoldsTheGateEvenWhileTheTranslatorIsFree() {
        let busy = TranslationRunSession.read(
            runState: .idle, isRunning: false,
            pipeline: .running(docId: "doc-1", language: "fr", leg: .read, book: nil))
        XCTAssertEqual(busy, .busy(language: "fr"))
        XCTAssertEqual(TranslationRunSession.read(runState: .idle, isRunning: false, pipeline: .idle), .free)
        XCTAssertEqual(
            TranslationRunState.refusal(target: .ready(docId: "doc-1", title: "One"), session: busy),
            TranslationRunState.busyReason(language: "fr"))
    }

    /// **A language tag the write pipeline will not accept is refused at the desk,
    /// in words** — the malformed-tag arm of Constraint 2.
    ///
    /// It is refused by CALLING the pipeline's own gate rather than by a second
    /// spelling of what a language tag is: the same function
    /// `TranslatorEnvironment`'s briefing calls before it spends a session. Left to
    /// the orchestrator the click abandons silently — `briefRound` answers `nil`,
    /// `abandon()` sets no state and emits no summary — and the writer presses a
    /// button that does nothing at all.
    func test_aTagThePipelineWillNotWriteIsRefusedAtTheDeskInWords() {
        let target = TranslationRunTarget.ready(docId: "doc-1", title: "Chapter 1")

        for tag in ["es", "pt-br", "fr"] {
            XCTAssertNil(
                TranslationRunState.preflight(language: tag, target: target,
                                             session: .free),
                "\(tag) is a tag the pipeline writes; the click must go through")
        }
        // **`pt-BR` is in this list rather than the one above**, and finding that
        // out is what this test is worth on its own: `isValidLanguageTag` is
        // lowercase BCP-47-ish, so an outside session that stamped a query
        // \u{201C}pt-BR\u{201D} leaves a row on the desk that no round can ever
        // be run for. Without the refusal the writer presses Run on it forever.
        for tag in ["", "not a tag!", "pt-BR",
                    "esperanto-in-a-very-long-subtag"] {
            let refusal = TranslationRunState.preflight(
                language: tag, target: target, session: .free)
            // The premise, so this cannot pass because the tag was fine:
            XCTAssertThrowsError(try TranslationWritePipeline.validate(language: tag),
                                 "premise: the pipeline refuses \u{201C}\(tag)\u{201D}")
            XCTAssertFalse(refusal?.isEmpty ?? true,
                           "\u{201C}\(tag)\u{201D} was allowed to reach the "
                           + "orchestrator, where it abandons in silence")
        }
    }

    /// The refusals stack in the order the writer needs them: a session in flight
    /// outranks a subject that could not be run anyway, because a run under way is
    /// the fact that changes what pressing anything will do.
    func test_aRunInFlightOutranksASubjectThatCouldNotBeRun() {
        let refusal = TranslationRunState.preflight(
            language: "es",
            target: .unavailable(TranslationRunTarget.openAChapter),
            session: .busy(language: "fr"))
        XCTAssertEqual(refusal,
                       TranslationRunState.busyReason(language: "fr"))
    }

    /// **The third abandon arm is closed by Constraint 1's gate, not by a message.**
    ///
    /// `TranslatorEnvironment`'s briefing answers `nil` in two cases, and the
    /// orchestrator abandons silently for both. One is the language tag, refused
    /// above. The other is a document whose current paragraphs cannot be resolved —
    /// and `currentParagraphState` resolves an OPEN document straight off the
    /// registry, which is exactly what `TranslationRunTarget.ready` guarantees. So
    /// the arm is unreachable from the desk rather than unhandled by it.
    ///
    /// This is the test rather than the sentence, because the claim is about
    /// another file's behaviour: if `currentParagraphState` ever grows a way to
    /// refuse an open document, the desk needs a message and this goes red.
    func test_theBriefingAbandonIsClosedByTheOpenDocumentGate() async throws {
        let h = try await makeProject()

        let target = TranslationRunTarget.resolve(
            subject: .item("doc-1"), structure: h.projectStore.manifest.structure,
            isOpen: { h.documentStore.document(for: $0) != nil })
        let docId = try XCTUnwrap(target.docId,
                                  "premise: the fixture's chapter is open")

        let state = try currentParagraphState(
            documentId: docId, store: h.projectStore,
            documentStore: h.documentStore, projectURL: h.projectURL)
        XCTAssertFalse(state.sequence.isEmpty,
                       "an open document the desk offers as a target must have "
                       + "paragraphs for the round to gather — otherwise the click "
                       + "abandons where nothing can say so")

        await h.documentStore.close()
    }

    // MARK: - What a finished run reports

    /// **A round that landed says what landed and what it asked.** Both halves,
    /// because a translator's questions are the other product of the round and a
    /// line naming only the paragraphs would send the writer to the queue by luck.
    func test_theReportSaysWhatLandedAndWhatWasAsked() {
        let line = try? XCTUnwrap(TranslationRunState.reportLine(
            .ingested(.init(entriesWritten: 12, queriesMinted: 2))))
        XCTAssertTrue(line?.contains("12") ?? false, line ?? "nil")
        XCTAssertTrue(line?.contains("2") ?? false, line ?? "nil")

        let quiet = try? XCTUnwrap(TranslationRunState.reportLine(
            .ingested(.init(entriesWritten: 7, queriesMinted: 0))))
        XCTAssertTrue(quiet?.contains("7") ?? false, quiet ?? "nil")
        XCTAssertFalse(quiet?.contains("0 ") ?? true,
                       "a round that asked nothing must not report \u{201C}0 "
                       + "questions\u{201D} \u{2014} a figure said every time is a "
                       + "figure the writer stops reading: \(quiet ?? "nil")")
    }

    /// **Construct warnings ride the report** (spec §6: advisory, non-blocking).
    /// They are the pipeline's own sentences, so they are carried rather than
    /// counted — "2 warnings" tells a writer nothing they can act on.
    func test_constructWarningsRideTheReportInTheirOwnWords() {
        let warning = "¶ab12: the translation has 3 constructs and the source has 1"
        let line = try? XCTUnwrap(TranslationRunState.reportLine(
            .ingested(.init(entriesWritten: 4, queriesMinted: 0,
                            warnings: [warning]))))
        XCTAssertTrue(line?.contains(warning) ?? false,
                      "the warning's own words must reach the desk: \(line ?? "nil")")
    }

    /// **A mid-run-edit rejection reaches the desk naming its paragraphs.**
    ///
    /// The sentence is `TranslatorEnvironment`'s — it lists the ids and says why
    /// nothing was written — and the desk's job is to carry it whole. A row that
    /// summarised it ("the round was rejected") would take away the only thing the
    /// writer can act on, which is *which* paragraphs they changed under it.
    func test_aMidRunEditRejectionArrivesWithItsParagraphsNamed() {
        let rejection = "paragraphs edited while this round was running: ab12, cd34 "
            + "\u{2014} nothing was written, because the translation would be of "
            + "text you have since changed. Run the translation again to pick up "
            + "the new wording."

        XCTAssertEqual(
            TranslationRunState.reportLine(.ingested(.init(rejection: rejection))),
            rejection,
            "the report carries the pipeline's sentence rather than a summary of it")

        // …and the same sentence arriving as the run STATE (which is how the
        // orchestrator surfaces it) reads the same way on the row.
        let target = TranslationRunTarget.ready(docId: "doc-1", title: "Chapter 1")
        let row = state("es", target: target,
                        runState: .failed(docId: "doc-1", language: "es",
                                          failure: .ingestRejected(rejection),
                                          at: Date()))
        XCTAssertEqual(row.statusLine, rejection)
        XCTAssertTrue(row.isFailure, "a rejected batch is not a quiet ending")
    }

    /// A cancel is the writer's own act and is never drawn as a failure — the
    /// cockpit's rule, in this surface's currency.
    func test_aCancelIsNotDrawnAsAFailure() {
        let line = TranslationRunState.reportLine(.cancelled)
        XCTAssertEqual(line, TranslationRunState.cancelledLine)
        for failure: CompilerRunFailure in [.timedOut(), .unusableOutput, .cliNotFound] {
            XCTAssertNotEqual(
                line, TranslationRunState.failureCopy(.run(failure)),
                "a cancel must not wear a failure's sentence")
        }
    }

    /// **A dead translation round is not described as a dead check.**
    ///
    /// The three sessions die through one `CompilerRunFailure`, so there goes on
    /// being one switch over it (`RoundNarrative.failureCopy`) — but the nouns in
    /// two of its arms name the work, and "the compiler's session" over a Spanish
    /// round, or "couldn't be read as notes" over a translation, is an account of
    /// the wrong thing.
    func test_aDeadTranslationRoundIsNotDescribedAsADeadCheck() {
        for failure: CompilerRunFailure in [.sessionDied(detail: "exit 1"),
                                            .unusableOutput, .timedOut()] {
            XCTAssertNotEqual(
                TranslationRunState.failureCopy(.run(failure)),
                RoundNarrative.failureCopy(failure),
                "\(failure) reads as the compiler's on the department desk")
            XCTAssertFalse(
                TranslationRunState.failureCopy(.run(failure)).isEmpty)
        }
        // The arms that name a surface rather than the work are shared verbatim —
        // "Claude Code isn't installed" is the same instruction whoever asked.
        XCTAssertEqual(TranslationRunState.failureCopy(.run(.cliNotFound)),
                       RoundNarrative.failureCopy(.cliNotFound))
    }

    /// **The report a row draws belongs to the chapter the desk is on.**
    ///
    /// The desk is project-scope and the log remembers a run per `(document,
    /// language)` pair, so a summary for chapter 1 must not be drawn while the
    /// window has moved to chapter 2 — the cockpit's `where runDocId == docId`
    /// rule, which is here rather than only in the log's key because a lookup that
    /// went wrong would otherwise be invisible.
    func test_aReportFromAnotherChapterIsNotThisRowsReport() {
        let summary = TranslatorOrchestrator.RunSummary(
            runId: "r1", docId: "doc-1", language: "es", at: Date(),
            outcome: .ingested(.init(entriesWritten: 3)))

        let mine = TranslationRunState.resolve(
            language: "es",
            target: .ready(docId: "doc-1", title: "Chapter 1"),
            session: .free, runState: .idle, lastRun: summary)
        XCTAssertNotNil(mine.report)

        let elsewhere = TranslationRunState.resolve(
            language: "es",
            target: .ready(docId: "doc-2", title: "Chapter 2"),
            session: .free, runState: .idle, lastRun: summary)
        XCTAssertNil(elsewhere.report,
                     "chapter 2's row must not report chapter 1's round")
    }

    /// The log keeps one run per pair and hands back the newest.
    func test_theLogRemembersTheNewestRunOfEachPair() {
        let log = TranslationRunLog()
        XCTAssertNil(log.run(docId: "doc-1", language: "es"))

        log.record(.init(runId: "r1", docId: "doc-1", language: "es", at: Date(),
                         outcome: .ingested(.init(entriesWritten: 1))))
        log.record(.init(runId: "r2", docId: "doc-1", language: "fr", at: Date(),
                         outcome: .cancelled))
        log.record(.init(runId: "r3", docId: "doc-1", language: "es", at: Date(),
                         outcome: .ingested(.init(entriesWritten: 9))))

        XCTAssertEqual(log.run(docId: "doc-1", language: "es")?.runId, "r3",
                       "the newest round for a pair replaces the one before it")
        XCTAssertEqual(log.run(docId: "doc-1", language: "fr")?.runId, "r2",
                       "…and does not disturb another edition's")
        XCTAssertNil(log.run(docId: "doc-2", language: "es"))
    }

    /// **What Cancel now promises, and what it stopped promising.**
    ///
    /// Before the pipeline a round was one translator call, so cancelling it
    /// really did write nothing. A seven-leg round has already written by the
    /// time leg 3 repairs anything, and those writes STAND (spec §5) — so the
    /// old sentence was a promise this surface could no longer keep. Pinned
    /// because it is exactly the kind of copy a later hand restores from
    /// memory.
    func test_theCancelHelpPromisesOnlyWhatAPipelineRoundCanKeep() {
        XCTAssertEqual(
            TranslationRunState.cancelHelp,
            "Stop this round after the leg that is running. What earlier legs "
            + "wrote stays; nothing later starts.")
        XCTAssertFalse(
            TranslationRunState.cancelHelp.contains("Nothing it has translated is written"),
            "the pre-pipeline promise is false of a round whose earlier legs "
            + "have already written")
    }

    // MARK: - The compile's one line (imprints P3 Task 5)

    /// **Every phase has something to say, and the order is the desk's** —
    /// what is happening now outranks what happened last, exactly as
    /// `TranslationRunState` orders a round's.
    func test_theCompilesLineSaysSomethingInEveryPhase() {
        XCTAssertNil(CompileRunState().statusLine,
                     "a desk nobody has pressed has nothing to report")

        let running = CompileRunState(
            phase: .running(format: .pdf, languages: ["en", "es"],
                            imprint: "special"),
            isRunning: true)
        let line = try? XCTUnwrap(running.statusLine)
        XCTAssertEqual(line, CompileRunState.compiling(
            format: .pdf, languages: ["en", "es"], imprint: "special"))
        XCTAssertFalse(running.isFailure, "a compile in flight is not a failure")

        XCTAssertEqual(
            CompileRunState(phase: .failed("template.tex is missing")).statusLine,
            "template.tex is missing")
        XCTAssertTrue(
            CompileRunState(phase: .failed("x")).isFailure,
            "…and that one is the only phase drawn red")

        XCTAssertEqual(
            CompileRunState(phase: .idle, isRunning: false,
                                   report: CompileRunState.cancelledLine)
                .statusLine,
            CompileRunState.cancelledLine,
            "an idle desk that just swallowed a press without a word is "
            + "indistinguishable from a button that did nothing")
        XCTAssertFalse(
            CompileRunState(phase: .idle, isRunning: false,
                                   report: CompileRunState.cancelledLine)
                .isFailure,
            "a cancel is the writer's own act and is never drawn as a failure")
    }

    /// **A refusal drawn while the run it refused carries on says both things.**
    ///
    /// The second press replaces the PHASE and leaves `isRunning` true — that
    /// is `CompileRunState`'s whole reason for storing the flag — so the
    /// one line has to carry the refusal AND the fact that something is still
    /// compiling. A bare refusal beside a live Cancel button is a desk telling
    /// the writer nothing is happening next to the control that stops it.
    ///
    /// The disable experiment: return `sentence` unconditionally from the
    /// `.refused` arm and the first two assertions fail while the settled one
    /// still passes.
    func test_aRefusalWhileTheRunCarriesOnStillSaysSomethingIsCompiling() {
        let midRun = CompileRunState(
            phase: .refused(CompileRunState.alreadyRunning),
            isRunning: true)
        let line = midRun.statusLine ?? ""
        XCTAssertTrue(line.contains(CompileRunState.alreadyRunning),
                      "the refusal is not lost: \(line)")
        XCTAssertTrue(line.contains("still compiling"),
                      "…and neither is the run it was refused for: \(line)")
        XCTAssertFalse(midRun.isFailure,
                       "nothing broke — a press arrived at the wrong moment")

        let settled = CompileRunState(
            phase: .refused("unknown imprint 'speciel'"), isRunning: false)
        XCTAssertEqual(settled.statusLine, "unknown imprint 'speciel'",
                       "a refusal with nothing running is the bare sentence — "
                       + "appending \u{201C}still compiling\u{201D} there would "
                       + "be a lie about a desk at rest")
    }

    // MARK: - Task 4: the Design row's decisions (no window)

    /// **The row names the person and the newest round.** The designer is the
    /// one identity resolution (`ProductionRole.effectiveName`), carried in
    /// rather than re-derived; the line under it says which round, where it
    /// stands and how long ago, because a proposal with no age is one the writer
    /// cannot tell from this morning's.
    func test_theDesignRowNamesItsDesignerAndItsNewestRound() {
        let now = Date()
        let row = designRow(
            designerName: "Tschichold",
            proposals: [proposal(round: 2, status: .pending,
                                 created: now.addingTimeInterval(-600)),
                        proposal(round: 1, status: .superseded,
                                 created: now.addingTimeInterval(-9000))],
            now: now)

        XCTAssertEqual(row.designerName, "Tschichold")
        XCTAssertTrue(row.latestLine.contains("Round 2"),
                      "the NEWEST round is the row's line: \(row.latestLine)")
        XCTAssertFalse(row.latestLine.contains("Round 1"),
                       "…and the superseded one is not: \(row.latestLine)")
        XCTAssertTrue(
            row.latestLine.contains(
                DesignRoundState.statusWord(.pending)),
            "where it stands is half the line: \(row.latestLine)")
        XCTAssertTrue(
            row.latestLine.contains(
                DesignRoundState.age(now.addingTimeInterval(-600), now: now)),
            "…and how long ago is the other half: \(row.latestLine)")
    }

    /// A project nobody has asked for a design of says so, rather than leaving a
    /// blank under the designer's name where a line goes.
    func test_aProjectWithNoRoundYetSaysSoRatherThanDrawingNothing() {
        let row = designRow(proposals: [])
        XCTAssertEqual(row.latestLine, DesignRoundState.noRoundYet)
        XCTAssertFalse(DesignRoundState.noRoundYet.isEmpty)
        XCTAssertNil(row.pendingBadge, "nothing staged, nothing pending")
    }

    /// **The badge is for a proposal still waiting on the writer**, and for no
    /// other status: it is the one thing on this row asking them for something.
    func test_theBadgeMarksAProposalStillWaitingOnTheWriter() {
        XCTAssertEqual(
            designRow(proposals: [proposal(round: 1, status: .pending)]).pendingBadge,
            DesignRoundState.pendingBadgeTitle)

        for settled: DesignProposalStore.Status in [.approved, .rejected,
                                                    .superseded] {
            XCTAssertNil(
                designRow(proposals: [proposal(round: 1, status: settled)]).pendingBadge,
                "\(settled) is a round the writer has already answered")
        }
    }

    /// **A status a NEWER build wrote is printed as it stands.** The store keeps
    /// `.unknown(raw)` lossless precisely so an older build cannot clobber it;
    /// printing "unknown" over it on the desk would tell the writer their
    /// proposal is broken when it is merely from the future.
    func test_aStatusFromANewerBuildIsPrintedRatherThanCalledUnknown() {
        let line = designRow(
            proposals: [proposal(round: 3, status: .unknown("archived"))]).latestLine
        XCTAssertTrue(line.contains("archived"), line)
        XCTAssertFalse(line.lowercased().contains("unknown"), line)
    }

    /// **One designer session, so a round in flight refuses both verbs** — and
    /// the refusal names the round, because "a round is running" tells a writer
    /// nothing about how far along the conversation they are waiting on is.
    func test_aRoundInFlightSaysWhichRoundAndRefusesBothVerbs() {
        let row = designRow(
            runState: .running(round: 2, language: nil),
            session: .busy(round: 2))

        XCTAssertEqual(row.statusLine, DesignRoundState.designingLine(
            round: 2, language: nil))
        XCTAssertTrue(row.statusLine?.contains("2") ?? false, row.statusLine ?? "nil")
        XCTAssertTrue(row.isRunning)
        XCTAssertFalse(row.canRun)
        XCTAssertTrue(row.refusal?.contains("2") ?? false,
                      "the refusal must name the round holding the session: "
                      + "\(row.refusal ?? "nil")")
    }

    /// **The click is refused before the send, too** — `isPreparingRun` counts
    /// as running while the briefing is gathered (an AST build and a template
    /// walk, a real window) and `runState` names no round yet, so the desk must
    /// still refuse in words without being able to say which.
    func test_theWindowBetweenTheDesignClickAndTheSendRefusesTheSecondClick() {
        let preparing = DesignSession.read(runState: .idle, isRunning: true)
        XCTAssertEqual(preparing, .busy(round: nil),
                       "a round under way that has not named itself is still a run")

        let row = designRow(session: preparing)
        XCTAssertFalse(row.canRun)
        XCTAssertFalse(row.refusal?.isEmpty ?? true,
                       "…and refusing without words is the silent no-op "
                       + "Constraint 2 forbids")
        XCTAssertEqual(DesignSession.read(runState: .idle, isRunning: false), .free)
        XCTAssertEqual(
            DesignSession.read(
                runState: .failed(failure: .run(.timedOut()), at: Date()),
                isRunning: false),
            .free,
            "a round that ended badly is not a session still holding the desk")
    }

    /// **A round started for an EDITION says so**, even though this desk starts
    /// none: the milestone's ruling is `language: nil`, but the orchestrator can
    /// be driven from elsewhere and a row that dropped the edition would draw
    /// somebody else's round as the book's.
    func test_aRoundForAnEditionIsNotDrawnAsTheBooksOwn() {
        let line = DesignRoundState.designingLine(round: 1, language: "es")
        XCTAssertTrue(
            line.contains(TranslationReviewIndicator.displayLabel(forLanguageTag: "es")),
            line)
        XCTAssertNotEqual(line, DesignRoundState.designingLine(round: 1,
                                                                 language: nil))
    }

    /// **A dead design round is not described as a dead check.**
    ///
    /// The three sessions die through one `CompilerRunFailure`, so there goes on
    /// being one switch over it (`RoundNarrative.failureCopy`) — but the nouns
    /// in two of its arms name the work, and "the compiler's session" over a
    /// design round, or "couldn't be read as notes" over a proposal, is an
    /// account of the wrong thing.
    func test_aDeadDesignRoundIsNotDescribedAsADeadCheck() {
        for failure: CompilerRunFailure in [.sessionDied(detail: "exit 1"),
                                            .unusableOutput, .timedOut()] {
            XCTAssertNotEqual(
                DesignRoundState.failureCopy(.run(failure)),
                RoundNarrative.failureCopy(failure),
                "\(failure) reads as the compiler's on the Design row")
            XCTAssertFalse(DesignRoundState.failureCopy(.run(failure)).isEmpty)
        }
        // The arms that name a surface rather than the work are shared verbatim.
        XCTAssertEqual(DesignRoundState.failureCopy(.run(.cliNotFound)),
                       RoundNarrative.failureCopy(.cliNotFound))
        // …and it is a third account, not the translator's with a new label.
        XCTAssertNotEqual(DesignRoundState.failureCopy(.run(.timedOut())),
                          TranslationRunState.failureCopy(.run(.timedOut())))
    }

    /// **A report that read perfectly and could not be written down says what
    /// refused it**, whole. `stagingRejected` is the loop's own ending and its
    /// sentence was built where the cause was known, so the row carries it
    /// rather than summarising it away.
    func test_aRefusedStagingReachesTheRowInItsOwnWords() {
        let sentence = "the design proposal could not be staged: the file "
            + "“.maugham/design” couldn’t be opened."
        let row = designRow(
            runState: .failed(failure: .stagingRejected(sentence), at: Date()))

        XCTAssertEqual(row.statusLine, sentence)
        XCTAssertTrue(row.isFailure, "a refused staging is not a quiet ending")
    }

    /// **An idle row's account of the last round is the PROPOSAL**, not a
    /// remembered sentence. A language row keeps a report line because what its
    /// round wrote is invisible on the desk; a design round's product is the
    /// line right above, re-derived from disk, so a second account under it
    /// would be two stories about one round — and only one of them survives a
    /// relaunch.
    func test_anIdleDesignRowSaysNothingBesideTheProposalItAlreadyDrew() {
        let row = designRow(proposals: [proposal(round: 1, status: .pending)])
        XCTAssertNil(row.statusLine)
        XCTAssertNotEqual(row.latestLine, DesignRoundState.noRoundYet,
                          "premise: the proposal line is what the row is saying")
    }

    // MARK: - Task 4: Request Changes

    /// **Offered only while the session that made the proposal can still revise
    /// it.** Outside that window the verb does not merely refuse — the honest
    /// move is Run with the writer's words as the round's direction, which is
    /// the button beside it.
    func test_requestChangesIsOfferedOnlyWhileTheSessionCanStillReviseIt() {
        XCTAssertTrue(designRow(hasOpenProposalRound: true).offersRequestChanges)
        XCTAssertFalse(designRow(hasOpenProposalRound: false).offersRequestChanges)
    }

    /// **A false return gets words** (Constraint 2). `requestChanges` answers a
    /// bare `Bool`, so the desk composes the sentence from the three conditions
    /// the writer can actually be in — and a round in flight outranks the other
    /// two, because it is the fact that changes what pressing anything will do.
    func test_everyWayRequestChangesRefusesIsAnsweredInWords() {
        let busy = DesignRoundState.changesRefusal(
            words: "warmer paper", session: .busy(round: 2),
            hasOpenProposalRound: true)
        XCTAssertEqual(busy, DesignRoundState.busyReason(round: 2),
                       "a round in flight outranks everything else")

        let wordless = DesignRoundState.changesRefusal(
            words: "   \n ", session: .free, hasOpenProposalRound: true)
        XCTAssertEqual(wordless, DesignRoundState.noWordsRefusal)

        let closed = DesignRoundState.changesRefusal(
            words: "warmer paper", session: .free, hasOpenProposalRound: false)
        XCTAssertEqual(closed, DesignRoundState.noOpenRoundRefusal)
        XCTAssertTrue(closed.lowercased().contains("run"),
                      "the refusal must point at the verb that DOES work: \(closed)")

        for sentence in [busy, wordless, closed,
                         DesignRoundState.unknownRefusal] {
            XCTAssertFalse(sentence.isEmpty)
        }
    }

    // MARK: - Task 4: the briefing abandon, closed in words

    /// **The two arms `DesignerEnvironment`'s briefing refuses a project for are
    /// refused at the desk instead** — Constraint 2's "briefing-gather abandon",
    /// which Task 3's report handed forward by name.
    ///
    /// Left to the orchestrator both vanish: `briefRound` answers `nil`,
    /// `abandon()` sets no state and emits no summary, and the writer presses a
    /// button that does nothing at all. Unlike the translator's, these arms are
    /// the designer loop's own, so there is no shared validator to lean on —
    /// what there is instead is the same two gates, CALLED (see `briefability`).
    func test_everyDesignBriefingAbandonArmIsRefusedAtTheDeskInWords() {
        XCTAssertNil(DesignRoundState.preflight(session: .free,
                                                   briefability: .ready),
                     "a project that can be briefed must let the click through")

        for arm: DesignBriefability in [.noPublishTemplates, .noBook] {
            let refusal = DesignRoundState.preflight(session: .free,
                                                        briefability: arm)
            XCTAssertFalse(refusal?.isEmpty ?? true,
                           "\(arm) reaches the orchestrator, where it abandons "
                           + "in silence")
        }
        XCTAssertNotEqual(DesignRoundState.noPublishTemplatesRefusal,
                          DesignRoundState.noBookRefusal,
                          "two different problems, two different moves")
        // An instruction rather than a diagnosis, as Constraint 2 asks.
        XCTAssertTrue(
            DesignRoundState.noPublishTemplatesRefusal.lowercased()
                .contains("set up publishing"),
            DesignRoundState.noPublishTemplatesRefusal)

        // …and a round in flight still outranks both.
        XCTAssertEqual(
            DesignRoundState.preflight(session: .busy(round: 1),
                                          briefability: .noBook),
            DesignRoundState.busyReason(round: 1))
    }

    /// **The desk asks the same two questions the briefing asks**, against a
    /// real project — the premise being the briefing's own `nil`, so this cannot
    /// pass by agreeing with a gate that stopped refusing.
    func test_theDesksBriefabilityAgreesWithTheBriefingsOwnRefusals() async throws {
        let full = try await makeDesignProject()
        XCTAssertEqual(
            DesignRoundState.briefability(store: full.projectStore,
                                             projectURL: full.projectURL),
            .ready)
        let fullInputs = await full.environment.briefRound(nil, nil)
        XCTAssertNotNil(fullInputs, "premise: the briefing accepts this project")
        await full.documentStore.close()

        let noTemplates = try await makeDesignProject(publishTree: false)
        XCTAssertEqual(
            DesignRoundState.briefability(store: noTemplates.projectStore,
                                             projectURL: noTemplates.projectURL),
            .noPublishTemplates)
        let noTemplateInputs = await noTemplates.environment.briefRound(nil, nil)
        XCTAssertNil(noTemplateInputs,
                     "premise: the briefing refuses a project with no templates")
        await noTemplates.documentStore.close()

        let noBook = try await makeDesignProject(manuscript: false)
        XCTAssertEqual(
            DesignRoundState.briefability(store: noBook.projectStore,
                                             projectURL: noBook.projectURL),
            .noBook)
        let noBookInputs = await noBook.environment.briefRound(nil, nil)
        XCTAssertNil(noBookInputs,
                     "premise: the briefing refuses a project with no book")
        await noBook.documentStore.close()
    }

    /// **The cheap question and the expensive one must not drift.** The desk
    /// asks `publishablePieces()`; the briefing asks `ast.sections.isEmpty`. One
    /// is a walk of the manifest, the other materializes every chapter — so they
    /// are two spellings by necessity, and this is what keeps them one answer.
    ///
    /// The fixture carries both things the filter drops: a collection reference,
    /// and a document row with no path.
    func test_thePublishablePiecesAreExactlyTheSectionsTheASTWouldBuild() async throws {
        let h = try await makeDesignProject()
        h.projectStore.manifest.structure.append(contentsOf: [
            StructureItem(id: "ref-1", title: "Another Book", type: .document,
                          path: "manuscript/ref.md", pieceKind: .reference),
            StructureItem(id: "pathless", title: "No File", type: .document),
        ])

        let source = ProjectStoreASTSource(projectStore: h.projectStore, figures: .none)
        let ast = try ProjectASTBuilder.build(from: source)

        XCTAssertEqual(source.publishablePieces().map(\.id), ["doc-1"],
                       "a reference and a pathless row are not pieces")
        XCTAssertEqual(source.publishablePieces().count, ast.sections.count,
                       "the desk's question and the briefing's must agree")

        await h.documentStore.close()
    }

    // MARK: - Task 9: the mint sheet for unlisted languages

    /// **The three ways a language answers "does Run need to ask first?"**
    /// (no window — `TranslationRunStart.needsTranslatorName` is a pure read
    /// over `EditionStatus.translatorName`, which is the row's own "No
    /// translator yet" question asked from the other side).
    func test_aPresetLanguageNeverNeedsTheMintSheet() {
        XCTAssertFalse(
            TranslationRunStart.needsTranslatorName(language: "es", in: Self.blankManifest()),
            "es has a preset translator (Cort\u{e1}zar) \u{2014} the sheet exists for "
            + "languages nobody has named, and es is never one of them")
    }

    func test_anUnlistedUnmintedLanguageNeedsTheMintSheet() {
        XCTAssertTrue(
            TranslationRunStart.needsTranslatorName(language: "xx", in: Self.blankManifest()),
            "xx has no preset and no stored role \u{2014} translatorRole(for:) would "
            + "mint one named nothing but the tag, unasked")
    }

    func test_anAlreadyMintedUnlistedLanguageNeedsNoSheet() {
        let stored = ProductionRole(id: "role-1", role: .translator(language: "xx"), name: nil)
        let manifest = Self.blankManifest(productionRoles: [stored])
        XCTAssertFalse(
            TranslationRunStart.needsTranslatorName(language: "xx", in: manifest),
            "a role already stored for this language \u{2014} even one still unnamed "
            + "\u{2014} answers `effectiveName` with the uppercased tag rather than nil, "
            + "and a run must not interrupt an edition the desk has already minted")
    }

    // MARK: - Task 9: the sheet itself (no host)

    /// **Every string the sheet draws is `EditionCastCopy`'s** — the
    /// `DepartmentDesk` split, so the whole surface is assertable with
    /// nothing but the language it was given.
    func test_theMintSheetNamesTheEditionItIsAskingAbout() async throws {
        let window = mountMintSheet(language: "pt-br")
        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains { $0.contains(EditionCastCopy.nameForRunTitle(language: "pt-br")) },
            "the sheet never said which edition it wants a name for. Published: "
            + "\(texts.sorted())")
        XCTAssertTrue(texts.contains { $0.contains(EditionCastCopy.explanation) },
                      "…nor why. Published: \(texts.sorted())")
    }

    /// **Confirm refuses a blank name** — a translator signed "" is the thing
    /// `renameProductionRole`'s own `.productionRoleNameEmpty` refusal exists
    /// against, and the sheet must not let a click reach it.
    func test_theMintSheetsConfirmIsDisabledUntilANameIsTyped() async throws {
        let window = mountMintSheet(language: "xx")
        let blank = try axButtons(labelled: EditionCastCopy.nameAndRunTitle, in: window)
        XCTAssertEqual(blank.count, 1)
        XCTAssertEqual(axEnabled(blank[0]), false,
                       "an empty field must not offer a way to confirm nothing")

        let field = try XCTUnwrap(textField(placeholder: EditionCastCopy.placeholder,
                                            in: window),
                                  "the sheet mounted no name field at all")
        type("Constance Garnett", into: field)
        pump(0.1)

        let named = try axButtons(labelled: EditionCastCopy.nameAndRunTitle, in: window)
        XCTAssertEqual(axEnabled(named[0]), true,
                       "…and a typed name must make it pressable, or this test "
                       + "could pass over a button that never enables")
    }

    // MARK: - Task 9: Run's verb, wired to a real translator loop

    /// **Run on an unlisted, unminted edition asks for the cast — and
    /// nothing else happens** (windowless since the desk went, shell p4 Task
    /// 7: `TranslationRunStart.startRun` is the verb a Run reaches). Nothing
    /// is minted, nothing is renamed, and the run never reaches
    /// `TranslatorOrchestrator`.
    func test_anUnlistedLanguageShowsTheSheetBeforeAnythingRuns() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "xx")

        let start = await TranslationRunStart.startRun(
            language: "xx", docId: "doc-1", pipeline: fixture.pipeline,
            documentStore: fixture.documentStore, store: fixture.projectStore)
        let prompt = try XCTUnwrap(start.castPrompt, "Run on an unnamed edition must ask "
                                   + "for its translator before anything runs")
        XCTAssertEqual(prompt.ask, .nameForRun(language: "xx", docId: "doc-1"))
        XCTAssertEqual(prompt.title, EditionCastCopy.nameForRunTitle(language: "xx"))

        XCTAssertTrue(fixture.projectStore.manifest.productionRoles.isEmpty,
                      "opening the sheet must mint nothing — only Confirm does")
        XCTAssertFalse(fixture.translator.isRunning,
                       "the run must not have reached the orchestrator")
        XCTAssertTrue(fixture.runner.sends.isEmpty,
                      "…and nothing was sent to a session that should not exist yet")

        await fixture.documentStore.close()
    }

    /// **A preset language never sees the sheet at all** — the control on
    /// the whole file: `es` has a name (Cortázar) before anybody asks, so
    /// Run must reach the orchestrator on the very first click.
    ///
    /// Windowless (tripwire 33, #120): Run's verb past the pre-flight,
    /// `TranslationRunStart.startRun`.
    func test_aPresetLanguageRunsStraightThroughWithNoSheet() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "es")

        let start = await TranslationRunStart.startRun(
            language: "es", docId: "doc-1", pipeline: fixture.pipeline,
            documentStore: fixture.documentStore, store: fixture.projectStore)

        XCTAssertNil(start.castPrompt, "…and the sheet must never have appeared")
        XCTAssertNil(start.notice, "doc-1 is this translator's to write")
        _ = await pumpUntil(deadline: 10) { !fixture.runner.sends.isEmpty }
        XCTAssertFalse(fixture.runner.sends.isEmpty,
                       "es must run immediately — nothing here should be waiting on a name")

        await fixture.documentStore.close()
    }

    /// **A chapter's Run drives a whole seven-leg ROUND** — `startRun` enters
    /// the PIPELINE at leg 1, not a bare `translator.runTranslation` (the
    /// pre-pipeline path, which would run a second round on one click). The
    /// round's drawing is an edition's To resolve head's
    /// (`ResolveEditionVerbTests`); the desk that drew it on a row is gone
    /// (shell p4 Task 7). Windowless: nothing is pressed (tripwire 33).
    func test_aRunDrivesTheSevenLegPipeline() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "es")
        let world = TranslationPipelineTests.FakeWorld()
        let pipeline = runPipeline(over: world, projectURL: fixture.projectURL)
        XCTAssertNil(TranslationRunState.preflight(
            language: "es",
            target: TranslationRunTarget.resolve(
                subject: .item("doc-1"), structure: fixture.projectStore.manifest.structure,
                isOpen: { fixture.documentStore.document(for: $0) != nil }),
            session: .free), "premise: the pre-flight lets this Run through")
        let start = await TranslationRunStart.startRun(
            language: "es", docId: "doc-1", pipeline: pipeline,
            documentStore: fixture.documentStore, store: fixture.projectStore)
        XCTAssertNil(start.castPrompt, "a preset edition asks for no name")

        _ = await pumpUntil(deadline: 10) { !world.calls.isEmpty }
        XCTAssertEqual(world.calls.first, "translate",
                       "Run must enter the pipeline at leg 1. Calls: \(world.calls)")
        XCTAssertTrue(fixture.runner.sends.isEmpty,
                      "…and must not ALSO drive the bare translator loop")
        let filed = await pumpUntil(deadline: 20) {
            TranslationRoundStore(projectURL: fixture.projectURL)
                .latest(language: "es", docId: "doc-1") != nil
        }
        XCTAssertTrue(filed, "the round the pipeline ran was never filed")
        pipeline.cancel()
        await fixture.documentStore.close()
    }

    /// **Run Whole Book asks the pipeline for the desk's OWN set, in binder
    /// order** — every chapter the rows are summed over, not the one chapter
    /// the window happens to be on.
    ///
    /// The pipeline is left parked in leg 1 (this world's translator leg never
    /// ends), which is what makes the queue readable: `status` still names the
    /// first document and the book's own position, and a verb that had passed
    /// the open chapter alone would carry no `book` at all.
    func test_runWholeBookQueuesEveryChapterOfTheBook() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "es",
                                                      extraChapters: 2)
        let pipeline = TranslationPipeline()
        let world = TranslationPipelineTests.FakeWorld()
        var environment = world.environment()
        // Parked: a runId, and nothing ever resumes it.
        environment.runTranslation = { _, _ in
            world.record("translate")
            return "held"
        }
        pipeline.configure(environment: environment)

        // Windowless (tripwire 33, #120): Run Whole Book's verb past its
        // refusals is `startBookRun` over the edition's run scope
        // (`ResolveEditionItems.runScope`, these two statics' composition), so
        // the ORDER asserted below rests on `EditionStatus
        // .manuscriptDocumentIds` and on `scopedDocumentIds`' pins in
        // `EditionLanguagesTests`.
        let book = PublishImprint.scopedDocumentIds(
            EditionStatus.manuscriptDocumentIds(in: fixture.projectStore.manifest),
            imprint: nil, in: nil)
        let start = await TranslationRunStart.startBookRun(
            language: "es", documentIds: book, pipeline: pipeline,
            documentStore: fixture.documentStore, store: fixture.projectStore)

        XCTAssertNil(start.castPrompt)
        XCTAssertEqual(
            pipeline.status,
            .running(docId: "doc-1", language: "es", leg: .translate,
                     book: .init(position: 1, count: 3)),
            "the book verb must hand the pipeline the desk's whole set in the "
            + "manifest's own order")

        pipeline.cancel()
        await fixture.documentStore.close()
    }

    /// **An unlisted language whose role was already minted (even unnamed)
    /// runs straight through on the next click** — the sheet answers a
    /// language once, not an edition's every round.
    func test_anAlreadyMintedUnlistedLanguageAlsoRunsStraightThrough() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "xx")
        _ = try await fixture.projectStore.translatorRole(for: "xx")

        // Windowless (tripwire 33, #120) — the preset case's shape.
        let start = await TranslationRunStart.startRun(
            language: "xx", docId: "doc-1", pipeline: fixture.pipeline,
            documentStore: fixture.documentStore, store: fixture.projectStore)

        XCTAssertNil(start.castPrompt)
        _ = await pumpUntil(deadline: 10) { !fixture.runner.sends.isEmpty }
        XCTAssertFalse(fixture.runner.sends.isEmpty,
                       "a language whose role already exists must not be interrupted again")

        await fixture.documentStore.close()
    }

    // MARK: - cast-management: the Add Language sheet (no host)

    /// **A tag no edition can be written for is refused in the sheet, in
    /// words** — not at a dead button, and not much later inside
    /// `TranslationWritePipeline`, where the writer is no longer looking.
    func test_theAddLanguageSheetRefusesAnUnusableTagInWords() async throws {
        let window = mountCastSheet(ask: .addLanguage)
        let tagField = try XCTUnwrap(
            textField(placeholder: EditionCastCopy.tagPlaceholder, in: window),
            "the Add Language sheet mounted no tag field at all")
        type("PT BR", into: tagField)
        pump(0.1)

        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains { $0.contains(EditionCastCopy.unusableTag("PT BR")) },
            "the sheet took an unusable tag without saying so. Published: "
            + "\(texts.sorted())")
        let confirm = try axButtons(labelled: EditionCastCopy.addConfirmTitle,
                                    in: window)
        XCTAssertEqual(axEnabled(confirm[0]), false,
                       "…and it must not offer a way to add it anyway")
    }

    /// **A preset language arrives with its translator already in the field**,
    /// and the sheet says whose name that is: an offer the writer recognises
    /// rather than a name they have to wonder about.
    func test_aPresetLanguageArrivesWithItsTranslatorAlreadyNamed() async throws {
        let window = mountCastSheet(ask: .addLanguage)
        let tagField = try XCTUnwrap(
            textField(placeholder: EditionCastCopy.tagPlaceholder, in: window))
        type("es", into: tagField)
        pump(0.1)

        let nameField = try XCTUnwrap(
            textField(placeholder: EditionCastCopy.placeholder, in: window))
        XCTAssertEqual(nameField.stringValue, "Cortázar")
        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains {
                $0.contains(EditionCastCopy.addExplanation(preset: "Cortázar"))
            },
            "the sheet never said where that name came from. Published: "
            + "\(texts.sorted())")
        let confirm = try axButtons(labelled: EditionCastCopy.addConfirmTitle,
                                    in: window)
        XCTAssertEqual(axEnabled(confirm[0]), true,
                       "a preset language is answerable the moment it is typed")
    }

    /// **A name the writer typed outranks any preset.** The auto-fill follows
    /// the tag only while the field still holds what the sheet put there; a
    /// writer who names their own translator and then corrects the tag must not
    /// find Cortázar in place of them.
    func test_theWritersOwnNameSurvivesAChangeOfTag() async throws {
        let window = mountCastSheet(ask: .addLanguage)
        let nameField = try XCTUnwrap(
            textField(placeholder: EditionCastCopy.placeholder, in: window))
        type("Ana", into: nameField)
        pump(0.1)
        let tagField = try XCTUnwrap(
            textField(placeholder: EditionCastCopy.tagPlaceholder, in: window))
        type("es", into: tagField)
        pump(0.1)

        XCTAssertEqual(nameField.stringValue, "Ana",
                       "the writer had already answered the question the preset "
                       + "answers")
    }

    /// A blank name is refused in words as well as by the disabled button — the
    /// refusal `renameProductionRole` would throw, said where the writer can act
    /// on it.
    func test_theSheetSaysWhyABlankNameIsNotEnough() async throws {
        let window = mountCastSheet(ask: .addLanguage)
        let nameField = try XCTUnwrap(
            textField(placeholder: EditionCastCopy.placeholder, in: window))
        type("Ana", into: nameField)
        pump(0.1)
        type("   ", into: nameField)
        pump(0.1)

        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains(EditionCastCopy.nameRequired) },
                      "a cleared name field said nothing about why Confirm went "
                      + "dead. Published: \(texts.sorted())")
    }

    // MARK: - cast-management: renaming the cast (no host)

    /// **A rename starts from the name it is about** — the writer is usually
    /// correcting a spelling, not typing a stranger from scratch — and the sheet
    /// says whose name it is asking about, because a desk with four editions
    /// offers four of these.
    func test_theRenameSheetStartsFromTheNameItIsAbout() async throws {
        let window = mountCastSheet(
            ask: .rename(subject: .edition(language: "es"),
                         currentName: "Cortázar"))

        let nameField = try XCTUnwrap(
            textField(placeholder: EditionCastCopy.placeholder, in: window))
        XCTAssertEqual(nameField.stringValue, "Cortázar")
        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains {
                $0.contains(EditionCastCopy.renameTitle(currentName: "Cortázar"))
            },
            "the sheet never said who it was about. Published: \(texts.sorted())")
        XCTAssertTrue(
            texts.contains {
                $0.contains(EditionCastCopy.renameExplanation(
                    subject: .edition(language: "es")))
            },
            "…nor that a rename orphans nothing, which is the fear that stops a "
            + "writer renaming anybody. Published: \(texts.sorted())")
    }

    /// The designer's sheet is one field — there is no reader or collator of a
    /// book's design.
    func test_theDesignerSheetHasNoCastFields() async throws {
        let window = mountCastSheet(
            ask: .rename(subject: .designer, currentName: "Tschichold"))
        XCTAssertNil(textField(placeholder: EditionCastCopy.readerPlaceholder, in: window))
        XCTAssertNil(textField(placeholder: EditionCastCopy.collatorPlaceholder, in: window))
    }

    /// **A row with nobody on it yet asks for a NAME**, which is the honest verb
    /// for an unlisted language nothing has minted a role for — "Rename " with
    /// an empty name after it would be a sheet about nobody.
    func test_aRowWithNobodyOnItAsksForANameRatherThanARename() async throws {
        let prompt = EditionCastPrompt(
            ask: .rename(subject: .edition(language: "xx"), currentName: ""))
        XCTAssertEqual(prompt.title,
                       EditionCastCopy.nameForRunTitle(language: "xx"))
        XCTAssertEqual(prompt.confirmTitle, EditionCastCopy.nameConfirmTitle)

        let window = mountCastSheet(ask: prompt.ask)
        let confirm = try axButtons(labelled: EditionCastCopy.nameConfirmTitle,
                                    in: window)
        XCTAssertEqual(confirm.count, 1)
        XCTAssertEqual(axEnabled(confirm[0]), false,
                       "there is nothing to confirm until somebody is named")
    }

    /// **Emptying the field is refused in words**, not only by a button going
    /// dead — `renameProductionRole` throws `.productionRoleNameEmpty` for the
    /// same reason, and a writer who cleared a field to retype it deserves the
    /// sentence rather than a puzzle.
    func test_anEmptyRenameIsRefusedInWords() async throws {
        let window = mountCastSheet(
            ask: .rename(subject: .designer, currentName: "Tschichold"))
        let nameField = try XCTUnwrap(
            textField(placeholder: EditionCastCopy.placeholder, in: window))
        type("   ", into: nameField)
        pump(0.1)

        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains(EditionCastCopy.nameRequired) },
                      "Published: \(texts.sorted())")
        let confirm = try axButtons(labelled: EditionCastCopy.renameConfirmTitle,
                                    in: window)
        XCTAssertEqual(axEnabled(confirm[0]), false)
    }

    // MARK: - Helpers: the decisions

    private func designRow(designerName: String = "Tschichold",
                           proposals: [DesignProposalStore.Proposal] = [],
                           runState: DesignerOrchestrator.RunState = .idle,
                           session: DesignSession = .free,
                           hasOpenProposalRound: Bool = false,
                           now: Date = Date()) -> DesignRoundState {
        DesignRoundState.resolve(
            designerName: designerName, proposals: proposals, runState: runState,
            session: session, hasOpenProposalRound: hasOpenProposalRound, now: now)
    }

    private func proposal(round: Int,
                          status: DesignProposalStore.Status,
                          created: Date = Date()) -> DesignProposalStore.Proposal {
        DesignProposalStore.Proposal(
            id: "prop-\(round)", designerName: "Tschichold", round: round,
            language: nil, created: created, status: status,
            specMarkdown: "A quiet page.", filePaths: ["template.tex"],
            sampleResult: nil, revertNote: nil)
    }

    private func state(_ language: String,
                       target: TranslationRunTarget,
                       session: TranslationRunSession = .free,
                       runState: TranslatorOrchestrator.RunState = .idle,
                       lastRun: TranslatorOrchestrator.RunSummary? = nil)
    -> TranslationRunState {
        TranslationRunState.resolve(language: language, target: target,
                                   session: session, runState: runState,
                                   lastRun: lastRun)
    }

    // MARK: - Helpers: hosting

    /// The cast sheet, mounted alone on the run-mint's own ask —
    /// `EditionLanguagesTests`' dumb-view mounting, for the sheet's own file.
    private func mountMintSheet(language: String,
                                onName: @escaping (String) -> Void = { _ in },
                                onCancel: @escaping () -> Void = { }) -> NSWindow {
        mountCastSheet(ask: .nameForRun(language: language, docId: "doc-1"),
                       onConfirm: { onName($0.name) }, onCancel: onCancel)
    }

    /// The cast sheet on any ask — the shape the Add Language cases drive.
    private func mountCastSheet(
        ask: EditionCastPrompt.Ask,
        currentReader: String? = nil, currentCollator: String? = nil,
        onConfirm: @escaping (EditionCastAnswer) -> Void = { _ in },
        onCancel: @escaping () -> Void = { }) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(EditionCastSheet(
                prompt: EditionCastPrompt(
                    ask: ask, currentReader: currentReader, currentCollator: currentCollator),
                onConfirm: onConfirm, onCancel: onCancel)),
            size: CGSize(width: 380, height: 360))
        windows.append(window)
        pump(0.1)
        return window
    }

    // MARK: - Helpers: the accessibility tree

    /// **Drive a SwiftUI `TextField`'s binding from outside the responder
    /// chain** — setting `stringValue` and posting the notification its
    /// delegate listens for, which is what a real keystroke does once it
    /// reaches the field, without needing this test host to be the active
    /// app (the synthetic-click premise, docs/testing/TROUBLESHOOTING.md "A
    /// mounted click test sees selectedRow == -1", in this surface's currency).
    private func type(_ text: String, into field: NSTextField) {
        field.stringValue = text
        NotificationCenter.default.post( // adr-0021-ok: Apple's own textDidChange, not a maugham.* event
            name: NSControl.textDidChangeNotification, object: field)
    }

    private func textField(placeholder: String, in window: NSWindow) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        var found: [NSTextField] = []
        collect(NSTextField.self, in: root, into: &found)
        return found.first { $0.placeholderString == placeholder }
    }


    // MARK: - Helpers: a project on disk

    private struct Fixture {
        let projectURL: URL
        let projectStore: ProjectStore
        let documentStore: DocumentStore
    }

    /// One open, registered chapter — the state Constraint 1's gate describes, so
    /// the abandon test can ask whether the gate really closes the arm.
    /// `extraChapters` adds further manuscript rows to the MANIFEST without
    /// opening them — which is exactly the book verb's own case: a whole-book
    /// run walks every chapter the desk sums, and all but one of them are
    /// closed. Only chapter 1 is registered, because Global Constraint 1's
    /// target is about the window's open document and nothing else here is.
    private func makeProject(extraChapters: Int = 0) async throws -> Fixture {
        let tmp = TestTemp.root
            .appendingPathComponent("DRT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let path = "manuscript/c1.md"
        try "Doc one first.\n\nDoc one second."
            .write(to: tmp.appendingPathComponent(path), atomically: true, encoding: .utf8)

        var structure = [
            StructureItem(id: "doc-1", title: "Chapter 1", type: .document, path: path),
        ]
        for index in 0..<extraChapters {
            let number = index + 2
            let extra = "manuscript/c\(number).md"
            try "Chapter \(number)."
                .write(to: tmp.appendingPathComponent(extra), atomically: true, encoding: .utf8)
            structure.append(StructureItem(id: "doc-\(number)", title: "Chapter \(number)",
                                           type: .document, path: extra))
        }

        let manifest = ProjectManifest(
            type: .novel, title: "The Project", author: "A",
            created: Date(), modified: Date(),
            structure: structure,
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let projectStore = try await ProjectStore.load(from: tmp)
        let documentStore = try await DocumentStore.open(url: tmp)
        projectStore.documentStore = documentStore

        let doc = try await Document.load(
            url: tmp.appendingPathComponent(path),
            device: "test", session: "s", presenter: nil)
        documentStore.register(document: doc, for: path)

        return Fixture(projectURL: tmp, projectStore: projectStore,
                       documentStore: documentStore)
    }

    // MARK: - Helpers: a project on disk, with a real translator loop (Task 9)

    /// A runner that answers a minimal, valid, EMPTY report the moment it is
    /// asked — this suite is about the run reaching (or not reaching) the
    /// orchestrator, never about what a round produces, so there is nothing
    /// here to hold open. Local to this suite, because each loop's spy is
    /// `private` to its own file and they will diverge as they grow.
    @MainActor
    private final class TranslatorSpyRunner: CompilerRunner {
        private(set) var sends: [String] = []
        var isRunning = false
        var sessionEpoch = 1

        func send(message: String, systemPreamble: String?) async -> CompilerRunEvent {
            sends.append(message)
            return .resultText(#"{"entries":[],"queries":[]}"#)
        }
        func cancelCurrentRun() { }
        func shutdown() { }
    }

    private struct TranslatorFixture {
        let projectURL: URL
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let translator: TranslatorOrchestrator
        let runner: TranslatorSpyRunner
        /// **The window's own record of finished rounds**, wired to this
        /// environment's `onRunEnded` — production's path from a round that has
        /// ENDED to the line its row draws (`ProjectWindow.translationRuns`).
        /// Without it a test could watch a round start and never see it land.
        let runLog: TranslationRunLog
        /// **The window's pipeline**, wired over the translator above exactly
        /// as `ProjectWindow` wires it (translation pipeline P4): the desk's
        /// Run enters here, and leg 1 is what reaches the spy runner. Its cold
        /// call is deliberately UNWIRED, so leg 2 answers `.sessionDied`
        /// without spawning anything and the round ends there — enough for the
        /// cases that ask only whether the click got through.
        let pipeline: TranslationPipeline
        /// **Where this fixture's bridge configs go.** Inside the fixture's own
        /// project, never `ClaudeCLISession.sessionConfigDirectory` — see
        /// `test_theFixtureWritesItsBridgeConfigInsideItsOwnProject`.
        let configDirectory: URL
    }

    /// **`makeProject`'s project, with a real translator loop wired to a spy
    /// runner** — `TranslatorEnvironmentTests.makeHarness`'s shape, so
    /// `translator.runTranslation` actually reaching the orchestrator (or
    /// not) is something this suite observes rather than assumes.
    ///
    /// `seedLanguage`, when given, gets one translation-file record for
    /// `doc-1` — a filename-only fact (`EditionStatus.documentRows`'
    /// `fileLanguages` scan never reads the record's content), which is
    /// what puts a row, and a Run button, on the desk for a language the
    /// desk would otherwise have no edition to show at all.
    private func makeTranslatorFixture(seedLanguage: String,
                                       extraChapters: Int = 0) async throws -> TranslatorFixture {
        let h = try await makeProject(extraChapters: extraChapters)
        try await TranslationStore.append(
            TranslationRecord(paragraphId: "zzzz", language: seedLanguage,
                              text: "placeholder", sourceHash: TranslationHash.hash("x")),
            forDocId: "doc-1", identity: LocalIdentities.current.translator, identities: .current,
            in: h.projectURL)

        let suite = "EditionMintSheet-\(UUID().uuidString)"
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let bible = BibleStore(projectRoot: h.projectURL,
                               device: DeviceIdentity.author.slug)
        // The window's own wiring: `ProjectWindow` hands `onRunEnded` to a
        // `TranslationRunLog` it owns, and the desk reads the log. Recording
        // into a log here is what makes the end-to-end test able to watch a
        // round LAND rather than only start.
        let runLog = TranslationRunLog()
        let translator = TranslatorOrchestrator()
        let pipeline = TranslationPipeline()
        // The window's own two listeners, in the window's own order: the log
        // records, and the pipeline's parked leg is resumed. Dropping the
        // second is what hangs a round forever (`ProjectWindow`'s comment).
        var environment = TranslatorOrchestrator.Environment.production(
            store: h.projectStore, documentStore: h.documentStore,
            projectURL: h.projectURL, bible: bible, preferences: preferences,
            onRunEnded: { [weak runLog, weak pipeline] summary in
                runLog?.record(summary)
                pipeline?.translatorRunEnded(summary)
            },
            onRunAbandoned: { [weak pipeline] runId in
                pipeline?.translatorRunAbandoned(runId)
            })
        let runner = TranslatorSpyRunner()
        environment.makeRunner = { _, _ in runner }
        // **The bridge config goes in this fixture's own project, not in the
        // machine's shared `maugham-compiler` temp directory.** `production`
        // writes there, `TranslatorOrchestrator.ensureRunner` calls it on the
        // first run of a pair, and nothing removes the file unless the
        // orchestrator is shut down — which no test here does. That is how 235
        // orphaned `compiler-mcp-<UUID>.json` files reached Denver's temp root
        // by 2026-09-06. The spy runner never reads the file; only its
        // location matters.
        let configDirectory = h.projectURL.appendingPathComponent(
            ".maugham/test-bridge-configs", isDirectory: true)
        environment.writeMCPConfig = {
            try ClaudeCLISession.writeMCPConfig(
                bridgeBinary: ClaudeCLISession.bridgeBinary,
                socketPath: nil, to: configDirectory)
        }
        translator.configure(environment: environment)

        pipeline.configure(environment: .production(
            store: h.projectStore, documentStore: h.documentStore,
            projectURL: h.projectURL, translator: translator,
            // Unwired on purpose — see `TranslatorFixture.pipeline`.
            coldCall: ColdCall(),
            onRoundEnded: { _ in }))

        return TranslatorFixture(projectURL: h.projectURL, projectStore: h.projectStore,
                                 documentStore: h.documentStore, translator: translator,
                                 runner: runner, runLog: runLog, pipeline: pipeline,
                                 configDirectory: configDirectory)
    }

    /// **The fixture's runs write their bridge config inside their own
    /// project.** `TranslatorOrchestrator.Environment.production` writes it
    /// into `ClaudeCLISession.sessionConfigDirectory` — one shared directory
    /// under the machine's temp root — and `ensureRunner` calls that on the
    /// first run of every (document, language) pair. Only `retireSession()`
    /// deletes the file, and it is reached from `shutdown()`/`detach()` alone,
    /// neither of which any test here calls: `deinit` is nonisolated by design
    /// and cannot reap. So every translator run this suite drove left a
    /// `compiler-mcp-<UUID>.json` behind for the life of the machine, 235 of
    /// them by 2026-09-06, in clusters whose timestamps matched gates rather
    /// than the writer's own use.
    ///
    /// Pinned on the LOCATION rather than on the shared directory's contents:
    /// seven gate workers share that directory, so a before/after count of it
    /// would be a test whose answer another worker decides.
    func test_theFixtureWritesItsBridgeConfigInsideItsOwnProject() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "es")

        XCTAssertTrue(
            fixture.configDirectory.path.hasPrefix(fixture.projectURL.path),
            "the config belongs to this fixture's project, which goes away with it; "
            + "got \(fixture.configDirectory.path)")
        XCTAssertFalse(
            fixture.configDirectory.path.hasPrefix(
                ClaudeCLISession.sessionConfigDirectory.path),
            "nothing this suite writes may land in the machine's shared compiler "
            + "temp directory — no test here shuts an orchestrator down, so nothing "
            + "would ever remove it")
    }

    /// **`TranslationPipelineTests.FakeWorld`'s environment, re-pointed at a
    /// pipeline this suite owns.**
    ///
    /// The fake configures its OWN pipeline in `init`, and its translator legs
    /// end by resuming *that* one (`end(with:)` calls
    /// `world.pipeline.translatorRunEnded`). A desk mounted over a second
    /// pipeline built from the same closures would therefore start leg 1 and
    /// wait for ever. So the two translator legs are rewritten here to resume
    /// the instance the run is actually given — the only two closures that
    /// resume anything — and `saveRound`/`onRoundEnded` are pointed at the
    /// project's real round store and the real event, which is the production
    /// wiring this test is about.
    private func runPipeline(over world: TranslationPipelineTests.FakeWorld,
                              projectURL: URL) -> TranslationPipeline {
        let pipeline = TranslationPipeline()
        var environment = world.environment()
        var runs = 0
        func end(_ outcome: TranslatorOrchestrator.RunSummary.Outcome,
                 _ docId: String, _ language: String) -> String {
            runs += 1
            let runId = "desk-run-\(runs)"
            Task {
                pipeline.translatorRunEnded(.init(runId: runId, docId: docId,
                                                  language: language, at: Date(),
                                                  outcome: outcome))
            }
            return runId
        }
        environment.runTranslation = { docId, language in
            world.record("translate")
            return end(world.translateOutcome, docId, language)
        }
        environment.runFix = { docId, language, notes, isFinal in
            world.record("fix")
            return end(world.fixAnswer(notes, isFinal), docId, language)
        }
        environment.saveRound = { try? TranslationRoundStore(projectURL: projectURL).append($0) }
        environment.onRoundEnded = {
            MaughamEvent.postTranslationRoundEnded(projectURL: projectURL, round: $0)
        }
        pipeline.configure(environment: environment)
        return pipeline
    }

    private static func blankManifest(
        productionRoles: [ProductionRole] = []) -> ProjectManifest {
        ProjectManifest(type: .novel, title: "T", author: "A",
                        created: Date(), modified: Date(),
                        structure: [], research: [],
                        productionRoles: productionRoles)
    }

    // MARK: - Helpers: a design round's own project (Task 4)

    /// A project the designer loop can actually be briefed for, and the
    /// production `Environment` over it — so a test can assert against the
    /// briefing's own refusals rather than against a re-statement of them.
    ///
    /// `publishTree`/`manuscript` are `DesignerEnvironmentTests.makeHarness`'
    /// two switches, for its reason: they are the two premises `briefRound`
    /// refuses without, and this desk has to refuse the same two in words.
    private struct DesignFixture {
        let projectURL: URL
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let environment: DesignerOrchestrator.Environment
    }

    private func makeDesignProject(
        publishTree: Bool = true, manuscript: Bool = true
    ) async throws -> DesignFixture {
        let tmp = TestTemp.root
            .appendingPathComponent("DRT-design-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        var structure: [StructureItem] = []
        if manuscript {
            try FileManager.default.createDirectory(
                at: tmp.appendingPathComponent("manuscript"),
                withIntermediateDirectories: true)
            try "# The Fog\n\nIt came on little cat feet."
                .write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
            structure = [StructureItem(id: "doc-1", title: "Chapter 1",
                                       type: .document, path: "manuscript/c1.md")]
        }
        if publishTree {
            // `PublishStarter.isInitialized` asks for exactly this file, and
            // `install` needs bundle resources a unit test host has no business
            // depending on. What the gate reads is what the fixture writes.
            let publish = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
            try FileManager.default.createDirectory(
                at: publish, withIntermediateDirectories: true)
            try "\\documentclass{book}\n\\begin{document}\n\\end{document}\n"
                .write(to: publish.appendingPathComponent("template.tex"),
                       atomically: true, encoding: .utf8)
        }

        let manifest = ProjectManifest(
            type: .novel, title: "The Project", author: "A",
            created: Date(), modified: Date(), structure: structure, research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let projectStore = try await ProjectStore.load(from: tmp)
        let documentStore = try await DocumentStore.open(url: tmp)
        projectStore.documentStore = documentStore
        if manuscript {
            let doc = try await Document.load(
                url: tmp.appendingPathComponent("manuscript/c1.md"),
                device: "test", session: "s", presenter: nil)
            documentStore.register(document: doc, for: "manuscript/c1.md")
        }

        let configURL = tmp.appendingPathComponent("designer-mcp.json")
        var environment = DesignerOrchestrator.Environment.production(
            store: projectStore, projectURL: tmp,
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "DesignDesk-\(UUID())")!),
            onRunEnded: { _ in })
        // The one thing production does here that a test host must not: write a
        // bridge config next to a real `claude`.
        environment.writeMCPConfig = {
            try Data("{}".utf8).write(to: configURL, options: .atomic)
            return configURL
        }

        return DesignFixture(projectURL: tmp, projectStore: projectStore,
                             documentStore: documentStore, environment: environment)
    }

    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = appSourceDir.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }
}
