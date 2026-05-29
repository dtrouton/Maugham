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

    func test_derive_walksOpsInGivenOrder() {
        // Caller is responsible for sorting; deriver respects input order.
        let ops = [
            makeOp(opId: "2", changes: [.init(paragraphId: "a", prior: nil, next: "Later")], sequence: ["a"]),
            makeOp(opId: "1", changes: [.init(paragraphId: "a", prior: nil, next: "Earlier")]),
        ]
        let state = Deriver.derive(ops: ops)
        XCTAssertEqual(state.paragraphs["a"], "Earlier",
            "deriver applies ops in argument order; sort happens upstream")
    }
}
