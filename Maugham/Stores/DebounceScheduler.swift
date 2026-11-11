import Foundation

/// Cancel-and-restart Task helper. Schedule a payload; if a new payload arrives
/// before `delay` elapses, the old one is cancelled. `flush()` invokes the
/// pending payload immediately. `cancel()` discards it.
@MainActor
public final class DebounceScheduler<Payload: Sendable> {

    private let delay: Duration
    private let action: (Payload) async -> Void
    private var pendingTask: Task<Void, Never>?
    private var pendingPayload: Payload?
    /// Bumped by every `schedule`, so a run that finishes clears the pending
    /// state only when no newer schedule replaced it while it ran. (A payload
    /// compare cannot tell: every `Void` payload is equal, and a finishing
    /// autosave run used to clear the schedule a keystroke made during it,
    /// leaving `flush()` — and so `close()` — nothing to write.)
    private var generation = 0

    public init(delay: Duration, action: @escaping (Payload) async -> Void) {
        self.delay = delay
        self.action = action
    }

    public func schedule(_ payload: Payload) {
        pendingTask?.cancel()
        pendingPayload = payload
        generation += 1
        let mine = generation
        let captured = payload
        pendingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await action(captured)
            // Clear pending state if this run completed; another schedule may
            // have replaced it while we slept or ran, so only clear if none did.
            if self.generation == mine {
                self.pendingPayload = nil
                self.pendingTask = nil
            }
        }
    }

    public func flush() async {
        guard let payload = pendingPayload else { return }
        pendingTask?.cancel()
        pendingPayload = nil
        pendingTask = nil
        await action(payload)
    }

    public func cancel() {
        pendingTask?.cancel()
        pendingPayload = nil
        pendingTask = nil
    }
}
