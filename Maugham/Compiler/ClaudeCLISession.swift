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

    // MARK: - Session state

    private var process: Process?
    private var stdinHandle: FileHandle?
    /// Retained so the pipe outlives the handler that reads it.
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var inFlight: CheckedContinuation<CompilerRunEvent, Never>?
    private var runTimeoutTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    /// Bumped on every teardown. Callbacks from a retired process carry the
    /// generation they were installed with and are ignored once it moves on —
    /// without this a kill-and-respawn lets the dead process's EOF resolve the
    /// NEW turn.
    private var generation = 0
    /// Bumped on every send, so a late timer cannot resolve a later turn.
    private var runToken = 0

    /// Remembered so a respawn re-applies the session's system prompt.
    private var lastPreamble: String?

    /// Resolved once per session and reused by every respawn — locating the
    /// CLI can cost a login shell, and death/cancel/timeout/toggle cycles all
    /// respawn. Only a SUCCESS is cached: a writer who installs `claude`
    /// mid-session should not have to restart the app.
    private var resolvedCLI: URL?

    private(set) var isRunning = false

    /// Test seam: whether a subprocess is currently held and alive.
    var hasLiveProcess: Bool { process?.isRunning == true }

    /// Test seam: the generation a spawn's reader callbacks carry.
    var currentGeneration: Int { generation }

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
         locator: @escaping @Sendable () -> URL? = { ClaudeCLISession.locateCLI() }) {
        self.model = model
        self.mcpConfigPath = mcpConfigPath
        self.cliOverride = cliOverride
        self.isEnabled = isEnabled
        self.idleTimeout = idleTimeout
        self.runTimeout = runTimeout
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
            return .failed(.sessionDied(detail: "a run is already in flight"))
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
            isRunning = false
            return .failed(.cliNotFound)
        }
        // Both can have changed while we were off-main: the writer may have
        // turned Claude off, or shut the session down, mid-probe. `generation`
        // moves on every teardown, so it detects a shutdown/cancel that landed
        // in the window — without this the session would spawn a process
        // moments after being told to stop.
        guard generation == epoch, runToken == token else {
            isRunning = false
            return .failed(.sessionDied(detail: "session shut down"))
        }
        guard isEnabled() else {
            isRunning = false
            teardown()
            return .failed(.disabledByToggle)
        }

        if let failure = ensureProcess(cli: cli) {
            isRunning = false
            return .failed(failure)
        }
        guard let stdin = stdinHandle else {
            isRunning = false
            return .failed(.sessionDied(detail: "no stdin on the spawned CLI"))
        }
        guard let payload = Self.userMessageLine(message) else {
            isRunning = false
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
        resolve(.failed(.sessionDied(detail: "cancelled")), token: token)
        isRunning = false
    }

    func shutdown() {
        let token = runToken
        idleTask?.cancel()
        idleTask = nil
        teardown()
        resolve(.failed(.sessionDied(detail: "session shut down")), token: token)
        isRunning = false
    }

    // MARK: - Spawn

    /// Ensure a live subprocess, spawning lazily. Returns a failure when one
    /// could not be had; `nil` on success.
    private func ensureProcess(cli: URL) -> CompilerRunFailure? {
        if let process, process.isRunning { return nil }
        teardown()

        let proc = Process()
        proc.executableURL = cli
        proc.arguments = Self.arguments(
            model: model, mcpConfigPath: mcpConfigPath, preamble: lastPreamble)
        proc.environment = ProcessInfo.processInfo.environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        generation &+= 1
        let gen = generation
        installReader(on: stdout.fileHandleForReading, generation: gen)
        // Drain stderr so a chatty CLI cannot fill the pipe and wedge itself.
        // The EOF guard is not optional: once the child's stderr closes, GCD
        // reports the fd continuously readable, and a handler that never
        // unregisters itself spins that queue until teardown happens to nil it.
        stderr.fileHandleForReading.readabilityHandler = { fh in
            if fh.availableData.isEmpty { fh.readabilityHandler = nil }
        }

        do {
            try proc.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return .cliNotFound
        }

        process = proc
        stdinHandle = stdin.fileHandleForWriting
        stdoutPipe = stdout
        stderrPipe = stderr
        return nil
    }

    /// The invocation the spike measured, plus Task 4's allowlist.
    ///
    /// The system preamble rides on `--append-system-prompt` rather than being
    /// prepended to the first user message: verified 2026-08-04 to compose with
    /// `-p` + stream-json in both directions, and it governs the whole session
    /// rather than one turn, which is what the caller means by "preamble".
    static func arguments(model: String, mcpConfigPath: URL, preamble: String?) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--mcp-config", mcpConfigPath.path,
            "--strict-mcp-config"
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
        case .result(let text):
            resolve(.resultText(text), token: runToken)
        case .unusableResult:
            resolve(.failed(.unusableOutput), token: runToken)
        }
    }

    private func receiveEOF(generation gen: Int) {
        guard gen == generation else { return }
        let token = runToken
        let hadRun = inFlight != nil
        let status = process.map { $0.isRunning ? nil : $0.terminationStatus } ?? nil
        teardown()
        if hadRun {
            let detail = status.map { "the CLI exited with status \($0)" }
                ?? "the CLI closed its output"
            resolve(.failed(.sessionDied(detail: detail)), token: token)
        }
    }

    enum StreamLine: Equatable {
        /// Anything that is not a terminal `result`: `system`, `assistant`,
        /// `rate_limit_event`, a type that does not exist yet, or a line that
        /// is not JSON at all.
        case ignore
        case result(String)
        case unusableResult
    }

    /// Classify one stream-json line. Keys on `type == "result"` and tolerates
    /// everything else (spike note §Consequences). Note the real CLI does not
    /// put `type` first in the object, so this parses rather than sniffs.
    static func classify(line: String) -> StreamLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let type = dict["type"] as? String,
              type == "result" else { return .ignore }
        guard let text = dict["result"] as? String, !text.isEmpty else {
            return .unusableResult
        }
        return .result(text)
    }

    // MARK: - Resolution, timers, teardown

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
        try? stdinHandle?.close()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        stdoutPipe = nil
        stderrPipe = nil
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
