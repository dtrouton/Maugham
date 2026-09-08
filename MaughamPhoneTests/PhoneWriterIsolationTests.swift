import XCTest
@testable import MaughamCore
@testable import MaughamPhone

/// The phone's asset writes stay off the main actor (the whole-branch review's I4).
///
/// Task 7 made `InboxCaptureWriter` `@MainActor` to reach `JSONLAppendStore`,
/// and that took `writeImage`'s and `writeAudio`'s coordinated `Data.write`
/// with it — a whole photograph or a whole `.m4a`, inside an `NSFileCoordinator`
/// claim against an iCloud Drive path, on the phone's one interaction that must
/// never hitch. Nothing red catches it: the bytes are identical either way and
/// the tests are fast and local. The only place it is visible is from INSIDE the
/// write, which is what the observer seam is for.
///
/// The class is `@MainActor` on purpose: that is where the real caller
/// (`CaptureView`, `AnnotationDetailView`) makes these calls from, so this is
/// the production calling convention rather than a friendlier one.
@MainActor
final class PhoneWriterIsolationTests: XCTestCase {

    /// Thread-safe collection point for what the observer saw. The observer
    /// runs on whatever thread the write is on, which is the whole question.
    private final class Sightings: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func record(_ isMain: Bool) {
            lock.lock(); defer { lock.unlock() }
            values.append(isMain)
        }
        var all: [Bool] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    private var identity: DeviceIdentity!
    private var root: URL!

    override func setUpWithError() throws {
        identity = .softwareForTesting()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CoordinatedFileIO.writeObserverForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }

    private var manifestURL: URL {
        InboxManifest.inboxManifestURL(forDeviceSlug: identity.slug, in: root)
    }

    private func manifestLines() throws -> [Data] {
        try Data(contentsOf: manifestURL)
            .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
            .map { Data($0) }
    }

    func test_theAssetWriteRunsOffTheMainThreadAndTheRowStillChainsAndSeals() async throws {
        let sightings = Sightings()
        CoordinatedFileIO.writeObserverForTesting = { sightings.record(Thread.isMainThread) }

        let writer = InboxCaptureWriter(projectRoot: root, identity: identity)
        let entry = try await writer.writeImage(
            Data(repeating: 0xAB, count: 4096), ext: "jpg", title: "a photograph")

        let seen = sightings.all
        XCTAssertEqual(seen.count, 1, "one coordinated asset write")
        XCTAssertEqual(seen.first, false,
            "the photograph must not be written on the main thread — it is a "
            + "coordinated write of unbounded size against an iCloud path")

        let lines = try manifestLines()
        XCTAssertEqual(lines.count, 2, "the row and the seal that signs it")
        XCTAssertEqual(OpLogChain.prev(ofLine: lines[0]), .some(OpLogChain.genesis),
            "the row is still chained")
        XCTAssertTrue(OpLogChain.isSealLine(lines[1]), "and still sealed")

        let read = try await JSONLAppendStore<InboxEntry>(fileURL: manifestURL).load()
        XCTAssertEqual(read.map(\.id), [entry.id])
        XCTAssertEqual(read.first?.sourceFilename, "\(entry.id).jpg")
    }

    func test_theAudioCopyRunsOffTheMainThreadToo() async throws {
        let sightings = Sightings()
        CoordinatedFileIO.writeObserverForTesting = { sightings.record(Thread.isMainThread) }

        let scratch = root.appendingPathComponent("scratch.m4a")
        try Data(repeating: 0x11, count: 2048).write(to: scratch)

        let writer = InboxCaptureWriter(projectRoot: root, identity: identity)
        _ = try await writer.writeAudio(from: scratch, transcriptDraft: "spoken")

        XCTAssertEqual(sightings.all, [false])
        let lines = try manifestLines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(OpLogChain.isSealLine(lines[1]))
    }
}
