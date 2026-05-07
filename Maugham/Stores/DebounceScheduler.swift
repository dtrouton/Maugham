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

    public init(delay: Duration, action: @escaping (Payload) async -> Void) {
        self.delay = delay
        self.action = action
    }

    public func schedule(_ payload: Payload) {
        pendingTask?.cancel()
        pendingPayload = payload
        let captured = payload
        pendingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await action(captured)
            // Clear pending state if this run completed; another schedule may
            // have replaced pendingPayload while we slept, so only clear if
            // the captured payload still matches.
            if Self.areEqual(self.pendingPayload, captured) {
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

    /// Pointer/value equality fallback: we don't require Payload: Equatable,
    /// so we use a structural compare that's lossy but only used for the
    /// "was my payload still pending?" check inside the Task.
    private static func areEqual(_ a: Payload?, _ b: Payload) -> Bool {
        guard let a else { return false }
        return String(describing: a) == String(describing: b)
    }
}
