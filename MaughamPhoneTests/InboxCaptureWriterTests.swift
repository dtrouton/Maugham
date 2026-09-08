import XCTest
@testable import MaughamCore
@testable import MaughamPhone

/// Proves phone-write / Mac-read compatibility: every assertion reads the
/// manifest back through the Mac's OWN reader (`JSONLAppendStore<InboxEntry>`),
/// so a divergence in date strategy, CodingKeys, or file naming fails here rather
/// than silently producing rows the Mac can't decode.
@MainActor
final class InboxCaptureWriterTests: XCTestCase {
    /// A signing identity: the simulator has no enclave, so a capture written
    /// under `DeviceIdentity.author` would be chained and never sealed. The
    /// software signer is what lets the seal half be asserted at all.
    private var identity: DeviceIdentity!
    private var deviceId: String { identity.deviceId }
    private var root: URL!

    override func setUpWithError() throws {
        identity = .softwareForTesting()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var manifestURL: URL {
        root.appendingPathComponent(".maugham/inbox/inbox.\(DeviceSlug.make(from: deviceId).raw).jsonl")
    }

    /// Read the manifest back through the Mac reader.
    private func loadEntries() async throws -> [InboxEntry] {
        try await JSONLAppendStore<InboxEntry>(fileURL: manifestURL).load()
    }

    /// The manifest's raw lines, seals and all — what the Mac's reader is
    /// handed before it classifies anything.
    private func manifestLines() throws -> [Data] {
        let bytes = try Data(contentsOf: manifestURL)
        return bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }.map { Data($0) }
    }

    private func makeWriter(
        now: @escaping () -> Date = { Date() }, identity: DeviceIdentity? = nil
    ) -> InboxCaptureWriter {
        InboxCaptureWriter(
            projectRoot: root, identity: identity ?? self.identity, now: now)
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
                      "expected manifest at inbox.\(DeviceSlug.make(from: deviceId).raw).jsonl")
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

    /// The phone's aim picker is gone (signed op log P1, task 8), so the writer
    /// has no way to stamp a palette aim and never does. The two fields survive
    /// on `InboxEntry` for rows already on disk — this pins that a NEW row
    /// carries neither.
    func test_theWriterNeverStampsAPaletteAim() async throws {
        let written = try await makeWriter().writeText("no aim here", title: "A note")

        let entries = try await loadEntries()
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.id, written.id)
        XCTAssertNil(e.paletteSubject)
        XCTAssertNil(e.sense)
    }

    // MARK: - The chain (task 7)

    /// Every row links to the head the phone verified, and a seal signs each
    /// capture on the spot — so the second row's `prev` is the FIRST ROW'S
    /// SEAL, which is the head by then. The Mac reads all of it unchanged.
    func test_everyCaptureIsChainedAndSealedOnTheSpot() async throws {
        let writer = makeWriter()
        let first = try await writer.writeText("one")
        let second = try await writer.writeText("two")

        let lines = try manifestLines()
        XCTAssertEqual(lines.count, 4, "a row and a seal for each of the two captures")

        XCTAssertEqual(OpLogChain.prev(ofLine: lines[0]) ?? nil, OpLogChain.genesis,
                       "the first line of a fresh file chains to the genesis sentinel")
        let firstSeal = try XCTUnwrap(OpLogChain.Seal.parse(lines[1]))
        XCTAssertTrue(firstSeal.verifies())
        XCTAssertEqual(firstSeal.key, identity.fingerprint)
        XCTAssertEqual(firstSeal.head, OpLogChain.lineHash(lines[0]))

        XCTAssertEqual(OpLogChain.prev(ofLine: lines[2]) ?? nil,
                       OpLogChain.lineHash(lines[1]),
                       "the second row chains onto the head — the seal that preceded it")
        let secondSeal = try XCTUnwrap(OpLogChain.Seal.parse(lines[3]))
        XCTAssertTrue(secondSeal.verifies())
        XCTAssertEqual(secondSeal.head, OpLogChain.lineHash(lines[2]))

        let entries = try await loadEntries()
        XCTAssertEqual(entries.map(\.id), [first.id, second.id],
                       "the Mac reader sees two captures and no seals")
    }

    /// Without a seal in between, the plain statement of the chain: the second
    /// row's `prev` is the first row's hash. A phone with no key is a state,
    /// not a failure — the rows are written and nothing throws.
    func test_aPhoneWithNoKeyChainsItsRowsAndSealsNothing() async throws {
        let unsigned = DeviceIdentity.unsignedForTesting(token: Data(repeating: 3, count: 32))
        let writer = makeWriter(identity: unsigned)
        _ = try await writer.writeText("one")
        _ = try await writer.writeText("two")

        let url = root.appendingPathComponent(
            ".maugham/inbox/inbox.\(unsigned.slug.raw).jsonl")
        let lines = try Data(contentsOf: url)
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }.map { Data($0) }
        XCTAssertEqual(lines.count, 2, "two rows, no seals")
        XCTAssertEqual(OpLogChain.prev(ofLine: lines[1]) ?? nil,
                       OpLogChain.lineHash(lines[0]))
        let entries = try await JSONLAppendStore<InboxEntry>(fileURL: url).load()
        XCTAssertEqual(entries.count, 2)
    }

    /// The row's `device_id` and the manifest's own filename come from ONE
    /// name — the identity's. Two spellings could file a capture under a
    /// device whose key never signed it.
    func test_theRowsDeviceIdIsTheIdentityThatSignedIt() async throws {
        let written = try await makeWriter().writeText("one")
        XCTAssertEqual(written.deviceId, identity.deviceId)
        XCTAssertEqual(manifestURL.lastPathComponent,
                       "inbox.\(identity.slug.raw).jsonl")
        let seal = try XCTUnwrap(OpLogChain.Seal.parse(try manifestLines()[1]))
        XCTAssertEqual(seal.key, identity.fingerprint)
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
