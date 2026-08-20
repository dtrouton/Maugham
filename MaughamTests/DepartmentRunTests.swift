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

    // MARK: - Helpers: the decisions

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
                       runTranslation: @escaping (String) -> Void = { _ in },
                       cancelRun: @escaping () -> Void = { }) -> NSWindow {
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
                           designProposalCount: 0,
                           notice: notice,
                           runTarget: target,
                           runs: runs,
                           runTranslation: runTranslation,
                           cancelRun: cancelRun)
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

    /// Every button carrying `label`, in tree order — which for a `VStack` of rows
    /// is the order a writer reads them down the column.
    ///
    /// **Pressed through the tree rather than clicked**, which is the difference
    /// between this and Task 2's door test: a synthetic `mouseDown` needs the test
    /// host to be the active app, and an overnight gate on a locked screen would go
    /// red for a reason that has nothing to do with the desk (CLAUDE.md).
    /// `accessibilityPerformPress` is the action the click ultimately performs and
    /// is `ReviewRoundCockpitTests`' technique for the same reason.
    private func axButtons(labelled label: String, in window: NSWindow) throws
    -> [AnyObject] {
        try requireAssistiveClient()
        let root = try XCTUnwrap(window.contentView)
        return axElements(under: root)
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .filter { (axAttribute($0, "accessibilityLabel") as? String) == label }
    }

    private func press(_ element: AnyObject) {
        _ = (element as? NSObject)?.perform(
            NSSelectorFromString("accessibilityPerformPress"))
    }

    private func axEnabled(_ element: AnyObject) -> Bool? {
        axAttribute(element, "isAccessibilityEnabled") as? Bool
    }

    private func axTexts(in window: NSWindow) throws -> [String] {
        try requireAssistiveClient()
        let root = try XCTUnwrap(window.contentView)
        return axElements(under: root).flatMap { element -> [String] in
            [axAttribute(element, "accessibilityValue") as? String,
             axAttribute(element, "accessibilityLabel") as? String]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        }
    }

    /// A tree that was never built is not evidence about this view, so the suite
    /// skips BY NAME where no assistive client can attach.
    private func requireAssistiveClient() throws {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process "
                + "(AXUIElementCopyAttributeValue -> \(error.rawValue)), so "
                + "SwiftUI never builds the tree this test reads")
        }
    }

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    private func collect<T: NSView>(_ type: T.Type, in window: NSWindow) -> [T] {
        guard let root = window.contentView else { return [] }
        var found: [T] = []
        collect(type, in: root, into: &found)
        return found
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    private func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func pumpUntil(deadline: TimeInterval,
                           _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            pump(0.05)
        }
        return condition()
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
