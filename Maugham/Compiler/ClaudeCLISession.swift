import Foundation
import MaughamCore

/// The warm `claude -p` session behind the `CompilerRunner` seam (spec §3.4).
///
/// One long-lived subprocess speaks `--input-format stream-json` on stdin and
/// `--output-format stream-json` on stdout. Each run writes one user message
/// down stdin and resolves when a `result` event comes back, so the second run
/// of a session pays no spawn cost (spike: 3.0 s cold, 1.3 s warm).
///
/// Lifetime, verbatim from the spec:
/// - Entering Author never starts it; only the first run does (lazy spawn).
/// - It dies on the AI toggle turning off, project close, app quit.
/// - It dies quietly after an idle timeout.
/// - Death mid-run fails that run once; the next run starts a fresh session.
///
/// All state lives on the main actor. The blocking pipe read runs on
/// `FileHandle`'s own queue and hands whole lines back over a `Task`; locating
/// the CLI runs off-main too, because a login-shell probe can take seconds. The
/// main actor never waits on a subprocess — the `TectonicInvoker` discipline
/// (`Maugham/Publish/TectonicInvoker.swift`), one process longer-lived.
///
/// **The owner must call `shutdown()`.** Releasing a live session does NOT kill
/// its `claude`: `deinit` is nonisolated and cannot touch main-actor state, and
/// deallocating a `Process` neither signals nor reaps the child. An
/// un-shut-down session leaks a real, billing, API-calling process for as long
/// as it survives its closed stdin. Every teardown path Tasks 6–7 wire —
/// toggle-off, project close, app quit, window/persona teardown, and error
/// paths — has to reach `shutdown()`; this type cannot defend itself.
@MainActor
final class ClaudeCLISession: CompilerRunner {

    // MARK: - Injected

    private let model: String
    private let mcpConfigPath: URL
    private let cliOverride: URL?
    /// Finds `claude` when no override is given. Runs OFF the main actor
    /// (hence `@Sendable`) because the fallback shells out.
    private let locator: @Sendable () -> URL?
    /// Reads `UserPreferences.mcpEnabled`. Consulted before *every* spawn.
    private let isEnabled: () -> Bool
    private let idleTimeout: TimeInterval
    private let runTimeout: TimeInterval
    /// How long the death join will wait for the child's exit once stdout has
    /// reached EOF, before falling back to the statusless sentence. See
    /// `tryCompleteDeath`.
    private let deathReapGrace: TimeInterval

    /// The default of the above, and the only number here that answers "how
    /// long is a reap allowed to lag?" — generous against a loaded CI VM,
    /// short against the 120 s run timeout it exists to keep a death away from.
    static let deathReapGrace: TimeInterval = 2

    // MARK: - Session state

    private var process: Process?
    private var stdinHandle: FileHandle?
    /// Retained so the pipe outlives the handler that reads it.
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    /// The last few lines the current process wrote to stderr. Spec §8's
    /// "the essence of stderr": when the CLI dies without answering — an
    /// expired login is the case the spec names — "the CLI exited with status
    /// 1" is honest and names nothing the writer can act on.
    private var stderrTail: StderrTail?

    private var inFlight: CheckedContinuation<CompilerRunEvent, Never>?
    private var runTimeoutTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    /// The death join's two halves (issue #36): whether stdout has reached EOF,
    /// and the countdown that bounds the wait for the exit that has not landed
    /// yet. Both are plain main-actor state — see `tryCompleteDeath`.
    private var deathEOFSeen = false
    private var deathGraceTask: Task<Void, Never>?

    /// Bumped on every teardown. Callbacks from a retired process carry the
    /// generation they were installed with and are ignored once it moves on —
    /// without this a kill-and-respawn lets the dead process's EOF resolve the
    /// NEW turn.
    private var generation = 0
    /// Bumped on every send, so a late timer cannot resolve a later turn.
    private var runToken = 0

    /// Remembered so a respawn re-applies the session's system prompt.
    private var lastPreamble: String?

    /// Where the turn's text goes as it arrives, or `nil` for a caller that
    /// only wants the answer.
    ///
    /// **Owned by the caller, not by the process.** A respawn does not clear
    /// it: the handler describes who is listening, which does not change
    /// because the CLI died and came back. What a retired process's deltas
    /// cannot do is reach it — that guard is `receive`'s, shared with the
    /// `result` path, and the reason the two travel the same road.
    private var partialHandler: (@MainActor (String) -> Void)?

    /// Resolved once per session and reused by every respawn — locating the
    /// CLI can cost a login shell, and death/cancel/timeout/toggle cycles all
    /// respawn. Only a SUCCESS is cached: a writer who installs `claude`
    /// mid-session should not have to restart the app.
    private var resolvedCLI: URL?

    private(set) var isRunning = false

    /// Test seam: whether a subprocess is currently held and alive.
    var hasLiveProcess: Bool { process?.isRunning == true }

    /// The `CompilerRunner` seam's respawn signal, and the generation a spawn's
    /// reader callbacks carry — the same counter, because they are the same
    /// question asked from inside and outside. See the protocol.
    var sessionEpoch: Int { generation }

    /// Test seam: deliver a stream line exactly as the reader installed for
    /// `generation` would.
    ///
    /// A stale callback cannot be arranged from outside — `teardown` nils the
    /// handler, so the only real window is a callback already enqueued on the
    /// main actor, which no test can schedule deterministically. This is the
    /// same call the reader makes with the generation frozen into its closure
    /// at spawn (`installReader`), so a test can pin the guard that stops a
    /// retired process from resolving the live turn.
    func deliverAsIfFromProcess(line: String, generation gen: Int) {
        receive(line: line, generation: gen)
    }

    init(model: String,
         mcpConfigPath: URL,
         cliOverride: URL?,
         isEnabled: @escaping () -> Bool,
         idleTimeout: TimeInterval = 600,
         runTimeout: TimeInterval = 120,
         deathReapGrace: TimeInterval = ClaudeCLISession.deathReapGrace,
         locator: @escaping @Sendable () -> URL? = { ClaudeCLISession.locateCLI() }) {
        self.model = model
        self.mcpConfigPath = mcpConfigPath
        self.cliOverride = cliOverride
        self.isEnabled = isEnabled
        self.idleTimeout = idleTimeout
        self.runTimeout = runTimeout
        self.deathReapGrace = deathReapGrace
        self.locator = locator
    }

    deinit {
        // Nothing to clean up here, and that is a liability rather than a
        // design: `deinit` is nonisolated and cannot touch this class's
        // main-actor state, so it cannot terminate the child. Dropping a
        // `Process` does not signal or reap the OS process it wrapped — a
        // session released without `shutdown()` ORPHANS a live `claude` until
        // it notices its closed stdin, which is behaviour of the real CLI we
        // have not verified. The timers hold only weak references, so those do
        // die with the session. See the type's doc comment.
    }

    // MARK: - CompilerRunner

    func send(message: String, systemPreamble: String?) async -> CompilerRunEvent {
        // The toggle is enforced HERE, not at the UI. Before any spawn, every
        // time — a session already warm when the writer turns Claude off must
        // not answer one more run.
        guard isEnabled() else {
            teardown()
            return .failed(.disabledByToggle)
        }
        // `isRunning` and not just `inFlight`: resolving the CLI suspends, and
        // the continuation that sets `inFlight` is stored only after it. A
        // second send arriving in that window would otherwise sail past this
        // guard and spawn over the first.
        guard !isRunning, inFlight == nil else {
            return .failed(.sessionDied(detail: CompilerRunFailure.Detail.runInFlight))
        }
        if let systemPreamble { lastPreamble = systemPreamble }

        // Claim the turn synchronously, before the first suspension point.
        runToken &+= 1
        let token = runToken
        let epoch = generation
        idleTask?.cancel()
        idleTask = nil
        isRunning = true

        guard let cli = await resolveCLI() else {
            relinquish(token: token)
            return .failed(.cliNotFound)
        }
        // Both can have changed while we were off-main: the writer may have
        // turned Claude off, or shut the session down, mid-probe. `generation`
        // moves on every teardown, so it detects a shutdown/cancel that landed
        // in the window — without this the session would spawn a process
        // moments after being told to stop.
        guard generation == epoch, runToken == token else {
            relinquish(token: token)
            return .failed(.sessionDied(detail: CompilerRunFailure.Detail.sessionShutDown))
        }
        guard isEnabled() else {
            relinquish(token: token)
            teardown()
            return .failed(.disabledByToggle)
        }

        if let failure = ensureProcess(cli: cli) {
            relinquish(token: token)
            return .failed(failure)
        }
        guard let stdin = stdinHandle else {
            relinquish(token: token)
            return .failed(.sessionDied(detail: "no stdin on the spawned CLI"))
        }
        guard let payload = Self.userMessageLine(message) else {
            relinquish(token: token)
            return .failed(.unusableOutput)
        }

        let event = await withCheckedContinuation { (cont: CheckedContinuation<CompilerRunEvent, Never>) in
            inFlight = cont
            do {
                try stdin.write(contentsOf: payload)
            } catch {
                // A broken pipe means the CLI is gone; SIGPIPE is already
                // process-wide ignored (MCPServer installs the handler), so
                // this surfaces as EPIPE rather than a signal.
                teardown()
                resolve(.failed(.sessionDied(detail: "stdin write failed: \(error.localizedDescription)")),
                        token: token)
                return
            }
            armRunTimeout(token: token)
        }

        // Only while a process still stands. A turn resolved BY a teardown —
        // shutdown, cancel, timeout, death — must not re-arm the idle timer it
        // just cancelled; `send` cannot otherwise tell "a real turn ended" from
        // "you were shut down out from under me".
        if process != nil { armIdleTimer() }
        return event
    }

    func setPartialHandler(_ handler: (@MainActor (String) -> Void)?) {
        partialHandler = handler
    }

    func cancelCurrentRun() {
        // `isRunning`, not `inFlight`: a send still resolving its CLI has no
        // continuation yet, and must still be stoppable — `teardown` moves
        // `generation`, which is what aborts it after its suspension.
        guard isRunning else { return }
        let token = runToken
        // stream-json offers no mid-turn interrupt: ending the turn means
        // ending the process. The next send respawns (the brief's sanctioned
        // implementation — the contract is that the next send works).
        teardown()
        resolve(.failed(.sessionDied(detail: CompilerRunFailure.Detail.cancelled)), token: token)
        isRunning = false
    }

    func shutdown() {
        let token = runToken
        idleTask?.cancel()
        idleTask = nil
        teardown()
        resolve(.failed(.sessionDied(detail: CompilerRunFailure.Detail.sessionShutDown)), token: token)
        isRunning = false
    }

    // MARK: - Spawn

    /// Ensure a live subprocess, spawning lazily. Returns a failure when one
    /// could not be had; `nil` on success.
    private func ensureProcess(cli: URL) -> CompilerRunFailure? {
        // `deathEOFSeen` as well as `isRunning`: a process whose stdout has
        // reached EOF can never answer again, and while the death join waits
        // out its grace for the exit that process is still technically alive.
        // Before the join, EOF tore down immediately and the next send got a
        // fresh CLI; without this a send landing inside the grace would write
        // its turn down a dead session's stdin. Nothing is in flight here — a
        // turn mid-join holds the session against a second send — so tearing
        // down early only brings forward what the completion would have done.
        if let process, process.isRunning, !deathEOFSeen { return nil }
        teardown()

        let proc = Process()
        proc.executableURL = cli
        proc.arguments = Self.arguments(
            model: model, mcpConfigPath: mcpConfigPath, preamble: lastPreamble)
        proc.environment = ProcessInfo.processInfo.environment
        // Defence in depth behind `--tools ""`. An unset `currentDirectoryURL`
        // inherits Maugham's own, which for a launched `.app` is `/` and for a
        // debug run is the developer's checkout — either way a directory the
        // writer's work can sit under. The session's own config directory holds
        // nothing but the bridge config it was handed. Created rather than
        // assumed: `Process.run` throws on a cwd that does not exist, and that
        // would reach the writer as "Claude Code isn't installed".
        let workingDirectory = mcpConfigPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: true)
        proc.currentDirectoryURL = workingDirectory

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        generation &+= 1
        let gen = generation
        installReader(on: stdout.fileHandleForReading, generation: gen)
        // Drain stderr so a chatty CLI cannot fill the pipe and wedge itself —
        // and keep the tail of what it drains, which is all `receiveEOF` has to
        // say WHY a death happened. The EOF guard is not optional: once the
        // child's stderr closes, GCD reports the fd continuously readable, and
        // a handler that never unregisters itself spins that queue until
        // teardown happens to nil it.
        let tail = StderrTail()
        stderr.fileHandleForReading.readabilityHandler = { fh in
            if tail.consume(from: fh) { fh.readabilityHandler = nil }
        }
        // The SECOND death signal (issue #36): stdout's EOF and the child's
        // exit are independent deliveries with no ordering, and the EOF used to
        // carry the whole verdict — polling `isRunning` at that instant and
        // giving up on the status when the reap lagged. Now both funnel into
        // one completion. Same hop as every other callback: nothing off the
        // main actor touches session state, and the generation is frozen in
        // here exactly as the reader's is.
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processDidExit(generation: gen) }
        }

        do {
            try proc.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            proc.terminationHandler = nil
            return .cliNotFound
        }

        process = proc
        stdinHandle = stdin.fileHandleForWriting
        stdoutPipe = stdout
        stderrPipe = stderr
        stderrTail = tail
        return nil
    }

    /// The invocation the spike measured, plus Task 4's allowlist.
    ///
    /// The system preamble rides on `--append-system-prompt` rather than being
    /// prepended to the first user message: verified 2026-08-04 to compose with
    /// `-p` + stream-json in both directions, and it governs the whole session
    /// rather than one turn, which is what the caller means by "preamble".
    ///
    /// **The membrane is two flags, and the enumerated one is the weaker
    /// half.** `--allowedTools` removes nothing: it pre-approves the tools it
    /// names so they skip the permission prompt. Under `-p` that does leave
    /// Bash/Edit/Write unreachable, because they would prompt — but the
    /// built-in Read/Glob/Grep never prompt inside the working directory, so
    /// the allowlist alone leaves the spawned model free to read any file it
    /// can reach. `--tools ""` empties the built-in set, and it is what makes
    /// "no file access" true rather than intended. Verified live against
    /// `claude` 2.1.222 on 2026-08-05 in both directions, and separately that
    /// `--tools ""` does not disturb the MCP tools, which arrive through
    /// `--mcp-config` rather than from the built-in set.
    static func arguments(model: String, mcpConfigPath: URL, preamble: String?) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--mcp-config", mcpConfigPath.path,
            "--strict-mcp-config",
            // **The stream has to be asked for.** Without this the CLI batches
            // the whole turn into its `result` and the writer waits out a
            // two-minute check with nothing on the pane; with it the same turn
            // emits `stream_event` lines from about four seconds in (spiked
            // 2026-08-08). It changes nothing about how a turn ENDS — the
            // `result` event is still the only thing that resolves one.
            "--include-partial-messages",
            "--tools", ""
        ]
        if let preamble, !preamble.isEmpty {
            args += ["--append-system-prompt", preamble]
        }
        args += CompilerAllowlist.cliArguments()
        return args
    }

    /// One stream-json user message, newline-terminated.
    static func userMessageLine(_ text: String) -> Data? {
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return data + Data("\n".utf8)
    }

    // MARK: - Locating the CLI

    /// Resolve the CLI once per session, off the main actor.
    ///
    /// The fallback shells out to a login shell, which on a real machine sources
    /// nvm/pyenv/oh-my-zsh and can take hundreds of milliseconds to seconds.
    /// Run inline on the main actor that is a frozen window and a spinning
    /// beachball, and it would run again on every respawn — so it goes to a
    /// detached task and its answer is kept.
    private func resolveCLI() async -> URL? {
        if let resolvedCLI { return resolvedCLI }
        if let cliOverride {
            guard FileManager.default.isExecutableFile(atPath: cliOverride.path) else {
                return nil
            }
            resolvedCLI = cliOverride
            return cliOverride
        }
        let locator = self.locator
        let found = await Task.detached(priority: .userInitiated) { locator() }.value
        // Only a success is cached — see `resolvedCLI`.
        if let found { resolvedCLI = found }
        return found
    }

    /// Find `claude` the way the writer's shell would.
    ///
    /// A GUI app inherits launchd's minimal PATH, which does not include
    /// `~/.local/bin` or Homebrew — so the plain `command -v` probe that
    /// `UpdateInstaller.python3Available()` uses would answer "no CLI" on a
    /// machine that plainly has one. Well-known install locations are checked
    /// first (no subprocess), then a *login* shell is asked, which sources the
    /// writer's profile and therefore sees their real PATH.
    /// `nonisolated` on purpose: this is the thing that must never run on the
    /// main actor, and the compiler should enforce that rather than a comment.
    nonisolated static func locateCLI() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ]
        for candidate in candidates
        where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        guard let found = loginShellProbe("command -v claude"),
              FileManager.default.isExecutableFile(atPath: found) else { return nil }
        return URL(fileURLWithPath: found)
    }

    /// Run `command` in a login shell and return its trimmed first line of
    /// stdout, or nil. Mirrors `UpdateInstaller.python3Available()`'s probe,
    /// widened to capture the path rather than only the exit status.
    nonisolated private static func loginShellProbe(_ command: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n").first
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - The bridge config

    /// Write the per-session `--mcp-config` file: exactly Maugham's own server,
    /// through the same bridge binary the setup sheet installs. `env` is
    /// omitted when the default socket is wanted, matching
    /// `ClaudeDesktopConfig.merge`. The server key comes from `BuildVariant`
    /// (tripwire 13) so a Dev build talks to the Dev socket.
    static func writeMCPConfig(bridgeBinary: URL, socketPath: String?, to dir: URL) throws -> URL {
        var entry: [String: Any] = ["command": bridgeBinary.path]
        if let socketPath {
            entry["env"] = ["MAUGHAM_MCP_SOCKET": socketPath]
        }
        let root: [String: Any] = [
            "mcpServers": [BuildVariant.current.mcpServerKey: entry]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("compiler-mcp-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Reading the stream

    /// Install the stdout reader. It runs on `FileHandle`'s own queue, splits
    /// on newlines there, and hands whole lines back to the main actor. EOF —
    /// which arrives *in order* behind the last byte of data, unlike the
    /// termination handler — is what reports the process's death, so a CLI
    /// that prints its result and then exits still gets its result read.
    private func installReader(on handle: FileHandle, generation gen: Int) {
        let accumulator = LineAccumulator()
        handle.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            let session = self
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                let tail = accumulator.drain()
                Task { @MainActor in
                    if let tail { session?.receive(line: tail, generation: gen) }
                    session?.receiveEOF(generation: gen)
                }
                return
            }
            let lines = accumulator.take(chunk)
            guard !lines.isEmpty else { return }
            Task { @MainActor in
                for line in lines { session?.receive(line: line, generation: gen) }
            }
        }
    }

    private func receive(line: String, generation gen: Int) {
        guard gen == generation, inFlight != nil else { return }
        switch Self.classify(line: line) {
        case .ignore:
            return
        case .partialText(let chunk):
            // The same two guards the result path is already behind, which is
            // the whole reason this rides `receive` rather than being read off
            // the pipe on its own: a retired process's enqueued deltas would
            // otherwise be spliced into the live run's report, and the run they
            // corrupted would still resolve normally.
            partialHandler?(chunk)
        case .result(let text):
            resolve(.resultText(text), token: runToken)
        case .unusableResult:
            resolve(.failed(.unusableOutput), token: runToken)
        }
    }

    /// stdout reached EOF: every byte the child wrote has been read. One half
    /// of the death join, and the half that anchors it.
    private func receiveEOF(generation gen: Int) {
        guard gen == generation else { return }
        deathEOFSeen = true
        tryCompleteDeath(generation: gen, graceExpired: false)
    }

    /// The child was reaped: its status is knowable, and its stderr has no
    /// writer left. The other half.
    private func processDidExit(generation gen: Int) {
        guard gen == generation else { return }
        tryCompleteDeath(generation: gen, graceExpired: false)
    }

    /// The death verdict, spoken once, after BOTH halves have landed — EOF on
    /// stdout (every byte read; the anchor, because EOF is ordered behind the
    /// last byte and an exit-first resolve would truncate a CLI that prints its
    /// result and dies) and the child's exit (the status, and the proof that
    /// `stderrEssence`'s synchronous drain cannot block: a reaped writer holds
    /// no fd). `DeclaredWorldDeriver.OneShotOutput` is the same join one
    /// abstraction over; here the lock is unnecessary because both signals hop
    /// to the main actor and the GENERATION guard is the mutual exclusion — a
    /// shutdown, cancel or timeout inside the wait bumps `generation` via
    /// `teardown` and resolves the turn itself, and the late completion bails
    /// above. The grace is the bounded-join door: if the exit never arrives (a
    /// stranger holding the process), fall back to the statusless sentence
    /// rather than hanging into the run timeout.
    private func tryCompleteDeath(generation gen: Int, graceExpired: Bool) {
        guard gen == generation, deathEOFSeen else { return }
        let exited = process.map { !$0.isRunning } ?? true
        if !exited && !graceExpired {
            if deathGraceTask == nil {
                let budget = deathReapGrace
                deathGraceTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.tryCompleteDeath(generation: gen, graceExpired: true)
                }
            }
            return
        }
        deathGraceTask?.cancel()
        deathGraceTask = nil
        // Read after the join and before `teardown` drops the pipe. Only for a
        // nonzero exit — a clean one has nothing to explain. The synchronous
        // read is safe by construction now rather than by inference: the join
        // only reaches here with the child reaped (or the grace spent, where
        // the status is nil and nothing is read at all), so the pipe's write
        // end is closed and `availableData` returns at EOF rather than waiting
        // for a writer that still exists. It is also why the *why* survives:
        // stderr written after the stdout close has landed by the time the
        // exit does.
        let token = runToken
        let hadRun = inFlight != nil
        let status = process.map { $0.isRunning ? nil : $0.terminationStatus } ?? nil
        let essence = (status ?? 0) != 0 ? stderrEssence() : nil
        teardown()
        if hadRun {
            let detail: String
            if let status {
                detail = essence.map { "the CLI exited with status \(status): \($0)" }
                    ?? "the CLI exited with status \(status)"
            } else {
                detail = "the CLI closed its output"
            }
            resolve(.failed(.sessionDied(detail: detail)), token: token)
        }
    }

    /// The last thing the dying process said, or `nil` if it went quietly.
    ///
    /// The handler runs on `FileHandle`'s queue and may not have seen the final
    /// write yet — stdout's EOF and stderr's readability are two independent
    /// deliveries with no ordering between them — so this finishes the read
    /// itself rather than reporting whatever happened to have arrived. Both
    /// paths read *inside* `StderrTail`'s lock, so the drain and a handler
    /// still in flight cannot both be inside `availableData` at once.
    private func stderrEssence() -> String? {
        guard let handle = stderrPipe?.fileHandleForReading, let tail = stderrTail else {
            return nil
        }
        handle.readabilityHandler = nil
        tail.drain(from: handle)
        return tail.lastNonEmptyLine()
    }

    enum StreamLine: Equatable {
        /// Anything that is neither a terminal `result` nor a fragment of the
        /// assistant's answer: `system`, `assistant`, `rate_limit_event`, a
        /// block opening or closing, the model's own thinking, a type that
        /// does not exist yet, or a line that is not JSON at all.
        case ignore
        /// A fragment of the answer, mid-turn. Fragments are exactly as the
        /// CLI cut them — they close no sentence and respect no boundary, so
        /// a reader has to accumulate before it can parse anything.
        case partialText(String)
        case result(String)
        case unusableResult
    }

    /// Classify one stream-json line. Keys on `type` and tolerates everything
    /// else (spike note §Consequences). Note the real CLI does not put `type`
    /// first in the object, so this parses rather than sniffs.
    static func classify(line: String) -> StreamLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let type = dict["type"] as? String
        else { return .ignore }
        if type == streamEventType { return classifyStreamEvent(dict) }
        guard type == "result" else { return .ignore }
        guard let text = dict["result"] as? String, !text.isEmpty else {
            return .unusableResult
        }
        return .result(text)
    }

    /// The wire names of the partial-message stream, in one place, captured
    /// from `claude` 2.1.222 on 2026-08-08 rather than guessed
    /// (`ClaudeCLISessionTests`' `captured…` constants are the same turn's
    /// lines verbatim).
    private static let streamEventType = "stream_event"
    private static let deltaEventType = "content_block_delta"
    private static let textDeltaType = "text_delta"

    /// One `stream_event`, which nests the Anthropic streaming event under
    /// `event`.
    ///
    /// **Only `text_delta` is the answer.** A turn's deltas come in three
    /// kinds and all three arrive as `content_block_delta`, differing one
    /// level deeper: `thinking_delta` carries the model's private reasoning,
    /// `signature_delta` carries an opaque blob, and `text_delta` carries what
    /// the assistant is actually saying. A classifier keyed on
    /// `content_block_delta` alone would hand the orchestrator a report made
    /// of the model thinking out loud — and nothing downstream could tell,
    /// because it would parse as prose that simply contains no sections.
    private static func classifyStreamEvent(_ dict: [String: Any]) -> StreamLine {
        guard let event = dict["event"] as? [String: Any],
              event["type"] as? String == deltaEventType,
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == textDeltaType,
              let text = delta["text"] as? String, !text.isEmpty
        else { return .ignore }
        return .partialText(text)
    }

    // MARK: - Resolution, timers, teardown

    /// Drop this turn's claim on the session — but only while it still holds
    /// it. A `send` that has been superseded must touch NOTHING.
    ///
    /// `send` suspends before it stores its continuation (resolving the CLI can
    /// cost a login shell), so a cancelled turn can still be sitting in that
    /// window when its replacement claims the session. Resetting `isRunning`
    /// unconditionally on the way out lets the stale turn clear the live one's
    /// claim, and `cancelCurrentRun` — which reads `isRunning` — then silently
    /// no-ops against a real process, leaving the writer no way to stop a run
    /// short of the run timeout. This is `resolve`'s token discipline applied
    /// to the branches that never reach `resolve`.
    ///
    /// Deliberately NOT used by `cancelCurrentRun`/`shutdown`: those are
    /// session-level verbs, not one turn's, and mean "nothing is running" no
    /// matter whose turn it was.
    private func relinquish(token: Int) {
        guard token == runToken else { return }
        isRunning = false
    }

    private func resolve(_ event: CompilerRunEvent, token: Int) {
        guard token == runToken, let cont = inFlight else { return }
        inFlight = nil
        isRunning = false
        runTimeoutTask?.cancel()
        runTimeoutTask = nil
        cont.resume(returning: event)
    }

    private func armRunTimeout(token: Int) {
        runTimeoutTask?.cancel()
        let budget = runTimeout
        runTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.runDidTimeOut(token: token)
        }
    }

    private func runDidTimeOut(token: Int) {
        guard token == runToken, inFlight != nil else { return }
        // The CLI is still working on the turn; ending it means ending the
        // process. The next send respawns.
        teardown()
        resolve(.failed(.timedOut), token: token)
    }

    private func armIdleTimer() {
        idleTask?.cancel()
        let budget = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.idleDidExpire()
        }
    }

    private func idleDidExpire() {
        guard inFlight == nil else { return }
        teardown()
    }

    /// Drop the subprocess. Retires the current generation first so no
    /// in-flight callback from the dying process can touch the next one.
    private func teardown() {
        generation &+= 1
        runTimeoutTask?.cancel()
        runTimeoutTask = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        deathGraceTask?.cancel()
        deathGraceTask = nil
        deathEOFSeen = false
        try? stdinHandle?.close()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        stdoutPipe = nil
        stderrPipe = nil
        stderrTail = nil
    }
}

/// The tail of a process's stderr — about the last 10 lines, capped at 2 KB.
///
/// Bounded on purpose: this exists so a death can name its cause, not so the
/// session can hold a log. A CLI that writes a megabyte of progress chatter
/// before failing costs the same two kilobytes as one that writes a sentence.
///
/// `@unchecked Sendable` for `LineAccumulator`'s reason: every access is under
/// `lock`, and `FileHandle`'s readability handler is a `@Sendable` closure that
/// must not capture mutable state. Unlike `LineAccumulator` it performs the
/// *read* under the lock too, so the synchronous drain at EOF cannot race a
/// handler still in flight for the same bytes.
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let byteLimit = 2048
    private let lineLimit = 10

    /// Take whatever `handle` has ready. Returns `true` at EOF, which is the
    /// signal for the handler to unregister itself.
    func consume(from handle: FileHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return true }
        buffer.append(chunk)
        trimLocked()
        return false
    }

    /// Everything left, up to EOF. **Only safe once the writer is gone** — see
    /// `ClaudeCLISession.stderrEssence`.
    func drain(from handle: FileHandle) {
        while !consume(from: handle) {}
    }

    /// The last line with something on it. `String(decoding:)` rather than the
    /// failable initialiser: the byte cap can cut a multi-byte character in
    /// half, and a replacement character somewhere off the front of a tail is
    /// better than losing the sentence.
    func lastNonEmptyLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    private func trimLocked() {
        if buffer.count > byteLimit {
            buffer = Data(buffer.suffix(byteLimit))
        }
        var newlines = 0
        var index = buffer.endIndex
        while index > buffer.startIndex {
            index = buffer.index(before: index)
            guard buffer[index] == UInt8(ascii: "\n") else { continue }
            newlines += 1
            if newlines > lineLimit {
                buffer = Data(buffer[buffer.index(after: index)...])
                return
            }
        }
    }
}

/// Splits a byte stream into newline-delimited lines off the main actor.
///
/// `@unchecked Sendable`: the buffer is only ever touched under `lock`. It is
/// a class rather than a captured `var` because `FileHandle`'s readability
/// handler is a `@Sendable` closure and must not capture mutable state.
private final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    /// Append `chunk` and return every complete line it closed.
    func take(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []
        while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer = buffer[buffer.index(after: index)...]
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }

    /// Whatever is left when the stream closes without a final newline.
    func drain() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        let rest = String(data: buffer, encoding: .utf8)
        buffer = Data()
        return rest
    }
}
