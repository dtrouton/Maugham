import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The designer's run: what starts one, what refuses one, what a run that
/// did not come back is allowed to stage — and the second verb the translator
/// never needed, `requestChanges`.**
///
/// The mechanics are `TranslatorOrchestratorTests`' — the same spy runner, the
/// same closure environment, the same "hold the turn open" discipline. What
/// differs is the subject: a designer round ends at a gate the writer stands
/// at, so this suite is as much about the round that stays OPEN between two
/// turns as it is about the turn itself.
@MainActor
final class DesignerOrchestratorTests: XCTestCase {

    // MARK: - Fixtures

    /// One spec and one file — the smallest report that gives staging both of
    /// the things it writes.
    static let oneProposal = """
        {"spec":"A quiet page: one column, generous gutter.",\
        "files":[{"path":"template.tex","content":"\\\\documentclass{book}"}]}
        """

    /// A runner that records what it was asked and answers what the test says
    /// — `TranslatorOrchestratorTests.SpyRunner`, kept local for the same
    /// reason that one is: the sibling is `private` to its suite and the two
    /// loops will diverge as each grows.
    ///
    /// `nextEvent == nil` holds the turn open, which is how the in-flight
    /// refusal is arranged: the guard has to be true while a real `send` is
    /// outstanding, not merely between two synchronous calls.
    @MainActor
    private final class SpyRunner: CompilerRunner {
        private(set) var sends: [(message: String, preamble: String?)] = []
        private(set) var shutdowns = 0
        private(set) var cancels = 0
        var isRunning = false
        var sessionEpoch = 1
        var nextEvent: CompilerRunEvent? = .resultText(DesignerOrchestratorTests.oneProposal)
        var onSend: (() -> Void)?
        private var held: CheckedContinuation<CompilerRunEvent, Never>?

        func send(message: String, systemPreamble: String?) async -> CompilerRunEvent {
            sends.append((message, systemPreamble))
            onSend?()
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
            cancels += 1
            release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.cancelled)))
        }

        func shutdown() {
            shutdowns += 1
            release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.sessionShutDown)))
        }
    }

    /// One round's briefing inputs, as the window answers a click with them.
    /// The designer's name lives here and nowhere else — it is the identity
    /// the briefing shows the model AND the one staging signs the proposal
    /// with.
    private func makeInputs(
        direction: String? = nil, language: String? = nil
    ) -> DesignerBriefing.Inputs {
        DesignerBriefing.Inputs(
            designerName: "Tschichold",
            roleBrief: "Design the page, not the decoration.",
            visualLanguageText: "Warm paper, a single serif, quiet running heads.",
            language: language,
            direction: direction)
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private struct Harness {
        let orchestrator: DesignerOrchestrator
        let configURL: URL
        /// Every report staging was handed, with the context it was handed —
        /// recorded rather than counted, because the property under test is
        /// that a failed run reaches this list not at all.
        var staged: [(report: DesignerReport, context: DesignerOrchestrator.StageContext)] {
            stagings()
        }
        let stagings: () -> [(report: DesignerReport,
                              context: DesignerOrchestrator.StageContext)]
        var summaries: [DesignerOrchestrator.RunSummary] { ended() }
        let ended: () -> [DesignerOrchestrator.RunSummary]
        /// What `briefRound` was asked, in order — so a follow-up round can be
        /// shown NOT to re-gather the doctrine it is already inside.
        var briefings: [(direction: String?, language: String?)] { gathered() }
        let gathered: () -> [(direction: String?, language: String?)]
        /// How many times a NEW session was asked for: the only thing on this
        /// side of the seam that can tell "the warm process answered again"
        /// from "it was retired and one was spawned in its place", since
        /// `makeRunner` hands back the same spy either way.
        var spawns: Int { runnerSpawns() }
        let runnerSpawns: () -> Int
        let setInputs: (DesignerBriefing.Inputs?) -> Void
    }

    /// A closure the test can hold open, so the window between the click and
    /// the send — a real window in production, the length of an AST build — is
    /// something to assert about rather than race.
    @MainActor
    private final class Gate {
        private(set) var entries = 0
        private var held: CheckedContinuation<Void, Never>?

        func hold() async {
            entries += 1
            await withCheckedContinuation { held = $0 }
        }

        func release() {
            let continuation = held
            held = nil
            continuation?.resume()
        }
    }

    private func makeHarness(
        runner: SpyRunner,
        inputs: DesignerBriefing.Inputs?,
        stageOutcome: DesignerOrchestrator.StageOutcome = .init(proposalId: "prop-1",
                                                                filesStaged: 1),
        /// Holds the briefing gather open — the run's one suspension before
        /// the send.
        holdBriefing: Gate? = nil,
        /// Holds STAGING open: the one suspension this class resumes from with
        /// writes still to do.
        holdStage: Gate? = nil
    ) throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesignerOrchestrator-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("designer-mcp.json")

        let live = Box(inputs)
        let stagings = Box<[(report: DesignerReport,
                             context: DesignerOrchestrator.StageContext)]>([])
        let summaries = Box<[DesignerOrchestrator.RunSummary]>([])
        let gathered = Box<[(direction: String?, language: String?)]>([])
        let spawns = Box(0)

        let orchestrator = DesignerOrchestrator()
        orchestrator.configure(environment: DesignerOrchestrator.Environment(
            projectId: "p-1",
            model: "test-model",
            briefRound: { direction, language in
                gathered.value.append((direction, language))
                if let holdBriefing { await holdBriefing.hold() }
                return live.value
            },
            writeMCPConfig: {
                try Data("{}".utf8).write(to: configURL, options: .atomic)
                return configURL
            },
            makeRunner: { _, _ in
                spawns.value += 1
                return runner
            },
            stage: { report, context in
                stagings.value.append((report, context))
                if let holdStage { await holdStage.hold() }
                return stageOutcome
            },
            onRunEnded: { summaries.value.append($0) }))

        return Harness(orchestrator: orchestrator, configURL: configURL,
                       stagings: { stagings.value },
                       ended: { summaries.value },
                       gathered: { gathered.value },
                       runnerSpawns: { spawns.value },
                       setInputs: { live.value = $0 })
    }

    /// Wait until the spy has been sent `count` messages, so an assertion
    /// about arity is made after the async `send` has actually happened rather
    /// than racing it.
    private func awaitSends(_ count: Int, on runner: SpyRunner) {
        let reached = expectation(description: "\(count) send(s) reached the runner")
        if runner.sends.count >= count {
            reached.fulfill()
        } else {
            runner.onSend = { if runner.sends.count >= count { reached.fulfill() } }
        }
        wait(for: [reached], timeout: 2)
        runner.onSend = nil
    }

    /// Give the main actor a few passes, so an assertion that something did
    /// NOT happen has turns in which it could have.
    private func settle(turns: Int = 3) {
        for turn in 0..<turns {
            let settled = expectation(description: "the run loop ran (\(turn))")
            Task { @MainActor in settled.fulfill() }
            wait(for: [settled], timeout: 2)
        }
    }

    private func source(at relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - The run

    /// The whole path, once: briefing, send, parse, staging — and a summary
    /// for the desk at the end of it.
    func test_aRunBriefsTheSessionAndStagesWhatComesBack() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner,
                                      inputs: makeInputs(direction: "warmer paper"))

        harness.orchestrator.runDesign(direction: "warmer paper", language: nil)
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(harness.briefings.map(\.direction), ["warmer paper"],
                       "the writer's words for this round reach the gather, which is "
                       + "what puts them in front of the model")
        XCTAssertTrue(runner.sends[0].message.contains("Tschichold"))
        XCTAssertTrue(runner.sends[0].message.contains("warmer paper"))
        XCTAssertEqual(runner.sends[0].preamble,
                       DesignerOrchestrator.sessionSystemPreamble(projectId: "p-1"),
                       "every send carries the session preamble, because a respawn "
                       + "re-applies it (CompilerRunner.send's contract)")

        let staged = try XCTUnwrap(harness.staged.first, "the report never reached staging")
        XCTAssertEqual(staged.report.specMarkdown,
                       "A quiet page: one column, generous gutter.")
        XCTAssertEqual(staged.report.files.map(\.path), ["template.tex"])
        XCTAssertEqual(staged.context.round, 1, "a fresh design round is round 1")
        XCTAssertNil(staged.context.language, "no language asked for is the base edition")
        XCTAssertEqual(staged.context.designerName, "Tschichold",
                       "staging signs the proposal with the name the briefing put in "
                       + "front of the model — a second resolution downstream is how a "
                       + "byline and a briefing come to name different people")
        XCTAssertEqual(harness.orchestrator.runState, .idle)

        let summary = try XCTUnwrap(harness.summaries.first)
        XCTAssertEqual(summary.round, 1)
        XCTAssertEqual(summary.runId, staged.context.runId,
                       "the desk's row and the staging name the same run")
        XCTAssertEqual(summary.outcome,
                       .staged(DesignerOrchestrator.StageOutcome(proposalId: "prop-1",
                                                                 filesStaged: 1)))
    }

    /// A round the window cannot brief at all — no project, no publish posture
    /// — is not an error and not a run. Nothing spawns, nothing is reported:
    /// the click had nothing to act on.
    func test_aRoundWithNoBriefingIsNotARun() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: nil)

        harness.orchestrator.runDesign()
        settle()

        XCTAssertEqual(runner.sends.count, 0)
        XCTAssertEqual(harness.spawns, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configURL.path),
                       "…and no session config, because no session was wanted")
        XCTAssertEqual(harness.orchestrator.runState, .idle)
        XCTAssertTrue(harness.summaries.isEmpty,
                      "a click that started nothing ends nothing")
    }

    /// The language a round is for rides every state and every record: a desk
    /// that could not tell a Spanish round from the base edition's would show
    /// one round's failure against the other's row.
    func test_theEditionARoundIsForRidesTheStateAndTheRecord() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil   // hold the turn open, so `running` is observable
        let harness = try makeHarness(runner: runner, inputs: makeInputs(language: "es"))

        harness.orchestrator.runDesign(language: "es")
        awaitSends(1, on: runner)

        XCTAssertEqual(harness.briefings.map(\.language), ["es"])
        XCTAssertEqual(harness.orchestrator.runState, .running(round: 1, language: "es"))

        runner.release(.resultText(Self.oneProposal))
        settle()

        XCTAssertEqual(harness.staged.first?.context.language, "es")
        XCTAssertEqual(harness.summaries.first?.language, "es")
    }

    // MARK: - Refusal

    /// A second run while one is in flight is refused, not queued: there is
    /// one session per orchestrator, and a second round is something the next
    /// click can do.
    func test_aSecondRunWhileRunningIsRefusedNotQueued() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil   // hold the turn open
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        XCTAssertEqual(harness.orchestrator.runState, .running(round: 1, language: nil))

        harness.orchestrator.runDesign()
        settle()

        XCTAssertEqual(runner.sends.count, 1, "the second click must not reach the runner")
        XCTAssertEqual(harness.orchestrator.runState, .running(round: 1, language: nil))
        XCTAssertTrue(harness.summaries.isEmpty)

        runner.release(.resultText(Self.oneProposal))
        settle()
    }

    /// The same refusal in the window BEFORE the send, while the round is
    /// still gathering its briefing. That window is an AST build and a
    /// directory read long in production, and a run started inside it would
    /// build a second briefing over the same book.
    func test_aSecondRunDuringTheBriefingGatherIsRefused() throws {
        let runner = SpyRunner()
        let gate = Gate()
        let harness = try makeHarness(runner: runner, inputs: makeInputs(),
                                      holdBriefing: gate)

        harness.orchestrator.runDesign()
        settle()
        XCTAssertEqual(gate.entries, 1)

        harness.orchestrator.runDesign()
        settle()
        XCTAssertEqual(gate.entries, 1, "the second click must not start a second gather")

        gate.release()
        awaitSends(1, on: runner)
        settle()
        XCTAssertEqual(runner.sends.count, 1)
    }

    // MARK: - Failure stages nothing

    /// **The property the whole loop is built around** (spec §6): a run that
    /// did not come back has staged nothing. Staging is not called with an
    /// empty report, or a partial one — it is not called at all, because it is
    /// reachable from exactly one place in the file and that place holds a
    /// parsed report.
    func test_aFailedRunStagesNothing() throws {
        for failure in [CompilerRunFailure.timedOut, .cliNotFound,
                        .sessionDied(detail: "the CLI exited with status 1")] {
            let runner = SpyRunner()
            runner.nextEvent = .failed(failure)
            let harness = try makeHarness(runner: runner, inputs: makeInputs())

            harness.orchestrator.runDesign()
            awaitSends(1, on: runner)
            settle()

            XCTAssertTrue(harness.staged.isEmpty,
                          "\(failure) reached staging — a dead session must have "
                          + "written nothing")
            guard case .failed(let reported, _) = harness.orchestrator.runState else {
                return XCTFail("expected a reported failure for \(failure), got "
                               + "\(harness.orchestrator.runState)")
            }
            XCTAssertEqual(reported, .run(failure))
            XCTAssertEqual(harness.summaries.map(\.outcome), [.failed(.run(failure))])
        }
    }

    /// Output that cannot be read at all is a failure in the same vocabulary,
    /// and stages nothing either. All-or-nothing starts at parse
    /// (`DesignerReport.parse`): a turn that got one path wrong is a model that
    /// has lost the contract, and there is no knowing which of its other files
    /// to trust.
    func test_unusableOutputIsSurfacedAndStagesNothing() throws {
        for text in ["I had a look and honestly the templates are fine.",
                     // A traversal in a path — parse refuses the whole report.
                     #"{"spec":"x","files":[{"path":"../config.json","content":""}]}"#] {
            let runner = SpyRunner()
            runner.nextEvent = .resultText(text)
            let harness = try makeHarness(runner: runner, inputs: makeInputs())

            harness.orchestrator.runDesign()
            awaitSends(1, on: runner)
            settle()

            XCTAssertTrue(harness.staged.isEmpty)
            guard case .failed(let reported, _) = harness.orchestrator.runState else {
                return XCTFail("expected a reported failure, got "
                               + "\(harness.orchestrator.runState)")
            }
            XCTAssertEqual(reported, .run(.unusableOutput))
        }
    }

    /// A words-only round is NOT unusable: a proposal that is a question, or a
    /// plan with nothing to show yet, parses and stages. The converse of the
    /// test above, so a parser tightened too far cannot pass both.
    func test_aWordsOnlyRoundIsAValidAnswer() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(#"{"spec":"What weight is the paper?","files":[]}"#)
        let harness = try makeHarness(runner: runner, inputs: makeInputs(),
                                      stageOutcome: .init(proposalId: "prop-1"))

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(harness.staged.count, 1,
                       "a round with only words to offer is still a round, and "
                       + "staging is what decides there are no files to write")
        XCTAssertEqual(harness.staged.first?.report.files.count, 0)
        XCTAssertEqual(harness.orchestrator.runState, .idle)
    }

    /// The writer's own actions are not errors — Cancel, project close, the
    /// window going away all come back as `.sessionDied`, and a red row
    /// reading "session died" after the writer pressed Cancel is the surface
    /// apologising for doing what it was told.
    func test_theWritersOwnActionsAreNotSurfacedAsFailures() throws {
        for detail in [CompilerRunFailure.Detail.cancelled,
                       CompilerRunFailure.Detail.sessionShutDown,
                       CompilerRunFailure.Detail.runInFlight] {
            let runner = SpyRunner()
            runner.nextEvent = .failed(.sessionDied(detail: detail))
            let harness = try makeHarness(runner: runner, inputs: makeInputs())

            harness.orchestrator.runDesign()
            awaitSends(1, on: runner)
            settle()

            XCTAssertEqual(harness.orchestrator.runState, .idle,
                           "\"\(detail)\" is the writer's own doing, not a failure")
            XCTAssertEqual(harness.summaries.map(\.outcome), [.cancelled])
            XCTAssertTrue(harness.staged.isEmpty)
        }
    }

    /// **A proposal the store refuses is loud**: a disk that will not take the
    /// staged files is something the writer has to know about, not a round
    /// that ends clean over a proposal that does not exist.
    func test_aStagingRejectionIsReportedRatherThanSwallowed() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, inputs: makeInputs(),
            stageOutcome: .init(rejection: "the proposal directory could not be written"))

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()

        guard case .failed(let reported, _) = harness.orchestrator.runState else {
            return XCTFail("expected a reported failure, got "
                           + "\(harness.orchestrator.runState)")
        }
        XCTAssertEqual(reported,
                       .stagingRejected("the proposal directory could not be written"))
        XCTAssertEqual(harness.summaries.count, 1,
                       "…and the desk still gets its row, carrying what staging reported")
        XCTAssertFalse(harness.orchestrator.hasOpenProposalRound,
                       "a proposal that was never staged is not a round the writer can "
                       + "ask for changes to")
    }

    /// A sample compile that failed rides the proposal and ends the run clean
    /// (spec §6): the gate view shows the tectonic error beside the spec, and
    /// a proposal the writer can still read and reject is not a failed run.
    func test_aFailedSampleCompileRidesTheRecordWithoutFailingTheRun() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, inputs: makeInputs(),
            stageOutcome: .init(proposalId: "prop-1", filesStaged: 1,
                                sample: .failed(error: "! Undefined control sequence.")))

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(harness.orchestrator.runState, .idle)
        guard case .staged(let outcome) = try XCTUnwrap(harness.summaries.first).outcome
        else { return XCTFail("expected a staged outcome") }
        XCTAssertEqual(outcome.sample, .failed(error: "! Undefined control sequence."))
        XCTAssertTrue(harness.orchestrator.hasOpenProposalRound,
                      "the writer can still ask for changes to a proposal whose "
                      + "samples would not compile — that is what they would ask for")
    }

    // MARK: - The warm session

    /// **Warm per PROJECT, and this is the divergence from the translator.** A
    /// second round — even one for another edition — reuses the process,
    /// because there is one book being designed and a follow-up round has to
    /// reach the process that made the proposal it is following up on.
    func test_theSessionStaysWarmAcrossRoundsAndEditions() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()
        harness.setInputs(makeInputs(language: "es"))
        harness.orchestrator.runDesign(language: "es")
        awaitSends(2, on: runner)
        settle()

        XCTAssertEqual(harness.spawns, 1,
                       "a round for another edition is still this book's design")
        XCTAssertEqual(runner.shutdowns, 0)
    }

    /// …and a model change does retire it, because `--model` is a spawn
    /// argument: the warm process would go on answering in the model the
    /// writer just changed away from.
    func test_aModelChangeRetiresTheSession() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()
        harness.orchestrator.updateModel("another-model")
        harness.orchestrator.runDesign()
        awaitSends(2, on: runner)
        settle()

        XCTAssertEqual(harness.spawns, 2)
        XCTAssertEqual(runner.shutdowns, 1,
                       "the session it replaced must be reaped, not released")
    }

    // MARK: - Request changes

    /// **The gate's iterate arm.** The writer's words go back into the SAME
    /// warm session as a follow-up, and what comes back is the next round of
    /// the same proposal line — no second gather, because the doctrine is
    /// already in the session's context and re-briefing it would be telling
    /// the model what it is looking at.
    func test_requestChangesContinuesTheSameSessionAsANewRound() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign(language: "es")
        awaitSends(1, on: runner)
        settle()

        XCTAssertTrue(harness.orchestrator.requestChanges("the running heads are too loud"))
        awaitSends(2, on: runner)
        settle()

        XCTAssertEqual(harness.spawns, 1, "a follow-up must reach the process that made "
                       + "the proposal it is following up on")
        XCTAssertTrue(runner.sends[1].message.contains("the running heads are too loud"))
        XCTAssertTrue(runner.sends[1].message.contains(DesignerReport.schemaDescription),
                      "the report contract is restated by reference, so round two "
                      + "cannot drift off the wire shape")
        XCTAssertEqual(harness.staged.map(\.context.round), [1, 2],
                       "the follow-up is the next round of the same line")
        XCTAssertEqual(harness.staged.map(\.context.language), ["es", "es"],
                       "…for the edition the line was opened for, which the writer "
                       + "never restates when they ask for a change")
        XCTAssertEqual(harness.staged.map(\.context.designerName),
                       ["Tschichold", "Tschichold"])
        XCTAssertEqual(harness.summaries.map(\.round), [1, 2])
    }

    /// Nothing to change: no round has been run, so there is no proposal for
    /// the writer's words to be about. Refused rather than turned into a
    /// briefing-less run, and the refusal is VISIBLE to the caller — P4's gate
    /// has to be able to say why a click did nothing.
    func test_requestChangesIsRefusedWhenNoProposalRoundIsOpen() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        XCTAssertFalse(harness.orchestrator.hasOpenProposalRound)
        XCTAssertFalse(harness.orchestrator.requestChanges("more air"))
        settle()

        XCTAssertEqual(runner.sends.count, 0)
        XCTAssertEqual(harness.spawns, 0)
        XCTAssertTrue(harness.summaries.isEmpty)
    }

    /// A run that failed opened no round either — there is no proposal on the
    /// desk to ask changes to, and the honest verb for the writer is Run
    /// again.
    func test_aFailedRunOpensNoRoundToChange() throws {
        let runner = SpyRunner()
        runner.nextEvent = .failed(.timedOut)
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()

        XCTAssertFalse(harness.orchestrator.hasOpenProposalRound)
        XCTAssertFalse(harness.orchestrator.requestChanges("more air"))
        settle()
        XCTAssertEqual(runner.sends.count, 1)
    }

    /// One turn at a time here too: a change requested while a round is in
    /// flight is refused, not queued behind it.
    func test_requestChangesIsRefusedWhileARunIsInFlight() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()

        runner.nextEvent = nil   // the follow-up holds the turn open
        XCTAssertTrue(harness.orchestrator.requestChanges("more air"))
        awaitSends(2, on: runner)

        XCTAssertFalse(harness.orchestrator.requestChanges("and warmer"),
                       "a second change request must be refused while the first is out")
        settle()
        XCTAssertEqual(runner.sends.count, 2)

        runner.release(.resultText(Self.oneProposal))
        settle()
    }

    /// **A follow-up only means anything to the process that heard the
    /// proposal.** `ClaudeCLISession` respawns silently after a timeout, a
    /// cancel or an idle expiry, and a fresh process asked to revise "your
    /// proposal" has never made one — it would invent a revision of nothing.
    /// The epoch is what tells the two apart (`CompilerRunner.sessionEpoch`),
    /// and a round whose session is gone is not open.
    func test_requestChangesIsRefusedAfterTheSessionRespawned() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()
        XCTAssertTrue(harness.orchestrator.hasOpenProposalRound)

        runner.sessionEpoch += 1   // the process behind the seam was replaced

        XCTAssertFalse(harness.orchestrator.hasOpenProposalRound)
        XCTAssertFalse(harness.orchestrator.requestChanges("more air"))
        settle()
        XCTAssertEqual(runner.sends.count, 1)
    }

    /// **A fresh round closes the open one at the send, whatever becomes of
    /// it.** The sharp sequence: round one stages a proposal, round two comes
    /// back unparseable — which retires no session and moves no epoch, so a
    /// round closed only by the paths that produce a proposal would still read
    /// as open. Request changes would then send "the writer has reviewed your
    /// proposal" into a session whose last turn was the garbled second attempt,
    /// and get back a revision of whichever design it decided that meant.
    func test_aFreshRoundClosesTheOpenOneEvenWhenItComesBackUnusable() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()
        XCTAssertTrue(harness.orchestrator.hasOpenProposalRound)

        runner.nextEvent = .resultText("I'd rather talk about the cover, honestly.")
        harness.orchestrator.runDesign()
        awaitSends(2, on: runner)
        settle()

        XCTAssertEqual(runner.shutdowns, 0, "the premise: nothing retired the session")
        XCTAssertEqual(harness.spawns, 1, "…and nothing respawned it, so the epoch is "
                       + "the same one the first proposal was made under")
        XCTAssertFalse(harness.orchestrator.hasOpenProposalRound,
                       "the first round's proposal is not something this session can "
                       + "still be asked to revise")
        XCTAssertFalse(harness.orchestrator.requestChanges("more air"))
        settle()
        XCTAssertEqual(runner.sends.count, 2, "the follow-up must not reach the runner")
    }

    /// Empty words are not a change request. Refused before anything is spent,
    /// and the round stays open for the writer to say what they meant.
    func test_anEmptyChangeRequestIsRefusedAndLeavesTheRoundOpen() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()

        XCTAssertFalse(harness.orchestrator.requestChanges("   \n  "))
        settle()

        XCTAssertEqual(runner.sends.count, 1)
        XCTAssertTrue(harness.orchestrator.hasOpenProposalRound)
    }

    /// The session ending takes the round with it: after a shutdown there is
    /// no process holding the proposal in context, so the follow-up verb is
    /// refused rather than sent to a process spawned fresh by the next click.
    func test_shutdownClosesTheOpenRound() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()
        XCTAssertTrue(harness.orchestrator.hasOpenProposalRound)

        harness.orchestrator.shutdown()

        XCTAssertFalse(harness.orchestrator.hasOpenProposalRound)
        XCTAssertFalse(harness.orchestrator.requestChanges("more air"))
        settle()
        XCTAssertEqual(runner.sends.count, 1)
    }

    // MARK: - Cancel and shutdown

    /// Cancel ends the turn and returns the surface to idle without a failure
    /// — and without a staging, because a cancelled round proposed half a
    /// design.
    func test_cancelEndsTheRunQuietly() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        harness.orchestrator.cancel()
        settle()

        XCTAssertEqual(runner.cancels, 1)
        XCTAssertEqual(harness.orchestrator.runState, .idle)
        XCTAssertTrue(harness.staged.isEmpty)
        XCTAssertEqual(harness.summaries.map(\.outcome), [.cancelled])
    }

    /// Cancel BEFORE the send — while the briefing is still being gathered —
    /// has no turn to end, so the round is abandoned by generation the way
    /// `shutdown()` abandons it. Without this the click would mean "carry on",
    /// and the round it did not stop would go on to spend a whole turn.
    func test_cancelBeforeTheSendAbandonsTheRun() throws {
        let runner = SpyRunner()
        let gate = Gate()
        let harness = try makeHarness(runner: runner, inputs: makeInputs(),
                                      holdBriefing: gate)

        harness.orchestrator.runDesign()
        settle()
        harness.orchestrator.cancel()
        gate.release()
        settle()

        XCTAssertEqual(runner.sends.count, 0, "the abandoned run must never send")
        XCTAssertEqual(harness.orchestrator.runState, .idle)
        XCTAssertEqual(harness.summaries.map(\.outcome), [.cancelled],
                       "the desk's row still ends — a spinner nothing closes is worse "
                       + "than a cancelled row")
    }

    /// **Shutdown reaps.** `deinit` cannot, so every path that ends a window
    /// owns this call — and the session's config file goes with it, or the
    /// socket path leaks into the temp directory for the life of the machine.
    func test_shutdownEndsTheSessionAndDeletesItsConfig() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.configURL.path))

        harness.orchestrator.shutdown()
        settle()

        XCTAssertEqual(runner.shutdowns, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configURL.path))
        XCTAssertEqual(harness.orchestrator.runState, .idle)
    }

    /// A shutdown mid-turn takes the round with it, and the late event that
    /// arrives afterwards must not stage anything — no proposal written into a
    /// window that is going away, no failure row on a desk that has gone.
    func test_shutdownMidTurnAbandonsTheRunAndTheLateAnswer() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        harness.orchestrator.shutdown()
        settle()
        // The dying process's last word, arriving after the teardown.
        runner.release(.resultText(Self.oneProposal))
        settle()

        XCTAssertTrue(harness.staged.isEmpty,
                      "a turn the writer shut down must not stage on its way out")
        XCTAssertEqual(harness.orchestrator.runState, .idle)
    }

    /// A staging still in flight when the window goes away must not paint a
    /// finished round onto a desk that is leaving — the last suspension, and
    /// the only one this class resumes from with writes still to do.
    func test_aShutdownDuringStagingLeavesTheSurfaceAlone() throws {
        let runner = SpyRunner()
        let gate = Gate()
        let harness = try makeHarness(runner: runner, inputs: makeInputs(),
                                      holdStage: gate)

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()
        XCTAssertEqual(gate.entries, 1)

        harness.orchestrator.shutdown()
        gate.release()
        settle()

        XCTAssertEqual(harness.orchestrator.runState, .idle)
        XCTAssertTrue(harness.summaries.isEmpty,
                      "the run the window abandoned reports nothing back to it")
        XCTAssertFalse(harness.orchestrator.hasOpenProposalRound)
    }

    /// A writer who closes the window and opens another must still have a
    /// working run: `shutdown()` ends the session and leaves the orchestrator
    /// usable, `detach()` additionally drops the window's object graph — the
    /// compiler's own distinction, and not interchangeable.
    func test_detachDropsTheEnvironmentAndShutdownDoesNot() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runDesign()
        awaitSends(1, on: runner)
        settle()

        harness.orchestrator.shutdown()
        harness.orchestrator.runDesign()
        awaitSends(2, on: runner)
        settle()
        XCTAssertEqual(runner.sends.count, 2, "shutdown leaves the orchestrator usable")

        harness.orchestrator.detach()
        harness.orchestrator.runDesign()
        settle()
        XCTAssertEqual(runner.sends.count, 2, "detach drops the environment with it")
    }

    // MARK: - The contracts, on the record

    /// The contract this type cannot enforce: `deinit` is nonisolated, cannot
    /// touch main-actor state, and deallocating a `Process` neither signals
    /// nor reaps its child — so an orchestrator merely released leaves a live,
    /// billing `claude` behind. `ClaudeCLISession` says this on itself; the
    /// THIRD owner of a session has to say it too, or the next reader meets
    /// the rule only in the file they are not editing.
    func test_theShutdownContractIsRestatedOnThisType() throws {
        let file = try source(at: "Maugham/Compiler/DesignerOrchestrator.swift")
        for phrase in ["shutdown()", "deinit", "billing"] {
            XCTAssertTrue(file.contains(phrase),
                          "the shutdown contract paragraph is missing \"\(phrase)\"")
        }
        XCTAssertFalse(file.contains("nonisolated deinit {"),
                       "a deinit here would be a reaper that cannot reach the process "
                       + "it claims to reap")
    }

    /// **The divergence has to be written where it is diverged from.** This
    /// session is warm per PROJECT while its sibling is warm per
    /// `(docId, language)`, and a reader who meets `ensureRunner` here after
    /// reading the translator's will assume the pair was forgotten unless the
    /// file says why it isn't there.
    func test_theWarmPerProjectDivergenceIsExplainedOnThisType() throws {
        let file = try source(at: "Maugham/Compiler/DesignerOrchestrator.swift")
        XCTAssertTrue(file.contains("TranslatorOrchestrator"),
                      "the divergence names the sibling it diverges from")
        for phrase in ["per project", "requestChanges"] {
            XCTAssertTrue(file.contains(phrase),
                          "the warm-session paragraph is missing \"\(phrase)\"")
        }
    }

    /// **No timer ever starts a design round** (ADR 0028's tempo discipline,
    /// carried into this milestone by the spec's own constitution check). The
    /// keystroke is the only trigger; every clock in this area ends a session,
    /// and none of them lives here.
    func test_noClockStartsARoundInThisFile() throws {
        let file = try source(at: "Maugham/Compiler/DesignerOrchestrator.swift")
        for clock in ["Timer(", "Timer.scheduled", "asyncAfter", "Task.sleep",
                      "DispatchSource"] {
            XCTAssertFalse(file.contains(clock),
                           "\"\(clock)\" in this file would be a run nobody asked for")
        }
    }
}
