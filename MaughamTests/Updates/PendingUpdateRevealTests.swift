// MaughamTests/Updates/PendingUpdateRevealTests.swift
import XCTest
@testable import Maugham

/// Covers the two testable halves of the quit-time install fallback
/// (`MaughamApp.swift`'s `willTerminate` observer):
///   1. `launchSwapHelper` returning false is the exact signal the terminate
///      path checks before marking a pending reveal.
///   2. `PendingUpdateReveal` round-trips and clears eagerly.
/// The terminate window itself — a `NotificationCenter` closure that calls
/// `NSApp`/real bundle paths during teardown — is NOT unit-testable; see
/// `Maugham/Updates/AREA.md` "What is and is not unit-testable".
final class PendingUpdateRevealTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "test.pendingUpdateReveal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - PendingUpdateReveal round trip

    func test_consumePending_returnsNil_whenNothingWasMarked() {
        let defaults = freshDefaults()
        XCTAssertNil(PendingUpdateReveal.consumePending(defaults: defaults))
    }

    func test_markPending_thenConsume_returnsTheBundleURL() {
        let defaults = freshDefaults()
        let bundle = URL(fileURLWithPath: "/Applications/Maugham.app")
        PendingUpdateReveal.markPending(bundleURL: bundle, defaults: defaults)
        XCTAssertEqual(PendingUpdateReveal.consumePending(defaults: defaults), bundle)
    }

    /// Consuming clears the flag — a second call (e.g. a crash-loop across
    /// launches) must not keep re-revealing the same stale bundle forever.
    func test_consumePending_clearsAfterFirstRead() {
        let defaults = freshDefaults()
        PendingUpdateReveal.markPending(
            bundleURL: URL(fileURLWithPath: "/Applications/Maugham.app"),
            defaults: defaults)
        _ = PendingUpdateReveal.consumePending(defaults: defaults)
        XCTAssertNil(PendingUpdateReveal.consumePending(defaults: defaults),
                     "second consume must return nil — the flag must not persist past one read")
    }

    // MARK: - launchSwapHelper false-return seam

    /// Mirrors the terminate-path condition exactly: an unwritable (here,
    /// nonexistent) install location makes `installMode` resolve to
    /// `.finderFallback`, so `launchSwapHelper` returns false before doing
    /// anything destructive. This is the exact boolean the terminate-path
    /// fallback in `MaughamApp.swift` now checks before calling
    /// `PendingUpdateReveal.markPending`.
    func test_launchSwapHelper_returnsFalse_whenInstallLocationUnwritable() {
        let staged = URL(fileURLWithPath: "/tmp/does-not-matter/Maugham.app")
        let unwritableInstalled = "/nonexistent-\(UUID().uuidString)/Maugham.app"
        let launched = UpdateInstaller.launchSwapHelper(
            stagedBundle: staged, relaunch: false,
            installedBundlePath: unwritableInstalled)
        XCTAssertFalse(launched)
    }

    /// End-to-end of the fallback shape (minus the real terminate window):
    /// a false return from `launchSwapHelper` is exactly the condition under
    /// which the terminate path marks a pending reveal.
    func test_falseLaunchResult_drivesMarkPending_likeTheTerminatePathDoes() {
        let defaults = freshDefaults()
        let staged = URL(fileURLWithPath: "/tmp/does-not-matter/Maugham.app")
        let launched = UpdateInstaller.launchSwapHelper(
            stagedBundle: staged, relaunch: false,
            installedBundlePath: "/nonexistent-\(UUID().uuidString)/Maugham.app")
        if !launched {
            PendingUpdateReveal.markPending(bundleURL: staged, defaults: defaults)
        }
        XCTAssertEqual(PendingUpdateReveal.consumePending(defaults: defaults), staged)
    }
}
