// MaughamTests/OpLog/CrossMacMergeTests.swift
import XCTest
import MaughamCore
@testable import Maugham

final class CrossMacMergeTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMM-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_logMerge_deduplicatesByOpIdAndSortsAcrossDevices() async throws {
        let store = await OpLogStore(projectURL: tmp)
        // Simulate Mac A ops and Mac B ops arriving in mixed order.
        try await store.append(Op(
            opId: "01HZK02", docId: "d", at: Date(), device: "mac-A",
            session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "a", prior: nil, next: "A-1")]))
        try await store.append(Op(
            opId: "01HZK01", docId: "d", at: Date(), device: "mac-B",
            session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "a", prior: nil, next: "B-0")]))
        try await store.append(Op(
            opId: "01HZK02", docId: "d", at: Date(), device: "mac-A",
            session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "a", prior: nil, next: "A-1-dup")]))

        let ops = try await store.load(docId: "d")
        XCTAssertEqual(ops.map(\.opId), ["01HZK01", "01HZK02"])
        // LWW: 01HZK02 wins for paragraph a.
        let state = Deriver.derive(ops: ops)
        XCTAssertEqual(state.paragraphs["a"], "A-1")
    }
}
