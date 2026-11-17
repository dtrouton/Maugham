// MaughamTests/Updates/UpdateScheduleTests.swift
import XCTest
@testable import Maugham

@MainActor
final class UpdateScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    private let h: TimeInterval = 3600
    private let m: TimeInterval = 60

    private var suite = ""
    private var defaults: UserDefaults!
    override func setUp() {
        super.setUp()
        suite = "UpdateScheduleTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func test_neverChecked_isDue() {
        XCTAssertTrue(UpdateSchedule.isDue(lastCompleted: nil, lastAttempt: nil, now: now))
    }
    func test_fiveHours_notDue() {
        XCTAssertFalse(UpdateSchedule.isDue(lastCompleted: ago(5 * h), lastAttempt: ago(5 * h), now: now))
    }
    func test_sevenHours_isDue() {
        XCTAssertTrue(UpdateSchedule.isDue(lastCompleted: ago(7 * h), lastAttempt: ago(7 * h), now: now))
    }
    func test_recentFailedAttempt_blocksEvenWhenStale() {
        XCTAssertFalse(UpdateSchedule.isDue(lastCompleted: ago(7 * h), lastAttempt: ago(5 * m), now: now))
        XCTAssertFalse(UpdateSchedule.isDue(lastCompleted: nil, lastAttempt: ago(5 * m), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCompleted: ago(7 * h), lastAttempt: ago(16 * m), now: now))
    }
    func test_clockMovedBackwards_isDueNotStuck() {
        XCTAssertTrue(UpdateSchedule.isDue(
            lastCompleted: now.addingTimeInterval(3 * h),
            lastAttempt: now.addingTimeInterval(3 * h), now: now))
    }

    private func release() -> GitHubRelease {
        let json = """
        {"tag_name":"v0.1.0","name":"x","body":"n","draft":false,"prerelease":false,"assets":[]}
        """
        return try! GitHubRelease.decode(from: Data(json.utf8))
    }
    private func checker(fetch: @escaping () async throws -> GitHubRelease) -> UpdateChecker {
        UpdateChecker(
            currentVersionString: "0.1.0", fetchLatest: fetch,
            downloadAsset: { _, _, _ in URL(fileURLWithPath: "/tmp/x.zip") },
            stageAndVerify: { u, _ in u }, refusalDefaults: defaults)
    }

    func test_performCheck_recordsAttemptAndCompletedOnSuccess() async {
        let c = checker { self.release() }
        await c.performCheck(trigger: .background)
        XCTAssertNotNil(UpdateSchedule.lastAttempt(defaults: defaults))
        XCTAssertNotNil(UpdateSchedule.lastCompleted(defaults: defaults))
    }
    func test_performCheck_fetchFailureRecordsAttemptOnly() async {
        struct E: Error {}
        let c = checker { throw E() }
        await c.performCheck(trigger: .background)
        XCTAssertNotNil(UpdateSchedule.lastAttempt(defaults: defaults))
        XCTAssertNil(UpdateSchedule.lastCompleted(defaults: defaults))
    }

    func test_trigger_skipsWhenNotDue_andChecksWhenDue() async {
        var fetches = 0
        let c = checker { fetches += 1; return self.release() }
        await c.checkInBackgroundIfDue(now: Date())            // never checked: due
        XCTAssertEqual(fetches, 1)
        await c.checkInBackgroundIfDue(now: Date())            // just completed: not due
        XCTAssertEqual(fetches, 1)
        await c.checkInBackgroundIfDue(now: Date().addingTimeInterval(7 * h))
        XCTAssertEqual(fetches, 2)
    }
    func test_trigger_doesNothingWhileACheckIsInFlight() async {
        var fetches = 0
        let gate = AsyncStream<Void>.makeStream()
        let c = checker {
            fetches += 1
            for await _ in gate.stream { break }
            return self.release()
        }
        let first = Task { await c.performCheck(trigger: .manual) }
        while c.state != .checking { await Task.yield() }
        await c.checkInBackgroundIfDue(now: Date().addingTimeInterval(100 * h))
        XCTAssertEqual(fetches, 1)
        gate.continuation.yield(())
        await first.value
    }

    // MARK: - #137 U1: a background check never wipes a state that carried information

    private struct Synthetic: Error, LocalizedError {
        var errorDescription: String? { "x" }
    }
    private let farFuture = Date().addingTimeInterval(100 * 3600)

    /// A checker whose fetch counts itself and fails on demand, plus a staged
    /// `.app` for the ready state.
    private final class Rig {
        var fetches = 0
        var failing = false
        var version = "0.2.0"
        var bundle: URL
        var downloadGate: AsyncStream<Void>?
        init(bundle: URL) { self.bundle = bundle }
    }
    private func rig() throws -> (Rig, UpdateChecker) {
        let bundle = TestTemp.root.appendingPathComponent("staged-0.2.0/Maugham.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let r = Rig(bundle: bundle)
        let c = UpdateTestKit.makeChecker(
            defaults: defaults,
            fetch: {
                r.fetches += 1
                if r.failing { throw Synthetic() }
                return UpdateTestKit.release(
                    version: r.version,
                    body: r.version == "0.9.0" ? "n<!-- maugham-minimum-macos: 99.0 -->" : "notes")
            },
            downloadAsset: { _, _, _ in
                if let g = r.downloadGate { for await _ in g { break } }
                return URL(fileURLWithPath: "/tmp/fake.zip")
            },
            stageAndVerify: { _, _ in bundle })
        return (r, c)
    }

    /// Skip states: no fetch, no attempt recorded, state untouched.
    private func assertSkips(_ c: UpdateChecker, _ r: Rig, line: UInt = #line) async {
        let before = c.state
        let fetches = r.fetches
        let attempt = UpdateSchedule.lastAttempt(defaults: defaults)
        await c.checkInBackgroundIfDue(now: farFuture)
        XCTAssertEqual(r.fetches, fetches, "a skip state makes no fetch", line: line)
        XCTAssertEqual(c.state, before, line: line)
        XCTAssertEqual(UpdateSchedule.lastAttempt(defaults: defaults), attempt,
                       "and records no attempt", line: line)
    }
    /// Check states: exactly one fetch; failing, the state ends as it began.
    private func assertChecksAndRestores(_ c: UpdateChecker, _ r: Rig, line: UInt = #line) async {
        let before = c.state
        let fetches = r.fetches
        r.failing = true
        await c.checkInBackgroundIfDue(now: farFuture)
        XCTAssertEqual(r.fetches, fetches + 1, "a check state fetches once", line: line)
        XCTAssertEqual(c.state, before, "a failed background check restores the state", line: line)
    }

    func test_U1_idle_checks() async throws {
        let (r, c) = try rig()
        XCTAssertEqual(c.state, .idle)
        await assertChecksAndRestores(c, r)
    }
    func test_U1_upToDate_checks_andKeepsUpToDateOnFailure() async throws {
        let (r, c) = try rig()
        r.version = "0.1.0"
        await c.performCheck(trigger: .manual)
        XCTAssertEqual(c.state, .upToDate(currentVersion: "0.1.0"))
        await assertChecksAndRestores(c, r)
    }
    func test_U1_error_checks_andKeepsTheErrorOnFailure() async throws {
        let (r, c) = try rig()
        r.failing = true
        await c.performCheck(trigger: .manual)
        XCTAssertEqual(c.state, .error("x"))
        await assertChecksAndRestores(c, r)
        XCTAssertEqual(c.state, .error("x"))
    }
    func test_U1_newerBuildNeedsNewerSystem_checks_andKeepsItsPayloadOnFailure() async throws {
        let (r, c) = try rig()
        r.version = "0.9.0"
        await c.performCheck(trigger: .manual)
        XCTAssertEqual(c.state, .newerBuildNeedsNewerSystem(
            currentVersion: "0.1.0", newerVersion: "0.9.0", requiredSystem: "99"))
        await assertChecksAndRestores(c, r)
    }
    func test_U1_readyToInstall_skips() async throws {
        let (r, c) = try rig()
        await c.performCheck(trigger: .manual)
        XCTAssertEqual(c.state, .readyToInstall(bundleURL: r.bundle, version: "0.2.0", releaseNotes: "notes"))
        r.failing = true
        await assertSkips(c, r)
    }
    func test_U1_installing_skips() async throws {
        let (r, c) = try rig()
        // The test host wires no real installer: this call once reached the
        // app's, which could not install and showed the test's temp folder in
        // Finder, taking focus, on every gate (2026-11-13 to 2026-11-17).
        XCTAssertNil(UpdateChecker.performInstall, "a test host must never wire the real install")
        await c.installNow(bundleURL: r.bundle, version: "0.2.0")
        XCTAssertEqual(c.state, .installing(version: "0.2.0"))
        await assertSkips(c, r)
    }
    func test_U1_checking_skips() async throws {
        let (r, _) = try rig()
        let gate = AsyncStream<Void>.makeStream()
        let c2 = UpdateTestKit.makeChecker(defaults: defaults, fetch: {
            r.fetches += 1
            for await _ in gate.stream { break }
            return UpdateTestKit.release(version: "0.1.0")
        })
        let first = Task { await c2.performCheck(trigger: .manual) }
        while c2.state != .checking { await Task.yield() }
        await assertSkips(c2, r)
        gate.continuation.yield(())
        await first.value
    }
    func test_U1_downloading_skips() async throws {
        let (r, c) = try rig()
        let gate = AsyncStream<Void>.makeStream()
        r.downloadGate = gate.stream
        let first = Task { await c.performCheck(trigger: .manual) }
        while true {
            if case .downloading = c.state { break }
            await Task.yield()
        }
        await assertSkips(c, r)
        gate.continuation.yield(())
        await first.value
    }

    /// Every decline exit of a background check, from a state that carried
    /// information, puts that state back.
    func test_U1_aBackgroundDeclineRestoresTheStateItBeganFrom() async throws {
        func json(tag: String, assets: String) -> GitHubRelease {
            try! GitHubRelease.decode(from: Data("""
            {"tag_name":"\(tag)","name":"x","body":"n","draft":false,"prerelease":false,"assets":\(assets)}
            """.utf8))
        }
        let good = "https://github.com/dtrouton/Maugham/releases/download/v0.2.0/Maugham-0.2.0.zip"
        let cap = UpdateLimits.standard.maxDownloadBytes + 1
        let cases: [(String, GitHubRelease)] = [
            ("unparseable", json(tag: "vnope", assets: "[]")),
            ("no asset", json(tag: "v0.2.0", assets: "[]")),
            ("untrusted url", json(tag: "v0.2.0", assets: """
                [{"name":"Maugham-0.2.0.zip","browser_download_url":"https://evil.example/Maugham-0.2.0.zip","size":100}]
                """)),
            ("over the cap", json(tag: "v0.2.0", assets: """
                [{"name":"Maugham-0.2.0.zip","browser_download_url":"\(good)","size":\(cap)}]
                """)),
            ("refusal limit", json(tag: "v0.2.0", assets: """
                [{"name":"Maugham-0.2.0.zip","browser_download_url":"\(good)","size":100}]
                """)),
        ]
        for (name, rel) in cases {
            var failing = true
            let c = UpdateTestKit.makeChecker(defaults: defaults, fetch: {
                if failing { throw Synthetic() }
                return rel
            })
            await c.performCheck(trigger: .manual)           // -> .error("x")
            XCTAssertEqual(c.state, .error("x"), name)
            failing = false
            if name == "refusal limit" {
                for _ in 0..<InstallRefusalMemory.backgroundLimit {
                    InstallRefusalMemory.recordRefusal(version: "0.2.0", defaults: defaults)
                }
            }
            await c.performCheck(trigger: .background)
            XCTAssertEqual(c.state, .error("x"), "\(name): a background decline restores the error")
            await c.performCheck(trigger: .manual)
            XCTAssertNotEqual(c.state, .error("x"), "\(name): a manual check is unchanged")
        }
    }

    // MARK: - #137 U2: the loop listens on the centers it was given

    func test_U2_wakeAndActivationOnTheInjectedCentersEachFetchOnce_andStopRemovesBoth() async throws {
        let workspace = NotificationCenter()
        let app = NotificationCenter()
        var fetches = 0
        var waiter: CheckedContinuation<Void, Never>?
        let c = UpdateTestKit.makeChecker(defaults: defaults, fetch: {
            fetches += 1
            waiter?.resume()
            waiter = nil
            return UpdateTestKit.release(version: "0.1.0")
        })
        c.startBackgroundLoop(workspaceCenter: workspace, appCenter: app, enabled: true)

        await withCheckedContinuation { cont in
            waiter = cont
            workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        }
        XCTAssertEqual(fetches, 1, "wake fetches once")

        // Due again: clear the cooldown and completed times.
        defaults.removeObject(forKey: UpdateSchedule.completedKey)
        defaults.removeObject(forKey: UpdateSchedule.attemptKey)
        await withCheckedContinuation { cont in
            waiter = cont
            app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        XCTAssertEqual(fetches, 2, "activation fetches once more")

        // A post on the wrong center does nothing.
        defaults.removeObject(forKey: UpdateSchedule.completedKey)
        defaults.removeObject(forKey: UpdateSchedule.attemptKey)
        app.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        c.stopBackgroundLoop()
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        // The observers hop onto the main actor before checking; let those
        // hops run (a yield is a scheduling point, not a wait for an effect).
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fetches, 2, "wrong-center posts and posts after stop fetch nothing")
    }

    func test_U2_aDisabledBuildStartsNothing() async {
        let workspace = NotificationCenter()
        var fetches = 0
        let c = UpdateTestKit.makeChecker(defaults: defaults, fetch: {
            fetches += 1
            return UpdateTestKit.release(version: "0.1.0")
        })
        c.startBackgroundLoop(workspaceCenter: workspace, appCenter: NotificationCenter(), enabled: false)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fetches, 0)
    }
}
