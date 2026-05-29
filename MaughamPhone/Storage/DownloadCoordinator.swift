import Foundation

/// Owns per-URL iCloud-Drive download state for the phone.
///
/// iOS aggressively evicts unused iCloud-Drive files, leaving placeholders that
/// read as empty bytes with NO error — so an evicted op-log file silently
/// renders as "no annotations." This actor dedups concurrent download requests,
/// tracks state, and enforces a 50 MB cold-launch budget for proactive op-log
/// prefetching. See design doc §3.13.
actor DownloadCoordinator {
    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(progress: Double)  // 0.0 ... 1.0
        case downloaded
        case failed(String)
    }

    private(set) var states: [URL: DownloadState] = [:]
    private(set) var coldLaunchBudgetRemaining: Int64 = 50 * 1024 * 1024  // 50 MB

    private let downloader: UbiquitousDownloader

    /// One driving task per URL. Both the lazy and the budget path route through
    /// `startIfNeeded`, which returns the existing task if one is in flight —
    /// that's the dedup invariant.
    private var inFlight: [URL: Task<Void, Error>] = [:]

    /// Live observers per URL. Each gets an immediate replay of the current
    /// state on subscribe, then every subsequent change until a terminal state.
    private var observers: [URL: [UUID: AsyncStream<DownloadState>.Continuation]] = [:]

    init(downloader: UbiquitousDownloader) {
        self.downloader = downloader
    }

    // MARK: - Public API

    /// Lazy "I need this now" path. Idempotent: multiple concurrent callers for
    /// the same URL share ONE underlying download and all return when it
    /// resolves. IGNORES the cold-launch budget. Throws if the download fails.
    func ensureDownloaded(_ url: URL) async throws {
        if states[url] == .downloaded { return }
        let task = startIfNeeded(url: url)
        try await task.value
    }

    /// Cold-launch proactive path. If the file is already `.downloaded`, returns
    /// true with no budget hit. Otherwise, if `sizeHint` fits in
    /// `coldLaunchBudgetRemaining`, reserves the budget, STARTS the (deduped)
    /// download WITHOUT awaiting its completion, and returns true. If the budget
    /// cannot accommodate `sizeHint`, returns false and does NOT start a
    /// download.
    func ensureDownloadedIfBudgetAllows(_ url: URL, sizeHint: Int64) async -> Bool {
        if states[url] == .downloaded { return true }

        // If a download is already in flight for this URL, don't double-charge
        // the budget; just report that we're on it.
        if inFlight[url] != nil { return true }

        guard sizeHint <= coldLaunchBudgetRemaining else { return false }

        coldLaunchBudgetRemaining -= sizeHint
        // v1: if this budgeted download later fails, we do NOT refund the
        // reservation. Keeping it simple — a failed prefetch is rare and the
        // budget is a soft cold-launch cap, not an accounting ledger.
        _ = startIfNeeded(url: url)
        return true
    }

    /// Cancels the in-flight download for `url` (if any) and removes its
    /// in-flight entry. State transitions appropriately.
    func cancel(_ url: URL) {
        guard let task = inFlight.removeValue(forKey: url) else { return }
        task.cancel()
        // The driving task's catch handler observes the CancellationError and
        // sets `.failed`, but it guards on still being the registered task; we
        // already removed it, so do the terminal bookkeeping here.
        transition(url, to: .failed("cancelled"))
    }

    /// Returns a stream that emits the CURRENT state immediately, then every
    /// subsequent state change for `url`, until the URL reaches a terminal
    /// state (.downloaded / .failed) — at which point the stream finishes.
    /// Multiple observers for the same URL are supported.
    func observe(_ url: URL) -> AsyncStream<DownloadState> {
        let id = UUID()
        let current = states[url] ?? .notDownloaded
        return AsyncStream { continuation in
            // Replay current state immediately.
            continuation.yield(current)

            // A terminal state means there's nothing further to observe.
            if current.isTerminal {
                continuation.finish()
                return
            }

            observers[url, default: [:]][id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeObserver(url: url, id: id) }
            }
        }
    }

    // MARK: - Private

    private func removeObserver(url: URL, id: UUID) {
        observers[url]?[id] = nil
        if observers[url]?.isEmpty == true { observers[url] = nil }
    }

    /// Creates the driving task for `url` exactly once; returns the existing one
    /// if a download is already in flight. This is the dedup core.
    private func startIfNeeded(url: URL) -> Task<Void, Error> {
        if let existing = inFlight[url] { return existing }

        transition(url, to: .downloading(progress: 0.0))

        let task = Task<Void, Error> { [downloader] in
            do {
                for try await progress in downloader.download(at: url) {
                    try Task.checkCancellation()
                    await self.transition(url, to: .downloading(progress: progress))
                }
                try Task.checkCancellation()
                await self.finish(url: url, terminal: .downloaded)
            } catch {
                await self.finish(url: url, terminal: .failed(self.describe(error)))
                throw error
            }
        }
        inFlight[url] = task
        return task
    }

    /// Terminal handler run from inside the driving task. Clears the in-flight
    /// entry (only if it's still ours — `cancel` may have already removed it)
    /// and emits the terminal state to observers.
    private func finish(url: URL, terminal: DownloadState) {
        let wasInFlight = inFlight.removeValue(forKey: url) != nil
        // If `cancel(_:)` already removed the in-flight entry, it also already
        // transitioned to `.failed("cancelled")`; don't clobber that with a
        // late `.downloaded`/`.failed` from the racing driving task.
        guard wasInFlight else { return }
        transition(url, to: terminal)
    }

    /// Updates stored state and fans out to observers. On a terminal state,
    /// finishes (and clears) every observer continuation for the URL.
    private func transition(_ url: URL, to newState: DownloadState) {
        states[url] = newState
        guard let conts = observers[url] else { return }
        for cont in conts.values { cont.yield(newState) }
        if newState.isTerminal {
            for cont in conts.values { cont.finish() }
            observers[url] = nil
        }
    }

    nonisolated private func describe(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

private extension DownloadCoordinator.DownloadState {
    var isTerminal: Bool {
        switch self {
        case .downloaded, .failed: return true
        case .notDownloaded, .downloading: return false
        }
    }
}
