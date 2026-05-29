import Foundation

/// Production `UbiquitousDownloader`: the thing that actually talks to
/// `FileManager` + `URL` resource keys to fault an evicted iCloud-Drive file in
/// and report progress, for `DownloadCoordinator` to drive.
///
/// Holds no mutable state — just an injected `UbiquitousFileSystem` seam — so it
/// is a value type and trivially `Sendable`. The poll loop's testability lives
/// entirely in that seam; tests inject a scripted fake.
///
/// Phase D: coordinated read/write wrappers (NSFileCoordinator) land here. This
/// type is the eventual general coordinated-I/O surface; for Phase D0 it is
/// scoped to just the download surface (`fileSize` + `download`).
struct CoordinatedFileIO: UbiquitousDownloader, Sendable {
    /// The default production instance, wired to the live FileManager-backed
    /// filesystem.
    static let live = CoordinatedFileIO(fileSystem: LiveUbiquitousFileSystem())

    /// Poll backoff: start fast (downloads often finish quickly), then back off
    /// exponentially to a 1s ceiling so a slow/stalled download doesn't busy-poll
    /// the resource keys. Yields a delay sequence of 100, 200, 400, 800, 1000,
    /// 1000…ms.
    private static let initialPollInterval: Duration = .milliseconds(100)
    private static let maxPollInterval: Duration = .seconds(1)
    private static let pollBackoffMultiplier: Int = 2

    private let fileSystem: UbiquitousFileSystem

    init(fileSystem: UbiquitousFileSystem = LiveUbiquitousFileSystem()) {
        self.fileSystem = fileSystem
    }

    func fileSize(at url: URL) -> Int64? {
        fileSystem.fileSize(at: url)
    }

    func download(at url: URL) -> AsyncThrowingStream<Double, Error> {
        let fs = fileSystem
        // `unfolding`: the produce closure runs in the CONSUMER's task context on
        // each `next()`. That's deliberate — it means `Task.sleep` / cancellation
        // observed here reflect the consumer's task directly, so cancelling the
        // consumer throws `CancellationError` straight into `for try await`
        // (rather than silently tearing down a detached producer). Single-consumer
        // by construction, so the captured `PollState` needs no synchronization.
        let state = PollState(initialInterval: Self.initialPollInterval)
        return AsyncThrowingStream { () async throws -> Double? in
            try await Self.nextProgress(url: url, fs: fs, state: state)
        }
    }

    /// Per-stream mutable poll state. Lives across `next()` calls; the stream is
    /// single-consumer so no locking is needed.
    private final class PollState {
        var started = false
        var finished = false
        var interval: Duration
        var lastProgress: Double = 0.0
        init(initialInterval: Duration) { self.interval = initialInterval }
    }

    /// Produces the next progress value, or nil to finish the stream normally.
    /// Throws the download error / start failure into the stream; throws
    /// `CancellationError` (via `Task.sleep`) if the consumer is cancelled
    /// mid-poll. Faults the file in lazily on the first call.
    private static func nextProgress(
        url: URL,
        fs: UbiquitousFileSystem,
        state: PollState
    ) async throws -> Double? {
        if state.finished { return nil }

        // First call: fast-path the already-current case, else kick off the
        // download before the first poll.
        if !state.started {
            state.started = true
            if fs.downloadSnapshot(at: url).status == .current {
                state.finished = true
                return 1.0
            }
            try fs.startDownloadingUbiquitousItem(at: url)
            // Falls through to poll immediately after start (no sleep yet).
            // `startDownloadingUbiquitousItem` returns before the OS begins the
            // transfer, so this first read typically reports .notDownloaded and
            // yields 0.0 — a harmless leading progress value before the first
            // backoff interval.
        } else {
            // Back off before re-polling. `Task.sleep` is also the between-polls
            // cancellation check — it throws CancellationError if cancelled.
            try await Task.sleep(for: state.interval)
            state.interval = min(state.interval * pollBackoffMultiplier, maxPollInterval)
        }

        let snapshot = fs.downloadSnapshot(at: url)
        if let error = snapshot.error { throw error }
        if snapshot.status == .current {
            state.finished = true
            return 1.0
        }

        // Clamp to 0...1 and never report a value below what we've already shown —
        // progress shouldn't visibly go backwards on a noisy read.
        if let fraction = snapshot.fractionDownloaded {
            state.lastProgress = max(state.lastProgress, min(max(fraction, 0.0), 1.0))
        }
        return state.lastProgress
    }
}
