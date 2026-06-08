// MaughamTests/OpLog/DeriverTests.swift
import XCTest
import MaughamCore
@testable import Maugham

final class DeriverTests: XCTestCase {
    private func makeOp(
        opId: String, kind: OpKind = .typingBurst,
        changes: [Op.ParagraphChange], sequence: [String]? = nil
    ) -> Op {
        return Op(
            opId: opId, docId: "doc-1", at: Date(), device: "m", session: "s",
            kind: kind, changes: changes, sequence: sequence)
    }

    func test_derive_emptyLog_returnsEmptyState() {
        let state = Deriver.derive(ops: [])
        XCTAssertEqual(state.paragraphs, [:])
        XCTAssertEqual(state.sequence, [])
    }

    func test_derive_singleBurst_populatesParagraphsAndSequence() {
        let op = makeOp(opId: "1", changes: [
            .init(paragraphId: "a", prior: nil, next: "First."),
            .init(paragraphId: "b", prior: nil, next: "Second."),
        ], sequence: ["a", "b"])
        let state = Deriver.derive(ops: [op])
        XCTAssertEqual(state.paragraphs, ["a": "First.", "b": "Second."])
        XCTAssertEqual(state.sequence, ["a", "b"])
    }

    func test_derive_lastWriteWinsPerParagraph() {
        let ops = [
            makeOp(opId: "1", changes: [.init(paragraphId: "a", prior: nil, next: "First v1")], sequence: ["a"]),
            makeOp(opId: "2", changes: [.init(paragraphId: "a", prior: "First v1", next: "First v2")]),
        ]
        let state = Deriver.derive(ops: ops)
        XCTAssertEqual(state.paragraphs["a"], "First v2")
    }

    func test_derive_sequenceUpdatedOnlyWhenOpCarriesSequence() {
        let ops = [
            makeOp(opId: "1", changes: [.init(paragraphId: "a", prior: nil, next: "A")], sequence: ["a"]),
            makeOp(opId: "2", changes: [.init(paragraphId: "a", prior: nil, next: "A2")]),  // no sequence
            makeOp(opId: "3", changes: [.init(paragraphId: "b", prior: nil, next: "B")], sequence: ["a", "b"]),
        ]
        let state = Deriver.derive(ops: ops)
        XCTAssertEqual(state.sequence, ["a", "b"])
    }

    // RED until M1/M2 — asserts post-fix order-independent LWW; see plan 0.2/0.4
    // + finding 0.4 / sweep-3. The old test blessed "deriver applies ops in
    // argument order, ignores opId," cementing an unenforced "caller must sort"
    // precondition that the whole merge-determinism story silently rests on.
    //
    // Correct contract: for a given paragraph, last-write-wins is BY opId
    // (the system's documented intent — ULIDs give a deterministic total
    // order), so derivation must be independent of input order. We MAY pin the
    // winner here because highest-opId-wins is documented intent, unlike the
    // cross-file content-collision survivor (M2.1) which we don't pin.
    func test_derive_isOrderIndependent_highestOpIdWinsPerParagraph() {
        let earlier = makeOp(opId: "1",
            changes: [.init(paragraphId: "a", prior: nil, next: "Earlier")],
            sequence: ["a"])
        let later = makeOp(opId: "2",
            changes: [.init(paragraphId: "a", prior: "Earlier", next: "Later")])

        // opId-sorted input and reverse (shuffled) input must derive the same.
        let sorted = Deriver.derive(ops: [earlier, later])
        let shuffled = Deriver.derive(ops: [later, earlier])

        XCTAssertEqual(sorted, shuffled,
            "derive must be order-independent: same ops, any order, same state")
        XCTAssertEqual(shuffled.paragraphs["a"], "Later",
            "highest opId wins per paragraph regardless of argument order")
    }
}
