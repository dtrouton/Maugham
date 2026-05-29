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
        let cps = try await s.load()
        XCTAssertEqual(cps, [])
    }

    func test_appendThenLoad_returnsAppended() async throws {
        let s = CheckpointStore(projectURL: tmp)
        let cp = makeCheckpoint(id: "cp-1")
        try await s.append(cp)
        let loaded = try await s.load()
        XCTAssertEqual(loaded, [cp])
    }

    func test_load_returnsInAppendOrder() async throws {
        let s = CheckpointStore(projectURL: tmp)
        try await s.append(makeCheckpoint(id: "cp-1"))
        try await s.append(makeCheckpoint(id: "cp-2"))
        try await s.append(makeCheckpoint(id: "cp-3"))
        let loaded = try await s.load()
        XCTAssertEqual(loaded.map(\.checkpointId), ["cp-1", "cp-2", "cp-3"])
    }
}
