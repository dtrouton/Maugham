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
}
