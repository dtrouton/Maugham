import AppKit
import os

private let quitLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham", category: "QuitCoordinator")

/// **⌘Q waits for the stores to close** (hardening 11-11 plan 2 final
/// review, G1; ruling R-C names quit). `applicationShouldTerminate` asks
/// this: with no project open the quit goes ahead at once; otherwise it is
/// deferred (`.terminateLater`), every open project's close runs, and the
/// reply is made when the last has finished — or at `bound`, whichever is
/// first, so a quit never hangs.
///
/// - **One round.** A second quit request while one is pending starts no
///   second round and is answered `.later`: the first round's reply lets the
///   quit go.
/// - **One reply.** The closers finishing and the bound passing both reach
///   the same once-only reply.
/// - **One place.** This is the only code that closes the stores at quit;
///   the project window's old `maughamAppWillTerminate` arm — a close started
///   and never waited for — is gone, so no store is closed twice.
/// - **Composes with install-on-quit.** *Restart & Update* launches the swap
///   helper and then calls `terminate`: the helper waits for this process to
///   exit, however long that takes. A staged update the writer dismissed is
///   handed to the helper in `willTerminate`, which runs after the reply.
///   Neither path is changed.
@MainActor
final class QuitCoordinator {
    /// One open project's close.
    typealias Closer = @MainActor () async -> Void

    enum Answer: Equatable {
        /// Nothing to wait for.
        case now
        /// The reply follows: the closers have finished, or the bound passed.
        case later
    }

    /// The longest a quit waits for the stores.
    static let bound: Duration = .seconds(10)

    private let closers: @MainActor () -> [Closer]
    /// The clock: returns once the duration has passed (a test's returns
    /// when the test says so).
    private let wait: @MainActor (Duration) async -> Void
    private var pending = false
    /// A round has begun: the stores are closing, or closed.
    private(set) var hasBegun = false

    init(closers: @escaping @MainActor () -> [Closer],
         wait: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.closers = closers
        self.wait = wait
    }

    /// A quit was asked for. `.now`: go ahead, and `reply` is never called.
    /// `.later`: `reply` is called once, on the main actor.
    func quitRequested(reply: @escaping @MainActor () -> Void) -> Answer {
        guard !pending else { return .later }
        let closers = closers()
        guard !closers.isEmpty else { return .now }
        // Never reset: the only reply is `true`, which always ends the
        // process. A cancel path, if one is ever added, must reset this, or a
        // later quit would answer `.later` and never reply.
        pending = true
        hasBegun = true
        var replied = false
        var clock: Task<Void, Never>?
        let once: @MainActor (Bool) -> Void = { finished in
            guard !replied else { return }
            replied = true
            clock?.cancel()
            if !finished {
                quitLog.error("quit: the stores had not closed within \(String(describing: Self.bound), privacy: .public); quitting anyway")
            }
            reply()
        }
        let wait = wait
        clock = Task { @MainActor in
            await wait(Self.bound)
            once(false)
        }
        Task { @MainActor in
            let running = closers.map { closer in Task { @MainActor in await closer() } }
            for close in running { await close.value }
            once(true)
        }
        return .later
    }
}

/// The app's delegate (`MaughamApp`'s `@NSApplicationDelegateAdaptor`): it
/// exists to answer `applicationShouldTerminate` from the `QuitCoordinator`.
final class MaughamAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `MaughamApp.init`, over the session registry's closers.
    @MainActor static var quit: QuitCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            Self.answer(Self.quit, isTestHost: TestHost.isActive) {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
    }

    /// **The one way the app asks itself to quit** (0.46.0's *Restart &
    /// Update* hang). AppKit answers `.terminateLater` by spinning a run loop
    /// INSIDE `terminate`, and the reply comes from main-actor tasks. A run
    /// loop nested in a main-queue block never drains the main queue, so a
    /// `terminate` called from a main-actor task (the update install is one)
    /// or from `DispatchQueue.main.async` waits for a reply that cannot be
    /// made: closers and the bound alike never run. This hands the call to
    /// the run loop itself, where the nested loop does drain the queue. ⌘Q
    /// arrives as an event and was never affected.
    @MainActor
    static func requestQuit(_ terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { terminate() }
        }
    }

    /// What AppKit is told. A test host is never held (a gate's worker ends
    /// when XCTest says so), and no coordinator means nothing to wait for.
    @MainActor
    static func answer(_ quit: QuitCoordinator?, isTestHost: Bool,
                       reply: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        guard let quit, !isTestHost else { return .terminateNow }
        switch quit.quitRequested(reply: reply) {
        case .now: return .terminateNow
        case .later: return .terminateLater
        }
    }
}
