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
        var nextEvent: CompilerRunEvent? = .resultText(#"{"diagnostics":[]}"#)
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

    private let docId = "doc-1"

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
        var flashes: Int { flashCount() }
        let flashCount: () -> Int
        /// What the next run reads off the live document — the writer, typing.
        let setReading: (CompilerOrchestrator.DocumentReading?) -> Void
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

    private func makeHarness(
        runner: SpyRunner,
        reading: CompilerOrchestrator.DocumentReading?,
        intentText: String? = "Cold, and never wistful.",
        liveParagraphText: @escaping (String, String) -> String? = { _, _ in "The fog came." },
        pinnedListing: @escaping (String) -> [String] = { _ in [] },
        paletteListing: @escaping () -> [String] = { [] },
        prepareForRun: @escaping @MainActor (String) async -> Void = { _ in }
    ) throws -> Harness {
        let root = try makeProjectRoot()
        let diagnostics = DiagnosticsStore(
            projectRoot: root, device: DeviceSlug.make(from: "test-mac"))
        let configURL = root.appendingPathComponent("compiler-mcp.json")
        let flashes = Box(0)
        let live = Box(reading)
        let orchestrator = CompilerOrchestrator()
        orchestrator.configure(
            environment: CompilerOrchestrator.Environment(
                projectId: "p-1",
                model: "test-model",
                prepareForRun: prepareForRun,
                reading: { id in id == self.docId ? live.value : nil },
                liveParagraphText: liveParagraphText,
                intent: { _ in (intentText, "this chapter") },
                pinnedListing: pinnedListing,
                paletteListing: paletteListing,
                writeMCPConfig: {
                    try Data("{}".utf8).write(to: configURL, options: .atomic)
                    return configURL
                },
                makeRunner: { _, _ in runner },
                onRunAcknowledged: { flashes.value += 1 }),
            diagnostics: diagnostics)
        return Harness(orchestrator: orchestrator, diagnostics: diagnostics,
                       root: root, configURL: configURL,
                       flashCount: { flashes.value },
                       setReading: { live.value = $0 })
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

    /// ⌘R while a run is in flight is a **quiet** no-op: no second send, no
    /// second flash, and the running state untouched. The pane header is
    /// already saying what is happening; a flash reading "Checking…" over a
    /// check already running is the key lying about what it did.
    func test_runWhileRunningIsRefusedQuietly() throws {
        let runner = SpyRunner()
        runner.nextEvent = nil   // hold the turn open
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        XCTAssertEqual(harness.orchestrator.runState, .running(docId: docId))
        let flashesAfterFirst = harness.flashes

        harness.orchestrator.runRequested(docId: docId)
        settle()

        XCTAssertEqual(runner.sends.count, 1, "the second ⌘R must not reach the runner")
        XCTAssertEqual(harness.orchestrator.runState, .running(docId: docId))
        XCTAssertEqual(harness.flashes, flashesAfterFirst,
                       "a refused run is silent — the flash acknowledges work started")

        runner.release(.resultText(#"{"diagnostics":[]}"#))
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
            #"{"diagnostics":[{"paragraph_id":"a1b2","category":"rhythm","body":"Two beats, not three."}]}"#)
        harness.orchestrator.runRequested(docId: docId)
        awaitSends(2, on: runner)
        settle()

        XCTAssertEqual(harness.diagnostics.lastOpId(docId: docId), "op1")
        XCTAssertEqual(harness.orchestrator.runState, .idle)
        let notes = harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." })
        XCTAssertEqual(notes.map(\.body), ["Two beats, not three."])
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

    /// A drift note carries no anchor and is stored ahead of the anchored ones,
    /// because the pane pins it at the top and a store the pane has to re-sort
    /// is two places that can disagree about the order.
    func test_aDriftNoteIsStoredAheadOfTheAnchoredOnes() throws {
        let runner = SpyRunner()
        runner.nextEvent = .resultText("""
            {"diagnostics":[{"paragraph_id":"a1b2","body":"Two beats, not three."}],
             "intent_drift":"You said cold; this is wistful."}
            """)
        let harness = try makeHarness(runner: runner, reading: standingReading())

        harness.orchestrator.runRequested(docId: docId)
        awaitSends(1, on: runner)
        settle()

        let notes = harness.diagnostics.live(docId: docId, currentText: { _ in "The fog came." })
        XCTAssertEqual(notes.map(\.body),
                       ["You said cold; this is wistful.", "Two beats, not three."])
        XCTAssertNil(notes.first?.anchor)
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
            {"diagnostics":[{"paragraph_id":"gone1","body":"Two beats, not three."},
                            {"paragraph_id":"gone2","body":"The tense slips here."},
                            {"paragraph_id":"gone3","body":"This repeats the last line."}]}
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
        runner.nextEvent = .resultText(
            #"{"diagnostics":[{"paragraph_id":"a1b2","body":"Two beats, not three."}]}"#)
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

    /// The intent is sent whole on the first run and elided on the second — the
    /// spec's diffed-in context (§3.3), which is what makes run N cost the new
    /// paragraphs rather than the world.
    func test_theIntentIsSentOnceWhileTheSessionLives() throws {
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
    /// fresh process the intent is "unchanged since last run" describes a run
    /// it never saw, and it judges the prose against nothing.
    func test_aRespawnedSessionIsSentTheWholeIntentAgain() throws {
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

    /// **The intent hash is tracked per document, not per session.** One warm
    /// session serves every document the writer visits in the window, so a
    /// single last-sent hash would let a switch between two documents corrupt
    /// the elision: document B's run would compare against document A's hash
    /// (masked whenever the two intents differ, which is the trap), and a
    /// later run back on A would wrongly re-send its whole intent — or worse,
    /// wrongly elide it — because the tracker remembers the wrong document.
    func test_intentHashIsPerDocument_notPerSession() throws {
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
                intent: { (intentFor[$0], "this chapter") },
                pinnedListing: { _ in [] },
                paletteListing: { [] },
                writeMCPConfig: {
                    try Data("{}".utf8).write(to: configURL, options: .atomic)
                    return configURL
                },
                makeRunner: { _, _ in runner },
                onRunAcknowledged: {}),
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
        store: ProjectStore, documentStore: DocumentStore, root: URL
    ) -> CompilerOrchestrator.Environment {
        CompilerOrchestrator.Environment.production(
            store: store, documentStore: documentStore, projectURL: root,
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "CompilerListings-\(UUID())")!),
            onRunAcknowledged: {})
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
        XCTAssertEqual(harness.flashes, 1)

        harness.orchestrator.runRequested(docId: docId)
        settle()
        XCTAssertEqual(gate.entries, 1, "the second press must not start a second run")
        XCTAssertEqual(harness.flashes, 1,
                       "a refused run is silent — the flash acknowledges work started")

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
        let root: URL
    }

    private func makeLiveDocumentHarness(
        runner: SpyRunner, initialProse: String = "The fog came.\n"
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

        let diagnostics = DiagnosticsStore(
            projectRoot: root, device: DeviceSlug.make(from: "test-mac"))
        let configURL = root.appendingPathComponent("compiler-mcp.json")
        var environment = makeProductionEnvironment(
            store: store, documentStore: documentStore, root: root)
        environment.writeMCPConfig = {
            try Data("{}".utf8).write(to: configURL, options: .atomic)
            return configURL
        }
        environment.makeRunner = { _, _ in runner }
        let orchestrator = CompilerOrchestrator()
        orchestrator.configure(environment: environment, diagnostics: diagnostics)

        return LiveDocumentHarness(
            orchestrator: orchestrator, diagnostics: diagnostics, document: document,
            store: store, documentStore: documentStore, root: root)
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
        XCTAssertEqual(harness.orchestrator.runState, .running(docId: docId))

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
}
