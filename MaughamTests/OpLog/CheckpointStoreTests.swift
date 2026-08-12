// MaughamTests/OpLog/CheckpointStoreTests.swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class CheckpointStoreTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CST-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeCheckpoint(id: String, label: String = "L") -> Checkpoint {
        Checkpoint(
            checkpointId: id, label: label, labelSource: .user,
            at: Date(timeIntervalSince1970: 0), device: "m",
            activeDoc: "doc-1", docPointers: ["doc-1": "op-1"],
            manuscriptWordCount: 42)
    }

    func test_load_missingFile_returnsEmpty() async throws {
        let s = CheckpointStore(projectURL: tmp)
        let cps = await s.load().checkpoints
        XCTAssertEqual(cps, [])
    }

    func test_appendThenLoad_returnsAppended() async throws {
        let s = CheckpointStore(projectURL: tmp)
        let cp = makeCheckpoint(id: "cp-1")
        try await s.append(cp)
        let loaded = await s.load().checkpoints
        XCTAssertEqual(loaded, [cp])
    }

    func test_load_returnsInAppendOrder() async throws {
        let s = CheckpointStore(projectURL: tmp)
        try await s.append(makeCheckpoint(id: "cp-1"))
        try await s.append(makeCheckpoint(id: "cp-2"))
        try await s.append(makeCheckpoint(id: "cp-3"))
        let loaded = await s.load().checkpoints
        XCTAssertEqual(loaded.map(\.checkpointId), ["cp-1", "cp-2", "cp-3"])
    }

    // MARK: - RULING-54: unreadable is never presented as empty

    /// An UNREADABLE-yet-present device file (a directory squatting on its
    /// path — the same failure shape as a permissions break or an iCloud
    /// dataless stub) must be NAMED in the result, never silently contribute
    /// zero checkpoints: the empty read is how a device's checkpoints vanished
    /// from History/Rewind with no trace (probe 2026-08-12: `load()` returned
    /// the readable device's rows with no error and no record of the bad
    /// file). Unlike the op log this is a notice, not a refusal — the
    /// readable devices' rows still load, because nothing derives manuscript
    /// text from this read.
    func test_load_unreadableDeviceFile_isNamedAndTheRestStillLoad() async throws {
        let s = CheckpointStore(projectURL: tmp)
        try await s.append(makeCheckpoint(id: "cp-1"))
        let bad = DeviceSlug.make(from: "bad")
        let badURL = CheckpointStore.fileURL(deviceSlug: bad, in: tmp)
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)

        let result = await s.load()

        XCTAssertEqual(result.checkpoints.map(\.checkpointId), ["cp-1"],
                       "the readable device's checkpoints still load")
        XCTAssertEqual(result.unreadableFiles.map(\.name), [badURL.lastPathComponent],
                       "the unreadable file is named, not silently empty")
        XCTAssertFalse(result.unreadableFiles[0].reason.isEmpty,
                       "the underlying reason rides along for the notice/log")
    }

    /// ABSENT stays fine — a project with no checkpoint files at all is the
    /// legitimate no-checkpoints-yet state, not an error.
    func test_load_absentFiles_reportNothingUnreadable() async throws {
        let result = await CheckpointStore(projectURL: tmp).load()
        XCTAssertTrue(result.checkpoints.isEmpty)
        XCTAssertTrue(result.unreadableFiles.isEmpty)
    }

    /// The HistoryPane notice: nil when everything read cleanly, names the
    /// files when it didn't (static so the copy is pinnable without a
    /// window mount — the `predecessorIndex` pattern).
    func test_historyPaneNotice_namesTheFiles_andIsNilWhenClean() {
        XCTAssertNil(HistoryPane.unreadableCheckpointNotice([]))
        let notice = HistoryPane.unreadableCheckpointNotice(
            ["checkpoints.bad.jsonl"])
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice?.contains("checkpoints.bad.jsonl") == true,
                      "the notice names the unreadable file")
    }
}
