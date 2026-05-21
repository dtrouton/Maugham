import XCTest
@testable import Maugham

final class DeriverUpToTests: XCTestCase {
    private func op(
        _ id: String, kind: OpKind = .typingBurst,
        changes: [(String, String?, String)] = [],
        sequence: [String]? = nil
    ) -> Op {
        Op(
            opId: id,
            docId: "doc-x",
            at: Date(timeIntervalSince1970: TimeInterval(id.hashValue & 0x7fffffff)),
            device: "d1", session: "s1",
            kind: kind,
            changes: changes.map { .init(paragraphId: $0.0, prior: $0.1, next: $0.2) },
            sequence: sequence,
            provenance: nil)
    }

    func test_deriveUpTo_now_returnsFullDerivation() {
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "first")], sequence: ["aabb"]),
            op("01B", changes: [("bzcc", nil, "second")], sequence: ["aabb", "bzcc"]),
        ]
        let full = Deriver.derive(ops: ops)
        let upToNow = Deriver.derive(ops: ops, upTo: .now)
        XCTAssertEqual(full, upToNow)
    }

    func test_deriveUpTo_atOp_returnsStateAtThatPoint() {
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "first")], sequence: ["aabb"]),
            op("01B", changes: [("bzcc", nil, "second")], sequence: ["aabb", "bzcc"]),
            op("01C", changes: [("dxee", nil, "third")], sequence: ["aabb", "bzcc", "dxee"]),
        ]
        let result = Deriver.derive(ops: ops, upTo: .atOp(opId: "01B", at: Date()))
        XCTAssertEqual(result.sequence, ["aabb", "bzcc"])
        XCTAssertEqual(result.paragraphs["aabb"], "first")
        XCTAssertEqual(result.paragraphs["bzcc"], "second")
        XCTAssertNil(result.paragraphs["dxee"])
    }

    func test_deriveUpTo_atOp_ignoresLaterOps() {
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "first")], sequence: ["aabb"]),
            op("01B", changes: [("bzcc", nil, "second")], sequence: ["aabb", "bzcc"]),
        ]
        let stateAtA = Deriver.derive(ops: ops, upTo: .atOp(opId: "01A", at: Date()))
        let opsTrimmed = Array(ops.prefix(1))
        let stateFromTrimmed = Deriver.derive(ops: opsTrimmed)
        XCTAssertEqual(stateAtA, stateFromTrimmed)
    }

    func test_deriveUpTo_atOp_includesAnnotationOps_butSkipsTheirChanges() {
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "para text")], sequence: ["aabb"]),
            // Annotation creation op carries a change as anchor + priorText
            // snapshot but its `.next` must NOT be applied.
            op("01B", kind: .claudeComment,
               changes: [("aabb", "para text", "")],
               sequence: ["aabb"]),
        ]
        let result = Deriver.derive(ops: ops, upTo: .atOp(opId: "01B", at: Date()))
        XCTAssertEqual(result.paragraphs["aabb"], "para text",
                       "Annotation creation must not blank the paragraph")
    }

    func test_deriveUpTo_atOp_withPriorRestore_handlesUndoChain() {
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "v1")], sequence: ["aabb"]),
            op("01B", changes: [("aabb", "v1", "v2")], sequence: ["aabb"]),
            // A prior restore that walked back to v1
            op("01C", kind: .checkpointRestore,
               changes: [("aabb", "v2", "v1")], sequence: ["aabb"]),
            op("01D", changes: [("aabb", "v1", "v3")], sequence: ["aabb"]),
        ]
        // Scrubbing to 01C should reflect v1 (the post-restore state).
        let atRestore = Deriver.derive(ops: ops, upTo: .atOp(opId: "01C", at: Date()))
        XCTAssertEqual(atRestore.paragraphs["aabb"], "v1")
        // Scrubbing to 01B should reflect v2 (pre-restore typing).
        let atV2 = Deriver.derive(ops: ops, upTo: .atOp(opId: "01B", at: Date()))
        XCTAssertEqual(atV2.paragraphs["aabb"], "v2")
    }

    func test_deriveUpTo_atOp_atBootstrap_returnsInitialState() {
        let ops: [Op] = [
            op("01A", kind: .bootstrap,
               changes: [("aabb", nil, "initial")],
               sequence: ["aabb"]),
            op("01B", changes: [("aabb", "initial", "later edit")], sequence: ["aabb"]),
        ]
        let atBootstrap = Deriver.derive(ops: ops, upTo: .atOp(opId: "01A", at: Date()))
        XCTAssertEqual(atBootstrap.paragraphs["aabb"], "initial")
        XCTAssertEqual(atBootstrap.sequence, ["aabb"])
    }

    func test_deriveUpTo_atOp_unknownId_returnsNow() {
        // Defensive: an op_id not in the stream is treated as `.now`
        // rather than throwing — useful if a stale UI cursor references
        // an op that's been merged away during a cross-Mac sync.
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "first")], sequence: ["aabb"]),
            op("01B", changes: [("bzcc", nil, "second")], sequence: ["aabb", "bzcc"]),
        ]
        let unknown = Deriver.derive(ops: ops, upTo: .atOp(opId: "01ZZZ", at: Date()))
        let full = Deriver.derive(ops: ops)
        XCTAssertEqual(unknown, full)
    }

    func test_deriveUpTo_legacyOpsWithoutSequence_synthesizesFromChanges() {
        // Legacy projects (pre-"always capture sequence on burst" fix) have
        // typing_burst ops with populated changes but no sequence field.
        // RewindWindow needs a non-empty sequence to render the preview;
        // verify the fallback synthesizes one from paragraph_id
        // first-appearance order in changes.
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "first")], sequence: nil),
            op("01B", changes: [("bzcc", nil, "second")], sequence: nil),
            op("01C", changes: [("dxee", nil, "third")], sequence: nil),
        ]
        // Default `derive(ops:)` preserves the pre-fix behaviour for
        // Document.load's recovery path (which relies on the empty
        // sequence as a signal to recover from the .md file).
        let strict = Deriver.derive(ops: ops)
        XCTAssertEqual(strict.sequence, [])
        XCTAssertEqual(strict.paragraphs.count, 3)
        // upTo path uses the fallback so the modal can render.
        let withFallback = Deriver.derive(ops: ops, upTo: .now)
        XCTAssertEqual(withFallback.sequence, ["aabb", "bzcc", "dxee"])
        XCTAssertEqual(withFallback.paragraphs["aabb"], "first")
        XCTAssertEqual(withFallback.paragraphs["dxee"], "third")
        // upTo a past op also synthesizes correctly (only paragraphs
        // touched at or before the cursor appear in the synthesized seq).
        let atB = Deriver.derive(ops: ops, upTo: .atOp(opId: "01B", at: Date()))
        XCTAssertEqual(atB.sequence, ["aabb", "bzcc"])
    }

    func test_deriveUpTo_explicitSequenceWins_overFallback() {
        // When at least one op carries an explicit sequence, that wins.
        // The synthesized fallback only activates when no op contributed
        // a sequence — otherwise the explicit sequence reflects deletions
        // and reorders that first-appearance synthesis can't see.
        let ops: [Op] = [
            op("01A", changes: [("aabb", nil, "a")], sequence: nil),
            op("01B", changes: [("bzcc", nil, "b")], sequence: ["bzcc"]),
        ]
        let result = Deriver.derive(ops: ops, upTo: .now)
        XCTAssertEqual(result.sequence, ["bzcc"],
                       "Explicit sequence must override first-appearance synthesis")
    }
}
