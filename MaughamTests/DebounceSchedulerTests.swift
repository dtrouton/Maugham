import XCTest
@testable import Maugham

@MainActor
final class DebounceSchedulerTests: XCTestCase {

    func test_schedule_fires_afterDelay() async throws {
        var fired: [Int] = []
        let scheduler = DebounceScheduler<Int>(
            delay: .milliseconds(80)
        ) { value in fired.append(value) }
        scheduler.schedule(42)
        XCTAssertEqual(fired, [])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fired, [42])
    }

    func test_rapidReschedule_cancelsPrevious_onlyLastFires() async throws {
        var fired: [Int] = []
        let scheduler = DebounceScheduler<Int>(
            delay: .milliseconds(80)
        ) { value in fired.append(value) }
        scheduler.schedule(1)
        try await Task.sleep(for: .milliseconds(20))
        scheduler.schedule(2)
        try await Task.sleep(for: .milliseconds(20))
        scheduler.schedule(3)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fired, [3])
    }

    func test_flush_firesImmediately() async throws {
        var fired: [Int] = []
        let scheduler = DebounceScheduler<Int>(
            delay: .milliseconds(800)
        ) { value in fired.append(value) }
        scheduler.schedule(7)
        await scheduler.flush()
        XCTAssertEqual(fired, [7])
    }

    func test_cancel_preventsFiring() async throws {
        var fired: [Int] = []
        let scheduler = DebounceScheduler<Int>(
            delay: .milliseconds(80)
        ) { value in fired.append(value) }
        scheduler.schedule(99)
        scheduler.cancel()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fired, [])
    }

    func test_flush_isNoOp_whenNothingScheduled() async {
        var fired: [Int] = []
        let scheduler = DebounceScheduler<Int>(
            delay: .milliseconds(80)
        ) { value in fired.append(value) }
        await scheduler.flush()
        XCTAssertEqual(fired, [])
    }
}
