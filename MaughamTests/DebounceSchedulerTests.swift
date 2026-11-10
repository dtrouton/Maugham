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

    /// A schedule made while a timer-fired run is in flight is still pending
    /// when that run finishes, so a later `flush()` runs it. Every `Void`
    /// payload compares equal, so clearing by payload equality wiped the
    /// newer schedule — and `Document.close()`'s flush then wrote nothing of
    /// the writer's last keystrokes. Driven by continuations and counters only.
    func test_aScheduleMadeWhileARunIsInFlightSurvivesThatRun() async {
        var calls = 0
        var returned = 0
        var parked: [Int: CheckedContinuation<Void, Never>] = [:]
        let scheduler = DebounceScheduler<Void>(delay: .zero) { _ in
            calls += 1
            let n = calls
            if n <= 2 {
                await withCheckedContinuation { parked[n] = $0 }
            }
            returned += 1
        }

        scheduler.schedule(())
        await yieldUntil("the first run starts") { parked[1] != nil }
        scheduler.schedule(())
        await yieldUntil("the second run starts") { parked[2] != nil }

        parked.removeValue(forKey: 1)?.resume()
        await yieldUntil("the first run returns") { returned == 1 }

        await scheduler.flush()
        XCTAssertEqual(calls, 3,
            "the schedule made during the first run must still be pending for flush()")

        parked.removeValue(forKey: 2)?.resume()
        await yieldUntil("the second run returns") { returned == 3 }
    }

    /// Lets the main actor run queued work until `condition` holds. Not a
    /// timer: the condition is a counter the code under test moves.
    private func yieldUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("never happened: \(what)")
    }
}
