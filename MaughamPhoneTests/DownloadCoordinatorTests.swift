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
    /// Total `download(at:)` invocations, and the count already consumed by an
    /// `awaitNextStart()`. Lets a waiter resolve immediately if a start already
    /// happened (no hang on lost races), and otherwise park until the next one.
    private var totalStarts = 0
    private var consumedStarts = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func fileSize(at url: URL) -> Int64? { nil }

    func download(at url: URL) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            starts[url, default: 0] += 1
            totalStarts += 1
            continuations[url] = continuation
            let waiters = startWaiters
            startWaiters.removeAll()
            consumedStarts = totalStarts
            lock.unlock()
            for w in waiters { w.resume() }
        }
    }

    func startCount(for url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return starts[url] ?? 0
    }

    /// Suspends until the next `download(at:)` invocation. Resolves immediately
    /// if an as-yet-unconsumed start has already happened, so the caller can't
    /// hang by racing the start.
    func awaitNextStart() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if totalStarts > consumedStarts {
                consumedStarts = totalStarts
                lock.unlock()
                cont.resume()
                return
            }
            startWaiters.append(cont)
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

// MARK: - Dedup

final class DownloadCoordinatorDedupTests: XCTestCase {
    func test_threeConcurrentCallers_shareOneDownload() async throws {
        let mock = MockUbiquitousDownloader()
        let coord = DownloadCoordinator(downloader: mock)
        let url = u("ops.jsonl")

        // Three concurrent callers for the SAME url.
        async let a: Void = coord.ensureDownloaded(url)
        async let b: Void = coord.ensureDownloaded(url)
        async let c: Void = coord.ensureDownloaded(url)

        // Wait until at least one download has actually been kicked off, then
        // give the other two callers a chance to coalesce onto it.
        await mock.awaitNextStart()
        // Let the remaining callers run through `ensureDownloaded` so they
        // attach to the in-flight task rather than starting their own.
        try await Task.sleep(nanoseconds: 50_000_000)

        mock.succeed(url)
        _ = try await (a, b, c)

        XCTAssertEqual(mock.startCount(for: url), 1, "all three callers must share one underlying download")
        let state = await coord.states[url]
        XCTAssertEqual(state, .downloaded)
    }
}

// MARK: - Budget

final class DownloadCoordinatorBudgetTests: XCTestCase {
    func test_budgetExhaustion_rejectsWithoutStarting() async throws {
        let mock = MockUbiquitousDownloader()
        let coord = DownloadCoordinator(downloader: mock)

        let big = u("big.jsonl")
        let overflow = u("overflow.jsonl")

        // First request takes nearly the whole 50 MB budget.
        let started1 = await coord.ensureDownloadedIfBudgetAllows(big, sizeHint: 49 * 1024 * 1024)
        XCTAssertTrue(started1)
        // The budget path starts the driving task without awaiting, so the
        // actual `download(at:)` invocation lands asynchronously — wait for it.
        await mock.awaitNextStart()
        XCTAssertEqual(mock.startCount(for: big), 1)

        let remaining = await coord.coldLaunchBudgetRemaining
        XCTAssertEqual(remaining, (50 - 49) * 1024 * 1024)

        // Next request exceeds remaining budget → must be rejected, no download.
        let started2 = await coord.ensureDownloadedIfBudgetAllows(overflow, sizeHint: 10 * 1024 * 1024)
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
        _ = await coord.ensureDownloadedIfBudgetAllows(big, sizeHint: 50 * 1024 * 1024)
        let remaining = await coord.coldLaunchBudgetRemaining
        XCTAssertEqual(remaining, 0)

        // The budgeted one over budget would be rejected...
        let rejected = await coord.ensureDownloadedIfBudgetAllows(u("nope.jsonl"), sizeHint: 1)
        XCTAssertFalse(rejected)

        // ...but the lazy path ignores the budget entirely and downloads.
        let lazyURL = u("lazy.jsonl")
        async let lazy: Void = coord.ensureDownloaded(lazyURL)
        await mock.awaitNextStart()
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
        await mock.awaitNextStart()
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

final class DownloadCoordinatorFailurePropagationTests: XCTestCase {
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
        await mock.awaitNextStart()
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
