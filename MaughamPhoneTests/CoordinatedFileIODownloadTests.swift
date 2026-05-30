import XCTest
@testable import MaughamPhone

// MARK: - Fake filesystem

/// Scriptable `UbiquitousFileSystem`: `downloadSnapshot` walks a fixed array of
/// snapshots on successive calls (the last element repeats forever, so a loop
/// that never reaches `.current` stalls deterministically). Records
/// `startDownloadingUbiquitousItem` calls and can be primed to throw from it.
final class FakeUbiquitousFileSystem: UbiquitousFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [UbiquitousDownloadSnapshot]
    private var index = 0
    private(set) var startCalls = 0
    private let startError: Error?
    private let reportedSize: Int64?
    private let exists: Bool

    init(snapshots: [UbiquitousDownloadSnapshot], startError: Error? = nil,
         fileSize: Int64? = nil, fileExists: Bool = true) {
        self.snapshots = snapshots.isEmpty ? [UbiquitousDownloadSnapshot()] : snapshots
        self.startError = startError
        self.reportedSize = fileSize
        self.exists = fileExists
    }

    func startDownloadingUbiquitousItem(at url: URL) throws {
        lock.lock(); startCalls += 1; lock.unlock()
        if let startError { throw startError }
    }

    func downloadSnapshot(at url: URL) -> UbiquitousDownloadSnapshot {
        lock.lock(); defer { lock.unlock() }
        let snap = snapshots[index]
        if index < snapshots.count - 1 { index += 1 }  // last element repeats
        return snap
    }

    func fileExists(at url: URL) -> Bool { exists }

    func fileSize(at url: URL) -> Int64? { reportedSize }

    var observedStartCalls: Int { lock.lock(); defer { lock.unlock() }; return startCalls }
}

private struct FakeDownloadError: Error, Equatable { let message: String }

private func u(_ s: String) -> URL { URL(string: "file:///icloud/\(s)")! }

private func snap(
    _ status: URLUbiquitousItemDownloadingStatus?,
    fraction: Double? = nil,
    error: Error? = nil
) -> UbiquitousDownloadSnapshot {
    UbiquitousDownloadSnapshot(status: status, fractionDownloaded: fraction, error: error)
}

// MARK: - Tests

final class CoordinatedFileIODownloadTests: XCTestCase {
    func test_pollLoopCompletesWhenStatusReachesCurrent() async throws {
        let fs = FakeUbiquitousFileSystem(snapshots: [
            snap(.notDownloaded),
            snap(.downloaded, fraction: 0.5),
            snap(.current),
        ])
        let io = CoordinatedFileIO(fileSystem: fs)

        var yielded: [Double] = []
        for try await progress in io.download(at: u("ops.jsonl")) {
            yielded.append(progress)
        }

        XCTAssertEqual(yielded.last, 1.0, "final yield must be 1.0 on reaching .current")
        XCTAssertEqual(fs.observedStartCalls, 1, "start must be called exactly once")
    }

    func test_alreadyCurrentSkipsStart() async throws {
        // A locally-current file must yield 1.0 and finish without ever calling
        // startDownloadingUbiquitousItem (no needless download of a present file).
        let fs = FakeUbiquitousFileSystem(snapshots: [snap(.current)])
        let io = CoordinatedFileIO(fileSystem: fs)

        var yielded: [Double] = []
        for try await progress in io.download(at: u("local.jsonl")) {
            yielded.append(progress)
        }

        XCTAssertEqual(yielded, [1.0])
        XCTAssertEqual(fs.observedStartCalls, 0, "start must not be called when already .current")
    }

    func test_nonUbiquitousLocalFile_readyWithoutDownload() async throws {
        // A plain local file (NOT an iCloud item) reports nil status. As long as
        // it exists it's already readable — the reader must NOT call
        // startDownloadingUbiquitousItem (which throws for non-ubiquitous items)
        // and must finish at once. This is what broke browsing a local folder.
        let fs = FakeUbiquitousFileSystem(snapshots: [snap(nil)], fileExists: true)
        let io = CoordinatedFileIO(fileSystem: fs)

        var yielded: [Double] = []
        for try await progress in io.download(at: u("local.md")) { yielded.append(progress) }

        XCTAssertEqual(yielded, [1.0])
        XCTAssertEqual(fs.observedStartCalls, 0, "a present local file must not trigger a download")
    }

    func test_downloadedStatus_readyWithoutDownload() async throws {
        // `.downloaded` (local copy exists, cloud has a newer version) is readable
        // now — must finish, NOT poll forever waiting for `.current`.
        let fs = FakeUbiquitousFileSystem(snapshots: [snap(.downloaded)])
        let io = CoordinatedFileIO(fileSystem: fs)

        var yielded: [Double] = []
        for try await progress in io.download(at: u("synced.jsonl")) { yielded.append(progress) }

        XCTAssertEqual(yielded, [1.0])
        XCTAssertEqual(fs.observedStartCalls, 0)
    }

    func test_throwsOnDownloadError() async throws {
        let boom = FakeDownloadError(message: "boom")
        let fs = FakeUbiquitousFileSystem(snapshots: [
            snap(.notDownloaded),
            snap(.notDownloaded, error: boom),
        ])
        let io = CoordinatedFileIO(fileSystem: fs)

        do {
            for try await _ in io.download(at: u("evicted.jsonl")) {}
            XCTFail("stream should have thrown the download error")
        } catch let e as FakeDownloadError {
            XCTAssertEqual(e, boom)
        }
    }

    func test_throwsOnStartFailure() async throws {
        let cantStart = FakeDownloadError(message: "not ubiquitous")
        let fs = FakeUbiquitousFileSystem(snapshots: [snap(.notDownloaded)], startError: cantStart)
        let io = CoordinatedFileIO(fileSystem: fs)

        do {
            for try await _ in io.download(at: u("nope.jsonl")) {}
            XCTFail("stream should have thrown the start failure")
        } catch let e as FakeDownloadError {
            XCTAssertEqual(e, cantStart)
        }
    }

    func test_throwsOnCancellation() async throws {
        // Stalls forever on .notDownloaded (an evicted placeholder that never
        // becomes ready), so the loop is always mid-poll when we cancel — making
        // the cancellation deterministic.
        let fs = FakeUbiquitousFileSystem(snapshots: [snap(.notDownloaded, fraction: 0.3)])
        let io = CoordinatedFileIO(fileSystem: fs)

        // The contract: cancelling the consuming task stops the download and the
        // stream finishes by throwing CancellationError (it must NOT run to a
        // spurious successful completion / yield 1.0). We iterate inside a child
        // task and cancel it mid-poll; the producer's between-polls cancellation
        // check converts to a thrown CancellationError that the consumer sees.
        enum Outcome: Equatable { case threwCancellation; case threwOther; case finishedNormally }
        let consumer = Task<Outcome, Never> {
            do {
                for try await _ in io.download(at: u("stalled.jsonl")) {}
                return .finishedNormally
            } catch is CancellationError {
                return .threwCancellation
            } catch {
                return .threwOther
            }
        }

        // Let the loop reach its first between-polls sleep (100ms backoff), then
        // cancel it there. 75ms sits safely inside that window with margin for a
        // loaded CI runner's task-spawn latency.
        try await Task.sleep(for: .milliseconds(75))
        consumer.cancel()

        let outcome = await consumer.value
        XCTAssertEqual(outcome, .threwCancellation,
                       "cancelled stream must throw CancellationError, not finish normally")
    }

    func test_fileSizeReadsResourceValueWithoutDownloading() {
        let fs = FakeUbiquitousFileSystem(snapshots: [snap(.notDownloaded)], fileSize: 4096)
        let io = CoordinatedFileIO(fileSystem: fs)

        XCTAssertEqual(io.fileSize(at: u("sized.jsonl")), 4096)
        XCTAssertEqual(fs.observedStartCalls, 0, "fileSize must not trigger a download")
    }
}
