// Maugham/Views/Review/RunWhenDocumentOpens.swift
import Foundation
import os

// Subsystem from the running bundle id so dev/stable logs separate without
// hardcoding "com.maugham" (tripwire 13 spirit).
private let runDeferralLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "ReviewBoardRound")

/// **Wait for a piece to be open, then ask for its round** (M4 P2 Task 4).
///
/// The Review board is a project-level surface: the chapter under a chip has
/// usually never been on screen. So a chip that starts a round has to do two
/// things that cannot happen on the same turn — take the writer to the piece,
/// and check it — because `CompilerOrchestrator.runRequested` **refuses
/// silently** while `Environment.reading(docId)` is `nil`, and a document is
/// opened asynchronously by `EditorHost.loadDocumentIfNeeded` some turns after
/// the subject is written. Firing the run beside the navigation produces no
/// error, no acknowledgment flash, no failed state and no notes: nothing at
/// all. `CompilerRunCommandTests.
/// test_falsification_aRunOnAPieceThatIsNotOpenYetIsRefusedInSilence` keeps
/// that hazard live, and this is the far side of it.
///
/// **A bounded poll, and the bound is what makes it honest.** Nothing here
/// observes the store — `DocumentStore.openDocuments` is not a stream, and an
/// observation whose completion depended on a redraw would be a second thing
/// that can fail to arrive. So it asks, waits `pollInterval`, and asks again,
/// for at most `deadline`. A piece that never opens — a load failure, a file
/// deleted under the manifest, a subject the tree refused — **drops the round,
/// and says so**: never a crash, never a hang, and never a run fired at a
/// document that is not there.
///
/// **The drop is a flash as well as a log line** (Denver's 2026-08-18 ruling).
/// It was the log alone until then, which made an expired chip press
/// indistinguishable from a control that does nothing: the writer travelled to
/// the piece, waited, and no round ever arrived with nothing anywhere saying
/// why. `onTimedOut` is a closure for `isOpen`/`run`'s reason — this file
/// names no window and no orchestrator, so the sentence is the caller's and
/// the expiry is ours.
///
/// **It is a value-shaped seam on purpose.** It names no store and no
/// orchestrator: the two closures are supplied by `ProjectWindow`'s mount,
/// which is the one place that knows what "open" means and what a run is. That
/// is what lets the whole wait, its expiry and its control be driven in a test
/// with no window (and it is why the `Task` is returned rather than discarded —
/// a test awaits the outcome instead of sleeping and hoping).
///
/// Two chips pressed in a row start two waits. The second run is refused by
/// `runRequested`'s own `isRunning` guard with the "Still checking…"
/// acknowledgment, which is the answer a second press gets everywhere else;
/// nothing is queued here.
@MainActor
enum RunWhenDocumentOpens {

    /// How long a piece is given to open before its round is dropped. Long
    /// enough for a real open — reading an op log off a cold disk — and short
    /// enough that a writer who has moved on is not ambushed by a check
    /// starting under them.
    ///
    /// `nonisolated` because it is a DEFAULT ARGUMENT of `start(…)`, which the
    /// compiler evaluates at the call site rather than inside the isolated
    /// body — a main-actor constant there is a Swift 6 error, and it is a
    /// `Duration`, which is `Sendable` and needs no isolation to be read.
    nonisolated static let deadline: Duration = .seconds(5)

    /// How often the question is asked. Cheap (a dictionary scan) and well
    /// under a frame, so the run starts on the turn after the document lands.
    /// `nonisolated` for `deadline`'s reason.
    nonisolated static let pollInterval: Duration = .milliseconds(25)

    enum Outcome: Equatable {
        /// The document opened and `run` was called.
        case ran
        /// It never opened inside `deadline`; the round was dropped.
        case timedOut
        /// The wait was cancelled before either.
        case cancelled
    }

    /// Start the wait. Returns its `Task` so a caller (in practice, a test) can
    /// await the outcome; the production mount discards it, because a window
    /// that goes away takes the run's reason with it.
    @discardableResult
    static func start(
        docId: String,
        within deadline: Duration = Self.deadline,
        polling pollInterval: Duration = Self.pollInterval,
        isOpen: @escaping @MainActor (String) -> Bool,
        run: @escaping @MainActor (String) -> Void,
        onTimedOut: @escaping @MainActor () -> Void = {}
    ) -> Task<Outcome, Never> {
        Task { @MainActor in
            let clock = ContinuousClock()
            let expiry = clock.now.advanced(by: deadline)
            while !isOpen(docId) {
                // Checked ahead of the deadline so a cancelled wait says so
                // rather than reporting an expiry it never reached — and
                // checked at all because `try?` below swallows the
                // cancellation `Task.sleep` throws, which would otherwise
                // spin this loop until the deadline.
                if Task.isCancelled { return .cancelled }
                guard clock.now < expiry else {
                    runDeferralLog.error(
                        "a round asked for from the review board was dropped: doc \(docId, privacy: .public) did not open within \(deadline.components.seconds, privacy: .public)s")
                    // The log is not a surface. Told BEFORE the outcome is
                    // returned, so a caller that only awaits `.timedOut` and a
                    // production mount that discards the task alike get the
                    // sentence.
                    onTimedOut()
                    return .timedOut
                }
                try? await Task.sleep(for: pollInterval)
            }
            run(docId)
            return .ran
        }
    }
}
