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
    /// starts fresh.
    case timedOut
    /// The subprocess ended without producing a result, was cancelled, or
    /// could not be written to. `detail` says which.
    case sessionDied(detail: String)
    /// A `result` event arrived carrying no usable text.
    case unusableOutput
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
}
