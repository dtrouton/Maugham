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
        FLAG="\(slowFlagURL.path)"
        MODE="\(mode.rawValue)"

        trap 'echo bye >> "$EXITS"; exit 143' TERM
        trap 'echo bye >> "$EXITS"' EXIT

        echo "spawn" >> "$COUNTER"
        N=$(wc -l < "$COUNTER" | tr -d ' ')
        printf '%s\\n' "$@" > "$ARGS"

        if [ "$MODE" = "dieFirst" ] && [ "$N" -eq 1 ]; then
          IFS= read -r _line
          exit 3
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
        runTimeout: TimeInterval = 20
    ) -> ClaudeCLISession {
        ClaudeCLISession(
            model: "haiku",
            mcpConfigPath: tempDir.appendingPathComponent("mcp.json"),
            cliOverride: cli,
            isEnabled: isEnabled,
            idleTimeout: idleTimeout,
            runTimeout: runTimeout)
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

    /// The invocation is the one the spike measured, and the system preamble
    /// rides on `--append-system-prompt` (verified 2026-08-04 to compose with
    /// `-p` + stream-json in both directions) rather than being smuggled into
    /// the first user message.
    func test_spawnArgumentsMatchTheSpike() async throws {
        let cli = try makeFakeCLI(mode: .normal)
        let session = makeSession(cli: cli)

        _ = await session.send(message: "hello", systemPreamble: "BE TERSE")

        let argv = try String(contentsOf: argsURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)

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

        session.shutdown()
    }
}
