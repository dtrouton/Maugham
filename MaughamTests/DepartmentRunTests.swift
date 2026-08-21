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
/// `DepartmentRunState` and `DepartmentRunTarget`, so the truth tables are driven
/// from literals; the mounted tests at the end are only about a writer being able
/// to see and press what the tables decide.
@MainActor
final class DepartmentRunTests: XCTestCase {

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
            DepartmentRunTarget.resolve(subject: .item("doc-1"),
                                        structure: Self.structure, isOpen: open),
            .ready(docId: "doc-1", title: "Chapter 1"),
            "the tree names an open chapter — that is the run's document")

        for subject: BinderSubject? in [nil, .project, .item("grp"),
                                        .research("r-1"), .item("doc-2"),
                                        .item("nonesuch")] {
            let target = DepartmentRunTarget.resolve(
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
        let closed = DepartmentRunTarget.resolve(
            subject: .item("doc-2"), structure: Self.structure, isOpen: { _ in false })
        XCTAssertNil(closed.docId)

        let opened = DepartmentRunTarget.resolve(
            subject: .item("doc-2"), structure: Self.structure,
            isOpen: { $0 == "manuscript/c2.md" })
        XCTAssertEqual(opened, .ready(docId: "doc-2", title: "Chapter 2"),
                       "…and the same chapter IS one once the window holds it")
    }

    /// The refusal tells the writer what to do, in the words the plan's constraint
    /// names. A sentence that only reported the state ("no document selected")
    /// would be a diagnosis where an instruction belongs.
    func test_theRefusalSaysWhatToDoAboutIt() {
        let words = DepartmentRunTarget.openAChapter.lowercased()
        XCTAssertTrue(words.contains("open"), DepartmentRunTarget.openAChapter)
        XCTAssertTrue(words.contains("chapter"), DepartmentRunTarget.openAChapter)
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
        let target = DepartmentRunTarget.ready(docId: "doc-1", title: "Chapter 1")

        XCTAssertEqual(state("es", target: target, runState: running).phase,
                       .running(translating: 4))
        XCTAssertEqual(state("fr", target: target, runState: running).phase, .idle,
                       "another edition of the same chapter is not this round")
        XCTAssertEqual(
            state("es", target: .ready(docId: "doc-2", title: "Chapter 2"),
                  runState: running).phase,
            .idle,
            "…and the same edition of another chapter is not this round either")
    }

    /// The two endings a row draws for itself, scoped the same way.
    func test_aRoundThatEndedSaysWhichEditionItEnded() {
        let target = DepartmentRunTarget.ready(docId: "doc-1", title: "Chapter 1")
        let died = TranslatorOrchestrator.RunState.failed(
            docId: "doc-1", language: "es", failure: .run(.timedOut), at: Date())
        XCTAssertEqual(state("es", target: target, runState: died).phase,
                       .failed(.run(.timedOut)))
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
        let target = DepartmentRunTarget.ready(docId: "doc-1", title: "Chapter 1")
        let line = state("es", target: target,
                         runState: .nothingToTranslate(docId: "doc-1", language: "es",
                                                       at: Date())).statusLine
        XCTAssertEqual(line, DepartmentRunState.nothingToTranslateLine)
        XCTAssertFalse(DepartmentRunState.nothingToTranslateLine.isEmpty)
    }

    // MARK: - Constraint 2: a refused click gets words

    /// **One session, so every Run refuses while one is warm** — and the refusal
    /// names the edition being translated, because a writer with four rows needs to
    /// know which one is holding the session.
    func test_everyRowRefusesWhileTheOneSessionIsBusyAndSaysWhoHasIt() {
        let target = DepartmentRunTarget.ready(docId: "doc-1", title: "Chapter 1")
        let busy = DepartmentRunSession.busy(language: "es")

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
        let target = DepartmentRunTarget.ready(docId: "doc-1", title: "Chapter 1")
        let preparing = DepartmentRunSession.read(runState: .idle, isRunning: true)
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
        XCTAssertEqual(DepartmentRunSession.read(runState: .idle, isRunning: false),
                       .free)
        XCTAssertEqual(
            DepartmentRunSession.read(
                runState: .running(docId: "d", language: "pt-BR", translating: 2),
                isRunning: true),
            .busy(language: "pt-BR"))
        XCTAssertEqual(
            DepartmentRunSession.read(
                runState: .failed(docId: "d", language: "es",
                                  failure: .run(.timedOut), at: Date()),
                isRunning: false),
            .free,
            "a round that ended badly is not a session still holding the desk")
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
        let target = DepartmentRunTarget.ready(docId: "doc-1", title: "Chapter 1")

        for tag in ["es", "pt-br", "fr"] {
            XCTAssertNil(
                DepartmentRunState.preflight(language: tag, target: target,
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
            let refusal = DepartmentRunState.preflight(
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
        let refusal = DepartmentRunState.preflight(
            language: "es",
            target: .unavailable(DepartmentRunTarget.openAChapter),
            session: .busy(language: "fr"))
        XCTAssertEqual(refusal,
                       DepartmentRunState.busyReason(language: "fr"))
    }

    /// **The third abandon arm is closed by Constraint 1's gate, not by a message.**
    ///
    /// `TranslatorEnvironment`'s briefing answers `nil` in two cases, and the
    /// orchestrator abandons silently for both. One is the language tag, refused
    /// above. The other is a document whose current paragraphs cannot be resolved —
    /// and `currentParagraphState` resolves an OPEN document straight off the
    /// registry, which is exactly what `DepartmentRunTarget.ready` guarantees. So
    /// the arm is unreachable from the desk rather than unhandled by it.
    ///
    /// This is the test rather than the sentence, because the claim is about
    /// another file's behaviour: if `currentParagraphState` ever grows a way to
    /// refuse an open document, the desk needs a message and this goes red.
    func test_theBriefingAbandonIsClosedByTheOpenDocumentGate() async throws {
        let h = try await makeProject()

        let target = DepartmentRunTarget.resolve(
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
        let line = try? XCTUnwrap(DepartmentRunState.reportLine(
            .ingested(.init(entriesWritten: 12, queriesMinted: 2))))
        XCTAssertTrue(line?.contains("12") ?? false, line ?? "nil")
        XCTAssertTrue(line?.contains("2") ?? false, line ?? "nil")

        let quiet = try? XCTUnwrap(DepartmentRunState.reportLine(
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
        let line = try? XCTUnwrap(DepartmentRunState.reportLine(
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
            DepartmentRunState.reportLine(.ingested(.init(rejection: rejection))),
            rejection,
            "the report carries the pipeline's sentence rather than a summary of it")

        // …and the same sentence arriving as the run STATE (which is how the
        // orchestrator surfaces it) reads the same way on the row.
        let target = DepartmentRunTarget.ready(docId: "doc-1", title: "Chapter 1")
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
        let line = DepartmentRunState.reportLine(.cancelled)
        XCTAssertEqual(line, DepartmentRunState.cancelledLine)
        for failure: CompilerRunFailure in [.timedOut, .unusableOutput, .cliNotFound] {
            XCTAssertNotEqual(
                line, DepartmentRunState.failureCopy(.run(failure)),
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
                                            .unusableOutput, .timedOut] {
            XCTAssertNotEqual(
                DepartmentRunState.failureCopy(.run(failure)),
                RoundNarrative.failureCopy(failure),
                "\(failure) reads as the compiler's on the department desk")
            XCTAssertFalse(
                DepartmentRunState.failureCopy(.run(failure)).isEmpty)
        }
        // The arms that name a surface rather than the work are shared verbatim —
        // "Claude Code isn't installed" is the same instruction whoever asked.
        XCTAssertEqual(DepartmentRunState.failureCopy(.run(.cliNotFound)),
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

        let mine = DepartmentRunState.resolve(
            language: "es",
            target: .ready(docId: "doc-1", title: "Chapter 1"),
            session: .free, runState: .idle, lastRun: summary)
        XCTAssertNotNil(mine.report)

        let elsewhere = DepartmentRunState.resolve(
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

    // MARK: - Mounted: what a writer can see and press

    /// **The reason is on screen, not only in a tooltip.** A disabled button whose
    /// explanation lives in a hover is an explanation most writers never read;
    /// Constraint 1 asks for the reason to be visible, so the desk says it once
    /// above the rows it applies to.
    func test_aDeskWithNoOpenChapterSaysSoWhereTheRowsAre() async throws {
        let window = mount(languages: ["es"],
                           target: .unavailable(DepartmentRunTarget.openAChapter))
        _ = try await scrollersSettling(in: window)

        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains(DepartmentRunTarget.openAChapter) },
                      "the desk drew no reason at all. Published: \(texts.sorted())")
    }

    /// …and the button itself refuses. Read off the accessibility tree, which is
    /// what a writer's keyboard and VoiceOver read.
    func test_theRunButtonRefusesWithNoOpenChapterAndAcceptsWithOne() async throws {
        let refusing = mount(languages: ["es"],
                             target: .unavailable(DepartmentRunTarget.openAChapter))
        _ = try await scrollersSettling(in: refusing)
        let disabled = try axButtons(labelled: DepartmentRunState.runTitle,
                                     in: refusing)
        XCTAssertEqual(disabled.count, 1,
                       "the row must still OFFER the run — a control that vanishes "
                       + "teaches nothing about why it is not available")
        XCTAssertEqual(axEnabled(disabled[0]), false)

        let ready = mount(languages: ["es"],
                          target: .ready(docId: "doc-1", title: "Chapter 1"))
        _ = try await scrollersSettling(in: ready)
        let live = try axButtons(labelled: DepartmentRunState.runTitle, in: ready)
        XCTAssertEqual(axEnabled(live[0]), true,
                       "…and an open chapter makes it pressable, or this test "
                       + "could pass over a button that is never enabled")
    }

    /// **The row's Run runs the ROW's edition** — two rows, and the second one's
    /// press must name `fr`. Pressed through the accessibility tree, which is the
    /// same action a click performs and does not depend on this process being the
    /// active app (CLAUDE.md's synthetic-click premise).
    func test_pressingARowsRunNamesThatRowsEdition() async throws {
        var asked: [String] = []
        let window = mount(languages: ["es", "fr"],
                           target: .ready(docId: "doc-1", title: "Chapter 1"),
                           runTranslation: { asked.append($0) })
        _ = try await scrollersSettling(in: window)

        let runs = try axButtons(labelled: DepartmentRunState.runTitle, in: window)
        XCTAssertEqual(runs.count, 2, "one Run per edition")
        press(runs[1])
        _ = await pumpUntil(deadline: 3) { !asked.isEmpty }

        XCTAssertEqual(asked, ["fr"],
                       "the second row's Run asked for \(asked) — a verb that "
                       + "captured the wrong row's tag would ask for the first")
    }

    /// **Cancel appears on the row that is running and nowhere else.** The cockpit's
    /// rule: there is nothing to cancel from an idle row, and a Cancel drawn on a
    /// row whose edition is not in flight would end somebody else's round.
    func test_cancelIsOfferedOnlyByTheRowThatIsRunning() async throws {
        var cancels = 0
        let window = mount(
            languages: ["es", "fr"],
            target: .ready(docId: "doc-1", title: "Chapter 1"),
            runState: .running(docId: "doc-1", language: "es", translating: 4),
            isRunning: true,
            cancelRun: { cancels += 1 })
        _ = try await scrollersSettling(in: window)

        let cancelButtons = try axButtons(labelled: DepartmentRunState.cancelTitle,
                                          in: window)
        XCTAssertEqual(cancelButtons.count, 1,
                       "exactly the running row offers a way out")

        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains(DepartmentRunState.translating(4)) },
                      "…and says what it is doing rather than spinning: "
                      + "\(texts.sorted())")

        press(cancelButtons[0])
        _ = await pumpUntil(deadline: 3) { cancels > 0 }
        XCTAssertEqual(cancels, 1)
    }

    /// **One message channel** (Task 2's concern 5). A refusal the writer earned by
    /// pressing Run lands in the same `notice` slot the brief door's refusal uses —
    /// two message lines on one pane is two places to look for one answer.
    func test_aRefusalTheWriterEarnedLandsInTheDesksOneNoticeSlot() async throws {
        let refusal = DepartmentRunState.unusableTag(language: "not a tag!")
        let window = mount(languages: ["es"],
                           target: .ready(docId: "doc-1", title: "Chapter 1"),
                           notice: refusal)
        _ = try await scrollersSettling(in: window)

        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains(refusal) },
                      "the refusal never reached the writer. Published: "
                      + "\(texts.sorted())")
    }

    /// The census that keeps the fold honest: the pane has ONE transient-message
    /// input, and a second one arriving later is what this goes red on.
    func test_theDeskCarriesOneMessageChannelAndNotTwo() throws {
        let code = try Self.codeLines(of: "Views/Publish/DepartmentPane.swift")
        let messageInputs = code.filter {
            $0.contains("var notice") || $0.contains("var message")
                || $0.contains("var refusalMessage") || $0.contains("var messages")
        }
        XCTAssertEqual(messageInputs.count, 1,
                       "the desk must carry exactly one transient-message input; "
                       + "found \(messageInputs)")
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
                DepartmentDesignRow.statusWord(.pending)),
            "where it stands is half the line: \(row.latestLine)")
        XCTAssertTrue(
            row.latestLine.contains(
                DepartmentDesignRow.age(now.addingTimeInterval(-600), now: now)),
            "…and how long ago is the other half: \(row.latestLine)")
    }

    /// A project nobody has asked for a design of says so, rather than leaving a
    /// blank under the designer's name where a line goes.
    func test_aProjectWithNoRoundYetSaysSoRatherThanDrawingNothing() {
        let row = designRow(proposals: [])
        XCTAssertEqual(row.latestLine, DepartmentDesignRow.noRoundYet)
        XCTAssertFalse(DepartmentDesignRow.noRoundYet.isEmpty)
        XCTAssertNil(row.pendingBadge, "nothing staged, nothing pending")
    }

    /// **The badge is for a proposal still waiting on the writer**, and for no
    /// other status: it is the one thing on this row asking them for something.
    func test_theBadgeMarksAProposalStillWaitingOnTheWriter() {
        XCTAssertEqual(
            designRow(proposals: [proposal(round: 1, status: .pending)]).pendingBadge,
            DepartmentDesignRow.pendingBadgeTitle)

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

        XCTAssertEqual(row.statusLine, DepartmentDesignRow.designingLine(
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
                runState: .failed(failure: .run(.timedOut), at: Date()),
                isRunning: false),
            .free,
            "a round that ended badly is not a session still holding the desk")
    }

    /// **A round started for an EDITION says so**, even though this desk starts
    /// none: the milestone's ruling is `language: nil`, but the orchestrator can
    /// be driven from elsewhere and a row that dropped the edition would draw
    /// somebody else's round as the book's.
    func test_aRoundForAnEditionIsNotDrawnAsTheBooksOwn() {
        let line = DepartmentDesignRow.designingLine(round: 1, language: "es")
        XCTAssertTrue(
            line.contains(TranslationReviewIndicator.displayLabel(forLanguageTag: "es")),
            line)
        XCTAssertNotEqual(line, DepartmentDesignRow.designingLine(round: 1,
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
                                            .unusableOutput, .timedOut] {
            XCTAssertNotEqual(
                DepartmentDesignRow.failureCopy(.run(failure)),
                RoundNarrative.failureCopy(failure),
                "\(failure) reads as the compiler's on the Design row")
            XCTAssertFalse(DepartmentDesignRow.failureCopy(.run(failure)).isEmpty)
        }
        // The arms that name a surface rather than the work are shared verbatim.
        XCTAssertEqual(DepartmentDesignRow.failureCopy(.run(.cliNotFound)),
                       RoundNarrative.failureCopy(.cliNotFound))
        // …and it is a third account, not the translator's with a new label.
        XCTAssertNotEqual(DepartmentDesignRow.failureCopy(.run(.timedOut)),
                          DepartmentRunState.failureCopy(.run(.timedOut)))
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
        XCTAssertNotEqual(row.latestLine, DepartmentDesignRow.noRoundYet,
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
        let busy = DepartmentDesignRow.changesRefusal(
            words: "warmer paper", session: .busy(round: 2),
            hasOpenProposalRound: true)
        XCTAssertEqual(busy, DepartmentDesignRow.busyReason(round: 2),
                       "a round in flight outranks everything else")

        let wordless = DepartmentDesignRow.changesRefusal(
            words: "   \n ", session: .free, hasOpenProposalRound: true)
        XCTAssertEqual(wordless, DepartmentDesignRow.noWordsRefusal)

        let closed = DepartmentDesignRow.changesRefusal(
            words: "warmer paper", session: .free, hasOpenProposalRound: false)
        XCTAssertEqual(closed, DepartmentDesignRow.noOpenRoundRefusal)
        XCTAssertTrue(closed.lowercased().contains("run"),
                      "the refusal must point at the verb that DOES work: \(closed)")

        for sentence in [busy, wordless, closed,
                         DepartmentDesignRow.unknownRefusal] {
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
        XCTAssertNil(DepartmentDesignRow.preflight(session: .free,
                                                   briefability: .ready),
                     "a project that can be briefed must let the click through")

        for arm: DesignBriefability in [.noPublishTemplates, .noBook] {
            let refusal = DepartmentDesignRow.preflight(session: .free,
                                                        briefability: arm)
            XCTAssertFalse(refusal?.isEmpty ?? true,
                           "\(arm) reaches the orchestrator, where it abandons "
                           + "in silence")
        }
        XCTAssertNotEqual(DepartmentDesignRow.noPublishTemplatesRefusal,
                          DepartmentDesignRow.noBookRefusal,
                          "two different problems, two different moves")
        // An instruction rather than a diagnosis, as Constraint 2 asks.
        XCTAssertTrue(
            DepartmentDesignRow.noPublishTemplatesRefusal.lowercased()
                .contains("set up publishing"),
            DepartmentDesignRow.noPublishTemplatesRefusal)

        // …and a round in flight still outranks both.
        XCTAssertEqual(
            DepartmentDesignRow.preflight(session: .busy(round: 1),
                                          briefability: .noBook),
            DepartmentDesignRow.busyReason(round: 1))
    }

    /// **The desk asks the same two questions the briefing asks**, against a
    /// real project — the premise being the briefing's own `nil`, so this cannot
    /// pass by agreeing with a gate that stopped refusing.
    func test_theDesksBriefabilityAgreesWithTheBriefingsOwnRefusals() async throws {
        let full = try await makeDesignProject()
        XCTAssertEqual(
            DepartmentDesignRow.briefability(store: full.projectStore,
                                             projectURL: full.projectURL),
            .ready)
        let fullInputs = await full.environment.briefRound(nil, nil)
        XCTAssertNotNil(fullInputs, "premise: the briefing accepts this project")
        await full.documentStore.close()

        let noTemplates = try await makeDesignProject(publishTree: false)
        XCTAssertEqual(
            DepartmentDesignRow.briefability(store: noTemplates.projectStore,
                                             projectURL: noTemplates.projectURL),
            .noPublishTemplates)
        let noTemplateInputs = await noTemplates.environment.briefRound(nil, nil)
        XCTAssertNil(noTemplateInputs,
                     "premise: the briefing refuses a project with no templates")
        await noTemplates.documentStore.close()

        let noBook = try await makeDesignProject(manuscript: false)
        XCTAssertEqual(
            DepartmentDesignRow.briefability(store: noBook.projectStore,
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

        let source = ProjectStoreASTSource(projectStore: h.projectStore)
        let ast = try ProjectASTBuilder.build(from: source)

        XCTAssertEqual(source.publishablePieces().map(\.id), ["doc-1"],
                       "a reference and a pathless row are not pieces")
        XCTAssertEqual(source.publishablePieces().count, ast.sections.count,
                       "the desk's question and the briefing's must agree")

        await h.documentStore.close()
    }

    // MARK: - Task 4: mounted

    /// **A project with nothing in it still offers a design round**, which is
    /// why Task 1's empty state is gone: every project has a designer from the
    /// moment it exists, and asking for the book's first design is exactly what
    /// a writer with an empty department came to the desk to do.
    func test_aProjectWithNothingInItStillOffersADesignRound() async throws {
        let window = mount(languages: [],
                           target: .unavailable(DepartmentRunTarget.openAChapter))
        _ = try await scrollersSettling(in: window)

        let runs = try axButtons(labelled: DepartmentDesignRow.runAccessibilityLabel,
                                 in: window)
        XCTAssertEqual(runs.count, 1, "the Design row's Run must be here")
        XCTAssertEqual(axEnabled(runs[0]), true,
                       "…and pressable: a design round needs no open chapter")

        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains(DepartmentDesignRow.noRoundYet) },
                      "…and the row says where the design stands. Published: "
                      + "\(texts.sorted())")
    }

    /// **The Design row's Run and the language rows' are distinct controls in
    /// the tree.** All three read "Run" on screen, told apart by the row they
    /// sit on — which a linear accessibility tree does not carry, so the design
    /// verb carries a label of its own. Without it a keyboard or VoiceOver user
    /// choosing "Run" would be choosing at random between designing the book and
    /// translating a chapter.
    func test_theDesignRunIsItsOwnControlAndNotAFourthLanguageRun() async throws {
        let window = mount(languages: ["es", "fr"],
                           target: .ready(docId: "doc-1", title: "Chapter 1"))
        _ = try await scrollersSettling(in: window)

        XCTAssertEqual(
            try axButtons(labelled: DepartmentRunState.runTitle, in: window).count, 2,
            "one Run per edition, and the design verb is not one of them")
        XCTAssertEqual(
            try axButtons(labelled: DepartmentDesignRow.runAccessibilityLabel,
                          in: window).count, 1)
    }

    /// Pressing it asks for a round. A bare press carries no direction — the
    /// field is empty, and an empty direction is `nil` rather than `""`, because
    /// a round briefed on "" is one told the writer said something.
    func test_pressingTheDesignRunAsksForARoundWithNoDirection() async throws {
        var asked: [String?] = []
        let window = mount(languages: [],
                           target: .unavailable(DepartmentRunTarget.openAChapter),
                           runDesign: { asked.append($0); return true })
        _ = try await scrollersSettling(in: window)

        press(try axButtons(labelled: DepartmentDesignRow.runAccessibilityLabel,
                            in: window)[0])
        _ = await pumpUntil(deadline: 3) { !asked.isEmpty }

        XCTAssertEqual(asked.count, 1)
        XCTAssertNil(asked[0], "an empty box is no direction at all")
    }

    /// **Request Changes is drawn only while there is something to change.**
    func test_requestChangesIsDrawnOnlyWhileTheSessionCanReviseSomething() async throws {
        let closed = mount(languages: [],
                           target: .unavailable(DepartmentRunTarget.openAChapter),
                           design: designRow(hasOpenProposalRound: false))
        _ = try await scrollersSettling(in: closed)
        XCTAssertTrue(
            try axButtons(labelled: DepartmentDesignRow.requestChangesTitle,
                          in: closed).isEmpty,
            "with no open round the honest verb is Run, and it is already here")

        var sent: [String] = []
        let open = mount(languages: [],
                         target: .unavailable(DepartmentRunTarget.openAChapter),
                         design: designRow(hasOpenProposalRound: true),
                         requestDesignChanges: { sent.append($0); return true })
        _ = try await scrollersSettling(in: open)
        let buttons = try axButtons(
            labelled: DepartmentDesignRow.requestChangesTitle, in: open)
        XCTAssertEqual(buttons.count, 1)

        press(buttons[0])
        _ = await pumpUntil(deadline: 3) { !sent.isEmpty }
        XCTAssertEqual(sent, [""],
                       "the writer's words travel verbatim — including none, "
                       + "which is what earns them the refusal")
    }

    /// **A refusal the design verbs earned lands in the desk's one notice slot**
    /// — the same channel the brief door's refusal and a refused translation use
    /// (Task 3's census). Two message lines on one pane is two places to look
    /// for one answer.
    func test_aRefusedDesignClickLandsInTheDesksOneNoticeSlot() async throws {
        let window = mount(languages: [],
                           target: .unavailable(DepartmentRunTarget.openAChapter),
                           notice: DepartmentDesignRow.noPublishTemplatesRefusal)
        _ = try await scrollersSettling(in: window)

        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains {
                $0.contains(DepartmentDesignRow.noPublishTemplatesRefusal)
            },
            "the refusal never reached the writer. Published: \(texts.sorted())")
    }

    /// **The end-to-end pin: the desk's Design Run drives a REAL round, and the
    /// proposal it stages is signed by the project's own designer.**
    ///
    /// `ReviewRoundCockpitTests.test_theRunButtonDrivesARealRoundWhoseNotesTheEditorSigns`
    /// is the precedent, and the reason it exists is that nothing else proves
    /// the wiring: `DepartmentRunTests`' other cases drive the decisions and the
    /// controls, `DesignerOrchestratorTests` drives the loop, and neither of them
    /// would notice a host that passed the wrong closure. Here the whole path
    /// runs: the real `DepartmentPaneHost`, the real pane, the button pressed the
    /// way a click presses it, the real pre-flight, the real
    /// `DesignerOrchestrator`, the real briefing over a real project, and the
    /// real `DesignProposalStore` at the end of it — then the desk re-derives and
    /// draws the round it just produced, which is the loop closing.
    ///
    /// **Two substitutions, both stated.** The subprocess, as always. And the
    /// sample compile: production's `stage` runs tectonic over the proposal, and
    /// a real typeset here would buy nothing this test is about at the cost of a
    /// `TectonicProbe` dependency and a multi-second run. What is NOT
    /// substituted is the staging itself — the proposal is written by the store,
    /// read back off disk, and drawn.
    func test_theDesignRunDrivesARealRoundWhoseProposalTheDesignerSigns() async throws {
        let h = try await makeDesignProject()
        let runner = DesignSpyRunner()
        let staged = Box<[DesignProposalStore.Proposal]>([])
        let store = DesignProposalStore(projectURL: h.projectURL)

        var environment = h.environment
        environment.makeRunner = { _, _ in runner }
        environment.stage = { report, context in
            do {
                let proposal = try store.stage(report: report, round: context.round,
                                               designerName: context.designerName,
                                               language: context.language)
                staged.value.append(proposal)
                return .init(proposalId: proposal.id, filesStaged: proposal.filePaths.count)
            } catch {
                return .init(rejection: "\(error)")
            }
        }
        let designer = DesignerOrchestrator()
        designer.configure(environment: environment)
        defer { designer.shutdown() }

        let window = mountHost(h, designer: designer)
        _ = try await scrollersSettling(in: window)

        press(try axButtons(labelled: DepartmentDesignRow.runAccessibilityLabel,
                            in: window)[0])
        _ = await pumpUntil(deadline: 10) { !staged.value.isEmpty }

        let proposal = try XCTUnwrap(
            staged.value.first,
            "the desk's Run never reached a real round — the wiring, not the "
            + "decisions, is what this test is about")
        XCTAssertEqual(proposal.round, 1)
        XCTAssertEqual(proposal.designerName,
                       h.projectStore.designerRole().effectiveName,
                       "the project's own designer signs what the round staged")
        XCTAssertEqual(try store.list().map(\.id), [proposal.id],
                       "…and it is on disk, which is where the desk reads it from")

        // The loop closing: the round ends, the host re-derives, and the row
        // draws the proposal it just made.
        let drew = await pumpUntil(deadline: 10) {
            (try? self.axTexts(in: window))?
                .contains { $0.contains("Round 1") } ?? false
        }
        XCTAssertTrue(drew, "the desk never drew the round it had just run. "
                      + "Published: \((try? axTexts(in: window))?.sorted() ?? [])")

        await h.documentStore.close()
    }

    // MARK: - Task 9: the mint sheet for unlisted languages

    /// **The three ways a language answers "does Run need to ask first?"**
    /// (no window — `DepartmentPaneHost.needsTranslatorName` is a pure read
    /// over `EditionStatus.translatorName`, which is the row's own "No
    /// translator yet" question asked from the other side).
    func test_aPresetLanguageNeverNeedsTheMintSheet() {
        XCTAssertFalse(
            DepartmentPaneHost.needsTranslatorName(language: "es", in: Self.blankManifest()),
            "es has a preset translator (Cort\u{e1}zar) \u{2014} the sheet exists for "
            + "languages nobody has named, and es is never one of them")
    }

    func test_anUnlistedUnmintedLanguageNeedsTheMintSheet() {
        XCTAssertTrue(
            DepartmentPaneHost.needsTranslatorName(language: "xx", in: Self.blankManifest()),
            "xx has no preset and no stored role \u{2014} translatorRole(for:) would "
            + "mint one named nothing but the tag, unasked")
    }

    func test_anAlreadyMintedUnlistedLanguageNeedsNoSheet() {
        let stored = ProductionRole(id: "role-1", role: .translator(language: "xx"), name: nil)
        let manifest = Self.blankManifest(productionRoles: [stored])
        XCTAssertFalse(
            DepartmentPaneHost.needsTranslatorName(language: "xx", in: manifest),
            "a role already stored for this language \u{2014} even one still unnamed "
            + "\u{2014} answers `effectiveName` with the uppercased tag rather than nil, "
            + "and a run must not interrupt an edition the desk has already minted")
    }

    // MARK: - Task 9: the sheet itself (no host)

    /// **Every string the sheet draws is `DepartmentMintCopy`'s** — the
    /// `DepartmentDesk` split, so the whole surface is assertable with
    /// nothing but the language it was given.
    func test_theMintSheetNamesTheEditionItIsAskingAbout() async throws {
        let window = mountMintSheet(language: "pt-br")
        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains { $0.contains(DepartmentMintCopy.title(language: "pt-br")) },
            "the sheet never said which edition it wants a name for. Published: "
            + "\(texts.sorted())")
        XCTAssertTrue(texts.contains { $0.contains(DepartmentMintCopy.explanation) },
                      "…nor why. Published: \(texts.sorted())")
    }

    /// **Confirm refuses a blank name** — a translator signed "" is the thing
    /// `renameProductionRole`'s own `.productionRoleNameEmpty` refusal exists
    /// against, and the sheet must not let a click reach it.
    func test_theMintSheetsConfirmIsDisabledUntilANameIsTyped() async throws {
        let window = mountMintSheet(language: "xx")
        let blank = try axButtons(labelled: DepartmentMintCopy.confirmTitle, in: window)
        XCTAssertEqual(blank.count, 1)
        XCTAssertEqual(axEnabled(blank[0]), false,
                       "an empty field must not offer a way to confirm nothing")

        let field = try XCTUnwrap(textField(placeholder: DepartmentMintCopy.placeholder,
                                            in: window),
                                  "the sheet mounted no name field at all")
        type("Constance Garnett", into: field)
        pump(0.1)

        let named = try axButtons(labelled: DepartmentMintCopy.confirmTitle, in: window)
        XCTAssertEqual(axEnabled(named[0]), true,
                       "…and a typed name must make it pressable, or this test "
                       + "could pass over a button that never enables")
    }

    /// **Confirm sends the trimmed name; Cancel backs out with no name at
    /// all.** Both closures, so a sheet that silently swallowed either verb
    /// would be caught here rather than only at the host.
    func test_theMintSheetSendsTheTrimmedNameAndCancelSendsNothing() async throws {
        var named: [String] = []
        var cancelled = 0
        let window = mountMintSheet(language: "xx",
                                    onName: { named.append($0) },
                                    onCancel: { cancelled += 1 })
        let field = try XCTUnwrap(textField(placeholder: DepartmentMintCopy.placeholder,
                                            in: window))
        type("  Constance Garnett  ", into: field)
        pump(0.1)
        press(try axButtons(labelled: DepartmentMintCopy.confirmTitle, in: window)[0])
        _ = await pumpUntil(deadline: 3) { !named.isEmpty }
        XCTAssertEqual(named, ["Constance Garnett"],
                       "the sheet must trim what it sends \u{2014} `renameProductionRole` "
                       + "trims too, but a name padded with the writer's own spaces should "
                       + "never reach it in the first place")

        press(try axButtons(labelled: DepartmentMintCopy.cancelTitle, in: window)[0])
        _ = await pumpUntil(deadline: 3) { cancelled > 0 }
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(named, ["Constance Garnett"], "Cancel must not also send a name")
    }

    // MARK: - Task 9: the whole desk, wired to a real translator loop

    /// **Run on an unlisted, unminted edition shows the sheet — and
    /// nothing else happens.** Nothing is minted, nothing is renamed, and the
    /// run never reaches `TranslatorOrchestrator`: `translatorIdentity` (the
    /// orchestrator's own mint) is never asked, which is the one signal that
    /// distinguishes "the sheet interposed" from "the run merely hasn't
    /// finished yet".
    func test_anUnlistedLanguageShowsTheSheetBeforeAnythingRuns() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "xx")
        let window = mountTranslatorHost(fixture)
        _ = try await scrollersSettling(in: window)

        press(try axButtons(labelled: DepartmentRunState.runTitle, in: window)[0])

        let sheet = await attachedSheetWindow(of: window)
        let sheetWindow = try XCTUnwrap(sheet, "Run on an unnamed edition must show the "
                                        + "mint sheet before anything runs")
        let texts = try axTexts(in: sheetWindow)
        XCTAssertTrue(
            texts.contains { $0.contains(DepartmentMintCopy.title(language: "xx")) },
            "Published: \(texts.sorted())")

        XCTAssertTrue(fixture.projectStore.manifest.productionRoles.isEmpty,
                      "opening the sheet must mint nothing — only Confirm does")
        XCTAssertFalse(fixture.translator.isRunning,
                       "the run must not have reached the orchestrator")
        XCTAssertTrue(fixture.runner.sends.isEmpty,
                      "…and nothing was sent to a session that should not exist yet")

        await fixture.documentStore.close()
    }

    /// **Cancel aborts the run visibly and mints nothing** (Global Constraint
    /// 2 — the one notice channel, said before the run rather than during
    /// it).
    func test_cancellingTheSheetAbortsVisiblyAndMintsNothing() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "xx")
        let window = mountTranslatorHost(fixture)
        _ = try await scrollersSettling(in: window)

        press(try axButtons(labelled: DepartmentRunState.runTitle, in: window)[0])
        let sheet = await attachedSheetWindow(of: window)
        let sheetWindow = try XCTUnwrap(sheet)
        press(try axButtons(labelled: DepartmentMintCopy.cancelTitle, in: sheetWindow)[0])

        _ = await pumpUntil(deadline: 5) { window.attachedSheet == nil }
        XCTAssertNil(window.attachedSheet, "the sheet must actually close on Cancel")

        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains { $0.contains(DepartmentMintCopy.cancelledLine(language: "xx")) },
            "the abandon must be said in words, in the desk's one notice slot. "
            + "Published: \(texts.sorted())")

        XCTAssertTrue(fixture.projectStore.manifest.productionRoles.isEmpty,
                      "Cancel must mint nothing")
        XCTAssertFalse(fixture.translator.isRunning)
        XCTAssertTrue(fixture.runner.sends.isEmpty)

        await fixture.documentStore.close()
    }

    /// **Confirm names the translator and runs the round it was standing in
    /// front of, in one visible act.** The mint and the rename both land on
    /// the manifest, and the run this pane's own `runTarget` resolved earlier
    /// is the one that reaches the orchestrator.
    func test_confirmingTheSheetNamesTheTranslatorAndRunsInOneAct() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "xx")
        let window = mountTranslatorHost(fixture)
        _ = try await scrollersSettling(in: window)

        press(try axButtons(labelled: DepartmentRunState.runTitle, in: window)[0])
        let sheet = await attachedSheetWindow(of: window)
        let sheetWindow = try XCTUnwrap(sheet)
        let field = try XCTUnwrap(textField(placeholder: DepartmentMintCopy.placeholder,
                                            in: sheetWindow))
        type("Constance Garnett", into: field)
        pump(0.1)
        press(try axButtons(labelled: DepartmentMintCopy.confirmTitle, in: sheetWindow)[0])

        _ = await pumpUntil(deadline: 10) {
            !fixture.projectStore.manifest.productionRoles.isEmpty
        }
        let role = try XCTUnwrap(
            fixture.projectStore.manifest.storedTranslator(for: "xx"),
            "Confirm must mint (or find) the role and store it")
        XCTAssertEqual(role.effectiveName, "Constance Garnett",
                       "…and rename it to what the writer typed, as one visible act")

        _ = await pumpUntil(deadline: 10) { !fixture.runner.sends.isEmpty }
        XCTAssertFalse(fixture.runner.sends.isEmpty,
                       "the run the sheet was standing in front of must actually reach "
                       + "the translator's session once the writer has named them")

        _ = await pumpUntil(deadline: 5) { window.attachedSheet == nil }
        XCTAssertNil(window.attachedSheet, "the sheet must close once it is answered")

        await fixture.documentStore.close()
    }

    /// **A preset language never sees the sheet at all** — the control on
    /// the whole file: `es` has a name (Cortázar) before anybody asks, so
    /// Run must reach the orchestrator on the very first click.
    func test_aPresetLanguageRunsStraightThroughWithNoSheet() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "es")
        let window = mountTranslatorHost(fixture)
        _ = try await scrollersSettling(in: window)

        press(try axButtons(labelled: DepartmentRunState.runTitle, in: window)[0])

        _ = await pumpUntil(deadline: 10) { !fixture.runner.sends.isEmpty }
        XCTAssertFalse(fixture.runner.sends.isEmpty,
                       "es must run immediately — nothing here should be waiting on a name")
        XCTAssertNil(window.attachedSheet, "…and the sheet must never have appeared")

        await fixture.documentStore.close()
    }

    /// **The end-to-end pin for the other loop: the desk's language Run drives a
    /// REAL round, and the row draws the report that round produced.**
    ///
    /// `test_theDesignRunDrivesARealRoundWhoseProposalTheDesignerSigns` is its
    /// twin one section down, and it exists for the same reason: nothing else
    /// proves the WIRING. The cases above drive the decisions and the controls,
    /// `TranslatorOrchestratorTests` drives the loop, and neither would notice a
    /// host that passed the wrong closure — or, as here, a desk handed no run
    /// log at all, which draws no report however well the round went. The whole
    /// path runs: the real `DepartmentPaneHost`, the real pane, the button
    /// pressed the way a click presses it, the real pre-flight, the real
    /// `TranslatorOrchestrator`, the real briefing over a real project, the real
    /// ingest, and `onRunEnded` into the window's own `TranslationRunLog` — then
    /// the desk re-derives and draws the round it just ran, which is the loop
    /// closing.
    ///
    /// **One substitution, stated**: the subprocess. The round is answered with
    /// a valid EMPTY report, which is enough — what is under test is that a
    /// finished round becomes a line on the row that asked for it, and "wrote
    /// nothing and asked nothing" is as much a report as any other.
    func test_theLanguageRunDrivesARealRoundWhoseReportTheRowDraws() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "es")
        let window = mountTranslatorHost(fixture)
        _ = try await scrollersSettling(in: window)

        let runs = try axButtons(labelled: DepartmentRunState.runTitle, in: window)
        XCTAssertEqual(runs.count, 1, "one Run for the book's one edition")
        press(runs[0])

        _ = await pumpUntil(deadline: 10) { !fixture.runner.sends.isEmpty }
        XCTAssertFalse(fixture.runner.sends.isEmpty,
                       "the row's Run never reached a real round — the wiring, "
                       + "not the decisions, is what this test is about")

        _ = await pumpUntil(deadline: 10) {
            fixture.runLog.run(docId: "doc-1", language: "es") != nil
        }
        let summary = try XCTUnwrap(
            fixture.runLog.run(docId: "doc-1", language: "es"),
            "the round ended and the window's record of it never heard — "
            + "`onRunEnded` is what turns a finished round into a line")
        XCTAssertEqual(summary.language, "es")

        let landed = DepartmentRunState.landedLine(entries: 0, queries: 0)
        let drew = await pumpUntil(deadline: 10) {
            (try? self.axTexts(in: window))?.contains { $0.contains(landed) } ?? false
        }
        XCTAssertTrue(drew,
                      "the desk never drew the round it had just run. Published: "
                      + "\((try? axTexts(in: window))?.sorted() ?? [])")

        await fixture.documentStore.close()
    }

    /// **An unlisted language whose role was already minted (even unnamed)
    /// runs straight through on the next click** — the sheet answers a
    /// language once, not an edition's every round.
    func test_anAlreadyMintedUnlistedLanguageAlsoRunsStraightThrough() async throws {
        let fixture = try await makeTranslatorFixture(seedLanguage: "xx")
        _ = try await fixture.projectStore.translatorRole(for: "xx")

        let window = mountTranslatorHost(fixture)
        _ = try await scrollersSettling(in: window)

        press(try axButtons(labelled: DepartmentRunState.runTitle, in: window)[0])

        _ = await pumpUntil(deadline: 10) { !fixture.runner.sends.isEmpty }
        XCTAssertFalse(fixture.runner.sends.isEmpty,
                       "a language whose role already exists must not be interrupted again")
        XCTAssertNil(window.attachedSheet)

        await fixture.documentStore.close()
    }

    // MARK: - Helpers: the decisions

    private func designRow(designerName: String = "Tschichold",
                           proposals: [DesignProposalStore.Proposal] = [],
                           runState: DesignerOrchestrator.RunState = .idle,
                           session: DesignSession = .free,
                           hasOpenProposalRound: Bool = false,
                           now: Date = Date()) -> DepartmentDesignRow {
        DepartmentDesignRow.resolve(
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
                       target: DepartmentRunTarget,
                       session: DepartmentRunSession = .free,
                       runState: TranslatorOrchestrator.RunState = .idle,
                       lastRun: TranslatorOrchestrator.RunSummary? = nil)
    -> DepartmentRunState {
        DepartmentRunState.resolve(language: language, target: target,
                                   session: session, runState: runState,
                                   lastRun: lastRun)
    }

    // MARK: - Helpers: hosting

    private func mount(languages: [String],
                       target: DepartmentRunTarget,
                       runState: TranslatorOrchestrator.RunState = .idle,
                       isRunning: Bool = false,
                       notice: String? = nil,
                       design: DepartmentDesignRow = DepartmentDesignRow(),
                       runTranslation: @escaping (String) -> Void = { _ in },
                       cancelRun: @escaping () -> Void = { },
                       runDesign: @escaping (String?) -> Bool = { _ in true },
                       requestDesignChanges: @escaping (String) -> Bool = { _ in true },
                       cancelDesignRun: @escaping () -> Void = { }) -> NSWindow {
        let rows = languages.map {
            EditionStatus.LanguageRow(language: $0, translator: nil,
                                      fresh: 0, stale: 0, missing: 0, openQueries: 0)
        }
        let session = DepartmentRunSession.read(runState: runState,
                                                isRunning: isRunning)
        var runs: [String: DepartmentRunState] = [:]
        for row in rows {
            runs[row.language] = DepartmentRunState.resolve(
                language: row.language, target: target, session: session,
                runState: runState, lastRun: nil)
        }

        let frame = CGRect(x: 0, y: 0, width: 340, height: 600)
        let hosting = NSHostingView(rootView: AnyView(
            DepartmentPane(title: "The Project",
                           languages: rows,
                           design: design,
                           notice: notice,
                           runTarget: target,
                           runs: runs,
                           runTranslation: runTranslation,
                           cancelRun: cancelRun,
                           runDesign: runDesign,
                           requestDesignChanges: requestDesignChanges,
                           cancelDesignRun: cancelDesignRun)
                .frame(maxWidth: .infinity, maxHeight: .infinity)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.1)
        return window
    }

    /// The mint sheet, mounted alone — `DepartmentPaneTests`' own dumb-view
    /// mounting, for the sheet's own file.
    private func mountMintSheet(language: String,
                                onName: @escaping (String) -> Void = { _ in },
                                onCancel: @escaping () -> Void = { }) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 380, height: 220)
        let hosting = NSHostingView(rootView: AnyView(
            DepartmentMintSheet(language: language, onName: onName, onCancel: onCancel)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.1)
        return window
    }

    private func scrollersSettling(in window: NSWindow,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) async throws -> [NSScrollView] {
        var found: [NSScrollView] = []
        _ = await pumpUntil(deadline: 5) {
            found = self.collect(NSScrollView.self, in: window)
            return !found.isEmpty
        }
        pump(0.2)
        found = collect(NSScrollView.self, in: window)
        XCTAssertFalse(found.isEmpty, "the desk mounted no sections at all",
                       file: file, line: line)
        return found
    }

    // MARK: - Helpers: the accessibility tree

    /// **Drive a SwiftUI `TextField`'s binding from outside the responder
    /// chain** — setting `stringValue` and posting the notification its
    /// delegate listens for, which is what a real keystroke does once it
    /// reaches the field, without needing this test host to be the active
    /// app (CLAUDE.md's synthetic-click premise, in this surface's currency).
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

    /// **Wait for a `.sheet(item:)` to actually attach** — a real child
    /// `NSWindow` once `parent` is ordered front, which it is in every
    /// mount this suite makes. Its own `contentView` is what the
    /// `axTexts`/`axButtons` helpers above read when handed this window
    /// instead of the parent.
    private func attachedSheetWindow(of parent: NSWindow,
                                     deadline: TimeInterval = 5) async -> NSWindow? {
        var sheet: NSWindow?
        _ = await pumpUntil(deadline: deadline) {
            sheet = parent.attachedSheet
            return sheet != nil
        }
        return sheet
    }

    // MARK: - Helpers: a project on disk

    private struct Fixture {
        let projectURL: URL
        let projectStore: ProjectStore
        let documentStore: DocumentStore
    }

    /// One open, registered chapter — the state Constraint 1's gate describes, so
    /// the abandon test can ask whether the gate really closes the arm.
    private func makeProject() async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DRT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let path = "manuscript/c1.md"
        try "Doc one first.\n\nDoc one second."
            .write(to: tmp.appendingPathComponent(path), atomically: true, encoding: .utf8)

        let manifest = ProjectManifest(
            type: .novel, title: "The Project", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-1", title: "Chapter 1", type: .document, path: path),
            ],
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
    /// here to hold open. Local to this suite for `DesignSpyRunner`'s own
    /// reason: each loop's spy is `private` to its own file and the three
    /// will diverge as they grow.
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
    private func makeTranslatorFixture(seedLanguage: String) async throws -> TranslatorFixture {
        let h = try await makeProject()
        try await TranslationStore.append(
            TranslationRecord(paragraphId: "zzzz", language: seedLanguage,
                              text: "placeholder", sourceHash: TranslationHash.hash("x")),
            forDocId: "doc-1", deviceSlug: DeviceSlug.make(from: "seed-device"),
            in: h.projectURL)

        let suite = "DepartmentMintSheet-\(UUID().uuidString)"
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let bible = BibleStore(projectRoot: h.projectURL,
                               device: DeviceSlug.make(from: MacDeviceID.current))
        // The window's own wiring: `ProjectWindow` hands `onRunEnded` to a
        // `TranslationRunLog` it owns, and the desk reads the log. Recording
        // into a log here is what makes the end-to-end test able to watch a
        // round LAND rather than only start.
        let runLog = TranslationRunLog()
        var environment = TranslatorOrchestrator.Environment.production(
            store: h.projectStore, documentStore: h.documentStore,
            projectURL: h.projectURL, bible: bible, preferences: preferences,
            onRunEnded: { [weak runLog] summary in runLog?.record(summary) })
        let runner = TranslatorSpyRunner()
        environment.makeRunner = { _, _ in runner }

        let translator = TranslatorOrchestrator()
        translator.configure(environment: environment)

        return TranslatorFixture(projectURL: h.projectURL, projectStore: h.projectStore,
                                 documentStore: h.documentStore, translator: translator,
                                 runner: runner, runLog: runLog)
    }

    /// The real host over a `TranslatorFixture`'s project — Task 4's own
    /// `mountHost`, one orchestrator over.
    private func mountTranslatorHost(_ fixture: TranslatorFixture) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 340, height: 600)
        let hosting = NSHostingView(rootView: AnyView(
            DepartmentPaneHost(store: fixture.projectStore,
                               documentStore: fixture.documentStore,
                               projectURL: fixture.projectURL,
                               subject: .item("doc-1"),
                               translator: fixture.translator,
                               // The window passes its log the same way; a desk
                               // without one draws no report line at all, and a
                               // test watching for one would wait for ever.
                               runLog: fixture.runLog)
                .frame(maxWidth: .infinity, maxHeight: .infinity)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.1)
        return window
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
        let tmp = FileManager.default.temporaryDirectory
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

    /// The real host over that project, which is what makes the end-to-end test
    /// end-to-end: the pane's values, its `.task`, its pre-flight and its verbs
    /// are all the production ones.
    private func mountHost(_ fixture: DesignFixture,
                           designer: DesignerOrchestrator) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 340, height: 600)
        let hosting = NSHostingView(rootView: AnyView(
            DepartmentPaneHost(store: fixture.projectStore,
                               documentStore: fixture.documentStore,
                               projectURL: fixture.projectURL,
                               designer: designer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.1)
        return window
    }

    /// A runner that answers one valid proposal. Local to this suite for the
    /// reason `DesignerOrchestratorTests`' own copy states: the siblings are
    /// `private` to their suites, and the three loops will diverge as they grow.
    @MainActor
    private final class DesignSpyRunner: CompilerRunner {
        var isRunning = false
        var sessionEpoch = 1
        var nextEvent: CompilerRunEvent? = .resultText("""
            {"spec":"A quiet page: one column, a generous gutter.",\
            "files":[{"path":"template.tex","content":"\\\\documentclass{book}"}]}
            """)
        private var held: CheckedContinuation<CompilerRunEvent, Never>?

        func send(message: String, systemPreamble: String?) async -> CompilerRunEvent {
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

    /// A mutable cell a `@Sendable`-shaped closure can write into from the main
    /// actor. `DesignerOrchestratorTests.Box`'s twin.
    @MainActor
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
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
