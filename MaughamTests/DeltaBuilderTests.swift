// MaughamTests/DeltaBuilderTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// `DeltaBuilder` answers one question for the compiler: since the last run's
/// marker, which paragraphs are new, which were revised, and what did the
/// revised ones say at the marker. Every contract below is golden — the
/// prompt the compiler builds is only as honest as this diff.
final class DeltaBuilderTests: XCTestCase {

    private func makeOp(
        opId: String,
        kind: OpKind = .typingBurst,
        changes: [Op.ParagraphChange],
        device: String = "macA"
    ) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(), device: device,
           session: "s", kind: kind, changes: changes, sequence: nil)
    }

    // MARK: - First run

    func test_firstRun_everythingIsNew() {
        let ops = [makeOp(opId: "op1", kind: .bootstrap, changes: [
            .init(paragraphId: "a1b2", prior: nil, next: "First."),
            .init(paragraphId: "c3d4", prior: nil, next: "Second."),
        ])]

        let delta = DeltaBuilder.delta(
            ops: ops, since: nil,
            currentParagraphs: ["a1b2": "First.", "c3d4": "Second."],
            sequence: ["a1b2", "c3d4"])

        XCTAssertEqual(delta.new, [
            .init(paragraphId: "a1b2", text: "First."),
            .init(paragraphId: "c3d4", text: "Second."),
        ])
        XCTAssertTrue(delta.revised.isEmpty)
    }

    // MARK: - Revision

    func test_revisedParagraph_carriesFirstSeenPrior() {
        let ops = [
            makeOp(opId: "op1", changes: [
                .init(paragraphId: "a1b2", prior: nil, next: "v1")]),
            makeOp(opId: "op2", changes: [
                .init(paragraphId: "a1b2", prior: "v1", next: "v2")]),
            makeOp(opId: "op3", changes: [
                .init(paragraphId: "a1b2", prior: "v2", next: "v3")]),
        ]

        let delta = DeltaBuilder.delta(
            ops: ops, since: "op1",
            currentParagraphs: ["a1b2": "v3"], sequence: ["a1b2"])

        // "v1" is what the paragraph said AS OF THE MARKER — not "v2", the
        // prior of the last op to touch it.
        XCTAssertEqual(delta.revised, [
            .init(paragraphId: "a1b2", prior: "v1", text: "v3")])
        XCTAssertTrue(delta.new.isEmpty)
    }

    func test_paragraphNewSinceMarker_hasNilPrior_andIsNew() {
        let ops = [
            makeOp(opId: "op1", changes: [
                .init(paragraphId: "a1b2", prior: nil, next: "Standing.")]),
            makeOp(opId: "op2", changes: [
                .init(paragraphId: "c3d4", prior: nil, next: "Born.")]),
            makeOp(opId: "op3", changes: [
                .init(paragraphId: "c3d4", prior: "Born.", next: "Grown.")]),
        ]

        let delta = DeltaBuilder.delta(
            ops: ops, since: "op1",
            currentParagraphs: ["a1b2": "Standing.", "c3d4": "Grown."],
            sequence: ["a1b2", "c3d4"])

        XCTAssertEqual(delta.new, [
            .init(paragraphId: "c3d4", text: "Grown.")])
        XCTAssertTrue(delta.revised.isEmpty,
                      "A ¶ minted since the marker is new, not revised, "
                      + "however many times it was rewritten afterwards.")
    }

    func test_editThatRestoresTheMarkerText_isNotReported() {
        let ops = [
            makeOp(opId: "op1", changes: [
                .init(paragraphId: "a1b2", prior: nil, next: "v1")]),
            makeOp(opId: "op2", changes: [
                .init(paragraphId: "a1b2", prior: "v1", next: "v2")]),
            makeOp(opId: "op3", changes: [
                .init(paragraphId: "a1b2", prior: "v2", next: "v1")]),
        ]

        let delta = DeltaBuilder.delta(
            ops: ops, since: "op1",
            currentParagraphs: ["a1b2": "v1"], sequence: ["a1b2"])

        XCTAssertTrue(delta.revised.isEmpty,
                      "Typed and untyped back is not a revision — a before/"
                      + "after with identical halves tells the compiler nothing.")
    }

    // MARK: - Absence

    func test_deletedParagraph_isOmitted() {
        let ops = [
            makeOp(opId: "op1", changes: [
                .init(paragraphId: "a1b2", prior: nil, next: "Doomed."),
                .init(paragraphId: "c3d4", prior: nil, next: "Survivor v1")]),
            makeOp(opId: "op2", changes: [
                .init(paragraphId: "a1b2", prior: "Doomed.", next: "Doomed v2")]),
            makeOp(opId: "op3", changes: [
                .init(paragraphId: "c3d4", prior: "Survivor v1",
                      next: "Survivor v2")]),
        ]

        // a1b2 was revised and then deleted: gone from both current maps.
        let delta = DeltaBuilder.delta(
            ops: ops, since: "op1",
            currentParagraphs: ["c3d4": "Survivor v2"], sequence: ["c3d4"])

        XCTAssertEqual(delta.new, [])
        XCTAssertEqual(delta.revised, [
            .init(paragraphId: "c3d4", prior: "Survivor v1",
                  text: "Survivor v2")])
    }

    func test_opsAtOrBeforeMarker_areIgnored() {
        let ops = [
            makeOp(opId: "op1", changes: [
                .init(paragraphId: "a1b2", prior: nil, next: "Settled v1")]),
            makeOp(opId: "op2", changes: [
                .init(paragraphId: "a1b2", prior: "Settled v1",
                      next: "Settled v2")]),
            makeOp(opId: "op3", changes: [
                .init(paragraphId: "c3d4", prior: nil, next: "Fresh.")]),
        ]

        // Marker IS op2 — strictly-after, so op2 itself contributes nothing.
        let delta = DeltaBuilder.delta(
            ops: ops, since: "op2",
            currentParagraphs: ["a1b2": "Settled v2", "c3d4": "Fresh."],
            sequence: ["a1b2", "c3d4"])

        XCTAssertEqual(delta.new, [.init(paragraphId: "c3d4", text: "Fresh.")])
        XCTAssertTrue(delta.revised.isEmpty)
    }

    // MARK: - Order

    func test_orderFollowsSequence_notOpArrival() {
        let ops = [
            makeOp(opId: "op1", changes: [
                .init(paragraphId: "e5f6", prior: nil, next: "Anchor.")]),
            // Arrives second in the log, stands FIRST in the manuscript.
            makeOp(opId: "op2", changes: [
                .init(paragraphId: "c3d4", prior: nil, next: "Middle.")]),
            makeOp(opId: "op3", changes: [
                .init(paragraphId: "a1b2", prior: nil, next: "Opening.")]),
        ]

        let delta = DeltaBuilder.delta(
            ops: ops, since: "op1",
            currentParagraphs: [
                "a1b2": "Opening.", "c3d4": "Middle.", "e5f6": "Anchor."],
            sequence: ["a1b2", "c3d4", "e5f6"])

        XCTAssertEqual(delta.new.map(\.paragraphId), ["a1b2", "c3d4"])
    }

    // MARK: - The marker

    func test_newestOpId_advancesToTheLastOpSeen() {
        let ops = [
            makeOp(opId: "op1", changes: [
                .init(paragraphId: "a1b2", prior: nil, next: "v1")]),
            makeOp(opId: "op3", changes: [
                .init(paragraphId: "a1b2", prior: "v2", next: "v3")]),
            makeOp(opId: "op2", changes: [
                .init(paragraphId: "a1b2", prior: "v1", next: "v2")]),
        ]

        let delta = DeltaBuilder.delta(
            ops: ops, since: "op1",
            currentParagraphs: ["a1b2": "v3"], sequence: ["a1b2"])

        XCTAssertEqual(delta.newestOpId, "op3",
                       "The marker advances by opId order, not arrival order.")
    }

    func test_noOpsAfterMarker_isEmpty_andKeepsNilNewestOpId() {
        let ops = [
            makeOp(opId: "op1", changes: [
                .init(paragraphId: "a1b2", prior: nil, next: "v1")]),
            makeOp(opId: "op2", changes: [
                .init(paragraphId: "a1b2", prior: "v1", next: "v2")]),
        ]

        let delta = DeltaBuilder.delta(
            ops: ops, since: "op2",
            currentParagraphs: ["a1b2": "v2"], sequence: ["a1b2"])

        XCTAssertTrue(delta.isEmpty)
        XCTAssertNil(delta.newestOpId)
    }

    // MARK: - Ops that carry no manuscript text

    func test_nonTextOps_produceNoDeltaEntries() {
        let ops = [
            makeOp(opId: "op1", changes: [
                .init(paragraphId: "a1b2", prior: nil, next: "Untouched.")]),
            makeOp(opId: "op2", kind: .taskCreate, changes: []),
            makeOp(opId: "op3", kind: .checkpoint, changes: []),
        ]

        let delta = DeltaBuilder.delta(
            ops: ops, since: "op1",
            currentParagraphs: ["a1b2": "Untouched."], sequence: ["a1b2"])

        XCTAssertTrue(delta.isEmpty)
        XCTAssertEqual(delta.newestOpId, "op3",
                       "The marker is a LOG position: it advances past ops "
                       + "that changed no prose, so they are not re-read.")
    }

    func test_annotationAnchorIsNotReadAsARevision() {
        // Cross-device (ADR 0012): device A's edit landed BEFORE the marker;
        // device B then commented against its stale view of the paragraph, so
        // the comment's anchor snapshot disagrees with the live text. The
        // anchor is not an edit and must not be diffed as one.
        let ops = [
            makeOp(opId: "op1", changes: [
                .init(paragraphId: "a1b2", prior: "v1", next: "v2")]),
            makeOp(opId: "op2", kind: .claudeComment, changes: [
                .init(paragraphId: "a1b2", prior: "v1", next: "")],
                   device: "macB"),
        ]

        let delta = DeltaBuilder.delta(
            ops: ops, since: "op1",
            currentParagraphs: ["a1b2": "v2"], sequence: ["a1b2"])

        XCTAssertTrue(delta.revised.isEmpty)
        XCTAssertTrue(delta.new.isEmpty)
    }
}
