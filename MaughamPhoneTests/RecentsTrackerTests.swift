import XCTest
@testable import MaughamPhone

// Fixed reference instant used throughout: 2026-01-15T00:00:00Z.
// All 14-day boundary arithmetic is relative to this value so tests are
// fully deterministic and never depend on the real clock.
private let fixedNow = Date(timeIntervalSince1970: 1_768_435_200)  // 2026-01-15 00:00:00 UTC

// MARK: - Compute tests

/// Tests for `RecentsTracker`'s `recents` union semantics, FIFO/cap behaviour of
/// `recordCapture`, and move-to-front dedup.
@MainActor
final class RecentsTrackerComputeTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RecentsTrackerComputeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // Builds a tracker locked to `fixedNow`.
    private func makeTracker() -> RecentsTracker {
        RecentsTracker(defaults: defaults, now: { fixedNow })
    }

    func test_recents_union_capturedAndRecentOpened() async throws {
        let tracker = makeTracker()

        // Insert three projects via capture (oldest-first, so the final
        // captured list will be [p3, p2, p1] — most-recent-first).
        tracker.recordCapture(into: "p1")
        tracker.recordCapture(into: "p2")
        tracker.recordCapture(into: "p3")

        // Two opened within 14 days of fixedNow.
        let withinWindow = fixedNow.addingTimeInterval(-(13 * 24 * 60 * 60))   // 13 days ago
        let alsoWithin   = fixedNow.addingTimeInterval(-(1 * 24 * 60 * 60))    // 1 day ago

        // Two opened MORE than 14 days ago — must not appear in recents.
        let justExpired  = fixedNow.addingTimeInterval(-(14 * 24 * 60 * 60 + 1)) // 14d+1s ago
        let longAgo      = fixedNow.addingTimeInterval(-(30 * 24 * 60 * 60))    // 30 days ago

        // Seed openedDates directly via recordOpen after temporarily overriding
        // `now` is not possible without a second tracker, so we use a fresh
        // tracker with a custom `now` for each opened record.
        let inWindow1 = RecentsTracker(defaults: defaults, now: { withinWindow })
        inWindow1.recordOpen("r1")

        let inWindow2 = RecentsTracker(defaults: defaults, now: { alsoWithin })
        inWindow2.recordOpen("r2")

        let expired1 = RecentsTracker(defaults: defaults, now: { justExpired })
        expired1.recordOpen("r3")

        let expired2 = RecentsTracker(defaults: defaults, now: { longAgo })
        expired2.recordOpen("r4")

        // Build the final tracker (reads persisted state) locked to fixedNow.
        let final = makeTracker()

        // recents = {p1,p2,p3} (captured) ∪ {r1,r2} (within window)
        let expected: Set<ProjectId> = ["p1", "p2", "p3", "r1", "r2"]
        XCTAssertEqual(final.recents, expected)

        // Expired entries must NOT appear.
        XCTAssertFalse(final.recents.contains("r3"), "just-expired entry must drop out")
        XCTAssertFalse(final.recents.contains("r4"), "long-ago entry must drop out")
    }

    func test_captured_order_mostRecentFirst() async throws {
        let tracker = makeTracker()
        tracker.recordCapture(into: "p1")
        tracker.recordCapture(into: "p2")
        tracker.recordCapture(into: "p3")

        // Most-recent capture is last call (p3), so list is [p3, p2, p1].
        XCTAssertEqual(tracker.captured, ["p3", "p2", "p1"])
    }

    func test_capture_capAt5_dropsOldest() async throws {
        let tracker = makeTracker()
        for i in 1...6 { tracker.recordCapture(into: "proj\(i)") }

        XCTAssertEqual(tracker.captured.count, 5, "captured must be capped at 5")
        // proj1 was the oldest capture and must have been dropped.
        XCTAssertFalse(tracker.captured.contains("proj1"), "oldest entry must fall off when cap is exceeded")
        // proj6 is the most recent — must be at the front.
        XCTAssertEqual(tracker.captured.first, "proj6")
    }

    func test_capture_moveToFront_doesNotGrowList() async throws {
        let tracker = makeTracker()
        tracker.recordCapture(into: "p1")
        tracker.recordCapture(into: "p2")
        tracker.recordCapture(into: "p3")

        // p1 is currently at the end. Capturing it again should move it to
        // the front without adding a duplicate.
        tracker.recordCapture(into: "p1")

        XCTAssertEqual(tracker.captured, ["p1", "p3", "p2"], "re-capture must move to front")
        XCTAssertEqual(tracker.captured.count, 3, "list must not grow on move-to-front")
    }
}

// MARK: - Persistence tests

/// Tests that state survives across `RecentsTracker` instances sharing a
/// `UserDefaults` suite, and that corrupt data decodes to empty rather than
/// crashing.
@MainActor
final class RecentsTrackerPersistenceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RecentsTrackerPersistenceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_stateRoundTrips_acrossTrackerInstances() async throws {
        // Writer tracker: record some captures and opens.
        let writer = RecentsTracker(defaults: defaults, now: { fixedNow })
        writer.recordCapture(into: "alpha")
        writer.recordCapture(into: "beta")
        writer.recordCapture(into: "gamma")
        writer.recordOpen("alpha")
        writer.recordOpen("delta")

        // Fresh tracker over the SAME suite must restore identical state.
        let reader = RecentsTracker(defaults: defaults, now: { fixedNow })

        XCTAssertEqual(reader.captured, ["gamma", "beta", "alpha"],
                       "captured list must survive across tracker instances")
        XCTAssertEqual(reader.openedDates["alpha"], fixedNow,
                       "openedDates[alpha] must survive with correct timestamp")
        XCTAssertEqual(reader.openedDates["delta"], fixedNow,
                       "openedDates[delta] must survive with correct timestamp")
        XCTAssertNil(reader.openedDates["beta"],
                     "beta was never opened — must not appear in openedDates")
    }

    func test_corruptData_decodesToEmpty_doesNotCrash() async throws {
        // Inject garbage bytes under both persistence keys.
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF])
        defaults.set(garbage, forKey: "recentProjectIds")
        defaults.set(garbage, forKey: "lastOpenedDates")

        // Must not crash; must start from empty state.
        let tracker = RecentsTracker(defaults: defaults, now: { fixedNow })
        XCTAssertTrue(tracker.captured.isEmpty,
                      "corrupt captured data must decode to empty list")
        XCTAssertTrue(tracker.openedDates.isEmpty,
                      "corrupt openedDates data must decode to empty dict")
        XCTAssertTrue(tracker.recents.isEmpty)
    }
}
