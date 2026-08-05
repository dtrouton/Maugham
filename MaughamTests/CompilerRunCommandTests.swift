import XCTest
import MaughamCore
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

    private func makeHarness(
        runner: SpyRunner,
        reading: CompilerOrchestrator.DocumentReading?,
        intentText: String? = "Cold, and never wistful.",
        liveParagraphText: @escaping (String, String) -> String? = { _, _ in "The fog came." }
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
                reading: { id in id == self.docId ? live.value : nil },
                liveParagraphText: liveParagraphText,
                intent: { _ in (intentText, "this chapter") },
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

    /// Give the main queue a pass, so an assertion that something did NOT
    /// happen has a turn in which it could have.
    private func settle() {
        let settled = expectation(description: "the run loop ran")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
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
        guard case .nothingNew = harness.orchestrator.runState else {
            return XCTFail("expected the idle 'nothing new' variant, got "
                           + "\(harness.orchestrator.runState)")
        }
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
        guard case .failed(let failure, _) = harness.orchestrator.runState else {
            return XCTFail("expected a reported failure, got \(harness.orchestrator.runState)")
        }
        XCTAssertEqual(failure, .timedOut)

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
        guard case .failed(let failure, _) = harness.orchestrator.runState else {
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

        guard case .failed(let failure, _) = harness.orchestrator.runState else {
            return XCTFail("the failure was erased by an unrelated teardown")
        }
        XCTAssertEqual(failure, .cliNotFound)
    }
}
