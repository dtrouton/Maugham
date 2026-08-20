import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The translator's run: what starts one, what refuses one, and what a run
/// is allowed to write when it does not come back.**
///
/// The mechanics are `CompilerRunCommandTests`' — the same spy runner, the
/// same closure environment, the same "hold the turn open" discipline — and
/// the subject is what differs: a translator run's whole safety property is
/// that a session which died has written nothing (spec §6), so most of this
/// file is about the paths that must reach ingest with nothing in their hands.
@MainActor
final class TranslatorOrchestratorTests: XCTestCase {

    // MARK: - Fixtures

    private let docId = "doc-1"
    private let language = "es"

    /// A runner that records what it was asked and answers what the test says
    /// — `CompilerRunCommandTests.SpyRunner`, kept local because that one is
    /// `private` to its suite and the two will diverge as each loop grows.
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
        var nextEvent: CompilerRunEvent? = .resultText(TranslatorOrchestratorTests.oneEntry)
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

    /// One translated paragraph and one question — the smallest turn that
    /// gives ingest both of the things it routes.
    static let oneEntry = """
        {"entries":[{"paragraph_id":"a1b2","text":"Lleg\u{00f3} la niebla."}],\
        "queries":[{"paragraph_id":"a1b2","text":"\u{00bf}La doctora es mujer?"}]}
        """

    private func makeInputs(work: Int = 1) -> TranslatorBriefing.Inputs {
        let ids = ["a1b2", "c3d4", "e5f6"]
        return TranslatorBriefing.Inputs(
            translatorName: "Elena Ruiz",
            language: language,
            workList: (0..<work).map {
                .init(paragraphId: ids[$0 % ids.count],
                      sourceText: "The fog came.", status: .missing)
            })
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private struct Harness {
        let orchestrator: TranslatorOrchestrator
        let configURL: URL
        /// Every report ingest was handed, with the context it was handed —
        /// recorded rather than counted, because the property under test is
        /// that a failed run reaches this list not at all.
        var ingests: [(report: TranslatorReport, context: TranslatorOrchestrator.IngestContext)] {
            ingested()
        }
        let ingested: () -> [(report: TranslatorReport,
                              context: TranslatorOrchestrator.IngestContext)]
        var summaries: [TranslatorOrchestrator.RunSummary] { ended() }
        let ended: () -> [TranslatorOrchestrator.RunSummary]
        /// Which environment closures were asked, in order — the identity
        /// mint has to precede the briefing that reads what it minted.
        var order: [String] { asked() }
        let asked: () -> [String]
        /// How many times a NEW session was asked for: the only thing on this
        /// side of the seam that can tell "the warm process answered again"
        /// from "it was retired and one was spawned in its place", since
        /// `makeRunner` hands back the same spy either way.
        var spawns: Int { runnerSpawns() }
        let runnerSpawns: () -> Int
        let setInputs: (TranslatorBriefing.Inputs?) -> Void
    }

    /// A closure the test can hold open, so the window between the click and
    /// the send — a real window in production, the length of a manifest write
    /// — is something to assert about rather than race.
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

    private enum HarnessError: Error { case identityRefused }

    private func makeHarness(
        runner: SpyRunner,
        inputs: TranslatorBriefing.Inputs?,
        identity: (name: String, roleId: String)? = ("Elena Ruiz", "role-es"),
        ingestOutcome: TranslatorOrchestrator.IngestOutcome = .init(entriesWritten: 1,
                                                                    queriesMinted: 1),
        /// Holds the briefing gather open — the run's first suspension.
        holdBriefing: Gate? = nil,
        /// Holds the INGEST open: the one suspension this class resumes from
        /// with writes still to do.
        holdIngest: Gate? = nil
    ) throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranslatorOrchestrator-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("translator-mcp.json")

        let live = Box(inputs)
        let ingests = Box<[(report: TranslatorReport,
                            context: TranslatorOrchestrator.IngestContext)]>([])
        let summaries = Box<[TranslatorOrchestrator.RunSummary]>([])
        let order = Box<[String]>([])
        let spawns = Box(0)

        let orchestrator = TranslatorOrchestrator()
        orchestrator.configure(environment: TranslatorOrchestrator.Environment(
            projectId: "p-1",
            model: "test-model",
            briefingInputs: { _, _ in
                order.value.append("briefingInputs")
                if let holdBriefing { await holdBriefing.hold() }
                return live.value
            },
            translatorIdentity: { _ in
                order.value.append("translatorIdentity")
                guard let identity else { throw HarnessError.identityRefused }
                return identity
            },
            writeMCPConfig: {
                try Data("{}".utf8).write(to: configURL, options: .atomic)
                return configURL
            },
            makeRunner: { _, _ in
                spawns.value += 1
                return runner
            },
            ingest: { report, context in
                ingests.value.append((report, context))
                if let holdIngest { await holdIngest.hold() }
                return ingestOutcome
            },
            onRunEnded: { summaries.value.append($0) }))

        return Harness(orchestrator: orchestrator, configURL: configURL,
                       ingested: { ingests.value },
                       ended: { summaries.value },
                       asked: { order.value },
                       runnerSpawns: { spawns.value },
                       setInputs: { live.value = $0 })
    }

    /// Wait until the spy has been sent `count` messages, so an assertion
    /// about arity is made after the async `send` has actually happened
    /// rather than racing it.
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
    /// NOT happen has turns in which it could have. Three rather than the
    /// compiler suite's two: a translator run suspends twice before its send
    /// (the identity mint, then the briefing gather).
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

    /// The whole path, once: identity, briefing, send, parse, ingest — and a
    /// summary for the desk at the end of it.
    func test_aRunBriefsTheSessionAndIngestsWhatComesBack() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(1, on: runner)
        settle()

        XCTAssertTrue(runner.sends[0].message.contains("The fog came."),
                      "the briefing carries this round's work, not an empty message")
        XCTAssertTrue(runner.sends[0].message.contains("Elena Ruiz"))
        XCTAssertEqual(runner.sends[0].preamble,
                       TranslatorOrchestrator.sessionSystemPreamble(projectId: "p-1"),
                       "every send carries the session preamble, because a respawn "
                       + "re-applies it (CompilerRunner.send's contract)")

        let ingest = try XCTUnwrap(harness.ingests.first, "the report never reached ingest")
        XCTAssertEqual(ingest.report.entries.map(\.paragraphId), ["a1b2"])
        XCTAssertEqual(ingest.report.queries.map(\.text), ["\u{00bf}La doctora es mujer?"])
        XCTAssertEqual(ingest.context.docId, docId)
        XCTAssertEqual(ingest.context.language, language)
        XCTAssertEqual(ingest.context.translatorName, "Elena Ruiz",
                       "ingest signs the queries with the name the run resolved — "
                       + "a second resolution downstream is how a byline and a "
                       + "briefing come to name different people")
        XCTAssertEqual(ingest.context.translatorRoleId, "role-es")
        XCTAssertEqual(harness.orchestrator.runState, .idle)

        let summary = try XCTUnwrap(harness.summaries.first)
        XCTAssertEqual(summary.docId, docId)
        XCTAssertEqual(summary.language, language)
        XCTAssertEqual(summary.runId, ingest.context.runId,
                       "the desk's row and the ingest name the same run")
        XCTAssertEqual(summary.outcome,
                       .ingested(TranslatorOrchestrator.IngestOutcome(entriesWritten: 1,
                                                                      queriesMinted: 1)))
    }

    /// **The identity is resolved before the briefing is asked**, and the
    /// order is load-bearing rather than incidental: `translatorRole(for:)`
    /// is find-or-create, and the briefing's role frame reads the stored
    /// role. Asked the other way round, a first run for a language would
    /// brief a translator who does not exist yet and sign the queries with
    /// one who does.
    func test_theIdentityIsMintedBeforeTheBriefingReadsIt() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(harness.order, ["translatorIdentity", "briefingInputs"])
    }

    /// A pair the window cannot brief — no such document, no translation
    /// posture — is not an error and not a run. Nothing spawns, nothing is
    /// reported: the click had nothing to act on.
    func test_aPairWithNoBriefingIsNotARun() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: nil)

        harness.orchestrator.runTranslation(docId: docId, language: language)
        settle()

        XCTAssertEqual(runner.sends.count, 0)
        XCTAssertEqual(harness.orchestrator.runState, .idle)
        XCTAssertTrue(harness.summaries.isEmpty,
                      "a click that started nothing ends nothing")
    }

    /// **Nothing stale, nothing missing — no session.** The work-list is the
    /// translator's delta, and spending a subprocess to be told what
    /// `TranslationDeriver` already knows is the compiler's empty-delta
    /// mistake in another currency.
    func test_anEmptyWorkListSpawnsNothing() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs(work: 0))

        harness.orchestrator.runTranslation(docId: docId, language: language)
        settle()

        XCTAssertEqual(runner.sends.count, 0)
        XCTAssertEqual(harness.spawns, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configURL.path),
                       "…and no session config, because no session was wanted")
        guard case .nothingToTranslate(let stateDoc, let stateLanguage, _)
                = harness.orchestrator.runState else {
            return XCTFail("expected the idle 'nothing to translate' variant, got "
                           + "\(harness.orchestrator.runState)")
        }
        XCTAssertEqual(stateDoc, docId)
        XCTAssertEqual(stateLanguage, language,
                       "the state names the edition it is about — a desk row for "
                       + "another language must not read it as its own")
        XCTAssertEqual(harness.summaries.map(\.outcome), [.nothingToTranslate])
    }

    // MARK: - Refusal

    /// A second run while one is in flight is refused, not queued: there is
    /// one session per orchestrator, and a second turn is something the next
    /// click can do.
    func test_aSecondRunWhileRunningIsRefusedNotQueued() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil   // hold the turn open
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(1, on: runner)
        XCTAssertEqual(harness.orchestrator.runState,
                       .running(docId: docId, language: language, translating: 1))

        harness.orchestrator.runTranslation(docId: docId, language: language)
        settle()

        XCTAssertEqual(runner.sends.count, 1, "the second click must not reach the runner")
        XCTAssertEqual(harness.orchestrator.runState,
                       .running(docId: docId, language: language, translating: 1))
        XCTAssertTrue(harness.summaries.isEmpty)

        runner.release(.resultText(Self.oneEntry))
        settle()
    }

    /// The same refusal in the window BEFORE the send, while the run is still
    /// resolving its identity and gathering its briefing. That window is a
    /// manifest write and a store read long in production, and a run started
    /// inside it would build a second briefing over the same work-list.
    func test_aSecondRunDuringTheBriefingGatherIsRefused() throws {
        let runner = SpyRunner()
        let gate = Gate()
        let harness = try makeHarness(runner: runner, inputs: makeInputs(),
                                      holdBriefing: gate)

        harness.orchestrator.runTranslation(docId: docId, language: language)
        settle()
        XCTAssertEqual(gate.entries, 1)

        harness.orchestrator.runTranslation(docId: docId, language: language)
        settle()
        XCTAssertEqual(gate.entries, 1, "the second click must not start a second gather")

        gate.release()
        awaitSends(1, on: runner)
        settle()
        XCTAssertEqual(runner.sends.count, 1)
    }

    // MARK: - Failure writes nothing

    /// **The property the whole loop is built around** (spec §6): a run that
    /// did not come back has written nothing. Ingest is not called with an
    /// empty report, or a partial one — it is not called at all.
    func test_aFailedRunIngestsNothing() throws {
        for failure in [CompilerRunFailure.timedOut, .cliNotFound,
                        .sessionDied(detail: "the CLI exited with status 1")] {
            let runner = SpyRunner()
            runner.nextEvent = .failed(failure)
            let harness = try makeHarness(runner: runner, inputs: makeInputs())

            harness.orchestrator.runTranslation(docId: docId, language: language)
            awaitSends(1, on: runner)
            settle()

            XCTAssertTrue(harness.ingests.isEmpty,
                          "\(failure) reached ingest — a dead session must have "
                          + "written nothing")
            guard case .failed(_, _, let reported, _) = harness.orchestrator.runState else {
                return XCTFail("expected a reported failure for \(failure), got "
                               + "\(harness.orchestrator.runState)")
            }
            XCTAssertEqual(reported, .run(failure))
            XCTAssertEqual(harness.summaries.map(\.outcome), [.failed(.run(failure))])
        }
    }

    /// Output that cannot be read at all is a failure in the same
    /// vocabulary, and writes nothing either. All-or-nothing starts at parse
    /// (`TranslatorReport.parse`): a turn that got one entry wrong is a model
    /// that has lost the contract, and there is no knowing which of its other
    /// entries to trust.
    func test_unusableOutputIsSurfacedAndIngestsNothing() throws {
        for text in ["I had a look and the Spanish is fine, honestly.",
                     // Both forms on one entry — parse refuses the whole report.
                     #"{"entries":[{"paragraph_id":"a1b2","text":"Ya","verbatim":true}],"queries":[]}"#] {
            let runner = SpyRunner()
            runner.nextEvent = .resultText(text)
            let harness = try makeHarness(runner: runner, inputs: makeInputs())

            harness.orchestrator.runTranslation(docId: docId, language: language)
            awaitSends(1, on: runner)
            settle()

            XCTAssertTrue(harness.ingests.isEmpty)
            guard case .failed(_, _, let reported, _) = harness.orchestrator.runState else {
                return XCTFail("expected a reported failure, got "
                               + "\(harness.orchestrator.runState)")
            }
            XCTAssertEqual(reported, .run(.unusableOutput))
        }
    }

    /// An empty report is NOT unusable: a round with nothing further to say
    /// parses, ingests nothing of substance, and ends clean. The converse of
    /// the test above, so a parser tightened too far cannot pass both.
    func test_anEmptyReportIsAValidAnswer() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(#"{"entries":[],"queries":[]}"#)
        let harness = try makeHarness(runner: runner, inputs: makeInputs(),
                                      ingestOutcome: .init())

        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(harness.ingests.count, 1,
                       "an empty report is still a report, and ingest is what "
                       + "decides there is nothing to write")
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

            harness.orchestrator.runTranslation(docId: docId, language: language)
            awaitSends(1, on: runner)
            settle()

            XCTAssertEqual(harness.orchestrator.runState, .idle,
                           "\"\(detail)\" is the writer's own doing, not a failure")
            XCTAssertEqual(harness.summaries.map(\.outcome), [.cancelled])
            XCTAssertTrue(harness.ingests.isEmpty)
        }
    }

    /// An identity that cannot be resolved — a blank language tag, a manifest
    /// that will not commit — fails the run before a session is spawned. The
    /// run is a write act and the translator's name is part of it; running
    /// anyway would produce work nobody could sign.
    func test_anIdentityThatCannotBeResolvedFailsBeforeAnySpawn() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs(), identity: nil)

        harness.orchestrator.runTranslation(docId: docId, language: language)
        settle()

        XCTAssertEqual(runner.sends.count, 0)
        XCTAssertEqual(harness.spawns, 0)
        XCTAssertTrue(harness.ingests.isEmpty)
        XCTAssertEqual(harness.order, ["translatorIdentity"],
                       "…and the briefing is never gathered for a run that cannot "
                       + "happen")
        guard case .failed(_, _, .run(.sessionDied), _) = harness.orchestrator.runState else {
            return XCTFail("expected a reported failure, got "
                           + "\(harness.orchestrator.runState)")
        }
    }

    /// **A batch the pipeline refuses is loud** (spec §6): a paragraph
    /// deleted between the send and the ingest fails the whole batch, and the
    /// run says so rather than ending clean over prose nobody wrote.
    func test_anIngestRejectionIsReportedRatherThanSwallowed() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, inputs: makeInputs(),
            ingestOutcome: .init(rejection: "unknown paragraph ids: a1b2"))

        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(1, on: runner)
        settle()

        guard case .failed(_, _, let reported, _) = harness.orchestrator.runState else {
            return XCTFail("expected a reported failure, got "
                           + "\(harness.orchestrator.runState)")
        }
        XCTAssertEqual(reported, .ingestRejected("unknown paragraph ids: a1b2"))
        XCTAssertEqual(harness.summaries.count, 1,
                       "…and the desk still gets its row, carrying what the ingest "
                       + "reported")
    }

    /// Advisory warnings ride the summary and end the run clean — construct
    /// parity is a note for the desk, never a reason to call a translation
    /// that landed a failure.
    func test_advisoryWarningsRideTheSummaryWithoutFailingTheRun() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, inputs: makeInputs(),
            ingestOutcome: .init(entriesWritten: 1,
                                 warnings: ["a1b2: the translation drops a heading"]))

        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(harness.orchestrator.runState, .idle)
        guard case .ingested(let outcome) = try XCTUnwrap(harness.summaries.first).outcome
        else { return XCTFail("expected an ingested outcome") }
        XCTAssertEqual(outcome.warnings, ["a1b2: the translation drops a heading"])
    }

    // MARK: - The warm session

    /// A second run on the SAME pair reuses the process — the whole point of
    /// a warm session, and what makes an edition's voice accumulate rather
    /// than restart every round.
    func test_theSessionStaysWarmForTheSamePair() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(1, on: runner)
        settle()
        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(2, on: runner)
        settle()

        XCTAssertEqual(harness.spawns, 1, "the second run must reuse the warm session")
        XCTAssertEqual(runner.shutdowns, 0)
    }

    /// …and a run on a different pair does not. A session's context is one
    /// document in one language; crossing either would carry another
    /// edition's register into a round that never asked for it, and unlike
    /// the compiler there is no briefing hash here to tell the process what
    /// it has already been told.
    func test_aChangeOfEitherHalfOfThePairRetiresTheSession() throws {
        for (docId, language) in [("doc-2", "es"), ("doc-1", "fr")] {
            let runner = SpyRunner()
            let harness = try makeHarness(runner: runner, inputs: makeInputs())

            harness.orchestrator.runTranslation(docId: self.docId, language: self.language)
            awaitSends(1, on: runner)
            settle()
            harness.orchestrator.runTranslation(docId: docId, language: language)
            awaitSends(2, on: runner)
            settle()

            XCTAssertEqual(harness.spawns, 2,
                           "(\(docId), \(language)) must be read by a session of its own")
            XCTAssertEqual(runner.shutdowns, 1,
                           "…and the one it replaced must be reaped, not released")
        }
    }

    // MARK: - Cancel and shutdown

    /// Cancel ends the turn and returns the surface to idle without a
    /// failure — and without an ingest, because a cancelled run read half a
    /// document.
    func test_cancelEndsTheRunQuietly() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(1, on: runner)
        harness.orchestrator.cancel()
        settle()

        XCTAssertEqual(runner.cancels, 1)
        XCTAssertEqual(harness.orchestrator.runState, .idle)
        XCTAssertTrue(harness.ingests.isEmpty)
        XCTAssertEqual(harness.summaries.map(\.outcome), [.cancelled])
    }

    /// Cancel BEFORE the send — while the identity or the briefing is still
    /// resolving — has no turn to end, so the run is abandoned by generation
    /// the way `shutdown()` abandons it. Without this the click would mean
    /// "carry on", and the run it did not stop would go on to spend a whole
    /// turn.
    func test_cancelBeforeTheSendAbandonsTheRun() throws {
        let runner = SpyRunner()
        let gate = Gate()
        let harness = try makeHarness(runner: runner, inputs: makeInputs(),
                                      holdBriefing: gate)

        harness.orchestrator.runTranslation(docId: docId, language: language)
        settle()
        harness.orchestrator.cancel()
        gate.release()
        settle()

        XCTAssertEqual(runner.sends.count, 0, "the abandoned run must never send")
        XCTAssertEqual(harness.orchestrator.runState, .idle)
        XCTAssertEqual(harness.summaries.map(\.outcome), [.cancelled],
                       "the desk's row still ends — a spinner nothing closes is "
                       + "worse than a cancelled row")
    }

    /// **Shutdown reaps.** `deinit` cannot, so every path that ends a window
    /// owns this call — and the session's config file goes with it, or the
    /// socket path leaks into the temp directory for the life of the machine.
    func test_shutdownEndsTheSessionAndDeletesItsConfig() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(1, on: runner)
        settle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.configURL.path))

        harness.orchestrator.shutdown()
        settle()

        XCTAssertEqual(runner.shutdowns, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configURL.path))
        XCTAssertEqual(harness.orchestrator.runState, .idle)
    }

    /// A shutdown mid-turn takes the run with it, and the late event that
    /// arrives afterwards must not write anything back — no ingest into a
    /// window that is going away, no failure row on a desk that has gone.
    func test_shutdownMidTurnAbandonsTheRunAndTheLateAnswer() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(1, on: runner)
        harness.orchestrator.shutdown()
        settle()
        // The dying process's last word, arriving after the teardown.
        runner.release(.resultText(Self.oneEntry))
        settle()

        XCTAssertTrue(harness.ingests.isEmpty,
                      "a turn the writer shut down must not write on its way out")
        XCTAssertEqual(harness.orchestrator.runState, .idle)
    }

    /// A writer who closes the window and opens another must still have a
    /// working run: `shutdown()` ends the session and leaves the orchestrator
    /// usable, `detach()` additionally drops the window's object graph — the
    /// compiler's own distinction, and not interchangeable.
    func test_detachDropsTheEnvironmentAndShutdownDoesNot() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, inputs: makeInputs())

        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(1, on: runner)
        settle()

        harness.orchestrator.shutdown()
        harness.orchestrator.runTranslation(docId: docId, language: language)
        awaitSends(2, on: runner)
        settle()
        XCTAssertEqual(runner.sends.count, 2, "shutdown leaves the orchestrator usable")

        harness.orchestrator.detach()
        harness.orchestrator.runTranslation(docId: docId, language: language)
        settle()
        XCTAssertEqual(runner.sends.count, 2, "detach drops the environment with it")
    }

    // MARK: - The shutdown contract, on the record

    /// The contract this type cannot enforce: `deinit` is nonisolated, cannot
    /// touch main-actor state, and deallocating a `Process` neither signals
    /// nor reaps its child — so an orchestrator merely released leaves a
    /// live, billing `claude` behind. `ClaudeCLISession` says this on itself;
    /// the second owner of a session has to say it too, or the next reader
    /// meets the rule only in the file they are not editing.
    func test_theShutdownContractIsRestatedOnThisType() throws {
        let file = try source(at: "Maugham/Compiler/TranslatorOrchestrator.swift")
        for phrase in ["shutdown()", "deinit", "billing"] {
            XCTAssertTrue(file.contains(phrase),
                          "the shutdown contract paragraph is missing \"\(phrase)\"")
        }
        XCTAssertFalse(file.contains("nonisolated deinit {"),
                       "a deinit here would be a reaper that cannot reach the "
                       + "process it claims to reap")
    }
}
