import XCTest
import MaughamCore
@testable import Maugham

/// Contracts for the `CompilerRunner` seam and its one production
/// implementation, `ClaudeCLISession`.
///
/// **No network and no real `claude` binary.** Every test injects a
/// `cliOverride` pointing at a bash fixture written to a temp directory. The
/// fixture reads stream-json lines off stdin and emits canned stream-json
/// lines back, so the session's process management, framing, parsing, timers
/// and lifetime are exercised against a real subprocess with real pipes —
/// which is the part that can break.
///
/// The fixture also records, per spawn, an invocation line and its argv, and
/// traps its own exit. Those three files are how a test observes process
/// *reuse*, spawn *arguments* and process *death* from outside.
@MainActor
final class ClaudeCLISessionTests: XCTestCase {

    // MARK: - Fixture

    /// How the fake CLI behaves once it is reading stdin.
    private enum FakeMode: String {
        /// Answer every turn immediately with a `result` event.
        case normal
        /// Answer, but precede the answer with event types the parser has
        /// never seen plus one line that is not JSON at all.
        case noisy
        /// Exit non-zero after consuming the first stdin line, on the FIRST
        /// spawn only. A second spawn behaves like `normal`.
        case dieFirst
        /// Say why on stderr, then exit non-zero — the shape of an expired
        /// login. The last line written is blank, so a test can tell "the last
        /// line" from "the last line with something on it".
        case dieWithStderr
        /// Withhold the answer for as long as the `slow` flag file exists.
        ///
        /// Deliberately keyed on a file the TEST owns rather than on the
        /// invocation counter: a process killed mid-cancel may be terminated
        /// during its own startup, before it ever records itself, so a
        /// counter-keyed "first spawn is slow" rule makes the *respawned*
        /// process the slow one. That flaw made `test_cancelDoesNotKillTheSession`
        /// pass for the wrong reason — the next send did work, but only after
        /// waiting out the stale process.
        case slowWhileFlagged
    }

    private var tempDir: URL!
    /// One line per spawn of the fake CLI.
    private var counterURL: URL { tempDir.appendingPathComponent("invocations") }
    /// argv of the most recent spawn, one argument per line.
    private var argsURL: URL { tempDir.appendingPathComponent("args") }
    /// One line per fake-CLI process exit.
    private var exitsURL: URL { tempDir.appendingPathComponent("exits") }
    /// The working directory the most recent spawn was given, resolved.
    private var cwdURL: URL { tempDir.appendingPathComponent("cwd") }
    /// While this file exists, a `slowWhileFlagged` fixture withholds its answer.
    private var slowFlagURL: URL { tempDir.appendingPathComponent("be-slow") }

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCLISessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    /// Write an executable bash script that impersonates `claude` in
    /// `--input-format stream-json --output-format stream-json` mode.
    private func makeFakeCLI(mode: FakeMode, maxStallSeconds: Int = 10) throws -> URL {
        let url = tempDir.appendingPathComponent("fake-claude")
        let script = """
        #!/bin/bash
        COUNTER="\(counterURL.path)"
        ARGS="\(argsURL.path)"
        EXITS="\(exitsURL.path)"
        CWD="\(cwdURL.path)"
        FLAG="\(slowFlagURL.path)"
        MODE="\(mode.rawValue)"

        trap 'echo bye >> "$EXITS"; exit 143' TERM
        trap 'echo bye >> "$EXITS"' EXIT

        echo "spawn" >> "$COUNTER"
        N=$(wc -l < "$COUNTER" | tr -d ' ')
        printf '%s\\n' "$@" > "$ARGS"
        pwd -P > "$CWD"

        if [ "$MODE" = "dieFirst" ] && [ "$N" -eq 1 ]; then
          IFS= read -r _line
          exit 3
        fi

        if [ "$MODE" = "dieWithStderr" ]; then
          IFS= read -r _line
          echo "Loading configuration" >&2
          echo "Invalid API key - Please run /login" >&2
          echo "" >&2
          exit 1
        fi

        while IFS= read -r _line; do
          if [ "$MODE" = "slowWhileFlagged" ]; then
            # Short sleeps, not one long one: bash defers a trapped signal until
            # the running foreground command returns, so a single `sleep 10`
            # would keep the process alive ~10s past its own SIGTERM.
            waited=0
            while [ -e "$FLAG" ] && [ "$waited" -lt \(maxStallSeconds * 10) ]; do
              sleep 0.1
              waited=$((waited+1))
            done
          fi
          if [ "$MODE" = "noisy" ]; then
            printf '%s\\n' '{"type":"wibble","payload":7}'
            printf '%s\\n' 'this line is not JSON at all'
            printf '%s\\n' '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}'
            printf '%s\\n' '{"no_type_field":true}'
          fi
          printf '%s\\n' '{"type":"system","subtype":"init","session_id":"fake-session"}'
          printf '%s\\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"partial"}]}}'
          printf '%s\\n' '{"is_error":false,"subtype":"success","result":"FAKE RESULT","session_id":"fake-session","type":"result"}'
        done
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeSession(
        cli: URL?,
        isEnabled: @escaping () -> Bool = { true },
        idleTimeout: TimeInterval = 600,
        runTimeout: TimeInterval = 20,
        locator: (@Sendable () -> URL?)? = nil
    ) -> ClaudeCLISession {
        ClaudeCLISession(
            model: "haiku",
            mcpConfigPath: tempDir.appendingPathComponent("mcp.json"),
            cliOverride: cli,
            isEnabled: isEnabled,
            idleTimeout: idleTimeout,
            runTimeout: runTimeout,
            locator: locator ?? { nil })
    }

    /// A locator whose FIRST call is held open until the test lets it go, so a
    /// test can decide which of two overlapping probes finishes first. Later
    /// calls answer immediately.
    private final class GatedLocator: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private let firstCallGate = DispatchSemaphore(value: 0)
        private let answer: URL

        init(answer: URL) { self.answer = answer }

        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

        func locate() -> URL? {
            lock.lock()
            _calls += 1
            let isFirst = _calls == 1
            lock.unlock()
            // Safe to block: the locator runs in a detached task, never on the
            // main actor — which `test_cliResolutionNeverRunsOnTheMainActor`
            // is the standing proof of.
            if isFirst { firstCallGate.wait() }
            return answer
        }

        func releaseFirstCall() { firstCallGate.signal() }
    }

    /// Records what the injected locator saw, from whatever thread ran it.
    private final class LocatorProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _ranOnMainThread = false
        private let answer: URL?

        init(answer: URL?) { self.answer = answer }

        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        var ranOnMainThread: Bool {
            lock.lock(); defer { lock.unlock() }; return _ranOnMainThread
        }

        func locate() -> URL? {
            lock.lock()
            _calls += 1
            // A login-shell probe blocks; if it ever runs here, the whole app
            // window is frozen for its duration.
            if Thread.isMainThread { _ranOnMainThread = true }
            lock.unlock()
            return answer
        }
    }

    /// Number of lines in `url`, or 0 when it does not exist.
    private func lineCount(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }

    /// Poll until `predicate` holds or `timeout` elapses. Used only for the
    /// fixture's own out-of-process side effects (its exit marker), never for
    /// the session's own state, which resolves through `await`.
    private func waitUntil(
        _ timeout: TimeInterval = 3,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return predicate()
    }

    // MARK: - Contracts

    /// Nothing is spawned by construction — entering the Author persona must
    /// not cost a subprocess; only the first run does (spec §3.4).
    func test_initSpawnsNothing() throws {
        let cli = try makeFakeCLI(mode: .normal)
        let session = makeSession(cli: cli)

        XCTAssertFalse(session.hasLiveProcess,
            "init must not spawn — the first send does")
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(lineCount(counterURL), 0,
            "the fake CLI must not have been invoked by init")
        _ = session
    }

    /// The point of the warm session: two runs, one process.
    func test_secondSendReusesTheProcess() async throws {
        let cli = try makeFakeCLI(mode: .normal)
        let session = makeSession(cli: cli)

        let first = await session.send(message: "one", systemPreamble: "preamble")
        XCTAssertEqual(first, .resultText("FAKE RESULT"))
        XCTAssertEqual(lineCount(counterURL), 1)

        let second = await session.send(message: "two", systemPreamble: nil)
        XCTAssertEqual(second, .resultText("FAKE RESULT"))
        XCTAssertEqual(lineCount(counterURL), 1,
            "the second send must reuse the warm process, not spawn a second one")

        session.shutdown()
    }

    /// A `result` event — and only a `result` event — ends the turn, and its
    /// `result` field is the text the caller gets.
    func test_resultEventResolvesTheSend() async throws {
        let cli = try makeFakeCLI(mode: .normal)
        let session = makeSession(cli: cli)

        let event = await session.send(message: "hello", systemPreamble: nil)

        XCTAssertEqual(event, .resultText("FAKE RESULT"))
        XCTAssertFalse(session.isRunning, "the turn is over once it resolves")
        session.shutdown()
    }

    /// The toggle is enforced at the RUNNER, not at the UI: a disabled session
    /// refuses before it spawns anything, and `shutdown` ends a live process.
    func test_toggleGovernsSpawnAndLifetime() async throws {
        let cli = try makeFakeCLI(mode: .normal)

        // Refusal happens before any spawn.
        var enabled = false
        let disabled = makeSession(cli: cli, isEnabled: { enabled })
        let refused = await disabled.send(message: "hello", systemPreamble: nil)
        XCTAssertEqual(refused, .failed(.disabledByToggle))
        XCTAssertFalse(disabled.hasLiveProcess)
        // Settle before believing the counter: a wrongly-spawned process needs
        // a moment to record itself, so an immediate read of 0 proves nothing.
        let spawnedAnyway = await waitUntil(0.5) { self.lineCount(self.counterURL) > 0 }
        XCTAssertFalse(spawnedAnyway,
            "a disabled runner must not spawn the CLI at all")

        // Enabled: it spawns, and shutdown kills the process for real.
        enabled = true
        _ = await disabled.send(message: "hello", systemPreamble: nil)
        XCTAssertTrue(disabled.hasLiveProcess)
        XCTAssertEqual(lineCount(counterURL), 1)

        disabled.shutdown()
        XCTAssertFalse(disabled.hasLiveProcess)
        let exited = await waitUntil { self.lineCount(self.exitsURL) >= 1 }
        XCTAssertTrue(exited, "shutdown must terminate the OS process, not just drop the reference")
    }

    /// No `claude` on the machine is an ordinary, reportable outcome — not a
    /// throw, not a crash.
    func test_missingCLIFailsHonestly() async throws {
        let nowhere = tempDir.appendingPathComponent("no-such-claude")
        let session = makeSession(cli: nowhere)

        let event = await session.send(message: "hello", systemPreamble: nil)

        XCTAssertEqual(event, .failed(.cliNotFound))
        XCTAssertFalse(session.hasLiveProcess)
    }

    /// A process that dies mid-turn fails that turn visibly ONCE; the next
    /// send starts a fresh session. Self-healing, no state to repair (§3.4).
    func test_sessionDeathSelfHeals() async throws {
        let cli = try makeFakeCLI(mode: .dieFirst)
        let session = makeSession(cli: cli)

        let died = await session.send(message: "one", systemPreamble: nil)
        guard case .failed(.sessionDied) = died else {
            return XCTFail("expected .sessionDied, got \(died)")
        }
        XCTAssertEqual(lineCount(counterURL), 1)

        let healed = await session.send(message: "two", systemPreamble: nil)
        XCTAssertEqual(healed, .resultText("FAKE RESULT"),
            "the next send must start a fresh session")
        XCTAssertEqual(lineCount(counterURL), 2)

        session.shutdown()
    }

    /// **A death that said why carries the why** (spec §8). The case the spec
    /// names is an expired login: without this the writer presses ⌘R and reads
    /// "the CLI exited with status 1", which is honest and names nothing they
    /// can act on. The last non-empty line is the one that carries — a CLI
    /// says what it was doing first and what went wrong last, and it often
    /// signs off with a blank line.
    func test_aDeathThatSaidWhyCarriesItsLastWord() async throws {
        let cli = try makeFakeCLI(mode: .dieWithStderr)
        let session = makeSession(cli: cli)

        let event = await session.send(message: "hello", systemPreamble: nil)

        guard case .failed(.sessionDied(let detail)) = event else {
            return XCTFail("expected .sessionDied, got \(event)")
        }
        XCTAssertTrue(detail.contains("status 1"), "got: \(detail)")
        XCTAssertTrue(detail.contains("Invalid API key - Please run /login"),
                      "the essence of stderr is missing from: \(detail)")
        XCTAssertFalse(detail.contains("Loading configuration"),
                       "one line, not a log: \(detail)")

        session.shutdown()
    }

    /// The converse: a process that went quietly gets the bare sentence and no
    /// invented cause.
    func test_aSilentDeathSaysOnlyWhatItKnows() async throws {
        let cli = try makeFakeCLI(mode: .dieFirst)
        let session = makeSession(cli: cli)

        let event = await session.send(message: "hello", systemPreamble: nil)

        XCTAssertEqual(event, .failed(.sessionDied(detail: "the CLI exited with status 3")))
        session.shutdown()
    }

    /// Cancelling ends the turn and leaves the runner usable. Whether it does
    /// that by killing and respawning is an implementation choice; the
    /// contract is that the next send works.
    func test_cancelDoesNotKillTheSession() async throws {
        let cli = try makeFakeCLI(mode: .slowWhileFlagged)
        try Data().write(to: slowFlagURL)
        let session = makeSession(cli: cli)

        async let inFlight = session.send(message: "slow one", systemPreamble: nil)
        let started = await waitUntil { session.isRunning }
        XCTAssertTrue(started, "the first send should be in flight")

        let cancelledAt = Date()
        session.cancelCurrentRun()
        _ = await inFlight
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2,
            "cancel must return the turn promptly, not wait out the CLI")
        XCTAssertFalse(session.isRunning, "cancel ends the turn")

        // Let the next process answer, so this measures the runner's recovery
        // and not the fixture's stall.
        try FileManager.default.removeItem(at: slowFlagURL)

        let resumedAt = Date()
        let next = await session.send(message: "two", systemPreamble: nil)
        XCTAssertLessThan(Date().timeIntervalSince(resumedAt), 3,
            "the respawned session must answer on its own, not wait out the "
            + "process the cancel killed")
        XCTAssertEqual(next, .resultText("FAKE RESULT"),
            "the runner must still be usable after a cancel")

        session.shutdown()
    }

    /// A turn that outruns its budget is reported as a timeout, not left
    /// hanging.
    func test_runTimeout() async throws {
        let cli = try makeFakeCLI(mode: .slowWhileFlagged)
        try Data().write(to: slowFlagURL)   // never lifted: the turn never lands
        let session = makeSession(cli: cli, runTimeout: 0.4)

        let started = Date()
        let event = await session.send(message: "slow", systemPreamble: nil)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(event, .failed(.timedOut))
        XCTAssertLessThan(elapsed, 4, "the timeout must fire well before the fixture answers")
        XCTAssertFalse(session.isRunning)

        session.shutdown()
    }

    /// The stream interleaves `system`, `assistant` and `rate_limit_event`
    /// today and will carry types that do not exist yet. Anything that is not
    /// a `result` is skipped, including a line that is not JSON.
    func test_unknownStreamEventsAreTolerated() async throws {
        let cli = try makeFakeCLI(mode: .noisy)
        let session = makeSession(cli: cli)

        let event = await session.send(message: "hello", systemPreamble: nil)

        XCTAssertEqual(event, .resultText("FAKE RESULT"),
            "unknown event types and unparseable lines must not fail the turn")
        session.shutdown()
    }

    /// The bridge config the runner hands the CLI is the shape the spike
    /// measured — and its server key is the variant's, never a literal
    /// (tripwire 13).
    func test_mcpConfigShapeMatchesTheSpike() throws {
        let bridge = URL(fileURLWithPath: "/Applications/Maugham.app/Contents/MacOS/maugham-mcp")
        let url = try ClaudeCLISession.writeMCPConfig(
            bridgeBinary: bridge, socketPath: "/tmp/some.sock", to: tempDir)

        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), [BuildVariant.current.mcpServerKey],
            "exactly the one Maugham server, keyed by the running variant")
        let entry = try XCTUnwrap(
            servers[BuildVariant.current.mcpServerKey] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, bridge.path)
        let env = try XCTUnwrap(entry["env"] as? [String: String])
        XCTAssertEqual(env["MAUGHAM_MCP_SOCKET"], "/tmp/some.sock")

        // No socket override → no env key, matching ClaudeDesktopConfig.
        let defaulted = try ClaudeCLISession.writeMCPConfig(
            bridgeBinary: bridge, socketPath: nil, to: tempDir)
        let dRoot = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try Data(contentsOf: defaulted)) as? [String: Any])
        let dServers = try XCTUnwrap(dRoot["mcpServers"] as? [String: Any])
        let dEntry = try XCTUnwrap(
            dServers[BuildVariant.current.mcpServerKey] as? [String: Any])
        XCTAssertNil(dEntry["env"],
            "the default socket wants no env override")
    }

    /// Locating the CLI must not run on the main actor. The fallback shells out
    /// to a login shell that sources the writer's profile — on a real machine
    /// that is hundreds of milliseconds to seconds of frozen window, and it
    /// would be paid again on every respawn.
    func test_cliResolutionNeverRunsOnTheMainActor() async throws {
        let cli = try makeFakeCLI(mode: .normal)
        let probe = LocatorProbe(answer: cli)
        let session = makeSession(cli: nil, locator: { probe.locate() })

        let event = await session.send(message: "hello", systemPreamble: nil)

        XCTAssertEqual(event, .resultText("FAKE RESULT"),
            "the probe path must still produce a working session")
        XCTAssertGreaterThan(probe.calls, 0, "the locator should have been consulted")
        XCTAssertFalse(probe.ranOnMainThread,
            "the CLI probe blocks; running it on the main actor freezes the app")

        session.shutdown()
    }

    /// The answer is kept for the session. Death, cancel, timeout and a toggle
    /// cycle all respawn, and none of them should re-pay for a login shell.
    func test_cliResolutionIsCachedAcrossRespawns() async throws {
        let cli = try makeFakeCLI(mode: .dieFirst)
        let probe = LocatorProbe(answer: cli)
        let session = makeSession(cli: nil, locator: { probe.locate() })

        // First send dies mid-turn, so the second one respawns.
        let died = await session.send(message: "one", systemPreamble: nil)
        guard case .failed(.sessionDied) = died else {
            return XCTFail("expected .sessionDied, got \(died)")
        }
        let healed = await session.send(message: "two", systemPreamble: nil)
        XCTAssertEqual(healed, .resultText("FAKE RESULT"))
        XCTAssertEqual(lineCount(counterURL), 2, "the second send must have respawned")

        XCTAssertEqual(probe.calls, 1,
            "the resolved CLI must be reused by the respawn, not probed again")

        session.shutdown()
    }

    /// A superseded turn must not clear the claim of the turn that replaced it.
    ///
    /// The chain: turn A suspends on a cold CLI probe; a cancel lands; turn B
    /// retries, wins its own probe, spawns and is genuinely running; only then
    /// does A's stale probe come back. If A resets `isRunning` on its way out
    /// without checking it still owns the turn, it clears B's claim — and the
    /// next `cancelCurrentRun`, aimed at B's real process, silently does
    /// nothing. The writer would press cancel on a live run and watch it keep
    /// going until the run timeout.
    func test_aSupersededTurnCannotDisarmCancelForTheLiveOne() async throws {
        let cli = try makeFakeCLI(mode: .slowWhileFlagged)
        try Data().write(to: slowFlagURL)   // keeps turn B in flight
        let locator = GatedLocator(answer: cli)
        let session = makeSession(cli: nil, locator: { locator.locate() })

        // Turn A: suspended inside its probe, claim taken, no continuation yet.
        async let turnA = session.send(message: "A", systemPreamble: nil)
        let aProbing = await waitUntil { locator.calls >= 1 }
        XCTAssertTrue(aProbing, "turn A should be inside the probe")
        XCTAssertTrue(session.isRunning)

        // Cancel A while it is still resolving, then start turn B.
        session.cancelCurrentRun()
        async let turnB = session.send(message: "B", systemPreamble: nil)
        let bRunning = await waitUntil { session.hasLiveProcess && session.isRunning }
        XCTAssertTrue(bRunning, "turn B should have spawned and be in flight")

        // Now let A's stale probe come back.
        locator.releaseFirstCall()
        let aEvent = await turnA
        guard case .failed = aEvent else {
            return XCTFail("the superseded turn must fail, got \(aEvent)")
        }

        XCTAssertTrue(session.isRunning,
            "the superseded turn must not clear the live turn's claim")

        // The real proof: a cancel aimed at B must actually reach B.
        session.cancelCurrentRun()
        let bEvent = await turnB
        guard case .failed(.sessionDied(let detail)) = bEvent, detail == "cancelled" else {
            return XCTFail("cancel must reach the live turn, got \(bEvent)")
        }
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.hasLiveProcess)
    }

    /// Resolving the CLI suspends, which opens a window that did not exist when
    /// resolution was synchronous: a `shutdown` can land while a send is
    /// off-main. It must not come back and spawn a process moments after the
    /// session was told to stop.
    func test_shutdownDuringCLIResolutionNeverSpawns() async throws {
        let cli = try makeFakeCLI(mode: .normal)
        let session = makeSession(cli: nil, locator: {
            Thread.sleep(forTimeInterval: 0.3)   // a login shell, in miniature
            return cli
        })

        async let pending = session.send(message: "hello", systemPreamble: nil)
        let claimed = await waitUntil { session.isRunning }
        XCTAssertTrue(claimed, "the turn should be claimed before resolution finishes")
        XCTAssertFalse(session.hasLiveProcess, "nothing is spawned until the CLI resolves")

        session.shutdown()
        let event = await pending

        guard case .failed = event else {
            return XCTFail("a send interrupted by shutdown must fail, got \(event)")
        }
        XCTAssertFalse(session.hasLiveProcess)
        let spawned = await waitUntil(0.6) { self.lineCount(self.counterURL) > 0 }
        XCTAssertFalse(spawned,
            "a session shut down mid-resolution must never spawn the CLI")
    }

    /// The same window, seen from the other side: the second send must be
    /// refused rather than spawning over the first, even though the first has
    /// not stored its continuation yet.
    func test_aSecondSendDuringCLIResolutionIsRefused() async throws {
        let cli = try makeFakeCLI(mode: .normal)
        let session = makeSession(cli: nil, locator: {
            Thread.sleep(forTimeInterval: 0.3)
            return cli
        })

        async let firstRun = session.send(message: "one", systemPreamble: nil)
        let claimed = await waitUntil { session.isRunning }
        XCTAssertTrue(claimed)

        let second = await session.send(message: "two", systemPreamble: nil)
        guard case .failed(.sessionDied(let detail)) = second else {
            return XCTFail("expected a refusal, got \(second)")
        }
        XCTAssertTrue(detail.contains("already in flight"), "got detail: \(detail)")

        let firstEvent = await firstRun
        XCTAssertEqual(firstEvent, .resultText("FAKE RESULT"),
            "the first turn must be unharmed by the refusal")
        XCTAssertEqual(lineCount(counterURL), 1, "exactly one process")

        session.shutdown()
    }

    /// The retired-process guard: a callback carrying a dead spawn's generation
    /// must not resolve the turn that replaced it. Without it a kill-and-respawn
    /// lets the corpse answer for the live run — the writer would see the
    /// cancelled turn's diagnostics attributed to the new one.
    func test_aRetiredProcessCannotResolveTheLiveTurn() async throws {
        let cli = try makeFakeCLI(mode: .slowWhileFlagged)
        try Data().write(to: slowFlagURL)
        let session = makeSession(cli: cli)

        // A first process, alive and mid-turn: capture the generation its
        // reader callbacks carry.
        async let first = session.send(message: "first", systemPreamble: nil)
        let firstStarted = await waitUntil { session.isRunning }
        XCTAssertTrue(firstStarted, "the first turn should be in flight")
        let retiredGeneration = session.sessionEpoch

        // Kill it, then start a turn that stays in flight on a fresh process.
        session.cancelCurrentRun()
        _ = await first
        async let live = session.send(message: "second", systemPreamble: nil)
        let inFlight = await waitUntil { session.isRunning }
        XCTAssertTrue(inFlight, "the second turn should be in flight")
        XCTAssertNotEqual(session.sessionEpoch, retiredGeneration,
            "the respawn must have moved the generation on")

        // The corpse speaks.
        session.deliverAsIfFromProcess(
            line: #"{"type":"result","result":"STALE ANSWER FROM THE DEAD PROCESS"}"#,
            generation: retiredGeneration)

        XCTAssertTrue(session.isRunning,
            "a retired process's result must not end the live turn")

        // The live process answers for itself.
        try FileManager.default.removeItem(at: slowFlagURL)
        let event = await live
        XCTAssertEqual(event, .resultText("FAKE RESULT"),
            "the live turn must resolve with its OWN process's result")

        session.shutdown()
    }

    /// The invocation is the one the spike measured, and the system preamble
    /// rides on `--append-system-prompt` (verified 2026-08-04 to compose with
    /// `-p` + stream-json in both directions) rather than being smuggled into
    /// the first user message.
    ///
    /// **`--tools ""` is the membrane's other half and the reason this test is
    /// not cosmetic.** `--allowedTools` removes nothing — it pre-approves the
    /// tools it names so they skip the permission prompt, and Claude Code's
    /// built-in Read/Glob/Grep do not prompt inside the working directory, so
    /// the enumerated MCP list alone leaves the spawned model able to read any
    /// file on the machine. Verified live against `claude` 2.1.222 on
    /// 2026-08-05, both directions: the same invocation returned a scratch
    /// file's contents without the flag and answered "CANNOT" with it, and a
    /// composed `--tools "" --mcp-config --allowedTools` turn still reached
    /// `mcp__maugham__list_projects`. The empty value is the whole point of the
    /// flag, which is why the argv is parsed here without dropping blanks.
    func test_spawnArgumentsMatchTheSpike() async throws {
        let cli = try makeFakeCLI(mode: .normal)
        let session = makeSession(cli: cli)

        _ = await session.send(message: "hello", systemPreamble: "BE TERSE")

        // `components`, not `split`: `split` discards empty subsequences, which
        // is exactly the argument this test exists to see. The fixture writes a
        // trailing newline, so one empty element at the end is the printf's,
        // not an argument's.
        var argv = try String(contentsOf: argsURL, encoding: .utf8)
            .components(separatedBy: "\n")
        if argv.last?.isEmpty == true { argv.removeLast() }

        for flag in ["-p", "--verbose", "--strict-mcp-config"] {
            XCTAssertTrue(argv.contains(flag), "missing \(flag) in \(argv)")
        }
        func value(after flag: String) -> String? {
            guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
            return argv[i + 1]
        }
        XCTAssertEqual(value(after: "--input-format"), "stream-json")
        XCTAssertEqual(value(after: "--output-format"), "stream-json")
        XCTAssertEqual(value(after: "--model"), "haiku")
        XCTAssertEqual(value(after: "--mcp-config"),
                       tempDir.appendingPathComponent("mcp.json").path)
        XCTAssertEqual(value(after: "--append-system-prompt"), "BE TERSE")
        XCTAssertEqual(value(after: "--allowedTools"),
                       CompilerAllowlist.cliArguments()[1],
                       "the allowlist is Task 4's, passed through whole")
        XCTAssertEqual(value(after: "--tools"), "",
                       "--allowedTools only pre-approves; --tools \"\" is what "
                       + "removes the built-in Read/Glob/Grep")

        // The subprocess must not stand in the writer's project: the built-ins
        // are gone, and its cwd is a directory with nothing of theirs in it.
        let cwd = try String(contentsOf: cwdURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path,
            tempDir.appendingPathComponent("mcp.json")
                .deletingLastPathComponent().resolvingSymlinksInPath().path,
            "the session runs in its own config directory, never an inherited cwd")

        session.shutdown()
    }
}
