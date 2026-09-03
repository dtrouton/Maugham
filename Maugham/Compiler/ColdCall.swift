import Foundation

/// **The cold sessions' one runner** (translation pipeline spec §5, §11).
///
/// A reader, a collator, a gloss and an Ask-the-collator each need one thing
/// from a `claude -p` process: send one briefing, read one report, end. They
/// share this runner rather than each owning a warm session — warmth would buy
/// nothing (the whole briefing is re-sent every time) and would cost the one
/// property these callers exist for: **blindness**. A reader shown its last
/// notes defends them; a process that remembers nothing cannot.
///
/// Every runner this spawns is `ClaudeCLISession.Confinement.sealed` — no
/// bridge config, no allowlist, built-ins emptied — and `TripwireGrepTests
/// .test_coldCallNeverBridges` keeps this file from ever asking for anything
/// else. The tool-less half of "reads and returns" is therefore a fact about
/// the spawn arguments, pinned by `ClaudeCLISessionTests`, not an intention.
///
/// **One call at a time**, the orchestrators' own rule: a second call arriving
/// while one is out is refused with `CompilerRunFailure.Detail.runInFlight`
/// and spawns nothing. Sequencing the pipeline's legs is `TranslationPipeline`'s
/// job (Plan 3); this type holds no queue.
///
/// **The owner must call `shutdown()` or `detach()`.** `ClaudeCLISession`'s
/// contract inherited whole: a call in flight when the window closes is a
/// live, billing process otherwise. `ProjectWindow` owns this runner beside
/// the three orchestrators and every teardown arm `TranslatorEnvironmentTests`'
/// census pairs carries a `coldCall.shutdown()` — it is the census's fourth
/// sibling.
///
/// **`@Observable`, like the three orchestrators it sits beside** (P4 Task 6).
/// `isRunning` is what a surface disables its buttons on — the Translation
/// pane's two spot-checks share this runner with the pipeline's cold legs — and
/// a plain class would leave those buttons greyed out after a leg finished,
/// until something unrelated happened to redraw the pane.
@Observable @MainActor
final class ColdCall {

    typealias RunnerFactory = @MainActor (_ model: String) -> CompilerRunner

    /// The refusal a call gets before `configure` has run, or after `detach()`.
    static let notWiredDetail = "no cold-call runner is wired to this window"

    private var makeRunner: RunnerFactory?
    /// The process of the call in flight, so `cancel()`/`shutdown()` can reach
    /// it. `nil` between calls — there is nothing to keep.
    private var live: CompilerRunner?
    /// Bumped by every `shutdown()`. A call resuming from its `send` compares
    /// the generation it started under and, if a shutdown landed in between,
    /// does not touch the runner the shutdown already ended — `ClaudeCLISession
    /// .generation`'s reasoning, one owner up.
    private var generation = 0

    private(set) var isRunning = false

    /// Wire the runner factory. Called where the preferences exist — never
    /// from a `body`.
    func configure(makeRunner: @escaping RunnerFactory) {
        self.makeRunner = makeRunner
    }

    /// One cold call: spawn, send, end. `model` is the caller's — the compiler's
    /// setting, read at the call rather than captured here, so a change
    /// between two calls reaches the second.
    func call(message: String, preamble: String?, model: String) async -> CompilerRunEvent {
        guard let makeRunner else {
            return .failed(.sessionDied(detail: Self.notWiredDetail))
        }
        guard !isRunning else {
            return .failed(.sessionDied(detail: CompilerRunFailure.Detail.runInFlight))
        }
        let gen = generation
        isRunning = true
        let runner = makeRunner(model)
        live = runner

        let event = await runner.send(message: message, systemPreamble: preamble)

        guard generation == gen else {
            // A shutdown landed while the turn was out. It ended this runner
            // and cleared the surface; the event it resolved the send with is
            // the honest answer, and touching the runner again would end a
            // process twice.
            return event
        }
        runner.shutdown()
        live = nil
        isRunning = false
        return event
    }

    /// End the turn in flight. The call returns `cancelled` and its process is
    /// ended by `call` on the way out.
    func cancel() {
        live?.cancelCurrentRun()
    }

    /// End whatever is in flight: window close, project close, app quit, the
    /// AI toggle. Not optional on any of those paths.
    func shutdown() {
        generation &+= 1
        live?.shutdown()
        live = nil
        isRunning = false
    }

    /// Shut down and forget the window's factory, so a call after the window
    /// is gone refuses rather than spawning against it.
    func detach() {
        shutdown()
        makeRunner = nil
    }

    // MARK: - Production

    /// The real thing: a sealed `ClaudeCLISession`, enabled by the same toggle
    /// every other session reads at every spawn. `preferences` is captured
    /// weak for the orchestrators' reason — `nil` means refuse.
    static func productionRunnerFactory(preferences: UserPreferences) -> RunnerFactory {
        { [weak preferences] model in
            ClaudeCLISession(
                model: model,
                confinement: .sealed,
                cliOverride: nil,
                isEnabled: { preferences?.mcpEnabled ?? false },
                runTimeout: ClaudeCLISession.translationRunTimeout)
        }
    }
}
