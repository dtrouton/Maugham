import XCTest
import MaughamCore
@testable import Maugham

/// Pins the cross-surface write rule: a `claudeAccept` op materializes the
/// proposed text into the manuscript; a `claudeSuggestion` alone does NOT.
///
/// This is the load-bearing accept contract — the phone writes `claudeAccept`
/// lifecycle ops and the Mac's shared `Deriver` must apply them. Modeled on
/// `MaughamPhoneTests/AnnotationWriterTests.test_makeAccept_suggestedChange_copiesChangeVerbatim_andMaterializes`.
final class DeriverAcceptContractTests: XCTestCase {

    private let docId = "d_01HQ7T3JKM2N4P5R6S8VWX0Y2Z"

    // MARK: - Helpers

    private func makeOp(
        opId: String, kind: OpKind,
        changes: [Op.ParagraphChange],
        sequence: [String]? = nil,
        provenance: Op.Provenance? = nil
    ) -> Op {
        Op(opId: opId, docId: docId,
           at: Date(timeIntervalSince1970: 1_699_000_000),
           device: "mac", session: "s",
           kind: kind, changes: changes,
           sequence: sequence, provenance: provenance)
    }

    // MARK: - 1. Suggestion does NOT materialize

    /// A `claudeSuggestion` carrying a ParagraphChange MUST NOT overwrite the
    /// live paragraph — it is a proposal, not a commit.
    func test_suggestion_doesNotMaterializeChange() {
        let base = makeOp(
            opId: "op-base", kind: .typingBurst,
            changes: [.init(paragraphId: "k7m3", prior: nil,
                            next: "The sun was setting.")],
            sequence: ["k7m3"])

        let suggestion = makeOp(
            opId: "op-suggest", kind: .claudeSuggestion,
            changes: [.init(paragraphId: "k7m3",
                            prior: "The sun was setting.",
                            next: "The sun bled into the horizon.")],
            provenance: .init(sessionId: "s", annotationBody: "stronger image"))

        let state = Deriver.derive(ops: [base, suggestion])

        XCTAssertEqual(
            state.paragraphs["k7m3"], "The sun was setting.",
            "claudeSuggestion must not overwrite the live paragraph — it is a proposal")
        XCTAssertNotEqual(
            state.paragraphs["k7m3"], "The sun bled into the horizon.",
            "the proposed text must remain unapplied until a claudeAccept follows")
    }

    // MARK: - 2. Accept DOES materialize

    /// A `claudeAccept` carrying the same ParagraphChange MUST apply `next` to
    /// the manuscript. This is what the Mac's Deriver honors when the phone writes
    /// an accept op.
    func test_accept_materializesChange() {
        let base = makeOp(
            opId: "op-base", kind: .typingBurst,
            changes: [.init(paragraphId: "k7m3", prior: nil,
                            next: "The sun was setting.")],
            sequence: ["k7m3"])

        let suggestion = makeOp(
            opId: "op-suggest", kind: .claudeSuggestion,
            changes: [.init(paragraphId: "k7m3",
                            prior: "The sun was setting.",
                            next: "The sun bled into the horizon.")],
            provenance: .init(sessionId: "s", annotationBody: "stronger image"))

        let accept = makeOp(
            opId: "op-accept", kind: .claudeAccept,
            changes: [.init(paragraphId: "k7m3",
                            prior: "The sun was setting.",
                            next: "The sun bled into the horizon.")],
            provenance: .init(sessionId: "s",
                              sourceAnnotationId: "op-suggest"))

        let state = Deriver.derive(ops: [base, suggestion, accept])

        XCTAssertEqual(
            state.paragraphs["k7m3"], "The sun bled into the horizon.",
            "claudeAccept must apply the proposed text to the manuscript")
    }

    // MARK: - 3. Accept without prior suggestion still materializes

    /// The accept contract does not require the suggestion op to be present in
    /// the same stream — on a phone-written accept replayed on the Mac the
    /// suggestion may land in a different per-device file after merging. The
    /// accept op ALONE must be sufficient to materialize.
    func test_accept_withoutSuggestionInStream_stillMaterializes() {
        let base = makeOp(
            opId: "op-base", kind: .typingBurst,
            changes: [.init(paragraphId: "k7m3", prior: nil,
                            next: "The sun was setting.")],
            sequence: ["k7m3"])

        let accept = makeOp(
            opId: "op-accept", kind: .claudeAccept,
            changes: [.init(paragraphId: "k7m3",
                            prior: "The sun was setting.",
                            next: "The sun bled into the horizon.")],
            provenance: .init(sessionId: "s",
                              sourceAnnotationId: "op-suggest"))

        let state = Deriver.derive(ops: [base, accept])

        XCTAssertEqual(
            state.paragraphs["k7m3"], "The sun bled into the horizon.",
            "claudeAccept must materialize even without the suggestion in the same stream")
    }

    // MARK: - 4. Reject and archive do NOT materialize

    /// `claudeReject` and `claudeArchive` are lifecycle ops that carry empty
    /// changes and must never mutate the manuscript.
    func test_reject_doesNotMaterialize() {
        let base = makeOp(
            opId: "op-base", kind: .typingBurst,
            changes: [.init(paragraphId: "k7m3", prior: nil,
                            next: "The sun was setting.")],
            sequence: ["k7m3"])

        let reject = makeOp(
            opId: "op-reject", kind: .claudeReject,
            changes: [],
            provenance: .init(sessionId: "s", sourceAnnotationId: "op-suggest",
                              userResponse: "Works as-is."))

        let state = Deriver.derive(ops: [base, reject])

        XCTAssertEqual(
            state.paragraphs["k7m3"], "The sun was setting.",
            "claudeReject must not touch the manuscript")
    }

    func test_archive_doesNotMaterialize() {
        let base = makeOp(
            opId: "op-base", kind: .typingBurst,
            changes: [.init(paragraphId: "k7m3", prior: nil,
                            next: "The sun was setting.")],
            sequence: ["k7m3"])

        let archive = makeOp(
            opId: "op-archive", kind: .claudeArchive,
            changes: [],
            provenance: .init(sessionId: "s", sourceAnnotationId: "op-comment"))

        let state = Deriver.derive(ops: [base, archive])

        XCTAssertEqual(
            state.paragraphs["k7m3"], "The sun was setting.",
            "claudeArchive must not touch the manuscript")
    }
}
