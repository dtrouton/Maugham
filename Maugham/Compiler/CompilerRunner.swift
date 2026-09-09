import Foundation

/// What one turn of the compiler's Claude session produced.
///
/// `started` exists for the streaming consumer (the Diagnostics pane's running
/// state); `send` itself resolves with a terminal event.
public enum CompilerRunEvent: Equatable, Sendable {
    case started
    /// The final structured message of a turn — the diagnostics payload.
    case resultText(String)
    case failed(CompilerRunFailure)
}

/// Every way a run can fail to produce a result. All of them are reportable
/// states, not thrown errors: the compiler is a background convenience and
/// must never surface as a crash or an alert the writer has to dismiss.
public enum CompilerRunFailure: Equatable, Sendable {
    /// No `claude` executable could be found (or the injected override is not
    /// executable).
    case cliNotFound
    /// The AI toggle is off. Checked before any spawn, on every send.
    case disabledByToggle
    /// The turn outran its budget. The session is torn down; the next send
    /// starts fresh. `Stall` says WHICH budget — the child went quiet, or the
    /// ceiling passed while it was still speaking — because the two mean
    /// different things to the writer (spec §2).
    case timedOut(Stall = .unknown)
    /// The subprocess ended without producing a result, was cancelled, or
    /// could not be written to. `detail` says which.
    case sessionDied(detail: String)
    /// A `result` event arrived carrying no usable text.
    case unusableOutput
}

extension CompilerRunFailure {

    /// The `sessionDied` details that describe **something the caller asked
    /// for** rather than something that went wrong.
    ///
    /// One spelling, shared by the site that mints each (`ClaudeCLISession`)
    /// and the site that reads it (`CompilerOrchestrator`, deciding whether to
    /// put a failure on screen) — the `MaughamEvent.personaKey` reasoning. Two
    /// copies of these strings is a reword away from a red banner that appears
    /// when the writer presses Cancel, or a real death that never surfaces.
    enum Detail {
        static let cancelled = "cancelled"
        static let sessionShutDown = "session shut down"
        static let runInFlight = "a run is already in flight"
    }

    /// Why a turn was stopped by a timer, and how far it had got.
    ///
    /// `silence` is what "genuinely hung" means — the CLI wrote nothing for
    /// `silenceTimeout`. `ceiling` is a child still speaking when the run's
    /// hard bound passed. `thinkingTokens` is the CLI's own running estimate
    /// at the moment of the stop — the last `system`/`thinking_tokens` event
    /// the session saw — and `nil` for a turn that reported none, or a runner
    /// that reads none.
    public struct Stall: Equatable, Sendable {
        public enum Cause: String, Equatable, Sendable {
            case silence, ceiling
        }
        public let cause: Cause
        public let after: TimeInterval
        public let thinkingTokens: Int?

        public init(cause: Cause, after: TimeInterval, thinkingTokens: Int? = nil) {
            self.cause = cause
            self.after = after
            self.thinkingTokens = thinkingTokens
        }

        /// A stop with no account of itself — the default so a `.timedOut()`
        /// built by a test or a legacy site still compiles and still says
        /// "took too long".
        public static let unknown = Stall(cause: .ceiling, after: 0)
    }

    /// Whether this failure is the writer's own action coming back at them.
    ///
    /// Cancel, project close, quit and the AI toggle all end a turn through
    /// `.sessionDied`, and so does a second run arriving while the first is
    /// still going. None of them is news: the compiler is a background
    /// convenience, and a surface that apologises for doing what it was told is
    /// the chirping IDE the spec is designed against.
    var isTheWritersOwnDoing: Bool {
        guard case .sessionDied(let detail) = self else { return false }
        return detail == Detail.cancelled
            || detail == Detail.sessionShutDown
            || detail == Detail.runInFlight
    }
}

/// The seam the compiler loop talks to. One production implementation today
/// (`ClaudeCLISession`, the warm process); the pre-authorized `--resume`
/// fallback (spec §3.4) swaps in here without touching a caller.
public protocol CompilerRunner: AnyObject {
    /// Run one turn. Never throws; every failure is a `.failed` event.
    ///
    /// `systemPreamble` governs the *session*, not the message — it is applied
    /// when a process is spawned and remembered so a respawn re-applies it.
    @MainActor func send(message: String, systemPreamble: String?) async -> CompilerRunEvent
    /// End the turn in flight. The runner stays usable.
    @MainActor func cancelCurrentRun()
    /// End the session: toggle-off, project close, quit, idle expiry.
    @MainActor func shutdown()
    /// Whether a turn is in flight (the run key is a quiet no-op while true).
    @MainActor var isRunning: Bool { get }
    /// Bumped whenever the session's process is retired or respawned, so a
    /// caller can tell *"the process that read my last run is the one reading
    /// this one"* from *"it respawned in between"*.
    ///
    /// This is what makes diffed-in context safe to send. A session that timed
    /// out, was cancelled or expired idle respawns silently on the next `send`
    /// with no memory of anything; `CompilerPrompt.runMessageV2`'s
    /// `previousBriefingHash` would then tell a brand-new process "Declared
    /// world, bible and pinned references: unchanged since last run.",
    /// describing a run it never saw, and it would judge the prose against
    /// nothing at all.
    @MainActor var sessionEpoch: Int { get }
    /// Where a turn's text goes **as it arrives**, or `nil` to stop listening.
    ///
    /// Chunks are fragments exactly as the transport cut them: they close no
    /// line, no sentence and no JSON object, so a caller accumulates and
    /// decides for itself when it has enough to read. What the seam guarantees
    /// is that a chunk belongs to the LIVE turn — a runner whose process was
    /// retired mid-turn drops that process's late deltas rather than splicing
    /// them into the turn that replaced it.
    ///
    /// **Whatever the stream said, the turn's own `resultText` is the truth.**
    /// The chunks are a preview: a caller may render off them, but must
    /// reconcile against the result when `send` resolves. They can be
    /// truncated, re-ordered by a model that revises itself, or absent
    /// entirely — a runner that cannot stream is a runner that never calls
    /// this, which is exactly what the default below is.
    @MainActor func setPartialHandler(_ handler: (@MainActor (String) -> Void)?)
    /// The timing of the LAST turn that resolved with a result — `nil` before
    /// any turn, after a failure, and for a runner that measures nothing.
    @MainActor var lastTurnTiming: RunTiming? { get }
    /// Where a live turn's progress goes, or `nil` to stop listening. A
    /// preview, like the partial text.
    @MainActor func setProgressHandler(_ handler: (@MainActor (RunProgress) -> Void)?)
}

public extension CompilerRunner {
    /// Streaming is optional, so a runner that does not do it needs to say
    /// nothing. The default is the whole of "this runner answers only at the
    /// end", and it is what keeps every existing conformer — including the
    /// suites' doubles — compiling unchanged.
    @MainActor func setPartialHandler(_ handler: (@MainActor (String) -> Void)?) {}
    /// Measuring is optional in the same way and for the same reason: a
    /// double that answers from an array has no turn to measure and no
    /// progress to report.
    @MainActor var lastTurnTiming: RunTiming? { nil }
    @MainActor func setProgressHandler(_ handler: (@MainActor (RunProgress) -> Void)?) {}
}
