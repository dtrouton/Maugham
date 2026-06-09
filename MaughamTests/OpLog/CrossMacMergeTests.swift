// MaughamTests/OpLog/CrossMacMergeTests.swift
import XCTest
@testable import MaughamCore
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

    // RED until M1/M2 — asserts post-fix merge determinism (load-order
    // independence on a divergent-content opId collision); see plan 0.2/0.4 +
    // finding 0.4. The old test asserted "A-1 survives purely because it loaded
    // first," certifying silent, load-order-dependent data loss as correct.
    //
    // `mergeSortedDedup` is fed by filesystem-enumeration-order reads, so its
    // input order is NOT controllable in production; the contract it must honor
    // is that its OUTPUT is the same whichever order the inputs arrive in. We
    // assert that order-swap-equality property directly.
    func test_logMerge_dedupesAndSorts_andIsDeterministicOnDivergentCollision() throws {
        // Non-colliding op from a third device.
        let opB0 = Op(
            opId: "01HZK01", docId: "d", at: Date(timeIntervalSince1970: 0),
            device: "mac-C", session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "aaaa", prior: nil, next: "B-0")],
            sequence: ["aaaa"])
        // The collision: SAME opId, DIFFERENT content (the bug the byte-identical
        // fixtures never exercised).
        let opA = Op(
            opId: "01HZK02", docId: "d", at: Date(timeIntervalSince1970: 0),
            device: "mac-A", session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "aaaa", prior: nil, next: "A-1")],
            sequence: ["aaaa"])
        let opADup = Op(
            opId: "01HZK02", docId: "d", at: Date(timeIntervalSince1970: 0),
            device: "mac-B", session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "aaaa", prior: nil, next: "A-1-dup")],
            sequence: ["aaaa"])

        // Same logical inputs, only the relative order of the colliding pair
        // differs — exactly what two devices' file-enumeration orders can do.
        let mergedXY = OpLogStore.mergeSortedDedup([opB0, opA, opADup])
        let mergedYX = OpLogStore.mergeSortedDedup([opB0, opADup, opA])

        // Dedup-and-sort still holds: two opIds survive, opId-ordered, either way.
        XCTAssertEqual(mergedXY.map(\.opId), ["01HZK01", "01HZK02"])
        XCTAssertEqual(mergedYX.map(\.opId), ["01HZK01", "01HZK02"])

        // Determinism = LOAD-ORDER INDEPENDENCE. We deliberately do NOT pin which
        // content wins (the survivor rule is M2.1's unmade design decision); we
        // assert only that the choice is the SAME whichever order the colliding
        // op was seen in — both at the op level and after derivation.
        XCTAssertEqual(
            mergedXY.first { $0.opId == "01HZK02" }?.changes.first?.next,
            mergedYX.first { $0.opId == "01HZK02" }?.changes.first?.next,
            "divergent same-opId collision must resolve to the same survivor "
                + "regardless of input/file order (no silent first-wins)")

        XCTAssertEqual(
            Deriver.derive(ops: mergedXY),
            Deriver.derive(ops: mergedYX),
            "two devices with identical logs must derive identical state "
                + "regardless of merge order")
    }
}
