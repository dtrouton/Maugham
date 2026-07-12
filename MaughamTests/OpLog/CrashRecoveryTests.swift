// MaughamTests/OpLog/CrashRecoveryTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

@MainActor
final class CrashRecoveryTests: XCTestCase {
    private var tmp: URL!
    private let device = "m"

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_pendingBufferOnDisk_isRecoveredOnReopen() async throws {
        // Simulate session 1: write to pending, do not flush burst.
        do {
            let buf = PendingBuffer(projectURL: tmp, docId: "d", device: device)
            buf.recordChange(paragraphId: "a", prior: nil, next: "Crashed in-flight.")
            try await buf.flushToDisk()
        }

        // Simulate session 2: open fresh buffer, recover from disk, flush to op log.
        let buf2 = PendingBuffer(projectURL: tmp, docId: "d", device: device)
        try await buf2.loadFromDisk()
        XCTAssertEqual(buf2.snapshot().count, 1)

        // Fold recovered pending into a fresh typing_burst op.
        let op = Op(
            opId: ULID.generate(), docId: "d", at: Date(),
            device: device, session: "s", kind: .typingBurst,
            changes: buf2.snapshot())
        try await OpLogStore(projectURL: tmp).append(op)
        try await buf2.clear()

        // Verify pending file is gone (device-partitioned path) and op log
        // carries the bytes.
        let slug = DeviceSlug.make(from: device)
        let pendingURL = tmp.appendingPathComponent(
            ".maugham/pending/d.\(slug.raw).pending.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        let loaded = try await OpLogStore(projectURL: tmp).load(docId: "d")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].changes.first?.next, "Crashed in-flight.")
    }
}
