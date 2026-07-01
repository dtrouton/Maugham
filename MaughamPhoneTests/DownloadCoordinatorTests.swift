import XCTest
@testable import MaughamPhone

// MARK: - Mock

/// Deterministic `UbiquitousDownloader` for testing dedup / budget / failure.
///
/// Each `download(at:)` registers a handle the test can resolve explicitly —
/// no sleeps, no real iCloud. `startCount(for:)` reports how many times the
/// coordinator actually invoked `download(at:)` for a URL, which is how the
/// dedup and budget tests assert "exactly one underlying download" / "did not
/// start."
final class MockUbiquitousDownloader: UbiquitousDownloader, @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [URL: Int] = [:]
    private var continuations: [URL: AsyncThrowingStream<Double, Error>.Continuation] = [:]
    /// Per-URL waiters parked in `awaitDownload(for:)`, resumed when that url's
    /// `download(at:)` is invoked.
    private var startWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func fileSize(at url: URL) -> Int64? { nil }

    func download(at url: URL) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            starts[url, default: 0] += 1
            continuations[url] = continuation
            let waiters = startWaiters[url] ?? []
            startWaiters[url] = nil
            lock.unlock()
            for w in waiters { w.resume() }
        }
    }

    func startCount(for url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return starts[url] ?? 0
    }

    /// Suspends until `download(at: url)` has been invoked for THIS url — i.e.
    /// its continuation is registered, so a later `succeed(url)` / `fail(url)`
    /// is guaranteed to take effect. Resolves immediately if it already happened
    /// (no lost-signal hang), and waits for THIS url specifically.
    ///
    /// This is the fix for the 2026-07-01 `DownloadCoordinatorBudgetTests` CI
    /// hang. The old url-agnostic `awaitNextStart()` resolved on ANY download
    /// start, so a stale unresolved start (e.g. a budget-reservation download
    /// left in flight) could satisfy it — letting `succeed(otherURL)` race ahead
    /// of that url's registration, where `succeed` no-ops and the awaiting
    /// `ensureDownloaded` hangs forever. Waiting per-url removes the race.
    func awaitDownload(for url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if (starts[url] ?? 0) >= 1 {
                lock.unlock()
                cont.resume()
                return
            }
            startWaiters[url, default: []].append(cont)
            lock.unlock()
        }
    }

    func emitProgress(_ value: Double, for url: URL) {
        lock.lock(); let c = continuations[url]; lock.unlock()
        c?.yield(value)
    }

    func succeed(_ url: URL) {
        lock.lock(); let c = continuations[url]; lock.unlock()
        c?.finish()
    }

    func fail(_ url: URL, _ error: Error) {
        lock.lock(); let c = continuations[url]; lock.unlock()
        c?.finish(throwing: error)
    }
}

private struct MockError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func u(_ s: String) -> URL { URL(string: "file:///icloud/\(s)")! }

// MARK: - Base

/// Base for the DownloadCoordinator suites. These tests coordinate across Tasks
/// and AsyncStreams via `await`s on cross-task signals (`awaitDownload(for:)`)
/// and `observe()` stream termination. The specific 2026-07-01 CI hang (a
/// url-agnostic wait resolving on a stale start) is fixed at the source in
/// `MockUbiquitousDownloader.awaitDownload(for:)`. This per-test bound stays as
/// defense-in-depth: any future missed signal fails fast and names itself
/// instead of stalling the whole run until CI's 30-min job timeout. Only
/// enforced when test timeouts are enabled (CI passes `-test-timeouts-enabled`);
/// ignored otherwise, so local runs are unaffected.
class DownloadCoordinatorTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 30
    }
}

// MARK: - Dedup

final class DownloadCoordinatorDedupTests: DownloadCoordinatorTestCase {
    func test_threeConcurrentCallers_shareOneDownload() async throws {
        let mock = MockUbiquitousDownloader()
        let coord = DownloadCoordinator(downloader: mock)
        let url = u("ops.jsonl")

        // Three concurrent callers for the SAME url.
        async let a: Void = coord.ensureDownloaded(url)
        async let b: Void = coord.ensureDownloaded(url)
        async let c: Void = coord.ensureDownloaded(url)

        // Wait until at least one download has actually been kicked off.
        await mock.awaitDownload(for: url)
        // No sync point needed for the other two callers: the actor serializes
        // them, and `startIfNeeded` returns the existing in-flight task rather
        // than starting a new one — so `startCount` stays 1 regardless of
        // scheduling order. (A caller arriving after .downloaded would hit the
        // early-return guard and never reach `startIfNeeded` either.)
        mock.succeed(url)
        _ = try await (a, b, c)

        XCTAssertEqual(mock.startCount(for: url), 1, "all three callers must share one underlying download")
        let state = await coord.states[url]
        XCTAssertEqual(state, .downloaded)
    }
}

// MARK: - Budget

final class DownloadCoordinatorBudgetTests: DownloadCoordinatorTestCase {
    func test_budgetExhaustion_rejectsWithoutStarting() async throws {
        let mock = MockUbiquitousDownloader()
        let coord = DownloadCoordinator(downloader: mock)

        let budget = DownloadCoordinator.defaultColdLaunchBudget
        let big = u("big.jsonl")
        let overflow = u("overflow.jsonl")

        // First request takes nearly the whole budget.
        let firstHint = budget - 1024 * 1024
        let started1 = await coord.ensureDownloadedIfBudgetAllows(big, sizeHint: firstHint)
        XCTAssertTrue(started1)
        // The budget path starts the driving task without awaiting, so the
        // actual `download(at:)` invocation lands asynchronously — wait for it.
        await mock.awaitDownload(for: big)
        XCTAssertEqual(mock.startCount(for: big), 1)

        let remaining = await coord.coldLaunchBudgetRemaining
        XCTAssertEqual(remaining, budget - firstHint)

        // Next request exceeds remaining budget → must be rejected, no download.
        let started2 = await coord.ensureDownloadedIfBudgetAllows(overflow, sizeHint: remaining + 1)
        XCTAssertFalse(started2)
        XCTAssertEqual(mock.startCount(for: overflow), 0, "over-budget request must not start a download")

        // Budget unchanged by the rejected request.
        let remaining2 = await coord.coldLaunchBudgetRemaining
        XCTAssertEqual(remaining2, remaining)
    }

    func test_lazyDownloadIgnoresBudget_afterExhaustion() async throws {
        let mock = MockUbiquitousDownloader()
        let coord = DownloadCoordinator(downloader: mock)

        // Exhaust the entire budget.
        let big = u("big.jsonl")
        _ = await coord.ensureDownloadedIfBudgetAllows(big, sizeHint: DownloadCoordinator.defaultColdLaunchBudget)
        let remaining = await coord.coldLaunchBudgetRemaining
        XCTAssertEqual(remaining, 0)

        // The budgeted one over budget would be rejected...
        let rejected = await coord.ensureDownloadedIfBudgetAllows(u("nope.jsonl"), sizeHint: 1)
        XCTAssertFalse(rejected)

        // ...but the lazy path ignores the budget entirely and downloads.
        let lazyURL = u("lazy.jsonl")
        async let lazy: Void = coord.ensureDownloaded(lazyURL)
        await mock.awaitDownload(for: lazyURL)
        mock.succeed(lazyURL)
        try await lazy

        XCTAssertEqual(mock.startCount(for: lazyURL), 1, "lazy ensureDownloaded must work despite exhausted budget")
        let state = await coord.states[lazyURL]
        XCTAssertEqual(state, .downloaded)
    }

    func test_alreadyDownloaded_returnsTrueWithNoBudgetDebit() async throws {
        let mock = MockUbiquitousDownloader()
        let coord = DownloadCoordinator(downloader: mock)
        let url = u("done.jsonl")

        // Drive it to .downloaded via the lazy path first.
        async let lazy: Void = coord.ensureDownloaded(url)
        await mock.awaitDownload(for: url)
        mock.succeed(url)
        try await lazy
        let downloaded = await coord.states[url]
        XCTAssertEqual(downloaded, .downloaded)

        let budgetBefore = await coord.coldLaunchBudgetRemaining

        // Budgeted call on an already-downloaded URL: true, zero debit, no new start.
        let result = await coord.ensureDownloadedIfBudgetAllows(url, sizeHint: 100 * 1024 * 1024)
        XCTAssertTrue(result)
        let budgetAfter = await coord.coldLaunchBudgetRemaining
        XCTAssertEqual(budgetAfter, budgetBefore, "already-downloaded must cost 0 budget")
        XCTAssertEqual(mock.startCount(for: url), 1, "already-downloaded must not start a second download")
    }
}

// MARK: - Failure propagation

final class DownloadCoordinatorFailurePropagationTests: DownloadCoordinatorTestCase {
    func test_failure_setsStateRethrowsAndNotifiesObservers() async throws {
        let mock = MockUbiquitousDownloader()
        let coord = DownloadCoordinator(downloader: mock)
        let url = u("evicted.jsonl")

        // Start observing before the download resolves.
        let observed = Task<[DownloadCoordinator.DownloadState], Never> {
            var seen: [DownloadCoordinator.DownloadState] = []
            for await s in await coord.observe(url) { seen.append(s) }
            return seen
        }

        async let caller: Void = coord.ensureDownloaded(url)
        await mock.awaitDownload(for: url)
        mock.fail(url, MockError(message: "boom"))

        // ensureDownloaded must rethrow.
        do {
            try await caller
            XCTFail("ensureDownloaded should have rethrown the download failure")
        } catch let e as MockError {
            XCTAssertEqual(e.message, "boom")
        }

        let state = await coord.states[url]
        XCTAssertEqual(state, .failed("boom"))

        // Observer stream must have ended on a terminal .failed.
        let seen = await observed.value
        XCTAssertEqual(seen.last, .failed("boom"))
    }

    func test_observerReplaysCurrentStateImmediately() async throws {
        let mock = MockUbiquitousDownloader()
        let coord = DownloadCoordinator(downloader: mock)
        let url = u("fresh.jsonl")

        // No activity yet: observer should immediately replay .notDownloaded.
        var iterator = await coord.observe(url).makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .notDownloaded)
    }
}

// MARK: - Cancel

final class DownloadCoordinatorCancelTests: DownloadCoordinatorTestCase {
    func test_cancel_setsFailedNotifiesObserversAndIgnoresLateSuccess() async throws {
        let mock = MockUbiquitousDownloader()
        let coord = DownloadCoordinator(downloader: mock)
        let url = u("inflight.jsonl")

        // Observe before cancelling so we capture the terminal .failed.
        let observed = Task<[DownloadCoordinator.DownloadState], Never> {
            var seen: [DownloadCoordinator.DownloadState] = []
            for await s in await coord.observe(url) { seen.append(s) }
            return seen
        }

        // Start an in-flight download in a child task. It will throw
        // CancellationError once we cancel; we tolerate that here.
        let caller = Task { try? await coord.ensureDownloaded(url) }
        await mock.awaitDownload(for: url)

        await coord.cancel(url)

        let state = await coord.states[url]
        XCTAssertEqual(state, .failed("cancelled"), "cancel must leave state .failed(\"cancelled\")")

        // Late success from the (now-cancelled) underlying stream must NOT flip
        // the state back to .downloaded — the `wasInFlight` guard drops it.
        mock.succeed(url)
        _ = await caller.value
        let afterLateSuccess = await coord.states[url]
        XCTAssertEqual(afterLateSuccess, .failed("cancelled"), "late success after cancel must be ignored")

        // Observer stream must have terminated on .failed("cancelled").
        let seen = await observed.value
        XCTAssertEqual(seen.last, .failed("cancelled"))
    }
}
