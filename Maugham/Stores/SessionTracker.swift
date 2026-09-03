import Foundation

/// In-memory tracker for the active writing session. Driven by
/// DocumentStore's idle timer; the tracker itself doesn't schedule
/// any timers — it only records start/end times and word-count
/// snapshots.
@MainActor
public final class SessionTracker {

    public struct ActiveSession: Equatable {
        public let startedAt: Date
        public let lastChangeAt: Date
        public let startWordCount: Int
        public let deviceId: String?
    }

    /// How long a document must go untouched before the sitting is over.
    /// The one constant: `DocumentStore` schedules its idle timer on it and
    /// `ProcessSignals` cuts its op-derived sessions on it, so the Statistics
    /// window and the compiler's briefing cannot disagree about how many
    /// sessions a writer has had.
    ///
    /// **`nonisolated`, unlike everything else on this class.** The tracker is
    /// `@MainActor` because it holds mutable session state; this is a `let`
    /// `TimeInterval`, which is `Sendable` and has nothing to protect. It has
    /// to be reachable from a nonisolated context because one of its two
    /// readers is one: `ProcessSignals` is a pure value the Statistics window
    /// computes on a detached task (`ProjectPractice.derive`). Main-actor
    /// isolation on the constant is a Swift 6 error at those call sites, and
    /// duplicating the number to dodge it is exactly the disagreement the
    /// single constant exists to prevent.
    nonisolated public static let idleThreshold: TimeInterval = 30 * 60

    public private(set) var activeSession: ActiveSession?

    public init() {}

    /// Called on every text change. Starts a session if none is active;
    /// otherwise updates `lastChangeAt` (the idle-timer reset signal).
    public func recordTextChange(
        at date: Date,
        projectWordCount: Int,
        deviceId: String? = nil
    ) {
        if let existing = activeSession {
            activeSession = ActiveSession(
                startedAt: existing.startedAt,
                lastChangeAt: date,
                startWordCount: existing.startWordCount,
                deviceId: existing.deviceId)
        } else {
            activeSession = ActiveSession(
                startedAt: date,
                lastChangeAt: date,
                startWordCount: projectWordCount,
                deviceId: deviceId)
        }
    }

    /// Called by the idle timer. If there's an active session, finalise
    /// it as a SessionEvent (using `lastChangeAt` as endedAt — the moment
    /// of the last keystroke, not the moment the timer fired). Returns
    /// nil if no active session.
    public func endSessionIfIdle(
        at firingDate: Date,
        currentProjectWordCount: Int
    ) -> SessionEvent? {
        guard let session = activeSession else { return nil }
        let event = SessionEvent(
            id: UUID().uuidString,
            startedAt: session.startedAt,
            endedAt: session.lastChangeAt,
            wordsNet: currentProjectWordCount - session.startWordCount,
            deviceId: session.deviceId)
        activeSession = nil
        _ = firingDate
        return event
    }

    /// Called on app quit. Same as endSessionIfIdle but using `at` as the
    /// end time instead of lastChangeAt — preserves the actual extent of
    /// the session up to quit.
    public func endSessionImmediately(
        at date: Date,
        currentProjectWordCount: Int
    ) -> SessionEvent? {
        guard let session = activeSession else { return nil }
        let event = SessionEvent(
            id: UUID().uuidString,
            startedAt: session.startedAt,
            endedAt: date,
            wordsNet: currentProjectWordCount - session.startWordCount,
            deviceId: session.deviceId)
        activeSession = nil
        return event
    }
}
