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

    /// One conformance strain against `paragraphId` — the smallest turn that
    /// produces a note the SIDECAR keeps. As of M4 P1 it is the only kind that
    /// stays there: a continuity question and a reader's report leave for the
    /// annotation layer, so a test about what the store holds is a test about a
    /// strain.
    private func oneStrain(
        _ whatPulls: String, about paragraphId: String,
        quote: String = "Cold, and never wistful."
    ) -> String {
        """
        {"section":"conformance","checks":[{"clause_quote":"\(quote)","status":"strains","refs":["\(paragraphId)"],"what_pulls":"\(whatPulls)"}]}
        {"section":"continuity","questions":[]}
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

    /// A third paragraph, for the tests that need three runs — a lane that is
    /// left and then returned to needs one ⌘R per lane change, and every run
    /// after the first needs prose the marker has not seen.
    private func readingAfterAThirdParagraph() -> CompilerOrchestrator.DocumentReading {
        CompilerOrchestrator.DocumentReading(
            ops: [makeOp(opId: "op1", kind: .bootstrap,
                         changes: [.init(paragraphId: "a1b2", prior: nil, next: "The fog came.")]),
                  makeOp(opId: "op2",
                         changes: [.init(paragraphId: "c3d4", prior: nil, next: "It stayed.")]),
                  makeOp(opId: "op3",
                         changes: [.init(paragraphId: "e5f6", prior: nil, next: "Then it lifted.")])],
            paragraphs: ["a1b2": "The fog came.", "c3d4": "It stayed.",
                         "e5f6": "Then it lifted."],
            sequence: ["a1b2", "c3d4", "e5f6"])
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
        /// The pass the writer has active on the piece — the round's lane.
        /// Settable because the sharp case is a pass that changes DURING a run
        /// (`test_thePreviewAndTheFinishedRunAgreeOnTheRound`).
        let setActivePass: (String?) -> Void
        /// How many times the run reached for a fresh derivation — the lazy
        /// trigger's own counter (`AREA.md`, "the derivation trigger").
        var derivations: Int { derivationCount() }
        let derivationCount: () -> Int
        /// What the run handed the bible ledger.
        var recordedFacts: [BibleFact] { factsRecorded() }
        let factsRecorded: () -> [BibleFact]
        /// **What the run asked the annotation layer to mint** (M4 P1 Task 3),
        /// with the context it minted under — recorded rather than counted,
        /// because the whole subject is WHICH findings leave the sidecar and
        /// what they are stamped with. One entry per finished run that had
        /// anything to mint.
        var mints: [(notes: [CompilerNote], context: CompilerMintContext)] { minted() }
        let minted: () -> [(notes: [CompilerNote], context: CompilerMintContext)]
        /// The delta prose the bible slice was asked about.
        var sliceQueries: [String] { slicesAsked() }
        let slicesAsked: () -> [String]
        /// How many times the orchestrator asked for a NEW session — the only
        /// thing on this side of the seam that can tell "the warm process
        /// answered again" from "it was retired and one was spawned in its
        /// place", since `makeRunner` hands back the same spy either way.
        var spawns: Int { runnerSpawns() }
        let runnerSpawns: () -> Int
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
        /// The project's lessons ledger, whole — the markdown
        /// `Environment.lessons` answers. `nil`, the default, is a project
        /// whose writer has kept no lesson yet, which is what every test
        /// written before the ledger existed was reading.
        lessons: String? = nil,
        /// The review pass active on the piece when a run starts. `nil` — the
        /// default, and every pre-P3 test's world — is the passless lane.
        activePass: String? = nil,
        /// The project's type, as `Environment.projectType` answers it — what
        /// the letter's scene position is derived from (spec §3.4). `nil` — the
        /// default, and every test written before the position existed — reads
        /// as prose, which is what those runs were.
        projectType: ProjectType? = nil,
        liveParagraphText: @escaping (String, String) -> String? = { _, _ in "The fog came." },
        pinnedListing: @escaping (String) -> [String] = { _ in [] },
        paletteListing: @escaping () -> [String] = { [] },
        prepareForRun: @escaping @MainActor (String) async -> Void = { _ in },
        /// Holds the derivation open, the way `prepareForRun`'s gate holds the
        /// burst — a real window in production, the length of a subprocess.
        holdDerivation: PrepareGate? = nil,
        /// Holds the MINT open — `finish`'s one suspension, and the only one
        /// this class resumes from with writes still to do (M4 P1 review,
        /// Minor 6).
        holdMint: PrepareGate? = nil
    ) throws -> Harness {
        let root = try makeProjectRoot()
        let diagnostics = DiagnosticsStore(
            projectRoot: root, device: DeviceSlug.make(from: "test-mac"))
        let configURL = root.appendingPathComponent("compiler-mcp.json")
        let flashes = Box<[CompilerOrchestrator.Acknowledgment]>([])
        let live = Box(reading)
        let derivations = Box(0)
        let recorded = Box<[BibleFact]>([])
        let mints = Box<[(notes: [CompilerNote], context: CompilerMintContext)]>([])
        let slices = Box<[String]>([])
        let pass = Box(activePass)
        let spawns = Box(0)
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
                lessons: { lessons },
                activePass: { id in id == self.docId ? Self.lane(pass.value) : nil },
                projectType: { _ in projectType },
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
                mintAnnotations: { notes, context in
                    mints.value.append((notes, context))
                    if let holdMint { await holdMint.hold("") }
                    // No document behind this harness, so there is no queue to
                    // dedupe against: every note is minted and none of them
                    // matched anything standing in another lane. The cross-lane
                    // count has its own harness (`makeLiveDocumentHarness`),
                    // which runs the production closure.
                    return CompilerOrchestrator.MintOutcome(
                        minted: notes.count, openInOtherLanes: 0)
                },
                recordFacts: { recorded.value += $0 },
                pinnedListing: pinnedListing,
                paletteListing: paletteListing,
                writeMCPConfig: {
                    try Data("{}".utf8).write(to: configURL, options: .atomic)
                    return configURL
                },
                makeRunner: { _, _ in
                    spawns.value += 1
                    return runner
                },
                onRunAcknowledged: { flashes.value.append($0) }),
            diagnostics: diagnostics)
        return Harness(orchestrator: orchestrator, diagnostics: diagnostics,
                       root: root, configURL: configURL,
                       acknowledgments: { flashes.value },
                       setReading: { live.value = $0 },
                       setActivePass: { pass.value = $0 },
                       derivationCount: { derivations.value },
                       factsRecorded: { recorded.value },
                       minted: { mints.value },
                       slicesAsked: { slices.value },
                       runnerSpawns: { spawns.value })
    }

    /// A pass id, as the lane the run resolves it to — through
    /// `ReviewPass.presets` and `effectiveEditorName`/`effectiveBrief`, which
    /// is what production does. Spelled once here so a test naming "copyedit"
    /// gets Gould without restating the resolution.
    static func lane(_ passId: String?) -> CompilerOrchestrator.ActivePass? {
        guard let passId else { return nil }
        let pass = ReviewPass.presets.first { $0.id == passId }
            ?? ReviewPass(id: passId, name: passId)
        return CompilerOrchestrator.ActivePass(
            id: pass.id, name: pass.name, editorName: pass.effectiveEditorName,
            brief: pass.effectiveBrief)
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
            oneStrain("Two beats, not three?", about: "a1b2"))
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

    /// **One turn, two destinations** (M4 P1 Task 3) — the routing split, at
    /// the seam where a run's answer is disposed of.
    ///
    /// The conformance strain stays in the sidecar, where it is read beside the
    /// clause it strains against. The continuity question and the reader's
    /// report leave for the annotation layer, in the contract's own order, and
    /// the store never sees either. This test used to assert all three landed
    /// in the store in that order; the ordering claim survives — it is just the
    /// mint that now has to keep it.
    func test_oneTurnSplitsBetweenTheSidecarAndTheMint() throws {
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
        XCTAssertEqual(notes.map(\.kind), [.conformanceStrain],
                       "the sidecar keeps the strain and only the strain \u{2014} "
                       + "a question in both homes is a question the writer is "
                       + "asked to answer twice")
        XCTAssertEqual(
            harness.diagnostics.lastRun(docId: docId)?.clauseStatuses?.map(\.status),
            ["strains"],
            "…and the summary the pane leads with rides on the run record")

        let mint = try XCTUnwrap(harness.mints.first, "nothing was routed to the mint")
        XCTAssertEqual(mint.notes.map(\.kind), [.query, .comment],
                       "continuity then the reader \u{2014} the contract's own "
                       + "order, now kept by the mint")
        XCTAssertEqual(mint.notes.map(\.body),
                       ["Has anyone said how long yet?",
                        "Belief \u{2014} The reader believes the fog is a person."])
        XCTAssertEqual(mint.notes.compactMap(\.paragraphId), ["a1b2", "a1b2"],
                       "anchored whole-paragraph at the first resolving ref")
        XCTAssertEqual(mint.context.runId, harness.diagnostics.lastRun(docId: docId)?.id,
                       "the notes and the report name the same check")
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
        /// The PRODUCTION environment the orchestrator was configured with, so
        /// a test can drive one of its closures (the mint) directly where the
        /// run cannot yet reach it.
        let environment: CompilerOrchestrator.Environment
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
            orchestrator: orchestrator, environment: environment,
            diagnostics: diagnostics, document: document,
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
            kind: .intent, forScope: .document("ch-1"), store: fx.store, world: fx.declaredWorld)

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

    /// **The enriched provenance survives the real chain too** (M4 P1 Task 6):
    /// answering a strain through `DiagnosticsPane.commitAnswer` — the real
    /// pane function, which mints the enriched `«excerpt»` provenance rather
    /// than the bare legacy string `RulingPerformer.rule` is called with
    /// directly above — writes a ruling whose text is exactly the writer's
    /// sentence, and that sentence still reaches run 2's briefing as its
    /// derived clause, unmangled. If the excerpt's em-dash sanitation ever
    /// broke, `RulingsSection.parseItem` would split the item on the wrong
    /// "—" and the deriver would echo a corrupted quote instead of the one
    /// asserted here.
    func test_theEnrichedProvenanceReachesTheNextRunsBriefingUnbroken() async throws {
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
        XCTAssertEqual(deriver.calls, 1, "precondition: run 1 derived, on an empty cache")

        // A strain carrying a clause quote — the answerable kind post-Task-3,
        // and the only one `answeredNoteProvenance` enriches.
        let note = Diagnostic(
            id: ULID.generate(), docId: "ch-1", anchor: nil,
            body: "Does this hold?", category: nil, runId: ULID.generate(),
            kind: .conformanceStrain, refs: nil,
            clauseQuote: "the dread stays unnamed")
        fx.diagnostics.replace(
            run: CompilerRun(id: "r0", at: Date(), model: "test-model", lastOpId: nil,
                             deltaSummary: "0 new, 0 revised \u{00b6}", intentSnapshot: nil),
            diagnostics: [note], docId: "ch-1")

        let ruled = "Kelly heard about the call offstage."
        let failure = await DiagnosticsPane.commitAnswer(
            ruled, to: note, docId: "ch-1", store: fx.store, world: fx.declaredWorld,
            diagnostics: fx.diagnostics)
        XCTAssertNil(failure, "the commit reported: \(failure ?? "")")

        let parsed = RulingsSection.parse(try fx.store.statementText(of: statement))
        XCTAssertEqual(parsed.rulings.map(\.text), [ruled],
                       "the parser survived the enriched, em-dash-bearing provenance")
        XCTAssertTrue(
            parsed.rulings.first?.provenance?.contains("the dread stays unnamed") == true,
            "got: \(parsed.rulings.first?.provenance ?? "nil")")

        // …and keeps writing, so run 2 has a delta of its own to check.
        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(2, on: runner)
        await settle()

        let second = runner.sends[1].message
        XCTAssertEqual(occurrences(of: ruled, in: second), 1,
                       "the writer's ruled sentence still reaches the briefing as a "
                       + "clause, exactly once and unmangled by the enriched "
                       + "provenance sitting beside it in the same file")
        XCTAssertEqual(deriver.calls, 2,
                       "…re-derived off the statement WITH the enriched ruling in it")
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
            oneStrain("Should she already know?", about: "a1b2"))
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
            oneStrain("Should she already know?", about: "a1b2"))
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

        // A conformance strain, because a strain is what a preview can show:
        // continuity and reader sections mint at finish and preview nothing
        // (M4 P1 Task 3).
        let strainLine = oneStrain("Should she already know?", about: "a1b2")
            .components(separatedBy: "\n")[0]
        runner.stream(strainLine + "\n")
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

        runner.release(.resultText(oneStrain("Should she already know?", about: "a1b2")))
        settle()

        let reconciled = harness.diagnostics.live(
            docId: docId, currentText: { _ in "The fog came." })
        XCTAssertEqual(reconciled.map(\.body), ["Should she already know?"],
                       "the finished run raises the note exactly once")

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
    /// first replace has nothing to remember. **Both of them stream**, because
    /// the first ⌘R against a new document is the sharp case — there is no
    /// finished run to set aside, and a `replace` that could not tell "set
    /// aside, and there was nothing" from "never set aside" would file round 1
    /// against its own half-report. Falsification: append to the ring from
    /// `preview` and this reads two.
    func test_aPreviewNeverEntersTheRoundRing() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil   // the first turn streams too
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        runner.stream(conformanceLine("Cold, and never wistful.", "strains",
                                      whatPulls: "The last line reaches for a sigh.") + "\n")
        runner.release(.resultText(
            oneStrain("Should she already know?", about: "a1b2")))
        settle()
        let finished = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(harness.diagnostics.roundHistory(docId: docId), [],
                       "a cold document's first run has no prior round to file — "
                       + "least of all itself")

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
        XCTAssertEqual(history.first?.fingerprints, [],
                       "the ring records THAT the round happened and when \u{2014} what "
                       + "it found is counted off the queue (M4 P1 Task 5)")
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

    // MARK: - The round stamps (M3-P3 Task 2)

    /// **A ⌘R while a pass is active is a numbered round.** The lane is the
    /// pass the writer has on the piece; the first run in it is round 1, and
    /// nothing before the pass existed counts toward it.
    func test_aRunUnderAnActivePassIsRoundOne() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line")

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let run = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(run.passId, "line", "the run records the lane it belongs to")
        XCTAssertEqual(run.round, 1, "the first round of a lane is round 1")
    }

    /// The next ⌘R in the same lane is the next round — the counting the
    /// whole loop is built on.
    func test_aSecondRunInTheSameLaneIsRoundTwo() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line")

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        // The writer keeps writing; a run over unchanged prose is an empty
        // delta and would spend no round at all.
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()

        let run = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(run.passId, "line")
        XCTAssertEqual(run.round, 2, "the second ⌘R in a lane is round 2")
    }

    /// **A lane is a lane of its own, and leaving one does not forget it.**
    /// The writer moves the piece from Line to Proof: Proof starts at 1, and
    /// coming back to Line resumes at 2 — which is only possible because the
    /// count survives in the round ring after the run carrying it has been
    /// superseded twice over.
    func test_aLaneChangeStartsAtOneAndTheOldLanesCountSurvives() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line")

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        XCTAssertEqual(harness.diagnostics.lastRun(docId: docId)?.round, 1)

        harness.setActivePass("proof")
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()
        let proof = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(proof.passId, "proof")
        XCTAssertEqual(proof.round, 1,
                       "a new lane starts at 1 — the Line rounds are not its own")

        harness.setActivePass("line")
        harness.setReading(readingAfterAThirdParagraph())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(3, on: runner)
        settle()
        let line = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(line.passId, "line")
        XCTAssertEqual(line.round, 2,
                       "returning to a lane resumes its count, which by now lives "
                       + "only in the round ring")
    }

    /// **A run with no active pass is an ordinary M2 run**, and says so on
    /// disk: no lane, no round, and not a `null` for either — decision 1's
    /// passless lane is an absence rather than a degenerate round 1.
    ///
    /// Asserted against the sidecar's own bytes, because the in-memory record
    /// cannot tell "never stamped" from "stamped nil" and the file is what a
    /// later launch reads back.
    func test_aRunWithNoActivePassStampsNoLaneAndNoRound() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let run = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertNil(run.passId)
        XCTAssertNil(run.round)

        let sidecar = DiagnosticsStore.sidecarURL(
            projectRoot: harness.root, docId: docId,
            device: DeviceSlug.make(from: "test-mac"))
        let json = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertFalse(json.contains("\"passId\""),
                       "a passless run writes no lane at all; got \(json)")
        // `"round":` and not `"round"` — the ring's own key is `"rounds"`.
        XCTAssertFalse(json.contains("\"round\":"),
                       "…and no round number; got \(json)")
    }

    /// **The lane and the round are minted at the KEYSTROKE, and the preview
    /// and the finished run carry the same pair.**
    ///
    /// Two defects in one assertion. A mint at `record(...)` time reads the
    /// store — which, mid-stream, holds this run's OWN preview — so the final
    /// record would be round 2 of a lane that has had one run: the run
    /// counting itself. And a writer who clicks another pass chip while the
    /// check is in flight would have the answer filed in a lane it was never
    /// read for.
    func test_thePreviewAndTheFinishedRunAgreeOnTheRound() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil   // the turn stays open
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line")
        streamingRun(runner: runner, harness: harness)

        runner.stream(conformanceLine("Cold, and never wistful.", "strains",
                                      whatPulls: "The last line reaches for a sigh.") + "\n")
        let preview = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(preview.passId, "line")
        XCTAssertEqual(preview.round, 1)

        // The writer switches the piece to another pass while the check runs.
        harness.setActivePass("proof")
        runner.release(.resultText(Self.fourEmptySections))
        settle()

        let finished = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(finished.passId, preview.passId,
                       "the run was read for the lane it started in; a mid-run "
                       + "switch belongs to the NEXT round")
        XCTAssertEqual(finished.round, preview.round,
                       "one ⌘R is one round — a mint at record time would have "
                       + "counted this run's own preview and filed round 2")
        XCTAssertEqual(finished.round, 1)
    }

    /// **The mint is never reached while a run stands** — R1's other half
    /// (#42). `runRequested`'s `!isRunning` refusal is what a second ⌘R hits
    /// BEFORE `beginRun`'s `latestRound(forPass:docId:)` call, and that is
    /// what keeps a run from numbering itself against itself: this run's own
    /// preview is already standing content by the time the second press
    /// arrives (`DiagnosticsStore.byDoc`, the same store `latestRound` reads
    /// directly, never the preview shadow — see its doc comment), so a mint
    /// that got past the guard would read that preview back and file the
    /// answer as the round after itself.
    ///
    /// Pinned on round numbers before and after the refused press, per the
    /// task brief — `runner.sends.count` alone (the existing refusal test's
    /// assertion) shows the runner was never asked again, not that the round
    /// arithmetic was untouched.
    func test_theMintNeverAsksLatestRoundWhileARunIsStanding() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil   // the turn stays open
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line")
        streamingRun(runner: runner, harness: harness)

        // Close a section so the preview is standing in the store at round 1
        // — exactly what a second mint, if the guard let one through, would
        // read back and count itself against.
        runner.stream(conformanceLine("Cold, and never wistful.", "strains",
                                      whatPulls: "The last line reaches for a sigh.") + "\n")
        XCTAssertEqual(harness.diagnostics.latestRound(forPass: "line", docId: docId), 1,
                       "the first run's own preview is standing")

        harness.orchestrator.runRequested(docId: docId)
        settle()

        XCTAssertEqual(runner.sends.count, 1, "the second ⌘R must not reach the runner")
        XCTAssertEqual(harness.diagnostics.latestRound(forPass: "line", docId: docId), 1,
                       "unchanged by the refused press — a mint that got through would "
                       + "have read this same preview back and produced round 2")

        runner.release(.resultText(Self.fourEmptySections))
        settle()

        let finished = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(finished.round, 1, "the run that actually ran is still round 1 — "
                       + "the refused press minted nothing to collide with it")
    }

    // MARK: - The board chip's round waits for the piece to open (M4 P2 Task 4)

    /// The path the editor mounts a chapter at, for the tests below that need
    /// to close and reopen it by hand.
    private static let liveDocPath = "manuscript/ch1.md"

    /// **The hazard, live.** `runRequested` refuses — silently, with no
    /// acknowledgment and no failure — while the document is not open
    /// (`environment.reading(docId) != nil`). A board chip navigates first and
    /// the open is asynchronous, so a run fired on the same turn as the
    /// navigation arrives before there is anything to read and simply does not
    /// happen: no error, no flash, no notes, nothing in the log.
    ///
    /// This is the falsification the deferral exists for, kept as a permanent
    /// test rather than a note: the day `runRequested` learns to open a
    /// document itself, this goes red and the deferral can go.
    func test_falsification_aRunOnAPieceThatIsNotOpenYetIsRefusedInSilence() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        setActivePass("copyedit", on: fx)
        fx.documentStore.unregister(path: Self.liveDocPath)

        fx.orchestrator.runRequested(docId: "ch-1")

        // Asserted synchronously because the refusal IS synchronous: the guard
        // sits above the burst hop, so a run that was going to happen has
        // already set `isPreparingRun` by now.
        XCTAssertFalse(fx.orchestrator.isRunning,
                       "a run on a closed piece must not even begin to prepare")
        await awaitNothingMinted()
        XCTAssertTrue(runner.sends.isEmpty,
                      "the refusal is total and it is silent \u{2014} which is "
                      + "exactly why the chip cannot run on the navigation turn")
    }

    /// **The deferral: the run lands once the editor has the piece open.**
    /// Nothing before that, one run after it.
    func test_theChipsRoundWaitsForThePieceToOpenAndThenRuns() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        setActivePass("copyedit", on: fx)
        fx.documentStore.unregister(path: Self.liveDocPath)

        let waiting = RunWhenDocumentOpens.start(
            docId: "ch-1", within: .seconds(5), polling: .milliseconds(5),
            isOpen: { [documentStore = fx.documentStore] id in
                documentStore.document(forDocId: id) != nil
            },
            run: { [orchestrator = fx.orchestrator] id in
                orchestrator.runRequested(docId: id)
            })

        XCTAssertTrue(runner.sends.isEmpty,
                      "premise: nothing runs while the piece is closed")

        // The editor mounts the chapter the navigation asked for.
        fx.documentStore.register(document: fx.document, for: Self.liveDocPath)

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .ran,
                       "the deferral must resolve into a run, not expire behind "
                       + "a document that did open")
        await awaitSends(1, on: runner)
        XCTAssertEqual(runner.sends.count, 1, "exactly one round, once")
    }

    /// The control for the wait: a piece already open runs without waiting for
    /// anything. Without this a deferral that never fired at all would pass the
    /// test above's sibling by never being asked.
    func test_aPieceAlreadyOpenRunsStraightAway() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        setActivePass("copyedit", on: fx)

        let waiting = RunWhenDocumentOpens.start(
            docId: "ch-1", polling: .milliseconds(5),
            isOpen: { [documentStore = fx.documentStore] id in
                documentStore.document(forDocId: id) != nil
            },
            run: { [orchestrator = fx.orchestrator] id in
                orchestrator.runRequested(docId: id)
            })

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .ran)
        await awaitSends(1, on: runner)
    }

    /// **A piece that never opens drops the round — and says so.** A load
    /// failure, a deleted file, a subject the tree refused: the writer gets no
    /// round and no hang, the reason goes to the log, and (Denver's 2026-08-18
    /// ruling) the expiry FLASHES. The log alone made a dropped chip press
    /// indistinguishable from a chip that does nothing — the writer travelled
    /// to the piece, waited, and no round ever arrived. The bound is
    /// `RunWhenDocumentOpens.deadline`; the test shortens it because what is
    /// under test is the expiry, not the number.
    func test_aPieceThatNeverOpensDropsTheRoundRatherThanHanging() async {
        var ran = 0
        var flashed = 0
        let waiting = RunWhenDocumentOpens.start(
            docId: "ch-1", within: .milliseconds(120), polling: .milliseconds(5),
            isOpen: { _ in false },
            run: { _ in ran += 1 },
            onTimedOut: { flashed += 1 })

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .timedOut,
                       "the wait is bounded \u{2014} a document that never "
                       + "arrives must not leave a task polling for the life of "
                       + "the window")
        XCTAssertEqual(ran, 0, "and nothing is run on a piece that never opened")
        XCTAssertEqual(flashed, 1,
                       "the drop must reach the writer, not only the log")
        XCTAssertEqual(
            CompilerOrchestrator.Acknowledgment.pieceWouldNotOpen.flashLabel,
            "Couldn\u{2019}t open the piece \u{2014} try again.",
            "the sentence the window shows, kept beside its case")
    }

    /// The two controls for the flash, so it cannot become an unconditional
    /// one: a wait that RUNS says nothing, and a wait that is CANCELLED says
    /// nothing either. A cancelled deferral is a window going away, and a
    /// capsule about a round the writer already left is worse than silence.
    func test_onlyTheExpiryFlashes() async {
        var flashed = 0
        let ran = RunWhenDocumentOpens.start(
            docId: "ch-1", polling: .milliseconds(5),
            isOpen: { _ in true }, run: { _ in },
            onTimedOut: { flashed += 1 })
        let ranOutcome = await ran.value
        XCTAssertEqual(ranOutcome, .ran)
        XCTAssertEqual(flashed, 0, "a round that started needs no apology")

        let cancelled = RunWhenDocumentOpens.start(
            docId: "ch-1", within: .seconds(30), polling: .milliseconds(5),
            isOpen: { _ in false }, run: { _ in },
            onTimedOut: { flashed += 1 })
        cancelled.cancel()
        let cancelledOutcome = await cancelled.value
        XCTAssertEqual(cancelledOutcome, .cancelled)
        XCTAssertEqual(flashed, 0, "a cancelled wait is not a failed one")
    }

    /// The production mount is what turns the closure into a capsule. The
    /// helper's own census (`ReviewBoardPaneTests`) reads its wait; this reads
    /// the sentence, because a deferral that expires into an empty closure
    /// would satisfy every other assertion in this file.
    func test_theProductionMountFlashesTheDroppedRound() throws {
        let window = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()      // MaughamTests/
                .deletingLastPathComponent()      // repo root
                .appendingPathComponent("Maugham/Views/ProjectWindow.swift"),
            encoding: .utf8)
        let helper = try XCTUnwrap(
            window.range(of: "private func runRoundWhenPieceOpens("),
            "the deferral's one production caller must still be readable here")
        // Generous, and deliberately so: the window has to cover the whole
        // `start(…)` call INCLUDING its comments, and a prefix sized to
        // today's body silently stops asserting the moment someone explains
        // themselves at length above the line under test. (It did exactly
        // that once, in this branch's own fix wave.)
        let body = String(window[helper.upperBound...].prefix(1_600))
        XCTAssertTrue(body.contains("onTimedOut:"),
                      "the mount must supply the expiry's sentence. Got:\n\(body)")
        XCTAssertTrue(body.contains(".show(.pieceWouldNotOpen)"),
                      "\u{2026}and it goes through the window's one flash path "
                      + "with the acknowledgment's own case. Got:\n\(body)")
        // Minor 6 (2026-08-18 review): the closure outlives the turn by the
        // deferral's whole 5s bound, so it captures the flash rather than the
        // window — beside two capture lists written for exactly that reason.
        // Asserted here because a later hand simplifying it back to a bare
        // `showCompilerFlash(…)` would still satisfy everything above while
        // holding `store`, `documentStore` and `compiler` for those 5s.
        XCTAssertTrue(body.contains("[flash = compilerFlash]"),
                      "the expiry closure must capture the flash sink, not "
                      + "`self`. Got:\n\(body)")
    }

    /// **A cancelled wait says so, and says it promptly.** `Task.sleep` throws
    /// on cancellation and the loop swallows that with `try?`, so without the
    /// `Task.isCancelled` check at the loop head a cancelled wait would spin at
    /// full speed to the deadline and then report a timeout it never reached.
    /// The generous `within:` here is the assertion: reaching `.cancelled` at
    /// all means the check fired rather than the clock.
    func test_aCancelledWaitSaysSoRatherThanReportingATimeout() async {
        var ran = 0
        let waiting = RunWhenDocumentOpens.start(
            docId: "ch-1", within: .seconds(30), polling: .milliseconds(5),
            isOpen: { _ in false },
            run: { _ in ran += 1 })

        waiting.cancel()

        let outcome = await waiting.value
        XCTAssertEqual(outcome, .cancelled,
                       "a wait cancelled 30 seconds short of its deadline must "
                       + "report the cancellation, not the expiry")
        XCTAssertEqual(ran, 0)
    }

    /// The bound is a real few seconds, not a token one: opening a document
    /// reads an op log off disk, and a deadline tight enough to expire on a
    /// cold cache would turn a working chip into an intermittent one.
    func test_theWaitsDefaultBoundIsGenerousEnoughForARealOpen() {
        XCTAssertGreaterThanOrEqual(
            RunWhenDocumentOpens.deadline, .seconds(3),
            "a document open is disk work \u{2014} the bound must survive one")
        XCTAssertLessThanOrEqual(
            RunWhenDocumentOpens.deadline, .seconds(30),
            "\u{2026}and must still be a bound a writer would notice ending")
    }

    /// **The task end to end, through the verb the board actually draws.**
    ///
    /// The chip's menu item is performed, the window's three acts happen in
    /// order — the lane is recorded, the subject moves, the run waits — the
    /// editor opens the piece, and what lands on the document is a note signed
    /// by that pass's own editor, stamped with that pass.
    func test_theBoardChipsRoundLandsANoteSignedByThatPassesEditor() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        runner.nextEvent = .resultText(oneQuestion("Has anyone said how long yet?",
                                                   about: pid))
        // The piece is not open: the reviewer is looking at the board, which is
        // a project-level surface, and the chapter they right-clicked has never
        // been on screen.
        fx.documentStore.unregister(path: Self.liveDocPath)

        var subject: BinderSubject?
        var waiting: Task<RunWhenDocumentOpens.Outcome, Never>?
        let verbs = ReviewBoardChipVerbs(
            onSetState: { _, _, _ in
                XCTFail("a round is not a ruling")
            },
            // The window's own closure, transcribed — the census in
            // `ReviewBoardPaneTests` is what keeps the production mount equal
            // to it.
            onRunRound: { [documentStore = fx.documentStore,
                           orchestrator = fx.orchestrator] pieceId, passId in
                documentStore.updateUIState {
                    $0.activePassMemory.record(piece: pieceId, passId: passId)
                }
                subject = .item(pieceId)
                waiting = RunWhenDocumentOpens.start(
                    docId: pieceId, polling: .milliseconds(5),
                    isOpen: { documentStore.document(forDocId: $0) != nil },
                    run: { orchestrator.runRequested(docId: $0) })
            })

        let menu = verbs.chipMenu(
            for: "ch-1", pass: ReviewPass(id: "copyedit", name: "Copyedit"),
            current: nil)
        XCTAssertEqual(menu.run.title, "Run Gould\u{2019}s round",
                       "premise: this is the verb a reviewer would press")
        menu.run.perform()

        XCTAssertEqual(
            fx.documentStore.uiState.activePassMemory.activePass(forPiece: "ch-1"),
            "copyedit",
            "the chip's round records the lane it is asking for \u{2014} the "
            + "value the run reads to sign and file its notes")
        XCTAssertEqual(subject, .item("ch-1"),
                       "\u{2026}and takes the reviewer to the piece being checked")
        XCTAssertTrue(runner.sends.isEmpty,
                      "\u{2026}and does not run yet: the piece is still closed")

        fx.documentStore.register(document: fx.document, for: Self.liveDocPath)
        let deferred = try XCTUnwrap(waiting, "the verb must have started a wait")
        let outcome = await deferred.value
        XCTAssertEqual(outcome, .ran)
        await awaitOpenNotes(1, on: fx.document)

        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
        XCTAssertEqual(notes.count, 1, "got \(notes.map(\.body))")
        XCTAssertEqual(notes.first?.author?.displayName, "Gould",
                       "the Copyedit pass's editor signs the round the chip asked for")
        XCTAssertEqual(notes.first?.reviewPassId, "copyedit",
                       "\u{2026}and the lane the chip named stamps what it wrote")
    }

    // MARK: - The round stamps: production wiring

    /// The compiler's read of the active pass is `validatedActivePass` off
    /// `uiState` — the same one-line spelling the margin stamp uses, keyed by
    /// the document (the piece IS the document here).
    func test_productionActivePassIsTheValidatedReadOffUIState() async throws {
        let root = try makeListingsProjectRoot()
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        documentStore.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: "line")
        }
        let environment = makeProductionEnvironment(
            store: store, documentStore: documentStore, root: root)

        let lane = try XCTUnwrap(environment.activePass("ch-1"))
        XCTAssertEqual(lane.id, "line")
        // **Resolved WHOLE, and through `ReviewPass`'s own fallbacks** (M4 P1
        // Task 3): the lane, the editor who signs its notes and the brief its
        // rounds are given come from one read. A production wiring that
        // answered only an id would leave the editor's name to be re-derived
        // somewhere else, and two spellings of "which pass is this" is how the
        // filing and the authorship come to disagree.
        XCTAssertEqual(lane.editorName, "Lish",
                       "the Line pass's editor \u{2014} `effectiveEditorName`, "
                       + "never the raw stored field")
        XCTAssertNotNil(lane.brief, "…and its doctrine, for the briefing")
        // **The piece next door is the coach's** (editorial letter P1, spec
        // §4.1). Before the seat existed this answered nil; now an unassigned
        // piece resolves to Le Guin, and the closure is the resolution's
        // reader rather than a second copy of the rule.
        XCTAssertEqual(environment.activePass("ch-2")?.id, "workshop",
                       "a piece the writer never opened a pass on is the coach's")
    }

    /// **A stored pass the project no longer offers falls to the coach**
    /// (editorial letter P1, spec §4.1: deleting a pass gives its pieces back
    /// to Le Guin). Pinned at the compiler's own read rather than only at
    /// `PieceReader`, so a later "optimize to the raw read" cannot file rounds
    /// into a lane that does not exist.
    func test_productionGivesARetiredPassesPieceToTheCoach() async throws {
        let root = try makeListingsProjectRoot()
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        documentStore.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: "retired-pass")
        }
        let environment = makeProductionEnvironment(
            store: store, documentStore: documentStore, root: root)

        let lane = try XCTUnwrap(
            environment.activePass("ch-1"),
            "a retired id reads as unassigned, and an unassigned piece is hers")
        XCTAssertEqual(lane.id, "workshop")
        XCTAssertEqual(lane.editorName, "Le Guin",
                       "the lane that does not exist must not be the one filed in")
    }

    /// **The one off switch, at the production read.** With the seat vacated
    /// an unassigned piece is nobody's again — the nil lane, which is what the
    /// orchestrator reads as M2's all-altitudes ⌘R.
    func test_productionHasNoLaneForAnUnassignedPieceOnceTheSeatIsVacated() async throws {
        let root = try makeListingsProjectRoot()
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        let environment = makeProductionEnvironment(
            store: store, documentStore: documentStore, root: root)
        XCTAssertEqual(environment.activePass("ch-1")?.id, "workshop",
                       "control: the seat starts held")

        try await store.setCoachVacated(true)

        XCTAssertNil(environment.activePass("ch-1"),
                     "a vacated seat leaves an unassigned piece in the nil lane")
    }

    /// The weak-capture discipline this file's own doc states, one closure
    /// further on: a window closed mid-run answers honestly rather than
    /// crashing on a store that is gone.
    func test_productionHasNoLaneOnceTheWindowsStoresAreGone() async throws {
        let root = try makeListingsProjectRoot()
        var store: ProjectStore? = try await ProjectStore.load(from: root)
        var documentStore: DocumentStore? = try await DocumentStore.open(url: root)
        documentStore?.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: "line")
        }
        let environment = makeProductionEnvironment(
            store: store!, documentStore: documentStore!, root: root)
        XCTAssertEqual(environment.activePass("ch-1")?.id, "line")

        store = nil
        documentStore = nil

        XCTAssertNil(environment.activePass("ch-1"))
    }

    // MARK: - Since last round (M3-P3 Task 3)

    /// **The next round is briefed on what the last one raised.** The whole
    /// loop in one test: run 1 asks a question, the writer writes on, and run
    /// 2's message carries that question back with the round it came from — so
    /// the model confirms rather than re-derives it.
    func test_theNextRoundIsBriefedOnWhatTheLastOneRaised() throws {
        let runner = SpyRunner()
        // A conformance strain: as of M4 P1 it is the only kind the round ring
        // and the standing report still hold, so it is what a later round can
        // be briefed on out of the sidecar. (The other two kinds are minted as
        // annotations, and briefing the model on THOSE is Task 4's.)
        runner.nextEvent = .resultText(
            oneStrain("Whose coat is on the chair?", about: "a1b2"))
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line")

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        XCTAssertEqual(harness.diagnostics.lastRun(docId: docId)?.round, 1)
        XCTAssertFalse(runner.sends[0].message.contains("raised these notes"),
                       "control: round 1 has no prior round to be briefed on")

        runner.nextEvent = .resultText(Self.fourEmptySections)
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()

        let second = runner.sends[1].message
        XCTAssertTrue(second.contains("Whose coat is on the chair?"),
                      "the previous round's note must reach the next round's "
                      + "message; got \(second)")
        // The lane in curly quotes, not a bare "line" — the schema description
        // says "four lines" a paragraph later, and a substring check for the
        // bare word would pass on a message with no round section at all.
        XCTAssertTrue(second.contains("Round 1 of the \u{201C}line\u{201D} pass"),
                      "…named by its round and its lane; got \(second)")

        // **The pane's line is drawn over the same two rounds** — and this
        // harness mints through a spy, so the queue it counts is empty and the
        // honest reading is three zeroes. What the line counts when notes
        // really land is `test_theSinceLastRoundLineCountsWhatTheWriterSettled`,
        // over a live document.
        XCTAssertEqual(
            RoundNarrative.sinceLastRoundLine(
                history: harness.diagnostics.roundHistory(docId: docId),
                run: harness.diagnostics.lastRun(docId: docId),
                annotations: []),
            "Since round 1: 0 resolved \u{00b7} 0 persisting \u{00b7} 0 new")
    }

    /// **The partition the app knows and the model cannot.** A note anchored
    /// to a paragraph the writer has since rewritten is exactly "they have
    /// been working behind this one" — `DiagnosticsStore.live`'s own
    /// anchor-text equality, read at the keystroke.
    func test_aNoteTheWriterHasEditedBehindIsBriefedAsSuch() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(
            oneStrain("Whose coat is on the chair?", about: "a1b2"))
        let live = Box("The fog came.")
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line",
            liveParagraphText: { _, _ in live.value })

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        // The writer rewrites the paragraph the question was about.
        live.value = "The fog lifted before noon."
        runner.nextEvent = .resultText(Self.fourEmptySections)
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()

        let second = runner.sends[1].message
        guard let heading = second.range(of: CompilerPrompt.sinceEditedHeading),
              let body = second.range(of: "Whose coat is on the chair?")
        else { return XCTFail("expected the edited-behind partition; got \(second)") }
        XCTAssertLessThan(heading.lowerBound, body.lowerBound)
        XCTAssertFalse(second.contains(CompilerPrompt.untouchedHeading),
                       "the only note there was has moved out of the untouched half")
    }

    /// **A new lane is briefed on nothing.** The comparison lane is
    /// `(document, pass)`: the Line pass's findings are not what a Proof round
    /// is measured against, and briefing them would have the model confirming
    /// notes from a pass the writer has finished.
    func test_aRoundThatOpensANewLaneIsBriefedOnNoPriorRound() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(
            oneQuestion("Whose coat is on the chair?", about: "a1b2"))
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line")

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        harness.setActivePass("proof")
        runner.nextEvent = .resultText(Self.fourEmptySections)
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()

        XCTAssertEqual(harness.diagnostics.lastRun(docId: docId)?.round, 1,
                       "control: the new lane starts at round 1")
        XCTAssertFalse(runner.sends[1].message.contains("Whose coat is on the chair?"),
                       "got: \(runner.sends[1].message)")
        XCTAssertFalse(runner.sends[1].message.contains("raised these notes"))
    }

    /// A ⌘R with no pass active is an ordinary M2 run: no lane, no round, and
    /// nothing to be measured against — not even the last round of the pass
    /// the writer has since stepped out of.
    func test_aPasslessRunIsBriefedOnNoPriorRound() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(
            oneQuestion("Whose coat is on the chair?", about: "a1b2"))
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line")

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        harness.setActivePass(nil)
        runner.nextEvent = .resultText(Self.fourEmptySections)
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()

        XCTAssertNil(harness.diagnostics.lastRun(docId: docId)?.round)
        XCTAssertFalse(runner.sends[1].message.contains("raised these notes"),
                       "got: \(runner.sends[1].message)")
    }

    /// **A failed run consumes no round number.** It records nothing, so the
    /// standing content is still the round before it — the next ⌘R takes the
    /// number the failure did not. Verified by reading in Task 2 and pinned
    /// here, where the lane's arithmetic is the subject.
    func test_aFailedRunConsumesNoRoundNumber() throws {
        let runner = SpyRunner()
        runner.nextEvent = .failed(.unusableOutput)
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line")

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        XCTAssertNil(harness.diagnostics.lastRun(docId: docId),
                     "control: a failed run records nothing at all")

        runner.nextEvent = .resultText(Self.fourEmptySections)
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()

        XCTAssertEqual(harness.diagnostics.lastRun(docId: docId)?.round, 1,
                       "the failure spent no round \u{2014} the writer's first "
                       + "report is round 1")
    }

    // MARK: - The intent-drift verdict (M3-P3 Task 4)

    /// A turn that answers all five sections, with the drift verdict the test
    /// asks for and nothing else to report.
    private static func fiveSections(verdict: String) -> String {
        fourEmptySections + "\n"
            + "{\"section\":\"intent_drift\",\"verdict\":\"\(verdict)\","
            + "\"note\":\"The last scenes reach for a warmth the intent rules out.\"}"
    }

    /// **The verdict rides the run record all the way to the sidecar's own
    /// bytes** — the field Task 1 added, written for the first time here.
    ///
    /// Against the raw JSON rather than the in-memory record: the pane, the
    /// strip and the next round all read a decoded file, and a field threaded
    /// into `record` but missing from the encoder would pass every in-memory
    /// assertion and lose the verdict on the first relaunch.
    func test_theDriftVerdictReachesTheSidecar() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(Self.fiveSections(verdict: "drifted"))
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line")

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(
            harness.diagnostics.lastRun(docId: docId)?.intentDriftVerdict, "drifted")

        let sidecar = DiagnosticsStore.sidecarURL(
            projectRoot: harness.root, docId: docId,
            device: DeviceSlug.make(from: "test-mac"))
        let json = try String(contentsOf: sidecar, encoding: .utf8) // adr-0018-ok: diagnostics sidecar, derived, not manuscript
        XCTAssertTrue(json.contains("\"intentDriftVerdict\":\"drifted\""),
                      "the verdict never reached disk; got \(json)")
        // The model's own sentence is dropped at ingest (ADR 0027) and must
        // not have travelled here by some other route.
        XCTAssertFalse(json.contains("warmth the intent rules out"),
                       "the model's drift sentence was persisted; got \(json)")
    }

    /// A run that answers the four sections it knows records no verdict —
    /// and writes no key for one, so a later build can tell "never judged"
    /// from "judged and unrecognised".
    func test_aFourSectionAnswerRecordsNoVerdict() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertNil(harness.diagnostics.lastRun(docId: docId)?.intentDriftVerdict)
        let sidecar = DiagnosticsStore.sidecarURL(
            projectRoot: harness.root, docId: docId,
            device: DeviceSlug.make(from: "test-mac"))
        let json = try String(contentsOf: sidecar, encoding: .utf8) // adr-0018-ok: diagnostics sidecar, derived, not manuscript
        XCTAssertFalse(json.contains("\"intentDriftVerdict\""),
                       "an unjudged run wrote a verdict key; got \(json)")
    }

    /// **A cancelled preview leaves the previous verdict standing** — the
    /// storage half of "a preview persists nothing", asserted on the field
    /// this task adds.
    ///
    /// The verdict is the sharpest case of the preview rule, because it is the
    /// one field a half-report can carry that reads as a judgement on the whole
    /// draft: a stream cut off after the drift section would otherwise leave
    /// "drifted" on the strip, sourced from a check that stopped reading. The
    /// byte comparison is the one assertion a write that merely round-trips
    /// cannot satisfy (its neighbour,
    /// `test_aDismissalCannotReachAPreview_soTheSidecarSurvivesACancelByteIdentical`,
    /// makes the same argument about `dismiss`).
    func test_aCancelledPreviewLeavesThePreviousVerdictStanding() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(Self.fiveSections(verdict: "holds"))
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        XCTAssertEqual(harness.diagnostics.lastRun(docId: docId)?.intentDriftVerdict,
                       "holds", "control: the finished run judged the draft")
        let sidecar = DiagnosticsStore.sidecarURL(
            projectRoot: harness.root, docId: docId,
            device: DeviceSlug.make(from: "test-mac"))
        let before = try Data(contentsOf: sidecar) // adr-0018-ok: diagnostics sidecar, derived, not manuscript

        // A second run, held open, its drift section already streamed.
        runner.nextEvent = nil
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        runner.stream("{\"section\":\"intent_drift\",\"verdict\":\"drifted\"}\n")
        XCTAssertEqual(
            harness.diagnostics.lastRun(docId: docId)?.intentDriftVerdict, "drifted",
            "control: the preview shows the verdict as it arrives")
        XCTAssertEqual(
            try Data(contentsOf: sidecar), before, // adr-0018-ok: diagnostics sidecar, derived, not manuscript
            "a previewed verdict was persisted")

        harness.orchestrator.cancel()
        settle()

        XCTAssertEqual(
            try Data(contentsOf: sidecar), before, // adr-0018-ok: diagnostics sidecar, derived, not manuscript
            "the cancelled run left its verdict behind")
        XCTAssertEqual(
            harness.diagnostics.lastRun(docId: docId)?.intentDriftVerdict, "holds",
            "the last finished run's verdict is the standing one")
    }

    /// **The verdict survives the stream's fold**, which it can only do if
    /// `combining` keeps the latest non-nil: the model answers the sections in
    /// the schema's order, so on a real stream the drift line arrives LAST and
    /// each preceding section folds a nil over whatever came before it. This
    /// drives the reverse — the drift line first, four nils after it — because
    /// that is the ordering a lost verdict would survive.
    func test_aStreamedVerdictSurvivesTheSectionsAfterIt() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())
        streamingRun(runner: runner, harness: harness)

        runner.stream("{\"section\":\"intent_drift\",\"verdict\":\"drifted\"}\n")
        XCTAssertEqual(
            harness.diagnostics.lastRun(docId: docId)?.intentDriftVerdict, "drifted")

        runner.stream(conformanceLine("Cold, and never wistful.", "strains",
                                      whatPulls: "The last line reaches for a sigh.") + "\n")
        XCTAssertEqual(
            harness.diagnostics.lastRun(docId: docId)?.intentDriftVerdict, "drifted",
            "a section with no verdict erased the one already streamed")

        runner.release(.resultText(Self.fiveSections(verdict: "drifted")))
        settle()
        XCTAssertEqual(
            harness.diagnostics.lastRun(docId: docId)?.intentDriftVerdict, "drifted")
    }

    // MARK: - The strip's quiet mark (M3-P3 Task 5)

    /// **A run against no declared intent records NO verdict**, whatever the
    /// model says — the honesty guard.
    ///
    /// The schema instructs `holds` where nothing is declared, which is the
    /// obliging answer and not a true one: there was no intent to check the
    /// draft against, so there is nothing the model can have judged. Recording
    /// it would put a judgement on the run record that no reading produced,
    /// and the sidecar is where a later build looks to tell "never judged"
    /// from "judged and held". The key must be absent, not false-ish.
    ///
    /// Nothing downstream of this reads `holds` — the mark fires on `drifted`
    /// alone — so this is about what the record is allowed to CLAIM rather
    /// than about the strip.
    func test_aRunWithNoDeclaredIntentRecordsNoVerdict() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(Self.fiveSections(verdict: "holds"))
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), statementText: nil)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertNotNil(harness.diagnostics.lastRun(docId: docId),
                        "control: the run must have finished and filed a record")
        XCTAssertNil(harness.diagnostics.lastRun(docId: docId)?.intentDriftVerdict)

        let sidecar = DiagnosticsStore.sidecarURL(
            projectRoot: harness.root, docId: docId,
            device: DeviceSlug.make(from: "test-mac"))
        let json = try String(contentsOf: sidecar, encoding: .utf8) // adr-0018-ok: diagnostics sidecar, derived, not manuscript
        XCTAssertFalse(
            json.contains("\"intentDriftVerdict\""),
            "a run with nothing declared recorded a verdict anyway; got \(json)")
    }

    /// The same guard's converse, so the fix cannot be "record nothing ever":
    /// with an intent declared, the verdict rides the record as Task 4 built
    /// it.
    func test_aRunWithADeclaredIntentStillRecordsItsVerdict() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(Self.fiveSections(verdict: "holds"))
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(
            harness.diagnostics.lastRun(docId: docId)?.intentDriftVerdict, "holds")
    }

    /// **The mark, end to end from the keystroke**: a round answers `drifted`
    /// and the decision the window asks raises it; the next round answers
    /// `holds` and it clears, with the writer having touched nothing.
    ///
    /// Driven through the orchestrator rather than a hand-built record,
    /// because the thing under test is the join — the snapshot the run stored
    /// and the statement text the window resolves have to be the same string
    /// or the hash comparison never matches and the mark can never appear.
    func test_theMarkFollowsTheStandingRoundsVerdict() throws {
        let intent = "Cold, and never wistful."
        let runner = SpyRunner()
        runner.nextEvent = .resultText(Self.fiveSections(verdict: "drifted"))
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), statementText: intent)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertTrue(
            IntentDrift.mayTrailDraft(
                lastRun: harness.diagnostics.lastRun(docId: docId),
                currentStatementText: intent),
            "the round judged the draft drifted and the intent is untouched")

        // The writer keeps writing; the next round finds the draft back on
        // its intent.
        runner.nextEvent = .resultText(Self.fiveSections(verdict: "holds"))
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()

        XCTAssertFalse(
            IntentDrift.mayTrailDraft(
                lastRun: harness.diagnostics.lastRun(docId: docId),
                currentStatementText: intent),
            "a later round said the draft holds; the mark must clear with no "
            + "stored state to un-set")
    }

    // MARK: - Fresh eyes (M3-P3 Task 6)
    //
    // ⌘⇧R is one keystroke with three parts, and each of them is separately
    // deletable while the other two keep working: the warm process dies, the
    // read is of the whole piece rather than the delta, and the round is
    // briefed on no prior round. A test per part, each with the ordinary ⌘R
    // beside it as its control.

    /// The failure a spawn refused by the AI toggle comes back as, whichever
    /// key asked for it — pulled out of the state so two runs can be compared
    /// without their timestamps taking part.
    private func failure(
        of state: CompilerOrchestrator.RunState
    ) -> (docId: String, failure: CompilerRunFailure)? {
        guard case .failed(let docId, let failure, _) = state else { return nil }
        return (docId, failure)
    }

    /// **The wiring census, Fresh Eyes' half.** Same reasoning as ⌘R's: the
    /// menu item and the modifier's subscription are the two ends no test can
    /// mount, and deleting either leaves every assertion below green over a
    /// keystroke that does nothing.
    func test_theFreshEyesCommandIsWiredFromTheMenuToTheWindow() throws {
        let app = try source(at: "Maugham/MaughamApp.swift")
        XCTAssertTrue(app.contains("MaughamEvent.postCompilerFreshEyes()"),
                      "the menu item must post through the typed wrapper (tripwire 21)")
        XCTAssertTrue(app.contains(#".keyboardShortcut("r", modifiers: [.command, .shift])"#),
                      "…and carry ⌘⇧R, which was verified unbound at implementation time")

        let modifier = try source(at: "Maugham/Views/CompilerRunModifier.swift")
        for token in [".onKeyWindowCommand(.maughamFreshEyesCompiler",
                      "freshEyes: true"] {
            XCTAssertTrue(modifier.contains(token),
                          "CompilerRunModifier is missing \(token) \u{2014} without it "
                          + "⌘⇧R reaches no orchestrator, or reaches it as an "
                          + "ordinary ⌘R")
        }
        XCTAssertFalse(modifier.contains(".onKeyWindowCommand(.maughamNotARealEvent"),
                       "the scan reads the file rather than always answering true")
    }

    /// **The discriminator.** A ⌘R over unchanged prose is an empty delta and
    /// spends nothing — that is the whole of M2's marker discipline. Fresh
    /// eyes over the same unchanged prose reads the piece: the marker is not
    /// consulted, so the paragraph the last run already checked is in this
    /// message.
    ///
    /// Falsification: keep the marker read on the fresh path and this run is
    /// `nothingNew` with no second send at all.
    func test_freshEyesReadsTheWholePieceThoughTheMarkerIsCurrent() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        XCTAssertTrue(runner.sends[0].message.contains("The fog came."))

        // Control: the ordinary key, over prose the marker has already seen.
        harness.orchestrator.runRequested(docId: docId)
        settle()
        XCTAssertEqual(runner.sends.count, 1,
                       "control: ⌘R over unchanged prose spends no turn")
        guard case .nothingNew = harness.orchestrator.runState else {
            return XCTFail("control: the ordinary key must report nothing new, "
                           + "got \(harness.orchestrator.runState)")
        }

        harness.orchestrator.runRequested(docId: docId, freshEyes: true)
        awaitSends(2, on: runner)
        settle()

        XCTAssertTrue(runner.sends[1].message.contains("The fog came."),
                      "the cold read must carry the paragraph the marker already "
                      + "covered; got \(runner.sends[1].message)")
        XCTAssertEqual(harness.diagnostics.lastRun(docId: docId)?.deltaSummary,
                       "1 new, 0 revised \u{00b6}",
                       "the whole standing manuscript arrives as new")
    }

    /// **The process dies before the read, and the cold one is told everything
    /// again.** `sentBriefing` is cleared with the session, so the message
    /// carries the essay rather than the marker line a warm session gets.
    func test_freshEyesRetiresTheWarmSessionAndBriefsItWhole() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        XCTAssertTrue(runner.sends[0].message.contains("Cold, and never wistful."),
                      "the first run of a session is briefed whole")
        XCTAssertEqual(harness.spawns, 1)

        // Control: an ordinary second run rides the same process, and the
        // briefing is elided because that process has already read it.
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()
        XCTAssertTrue(runner.sends[1].message.contains("unchanged since last run"),
                      "control: a warm session is told the briefing is unchanged; "
                      + "got \(runner.sends[1].message)")
        XCTAssertEqual(runner.shutdowns, 0, "control: ⌘R retires nothing")
        XCTAssertEqual(harness.spawns, 1, "control: ⌘R spawns nothing")

        harness.setReading(readingAfterAThirdParagraph())
        harness.orchestrator.runRequested(docId: docId, freshEyes: true)
        awaitSends(3, on: runner)
        settle()

        XCTAssertEqual(runner.shutdowns, 1,
                       "the warm process must be shut down, not merely dropped")
        XCTAssertEqual(harness.spawns, 2,
                       "…and a new one asked for in its place")
        XCTAssertFalse(runner.sends[2].message.contains("unchanged since last run"),
                       "a cold process has read nothing; got \(runner.sends[2].message)")
        XCTAssertTrue(runner.sends[2].message.contains("Cold, and never wistful."),
                      "…so the whole briefing re-embeds; got \(runner.sends[2].message)")
    }

    /// **A fresh-eyes press with nothing to read costs the writer nothing.**
    /// `retireSession()` sits BELOW the empty-delta guard on purpose — the
    /// warm process is the expensive thing in this design, and a keystroke
    /// that turns out to have no prose behind it must not have killed it on
    /// the way past. The ordering was asserted in three prose comments
    /// (`beginRun`'s own, and `Maugham/Compiler/AREA.md`'s lifetime row) and
    /// pinned by nothing.
    ///
    /// Falsification: hoist `if freshEyes { retireSession() }` above the
    /// `guard !delta.isEmpty` and `shutdowns` reads 1 — the session established
    /// by the first run is reaped for a press that then reports `nothingNew`.
    func test_freshEyesWithNothingToReadKeepsTheWarmSession() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        // A real run first, so there IS a warm session to lose. Without it
        // `runner` is still nil inside the orchestrator and `retireSession`
        // would be a silent no-op wherever it sat.
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        XCTAssertEqual(runner.shutdowns, 0)
        XCTAssertEqual(harness.spawns, 1)

        // Nothing standing to read. A cold read consults no marker, so this —
        // not "unchanged prose" — is what an empty delta looks like on the
        // fresh path (`DeltaBuilder` walks `sequence` when `since` is nil).
        harness.setReading(CompilerOrchestrator.DocumentReading(
            ops: [], paragraphs: [:], sequence: []))
        harness.orchestrator.runRequested(docId: docId, freshEyes: true)
        settle()

        XCTAssertEqual(runner.shutdowns, 0,
                       "the press had nothing to read, so it must not have cost "
                       + "the writer their warm session")
        XCTAssertEqual(harness.spawns, 1, "…and nothing was spawned in its place")
        XCTAssertEqual(runner.sends.count, 1, "…and no turn was spent")
        guard case .nothingNew(let stateDocId, _) = harness.orchestrator.runState else {
            return XCTFail("expected the idle 'nothing new' variant, got "
                           + "\(harness.orchestrator.runState)")
        }
        XCTAssertEqual(stateDocId, docId)
    }

    /// **A cold read is briefed on no prior round, though its lane has one.**
    /// The round section would hand the model the last round's findings and
    /// ask it to compare — which is exactly what fresh eyes exists not to do.
    /// The lane and the number are minted normally: it is round N of the pass,
    /// and it says so on the record.
    func test_freshEyesIsBriefedOnNoPriorRoundThoughItsLaneHasOne() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(
            oneQuestion("Whose coat is on the chair?", about: "a1b2"))
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line")

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        XCTAssertEqual(harness.diagnostics.lastRun(docId: docId)?.round, 1)

        runner.nextEvent = .resultText(Self.fourEmptySections)
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId, freshEyes: true)
        awaitSends(2, on: runner)
        settle()

        let second = runner.sends[1].message
        XCTAssertFalse(second.contains("Round 1 of the \u{201C}line\u{201D} pass"),
                       "the cold read must be briefed on no prior round; got \(second)")
        XCTAssertFalse(second.contains("Whose coat is on the chair?"),
                       "…and on none of its findings; got \(second)")

        let run = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(run.passId, "line", "the lane is minted normally")
        XCTAssertEqual(run.round, 2, "…and so is the number")
        XCTAssertEqual(run.freshEyes, true, "…and the round says how it was read")
    }

    /// **The stamp reaches disk**, because the pane's header and every later
    /// build read a decoded file. An ordinary run writes no key at all, so
    /// "read cold" stays distinguishable from "never asked".
    func test_theFreshEyesStampReachesTheSidecar() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "line")
        let sidecar = DiagnosticsStore.sidecarURL(
            projectRoot: harness.root, docId: docId,
            device: DeviceSlug.make(from: "test-mac"))

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        let ordinary = try String(contentsOf: sidecar, encoding: .utf8) // adr-0018-ok: diagnostics sidecar, derived, not manuscript
        XCTAssertFalse(ordinary.contains("\"freshEyes\""),
                       "control: an ordinary run stamps no key; got \(ordinary)")

        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId, freshEyes: true)
        awaitSends(2, on: runner)
        settle()

        let cold = try String(contentsOf: sidecar, encoding: .utf8) // adr-0018-ok: diagnostics sidecar, derived, not manuscript
        XCTAssertTrue(cold.contains("\"freshEyes\":true"),
                      "the stamp never reached disk; got \(cold)")
    }

    /// **The next plain ⌘R is warm again and back on the marker.** A fresh
    /// read advances the marker exactly as any run does, so the keystroke
    /// after it reads the delta since the cold read — not the piece, and not
    /// nothing.
    func test_theRunAfterFreshEyesIsWarmAndBackOnTheMarker() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId, freshEyes: true)
        awaitSends(1, on: runner)
        settle()
        XCTAssertEqual(harness.spawns, 1)

        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()

        let second = runner.sends[1].message
        XCTAssertTrue(second.contains("It stayed."),
                      "the run after a cold read is an ordinary delta; got \(second)")
        XCTAssertFalse(second.contains("The fog came."),
                       "…measured from the marker the cold read advanced; got \(second)")
        XCTAssertTrue(second.contains("unchanged since last run"),
                      "…on the session the cold read spawned, which has read the "
                      + "briefing; got \(second)")
        XCTAssertEqual(harness.spawns, 1, "no second session was asked for")
    }

    /// The capsule says what this keystroke is doing, and it is not what ⌘R
    /// does — a cold read of the whole piece takes minutes where a delta takes
    /// seconds, and "Checking…" over it is the wrong promise.
    func test_freshEyesFlashesThatItIsReadingWhole() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId, freshEyes: true)
        awaitSends(1, on: runner)
        settle()

        XCTAssertEqual(harness.flashesSaid, [.freshEyes])
        XCTAssertEqual(CompilerOrchestrator.Acknowledgment.freshEyes.flashLabel,
                       "Reading whole\u{2026}")
    }

    /// **⌘⇧R while a run is in flight refuses exactly as ⌘R does** — and,
    /// sharper than the ordinary key, it must not reach the session on its way
    /// to refusing. A retire-first written above the guard would kill the turn
    /// the writer is waiting on.
    func test_freshEyesWhileARunIsInFlightRefusesAndTouchesNothing() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)

        harness.orchestrator.runRequested(docId: docId, freshEyes: true)
        settle()

        XCTAssertEqual(runner.sends.count, 1, "no second turn was started")
        XCTAssertEqual(runner.shutdowns, 0,
                       "the run in flight must survive a fresh-eyes press")
        XCTAssertEqual(harness.spawns, 1)
        XCTAssertEqual(harness.flashesSaid, [.started, .alreadyChecking],
                       "the refusal says what ⌘R's says")
        XCTAssertEqual(harness.orchestrator.runState, runningOnTheStandingReading)

        runner.release(.resultText(Self.fourEmptySections))
        settle()
    }

    /// **The AI toggle refuses both keys identically.** The toggle is enforced
    /// at the spawn (`ClaudeCLISession`), so a cold read that retired the warm
    /// session finds the same closed door — and must surface it the same way,
    /// rather than as a special failure of its own.
    func test_freshEyesWithTheToggleOffRefusesExactlyAsTheRunKeyDoes() throws {
        let ordinaryRunner = SpyRunner()
        ordinaryRunner.nextEvent = .failed(.disabledByToggle)
        let ordinary = try makeHarness(runner: ordinaryRunner, reading: standingReading())
        ordinary.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: ordinaryRunner)
        settle()

        let coldRunner = SpyRunner()
        coldRunner.nextEvent = .failed(.disabledByToggle)
        let cold = try makeHarness(runner: coldRunner, reading: standingReading())
        cold.orchestrator.runRequested(docId: docId, freshEyes: true)
        awaitSends(1, on: coldRunner)
        settle()

        let expected = try XCTUnwrap(failure(of: ordinary.orchestrator.runState),
                                     "control: the ordinary key surfaces the toggle")
        XCTAssertEqual(expected.failure, .disabledByToggle)
        let got = try XCTUnwrap(failure(of: cold.orchestrator.runState),
                                "the cold read must surface the same refusal")
        XCTAssertEqual(got.failure, expected.failure)
        XCTAssertEqual(got.docId, expected.docId)
        XCTAssertNil(cold.diagnostics.lastRun(docId: docId),
                     "a refused run records nothing, cold or warm")
    }

    // MARK: - The mint: one finding, one home (M4 P1 Task 3)

    /// The reader's report **as the mint writes it**: its two-valued kind
    /// travels in the body now that no pane draws a label above the row
    /// (M4 P1 review, Important 3).
    private static let mintedReaderBody =
        "Belief \u{2014} The reader stopped believing the fog."

    /// A turn carrying one continuity question and one reader report against
    /// the same live paragraph — the smallest answer that must land in TWO
    /// homes and does not.
    private func questionAndReport(about paragraphId: String) -> String {
        """
        {"section":"conformance","checks":[]}
        {"section":"continuity","questions":[{"cites":"the fog","refs":["\(paragraphId)"],"question":"Has anyone said how long yet?"}]}
        {"section":"reader","reports":[{"kind":"belief","refs":["\(paragraphId)"],"report":"The reader stopped believing the fog."}]}
        {"section":"facts","candidates":[]}
        """
    }

    /// A turn carrying one continuity question and one conformance strain — so
    /// the two halves of the split can be asserted against each other in one
    /// run rather than in two.
    private func questionAndStrain(about paragraphId: String) -> String {
        """
        {"section":"conformance","checks":[{"clause_quote":"Cold, and never wistful.","status":"strains","refs":["\(paragraphId)"],"what_pulls":"The last line reaches for a sigh."}]}
        {"section":"continuity","questions":[{"cites":"the fog","refs":["\(paragraphId)"],"question":"Has anyone said how long yet?"}]}
        {"section":"reader","reports":[]}
        {"section":"facts","candidates":[]}
        """
    }

    /// Poll until the document holds `count` open notes, or give up. The mint
    /// is an op-log append per note — real file I/O off this actor — so a fixed
    /// number of main-actor turns is a race rather than a wait.
    private func awaitOpenNotes(_ count: Int, on document: Document) async {
        let deadline = Date().addingTimeInterval(5)
        while document.annotations(filter: AnnotationFilter(statuses: [.open])).count < count,
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A grace long enough that a mint which was going to happen has happened —
    /// for the assertions whose subject is that NOTHING was written.
    private func awaitNothingMinted() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    /// Every op-log line this project has written, as raw text. The projection
    /// is convenient and the wire is the contract: a provenance field that is
    /// derived correctly and never serialised syncs to no other device.
    private func rawOpLog(under root: URL) throws -> String {
        let ops = root.appendingPathComponent(".maugham/ops")
        let files = try FileManager.default.contentsOfDirectory(at: ops, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "jsonl" }
            // adr-0018-ok: the op log itself, which is the source of truth
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined()
    }

    private func setActivePass(_ passId: String, on fx: LiveDocumentHarness) {
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: passId)
        }
    }

    /// **The task, end to end.** A run raises a continuity question and a
    /// reader's report; both leave the sidecar entirely and land on the open
    /// document as pass-stamped annotations, signed by the pass's own editor,
    /// carrying the run that wrote them on the wire.
    func test_continuityAndReaderMintAsPassStampedAnnotations() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("copyedit", on: fx)
        runner.nextEvent = .resultText(questionAndReport(about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)

        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
        XCTAssertEqual(notes.count, 2,
                       "a continuity question and a reader report must both mint "
                       + "\u{2014} got \(notes.map(\.body))")
        let question = try XCTUnwrap(
            notes.first { $0.body == "Has anyone said how long yet?" },
            "the continuity question never became a note")
        let report = try XCTUnwrap(
            notes.first { $0.body == Self.mintedReaderBody },
            "the reader's report never became a note")
        XCTAssertEqual(question.kind, .query,
                       "a question asks the writer something, and its reply is a "
                       + "decision \u{2014} that is what .query is")
        XCTAssertEqual(report.kind, .comment,
                       "a reader's report asks nothing, so it is not a query")
        XCTAssertEqual(question.paragraphId, pid,
                       "anchored at the first resolving ref, whole-paragraph")

        for note in [question, report] {
            XCTAssertEqual(note.author?.displayName, "Gould",
                           "the Copyedit pass's editor signs its round's notes "
                           + "\u{2014} the exact label IS the filter bucket")
            XCTAssertTrue(AnnotationAuthorPresentation.isClaude(note.author),
                          "a named editor is still Claude: every Claude "
                          + "affordance must keep applying to these notes")
            XCTAssertEqual(note.reviewPassId, "copyedit",
                           "the round's lane must stamp what it wrote")
            XCTAssertEqual(note.compilerRound, 1, "round 1 of the copyedit lane")
            XCTAssertNotNil(note.compilerFingerprint,
                            "a finding with an anchor has an identity, and the "
                            + "dedupe is what reads it back")
            XCTAssertTrue(note.isCompilerAuthored)
        }
        XCTAssertEqual(question.compilerRunId,
                       fx.diagnostics.lastRun(docId: "ch-1")?.id,
                       "the note and the report it was raised in must name the "
                       + "same check")

        // The wire, not the projection: a field derived correctly and never
        // serialised syncs to no other device.
        // **Values, not key presence** — a key carrying the wrong id or an
        // empty fingerprint would satisfy a presence check and would be exactly
        // the defect that matters: the dedupe compares the fingerprint, and a
        // reader joining a note to its run compares the id.
        let raw = try rawOpLog(under: fx.root)
        let runId = try XCTUnwrap(fx.diagnostics.lastRun(docId: "ch-1")?.id)
        XCTAssertTrue(raw.contains("\"compiler_run_id\":\"\(runId)\""),
                      "the op log must name the run that wrote the note, not "
                      + "merely carry the field")
        XCTAssertTrue(raw.contains("\"compiler_round\":1"),
                      "the round number never reached the op log")
        let questionFingerprint = try XCTUnwrap(question.compilerFingerprint)
        XCTAssertEqual(questionFingerprint, "continuity\u{1f}the fog\u{1f}\(pid)\u{1f}",
                       "the projected fingerprint is not the one spelling")
        // JSON-escaped, because U+001F is a control character on the wire.
        XCTAssertTrue(
            raw.contains("\"compiler_fingerprint\":\"continuity\\u001fthe fog\\u001f\(pid)\\u001f\""),
            "the fingerprint reached the op log with a different value than the "
            + "one the dedupe reads back")
        XCTAssertTrue(raw.contains("\"review_pass_id\":\"copyedit\""),
                      "the lane never reached the op log")
        XCTAssertFalse(raw.contains("\"compiler_fresh_eyes\""),
                       "a warm round stamps nothing rather than false")
    }

    /// A turn whose sixth section carries one anchored letter question — the
    /// smallest answer that must reach the queue through the letter rather
    /// than through continuity.
    private func oneLetterQuestion(_ question: String, about paragraphId: String) -> String {
        """
        {"section":"conformance","checks":[]}
        {"section":"continuity","questions":[]}
        {"section":"reader","reports":[]}
        {"section":"facts","candidates":[]}
        {"section":"intent_drift","verdict":"holds"}
        {"section":"letter","about":"A woman waits out a fog.",\
        "one_thing":"Let the fog do less of the work.",\
        "questions":[{"refs":["\(paragraphId)"],"question":"\(question)"}]}
        """
    }

    /// **The letter's question is an ordinary queue row from the moment it
    /// lands** (spec §3.2, editorial letter P1 Task 2). Through the production
    /// environment, on a live document, under an ASSIGNED stage — Perkins's
    /// structural lane, so the assertion is about what a pass gives a note and
    /// not about what an unassigned piece signs, which is a different task's
    /// question.
    ///
    /// What must be true: a `.query`, anchored at the ref it named, signed by
    /// that stage's editor, stamped with that stage's lane, carrying the run
    /// that raised it and a fingerprint the dedupe can read back. The run's
    /// own record keeps the letter beside it.
    func test_aLetterQuestionMintsAsAPassStampedQueryFromTheStageThatAskedIt() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("structural", on: fx)
        runner.nextEvent = .resultText(
            oneLetterQuestion("Whose fear is this, hers or the narrator\u{2019}s?", about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(1, on: fx.document)

        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
        XCTAssertEqual(notes.count, 1, "got \(notes.map(\.body))")
        let note = try XCTUnwrap(notes.first)
        XCTAssertEqual(note.body, "Whose fear is this, hers or the narrator\u{2019}s?")
        XCTAssertEqual(note.kind, .query,
                       "the letter asks and never suggests \u{2014} that is .query")
        XCTAssertEqual(note.paragraphId, pid, "anchored at the ref it named")
        XCTAssertEqual(note.author?.displayName, "Perkins",
                       "the Structural stage's editor signs the letter it wrote")
        XCTAssertEqual(note.reviewPassId, "structural",
                       "\u{2026}and that stage's lane stamps it")
        XCTAssertEqual(note.compilerRound, 1)
        XCTAssertTrue(note.isCompilerAuthored)
        XCTAssertEqual(note.compilerFingerprint,
                       "letterQuestion\u{1f}\u{1f}\(pid)\u{1f}",
                       "the letter's own kind is in the identity, or a coach's "
                       + "question and a continuity question about one paragraph "
                       + "would be the same finding")

        // The run keeps the letter itself: the question is in the queue, and
        // the prose around it is in the report.
        let run = try XCTUnwrap(fx.diagnostics.lastRun(docId: "ch-1"))
        XCTAssertEqual(run.letter?.about, "A woman waits out a fog.")
        XCTAssertEqual(run.letter?.oneThing, "Let the fog do less of the work.")
        XCTAssertEqual(run.letter?.questions.count, 1,
                       "the letter keeps its own copy for reading in place")
        XCTAssertEqual(note.compilerRunId, run.id)

        let rows = fx.diagnostics.live(docId: "ch-1", currentText: { fx.document.paragraph(id: $0) })
        XCTAssertEqual(rows, [],
                       "one finding has one home \u{2014} the letter's question "
                       + "must not also be a sidecar row")
    }

    /// **The dedupe reaches the letter too.** A second round re-raising the
    /// same question mints nothing: one open note before, one after.
    func test_aRepeatedLetterQuestionMintsNothingASecondTime() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("structural", on: fx)
        runner.nextEvent = .resultText(oneLetterQuestion("Whose fear is this?", about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(1, on: fx.document)
        XCTAssertEqual(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open])).count, 1,
            "control: the first round minted it")

        // The writer types, so the next \u{2318}R has a delta to read.
        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")
        try await fx.document.flushBurstNow()
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(2, on: runner)
        await awaitRound(2, on: fx)
        await awaitNothingMinted()

        XCTAssertEqual(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open])).count, 1,
            "the same question was minted twice \u{2014} the writer now has two "
            + "copies of a question they have not answered")
    }

    /// **The other half of the same commit: the sidecar.** The strain stays in
    /// the report; the question is nowhere in it, in memory or on disk. (The
    /// pane's own half is `DiagnosticsPaneTests`, mounted.)
    func test_theSidecarKeepsOnlyTheStrain() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("copyedit", on: fx)
        runner.nextEvent = .resultText(questionAndStrain(about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(1, on: fx.document)

        let rows = fx.diagnostics.live(docId: "ch-1", currentText: { paragraphId in
            fx.document.paragraph(id: paragraphId)
        })
        XCTAssertEqual(rows.map(\.kind), [.conformanceStrain],
                       "the sidecar must hold the strain and nothing else "
                       + "\u{2014} got \(rows.map { ($0.kind, $0.body) })")

        let sidecar = DiagnosticsStore.sidecarURL(
            projectRoot: fx.root, docId: "ch-1",
            device: DeviceSlug.make(from: "test-mac"))
        // adr-0018-ok: diagnostics sidecar, derived, not manuscript
        let persisted = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertFalse(persisted.contains("Has anyone said how long yet?"),
                       "the continuity question is on disk in the sidecar as "
                       + "well as in the op log \u{2014} two homes for one "
                       + "finding is exactly what this task closes")
        XCTAssertTrue(persisted.contains("The last line reaches for a sigh."),
                      "control: the strain really is in the file being read")
    }

    /// **One round is ONE event.** Two mints, one
    /// `.maughamAnnotationsChanged` — every receiver walks the whole project to
    /// answer it. Falsified by dropping `announcing: false` in the mint loop.
    func test_aRoundsMintsAnnounceExactlyOnce() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("copyedit", on: fx)
        runner.nextEvent = .resultText(questionAndReport(about: pid))

        var posts = 0
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamAnnotationsChanged, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)
        await awaitNothingMinted()

        XCTAssertEqual(posts, 1,
                       "two notes minted in one round posted \(posts) times; "
                       + "each post is a project-wide walk for one act")
    }

    /// **The dedupe backstop.** A second round re-raising the same question
    /// mints nothing: one open note before, one after.
    func test_aRepeatedQuestionMintsNothingASecondTime() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("copyedit", on: fx)
        runner.nextEvent = .resultText(questionAndReport(about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)
        XCTAssertEqual(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open])).count, 2,
            "control: the first round minted both")

        // The writer types, so the next \u{2318}R has a delta to read.
        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")
        try await fx.document.flushBurstNow()
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(2, on: runner)
        await awaitRound(2, on: fx)
        await awaitNothingMinted()

        XCTAssertEqual(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open])).count, 2,
            "the same two findings were minted a second time \u{2014} the writer "
            + "now has two copies of a question they have not answered")

        // **The control for #42 F-H.** A re-raise in the round's OWN lane is
        // already spoken for: the note is in the queue the writer is working,
        // and the line calls it *persisting*. Counting it a second time as
        // "was already open in another lane" would say one finding is two.
        XCTAssertEqual(fx.diagnostics.lastRun(docId: "ch-1")?.openInOtherLanes, 0)
        XCTAssertEqual(
            RoundNarrative.sinceLastRoundLine(
                history: fx.diagnostics.roundHistory(docId: "ch-1"),
                run: fx.diagnostics.lastRun(docId: "ch-1"),
                annotations: fx.document.annotations(filter: AnnotationFilter(statuses: nil))),
            "Since round 1: 0 resolved \u{00b7} 2 persisting \u{00b7} 0 new",
            "a same-lane re-raise adds no clause to the line")
    }

    /// **The load-bearing path.** \u{2318}\u{21e7}R is briefed on no prior round
    /// by design, so it re-raises everything it still finds true. Without the
    /// backstop every cold reread doubles the writer's open notes.
    func test_freshEyesReRaisingAQuestionMintsNothingNew() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("copyedit", on: fx)
        runner.nextEvent = .resultText(questionAndReport(about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)

        fx.orchestrator.runRequested(docId: "ch-1", freshEyes: true)
        await awaitSends(2, on: runner)
        await awaitNothingMinted()

        XCTAssertEqual(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open])).count, 2,
            "a cold reread minted a second copy of every open finding")
    }

    /// **Only OPEN notes block.** A finding the writer resolved and prose that
    /// still reads the same way is news again, not an echo.
    func test_aResolvedNoteDoesNotBlockTheSameFindingComingBack() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("copyedit", on: fx)
        runner.nextEvent = .resultText(questionAndReport(about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)
        for note in fx.document.annotations(filter: AnnotationFilter(statuses: [.open])) {
            try await fx.document.archiveAnnotation(id: note.id)
        }
        XCTAssertEqual(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open])).count, 0,
            "control: the writer dealt with both")

        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")
        try await fx.document.flushBurstNow()
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(2, on: runner)
        await awaitOpenNotes(2, on: fx.document)

        XCTAssertEqual(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open])).count, 2,
            "a resolved note blocked the same finding from being raised again "
            + "\u{2014} the dedupe is a backstop against duplicates, not a "
            + "memory of what the writer has already seen")
    }

    /// A \u{2318}R outside every pass signs "Claude" \u{2014} M2's identity,
    /// and the bucket the writer already has \u{2014} and stamps no lane.
    ///
    /// **This is the VACATED-SEAT case now** (editorial letter P1 Task 5). An
    /// unassigned piece is the coach's by default, so "outside every pass"
    /// means the writer took the one off switch there is: `coachVacated`. What
    /// it asserts is unchanged, because the whole point of vacating is that
    /// the run goes back to being exactly M2's.
    func test_aPasslessRunMintsAsClaudeWithNoStamp() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        try await fx.store.setCoachVacated(true)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        runner.nextEvent = .resultText(questionAndReport(about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)

        for note in fx.document.annotations(filter: AnnotationFilter(statuses: [.open])) {
            XCTAssertEqual(note.author?.displayName, "Claude")
            XCTAssertNil(note.reviewPassId, "a passless run stamps no lane")
            XCTAssertNil(note.compilerRound,
                         "…and mints no round number rather than round 1 of nothing")
            XCTAssertTrue(note.isCompilerAuthored,
                          "it is still the compiler's note: the run id says so")
        }
    }

    /// **An unassigned piece is the coach's, and her rounds are numbered**
    /// (spec \u{00a7}4.1, "Rounds"). The passless lane used to mean "nobody
    /// read this"; with the seat held it means Le Guin, and she files into her
    /// own lane through the machinery a stage run already uses \u{2014} no
    /// orchestrator change buys the round number, the stamp and the byline.
    func test_anUnassignedPieceRunsAsTheCoachAndFilesInHerLane() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        XCTAssertFalse(fx.store.manifest.coachVacated,
                       "premise: a new project holds the seat")
        let pid = try XCTUnwrap(fx.document.sequence.first)
        runner.nextEvent = .resultText(questionAndReport(about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)

        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
        XCTAssertEqual(notes.count, 2, "control: the round minted both findings")
        for note in notes {
            XCTAssertEqual(note.author?.displayName, "Le Guin",
                           "the mint context's editorName is the resolution's, so "
                           + "an unassigned piece's notes are signed by the coach")
            XCTAssertEqual(note.reviewPassId, "workshop",
                           "\u{2026}and stamped with her lane, not left unstamped")
            XCTAssertEqual(note.compilerRound, 1,
                           "\u{2026}and numbered, which the nil lane never was")
        }
        XCTAssertEqual(fx.diagnostics.lastRun(docId: "ch-1")?.passId, "workshop",
                       "the run record files in the coach's lane")
        XCTAssertEqual(fx.diagnostics.lastRun(docId: "ch-1")?.round, 1)

        // The writer types, so the next \u{2318}R has a delta to read.
        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")
        try await fx.document.flushBurstNow()
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(2, on: runner)
        await awaitRound(2, on: fx)
        XCTAssertEqual(fx.diagnostics.lastRun(docId: "ch-1")?.round, 2,
                       "her second reading is round 2 \u{2014} the since-line and "
                       + "\"Le Guin \u{00b7} round 2\" exist because of this")
        XCTAssertEqual(fx.diagnostics.lastRun(docId: "ch-1")?.passId, "workshop")
    }

    /// **A mint that fails costs one note and never the run.** The writer
    /// deletes the paragraph between the parse and the append; that note is
    /// dropped, the other is written, and the check still finishes.
    func test_aFailedMintDropsItsNoteAndTheRunStillSucceeds() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(
            runner: runner, initialProse: "The fog came.\n\nIt stayed.\n")
        let doomed = try XCTUnwrap(fx.document.sequence.first)
        let survivor = try XCTUnwrap(fx.document.sequence.last)
        XCTAssertNotEqual(doomed, survivor, "premise: two paragraphs")
        let answer = """
            {"section":"conformance","checks":[]}
            {"section":"continuity","questions":[{"cites":"the fog","refs":["\(doomed)"],"question":"Has anyone said how long yet?"}]}
            {"section":"reader","reports":[{"kind":"belief","refs":["\(survivor)"],"report":"The reader stopped believing the fog."}]}
            {"section":"facts","candidates":[]}
            """
        // Held open, so the writer can delete the paragraph while the turn is
        // out — the real window between the parse and the append.
        runner.nextEvent = nil

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        fx.document.setFullText("It stayed.\n")
        runner.release(.resultText(answer))
        await awaitOpenNotes(1, on: fx.document)
        await awaitNothingMinted()

        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
        XCTAssertEqual(notes.map(\.body), [Self.mintedReaderBody],
                       "the note whose paragraph survived must be written and the "
                       + "other dropped \u{2014} got \(notes.map(\.body))")
        XCTAssertEqual(fx.orchestrator.runState, .idle,
                       "a note that could not be written is not a failed check")
        XCTAssertNotNil(fx.diagnostics.lastRun(docId: "ch-1"),
                        "…and the run still recorded")
    }

    /// **A run that never finished mints nothing.** Preview persists nothing,
    /// and a cancelled check must not leave findings the writer has to dismiss.
    func test_aCancelledStreamingRunMintsNothing() async throws {
        let runner = SpyRunner()
        runner.nextEvent = nil
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("copyedit", on: fx)

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        let sections = questionAndReport(about: pid).components(separatedBy: "\n")
        runner.stream(sections[1] + "\n")
        runner.stream(sections[2] + "\n")

        fx.orchestrator.cancel()
        await awaitNothingMinted()

        XCTAssertEqual(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open])), [],
            "a streamed section minted a note before its run finished \u{2014} a "
            + "cancel then leaves the writer notes from a check that stopped "
            + "reading half way through")
    }

    // MARK: - The mint's edges (M4 P1 review)

    /// Two findings that name no paragraph at all — the schema permits an
    /// entry with no refs, and both sections can produce one.
    private func anchorlessFindings() -> String {
        """
        {"section":"conformance","checks":[]}
        {"section":"continuity","questions":[{"refs":[],"question":"The outline promised a scene that never got written."}]}
        {"section":"reader","reports":[{"refs":[],"report":"The piece ends before it lands."}]}
        {"section":"facts","candidates":[]}
        """
    }

    /// **An anchorless finding is a whole-piece observation, and it survives**
    /// (M4 P1 review, Important 2).
    ///
    /// `.query` and `.comment` are paragraph-scoped and `addAnnotation` refuses
    /// either with a nil id, so minting them as such put every note ABOUT THE
    /// PIECE straight into the failure arm — silently, because the arm's whole
    /// job is not to fail the run. A doc-scoped craft note is what that
    /// observation is.
    func test_anAnchorlessFindingMintsAsADocScopedCraftNote() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        setActivePass("copyedit", on: fx)
        runner.nextEvent = .resultText(anchorlessFindings())

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)

        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
        XCTAssertEqual(notes.count, 2,
                       "an anchorless question and an anchorless report were "
                       + "destroyed on their way out; got \(notes.map(\.body))")
        XCTAssertEqual(Set(notes.map(\.kind)), [.craftNote],
                       "both must be doc-scoped craft notes \u{2014} the only kind "
                       + "the annotation layer will hold without a paragraph")
        XCTAssertEqual(notes.compactMap(\.paragraphId), [],
                       "…and none of them invented an anchor")
        XCTAssertEqual(
            Set(notes.map(\.body)),
            ["The outline promised a scene that never got written.",
             "The piece ends before it lands."])
        for note in notes {
            XCTAssertEqual(note.author?.displayName, "Gould",
                           "a craft note is still this round's note")
            XCTAssertEqual(note.reviewPassId, "copyedit")
            XCTAssertTrue(note.isCompilerAuthored)
        }
    }

    /// **The reader's two kinds are two findings on one paragraph** (M4 P1
    /// review, Important 3) — and the label the pane used to draw above the row
    /// travels in the body, because no pane draws it now.
    func test_theReadersTwoKindsBothMintAndCarryTheirLabel() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("copyedit", on: fx)
        runner.nextEvent = .resultText("""
            {"section":"conformance","checks":[]}
            {"section":"continuity","questions":[]}
            {"section":"reader","reports":[{"kind":"dream_break","refs":["\(pid)"],"report":"The spell breaks at the semicolon."},
                                           {"kind":"belief","refs":["\(pid)"],"report":"The reader stopped believing the fog."}]}
            {"section":"facts","candidates":[]}
            """)

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)

        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
        XCTAssertEqual(notes.count, 2,
                       "two reader kinds on one paragraph collapsed into one "
                       + "finding, and the dedupe threw the second away; got "
                       + "\(notes.map(\.body))")
        XCTAssertEqual(
            Set(notes.map(\.body)),
            ["Dream break \u{2014} The spell breaks at the semicolon.",
             "Belief \u{2014} The reader stopped believing the fog."],
            "the reader's own kind must reach the writer \u{2014} it is content, "
            + "and the row that used to render it above the note is gone")
        XCTAssertEqual(Set(notes.compactMap(\.compilerFingerprint)).count, 2,
                       "…and the two must be distinguishable to the dedupe")
    }

    /// A model that raises the SAME reader kind twice on one paragraph is one
    /// finding, which is the rule the category refines rather than replaces.
    func test_theSameReaderKindTwiceOnOneParagraphMintsOnce() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        runner.nextEvent = .resultText("""
            {"section":"conformance","checks":[]}
            {"section":"continuity","questions":[]}
            {"section":"reader","reports":[{"kind":"belief","refs":["\(pid)"],"report":"She is not believable here."},
                                           {"kind":"belief","refs":["\(pid)"],"report":"I did not believe her."}]}
            {"section":"facts","candidates":[]}
            """)

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(1, on: fx.document)
        await awaitNothingMinted()

        XCTAssertEqual(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open])).count, 1,
            "the model rewording one finding is one finding")
    }

    /// **A cold reread that finds something NEW mints it, stamped as cold**
    /// (M4 P1 review, Minor 7). The dedupe protects the writer from duplicates;
    /// it must not protect them from news.
    func test_freshEyesMintsANewFindingAndStampsItselfOnTheWire() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("proof", on: fx)
        runner.nextEvent = .resultText(questionAndReport(about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)

        // A cold read, raising a question the warm round never asked: a
        // different `cites` is a different finding, so nothing dedupes it away.
        runner.nextEvent = .resultText("""
            {"section":"conformance","checks":[]}
            {"section":"continuity","questions":[{"cites":"the coat","refs":["\(pid)"],"question":"Whose coat is on the chair?"}]}
            {"section":"reader","reports":[]}
            {"section":"facts","candidates":[]}
            """)
        fx.orchestrator.runRequested(docId: "ch-1", freshEyes: true)
        await awaitSends(2, on: runner)
        await awaitOpenNotes(3, on: fx.document)

        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
        let cold = try XCTUnwrap(notes.first { $0.body == "Whose coat is on the chair?" },
                                 "the cold read's new question never minted")
        XCTAssertEqual(cold.author?.displayName, "Argus", "the Proof pass's editor")
        XCTAssertEqual(cold.compilerRound, 2, "round 2 of the proof lane")

        let raw = try rawOpLog(under: fx.root)
        XCTAssertTrue(raw.contains("\"compiler_fresh_eyes\":true"),
                      "a cold round must say so on the wire \u{2014} it is the one "
                      + "fact about the run that a reader of the note cannot "
                      + "otherwise recover")
    }

    // MARK: - Since last round, off the queue (M4 P1 Task 5)

    /// Poll until the standing run for `ch-1` is the round expected, or give up.
    /// A finish is file I/O off this actor, so a fixed number of main-actor
    /// turns is a race rather than a wait — `awaitOpenNotes`' reasoning, for a
    /// run whose whole point is that it mints NOTHING.
    private func awaitRound(_ round: Int, on fx: LiveDocumentHarness) async {
        let deadline = Date().addingTimeInterval(5)
        while fx.diagnostics.lastRun(docId: "ch-1")?.round != round, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// **The whole loop, end to end.** Round 1 raises two findings; the writer
    /// stets one; round 2 re-raises the other in different words and finds
    /// nothing else. The line the pane draws is the writer's own account of
    /// that: one settled, one still in front of them, nothing new.
    ///
    /// The re-raise is the sharp half. The model rewords a finding every time
    /// it raises it, so the note is DEDUPED at the mint rather than minted
    /// again — and a line that counted the model's answer instead of the queue
    /// would call the same question one resolved plus one new, every round,
    /// forever.
    func test_theSinceLastRoundLineCountsWhatTheWriterSettled() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("copyedit", on: fx)

        runner.nextEvent = .resultText(questionAndReport(about: pid))
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)
        XCTAssertEqual(fx.diagnostics.lastRun(docId: "ch-1")?.round, 1)

        // The writer reads the reader's report and lets the words stand.
        let report = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
                .first { $0.body == Self.mintedReaderBody })
        try await fx.document.stetAnnotation(id: report.id)

        // …and writes on, because a ⌘R with nothing new is not a round at all
        // (`beginRun`'s empty-delta guard) — the writer's own paragraph, typed
        // through the burst the run closes for itself.
        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")

        // Round 2 raises the same continuity question in different words, and
        // nothing else.
        runner.nextEvent = .resultText("""
            {"section":"conformance","checks":[]}
            {"section":"continuity","questions":[{"cites":"the fog","refs":["\(pid)"],"question":"How long has the fog been sitting there?"}]}
            {"section":"reader","reports":[]}
            {"section":"facts","candidates":[]}
            """)
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(2, on: runner)
        await awaitRound(2, on: fx)
        await awaitNothingMinted()

        let queue = fx.document.annotations(filter: AnnotationFilter(statuses: nil))
        XCTAssertEqual(queue.filter(\.isCompilerAuthored).count, 2,
                       "the reworded re-raise minted a second copy of a question "
                       + "the writer is already holding; got \(queue.map(\.body))")

        XCTAssertEqual(
            RoundNarrative.sinceLastRoundLine(
                history: fx.diagnostics.roundHistory(docId: "ch-1"),
                run: fx.diagnostics.lastRun(docId: "ch-1"),
                annotations: queue),
            "Since round 1: 1 resolved \u{00b7} 1 persisting \u{00b7} 0 new")
    }

    /// Poll until the standing run for `ch-1` is one this test has not seen
    /// before. **`awaitRound` cannot serve a test that switches lanes**: round
    /// numbers are per pass, so a Structural round 1 and a Line round 1 are
    /// both `round == 1` and the wait would fall through the instant the
    /// keystroke was pressed. The run's own id is what actually changes.
    private func awaitRunAfter(
        _ previous: String?, on fx: LiveDocumentHarness
    ) async -> CompilerRun? {
        let deadline = Date().addingTimeInterval(5)
        while fx.diagnostics.lastRun(docId: "ch-1")?.id == previous, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return fx.diagnostics.lastRun(docId: "ch-1")
    }

    /// **A finding already open in another lane is counted, not silently
    /// dropped** (#42 F-H). Structural raises a question and mints it; the
    /// writer moves the piece to Line, and Line's rounds keep finding the same
    /// thing. The mint refuses a second copy — one finding is one note, and
    /// which lane raised it first does not make it two — so the Line lane's own
    /// counts are all zero and, without this, the report read "0 resolved
    /// \u{00b7} 0 persisting \u{00b7} 0 new" over a round that engaged the
    /// question every time.
    ///
    /// The lane is what makes it a different case from a same-lane re-raise:
    /// that one is already spoken for as *persisting*, and the writer can see
    /// the note in the queue they are working. A note in another pass's lane is
    /// one they cannot see from here at all.
    func test_aFindingRaisedAgainInAnotherLaneIsCountedOnTheSinceLine() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)

        // Round 1 of Structural raises it, and Perkins signs the one note.
        setActivePass("structural", on: fx)
        runner.nextEvent = .resultText(
            oneQuestion("Has anyone said how long yet?", about: pid))
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(1, on: fx.document)
        let structuralRun = await awaitRunAfter(nil, on: fx)
        let structural = try XCTUnwrap(structuralRun)
        XCTAssertEqual(structural.passId, "structural")
        XCTAssertEqual(structural.round, 1)
        XCTAssertEqual(structural.openInOtherLanes, 0,
                       "control: nothing was open anywhere when it minted")

        // The writer moves the piece to the Line pass and writes on.
        setActivePass("line", on: fx)
        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")
        runner.nextEvent = .resultText(
            oneQuestion("How long has the fog been sitting there?", about: pid))
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(2, on: runner)
        let lineOneRun = await awaitRunAfter(structural.id, on: fx)
        let lineOne = try XCTUnwrap(lineOneRun)
        XCTAssertEqual(lineOne.passId, "line")
        XCTAssertEqual(lineOne.round, 1, "the Line lane starts its own count")
        XCTAssertEqual(lineOne.mintedNotes, 0, "the dedupe refused a second copy")
        XCTAssertEqual(lineOne.openInOtherLanes, 1,
                       "the round engaged a question open in the Structural "
                       + "lane and recorded nothing about it")

        // Round 2 of Line, still finding the same thing — the first round of a
        // lane has nothing behind it, so this is the first round that draws a
        // line at all.
        fx.document.setFullText(
            "The fog came.\n\nIt stayed for three days.\n\nThen it lifted.")
        runner.nextEvent = .resultText(
            oneQuestion("Is the fog's duration ever established?", about: pid))
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(3, on: runner)
        let lineTwoRun = await awaitRunAfter(lineOne.id, on: fx)
        let lineTwo = try XCTUnwrap(lineTwoRun)
        XCTAssertEqual(lineTwo.round, 2)
        await awaitNothingMinted()

        let queue = fx.document.annotations(filter: AnnotationFilter(statuses: nil))
        let notes = queue.filter(\.isCompilerAuthored)
        XCTAssertEqual(notes.count, 1,
                       "one finding is one note across lanes; got \(notes.map(\.body))")
        XCTAssertEqual(notes.first?.reviewPassId, "structural",
                       "\u{2026}and it stays in the lane that raised it")

        XCTAssertEqual(
            RoundNarrative.sinceLastRoundLine(
                history: fx.diagnostics.roundHistory(docId: "ch-1"),
                run: fx.diagnostics.lastRun(docId: "ch-1"),
                annotations: queue),
            "Since round 1: 0 resolved \u{00b7} 0 persisting \u{00b7} 0 new "
            + "\u{00b7} 1 was already open in another lane")
    }

    /// **One fingerprint, two OPEN notes, two lanes — and a round in EITHER of
    /// those lanes must not count its own persisting note as somebody else's**
    /// (review fix, #42).
    ///
    /// The state is reachable through nothing but the writer's own verbs,
    /// which is why it needs pinning: only OPEN notes block the mint, so a
    /// rejected note stops blocking, the next lane's round mints a second note
    /// under the same fingerprint, and Reopen puts the first one back.
    /// `reopenAnnotation` has no fingerprint-collision guard and should not
    /// grow one — reopening is the writer taking a note back, not a claim
    /// about any other note.
    ///
    /// **Both holding lanes are asserted, and that is what makes this a
    /// falsifier rather than a coincidence.** A single-valued fingerprint→lane
    /// map keeps exactly one of the two, and which one it keeps is an accident
    /// of the order `annotations(filter:)` happens to return: whichever it
    /// kept, the round in the OTHER lane would read a foreign lane back and
    /// report its own persisting note as "was already open in another lane" — counted
    /// twice, once on each side of the same sentence. Asserting only one of the
    /// two lanes would pass on the broken code half the time.
    ///
    /// The third round is the mirror: a lane holding neither counts ONE, not
    /// two. Two notes, one finding.
    func test_aFindingOpenInTwoLanesAtOnceIsCountedOnceAndNeverFromItsOwnLane() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        let fingerprint = "continuity\u{1f}the fog\u{1f}\(pid)\u{1f}"

        // Structural round 1 raises the finding and mints it.
        setActivePass("structural", on: fx)
        runner.nextEvent = .resultText(
            oneQuestion("Has anyone said how long yet?", about: pid))
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(1, on: fx.document)
        let structuralOneRecord = await awaitRunAfter(nil, on: fx)
        let structuralOne = try XCTUnwrap(structuralOneRecord)
        let first = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open])).first)
        XCTAssertEqual(first.compilerFingerprint, fingerprint,
                       "precondition: the fixture's fingerprint is the one spelling")

        // The writer rejects it, so nothing open holds the fingerprint any more.
        try await fx.document.rejectAnnotation(id: first.id)
        XCTAssertEqual(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open])).count, 0,
            "precondition: the dedupe has nothing left to refuse against")

        // A Line round raises the same finding and mints a SECOND note under
        // the same fingerprint — correctly, on the rule that a resolved note
        // does not block a finding coming back.
        setActivePass("line", on: fx)
        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")
        runner.nextEvent = .resultText(
            oneQuestion("How long has the fog been sitting there?", about: pid))
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(2, on: runner)
        await awaitOpenNotes(1, on: fx.document)
        let lineOneRecord = await awaitRunAfter(structuralOne.id, on: fx)
        let lineOne = try XCTUnwrap(lineOneRecord)
        XCTAssertEqual(lineOne.mintedNotes, 1, "precondition: the Line lane minted its own")

        // …and the writer takes the first one back. Two open notes, one
        // fingerprint, two lanes — the state this test exists for.
        try await fx.document.reopenAnnotation(id: first.id)
        let open = fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
        XCTAssertEqual(open.count, 2)
        XCTAssertEqual(Set(open.compactMap(\.compilerFingerprint)), [fingerprint])
        XCTAssertEqual(Set(open.map(\.reviewPassId)), ["structural", "line"])

        // **Structural round 2: its own lane holds one of the two.**
        setActivePass("structural", on: fx)
        fx.document.setFullText(
            "The fog came.\n\nIt stayed for three days.\n\nThen it lifted.")
        runner.nextEvent = .resultText(
            oneQuestion("Is the fog's duration ever established?", about: pid))
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(3, on: runner)
        let structuralTwoRecord = await awaitRunAfter(lineOne.id, on: fx)
        let structuralTwo = try XCTUnwrap(structuralTwoRecord)
        await awaitNothingMinted()
        XCTAssertEqual(structuralTwo.round, 2)
        XCTAssertEqual(structuralTwo.openInOtherLanes, 0,
                       "the Structural lane holds one of the two notes, so the "
                       + "finding is not open somewhere this writer cannot see")
        XCTAssertEqual(
            RoundNarrative.sinceLastRoundLine(
                history: fx.diagnostics.roundHistory(docId: "ch-1"),
                run: structuralTwo,
                annotations: fx.document.annotations(filter: AnnotationFilter(statuses: nil))),
            "Since round 1: 0 resolved \u{00b7} 1 persisting \u{00b7} 0 new",
            "counted once, as persisting, with no cross-lane clause beside it")

        // **Line round 2: so does its own lane.** The other half of the same
        // claim — and the half that fails whenever the single-valued map kept
        // "structural" rather than "line".
        setActivePass("line", on: fx)
        fx.document.setFullText(
            "The fog came.\n\nIt stayed for three days.\n\nThen it lifted.\n\nBriefly.")
        runner.nextEvent = .resultText(
            oneQuestion("Does the piece ever fix the fog's duration?", about: pid))
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(4, on: runner)
        let lineTwoRecord = await awaitRunAfter(structuralTwo.id, on: fx)
        let lineTwo = try XCTUnwrap(lineTwoRecord)
        await awaitNothingMinted()
        XCTAssertEqual(lineTwo.round, 2)
        XCTAssertEqual(lineTwo.openInOtherLanes, 0,
                       "the Line lane holds the other of the two notes")
        XCTAssertEqual(
            RoundNarrative.sinceLastRoundLine(
                history: fx.diagnostics.roundHistory(docId: "ch-1"),
                run: lineTwo,
                annotations: fx.document.annotations(filter: AnnotationFilter(statuses: nil))),
            "Since round 1: 0 resolved \u{00b7} 1 persisting \u{00b7} 0 new")

        // **The mirror: a lane holding neither counts ONE, not two.** Both open
        // notes match, and they are one finding.
        setActivePass("proof", on: fx)
        fx.document.setFullText(
            "The fog came.\n\nIt stayed for three days.\n\nThen it lifted.\n\n"
            + "Briefly.\n\nNobody wrote it down.")
        runner.nextEvent = .resultText(
            oneQuestion("Is the duration established anywhere?", about: pid))
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(5, on: runner)
        let proofRecord = await awaitRunAfter(lineTwo.id, on: fx)
        let proof = try XCTUnwrap(proofRecord)
        await awaitNothingMinted()
        XCTAssertEqual(proof.openInOtherLanes, 1,
                       "two notes hold this fingerprint, but they are one "
                       + "finding \u{2014} the count is of findings, which is "
                       + "what the sentence it feeds says")
        XCTAssertEqual(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open])).count, 2,
            "and no round minted a third copy")
    }

    /// **A Cancel inside the mint window leaves the stale finish nothing to
    /// write** (M4 P1 review, Minor 6).
    ///
    /// The mint is `finish`'s one suspension and the only one this class
    /// resumes from with writes still to do. Without the generation re-check,
    /// a Cancel (which bumps the generation and goes idle) followed by a ⌘R
    /// would have the abandoned turn stamp `sentBriefing` and `runState` over
    /// a live run: a new session told it had already been briefed, and a check
    /// still going called finished.
    func test_aCancelInsideTheMintWindowAbandonsTheRest() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText(oneQuestion("Two beats, not three?", about: "a1b2"))
        let gate = PrepareGate()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), holdMint: gate)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        XCTAssertEqual(gate.entries, 1, "precondition: the run is suspended in its mint")
        XCTAssertNil(harness.diagnostics.lastRun(docId: docId),
                     "precondition: nothing is recorded until the mint returns")

        harness.orchestrator.cancel()
        gate.release()
        settle()

        XCTAssertNil(harness.diagnostics.lastRun(docId: docId),
                     "the abandoned turn recorded its run anyway")
        XCTAssertNil(harness.diagnostics.lastOpId(docId: docId),
                     "\u{2026}and moved the marker, so the prose it stopped "
                     + "checking is never checked again")
        XCTAssertEqual(harness.orchestrator.runState, .idle)
    }

    // MARK: - The briefing carries the lane and the writer (M4 P1 Task 4)

    /// **The named editor and their doctrine reach the wire.** The pass is
    /// resolved once, at the keystroke, and the same value that signs the
    /// round's notes is what frames the model reading them.
    func test_thePassesEditorAndBriefReachTheMessage() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), activePass: "copyedit")

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let message = runner.sends[0].message
        XCTAssertTrue(message.contains("You are Gould"),
                      "the Copyedit lane's editor never framed the round; got \(message)")
        let brief = try XCTUnwrap(ReviewPass.presets.first { $0.id == "copyedit" }?.brief)
        XCTAssertTrue(message.contains(brief),
                      "the pass's brief never reached the model; got \(message)")
    }

    /// A passless \u{2318}R is M2's all-altitudes check and says so by saying
    /// nothing: no editor, no register, no brief.
    func test_aPasslessRunIsFramedByNoEditor() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertFalse(runner.sends[0].message.contains("You are "),
                       "got \(runner.sends[0].message)")
    }

    /// A turn carrying all three kinds — a question and a report that mint as
    /// notes, and a strain that stays in the sidecar so the NEXT round has a
    /// previous round to be briefed on.
    private func questionReportAndStrain(about paragraphId: String) -> String {
        """
        {"section":"conformance","checks":[{"clause_quote":"Cold, and never wistful.","status":"strains","refs":["\(paragraphId)"],"what_pulls":"The last line reaches for a sigh."}]}
        {"section":"continuity","questions":[{"cites":"the fog","refs":["\(paragraphId)"],"question":"Has anyone said how long yet?"}]}
        {"section":"reader","reports":[{"kind":"belief","refs":["\(paragraphId)"],"report":"The reader stopped believing the fog."}]}
        {"section":"facts","candidates":[]}
        """
    }

    /// **The writer's answer reaches the next round** — end to end, through the
    /// annotation layer rather than through anything the compiler kept.
    ///
    /// Run 1 raises a question and a report; the writer rejects the report in
    /// their own words and leaves the question standing. Run 2 must be told
    /// both facts, and told them differently: the standing one is live and
    /// must not be re-raised as news, the settled one is answered and must not
    /// be raised at all.
    func test_theWritersDispositionsReachTheNextRoundsBriefing() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("copyedit", on: fx)
        runner.nextEvent = .resultText(questionReportAndStrain(about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)

        let report = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
                .first { $0.body == Self.mintedReaderBody },
            "precondition: the reader's report minted")
        try await fx.document.rejectAnnotation(
            id: report.id, userResponse: "The fog is deliberately unmeasured.")

        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")
        runner.nextEvent = .resultText(Self.fourEmptySections)
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(2, on: runner)
        await settle()

        let second = runner.sends[1].message
        XCTAssertTrue(second.contains(CompilerPrompt.standingNotesHeading), second)
        XCTAssertTrue(second.contains("Has anyone said how long yet?"),
                      "the note still in the writer's queue must be briefed as "
                      + "standing, or the round raises it again as news; got \(second)")
        XCTAssertTrue(second.contains(CompilerPrompt.settledNotesHeading), second)
        XCTAssertTrue(second.contains("REJECTED: The fog is deliberately unmeasured."),
                      "the writer's own reason is what stops the finding coming "
                      + "back; got \(second)")
        XCTAssertTrue(second.contains("The reader stopped believing the fog."),
                      "\u{2026}and the model needs to know WHICH finding was "
                      + "answered; got \(second)")
        XCTAssertTrue(second.contains("raised these notes"),
                      "control: the round section is here too, so the fresh-eyes "
                      + "test's absences mean something")
    }

    /// **The one-gesture decline reaches the next round's briefing** (M4 P2
    /// Task 1, spec §7.0).
    ///
    /// Author's wet-ink view declines a note with **Not this** and asks for
    /// nothing — the reason-carrying decline is Review's queue's. So the
    /// disposition arrives here with a verdict and no words, and the briefing
    /// has to carry it on the excerpt alone: the model must recognise the
    /// finding it may not raise again from its own earlier prose, with nothing
    /// of the writer's beside it.
    ///
    /// End to end, through the annotation layer's own reject — the same verb
    /// `DiagnosticsPane`'s **Not this** presses, with the `userResponse` the
    /// one-gesture rule leaves nil.
    func test_aReasonlessDeclineReachesTheNextRoundsBriefingAsSettled() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("copyedit", on: fx)
        runner.nextEvent = .resultText(questionReportAndStrain(about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)

        let report = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
                .first { $0.body == Self.mintedReaderBody },
            "precondition: the reader's report minted")
        // Not this: no reason, no field, nothing asked.
        try await fx.document.rejectAnnotation(id: report.id)

        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")
        runner.nextEvent = .resultText(Self.fourEmptySections)
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(2, on: runner)
        await settle()

        let second = runner.sends[1].message
        XCTAssertTrue(second.contains(CompilerPrompt.settledNotesHeading), second)
        XCTAssertTrue(
            second.contains("\(Self.mintedReaderBody) [REJECTED]"),
            "a decline with no words must still name the finding it settled and "
            + "say what became of it; got \(second)")
        XCTAssertFalse(second.contains("[REJECTED:"),
                       "\u{2026}and must not invent a reason the writer never "
                       + "gave; got \(second)")
    }

    /// **Cold means cold.** A fresh-eyes reread is briefed on no prior round
    /// and no dispositions — the whole point is a reader who has not seen this
    /// piece before. The editor's own identity survives: Argus is still a
    /// proofreader, and the dedupe backstop is what stops the duplicates.
    func test_freshEyesIsBriefedOnNeitherTheRoundNorTheDispositions() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        setActivePass("copyedit", on: fx)
        runner.nextEvent = .resultText(questionReportAndStrain(about: pid))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await awaitOpenNotes(2, on: fx.document)

        runner.nextEvent = .resultText(Self.fourEmptySections)
        fx.orchestrator.runRequested(docId: "ch-1", freshEyes: true)
        await awaitSends(2, on: runner)
        await settle()

        let second = runner.sends[1].message
        XCTAssertFalse(second.contains(CompilerPrompt.standingNotesHeading), second)
        XCTAssertFalse(second.contains(CompilerPrompt.settledNotesHeading), second)
        XCTAssertFalse(second.contains("Has anyone said how long yet?"), second)
        XCTAssertFalse(second.contains("raised these notes"), second)
        XCTAssertTrue(second.contains("You are Gould"),
                      "a cold reader is still this pass's editor; got \(second)")
    }

    // MARK: - The letter's scene position (editorial letter P1 Task 3)

    /// A turn whose sixth section carries a letter and nothing else worth
    /// minting — the smallest answer that produces a letter to stamp.
    private static let aLetterAndNothingElse = """
        {"section":"conformance","checks":[]}
        {"section":"continuity","questions":[]}
        {"section":"reader","reports":[]}
        {"section":"facts","candidates":[]}
        {"section":"intent_drift","verdict":"holds"}
        {"section":"letter","about":"A woman waits out a fog.","one_thing":null,\
        "working":[],"habits":[],"questions":[],"scenes":null}
        """

    /// **The position is stamped by the RUN, not answered by the model**
    /// (spec §3.4). It is derived app-side at the keystroke and the model is
    /// only told about it, so the record must carry what the run decided —
    /// here a screenplay whose intent says nothing about form, which is the
    /// strong form with no clause of the writer's to strain against.
    ///
    /// The raw value is asserted rather than the case: `Letter.scenePosition`
    /// carries `rawValue` into the sidecar, so `"strong_default"` is a disk
    /// format and a rename reads back as `nil` on every letter already
    /// written.
    func test_aRunStampsTheDerivedScenePositionOntoItsLetter() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            statementText: "Cold, and never wistful.",
            projectType: .screenplay)
        runner.nextEvent = .resultText(Self.aLetterAndNothingElse)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let run = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(run.letter?.about, "A woman waits out a fog.",
                       "control: the letter itself really did land")
        XCTAssertEqual(run.letter?.scenePosition, "strong_default")
    }

    /// The other half of the derivation reaching the record: the same run over
    /// a prose piece whose writer declared the clause in their own intent
    /// files `strong_declared`, and a prose piece that declared nothing files
    /// `weak`. Nothing about the turn changed — only what the writer owns.
    func test_theStampFollowsTheProjectAndTheIntentRatherThanTheTurn() throws {
        for (statement, type, expected) in [
            ("Every scene must turn.", ProjectType.novel, "strong_declared"),
            ("Cold, and never wistful.", ProjectType.novel, "weak"),
            ("A lyric sequence.", ProjectType.screenplay, "none"),
        ] {
            let runner = SpyRunner()
            let harness = try makeHarness(
                runner: runner, reading: standingReading(),
                statementText: statement, projectType: type)
            runner.nextEvent = .resultText(Self.aLetterAndNothingElse)

            harness.orchestrator.runRequested(docId: docId)
            awaitSends(1, on: runner)
            settle()

            let run = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
            XCTAssertEqual(run.letter?.scenePosition, expected,
                           "\(type) + \"\(statement)\"")
        }
    }

    // MARK: - The writer's ask (editorial letter P2 Task 3)

    /// **What the writer asked reaches the run, and the run stamps it back**
    /// (P2 §3.7). The ask is read off `DiagnosticsStore` at the keystroke —
    /// the orchestrator already holds the store — briefed outside the hash,
    /// and stamped onto the letter at `record` so the section can still say
    /// what was asked after the writer has cleared the field.
    func test_aRunBriefsTheWritersAskAndStampsItOntoItsLetter() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())
        harness.diagnostics.setAsk("I'm worried the middle sags.", docId: docId)
        runner.nextEvent = .resultText(Self.aLetterAndNothingElse)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertTrue(
            runner.sends.first?.message.contains("I'm worried the middle sags.") ?? false,
            "the ask must reach the briefing; got \(runner.sends.first?.message ?? "nothing")")
        let run = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(run.letter?.about, "A woman waits out a fog.",
                       "control: the letter itself really did land")
        XCTAssertEqual(run.letter?.asked, "I'm worried the middle sags.")
    }

    /// The control: a run the writer asked nothing on briefs no ask and
    /// stamps none, so the stamp above is reading a real value rather than
    /// echoing whatever the letter already carried.
    func test_aRunWithNoAskBriefsNothingAndStampsNil() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())
        runner.nextEvent = .resultText(Self.aLetterAndNothingElse)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertFalse(
            runner.sends.first?.message.lowercased().contains("the writer asks") ?? true,
            "no ask, no section")
        let run = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertNotNil(run.letter, "control: the letter itself still landed")
        XCTAssertNil(run.letter?.asked)
    }

    /// **The ask the run was BRIEFED on is what it stamps**, not whatever the
    /// field says by the time the answer lands. A writer reads the answer and
    /// immediately asks something else — or clears the field — and a stamp
    /// re-read at `record` would put that second question above the first
    /// question's answer.
    func test_theStampIsTheAskTheRunWasBriefedOnEvenIfTheWriterClearsIt() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())
        harness.diagnostics.setAsk("Does the middle sag?", docId: docId)
        runner.nextEvent = .resultText(Self.aLetterAndNothingElse)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        harness.diagnostics.setAsk(nil, docId: docId)
        settle()

        let run = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(run.letter?.asked, "Does the middle sag?")
        XCTAssertNil(harness.diagnostics.ask(docId: docId),
                     "control: the writer really did clear it")
    }

    /// **The run derives over the WHOLE statement, not the essay half it
    /// briefs with** (spec §3.4, and the reason Task 9's offer works at all).
    ///
    /// The offer files "Every scene must turn." as a dated ruling under
    /// `## Rulings`, which is where `RulingPerformer` writes — beneath the
    /// essay boundary. `beginRun` computes `essay` one line above the
    /// derivation and that value is the RIGHT one for the prompt's own essay
    /// section, so handing it to `ScenePosition.derive` is a one-word mistake
    /// that compiles, keeps the whole suite green through the pure function's
    /// own tests, and silently makes the Add-to-intent offer reappear on every
    /// round forever while no strain is ever raised. This is the call site's
    /// own guard, and it caught exactly that during Task 3's disable
    /// experiments.
    func test_theDerivationReadsTheRulingsHalfAndNotJustTheEssay() throws {
        let statement = """
            Cold, and never wistful.

            ## Rulings

            - 2026-09-01 — Every scene must turn.
            """
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            statementText: statement, projectType: .novel)
        runner.nextEvent = .resultText(Self.aLetterAndNothingElse)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let run = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(run.letter?.scenePosition, "strong_declared",
                       "a clause the writer ruled is still a clause the writer wrote")
        XCTAssertFalse(
            StatementEssay.half(of: statement).lowercased().contains("every scene must turn"),
            "control: the essay half genuinely does not carry it, so briefing "
            + "the derivation with `essay` would have answered weak")
    }

    /// **The model is TOLD its position** — the run message carries the
    /// sentence, so nothing about the scene table is left to be inferred from
    /// the prose (spec §3.4).
    func test_theRunMessageTellsTheModelItsScenePosition() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            statementText: "Cold, and never wistful.", projectType: .screenplay)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let message = try XCTUnwrap(runner.sends.first?.message)
        XCTAssertTrue(
            message.contains(try XCTUnwrap(
                CompilerPrompt.scenePositionSection(.strongDefault))),
            "got \(message)")
    }

    /// **The preview stamps the same position the finish does.** `record` is
    /// one spelling and takes the position undefaulted, so the compiler
    /// forces both call sites to pass something — it cannot force them to pass
    /// the SAME thing, which is what this pins. A preview that disagreed would
    /// flip the letter's scene section under the writer as the check ended,
    /// which is the defect the carried-on-`StreamingRun` shape exists to
    /// prevent.
    func test_thePreviewAndTheFinishAgreeAboutTheScenePosition() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil   // the turn stays open
        let harness = try makeHarness(
            runner: runner, reading: standingReading(),
            statementText: "Cold, and never wistful.", projectType: .screenplay)
        streamingRun(runner: runner, harness: harness)

        runner.stream("""
            {"section":"letter","about":"A woman waits out a fog.","working":[],\
            "habits":[],"questions":[],"scenes":null}
            """ + "\n")

        let previewed = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(previewed.letter?.scenePosition, "strong_default",
                       "the preview's letter carries the run's own position")

        runner.release(.resultText(Self.aLetterAndNothingElse))
        settle()

        let finished = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertEqual(finished.letter?.scenePosition, previewed.letter?.scenePosition,
                       "\u{2026}and the answer that supersedes it says the same thing")
    }

    /// **A turn with no letter has nothing to stamp**, and the position does
    /// not conjure one. `scenePosition` is a fact about a letter, not about a
    /// run: a four-section answer records no letter, exactly as it did before
    /// this task existed.
    func test_aTurnWithNoLetterRecordsNoLetterToStamp() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), projectType: .screenplay)
        runner.nextEvent = .resultText(Self.fourEmptySections)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let run = try XCTUnwrap(harness.diagnostics.lastRun(docId: docId))
        XCTAssertNil(run.letter)
    }

    // MARK: - The ledger in the briefing (editorial letter P2 Task 4)

    /// A ledger of the shape `LessonsLedger` reads, with one entry of each
    /// kind under the writer's own preamble.
    private static let ledger = """
        I keep learning the same two things.

        ## Rulings

        - Filter words — ruled 1 Sep 2026, Denver
        - Choice: Present tense throughout — ruled 1 Sep 2026, Denver
        - Throat-clearing (retired 2 Sep 2026) — ruled 1 Sep 2026, Denver
        """

    /// **Every round is briefed on the ledger** — the writer's preamble, the
    /// lessons still open, and the choices already settled — and on none of
    /// what they have retired.
    func test_aRunIsBriefedOnTheProjectsLedger() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), lessons: Self.ledger)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let message = try XCTUnwrap(runner.sends.first?.message)
        XCTAssertTrue(message.contains("Lessons the writer is working on"), message)
        XCTAssertTrue(message.contains("Filter words"), message)
        XCTAssertTrue(message.contains("Present tense throughout"), message)
        XCTAssertFalse(message.contains("Throat-clearing"),
                       "a lesson the writer retired was put back in front of "
                       + "the reader; got \(message)")
    }

    /// Control for the pin above, and the ordinary case: a project whose
    /// writer has kept no lesson yet is briefed on no ledger at all.
    func test_aProjectWithNoLedgerIsBriefedOnNone() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        XCTAssertFalse(
            try XCTUnwrap(runner.sends.first?.message)
                .contains("Lessons the writer is working on"))
    }

    /// **A cold reader is told the ledger again, in full.** `sentBriefing`
    /// clears with the session, and the ledger diffs in with the essay, the
    /// world and the bible as one unit — so the replacement process, which has
    /// read nothing, gets all four rather than the marker line.
    func test_freshEyesRebriefsTheLedgerWhole() throws {
        let runner = SpyRunner()
        let harness = try makeHarness(
            runner: runner, reading: standingReading(), lessons: Self.ledger)

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()
        XCTAssertTrue(runner.sends[0].message.contains("Filter words"))
        XCTAssertEqual(harness.spawns, 1)

        // Control: the warm process has already read it, so the second run
        // gets the marker line and no ledger.
        harness.setReading(readingAfterMoreWriting())
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()
        XCTAssertTrue(runner.sends[1].message.contains("unchanged since last run"))
        XCTAssertFalse(runner.sends[1].message.contains("Filter words"),
                       "control: a warm session is not re-told the ledger")
        XCTAssertEqual(harness.spawns, 1)

        harness.setReading(readingAfterAThirdParagraph())
        harness.orchestrator.runRequested(docId: docId, freshEyes: true)
        awaitSends(3, on: runner)
        settle()

        XCTAssertEqual(harness.spawns, 2, "the cold read runs on a new process")
        XCTAssertTrue(runner.sends[2].message.contains("Filter words"),
                      "the replacement has read nothing and must be told the "
                      + "ledger whole; got \(runner.sends[2].message)")
    }

    /// A turn whose letter raises one habit and asks two questions about the
    /// same live paragraph: one raised under that habit, one raised under a
    /// habit this letter never named.
    ///
    /// **The habit's `name` and its `lesson` differ on purpose** (fix wave,
    /// finding 1): the citation is matched against the name, and what rides
    /// the note is the ledger heading — the sentence the letter's own Keep
    /// would file.
    private static func aLetterCitingHabits(
        about paragraphId: String, cited: String
    ) -> String {
        """
        {"section":"conformance","checks":[]}
        {"section":"continuity","questions":[]}
        {"section":"reader","reports":[]}
        {"section":"facts","candidates":[]}
        {"section":"intent_drift","verdict":"holds"}
        {"section":"letter","about":"A woman waits out a fog.",\
        "habits":[{"name":"Filter words","refs":["\(paragraphId)"],\
        "cost":"The reader is held one step back.",\
        "lesson":"Cut the filter words."}],\
        "questions":[{"refs":["\(paragraphId)"],"habit":"\(cited)",\
        "question":"Whose fear is this, hers or the narrator's?"}],\
        "scenes":null,"retired":["Throat-clearing"]}
        """
    }

    /// **The wire, end to end through a real run** (Task 2 built it, this task
    /// stamps it): a letter question raised under a habit the same letter named
    /// reaches the queue as a `.query` carrying that heading. Nothing between
    /// the parse and the op may drop it — this is the first test in which a
    /// RUN, rather than a hand-built note, puts one there.
    func test_aRunsQuestionReachesTheQueueCarryingItsHabitHeading() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        runner.nextEvent = .resultText(
            Self.aLetterCitingHabits(about: pid, cited: "Filter words"))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await settle()

        let note = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
                .first { $0.body.hasPrefix("Whose fear is this") },
            "the letter's question never reached the queue at all")
        XCTAssertEqual(note.lessonHeading, "Cut the filter words.",
                       "the habit the question was raised under was lost "
                       + "somewhere between the wire and the op")
        XCTAssertEqual(fx.diagnostics.lastRun(docId: "ch-1")?.letter?.retiredHeadings,
                       ["Throat-clearing"],
                       "…and what the reading did not find rode the record")
    }

    /// The control: a question citing a habit this letter never raised is
    /// minted like any other question and stamped with nothing. Without it,
    /// a parser that stamped every question with whatever string arrived would
    /// pass the pin above.
    func test_aRunsQuestionCitingAnUnknownHabitCarriesNothing() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        runner.nextEvent = .resultText(
            Self.aLetterCitingHabits(about: pid, cited: "Filler words"))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await settle()

        let note = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
                .first { $0.body.hasPrefix("Whose fear is this") },
            "control: the question is minted whatever it cites")
        XCTAssertNil(note.lessonHeading,
                     "a heading naming no habit in this letter was stamped anyway")
    }

    /// **One habit reaches the ledger under ONE identity** (fix wave, finding
    /// 1) — the seam this branch shipped broken, asserted end to end because
    /// neither half can see it alone.
    ///
    /// A run stamps a question with the habit it was raised under; the queue's
    /// *This is a choice* files that stamp; the letter's *Keep as lesson* asks
    /// `keepIsOffered` about the same habit. With the parse stamping the
    /// habit's `name` and the offer asking about its `lesson`, the two never
    /// met: the choice went in as `Choice: Filter words`, the Keep still stood,
    /// and pressing it filed `Cut the filter words.` as a live lesson beside
    /// it — so every later round was briefed to work on the habit and to never
    /// raise it.
    ///
    /// The control is a habit the ledger has never heard of: its Keep is still
    /// offered, so what withdraws the first one is the choice and not the
    /// predicate having stopped answering.
    func test_aHabitFiledFromTheQueueWithdrawsTheLettersKeep() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)
        runner.nextEvent = .resultText(
            Self.aLetterCitingHabits(about: pid, cited: "Filter words"))

        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await settle()

        let habit = try XCTUnwrap(
            fx.diagnostics.lastRun(docId: "ch-1")?.letter?.habits.first,
            "the run's letter never reached the record")
        XCTAssertNotEqual(habit.name, habit.ledgerHeading,
                          "precondition: this fixture's habit is only useful "
                          + "while its name and its ledger heading differ")
        let note = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
                .first { $0.body.hasPrefix("Whose fear is this") },
            "the letter's question never reached the queue at all")

        // The offer stands before the press — otherwise the assertion below
        // would pass over a habit that was never keepable.
        XCTAssertTrue(
            LessonOffer.keepIsOffered(
                habit, ledgerText: LessonLedgerVerbs.ledgerText(store: fx.store)),
            "precondition: nothing is in the ledger yet")

        let refusal = await QueueLedgerVerbs.makeChoice(
            note, in: fx.document, store: fx.store,
            world: fx.declaredWorld, undoManager: nil)
        XCTAssertNil(refusal, "the queue could not file the choice")

        XCTAssertFalse(
            LessonOffer.keepIsOffered(
                habit, ledgerText: LessonLedgerVerbs.ledgerText(store: fx.store)),
            "the queue filed this habit and the letter still offers to file it "
            + "again: one habit, two ledger identities")

        // Control: a habit the ledger does not carry is still offered.
        let other = Letter.Habit(
            name: "Throat-clearing", refs: [], cost: "A cost.",
            lesson: "Start on the second sentence.", exercise: nil)
        XCTAssertTrue(
            LessonOffer.keepIsOffered(
                other, ledgerText: LessonLedgerVerbs.ledgerText(store: fx.store)),
            "the withdrawal is the choice's doing, not the predicate's")
    }

    /// **The production closure reads the writer's real `lessons.md`** — the
    /// half no hand-built `Environment` can prove. A ledger created through
    /// `ProjectStore` and written through the shared append path reaches the
    /// run's message; nothing here stubs the read.
    func test_theProductionEnvironmentBriefsTheLedgerOnDisk() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)

        // Control first: with no ledger on disk, no ledger in the briefing.
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(1, on: runner)
        await settle()
        XCTAssertFalse(runner.sends[0].message.contains("Lessons the writer is working on"))

        let ledger = try await fx.store.createStatement(kind: .lessons, scope: .project)
        try await fx.store.appendToStatement(
            "## Rulings\n\n- Filter words — ruled 1 Sep 2026, Denver",
            to: ledger, session: "test-\(UUID().uuidString)")

        fx.document.setFullText("The fog came.\n\nIt stayed for three days.")
        fx.orchestrator.runRequested(docId: "ch-1")
        await awaitSends(2, on: runner)
        await settle()

        XCTAssertTrue(runner.sends[1].message.contains("Filter words"),
                      "the ledger the writer keeps on disk never reached the "
                      + "run; got \(runner.sends[1].message)")
    }

    // MARK: - The ledger heading rides the note (editorial letter P2 Task 2)

    /// **The wire, end to end on a live document**: a note written with a
    /// habit heading carries it on the op, off the op, and onto the
    /// projection. `addAnnotation` is the one door, so this is the whole
    /// writing half of the field.
    ///
    /// Nothing stamps a heading from a real run yet — Task 4 teaches the
    /// ingest to — so the argument is passed here directly, which is exactly
    /// what the mint will do once it has one.
    func test_aNoteWrittenWithALedgerHeadingCarriesItOnTheOpAndTheProjection() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)

        let id = try await fx.document.addAnnotation(
            kind: .query, paragraphId: pid,
            body: "Whose fear is this, hers or the narrator\u{2019}s?",
            compilerLessonHeading: "filter words")

        let note = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
                .first { $0.id == id })
        XCTAssertEqual(note.lessonHeading, "filter words",
                       "the heading never reached the projection, so the queue "
                       + "can never say what habit the question came out of")

        let raw = try rawOpLog(under: fx.root)
        XCTAssertTrue(raw.contains("\"compiler_lesson_heading\":\"filter words\""),
                      "the heading was derived but never serialised, so it "
                      + "syncs to no other device")
    }

    /// **Every existing caller writes exactly the op it wrote before.** The
    /// key is absent, not null: an argument nobody passes must leave no trace
    /// in the op log.
    func test_aNoteWrittenWithoutOneLeavesNoKeyBehind() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)

        let id = try await fx.document.addAnnotation(
            kind: .query, paragraphId: pid, body: "Has anyone said how long yet?")

        let note = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
                .first { $0.id == id })
        XCTAssertNil(note.lessonHeading)
        let raw = try rawOpLog(under: fx.root)
        XCTAssertFalse(raw.contains("compiler_lesson_heading"),
                       "an unpassed argument put a key on the wire: \(raw)")
    }

    /// **The letter's question carries a heading; a continuity question has
    /// none to carry.** `CompilerNote` is the value that crosses the seam into
    /// the mint, so a heading dropped here never reaches `addAnnotation` at
    /// all — and the two kinds are asserted together because the field must be
    /// carried, not defaulted on by kind.
    func test_aCompilerNoteCarriesTheLetterQuestionsHeadingAndNothingElses() throws {
        func diagnostic(kind: DiagnosticKind, heading: String?) -> Diagnostic {
            var d = Diagnostic(
                id: "01AAAA", docId: "ch-1",
                anchor: .init(paragraphId: "ab12", anchorText: "The fog came."),
                body: "Whose fear is this?", category: nil, runId: "run-7")
            d.kind = kind
            d.lessonHeading = heading
            return d
        }

        let letter = try XCTUnwrap(
            CompilerNote(diagnostic: diagnostic(kind: .letterQuestion,
                                                heading: "filter words")))
        XCTAssertEqual(letter.kind, .query)
        XCTAssertEqual(letter.lessonHeading, "filter words",
                       "the heading was dropped at the seam into the mint")

        let continuity = try XCTUnwrap(
            CompilerNote(diagnostic: diagnostic(kind: .continuity, heading: nil)))
        XCTAssertNil(continuity.lessonHeading,
                     "a continuity question is raised under no habit")
    }


    /// **The mint's own thread**, driven through the PRODUCTION environment.
    /// Nothing parses a heading off the wire until Task 4, so no run can carry
    /// one end to end yet — but the loop that puts a note on the document is
    /// shipped code, and a note handed to it with a heading must arrive with
    /// one. Without this the last link of the wire has no test at all until a
    /// later task happens to exercise it.
    func test_theMintPutsTheNotesHeadingOnTheOpItWrites() async throws {
        let runner = SpyRunner()
        let fx = try await makeLiveDocumentHarness(runner: runner)
        let pid = try XCTUnwrap(fx.document.sequence.first)

        let outcome = await fx.environment.mintAnnotations(
            [CompilerNote(kind: .query, paragraphId: pid,
                          body: "Whose fear is this?",
                          fingerprint: "letterQuestion\u{1f}\u{1f}\(pid)\u{1f}",
                          lessonHeading: "filter words"),
             CompilerNote(kind: .query, paragraphId: pid,
                          body: "Has anyone said how long yet?",
                          fingerprint: "continuity\u{1f}\u{1f}\(pid)\u{1f}")],
            CompilerMintContext(
                docId: "ch-1", runId: "run-7", passId: "structural", round: 1,
                freshEyes: false, editorName: "Perkins"))
        XCTAssertEqual(outcome.minted, 2, "control: both notes minted")

        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
        let raised = try XCTUnwrap(notes.first { $0.body == "Whose fear is this?" })
        let plain = try XCTUnwrap(
            notes.first { $0.body == "Has anyone said how long yet?" })
        XCTAssertEqual(raised.lessonHeading, "filter words",
                       "the mint dropped the heading between the note and the op")
        XCTAssertNil(plain.lessonHeading,
                     "the mint put a heading on a note that carried none")
    }
}
