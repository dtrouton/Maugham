// MaughamTests/OpLog/OpLogStoreTests.swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class OpLogStoreTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OLT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeOp(opId: String) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 0),
           device: "m", session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "a", prior: nil, next: "x")])
    }

    func test_load_missingFile_returnsEmpty() async throws {
        let store = OpLogStore(projectURL: tmp)
        let ops = try await store.load(docId: "doc-1")
        XCTAssertEqual(ops, [])
    }

    func test_appendThenLoad_returnsAppendedOp() async throws {
        let store = OpLogStore(projectURL: tmp)
        let op = makeOp(opId: "01HZK01")
        try await store.append(op)
        let loaded = try await store.load(docId: "doc-1")
        XCTAssertEqual(loaded, [op])
    }

    func test_load_sortsByOpId() async throws {
        let store = OpLogStore(projectURL: tmp)
        try await store.append(makeOp(opId: "01HZK03"))
        try await store.append(makeOp(opId: "01HZK01"))
        try await store.append(makeOp(opId: "01HZK02"))
        let loaded = try await store.load(docId: "doc-1")
        XCTAssertEqual(loaded.map(\.opId), ["01HZK01", "01HZK02", "01HZK03"])
    }

    func test_load_deduplicatesByOpId() async throws {
        let store = OpLogStore(projectURL: tmp)
        try await store.append(makeOp(opId: "01HZK01"))
        try await store.append(makeOp(opId: "01HZK01"))   // duplicate
        let loaded = try await store.load(docId: "doc-1")
        XCTAssertEqual(loaded.count, 1)
    }

    func test_load_dropsUnparseableTrailingLines() async throws {
        let store = OpLogStore(projectURL: tmp)
        let op = makeOp(opId: "01HZK01")
        try await store.append(op)
        // Manually append a corrupted trailing line.
        let opsDir = tmp.appendingPathComponent(".maugham/ops")
        let file = opsDir.appendingPathComponent("doc-1.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"this is\": \"truncated\n".utf8))
        try handle.close()
        let loaded = try await store.load(docId: "doc-1")
        XCTAssertEqual(loaded.count, 1, "corrupt trailing line should be dropped")
    }
}
