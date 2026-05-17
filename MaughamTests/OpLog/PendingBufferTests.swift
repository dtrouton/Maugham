// MaughamTests/OpLog/PendingBufferTests.swift
import XCTest
@testable import Maugham

@MainActor
final class PendingBufferTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PBT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_recordChange_thenSnapshot_returnsRecorded() {
        let buf = PendingBuffer(projectURL: tmp, docId: "d")
        buf.recordChange(paragraphId: "a", prior: nil, next: "Hello.")
        XCTAssertEqual(buf.snapshot().map(\.paragraphId), ["a"])
    }

    func test_recordChange_multipleSamePid_keepsLatest() {
        let buf = PendingBuffer(projectURL: tmp, docId: "d")
        buf.recordChange(paragraphId: "a", prior: nil, next: "v1")
        buf.recordChange(paragraphId: "a", prior: "v1", next: "v2")
        let snap = buf.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0].next, "v2")
    }

    func test_flushToDisk_writesPendingJsonl() async throws {
        let buf = PendingBuffer(projectURL: tmp, docId: "d")
        buf.recordChange(paragraphId: "a", prior: nil, next: "Hello.")
        try await buf.flushToDisk()
        let url = tmp.appendingPathComponent(".maugham/ops/d.pending.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"a\""))
        XCTAssertTrue(text.contains("Hello."))
    }

    func test_clear_emptiesInMemoryAndDeletesDiskFile() async throws {
        let buf = PendingBuffer(projectURL: tmp, docId: "d")
        buf.recordChange(paragraphId: "a", prior: nil, next: "Hello.")
        try await buf.flushToDisk()
        try await buf.clear()
        XCTAssertEqual(buf.snapshot().count, 0)
        let url = tmp.appendingPathComponent(".maugham/ops/d.pending.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_loadFromDisk_recoversRecordedChanges() async throws {
        let original = PendingBuffer(projectURL: tmp, docId: "d")
        original.recordChange(paragraphId: "a", prior: nil, next: "From disk.")
        try await original.flushToDisk()

        let fresh = PendingBuffer(projectURL: tmp, docId: "d")
        try await fresh.loadFromDisk()
        let snap = fresh.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0].paragraphId, "a")
        XCTAssertEqual(snap[0].next, "From disk.")
    }
}
