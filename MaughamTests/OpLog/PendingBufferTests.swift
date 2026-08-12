// MaughamTests/OpLog/PendingBufferTests.swift
import XCTest
@testable import Maugham
@testable import MaughamCore

@MainActor
final class PendingBufferTests: XCTestCase {
    private var tmp: URL!
    private let device = "Denvers-Mac.local"

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PBT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// The device-partitioned, relocated pending-buffer path for a given doc.
    private func pendingURL(docId: String) -> URL {
        let slug = DeviceSlug.make(from: device)
        return tmp.appendingPathComponent(".maugham/pending/\(docId).\(slug.raw).pending.jsonl")
    }

    func test_recordChange_thenSnapshot_returnsRecorded() {
        let buf = PendingBuffer(projectURL: tmp, docId: "d", device: device)
        buf.recordChange(paragraphId: "a", prior: nil, next: "Hello.")
        XCTAssertEqual(buf.snapshot().map(\.paragraphId), ["a"])
    }

    func test_recordChange_multipleSamePid_keepsLatest() {
        let buf = PendingBuffer(projectURL: tmp, docId: "d", device: device)
        buf.recordChange(paragraphId: "a", prior: nil, next: "v1")
        buf.recordChange(paragraphId: "a", prior: "v1", next: "v2")
        let snap = buf.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0].next, "v2")
    }

    func test_flushToDisk_writesDevicePartitionedPendingJsonl() async throws {
        let buf = PendingBuffer(projectURL: tmp, docId: "d", device: device)
        buf.recordChange(paragraphId: "a", prior: nil, next: "Hello.")
        try await buf.flushToDisk()

        // (a) Device-partitioned: the filename carries this device's slug.
        let url = pendingURL(docId: "d")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "pending file must be at the device-partitioned path")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"a\""))
        XCTAssertTrue(text.contains("Hello."))

        // (b) NOT under .maugham/ops/ — it must not be able to match the
        // op-log glob. The old unpartitioned `.maugham/ops/<docId>.pending.jsonl`
        // path must not exist.
        let oldOpsPath = tmp.appendingPathComponent(".maugham/ops/d.pending.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldOpsPath.path),
                       "pending file must NOT live under .maugham/ops/")
    }

    /// The highest-value tripwire: a flushed pending file must NOT be picked up
    /// by the op-log glob (it used to, because it lived under `.maugham/ops/`
    /// and matched `<docId>.*.jsonl`). Relocating it outside `ops/` is what
    /// makes this pass.
    func test_flushedPending_notMatchedByOpLogGlob() async throws {
        let docId = "d_01HQ7T3JKM2N4P5R6S8VWX0Y2Z"
        let buf = PendingBuffer(projectURL: tmp, docId: docId, device: device)
        buf.recordChange(paragraphId: "aaaa", prior: nil, next: "uncommitted")
        try await buf.flushToDisk()

        let opLogFiles = OpLogStore.opLogFileURLs(forDocId: docId, in: tmp)
        XCTAssertTrue(opLogFiles.isEmpty,
                      "the pending file must not be returned by the op-log glob")
        XCTAssertEqual(try OpLogStore.loadSyncMerged(forDocId: docId, in: tmp).count, 0,
                       "the pending file must not be ingested as op-log content")
    }

    func test_clear_emptiesInMemoryAndDeletesDiskFile() async throws {
        let buf = PendingBuffer(projectURL: tmp, docId: "d", device: device)
        buf.recordChange(paragraphId: "a", prior: nil, next: "Hello.")
        try await buf.flushToDisk()
        try await buf.clear()
        XCTAssertEqual(buf.snapshot().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL(docId: "d").path))
    }

    func test_loadFromDisk_recoversRecordedChanges_sameDevice() async throws {
        let original = PendingBuffer(projectURL: tmp, docId: "d", device: device)
        original.recordChange(paragraphId: "a", prior: nil, next: "From disk.")
        try await original.flushToDisk()

        // A fresh buffer for the SAME device (the crashed device recovering its
        // own uncommitted keystrokes) reads back from the partitioned path.
        let fresh = PendingBuffer(projectURL: tmp, docId: "d", device: device)
        await fresh.loadFromDisk()
        let snap = fresh.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0].paragraphId, "a")
        XCTAssertEqual(snap[0].next, "From disk.")
    }

    /// Recovery is this-device-only: another device's pending buffer must NOT be
    /// folded in (its un-bursted keystrokes are not this device's to commit).
    func test_loadFromDisk_doesNotReadOtherDevicesPending() async throws {
        let other = PendingBuffer(projectURL: tmp, docId: "d", device: "phone:D2A1F8B0")
        other.recordChange(paragraphId: "z", prior: nil, next: "phone draft")
        try await other.flushToDisk()

        let thisDevice = PendingBuffer(projectURL: tmp, docId: "d", device: device)
        await thisDevice.loadFromDisk()
        XCTAssertEqual(thisDevice.snapshot().count, 0,
                       "loadFromDisk must read only THIS device's slug file")
    }

    // MARK: - RULING-54: an unrecoverable pending file is never silent

    /// An UNDECODABLE-yet-present pending file holds the writer's un-bursted
    /// keystrokes from a crashed session; it used to collapse into the absent
    /// case (silent return) and the next autosave overwrote the only copy.
    /// Now the outcome names the file, the reason, and carries the raw bytes
    /// so the caller can preserve them.
    func test_loadFromDisk_undecodableFile_reportsUnrecoverableWithRawCarried() async throws {
        let url = pendingURL(docId: "d")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "NOT JSON — a crashed session's torn pending state".write(
            to: url, atomically: true, encoding: .utf8)

        let buf = PendingBuffer(projectURL: tmp, docId: "d", device: device)
        let outcome = await buf.loadFromDisk()

        guard case .unrecoverable(let name, let reason, let raw) = outcome else {
            XCTFail("expected .unrecoverable, got \(outcome)"); return
        }
        XCTAssertEqual(name, url.lastPathComponent, "the file is named")
        XCTAssertFalse(reason.isEmpty, "the decode failure's reason rides along")
        XCTAssertEqual(raw, "NOT JSON — a crashed session's torn pending state",
                       "the readable bytes are carried so the caller can preserve them")
        XCTAssertEqual(buf.snapshot().count, 0, "nothing half-folded")
    }

    /// UNREADABLE-yet-present (a directory squatting on the pending path — the
    /// permissions-break / dataless-stub shape): unrecoverable with no raw.
    func test_loadFromDisk_unreadableFile_reportsUnrecoverableWithoutRaw() async throws {
        let url = pendingURL(docId: "d")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let buf = PendingBuffer(projectURL: tmp, docId: "d", device: device)
        let outcome = await buf.loadFromDisk()

        guard case .unrecoverable(let name, _, let raw) = outcome else {
            XCTFail("expected .unrecoverable, got \(outcome)"); return
        }
        XCTAssertEqual(name, url.lastPathComponent)
        XCTAssertNil(raw, "nothing could be read, so nothing is claimed")
    }

    /// ABSENT stays the clean-quit state, and a good file reports .loaded.
    func test_loadFromDisk_absentAndLoadedOutcomes() async throws {
        let buf = PendingBuffer(projectURL: tmp, docId: "d", device: device)
        let absent = await buf.loadFromDisk()
        XCTAssertEqual(absent, .absent)

        buf.recordChange(paragraphId: "a", prior: nil, next: "words")
        try await buf.flushToDisk()
        let fresh = PendingBuffer(projectURL: tmp, docId: "d", device: device)
        let loaded = await fresh.loadFromDisk()
        XCTAssertEqual(loaded, .loaded)
        XCTAssertEqual(fresh.snapshot().count, 1)
    }
}
