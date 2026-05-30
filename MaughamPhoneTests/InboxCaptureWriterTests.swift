import XCTest
import MaughamCore
@testable import MaughamPhone

/// Proves phone-write / Mac-read compatibility: every assertion reads the
/// manifest back through the Mac's OWN reader (`JSONLAppendStore<InboxEntry>`),
/// so a divergence in date strategy, CodingKeys, or file naming fails here rather
/// than silently producing rows the Mac can't decode.
@MainActor
final class InboxCaptureWriterTests: XCTestCase {
    private let deviceId = "phone:TESTDEVICE"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var manifestURL: URL {
        root.appendingPathComponent(".maugham/inbox/inbox.\(DeviceSlug.make(from: deviceId)).jsonl")
    }

    /// Read the manifest back through the Mac reader.
    private func loadEntries() async throws -> [InboxEntry] {
        try await JSONLAppendStore<InboxEntry>(fileURL: manifestURL).load()
    }

    private func makeWriter(now: @escaping () -> Date = { Date() }) -> InboxCaptureWriter {
        InboxCaptureWriter(projectRoot: root, deviceId: deviceId, now: now)
    }

    func test_writeText_roundTripsThroughMacReader() async throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let written = try await makeWriter(now: { fixed }).writeText("hello world", title: "A note")

        let entries = try await loadEntries()
        XCTAssertEqual(entries.count, 1)
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.id, written.id)
        XCTAssertEqual(e.kind, .text)
        XCTAssertEqual(e.inlineText, "hello world")
        XCTAssertEqual(e.title, "A note")
        XCTAssertNil(e.sourceFilename)
        XCTAssertEqual(e.status, .new)
        XCTAssertEqual(e.deviceId, deviceId)
        let writtenAt = try XCTUnwrap(e.writtenAt)
        XCTAssertGreaterThan(writtenAt, e.createdAt)

        // Manifest file is the per-device stream named off the device slug.
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path),
                      "expected manifest at inbox.\(DeviceSlug.make(from: deviceId)).jsonl")
    }

    func test_writeImage_writesAssetAndManifest() async throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        let written = try await makeWriter().writeImage(bytes, ext: "jpg")

        let assetURL = root.appendingPathComponent(".maugham/inbox/images/\(written.id).jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
        XCTAssertEqual(try Data(contentsOf: assetURL), bytes)

        let entries = try await loadEntries()
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.id, written.id)
        XCTAssertEqual(e.kind, .image)
        XCTAssertEqual(e.sourceFilename, "\(written.id).jpg")
        XCTAssertNil(e.inlineText)
        XCTAssertEqual(e.status, .new)
    }

    func test_writeAudio_movesM4aAndSetsDraft() async throws {
        let audioBytes = Data("fake-m4a-bytes".utf8)
        let tempURL = root.appendingPathComponent("recording-tmp.m4a")
        try audioBytes.write(to: tempURL)

        let written = try await makeWriter().writeAudio(from: tempURL, transcriptDraft: "hello")

        let assetURL = root.appendingPathComponent(".maugham/inbox/audio/\(written.id).m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
        XCTAssertEqual(try Data(contentsOf: assetURL), audioBytes)

        let entries = try await loadEntries()
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.kind, .audio)
        XCTAssertEqual(e.sourceFilename, "\(written.id).m4a")
        XCTAssertEqual(e.transcript, "hello")
        XCTAssertEqual(e.transcriptionState, .onDeviceDraft)
    }

    func test_writtenAt_isMonotonicAfterCreatedAt() async throws {
        // now == createdAt; tripwire 17 requires writtenAt == createdAt + 1ms.
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = makeWriter(now: { fixed }).buildEntry(kind: .text, inlineText: "x")
        XCTAssertEqual(entry.createdAt, fixed)
        let writtenAt = try XCTUnwrap(entry.writtenAt)
        XCTAssertEqual(writtenAt.timeIntervalSince(fixed), 0.001, accuracy: 0.0001)
    }

    func test_multipleCaptures_appendToSamePerDeviceFile() async throws {
        let writer = makeWriter()
        let a = try await writer.writeText("one")
        let b = try await writer.writeText("two")
        let c = try await writer.writeText("three")

        let entries = try await loadEntries()
        XCTAssertEqual(entries.count, 3)
        let ids = Set(entries.map(\.id))
        XCTAssertEqual(ids.count, 3, "ids must be distinct")
        XCTAssertEqual(ids, [a.id, b.id, c.id])
    }
}
