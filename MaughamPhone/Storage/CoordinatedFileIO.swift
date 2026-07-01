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

    // MARK: - Coordinated read/write (Phase D)
    //
    // Every phone read inside the bookmarked iCloud-Drive projects folder, and
    // every write into `.maugham/inbox/*` + `.maugham/ops/*.jsonl`, funnels
    // through `NSFileCoordinator` here — the same primitive the Mac's
    // `ProjectFolderPresenter` uses. That shared coordination is what lets the
    // two sides cooperate cleanly through iCloud Drive (spec §3.6). The phone
    // registers no `NSFilePresenter` in v1, so these are plain coordinate-read /
    // coordinate-write calls (no presenter argument).
    //
    // These methods are eviction-AGNOSTIC: they assume the file is already local.
    // Faulting an evicted iCloud file in is `DownloadCoordinator`'s job — callers
    // `ensureDownloaded` first, *then* `coordinatedRead`.
    //
    // NSFileCoordinator's accessor block runs synchronously, so these stay
    // sync-throwing. Errors thrown from inside the accessor (Data init, FileHandle
    // failures) are captured into a `Swift.Error?` and rethrown after the
    // coordination returns — `coordinate(...)` only surfaces *coordination* errors
    // via its `error:` out-param, never accessor-thrown ones. Async callers invoke
    // these directly; the file ops are brief.

    /// Coordinated read of a file's bytes. Use for ANY read inside the bookmarked
    /// projects folder. Assumes the file is already local (download first).
    func coordinatedRead(at url: URL) throws -> Data {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var accessorError: Swift.Error?
        var data: Data?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                data = try Data(contentsOf: coordinatedURL)  // adr-0018-ok: generic coordinated-read primitive; the Read-tab manuscript display read flows through here — contracted divergence, see cross-surface-contracts.md
            } catch {
                accessorError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let accessorError { throw accessorError }
        // If coordination succeeded with no accessor error, `data` is non-nil.
        guard let data else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }

    /// Coordinated write: runs `body` with the coordinated (possibly
    /// temp-swapped) URL inside a write coordination. Use for ANY write into
    /// `.maugham/inbox/*` or `.maugham/ops/*.jsonl`.
    func coordinatedWrite(at url: URL, _ body: (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var accessorError: Swift.Error?

        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                try body(coordinatedURL)
            } catch {
                accessorError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let accessorError { throw accessorError }
    }

    /// Coordinated append of a single record line to a JSONL file, creating the
    /// file + intermediate directories if absent. A trailing "\n" is added unless
    /// `line` already ends in one. This is the inbox / op-log append primitive the
    /// phone writers use.
    ///
    /// The whole append happens inside one write coordination so concurrent
    /// appenders (and the Mac's coordinated writes) serialize rather than tearing
    /// each other's records.
    func coordinatedAppendLine(_ line: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var accessorError: Swift.Error?

        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                let fm = FileManager.default
                // Ensure parent dir exists (first capture for a fresh project).
                let parent = coordinatedURL.deletingLastPathComponent()
                if !fm.fileExists(atPath: parent.path) {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                // Create the file if absent so FileHandle(forWritingTo:) can open it.
                if !fm.fileExists(atPath: coordinatedURL.path) {
                    fm.createFile(atPath: coordinatedURL.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: coordinatedURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                // Newline-terminate so each record is its own line; don't double up
                // if the caller already supplied the terminator.
                if line.last != UInt8(ascii: "\n") {
                    try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
                }
            } catch {
                accessorError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let accessorError { throw accessorError }
    }

    /// Create a directory (and intermediates) if missing. Coordinated, so it
    /// races cleanly against the Mac creating the same `.maugham/` subtree.
    func ensureDirectory(at url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var accessorError: Swift.Error?

        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                let fm = FileManager.default
                if !fm.fileExists(atPath: coordinatedURL.path) {
                    try fm.createDirectory(at: coordinatedURL, withIntermediateDirectories: true)
                }
            } catch {
                accessorError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let accessorError { throw accessorError }
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

        // First call: if the file is already locally readable, finish at once —
        // ONLY an evicted placeholder (.notDownloaded) needs a fetch. This is
        // what makes the reader work for non-iCloud (local) folders and for
        // already-downloaded iCloud files, not just evicted placeholders.
        if !state.started {
            state.started = true
            if Self.isLocallyReady(fs.downloadSnapshot(at: url), url: url, fs: fs) {
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
        if Self.isLocallyReady(snapshot, url: url, fs: fs) {
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

    /// Whether `url` is readable right now without a (further) download:
    ///   - `.current` / `.downloaded` — a local iCloud copy exists.
    ///   - nil status + the file is present — a plain (non-ubiquitous) local file.
    /// Only `.notDownloaded` (an evicted placeholder) is NOT ready and needs a
    /// fetch. `URLUbiquitousItemDownloadingStatus` is a String-backed struct, not
    /// a frozen enum, so this compares rather than exhaustively switches.
    private static func isLocallyReady(
        _ snapshot: UbiquitousDownloadSnapshot, url: URL, fs: UbiquitousFileSystem
    ) -> Bool {
        guard let status = snapshot.status else {
            // Not a ubiquitous item — a plain local file. Ready iff it exists.
            return fs.fileExists(at: url)
        }
        // `.current` / `.downloaded` are local; `.notDownloaded` is a placeholder.
        return status != .notDownloaded
    }
}
