import XCTest
// `@testable` for the injected op-log append failure the wet-ink section arms
// (`OpLogStore.appendFailureForTesting`, `DocumentCloseFlushTests`' own hook).
@testable import MaughamCore
@testable import Maugham

/// **The run command: the keystroke, the path it travels, and what the
/// orchestrator does when it arrives.**
///
/// Tasks 1–6 built a delta, a prompt, a session, a parser and a store, none of
/// which anything called. This suite is about the call — and about the two
/// things that can be built, tested and still not work: a key equivalent that
/// reaches no receiver (the slice-3 ⌘Z lesson, 22 green tests on a shortcut
/// that could not reach the stack), and a marker that advances when the run
/// failed, which loses the writer's prose from every later delta silently.
@MainActor
final class CompilerRunCommandTests: XCTestCase {

    // MARK: - Fixtures

    /// A runner that records what it was asked and answers what the test says.
    ///
    /// `nextEvent == nil` holds the turn open, which is how the in-flight
    /// refusal is arranged: the orchestrator's guard has to be true while a
    /// real `send` is outstanding, not merely between two synchronous calls.
    @MainActor
    private final class SpyRunner: CompilerRunner {
        private(set) var sends: [(message: String, preamble: String?)] = []
        private(set) var shutdowns = 0
        private(set) var cancels = 0
        var isRunning = false
        var sessionEpoch = 1
        /// The event `send` resolves with. `nil` holds the turn open until
        /// `release(_:)`.
        var nextEvent: CompilerRunEvent? = .resultText(CompilerRunCommandTests.fourEmptySections)
        var onSend: (() -> Void)?
        private var held: CheckedContinuation<CompilerRunEvent, Never>?
        /// Where the orchestrator asked its stream to go. Recorded rather than
        /// counted so a test can BE the CLI's stdout — `stream(_:)` below is
        /// the same call `ClaudeCLISession.receive` makes for one delta.
        private(set) var partialHandler: (@MainActor (String) -> Void)?

        func setPartialHandler(_ handler: (@MainActor (String) -> Void)?) {
            partialHandler = handler
        }

        /// Deliver text the way the CLI's deltas do — in fragments the
        /// transport chose, which close nothing.
        func stream(_ chunk: String) { partialHandler?(chunk) }

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

    private let docId = "doc-1"

    // MARK: - v2 fixtures

    /// A turn that honours the contract and has nothing to say — four section
    /// lines, every array empty. The harness default, because most of this
    /// suite is about the run's mechanics rather than its content, and a v1
    /// `{"diagnostics":[]}` is now unreadable output rather than an empty run.
    static let fourEmptySections = """
        {"section":"conformance","checks":[]}
        {"section":"continuity","questions":[]}
        {"section":"reader","reports":[]}
        {"section":"facts","candidates":[]}
        """

    /// One continuity question against `paragraphId` — the smallest turn that
    /// produces a note the pane would show.
    private func oneQuestion(_ question: String, about paragraphId: String) -> String {
        """
        {"section":"conformance","checks":[]}
        {"section":"continuity","questions":[{"cites":"the fog","refs":["\(paragraphId)"],"question":"\(question)"}]}
        {"section":"reader","reports":[]}
        {"section":"facts","candidates":[]}
        """
    }

    private func makeOp(
        opId: String, kind: OpKind = .typingBurst, changes: [Op.ParagraphChange]
    ) -> Op {
        Op(opId: opId, docId: docId, at: Date(), device: "macA", session: "s",
           kind: kind, changes: changes, sequence: nil)
    }

    /// One new paragraph since the beginning of time — the shape of a first run.
    private func standingReading() -> CompilerOrchestrator.DocumentReading {
        CompilerOrchestrator.DocumentReading(
            ops: [makeOp(opId: "op1", kind: .bootstrap,
                         changes: [.init(paragraphId: "a1b2", prior: nil, next: "The fog came.")])],
            paragraphs: ["a1b2": "The fog came."],
            sequence: ["a1b2"])
    }

    /// The run state a run over `standingReading()` sits in — spelled once, so
    /// a test asserting "a run is in flight" is not also restating the
    /// fixture's arithmetic. The counts themselves are asserted where they are
    /// the subject (`test_theRunningStateCarriesWhatItIsReading`).
    private var runningOnTheStandingReading: CompilerOrchestrator.RunState {
        .running(docId: docId, checking: CompilerOrchestrator.DeltaCounts(new: 1, revised: 0))
    }

    private func makeProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompilerRunCommand-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A second paragraph, written after the first run checked the first one.
    ///
    /// Every multi-run test needs this: a successful run advances the marker to
    /// the newest op it saw, so pressing ⌘R twice over unchanged prose is an
    /// empty delta by design and spends no API call. Simulating the writer
    /// typing is the only way to get a second run.
    private func readingAfterMoreWriting() -> CompilerOrchestrator.DocumentReading {
        CompilerOrchestrator.DocumentReading(
            ops: [makeOp(opId: "op1", kind: .bootstrap,
                         changes: [.init(paragraphId: "a1b2", prior: nil, next: "The fog came.")]),
                  makeOp(opId: "op2",
                         changes: [.init(paragraphId: "c3d4", prior: nil, next: "It stayed.")])],
            paragraphs: ["a1b2": "The fog came.", "c3d4": "It stayed."],
            sequence: ["a1b2", "c3d4"])
    }

    private struct Harness {
        let orchestrator: CompilerOrchestrator
        let diagnostics: DiagnosticsStore
        let root: URL
        /// The per-session `--mcp-config` file the orchestrator asked for.
        let configURL: URL
        var flashes: Int { acknowledgments().count }
        /// Every acknowledgment the run key asked the window for, in order —
        /// recorded as VALUES rather than counted, because the second press of
        /// a double-press now flashes too and the whole point is that it says
        /// something different (`Acknowledgment.alreadyChecking`).
        var flashesSaid: [CompilerOrchestrator.Acknowledgment] { acknowledgments() }
        let acknowledgments: () -> [CompilerOrchestrator.Acknowledgment]
        /// What the next run reads off the live document — the writer, typing.
        let setReading: (CompilerOrchestrator.DocumentReading?) -> Void
        /// How many times the run reached for a fresh derivation — the lazy
        /// trigger's own counter (`AREA.md`, "the derivation trigger").
        var derivations: Int { derivationCount() }
        let derivationCount: () -> Int
        /// What the run handed the bible ledger.
        var recordedFacts: [BibleFact] { factsRecorded() }
        let factsRecorded: () -> [BibleFact]
        /// The delta prose the bible slice was asked about.
        var sliceQueries: [String] { slicesAsked() }
        let slicesAsked: () -> [String]
    }

    /// A `prepareForRun` the test can hold open, so the window between the
    /// keystroke and the delta — a real window in production, the length of an
    /// op-log append — is something to assert about rather than race.
    @MainActor
    private final class PrepareGate {
        private(set) var entries = 0
        private var held: CheckedContinuation<Void, Never>?

        func hold(_: String) async {
            entries += 1
            await withCheckedContinuation { held = $0 }
        }

        func release() {
            let continuation = held
            held = nil
            continuation?.resume()
        }
    }

    /// - Parameters:
    ///   - statementText: the writer's intent statement WHOLE — essay and any
    ///     stratum under it. What the briefing embeds is its essay half; what
    ///     the derivation reads is all of it. `nil` is a document with no
    ///     intent anywhere, which is valid and mints nothing.
    ///   - cachedWorld: the reading already held for this statement's exact
    ///     text, or `nil` for a cache miss (which is what makes the run reach
    ///     for `derivedWorld`).
    ///   - derivedWorld: what a fresh derivation would answer. `nil` is the
    ///     honest failure every arm of `ClaudeWorldDeriver` reports.
    private func makeHarness(
        runner: SpyRunner,
        reading: CompilerOrchestrator.DocumentReading?,
        statementText: String? = "Cold, and never wistful.",
        cachedWorld: DerivedWorld? = nil,
        derivedWorld: DerivedWorld? = nil,
        bibleFacts: [BibleFact] = [],
        liveParagraphText: @escaping (String, String) -> String? = { _, _ in "The fog came." },
        pinnedListing: @escaping (String) -> [String] = { _ in [] },
        paletteListing: @escaping () -> [String] = { [] },
        prepareForRun: @escaping @MainActor (String) async -> Void = { _ in },
        /// Holds the derivation open, the way `prepareForRun`'s gate holds the
        /// burst — a real window in production, the length of a subprocess.
        holdDerivation: PrepareGate? = nil
    ) throws -> Harness {
        let root = try makeProjectRoot()
        let diagnostics = DiagnosticsStore(
            projectRoot: root, device: DeviceSlug.make(from: "test-mac"))
        let configURL = root.appendingPathComponent("compiler-mcp.json")
        let flashes = Box<[CompilerOrchestrator.Acknowledgment]>([])
        let live = Box(reading)
        let derivations = Box(0)
        let recorded = Box<[BibleFact]>([])
        let slices = Box<[String]>([])
        let orchestrator = CompilerOrchestrator()
        orchestrator.configure(
            environment: CompilerOrchestrator.Environment(
                projectId: "p-1",
                model: "test-model",
                prepareForRun: prepareForRun,
                reading: { id in id == self.docId ? live.value : nil },
                liveParagraphText: liveParagraphText,
                intent: { _ in
                    statementText.map {
                        CompilerOrchestrator.IntentBriefing(
                            statementText: $0, scopeKey: "doc-doc-1")
                    }
                },
                cachedWorld: { _ in cachedWorld },
                deriveWorld: { _, _ in
                    derivations.value += 1
                    if let holdDerivation { await holdDerivation.hold("") }
                    return derivedWorld
                },
                bibleSlice: { prose in
                    slices.value.append(prose)
                    return bibleFacts
                },
                recordFacts: { recorded.value += $0 },
                pinnedListing: pinnedListing,
                paletteListing: paletteListing,
                writeMCPConfig: {
                    try Data("{}".utf8).write(to: configURL, options: .atomic)
                    return configURL
                },
                makeRunner: { _, _ in runner },
                onRunAcknowledged: { flashes.value.append($0) }),
            diagnostics: diagnostics)
        return Harness(orchestrator: orchestrator, diagnostics: diagnostics,
                       root: root, configURL: configURL,
                       acknowledgments: { flashes.value },
                       setReading: { live.value = $0 },
                       derivationCount: { derivations.value },
                       factsRecorded: { recorded.value },
                       slicesAsked: { slices.value })
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Wait until the spy has been sent `count` messages, so an assertion about
    /// arity is made after the async `send` has actually happened rather than
    /// racing it.
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

    /// Give the main actor a couple of passes, so an assertion that something
    /// did NOT happen has a turn in which it could have.
    ///
    /// Two turns, through `Task` rather than `DispatchQueue.main.async`: a run
    /// closes the writer's pending typing burst before it reads anything
    /// (`Environment.prepareForRun`), so the delta is now decided one hop after
    /// the keystroke. A single dispatched block can be drained ahead of that
    /// hop, and an assertion made in the gap reads a run that has not started
    /// yet as one that decided not to.
    private func settle(turns: Int = 2) {
        for turn in 0..<turns {
            let settled = expectation(description: "the run loop ran (\(turn))")
            Task { @MainActor in settled.fulfill() }
            wait(for: [settled], timeout: 2)
        }
    }

    /// The two helpers above, for an `async` test method.
    ///
    /// **Not a convenience.** `wait(for:)` inside an `async @MainActor` test
    /// blocks the main actor's own thread, so the run's prepare hop and the
    /// spy's `send` can never be scheduled at all: every expectation times out
    /// having proved nothing about the code under test. `fulfillment(of:)`
    /// suspends instead, which is what lets the main actor run the work being
    /// waited on. The sync overloads stay for the sync tests, which spin a real
    /// run loop and are fine.
    private func awaitSends(_ count: Int, on runner: SpyRunner) async {
        let reached = expectation(description: "\(count) send(s) reached the runner")
        if runner.sends.count >= count {
            reached.fulfill()
        } else {
            runner.onSend = { if runner.sends.count >= count { reached.fulfill() } }
        }
        await fulfillment(of: [reached], timeout: 2)
        runner.onSend = nil
    }

    private func settle(turns: Int = 2) async {
        for turn in 0..<turns {
            let settled = expectation(description: "the run loop ran (\(turn))")
            Task { @MainActor in settled.fulfill() }
            await fulfillment(of: [settled], timeout: 2)
        }
    }

    private func source(at relativePath: String) throws -> String {
        // Two levels up: `MaughamTests/` → the repo. This file is flat in
        // MaughamTests; `CanvasSourceCensus` resolves three and says in its own
        // doc comment that a suite living elsewhere needs its own.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - The real delivery path

    /// **The keystroke reaches the orchestrator, or none of the above matters.**
    ///
    /// Driven through the real post and the real scope filter rather than by
    /// calling `runRequested` directly: `MaughamEvent.shouldDeliver` drops a
    /// post whose scope does not match the receiver's, with nothing red
    /// anywhere, and that is precisely the failure this test exists to catch.
    func test_theRunKeyReachesTheOrchestratorThroughTheEvent() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        let token = MaughamEvent.observe(
            .maughamRunCompiler,
            context: { EventReceiverContext(kind: .keyWindow, isWindowLive: true,
                                            isWindowKey: true) },
            handler: { [docId] _ in harness.orchestrator.runRequested(docId: docId) })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.postCompilerRun()
        awaitSends(1, on: runner)

        XCTAssertEqual(runner.sends.count, 1,
                       "the menu item's post must reach the orchestrator and start "
                       + "exactly one run")
        XCTAssertTrue(runner.sends[0].message.contains("The fog came."),
                      "…carrying the delta, not an empty message")
    }

    /// The other half of the scope rule: a window that is not key must not run.
    /// ⌘R is a menu command, and a background window acting on it would run the
    /// wrong document against the wrong intent.
    func test_aWindowThatIsNotKeyDoesNotRun() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        let token = MaughamEvent.observe(
            .maughamRunCompiler,
            context: { EventReceiverContext(kind: .keyWindow, isWindowLive: true,
                                            isWindowKey: false) },
            handler: { [docId] _ in harness.orchestrator.runRequested(docId: docId) })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.postCompilerRun()
        settle()

        XCTAssertEqual(runner.sends.count, 0)
    }

    /// **The wiring census.** The two ends of the path above are a menu item in
    /// `MaughamApp` and a subscription in `CompilerRunModifier`, neither of
    /// which a test can mount. Delete either and every assertion in this file
    /// still passes while ⌘R does nothing at all — this is what says so.
    func test_theRunCommandIsWiredFromTheMenuToTheWindow() throws {
        let app = try source(at: "Maugham/MaughamApp.swift")
        XCTAssertTrue(app.contains("MaughamEvent.postCompilerRun()"),
                      "the menu item must post through the typed wrapper (tripwire 21)")
        XCTAssertTrue(app.contains(#".keyboardShortcut("r", modifiers: .command)"#),
                      "…and carry ⌘R, which was verified unbound at implementation time")

        let modifier = try source(at: "Maugham/Views/CompilerRunModifier.swift")
        for token in [".onKeyWindowCommand(.maughamRunCompiler",
                      "orchestrator.runRequested(",
                      ".onGlobalEvent(.maughamAppWillTerminate)",
                      "orchestrator.shutdown()"] {
            XCTAssertTrue(modifier.contains(token),
                          "CompilerRunModifier is missing \(token)")
        }
        XCTAssertFalse(modifier.contains(".onKeyWindowCommand(.maughamNotARealEvent"),
                       "the scan reads the file rather than always answering true")

        let window = try source(at: "Maugham/Views/ProjectWindow.swift")
        for token in ["CompilerRunModifier(", "compiler.detach()",
                      "SaveFlashOverlay(isShowing: $showingCompilerFlash"] {
            XCTAssertTrue(window.contains(token),
                          "ProjectWindow is missing \(token) — without the first the "
                          + "modifier is never mounted, without the second a closed "
                          + "window keeps its session and its stores alive, and without "
                          + "the third the keystroke is unacknowledged")
        }
    }

    // MARK: - Refusal

    /// ⌘R while a run is in flight starts nothing — and **says so**, which is
    /// the judgment M2 Task 7 made the other way (run-rebuilt Task 5).
    ///
    /// The original reasoning was that ⌘S's capsule promises work was done, so
    /// flashing over a check already running would be the key lying. That
    /// reasoning is answered by the copy rather than overruled: "Still
    /// checking…" claims nothing started. What the silence cost was measurable
    /// — a cold first run takes ~2 minutes, and a writer whose second press
    /// produced no reaction at all cannot tell a busy compiler from a dead
    /// keystroke. Everything else about the refusal is unchanged: no second
    /// send, no second session, the running state untouched.
    func test_runWhileRunningStartsNothingAndSaysSo() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil   // hold the turn open
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        XCTAssertEqual(harness.orchestrator.runState,
                       .running(docId: docId,
                                checking: CompilerOrchestrator.DeltaCounts(new: 1, revised: 0)))
        XCTAssertEqual(harness.flashesSaid, [.started])

        harness.orchestrator.runRequested(docId: docId)
        settle()

        XCTAssertEqual(runner.sends.count, 1, "the second ⌘R must not reach the runner")
        XCTAssertEqual(harness.orchestrator.runState,
                       .running(docId: docId,
                                checking: CompilerOrchestrator.DeltaCounts(new: 1, revised: 0)))
        XCTAssertEqual(harness.flashesSaid, [.started, .alreadyChecking],
                       "the second press is acknowledged, and by a different sentence — "
                       + "a second \u{201C}Checking\u{2026}\u{201D} would be the key claiming "
                       + "it started a run it refused")
        XCTAssertEqual(CompilerOrchestrator.Acknowledgment.started.flashLabel, "Checking\u{2026}")
        XCTAssertEqual(CompilerOrchestrator.Acknowledgment.alreadyChecking.flashLabel,
                       "Still checking\u{2026}")

        runner.release(.resultText(Self.fourEmptySections))
        settle()
    }

    /// The same second press, **through the real event and the real scope
    /// filter** rather than a direct call — `MaughamEvent.shouldDeliver` drops
    /// a post whose scope does not match with nothing red anywhere, so an
    /// acknowledgment proven only from `runRequested` proves nothing about the
    /// key a writer actually presses.
    func test_theSecondPressIsAcknowledgedOnTheDeliveryPath() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil   // hold the turn open
        let harness = try makeHarness(runner: runner, reading: standingReading())

        let token = MaughamEvent.observe(
            .maughamRunCompiler,
            context: { EventReceiverContext(kind: .keyWindow, isWindowLive: true,
                                            isWindowKey: true) },
            handler: { [docId] _ in harness.orchestrator.runRequested(docId: docId) })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.postCompilerRun()
        awaitSends(1, on: runner)
        MaughamEvent.postCompilerRun()
        settle()

        XCTAssertEqual(runner.sends.count, 1)
        XCTAssertEqual(harness.flashesSaid, [.started, .alreadyChecking],
                       "⌘R pressed twice must acknowledge twice, and the second must "
                       + "say it started nothing")

        runner.release(.resultText(Self.fourEmptySections))
        settle()
    }

    /// **What the wait says it is reading.** The running state carries the
    /// delta's own counts, resolved before the send, so the pane's header can
    /// name what the compiler is checking rather than making a writer stare at
    /// a bare "Checking…" for two minutes (requirement 5).
    func test_theRunningStateCarriesWhatItIsReading() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(
            runner: runner,
            reading: CompilerOrchestrator.DocumentReading(
                ops: [makeOp(opId: "op1", changes: [
                        .init(paragraphId: "a1b2", prior: nil, next: "The fog came."),
                        .init(paragraphId: "c3d4", prior: nil, next: "It stayed."),
                        .init(paragraphId: "e5f6", prior: "A cold morning.",
                              next: "A colder morning.")]),
                ],
                paragraphs: ["a1b2": "The fog came.", "c3d4": "It stayed.",
                             "e5f6": "A colder morning."],
                sequence: ["a1b2", "c3d4", "e5f6"]))

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)

        guard case .running(_, let checking) = harness.orchestrator.runState else {
            return XCTFail("expected a running state, got \(harness.orchestrator.runState)")
        }
        XCTAssertEqual(checking.new + checking.revised, 3,
                       "the counts must describe the delta this run actually built")

        runner.release(.resultText(Self.fourEmptySections))
        settle()
    }

    // MARK: - The empty delta

    /// Nothing new since the last run spawns nothing. The session is the
    /// expensive part; asking it to read an empty delta costs a real API call
    /// to be told what `DeltaBuilder` already knows.
    func test_emptyDeltaDoesNotSpawn() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner,
            reading: CompilerOrchestrator.DocumentReading(
                ops: [], paragraphs: [:], sequence: []))

        harness.orchestrator.runRequested(docId: docId)
        settle()

        XCTAssertEqual(runner.sends.count, 0)
        guard case .nothingNew(let stateDocId, _) = harness.orchestrator.runState else {
            return XCTFail("expected the idle 'nothing new' variant, got "
                           + "\(harness.orchestrator.runState)")
        }
        XCTAssertEqual(stateDocId, docId,
            "the state names the document it is about — a pane on another "
            + "document must not read it as its own")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configURL.path),
                       "…and no session config, because no session was wanted")
    }

    /// **An empty delta still moves the marker.** Ops can land that change no
    /// prose — a checkpoint, an annotation — and a marker that does not pass
    /// them makes every later run re-walk them for nothing.
    func test_anEmptyDeltaStillAdvancesTheMarker() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner,
            reading: CompilerOrchestrator.DocumentReading(
                ops: [makeOp(opId: "op1", changes: [
                          .init(paragraphId: "a1b2", prior: nil, next: "The fog came.")]),
                      makeOp(opId: "op2", kind: .claudeComment, changes: [
                          .init(paragraphId: "a1b2", prior: nil, next: "The fog came.")])],
                paragraphs: ["a1b2": "The fog came."],
                sequence: ["a1b2"]))
        // A run already happened and checked as of op1.
        harness.diagnostics.replace(
            run: CompilerRun(id: "r0", at: Date(), model: "test-model", lastOpId: "op1",
                             deltaSummary: "1 new, 0 revised \u{00b6}", intentSnapshot: nil),
            diagnostics: [], docId: docId)

        harness.orchestrator.runRequested(docId: docId)
        settle()

        XCTAssertEqual(runner.sends.count, 0)
        XCTAssertEqual(harness.diagnostics.lastOpId(docId: docId), "op2",
                       "the annotation op changed no prose, but the next run must "
                       + "not read it again")
    }

    /// **⌘R twice over prose nobody has touched spends nothing.** A successful
    /// run advances the marker to the newest op it saw, so the second press
    /// finds an empty delta and never reaches the session — the run key is
    /// cheap to lean on, which is the whole design (spec §1).
    func test_asecondRunOverUnchangedProseCostsNothing() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        harness.orchestrator.runRequested(docId: docId)
        settle()

        XCTAssertEqual(runner.sends.count, 1)
        guard case .nothingNew = harness.orchestrator.runState else {
            return XCTFail("expected 'nothing new', got \(harness.orchestrator.runState)")
        }
    }

    // MARK: - The flash

    /// The keystroke is acknowledged the way ⌘S is — the muscle-memory
    /// contract, not a progress indicator.
    func test_theAcknowledgmentFlashFires() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        XCTAssertEqual(harness.flashes, 0)
        harness.orchestrator.runRequested(docId: docId)
        XCTAssertEqual(harness.flashes, 1,
                       "the flash is synchronous with the keystroke — a flash that "
                       + "waits for the subprocess is not an acknowledgment")
        awaitSends(1, on: runner)
    }

    /// A subject the window has no document for — the project row, or nothing
    /// selected — is not an error and not a run. Nothing flashes, because
    /// nothing was started.
    func test_aSubjectWithNoDocumentIsNotARun() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: BinderSubject.noDocumentSubject)
        settle()

        XCTAssertEqual(runner.sends.count, 0)
        XCTAssertEqual(harness.flashes, 0)
        XCTAssertEqual(harness.orchestrator.runState, .idle)
    }

    // MARK: - The marker

    /// **The marker advances only on a run that produced something to store.**
    /// Advance it on a failure and every paragraph written since the last good
    /// run is invisible to every future run — the words are still on disk, but
    /// the compiler never sees them again, and nothing on screen says so.
    func test_theMarkerAdvancesOnlyOnSuccess() throws {
        let runner = SpyRunner()
        runner.nextEvent = .failed(.timedOut)
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertNil(harness.diagnostics.lastOpId(docId: docId),
                     "a run that never produced a result checked nothing")
        guard case .failed(let stateDocId, let failure, _) = harness.orchestrator.runState
        else {
            return XCTFail("expected a reported failure, got \(harness.orchestrator.runState)")
        }
        XCTAssertEqual(failure, .timedOut)
        XCTAssertEqual(stateDocId, docId,
            "the failure belongs to the document it was raised on — otherwise a "
            + "red line follows the writer to a document that never ran")

        // The same document, the same delta, a run that comes back.
        runner.nextEvent = .resultText(
            oneQuestion("Two beats, not three?", about: "a1b2"))
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()

        XCTAssertEqual(harness.diagnostics.lastOpId(docId: docId), "op1")
        XCTAssertEqual(harness.orchestrator.runState, .idle)
        let notes = harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." })
        XCTAssertEqual(notes.map(\.body), ["Two beats, not three?"])
        XCTAssertEqual(harness.diagnostics.lastRun(docId: docId)?.intentSnapshot,
                       "Cold, and never wistful.",
                       "the run records what it was judged against — the one thing "
                       + "promote-to-task cannot recover later")
    }

    /// Output that cannot be read at all is a failure, and a failure does not
    /// move the marker either.
    func test_unusableOutputDoesNotAdvanceTheMarker() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText("I had a look and it's fine, honestly.")
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertNil(harness.diagnostics.lastOpId(docId: docId))
        guard case .failed(_, let failure, _) = harness.orchestrator.runState else {
            return XCTFail("expected a reported failure, got \(harness.orchestrator.runState)")
        }
        XCTAssertEqual(failure, .unusableOutput)
    }

    /// **The sections are stored in the order the contract sends them**, so the
    /// pane reads a store it never has to re-sort — two places that can
    /// disagree about the order is what the v1 drift-first rule existed to
    /// prevent, and the ordering outlived the note kind that motivated it.
    ///
    /// v1's `intent_drift` has no successor here: drift becomes a PATTERN
    /// computed across run records in Stage 3 (spec §3.4), and this stage
    /// carries nothing in its place.
    func test_theSectionsAreStoredInTheOrderTheContractSendsThem() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText("""
            {"section":"conformance","checks":[{"clause_quote":"Cold, and never wistful.","status":"strains","refs":["a1b2"],"what_pulls":"The fog is doing the feeling here."}]}
            {"section":"continuity","questions":[{"cites":"three days","refs":["a1b2"],"question":"Has anyone said how long yet?"}]}
            {"section":"reader","reports":[{"kind":"belief","refs":["a1b2"],"report":"The reader believes the fog is a person."}]}
            {"section":"facts","candidates":[]}
            """)
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let notes = harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." })
        XCTAssertEqual(notes.map(\.kind),
                       [.conformanceStrain, .continuity, .readerReport],
                       "conformance leads, then continuity, then the reader — the "
                       + "contract's own order, kept by the store")
        XCTAssertEqual(
            harness.diagnostics.lastRun(docId: docId)?.clauseStatuses?.map(\.status),
            ["strains"],
            "…and the summary the pane leads with rides on the run record")
    }

    /// **A run that lost every note it raised records that it did.** The model
    /// returned three real notes against paragraphs the writer has since
    /// changed; ingest correctly drops all three and accepts nothing. Counted
    /// and then discarded, that run is indistinguishable in the store from one
    /// with nothing to say, and the pane puts the seal on it — the compiler
    /// looked, spoke, and was mistranscribed.
    func test_aRunWhoseNotesAllDangledRecordsWhatItLost() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText("""
            {"section":"conformance","checks":[]}
            {"section":"continuity","questions":[{"cites":"the fog","refs":["gone1"],"question":"Two beats, not three?"},
                                                 {"cites":"the fog","refs":["gone2"],"question":"Does the tense slip here?"},
                                                 {"cites":"the fog","refs":["gone3"],"question":"Does this repeat the last line?"}]}
            {"section":"reader","reports":[]}
            {"section":"facts","candidates":[]}
            """)
        // No paragraph the notes name is still in the document.
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            liveParagraphText: { _, _ in nil })

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(
            harness.diagnostics.live(docId: docId, currentText: { _ in nil }).count, 0,
            "nothing could be placed, so nothing is live")
        XCTAssertEqual(harness.diagnostics.lastRun(docId: docId)?.droppedDangling, 3,
            "the run record carries what the ingest lost, or the pane cannot "
            + "tell this from a clean bill")
    }

    /// The converse: a run that placed everything it raised lost nothing, so
    /// the clean-run line has nothing to append.
    func test_aRunThatPlacedItsNotesRecordsNoLoss() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(oneQuestion("Two beats, not three?", about: "a1b2"))
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(harness.diagnostics.lastRun(docId: docId)?.droppedDangling, 0)
    }

    // MARK: - What is not a failure

    /// **The writer's own actions are not errors.** Cancel, project close, the
    /// AI toggle and a refused overlapping send all come back as
    /// `.sessionDied`, and a red banner reading "session died" after the writer
    /// pressed Cancel is the surface apologising for doing what it was told.
    func test_theWritersOwnActionsAreNotSurfacedAsFailures() throws {
        for detail in [CompilerRunFailure.Detail.cancelled,
                       CompilerRunFailure.Detail.sessionShutDown,
                       CompilerRunFailure.Detail.runInFlight] {
            let runner = SpyRunner()
            runner.nextEvent = .failed(.sessionDied(detail: detail))
            let harness = try makeHarness(runner: runner, reading: standingReading())

            harness.orchestrator.runRequested(docId: docId)
            awaitSends(1, on: runner)
            settle()

            XCTAssertEqual(harness.orchestrator.runState, .idle,
                           "\"\(detail)\" is the writer's own doing, not a failure")
        }
    }

    /// A session that really did die IS reported — the suppression above must
    /// not swallow the case the writer needs to know about.
    func test_aSessionThatDiedOnItsOwnIsReported() throws {
        let runner = SpyRunner()
        runner.nextEvent = .failed(.sessionDied(detail: "the CLI exited with status 1"))
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        guard case .failed = harness.orchestrator.runState else {
            return XCTFail("a real death must reach the writer, got "
                           + "\(harness.orchestrator.runState)")
        }
    }

    /// The three suppressed spellings are minted by the session and read by the
    /// orchestrator, so they are constants rather than two copies of a string —
    /// the `MaughamEvent.personaKey` reasoning. A raw literal on either side is
    /// a rename away from a failure surface that never appears or never clears.
    func test_theSuppressedDetailsAreOneSpellingSharedByBothSides() throws {
        let session = try source(at: "Maugham/Compiler/ClaudeCLISession.swift")
        for raw in ["\"cancelled\"", "\"session shut down\"",
                    "\"a run is already in flight\""] {
            XCTAssertFalse(session.contains("detail: \(raw)"),
                           "ClaudeCLISession mints \(raw) as a raw literal — the "
                           + "orchestrator's suppression reads "
                           + "CompilerRunFailure.Detail, and the two can drift apart")
        }
        XCTAssertTrue(session.contains("Detail.cancelled"),
                      "…and the scan reads the file rather than always answering true")
    }

    // MARK: - Cancel

    /// Cancel ends the turn and returns the surface to idle without a failure.
    func test_cancelEndsTheRunQuietly() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        harness.orchestrator.cancel()
        settle()

        XCTAssertEqual(runner.cancels, 1)
        XCTAssertEqual(harness.orchestrator.runState, .idle)
        XCTAssertNil(harness.diagnostics.lastOpId(docId: docId),
                     "a cancelled run checked nothing")
    }

    // MARK: - The session's config file

    /// **Written once per session, reused, and deleted when the session dies.**
    /// The orchestrator owns this file's whole life (Task 5's session takes a
    /// path and never cleans up); one per run would litter the temp directory
    /// with a JSON file per keystroke.
    func test_theSessionConfigIsWrittenOnceAndDeletedOnShutdown() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.configURL.path))
        let writtenAt = try FileManager.default
            .attributesOfItem(atPath: harness.configURL.path)[.creationDate] as? Date

        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()
        XCTAssertEqual(
            try FileManager.default
                .attributesOfItem(atPath: harness.configURL.path)[.creationDate] as? Date,
            writtenAt,
            "the second run reuses the live session's config rather than writing "
            + "a second one")

        harness.orchestrator.shutdown()
        XCTAssertEqual(runner.shutdowns, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configURL.path),
                       "an un-deleted config leaks the socket path into the temp "
                       + "directory for the life of the machine")
    }

    // MARK: - Diffed-in context

    /// The declared world is sent whole on the first run and elided on the
    /// second — the spec's diffed-in context (§3.3), which is what makes run N
    /// cost the new paragraphs rather than the world. v2 widened the unit from
    /// the intent alone to essay + clauses + facts together
    /// (`CompilerPrompt.runMessageV2`'s `briefingHash`).
    func test_theBriefingIsSentOnceWhileTheSessionLives() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        XCTAssertTrue(runner.sends[0].message.contains("Cold, and never wistful."))

        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()
        XCTAssertFalse(runner.sends[1].message.contains("Cold, and never wistful."))
        XCTAssertTrue(runner.sends[1].message.contains("unchanged since last run"))
    }

    /// **…and sent again the moment the process behind the session is not the
    /// one that read it.** A session that timed out, was cancelled or expired
    /// idle respawns on the next send with no memory of anything; telling that
    /// fresh process the briefing is "unchanged since last run" describes a run
    /// it never saw, and it judges the prose against nothing.
    func test_aRespawnedSessionIsSentTheWholeBriefingAgain() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        runner.sessionEpoch += 1   // the process was retired between runs
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()

        XCTAssertTrue(runner.sends[1].message.contains("Cold, and never wistful."),
                      "a respawned session has read nothing, so it is told everything")
    }

    /// Every run carries the session preamble, because the session applies it at
    /// spawn and a respawn has to re-apply it (`CompilerRunner.send`'s contract).
    func test_everyRunCarriesTheSessionPreamble() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()

        for send in runner.sends {
            XCTAssertEqual(send.preamble,
                           CompilerPrompt.sessionSystemPreamble(projectId: "p-1"))
        }
    }

    // MARK: - Context listings (what the writer pinned)

    /// The two listings reach the assembled prompt, each under its own
    /// section, when the environment has something to say.
    func test_nonEmptyListingsReachThePromptWithTheirSections() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            pinnedListing: { _ in ["Sarah (res-sarah) — read_document"] },
            paletteListing: { ["Act II fog (res-card)"] })

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let message = runner.sends[0].message
        XCTAssertTrue(message.contains("Pinned references"))
        XCTAssertTrue(message.contains("Sarah (res-sarah) — read_document"))
        XCTAssertTrue(message.contains("Palette cards"))
        XCTAssertTrue(message.contains("Act II fog (res-card)"))
    }

    /// The converse: nothing pinned, nothing in the palette — both sections
    /// are absent, not present-and-empty. This is the harness default, so
    /// every other test in this file already exercises this path; this one
    /// names it.
    func test_emptyListingsOmitTheirSectionsFromThePrompt() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let message = runner.sends[0].message
        XCTAssertFalse(message.contains("Pinned references"))
        XCTAssertFalse(message.contains("Palette cards"))
    }

    /// **The briefing hash is tracked per document, not per session.** One warm
    /// session serves every document the writer visits in the window, so a
    /// single last-sent hash would let a switch between two documents corrupt
    /// the elision: document B's run would compare against document A's hash
    /// (masked whenever the two briefings differ, which is the trap), and a
    /// later run back on A would wrongly re-send its whole briefing — or worse,
    /// wrongly elide it — because the tracker remembers the wrong document.
    func test_theBriefingHashIsPerDocument_notPerSession() throws {
        let runner = SpyRunner()
        let root = try makeProjectRoot()
        let diagnostics = DiagnosticsStore(
            projectRoot: root, device: DeviceSlug.make(from: "test-mac"))
        let configURL = root.appendingPathComponent("compiler-mcp.json")
        let docA = "doc-a", docB = "doc-b"
        let intentFor: [String: String] = [docA: "Intent A.", docB: "Intent B."]

        func reading(_ docId: String, opId: String, paragraphId: String, text: String)
        -> CompilerOrchestrator.DocumentReading {
            CompilerOrchestrator.DocumentReading(
                ops: [Op(opId: opId, docId: docId, at: Date(), device: "macA", session: "s",
                        kind: .bootstrap,
                        changes: [.init(paragraphId: paragraphId, prior: nil, next: text)],
                        sequence: nil)],
                paragraphs: [paragraphId: text], sequence: [paragraphId])
        }

        let readingA = Box(reading(docA, opId: "opA1", paragraphId: "aaaa", text: "Doc A, part one."))
        let readingB = Box(reading(docB, opId: "opB1", paragraphId: "bbbb", text: "Doc B, part one."))

        let orchestrator = CompilerOrchestrator()
        orchestrator.configure(
            environment: CompilerOrchestrator.Environment(
                projectId: "p-1",
                model: "test-model",
                prepareForRun: { _ in },
                reading: { id in
                    id == docA ? readingA.value : (id == docB ? readingB.value : nil)
                },
                liveParagraphText: { _, _ in nil },
                intent: { docId in
                    intentFor[docId].map {
                        CompilerOrchestrator.IntentBriefing(
                            statementText: $0, scopeKey: "doc-\(docId)")
                    }
                },
                cachedWorld: { _ in nil },
                deriveWorld: { _, _ in nil },
                bibleSlice: { _ in [] },
                recordFacts: { _ in },
                pinnedListing: { _ in [] },
                paletteListing: { [] },
                writeMCPConfig: {
                    try Data("{}".utf8).write(to: configURL, options: .atomic)
                    return configURL
                },
                makeRunner: { _, _ in runner },
                onRunAcknowledged: { _ in }),
            diagnostics: diagnostics)

        orchestrator.runRequested(docId: docA)
        awaitSends(1, on: runner)
        settle()
        XCTAssertTrue(runner.sends[0].message.contains("Intent A."),
                      "document A's first run sends its intent whole")

        orchestrator.runRequested(docId: docB)
        awaitSends(2, on: runner)
        settle()
        XCTAssertTrue(runner.sends[1].message.contains("Intent B."),
                      "document B's first run must send its own intent whole — "
                      + "it has never been sent, whatever A just sent")

        // More writing on A, so the third run has a non-empty delta.
        readingA.value = reading(docA, opId: "opA2", paragraphId: "cccc", text: "Doc A, part two.")
        orchestrator.runRequested(docId: docA)
        awaitSends(3, on: runner)
        settle()
        XCTAssertTrue(runner.sends[2].message.contains("unchanged since last run"),
                      "document A's hash was recorded on run 1 and must still be "
                      + "found on run 3 — a session-wide tracker would have "
                      + "overwritten it with document B's hash on run 2")
        XCTAssertFalse(runner.sends[2].message.contains("Intent A."),
                       "…so the elided run must not carry the full text either")
    }

    // MARK: - The declared world

    /// A statement with a Rulings stratum under it, and the reading Claude
    /// made of the whole thing.
    private func statementWithARuling() -> String {
        """
        Cold, and never wistful.

        \(RulingsSection.heading)

        - Kelly heard about the call offstage — ruled 7 Aug 2026, from a compiler note
        """
    }

    private func readingOf(_ statement: String) -> DerivedWorld {
        DerivedWorld(
            sourceHash: DerivedWorld.sourceHash(of: statement),
            clauses: [DerivedClause(quote: "Cold, and never wistful.",
                                    check: "No sentence may reach for nostalgia.")],
            rules: [DerivedRule(subject: "Kelly",
                                quote: "Kelly heard about the call offstage",
                                constraint: "No scene may show Kelly learning it on the page.")],
            derivedAt: Date())
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// **The atomic switch, in one assertion: a ruling reaches the run as a
    /// derived clause and never as its own prose.**
    ///
    /// Until this task the run briefed the statement WHOLE, which was right
    /// while nothing consumed the derivation — rulings are declarations and the
    /// old contract had to see them. The moment the derived clauses go in, the
    /// same sentence is in the message twice: once as the writer's line and
    /// once as the clause read off it. That is not merely wasteful. A model
    /// asked to check a delta against a world it has been told twice weights
    /// the doubled clause over the rest of the writer's intent, and the run
    /// quietly stops being about the essay.
    ///
    /// So the two halves of the switch had to land together, and this is the
    /// guard on the pair: the essay is present, the reading is present, and the
    /// section the reading came from is nowhere.
    func test_rulingsAreBriefedAsClausesNotProse() throws {
        let runner = SpyRunner()
        let statement = statementWithARuling()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            statementText: statement, cachedWorld: readingOf(statement))

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let message = runner.sends[0].message
        XCTAssertTrue(message.contains("Cold, and never wistful."),
                      "the essay is what the writer declared in prose, and it is "
                      + "still briefed as prose")
        XCTAssertTrue(message.contains("No scene may show Kelly learning it on the page."),
                      "the ruling reaches the run as its derived reading")

        XCTAssertFalse(message.contains(RulingsSection.heading),
                       "the rulings SECTION must not be in the message — the clauses "
                       + "are what carries it now")
        XCTAssertFalse(message.contains("ruled 7 Aug 2026"),
                       "…nor the row's own date and provenance, which are the pane's "
                       + "furniture and mean nothing to a reader of prose")
        XCTAssertEqual(
            occurrences(of: "Kelly heard about the call offstage", in: message), 1,
            "the double-count guard: the writer's sentence appears once, as the "
            + "rule's quote. Twice means the whole-text briefing survived the "
            + "switch and the run is over-weighting one declaration")
    }

    /// **The lazy trigger: a reading already made for exactly this text is
    /// served, and nothing is spawned.** `AREA.md`'s "derivation trigger"
    /// section — the first consumer that finds the cache empty is the one that
    /// derives, and a consumer that finds it full derives nothing.
    func test_aCachedReadingIsServedAndNothingIsDerived() throws {
        let runner = SpyRunner()
        let statement = statementWithARuling()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            statementText: statement, cachedWorld: readingOf(statement))

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(harness.derivations, 0,
                       "a hit must spawn no `claude -p` — a derivation per run is a "
                       + "subprocess and a bill per keystroke")
        XCTAssertTrue(runner.sends[0].message.contains("No sentence may reach for nostalgia."))
    }

    /// The converse, and the first production caller `derive` has ever had: a
    /// miss derives exactly once and briefs what came back.
    func test_aCacheMissDerivesOnceAndBriefsTheReading() throws {
        let runner = SpyRunner()
        let statement = statementWithARuling()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            statementText: statement, cachedWorld: nil,
            derivedWorld: readingOf(statement))

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(harness.derivations, 1)
        XCTAssertTrue(runner.sends[0].message.contains("No sentence may reach for nostalgia."),
                      "the fresh reading is what the run is briefed on")
    }

    /// **A derivation that could not be had costs the clauses and not the
    /// run.** The CLI is missing, the toggle went off between the keystroke and
    /// the spawn, the model answered prose — all of them are `nil` from
    /// `WorldDeriver.derive`, and all of them leave a writer who pressed ⌘R
    /// with a check of their wet ink against their essay. Honest, not fatal.
    func test_aDerivationThatFailsStillBriefsTheEssay() throws {
        let runner = SpyRunner()
        let statement = statementWithARuling()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            statementText: statement, cachedWorld: nil, derivedWorld: nil)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let message = runner.sends[0].message
        XCTAssertTrue(message.contains("Cold, and never wistful."),
                      "the essay still reaches the run")
        XCTAssertFalse(message.contains("Declared world —"),
                       "…and no clause section is invented for a reading that does "
                       + "not exist")
        XCTAssertEqual(harness.orchestrator.runState, .idle,
                       "a missing derivation is not a failed run")
    }

    /// **No statement at all is a valid state and still a run.** M1A's rule —
    /// absence mints nothing — means a writer who has never written an intent
    /// gets the reader's report and the continuity questions, with the
    /// conformance section simply having nothing to check (the schema tolerates
    /// an empty `checks` array).
    func test_noDeclaredWorldStillRuns() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), statementText: nil)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(harness.derivations, 0, "there is nothing to derive")
        let message = runner.sends[0].message
        XCTAssertTrue(message.contains("The fog came."), "the delta is still briefed")
        XCTAssertTrue(message.contains(CompilerPrompt.sectionSchemaDescription),
                      "…and the four-section contract is still asked for")
        XCTAssertEqual(harness.orchestrator.runState, .idle)
        XCTAssertNil(harness.diagnostics.lastRun(docId: docId)?.intentSnapshot,
                     "the run records that it was judged against nothing declared")
    }

    /// **The bible slice goes out and the run's fact-candidates come back.**
    /// The ledger is what the compiler already believes; the candidates are
    /// what this delta established. Neither is ever rendered as a note — they
    /// land in the store and surface in the Intent pane's bible stratum.
    func test_theBibleSliceIsBriefedAndTheRunsFactsAreRecorded() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText("""
            {"section":"conformance","checks":[]}
            {"section":"continuity","questions":[]}
            {"section":"reader","reports":[]}
            {"section":"facts","candidates":[{"subject":"Kelly","fact":"Kelly is at the dock by dawn.","refs":["a1b2"]}]}
            """)
        let known = BibleFact(
            id: "f1", subject: "Kelly", fact: "Kelly has never seen the sea.",
            establishedAt: "z9y8", docId: "doc-1", recordedAt: Date())
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), bibleFacts: [known])

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertTrue(runner.sends[0].message.contains("Kelly has never seen the sea."),
                      "what the ledger already holds about this delta's subjects is "
                      + "briefed — a run about Kelly's scene carries Kelly's facts")
        XCTAssertEqual(harness.sliceQueries.first?.contains("The fog came."), true,
                       "…and the slice is asked against the delta's own prose")
        XCTAssertEqual(harness.recordedFacts.map(\.fact),
                       ["Kelly is at the dock by dawn."],
                       "the run's candidates reach the ledger")
        XCTAssertEqual(
            harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." }).count,
            0,
            "…and never the pane: a fact is not a note")
    }

    /// **Cancel has to reach a run that has not sent anything yet.** The
    /// session's own `cancelCurrentRun` guards on having a turn, so against a
    /// run still deriving it is a silent no-op — the writer presses Cancel,
    /// nothing stops, and seconds later the run they cancelled spends a whole
    /// turn. The window was an instant before the derivation moved into it.
    func test_cancelDuringTheDerivationEndsTheRun() throws {
        let runner = SpyRunner()
        let gate = PrepareGate()
        let statement = statementWithARuling()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            statementText: statement, cachedWorld: nil,
            derivedWorld: readingOf(statement), holdDerivation: gate)

        harness.orchestrator.runRequested(docId: docId)
        settle()
        XCTAssertEqual(harness.orchestrator.runState, runningOnTheStandingReading)

        harness.orchestrator.cancel()
        XCTAssertEqual(harness.orchestrator.runState, .idle,
                       "Cancel is answered at the keystroke, not when the "
                       + "subprocess happens to finish")

        gate.release()
        settle()
        XCTAssertEqual(runner.sends.count, 0,
                       "the cancelled run must not go on to spend a turn")

        // And the orchestrator is still usable — Cancel ends a run, not the
        // session (`shutdown()` is the other verb).
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        settle()
        gate.release()
        awaitSends(1, on: runner)
        XCTAssertEqual(runner.sends.count, 1)
    }

    /// **A derivation is a subprocess, and the writer can switch Claude off
    /// while it runs.** The same defect the burst-flush hop has — a run
    /// acknowledged a moment before the toggle went off must not spawn the
    /// session the toggle was meant to prevent — arriving through the second
    /// suspension point this run now has.
    func test_shutdownDuringTheDerivationAbandonsTheRun() throws {
        let runner = SpyRunner()
        let gate = PrepareGate()
        let statement = statementWithARuling()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            statementText: statement, cachedWorld: nil,
            derivedWorld: readingOf(statement), holdDerivation: gate)

        harness.orchestrator.runRequested(docId: docId)
        settle()
        XCTAssertEqual(gate.entries, 1, "the run is deriving")

        harness.orchestrator.shutdown()
        gate.release()
        settle()

        XCTAssertEqual(runner.sends.count, 0,
                       "the abandoned run must not reach a session")
        XCTAssertEqual(harness.orchestrator.runState, .idle)
    }

    // MARK: - Production wiring (real store, real closures)

    /// A project on disk with one document linked to a plain research note
    /// and a palette card. `res-card`'s own file is deliberately never
    /// written — `test_productionPaletteListingReadsTheManifestNotTheFile`
    /// depends on that absence.
    private func makeListingsProjectRoot() throws -> URL {
        let root = try makeProjectRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("research/palette"), withIntermediateDirectories: true)
        try "Chapter prose.\n".write(
            to: root.appendingPathComponent("manuscript/ch1.md"),
            atomically: true, encoding: .utf8)
        try "The falls at night.\n".write(
            to: root.appendingPathComponent("research/the-falls-at-night.md"),
            atomically: true, encoding: .utf8)
        let card = ResearchItem(id: "res-card", title: "Act II fog", type: .asset,
                                kind: .document, path: "research/palette/act-ii-fog.md")
        let group = ResearchItem(id: "res-palette", title: "Palette", type: .group,
                                 path: PaletteConvention.folderPath,
                                 children: [card], role: .paletteGroup)
        let note = ResearchItem(id: "res-note", title: "The falls at night", type: .asset,
                                kind: .document, path: "research/the-falls-at-night.md")
        let chapter = StructureItem(id: "ch-1", title: "Chapter 1", type: .document,
                                    path: "manuscript/ch1.md",
                                    linkedResearchIds: ["res-note", "res-card"])
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [chapter], research: [group, note])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("project.maugham.json"))
        return root
    }

    private func makeProductionEnvironment(
        store: ProjectStore, documentStore: DocumentStore, root: URL,
        declaredWorld: DeclaredWorldStore? = nil, bible: BibleStore? = nil
    ) -> CompilerOrchestrator.Environment {
        let device = DeviceSlug.make(from: "test-mac")
        return CompilerOrchestrator.Environment.production(
            store: store, documentStore: documentStore, projectURL: root,
            declaredWorld: declaredWorld
                ?? DeclaredWorldStore(projectRoot: root, device: device),
            bible: bible ?? BibleStore(projectRoot: root, device: device),
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "CompilerListings-\(UUID())")!),
            onRunAcknowledged: { _ in })
    }

    /// Each pinned kind names the tool that fetches its full contents — a
    /// research note through `read_document`, a palette card through its own
    /// tool, because `CompilerPrompt`'s section header names only the first.
    func test_productionPinnedListingNamesTheFetchToolPerKind() async throws {
        let root = try makeListingsProjectRoot()
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        let environment = makeProductionEnvironment(
            store: store, documentStore: documentStore, root: root)

        let lines = environment.pinnedListing("ch-1")

        XCTAssertTrue(lines.contains("The falls at night (res-note) — read_document"),
                      "a plain research note fetches through read_document; got \(lines)")
        XCTAssertTrue(lines.contains("Act II fog (res-card) — read_palette_card"),
                      "a palette card is told apart by position, not id shape, and "
                      + "fetches through its own tool; got \(lines)")
    }

    /// **The regression this task's research caught.** `StructureItem.links`
    /// is `InspectorLinksSection`'s document-to-document backlink field —
    /// unrelated despite the name — and `ProjectStore.linkResearch` (the
    /// writer's actual "link this research to this document" action) never
    /// touches it; it writes `linkedResearchIds`. A fixture that sets only
    /// `.links` must pin nothing, proving the wiring reads the field
    /// production actually writes.
    func test_productionPinnedListingIgnoresTheUnrelatedLinksField() async throws {
        let root = try makeProjectRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "Prose.\n".write(
            to: root.appendingPathComponent("manuscript/ch1.md"),
            atomically: true, encoding: .utf8)
        try "Sarah.\n".write(
            to: root.appendingPathComponent("research/sarah.md"),
            atomically: true, encoding: .utf8)
        let sarah = ResearchItem(id: "res-sarah", title: "Sarah", type: .asset,
                                 kind: .document, path: "research/sarah.md")
        let chapter = StructureItem(id: "ch-1", title: "Chapter 1", type: .document,
                                    path: "manuscript/ch1.md", links: ["res-sarah"])
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [chapter], research: [sarah])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        let environment = makeProductionEnvironment(
            store: store, documentStore: documentStore, root: root)

        XCTAssertEqual(environment.pinnedListing("ch-1"), [],
                       "`.links` is not the research-linking field; only "
                       + "linkedResearchIds may pin")
    }

    /// The palette listing is sourced from the manifest index
    /// (`PaletteLookup.paletteCards`), not `ProjectStore.loadPaletteCards()`
    /// (`list_palette_cards`'s own path, which parses each card's markdown
    /// file). `res-card`'s file was never written by the fixture; a listing
    /// that read files would come back empty or throw.
    func test_productionPaletteListingReadsTheManifestNotTheFile() async throws {
        let root = try makeListingsProjectRoot()
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        let environment = makeProductionEnvironment(
            store: store, documentStore: documentStore, root: root)

        XCTAssertEqual(environment.paletteListing(), ["Act II fog (res-card)"])
    }

    /// The weak-capture discipline (`CompilerEnvironment+Project.swift`'s own
    /// stated reason): a window closed mid-run must answer empty, honestly,
    /// rather than crash on a deallocated store.
    func test_productionListingsAreEmptyOnceTheStoreIsGone() async throws {
        let root = try makeListingsProjectRoot()
        var store: ProjectStore? = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        let environment = makeProductionEnvironment(
            store: store!, documentStore: documentStore, root: root)

        store = nil

        XCTAssertEqual(environment.pinnedListing("ch-1"), [])
        XCTAssertEqual(environment.paletteListing(), [])
    }

    // MARK: - Production wiring: the declared world and the bible

    /// The briefing carries the statement WHOLE and the key its reading is
    /// cached under — and the key is `DeclaredWorldStore`'s own spelling, asked
    /// for rather than rebuilt. Two spellings mean two caches, and one of them
    /// is never hit: every run would re-derive, spawning a `claude` per
    /// keystroke against prose that has not moved.
    func test_productionIntentBriefsTheWholeStatementUnderItsCacheKey() async throws {
        let root = try makeListingsProjectRoot()
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        store.documentStore = documentStore
        let statement = try await store.createStatement(
            kind: .intent, scope: .document("ch-1"))
        try await store.appendToStatement(
            "Cold, and never wistful.", to: statement, session: "s")
        let environment = makeProductionEnvironment(
            store: store, documentStore: documentStore, root: root)

        let briefing = try XCTUnwrap(environment.intent("ch-1"))

        let resolved = try XCTUnwrap(store.effectiveIntent(forDocId: "ch-1"))
        XCTAssertEqual(briefing.statementText, try store.statementText(of: resolved),
                       "the run reads the statement through the one spelling every "
                       + "other reader uses")
        XCTAssertEqual(briefing.scopeKey, DeclaredWorldStore.scopeKey(for: resolved.scope),
                       "…and names its cache scope the way the cache does")
    }

    /// The cache's hash gate, reached through the production closure: a reading
    /// made from exactly this text is served, and one made from text that has
    /// since moved is not. Nothing here derives — the closure that spawns is
    /// the other one, deliberately.
    func test_productionServesOnlyAReadingMadeFromTheTextInHand() async throws {
        let root = try makeListingsProjectRoot()
        let device = DeviceSlug.make(from: "test-mac")
        let worlds = DeclaredWorldStore(projectRoot: root, device: device)
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        let environment = makeProductionEnvironment(
            store: store, documentStore: documentStore, root: root, declaredWorld: worlds)

        let statement = "Cold, and never wistful."
        worlds.store(
            DerivedWorld(
                sourceHash: DerivedWorld.sourceHash(of: statement),
                clauses: [DerivedClause(quote: statement, check: "No nostalgia.")],
                rules: [], derivedAt: Date()),
            forScopeKey: "doc-ch-1")

        XCTAssertEqual(
            environment.cachedWorld(
                CompilerOrchestrator.IntentBriefing(
                    statementText: statement, scopeKey: "doc-ch-1"))?.clauses.first?.check,
            "No nostalgia.")
        XCTAssertNil(
            environment.cachedWorld(
                CompilerOrchestrator.IntentBriefing(
                    statementText: statement + " Mostly.", scopeKey: "doc-ch-1")),
            "the writer edited the statement; the old reading is not of this text")
    }

    /// **A derivation that is not cached is a derivation paid for again on the
    /// next keystroke.** The lazy trigger only holds if the miss it answers
    /// stops being a miss, so the production closure stores what it derived —
    /// asserted by asking the cache afterwards, not by watching the closure.
    func test_productionCachesWhatItDerives() async throws {
        let root = try makeListingsProjectRoot()
        let device = DeviceSlug.make(from: "test-mac")
        let worlds = DeclaredWorldStore(projectRoot: root, device: device)
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        let statement = "Cold, and never wistful."
        let deriver = StubDeriver(
            answer: DerivedWorld(
                sourceHash: DerivedWorld.sourceHash(of: statement),
                clauses: [DerivedClause(quote: statement, check: "No nostalgia.")],
                rules: [], derivedAt: Date()))
        let environment = CompilerOrchestrator.Environment.production(
            store: store, documentStore: documentStore, projectURL: root,
            declaredWorld: worlds, bible: BibleStore(projectRoot: root, device: device),
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "CompilerDerive-\(UUID())")!),
            makeDeriver: { _ in deriver },
            onRunAcknowledged: { _ in })
        let briefing = CompilerOrchestrator.IntentBriefing(
            statementText: statement, scopeKey: "doc-ch-1")

        let derived = await environment.deriveWorld(briefing, "test-model")

        XCTAssertEqual(derived?.clauses.first?.check, "No nostalgia.")
        XCTAssertEqual(deriver.calls, 1)
        XCTAssertNotNil(environment.cachedWorld(briefing),
                        "the reading must be in the cache afterwards, or the next run "
                        + "spawns `claude` again over prose that has not moved")
        XCTAssertEqual(deriver.sawText, statement,
                       "the derivation reads the statement WHOLE — the rulings are "
                       + "half of what there is to derive")
    }

    /// A derivation that failed stores nothing: an absent entry is a miss the
    /// next run can retry, and there is no such thing as a cached failure.
    func test_productionCachesNothingWhenTheDerivationFails() async throws {
        let root = try makeListingsProjectRoot()
        let device = DeviceSlug.make(from: "test-mac")
        let worlds = DeclaredWorldStore(projectRoot: root, device: device)
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        let environment = CompilerOrchestrator.Environment.production(
            store: store, documentStore: documentStore, projectURL: root,
            declaredWorld: worlds, bible: BibleStore(projectRoot: root, device: device),
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "CompilerDerive-\(UUID())")!),
            makeDeriver: { _ in StubDeriver(answer: nil) },
            onRunAcknowledged: { _ in })
        let briefing = CompilerOrchestrator.IntentBriefing(
            statementText: "Cold.", scopeKey: "doc-ch-1")

        let derived = await environment.deriveWorld(briefing, "test-model")

        XCTAssertNil(derived)
        XCTAssertNil(environment.cachedWorld(briefing))
    }

    /// **The slice rule, stated where it is decided: a fact rides along when
    /// its SUBJECT's string occurs in the delta's prose, case-insensitively.**
    /// The spec's own words — "a run about Kelly's scene carries Kelly's facts,
    /// not the ledger" — and the cheapest rule that can be true of prose nobody
    /// has parsed for entities.
    func test_productionBibleSliceCarriesOnlyTheSubjectsTheDeltaMentions() async throws {
        let root = try makeListingsProjectRoot()
        let device = DeviceSlug.make(from: "test-mac")
        let bible = BibleStore(projectRoot: root, device: device)
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        bible.record([
            BibleFact(id: "f1", subject: "Kelly", fact: "Kelly has never seen the sea.",
                      establishedAt: nil, docId: "ch-1", recordedAt: Date()),
            BibleFact(id: "f2", subject: "Sarah", fact: "Sarah drives a green van.",
                      establishedAt: nil, docId: "ch-1", recordedAt: Date())
        ])
        let environment = makeProductionEnvironment(
            store: store, documentStore: documentStore, root: root, bible: bible)

        let sliced = environment.bibleSlice("the fog found kelly at the dock")

        XCTAssertEqual(sliced.map(\.subject), ["Kelly"],
                       "lower-cased prose still names Kelly; Sarah is not in this "
                       + "delta and her facts are not this run's business")
    }

    /// The other half of the ledger seam: what a run establishes is recorded.
    func test_productionRecordsTheRunsFactCandidates() async throws {
        let root = try makeListingsProjectRoot()
        let device = DeviceSlug.make(from: "test-mac")
        let bible = BibleStore(projectRoot: root, device: device)
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        let environment = makeProductionEnvironment(
            store: store, documentStore: documentStore, root: root, bible: bible)

        environment.recordFacts([
            BibleFact(id: "f1", subject: "Kelly", fact: "Kelly is at the dock by dawn.",
                      establishedAt: "a1b2", docId: "ch-1", recordedAt: Date())
        ])

        XCTAssertEqual(bible.allFacts().map(\.fact), ["Kelly is at the dock by dawn."])
    }

    /// A `WorldDeriver` that answers what the test says and counts its calls —
    /// the derivation's `SpyRunner`. Production's own deriver spawns a real
    /// `claude`, which no test may do.
    @MainActor
    private final class StubDeriver: WorldDeriver {
        private let answer: DerivedWorld?
        private(set) var calls = 0
        private(set) var sawText: String?

        init(answer: DerivedWorld?) { self.answer = answer }

        func derive(statementText: String) async -> DerivedWorld? {
            calls += 1
            sawText = statementText
            return answer
        }
    }

    // MARK: - The window the burst opens

    /// **The refusal covers the new window too.** Closing the burst is a disk
    /// write, so ⌘R now has a moment in which it has been acknowledged and has
    /// read nothing — and `runState` is honestly still idle throughout it. A
    /// second press landing there must be refused exactly as one mid-turn is,
    /// or an impatient double-⌘R spends two runs and hands the second a delta
    /// the first has already claimed.
    func test_asecondRunWhileTheBurstIsStillClosingIsRefused() throws {
        let runner = SpyRunner()
        let gate = PrepareGate()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            prepareForRun: { [gate] in await gate.hold($0) })

        harness.orchestrator.runRequested(docId: docId)
        settle()
        XCTAssertEqual(gate.entries, 1, "the run is closing the burst")
        XCTAssertEqual(harness.flashesSaid, [.started])

        harness.orchestrator.runRequested(docId: docId)
        settle()
        XCTAssertEqual(gate.entries, 1, "the second press must not start a second run")
        XCTAssertEqual(harness.flashesSaid, [.started, .alreadyChecking],
                       "…and is answered as one that started nothing. The window is "
                       + "short and `runState` is honestly still idle inside it, so "
                       + "without this the impatient second press of a double-⌘R is the "
                       + "one press in the whole flow that produces no reaction at all")

        gate.release()
        awaitSends(1, on: runner)
        XCTAssertEqual(runner.sends.count, 1)
    }

    /// **A run acknowledged a moment before the toggle went off must not spawn
    /// the session the toggle was meant to prevent.** `shutdown()` retires the
    /// session, and a run still closing its burst has none to retire — so
    /// without abandoning the hop by generation, the AI toggle going off (or
    /// the window closing) is followed by the very spawn it was there to stop.
    func test_shutdownDuringTheBurstAbandonsTheRun() throws {
        let runner = SpyRunner()
        let gate = PrepareGate()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            prepareForRun: { [gate] in await gate.hold($0) })

        harness.orchestrator.runRequested(docId: docId)
        settle()
        harness.orchestrator.shutdown()

        gate.release()
        settle()

        XCTAssertEqual(runner.sends.count, 0,
                       "the abandoned run must not reach a session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configURL.path),
                       "…nor write a session config, because no session was wanted")
        XCTAssertEqual(harness.orchestrator.runState, .idle)

        // And the orchestrator is still usable: a writer who turns Claude off
        // and on again has a working ⌘R (`shutdown()` vs `detach()`).
        harness.orchestrator.runRequested(docId: docId)
        settle()
        gate.release()
        awaitSends(1, on: runner)
        XCTAssertEqual(runner.sends.count, 1)
    }

    // MARK: - The wet ink

    private struct InjectedDiskError: Error {}

    /// A real project with a real open `Document`, driven through the
    /// **production** environment with only the subprocess replaced.
    ///
    /// The defect this section is about lives in the seam between the live
    /// document and the run — the burst that has not closed yet — so a harness
    /// whose `reading` is a canned value cannot see it at all. The two closures
    /// that matter here (`reading`, `prepareForRun`) are the ones production
    /// ships; `makeRunner` and `writeMCPConfig` are the only substitutions,
    /// because the first spawns a billing `claude` and the second writes a
    /// socket path.
    private struct LiveDocumentHarness {
        let orchestrator: CompilerOrchestrator
        let diagnostics: DiagnosticsStore
        let document: Document
        /// Held so the stores outlive the environment's weak captures.
        let store: ProjectStore
        let documentStore: DocumentStore
        /// The real derivation cache the run and `RulingPerformer` share — the
        /// two ends of the invalidation chain.
        let declaredWorld: DeclaredWorldStore
        let root: URL
    }

    private func makeLiveDocumentHarness(
        runner: SpyRunner, initialProse: String = "The fog came.\n",
        /// The one substitution beyond the subprocess itself: production would
        /// spawn a real, billing `claude -p` here.
        deriver: WorldDeriver? = nil
    ) async throws -> LiveDocumentHarness {
        let root = try makeProjectRoot()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let docPath = "manuscript/ch1.md"
        try initialProse.write(
            to: root.appendingPathComponent(docPath), atomically: true, encoding: .utf8)
        let chapter = StructureItem(id: "ch-1", title: "Chapter 1", type: .document,
                                    path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [chapter], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("project.maugham.json"))

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
        var environment = CompilerOrchestrator.Environment.production(
            store: store, documentStore: documentStore, projectURL: root,
            declaredWorld: declaredWorld, bible: BibleStore(projectRoot: root, device: device),
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "CompilerLiveDoc-\(UUID())")!),
            makeDeriver: deriver.map { stub in { _ in stub } },
            onRunAcknowledged: { _ in })
        environment.writeMCPConfig = {
            try Data("{}".utf8).write(to: configURL, options: .atomic)
            return configURL
        }
        environment.makeRunner = { _, _ in runner }
        let orchestrator = CompilerOrchestrator()
        orchestrator.configure(environment: environment, diagnostics: diagnostics)

        return LiveDocumentHarness(
            orchestrator: orchestrator, diagnostics: diagnostics, document: document,
            store: store, documentStore: documentStore, declaredWorld: declaredWorld,
            root: root)
    }

    /// **The run reads the present, not the last pause.** Freshly typed prose
    /// lives in the `PendingBuffer` until a pause closes the burst, so a writer
    /// who types a chunk and presses ⌘R immediately was handed a delta with
    /// none of it in — measured in the field as a 14-paragraph chunk reported
    /// as "0 new, 1 revised", the burst closing two seconds after the snapshot
    /// was taken. The wet ink is the compiler's whole subject (spec §3.2);
    /// a run that cannot see it inverts what the key is for.
    func test_theRunSeesProseTheWriterHasNotPausedAfter() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)

        // A run has already checked the standing paragraph, so the marker sits
        // at the bootstrap op. This is the field's own shape: everything before
        // the marker is checked, and everything the writer has typed since is
        // in the pending buffer.
        let bootstrapOpId = try XCTUnwrap(fx.document.opLogSnapshot.last?.opId)
        fx.diagnostics.replace(
            run: CompilerRun(id: "r0", at: Date(), model: "test-model",
                             lastOpId: bootstrapOpId,
                             deltaSummary: "1 new, 0 revised \u{00b6}", intentSnapshot: nil),
            diagnostics: [], docId: "ch-1")
        let opsBeforeTyping = fx.document.opLogSnapshot.count

        // The writer types, and reaches for ⌘R without pausing. Nothing closes
        // the burst: its debounce is 30s idle, and no other path has run.
        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")
        XCTAssertEqual(fx.document.opLogSnapshot.count, opsBeforeTyping,
                       "precondition: the new paragraph is still in the pending "
                       + "buffer, not the op log")

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await settle()

        let message = try XCTUnwrap(
            runner.sends.first?.message,
            "the run never reached the session at all: with the burst still open "
            + "the delta since the marker is empty, and ⌘R answers \"nothing "
            + "new\" to a writer who has just written a chunk")
        XCTAssertTrue(message.contains("It stayed for three days."),
                      "the run must carry the prose the writer had just typed — "
                      + "without closing the burst first, the delta is built "
                      + "against a document that predates it")
        let typedId = try XCTUnwrap(
            fx.document.sequence.first(where: { fx.document.paragraph(id: $0)?
                .contains("It stayed for three days.") == true }))
        XCTAssertTrue(message.contains("[\(typedId)] (new)"),
                      "…and carry it as NEW: it was minted since the marker, and "
                      + "'revised' would ask the model to compare it against a "
                      + "prior version that never existed")

        let burstOpId = try XCTUnwrap(fx.document.opLogSnapshot.last?.opId)
        XCTAssertEqual(fx.document.opLogSnapshot.count, opsBeforeTyping + 1,
                       "the run closed the burst rather than reading around it")
        XCTAssertEqual(fx.diagnostics.lastOpId(docId: "ch-1"), burstOpId,
                       "the marker advances past the burst this run read, or the "
                       + "next run re-reads the same paragraphs")
    }

    /// **A flush that fails does not cost the writer the run.** The op-log
    /// append can throw (a full disk, a revoked bookmark); the pending buffer
    /// survives it intact — `flushBurstNow` clears only after a successful
    /// append — so the words are not at risk and the next burst or `close()`
    /// carries them. What would be wrong is turning a run into a failure over
    /// it: a delta one burst stale still checks real prose, and no run at all
    /// checks nothing.
    ///
    /// Unlike the test above this one passes on either side of the fix — it
    /// guards the fix's error handling, not the defect. No marker is seeded, so
    /// `DeltaBuilder`'s first-run branch (which walks the LIVE paragraphs and
    /// consults no op) still yields a delta to run on; the marker branch, where
    /// the ops are what decide, is the one the test above is about.
    func test_aBurstFlushThatFailsStillRunsOnWhatItHas() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)

        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")
        fx.document.opStore.appendFailureForTesting = InjectedDiskError()

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await settle()

        XCTAssertEqual(runner.sends.count, 1,
                       "the run proceeds on the snapshot it has — a stale delta "
                       + "beats no run")
        XCTAssertEqual(fx.orchestrator.runState, .idle,
                       "a flush that failed is not the run failing; the surface "
                       + "must not wear a red line for it")

        // And the words were never at risk: `flushBurstNow` clears the buffer
        // only after a successful append, so the next flush still carries them.
        XCTAssertFalse(fx.document.pending.isEmpty(),
                       "the failed flush left the pending buffer intact")
        fx.document.opStore.appendFailureForTesting = nil
        try await fx.document.flushBurstNow()
        XCTAssertEqual(fx.document.opLogSnapshot.last?.changes
            .contains(where: { $0.next.contains("It stayed for three days.") }), true,
                       "the burst the run could not close lands on the next one")
    }

    // MARK: - The chain the atomic switch exists for

    /// A deriver that reads the statement the way the real one is asked to —
    /// **the rulings included** — and hands each back as a clause.
    ///
    /// Echoing rather than answering a canned world is the point: the test can
    /// then name the writer's ruled sentence in its assertions and know it got
    /// there by travelling the whole chain (ruling written → cache retired →
    /// re-derived → briefed), rather than because a fixture put it there.
    @MainActor
    private final class EchoRulingsDeriver: WorldDeriver {
        private(set) var calls = 0
        private(set) var sawTexts: [String] = []

        func derive(statementText: String) async -> DerivedWorld? {
            calls += 1
            sawTexts.append(statementText)
            let parsed = RulingsSection.parse(statementText)
            return DerivedWorld(
                sourceHash: DerivedWorld.sourceHash(of: statementText),
                clauses: parsed.rulings.map {
                    DerivedClause(quote: $0.text, check: Self.check)
                },
                rules: [], derivedAt: Date())
        }

        /// Distinct from anything the statement says, so an assertion on it
        /// cannot pass on raw prose leaking through — **and repeating none of
        /// the ruling's own words**, which the first draft of this fixture did:
        /// it built the check out of the ruled sentence, and the exact-once
        /// assertion below went red on the fixture rather than on the code. The
        /// count guard doing its job on its own author is the best evidence
        /// available that it is not decorative.
        static let check = "checkable, as the derivation reads it"
    }

    /// **The whole chain, driven once, with nothing faked but the two
    /// subprocesses.** A writer answers a note, the answer lands as a ruling on
    /// the real statement through the real `RulingPerformer`, and the NEXT run
    /// is briefed on it.
    ///
    /// Every link here was already pinned in isolation — `RulingPerformerTests`
    /// for the invalidation, `test_aCacheMissDerivesOnceAndBriefsTheReading`
    /// for derive-and-brief, `test_theBriefingIsSentOnceWhileTheSessionLives`
    /// for the elision — and that is exactly the arrangement this codebase has
    /// been bitten by: each half correct, the composition broken, nothing red.
    /// The load-bearing assertion is the NEGATIVE one — that run 2 is not
    /// elided — because eliding is what a run does when it believes nothing has
    /// changed, and a writer whose ruling is answered with "unchanged since
    /// last run" has declared something into a void with no symptom anywhere.
    func test_aRulingBetweenRunsReachesTheNextBriefing() async throws {
        let runner = SpyRunner()
        let deriver = EchoRulingsDeriver()
        let fx = try await makeLiveDocumentHarness(runner: runner, deriver: deriver)
        let statement = try await fx.store.createStatement(
            kind: .intent, scope: .document("ch-1"))
        try await fx.store.appendToStatement(
            "Cold, and never wistful.", to: statement, session: "seed")

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await settle()
        XCTAssertTrue(runner.sends[0].message.contains("Cold, and never wistful."),
                      "precondition: run 1 briefs the essay")
        XCTAssertEqual(deriver.calls, 1, "precondition: run 1 derived, on an empty cache")

        // The writer answers a note. This is `DiagnosticsPane.commitAnswer`'s
        // own call, with its own arguments — the run has no route into a
        // statement and must not grow one (the membrane, AREA.md).
        let ruled = "Kelly heard about the call offstage."
        try await RulingPerformer.rule(
            ruled, provenance: "answered a compiler note",
            forScope: .document("ch-1"), store: fx.store, world: fx.declaredWorld)

        // …and keeps writing, so run 2 has a delta of its own to check. Without
        // this the second ⌘R is "nothing new" and never reaches the session at
        // all — the run being asserted about would not exist.
        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(2, on: runner)
        await settle()

        let second = runner.sends[1].message
        XCTAssertFalse(second.contains("unchanged since last run"),
                       "the declared world MOVED, so the briefing must be re-embedded "
                       + "— an elided run tells the session nothing happened and the "
                       + "writer's ruling is checked by nobody")
        XCTAssertTrue(second.contains(EchoRulingsDeriver.check),
                      "the ruling reaches run 2 as its derived clause: the cache was "
                      + "retired, the statement re-derived, and the reading briefed")
        XCTAssertEqual(deriver.calls, 2,
                       "…and it was re-derived rather than served from the reading "
                       + "made before the ruling existed")
        XCTAssertEqual(deriver.sawTexts.last?.contains(ruled), true,
                       "…from the statement WITH the ruling in it — the derivation "
                       + "reads all of it, or a ruled decision is derived out of "
                       + "existence")

        // The atomic switch, holding through the real chain rather than a
        // fixture: the ruling is in the message as a clause and not as its own
        // prose, exactly once.
        XCTAssertFalse(second.contains(RulingsSection.heading))
        XCTAssertEqual(occurrences(of: ruled, in: second), 1,
                       "the writer's sentence appears once, in the clause. Twice is "
                       + "the whole-statement briefing back through a real ruling")
    }

    /// A turn that reads one fact off the delta — the same reading every time
    /// it is asked, which is what a manuscript that still establishes the fact
    /// produces. `refs` is empty on purpose: a fact with no anchor is valid
    /// (`DiagnosticIngest.resolveRefs`' own escape hatch) and the stratum
    /// captions it by its subject, which keeps this fixture about the loop
    /// rather than about excerpt resolution.
    private static let oneFactAboutKelly = """
        {"section":"conformance","checks":[]}
        {"section":"continuity","questions":[]}
        {"section":"reader","reports":[]}
        {"section":"facts","candidates":[{"subject":"Kelly","fact":"Kelly is a nurse.","refs":[]}]}
        """

    /// **The bible loop, across three runs, with a bless in the middle** — the
    /// composition nothing walked until now (`Maugham/Compiler/AREA.md`, "the
    /// third door": *"no test walks the bible loop across two runs at all"*).
    ///
    /// Production the whole way but the two subprocesses: the real orchestrator
    /// over a real project, the real `BibleStore`, the real `StatementPane`
    /// mounted in a window, and the writer's press delivered through the
    /// accessibility tree to the real `Bless` button.
    ///
    /// **Why three runs and not two.** The ledger is read at the START of a run
    /// (`bibleSlice`) and written at its END (`recordFacts`), so the run that
    /// re-emits a blessed fact is never the run that would brief it — the one
    /// after it is. Run 2 is where the suppression happens; run 3 is where the
    /// damage would have shown. Falsify by deleting `record`'s graduated guard:
    /// run 2's candidate returns to the register (assertions 3 and 4 go red)
    /// and run 3's message carries the same declaration twice, once as a bible
    /// fact and once as the ruling's derived clause (assertion 6).
    func test_theBibleLoopConvergesAcrossRunsWithABlessInTheMiddle() async throws {
        let fixture = try await StatementMountFixture.novel(named: "bible-loop")
        defer { fixture.tearDown() }
        let docId = fixture.documentItemId
        let device = DeviceSlug.make(from: "test-mac")
        let bible = BibleStore(projectRoot: fixture.projectURL, device: device)
        let declaredWorld = DeclaredWorldStore(projectRoot: fixture.projectURL, device: device)
        let diagnostics = DiagnosticsStore(projectRoot: fixture.projectURL, device: device)
        let runner = SpyRunner()
        let deriver = EchoRulingsDeriver()
        runner.nextEvent = .resultText(Self.oneFactAboutKelly)

        // The manuscript the run reads. `reading` resolves the OPEN document by
        // id, so the run has nothing to check until one is registered — the
        // pane's mount opens the statement, never the chapter.
        let item = try XCTUnwrap(
            fixture.store.manifest.structure.first(where: { $0.id == docId }))
        let path = try XCTUnwrap(item.path)
        let document = try await Document.load(
            url: fixture.projectURL.appendingPathComponent(path),
            device: "test-mac", session: "s", presenter: nil)
        fixture.documentStore.register(document: document, for: path)

        var environment = CompilerOrchestrator.Environment.production(
            store: fixture.store, documentStore: fixture.documentStore,
            projectURL: fixture.projectURL, declaredWorld: declaredWorld, bible: bible,
            preferences: fixture.preferences,
            makeDeriver: { _ in deriver },
            onRunAcknowledged: { _ in })
        environment.writeMCPConfig = {
            let url = fixture.projectURL.appendingPathComponent("compiler-mcp.json")
            try Data("{}".utf8).write(to: url, options: .atomic)
            return url
        }
        environment.makeRunner = { _, _ in runner }
        let orchestrator = CompilerOrchestrator()
        orchestrator.configure(environment: environment, diagnostics: diagnostics)
        defer { orchestrator.detach() }

        let window = await fixture.host(
            kind: .intent, subject: .item(docId), bible: bible, world: declaredWorld)

        // 1. Run 1 reads the fact off the writer's scene, and the mounted
        //    stratum shows it.
        document.setFullText("Kelly came off a double shift.")
        orchestrator.runRequested(docId: docId)
        await awaitSends(1, on: runner)
        await settle()
        await fixture.pumpUntil(deadline: 5) {
            fixture.shows("Kelly is a nurse.", in: window)
        }
        XCTAssertEqual(bible.allFacts().map(\.fact), ["Kelly is a nurse."],
                       "run 1's candidate never reached the ledger, so there is no "
                       + "fact on the pane to bless")
        let onScreenAfterRunOne = try fixture.staticTexts(
            in: window, containing: CanvasAccessibility.claudeTerm)
        XCTAssertFalse(
            onScreenAfterRunOne.isEmpty,
            "the fact never reached the mounted stratum \u{2014} there is no control "
            + "to press, and the assertion after run 2 would pass over an empty pane")

        // 2. The writer blesses it, through the button they press.
        try fixture.pressButton(labelled: "Bless", in: window)
        await fixture.pumpUntil(deadline: 5) { bible.allFacts().isEmpty }
        let ruled = "Kelly is a nurse."
        let statement = try XCTUnwrap(
            fixture.store.statement(kind: .intent, scope: .document(docId)),
            "the bless minted no statement, so nothing graduated and the rest of "
            + "this test is about a loop that never closed")
        XCTAssertEqual(
            RulingsStratum.rows(in: try fixture.store.statementText(of: statement)).map(\.text),
            [ruled])
        XCTAssertTrue(bible.allFacts().isEmpty, "the blessed fact stayed in the register")

        // 3. The writer revises the establishing scene; run 2 re-reads it and
        //    re-emits the identical fact. It must not come back.
        document.setFullText("Kelly came off a double shift.\n\nKelly took the long way home.")
        orchestrator.runRequested(docId: docId)
        await awaitSends(2, on: runner)
        await settle()
        await fixture.waitOut(0.4)

        XCTAssertTrue(
            bible.allFacts().isEmpty,
            "the blessed fact came back: run 2 re-established it and `record` had no "
            + "memory of the graduation, so the writer is asked to bless what they "
            + "have already ruled")
        let onScreenAfterRunTwo = try fixture.staticTexts(
            in: window, containing: CanvasAccessibility.claudeTerm)
        XCTAssertTrue(
            onScreenAfterRunTwo.isEmpty,
            "the provisional register put the blessed fact back on screen: "
            + onScreenAfterRunTwo.description)

        // 4. Run 2's own briefing: the ruling reaches the model as its derived
        //    clause, exactly once, and no bible section repeats it.
        let second = runner.sends[1].message
        XCTAssertFalse(second.contains("Established so far:"),
                       "the graduated fact was briefed as a reading as well as a ruling")
        XCTAssertTrue(second.contains(EchoRulingsDeriver.check),
                      "the blessed sentence did not reach run 2 as a clause at all, so "
                      + "the writer graduated it into a briefing that ignores it")
        XCTAssertEqual(occurrences(of: ruled, in: second), 1,
                       "the declaration is in the message twice \u{2014} the "
                       + "over-weighting the whole convergence exists to prevent")

        // 5. Run 3 is where a returned fact would have been briefed. With the
        //    ledger converged and the world unmoved there is nothing new to
        //    embed at all, and the run says so in one line.
        //
        //    **The new paragraph names Kelly on purpose.** The slice matches a
        //    subject against the DELTA's prose, not the document's, so prose
        //    about anyone else would leave a returned fact out of this briefing
        //    for a reason that has nothing to do with the graduation — and
        //    these assertions would pass with the door wide open. Measured:
        //    they did, on the red run, with "The fog came." here.
        document.setFullText(
            "Kelly came off a double shift.\n\nKelly took the long way home."
            + "\n\nKelly did not come back for three days.")
        orchestrator.runRequested(docId: docId)
        await awaitSends(3, on: runner)
        await settle()

        let third = runner.sends[2].message
        XCTAssertFalse(third.contains("Established so far:"),
                       "the returned fact reached the briefing a run later")
        XCTAssertEqual(
            occurrences(of: ruled, in: third), 0,
            "with nothing recorded and nothing ruled since run 2, the declared block "
            + "is elided in one line \u{2014} a message carrying the sentence at all "
            + "means the ledger moved, and one carrying it twice is the third door "
            + "standing open")
        XCTAssertTrue(third.contains("unchanged since last run"),
                      "…and the elision is what says the ledger converged rather than "
                      + "the assertion above passing on a message with no world in it")
        XCTAssertEqual(deriver.calls, 1,
                       "the statement did not move between runs 2 and 3, so the "
                       + "reading made for run 2 is the one run 3 is elided against")
    }

    // MARK: - Teardown

    /// Releasing the window releases the session AND the closures that hold the
    /// project's stores. `.onDisappear` scorches `ProjectWindow`'s heavy state
    /// precisely because SwiftUI never dismantles a closed window's view graph;
    /// an orchestrator still holding a `ProjectStore` keeps the whole thing
    /// alive in the husk.
    func test_detachEndsTheSessionAndReleasesTheEnvironment() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        harness.orchestrator.detach()
        XCTAssertEqual(runner.shutdowns, 1)

        harness.orchestrator.runRequested(docId: docId)
        settle()
        XCTAssertEqual(runner.sends.count, 1,
                       "a detached orchestrator runs nothing — it has no window")
    }

    /// Shutting the session down mid-run leaves the surface idle rather than
    /// stuck on "running" forever.
    func test_shutdownMidRunClearsTheRunningState() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        XCTAssertEqual(harness.orchestrator.runState, runningOnTheStandingReading)

        harness.orchestrator.shutdown()
        settle()
        XCTAssertEqual(harness.orchestrator.runState, .idle)
    }

    /// A failure the writer has not seen yet survives a shutdown — the toggle
    /// going off must not erase the banner that says why the last run failed.
    func test_shutdownDoesNotClearAReportedFailure() throws {
        let runner = SpyRunner()
        runner.nextEvent = .failed(.cliNotFound)
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        harness.orchestrator.shutdown()

        guard case .failed(_, let failure, _) = harness.orchestrator.runState else {
            return XCTFail("the failure was erased by an unrelated teardown")
        }
        XCTAssertEqual(failure, .cliNotFound)
    }

    // MARK: - Streaming (Task 4)

    /// One conformance section, as a line the model would write.
    private func conformanceLine(
        _ quote: String, _ status: String, whatPulls: String? = nil,
        about paragraphId: String = "a1b2"
    ) -> String {
        let pulls = whatPulls.map { ",\"what_pulls\":\"\($0)\"" } ?? ""
        return "{\"section\":\"conformance\",\"checks\":[{\"clause_quote\":\"\(quote)\","
            + "\"status\":\"\(status)\",\"refs\":[\"\(paragraphId)\"]\(pulls)}]}"
    }

    /// Start a run and hold its turn open, with the stream armed.
    private func streamingRun(
        runner: SpyRunner, harness: Harness
    ) {
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
    }

    /// **A section renders while the rest of the turn is still generating** —
    /// the whole of the task, in one assertion.
    ///
    /// Conformance is the first section the schema asks for and the one the
    /// pane leads with, so it is the one that earns the streaming: the writer
    /// reads their own clauses back within seconds of pressing ⌘R rather than
    /// after two minutes of "Checking…".
    func test_sectionsRenderWhileTheTurnIsStillGenerating() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil   // the turn stays open
        let harness = try makeHarness(runner: runner, reading: standingReading())
        streamingRun(runner: runner, harness: harness)

        XCTAssertNil(harness.diagnostics.lastRun(docId: docId),
                     "nothing may be on the pane before a section closes")

        runner.stream(conformanceLine("Cold, and never wistful.", "strains",
                                      whatPulls: "The last line reaches for a sigh.") + "\n")

        let clauses = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId)?.clauseStatuses)
        XCTAssertEqual(clauses.map(\.clauseQuote), ["Cold, and never wistful."],
                       "the conformance summary should be readable mid-turn")
        let notes = harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." })
        XCTAssertEqual(notes.map(\.body), ["The last line reaches for a sigh."])
        XCTAssertEqual(harness.orchestrator.runState, runningOnTheStandingReading,
                       "a preview must not end the run")

        runner.release(.resultText(Self.fourEmptySections))
        settle()
    }

    /// **A chunk is not a line.** The transport cuts wherever it likes — a
    /// section's JSON object routinely arrives in pieces — so nothing may be
    /// read until a newline says the line is whole. A parser fed the fragments
    /// would see unbalanced JSON and, worse, could see a `}` land early and
    /// read a truncated section as a complete one.
    func test_aSectionIsNotReadUntilItsLineCloses() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())
        streamingRun(runner: runner, harness: harness)

        let line = conformanceLine("Cold, and never wistful.", "holds")
        let cut = line.index(line.startIndex, offsetBy: 30)
        runner.stream(String(line[line.startIndex..<cut]))
        XCTAssertNil(harness.diagnostics.lastRun(docId: docId),
                     "half a section is not a section")

        runner.stream(String(line[cut...]))
        XCTAssertNil(harness.diagnostics.lastRun(docId: docId),
                     "the line has not closed — its newline has not arrived")

        runner.stream("\n")
        XCTAssertEqual(
            harness.diagnostics.lastRun(docId: docId)?.clauseStatuses?.count, 1,
            "the closed line should have been read")

        runner.release(.resultText(Self.fourEmptySections))
        settle()
    }

    /// **The result is the truth, and it REPLACES the preview** — the contract
    /// that keeps one source of truth at the end of a turn.
    ///
    /// The sharp case is a section that appears in both: streamed once, and
    /// present again in the turn's own text, which is where it always was.
    /// Accumulate instead of reconcile and the writer reads the same finding
    /// twice, with the duplicate persisted.
    func test_theFinalResultReconcilesTheStream() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())
        streamingRun(runner: runner, harness: harness)

        let conformance = conformanceLine(
            "Cold, and never wistful.", "strains", whatPulls: "The last line reaches for a sigh.")
        runner.stream(conformance + "\n")
        XCTAssertEqual(
            harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." }).count, 1)

        // The turn's own text — the same conformance section, plus the three
        // that never got their newline out.
        runner.release(.resultText("""
            \(conformance)
            {"section":"continuity","questions":[]}
            {"section":"reader","reports":[]}
            {"section":"facts","candidates":[]}
            """))
        settle()

        let notes = harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." })
        XCTAssertEqual(notes.map(\.body), ["The last line reaches for a sigh."],
                       "the streamed section must be replaced by the result, not added to it")
        XCTAssertEqual(harness.diagnostics.lastRun(docId: docId)?.clauseStatuses?.count, 1,
                       "one clause was checked; the summary must say so once")
        XCTAssertEqual(harness.orchestrator.runState, .idle)
    }

    /// **A run that never finished leaves nothing behind.** The writer pressed
    /// Cancel; what was on the pane came from a check that stopped half way,
    /// and the answer that stood before it is the honest thing to show.
    func test_aCancelMidStreamLeavesNoHalfReport() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())
        streamingRun(runner: runner, harness: harness)

        runner.stream(conformanceLine("Cold, and never wistful.", "strains",
                                      whatPulls: "The last line reaches for a sigh.") + "\n")
        XCTAssertNotNil(harness.diagnostics.lastRun(docId: docId))

        harness.orchestrator.cancel()
        settle()

        XCTAssertNil(harness.diagnostics.lastRun(docId: docId),
                     "the half-report survived a cancel")
        XCTAssertEqual(
            harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." }), [])
        XCTAssertEqual(harness.orchestrator.runState, .idle)
    }

    /// The same, through the toggle: Claude switched off mid-check takes the
    /// half-report with it.
    func test_aToggleOffMidStreamLeavesNoHalfReport() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())
        streamingRun(runner: runner, harness: harness)

        runner.stream(conformanceLine("Cold, and never wistful.", "holds") + "\n")
        XCTAssertNotNil(harness.diagnostics.lastRun(docId: docId))

        harness.orchestrator.shutdown()
        settle()

        XCTAssertNil(harness.diagnostics.lastRun(docId: docId),
                     "the half-report survived the toggle going off")
    }

    /// **A cancelled preview restores the run that DID finish** — the case a
    /// blanket "clear the doc" discard would get wrong, because the sidecar it
    /// re-reads is the previous run's and was never overwritten.
    func test_aCancelledPreviewPutsTheLastFinishedRunBack() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(
            oneQuestion("Should she already know?", about: "a1b2"))
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        let finished = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))

        // A second run, streamed and then cancelled.
        runner.nextEvent = nil
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        runner.stream(conformanceLine("Cold, and never wistful.", "strains",
                                      whatPulls: "Something else entirely.") + "\n")
        harness.orchestrator.cancel()
        settle()

        XCTAssertEqual(harness.diagnostics.lastRun(docId: docId)?.id, finished.id,
                       "the run that finished should be back on the pane")
        XCTAssertEqual(
            harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." })
                .map(\.body),
            ["Should she already know?"])
    }

    /// **The sharpest assertion of "a preview never persists": a dismissal
    /// aimed at one changes not a byte** (C1, scenario A).
    ///
    /// `dismiss` is the store's third writer and the only one older than
    /// streaming — it was written when every note it could reach belonged to a
    /// run that had finished, and it persists. Against a preview it wrote the
    /// half-report to the sidecar as the standing answer, carrying the marker
    /// `beginRun` mints BEFORE the send; the cancel below then read it back and
    /// the next check would have started from a position this run never
    /// reached, silently never re-reading the prose it stopped half way
    /// through.
    ///
    /// Byte-comparison rather than a field-by-field one: the defect was a WRITE
    /// that should not have happened, and the only assertion that cannot be
    /// satisfied by a write that merely round-trips is "the file did not
    /// change".
    func test_aDismissalCannotReachAPreview_soTheSidecarSurvivesACancelByteIdentical() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(
            oneQuestion("Should she already know?", about: "a1b2"))
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        let sidecar = DiagnosticsStore.sidecarURL(
            projectRoot: harness.root, docId: docId,
            device: DeviceSlug.make(from: "test-mac"))
        let before = try Data(contentsOf: sidecar) // adr-0018-ok: diagnostics sidecar, derived, not manuscript
        XCTAssertEqual(harness.diagnostics.lastOpId(docId: docId), "op1",
                       "control: the finished run's marker")

        // A second run, held open, one section in.
        runner.nextEvent = nil
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        runner.stream(conformanceLine("Cold, and never wistful.", "strains",
                                      whatPulls: "The last line reaches for a sigh.") + "\n")
        let previewed = harness.diagnostics.live(
            docId: docId, currentText: { _ in "The fog came." })
        XCTAssertEqual(previewed.count, 1, "control: the preview put a note on the pane")

        harness.diagnostics.dismiss(try XCTUnwrap(previewed.first).id, docId: docId)

        XCTAssertEqual(
            try Data(contentsOf: sidecar), before, // adr-0018-ok: diagnostics sidecar, derived, not manuscript
            "dismissing a previewed note wrote the half-report to disk")
        XCTAssertEqual(
            harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." }).count, 1,
            "the refusal is total \u{2014} a preview's notes are not the writer's to "
            + "dismiss, because the run raising them has not finished")

        harness.orchestrator.cancel()
        settle()

        XCTAssertEqual(
            try Data(contentsOf: sidecar), before, // adr-0018-ok: diagnostics sidecar, derived, not manuscript
            "the cancelled run left something behind")
        XCTAssertEqual(harness.diagnostics.lastOpId(docId: docId), "op1",
                       "a run that produced nothing checked nothing \u{2014} advancing the "
                       + "marker would tell the next run that op2's prose was read")
        XCTAssertEqual(
            harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." })
                .map(\.body),
            ["Should she already know?"],
            "the run that finished should be back on the pane")
    }

    /// **The other arm of C1: a completed turn raises each note once, and the
    /// dismissal that was refused mid-stream lands for real afterwards.**
    ///
    /// `finish` reconciles with `parseAll` over the whole turn and REPLACES —
    /// and the turn's own text still contains the section the stream carried.
    /// A dismissal that took mid-stream therefore bought nothing: the note came
    /// straight back with a fresh id, indistinguishable from an unanswered one,
    /// and a second answer minted a duplicate ruling. Refused mid-stream, there
    /// is exactly one note to answer and answering it sticks.
    func test_aNoteRefusedMidStreamIsRaisedOnceByTheFinishedRun_andDismissesForReal() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())
        streamingRun(runner: runner, harness: harness)

        let question = oneQuestion("Should she already know?", about: "a1b2")
            .components(separatedBy: "\n")[1]
        runner.stream(question + "\n")
        let previewed = harness.diagnostics.live(
            docId: docId, currentText: { _ in "The fog came." })
        harness.diagnostics.dismiss(try XCTUnwrap(previewed.first).id, docId: docId)

        // This document has never had a run finish, so there is no sidecar at
        // all — the sharpest form of "a preview never persists", and the arm
        // that catches an un-gated `dismiss`, which would MINT the file here
        // out of a half-report.
        let sidecar = DiagnosticsStore.sidecarURL(
            projectRoot: harness.root, docId: docId,
            device: DeviceSlug.make(from: "test-mac"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sidecar.path),
            "a dismissal against a preview wrote a sidecar for a run that has not "
            + "finished \u{2014} a relaunch would read the half-report as the answer")

        runner.release(.resultText(oneQuestion("Should she already know?", about: "a1b2")))
        settle()

        let reconciled = harness.diagnostics.live(
            docId: docId, currentText: { _ in "The fog came." })
        XCTAssertEqual(reconciled.map(\.body), ["Should she already know?"],
                       "the finished run raises the question exactly once")

        harness.diagnostics.dismiss(try XCTUnwrap(reconciled.first).id, docId: docId)
        XCTAssertEqual(
            harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." }), [],
            "the run has finished \u{2014} its notes are the writer's to answer")

        let persisted = try XCTUnwrap(String(
            data: try Data(contentsOf: sidecar), encoding: .utf8)) // adr-0018-ok: diagnostics sidecar, derived, not manuscript
        XCTAssertFalse(persisted.contains("Should she already know?"),
                       "and the dismissal reached disk, so the note cannot come back "
                       + "on the next launch to be answered twice")
    }

    /// **A preview is not a run, and the drift ring must not count it as one.**
    ///
    /// `DriftDetector` reads a clause straining across CONSECUTIVE RUNS. A
    /// preview appending a snapshot per section would let a single ⌘R
    /// contribute several, and three sections of one check would announce a
    /// drift the writer's prose never had.
    func test_aPreviewNeverEntersTheDriftRing() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())
        streamingRun(runner: runner, harness: harness)

        let strain = conformanceLine("Cold, and never wistful.", "strains",
                                     whatPulls: "The last line reaches for a sigh.")
        runner.stream(strain + "\n")
        runner.stream(strain + "\n")
        runner.stream(strain + "\n")
        XCTAssertEqual(harness.diagnostics.clauseStatusHistory(docId: docId).count, 0,
                       "a preview must not touch the ring at all")

        runner.release(.resultText("""
            \(strain)
            {"section":"continuity","questions":[]}
            {"section":"reader","reports":[]}
            {"section":"facts","candidates":[]}
            """))
        settle()

        XCTAssertEqual(harness.diagnostics.clauseStatusHistory(docId: docId).count, 1,
                       "one run is one entry in the ring, however many sections streamed")
    }

    /// **A preview is not a round either.** The round ring records rounds that
    /// FINISHED: one ⌘R is one entry, however many sections streamed under it,
    /// and the entry is the run the finished one superseded — never the
    /// half-report the same run put on the pane on its way there.
    ///
    /// Two runs, because the ring holds the OUTGOING run: a cold document's
    /// first replace has nothing to remember. Falsification: append to the ring
    /// from `preview` and this reads two.
    func test_aPreviewNeverEntersTheRoundRing() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(
            oneQuestion("Should she already know?", about: "a1b2"))
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        let finished = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(harness.diagnostics.roundHistory(docId: docId), [],
                       "control: the first run has no prior round to remember")

        // A second run, streamed section by section, then finished.
        runner.nextEvent = nil
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        let strain = conformanceLine("Cold, and never wistful.", "strains",
                                     whatPulls: "The last line reaches for a sigh.")
        runner.stream(strain + "\n")
        runner.stream(strain + "\n")
        XCTAssertEqual(harness.diagnostics.roundHistory(docId: docId), [],
                       "a preview must not touch the ring at all")

        runner.release(.resultText("""
            \(strain)
            {"section":"continuity","questions":[]}
            {"section":"reader","reports":[]}
            {"section":"facts","candidates":[]}
            """))
        settle()

        let history = harness.diagnostics.roundHistory(docId: docId)
        XCTAssertEqual(history.count, 1,
                       "one run is one entry in the ring, however many sections streamed")
        XCTAssertEqual(history.first?.runId, finished.id,
                       "and the entry is the run that FINISHED before this one — not "
                       + "this run's own half-report, which would compare a round "
                       + "against itself")
        XCTAssertEqual(history.first?.fingerprints.count, 1,
                       "carrying what run 1 raised")
    }

    /// **A preview is never written to disk.** A half-report in the sidecar
    /// would be read back on the next launch as the standing answer, and
    /// nothing on the pane would distinguish it from a check that finished.
    func test_aPreviewIsNotPersisted() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())
        streamingRun(runner: runner, harness: harness)

        runner.stream(conformanceLine("Cold, and never wistful.", "strains",
                                      whatPulls: "The last line reaches for a sigh.") + "\n")
        XCTAssertNotNil(harness.diagnostics.lastRun(docId: docId), "it is on the pane")

        // A second store over the same project reads only what is on disk.
        let onDisk = DiagnosticsStore(
            projectRoot: harness.root, device: DeviceSlug.make(from: "test-mac"))
        onDisk.load(docId: docId)
        XCTAssertNil(onDisk.lastRun(docId: docId),
                     "the preview reached the sidecar")

        runner.release(.resultText(Self.fourEmptySections))
        settle()

        onDisk.load(docId: docId)
        XCTAssertNotNil(onDisk.lastRun(docId: docId),
                        "the finished run must persist as it always did")
    }

    /// A superseded run's late chunks touch nothing. The orchestrator's own
    /// generation guard, distinct from the session's: the session drops a
    /// retired PROCESS's deltas, and this drops a retired RUN's — a shutdown
    /// abandons the run without the runner ever being asked to stop.
    func test_lateChunksFromAnAbandonedRunAreIgnored() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())
        streamingRun(runner: runner, harness: harness)

        harness.orchestrator.shutdown()
        settle()

        runner.stream(conformanceLine("Cold, and never wistful.", "strains",
                                      whatPulls: "The last line reaches for a sigh.") + "\n")

        XCTAssertNil(harness.diagnostics.lastRun(docId: docId),
                     "an abandoned run's chunk reached the pane")
    }

    /// Prose, fences and anything else the model puts around its sections read
    /// as nothing — `parseSection`'s own tolerance, exercised on the path
    /// where a non-section line arrives on its own rather than inside a turn.
    func test_narrationBetweenSectionsIsNotASection() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())
        streamingRun(runner: runner, harness: harness)

        runner.stream("Here is what I found.\n```json\n")
        XCTAssertNil(harness.diagnostics.lastRun(docId: docId))

        runner.release(.resultText(Self.fourEmptySections))
        settle()
    }
}
