import XCTest
@testable import MaughamCore

/// M3 P2 Task 6 — the ops→annotations pair both surfaces derive through
/// (tripwire 19). The phone had the only copy (`AnnotationLoading`); the Mac's
/// project-wide walk needs the same derivation, so it lives here and the phone
/// delegates.
///
/// Paragraph ids are 4-char and drawn from `ParagraphID`'s alphabet (tripwire 8).
final class AnnotationAggregationTests: XCTestCase {

    // MARK: - Fixtures

    private func bootstrapOp(pid: String, text: String) -> Op {
        Op(opId: "01AAA0", docId: "doc-1", at: Date(timeIntervalSince1970: 1),
           device: "mac", session: "s1",
           kind: .bootstrap,
           changes: [.init(paragraphId: pid, prior: nil, next: text)],
           sequence: [pid])
    }

    private func commentOp(opId: String, pid: String, body: String) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 2),
           device: "mac", session: "s1",
           kind: .claudeComment,
           changes: [.init(paragraphId: pid, prior: nil, next: "")],
           provenance: Op.Provenance(sessionId: "s1", annotationBody: body))
    }

    private func lifecycleOp(opId: String, kind: OpKind, source: String) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 3),
           device: "mac", session: "s1",
           kind: kind, changes: [],
           provenance: Op.Provenance(sessionId: "s1", sourceAnnotationId: source))
    }

    /// A stream with one open note, one accepted note, one stetted note and
    /// one withdrawn note over a single bootstrapped paragraph.
    private func mixedOps() -> [Op] {
        [
            bootstrapOp(pid: "ab12", text: "Source."),
            commentOp(opId: "01BBB1", pid: "ab12", body: "still open"),
            commentOp(opId: "01BBB2", pid: "ab12", body: "will be accepted"),
            commentOp(opId: "01BBB3", pid: "ab12", body: "will be stetted"),
            commentOp(opId: "01BBB4", pid: "ab12", body: "will be withdrawn"),
            lifecycleOp(opId: "01CCC1", kind: .claudeAccept, source: "01BBB2"),
            lifecycleOp(opId: "01CCC2", kind: .annotationStet, source: "01BBB3"),
            lifecycleOp(opId: "01CCC3", kind: .annotationWithdraw, source: "01BBB4"),
        ]
    }

    // MARK: - Control

    /// CONTROL: the deriver this enum wraps, called directly. A green file
    /// where this fails would mean the fixture, not the lift, is what broke.
    func test_control_theUnderlyingDeriverSeesTheNotes() {
        let paragraphs = Deriver.derive(ops: mixedOps()).paragraphs
        let direct = AnnotationDeriver.derive(ops: mixedOps(), paragraphs: paragraphs)
        XCTAssertEqual(direct.count, 3, "withdrawn notes are absent from the projection")
    }

    // MARK: - allAnnotations

    func test_allAnnotationsCarriesEveryUnwithdrawnStatus() {
        let all = AnnotationAggregation.allAnnotations(ops: mixedOps())
        XCTAssertEqual(Set(all.map(\.status)), [.open, .accepted, .stetted])
        XCTAssertFalse(all.contains { $0.body == "will be withdrawn" },
                       "a withdrawn note is not in the projection at all")
    }

    func test_allAnnotationsResolvesBodiesAgainstDerivedParagraphs() {
        let all = AnnotationAggregation.allAnnotations(ops: mixedOps())
        let open = all.first { $0.status == .open }
        XCTAssertEqual(open?.body, "still open")
        XCTAssertEqual(open?.paragraphId, "ab12")
        XCTAssertFalse(open?.isStale ?? true,
                       "the paragraph still exists, so the note is not stale")
    }

    func test_allAnnotationsOverAnEmptyStreamIsEmpty() {
        XCTAssertTrue(AnnotationAggregation.allAnnotations(ops: []).isEmpty)
    }

    // MARK: - openAnnotations

    func test_openAnnotationsIsTheOpenSubsetOfAll() {
        let open = AnnotationAggregation.openAnnotations(ops: mixedOps())
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.body, "still open")
        XCTAssertTrue(open.allSatisfy { $0.status == .open })
    }

    /// A stet resolves — it must not read as open. This is the M3 P2 case the
    /// pre-stet copy of this filter could not have got wrong.
    func test_aStettedNoteIsNotOpen() {
        let open = AnnotationAggregation.openAnnotations(ops: mixedOps())
        XCTAssertFalse(open.contains { $0.body == "will be stetted" })
    }

    // MARK: - The paragraphs-taking overload

    /// The Mac's project walk already derives paragraphs (it needs the
    /// sequence too), so it calls the overload rather than deriving twice.
    /// Both spellings must agree.
    func test_theParagraphsOverloadAgreesWithTheDerivingOne() {
        let ops = mixedOps()
        let paragraphs = Deriver.deriveWithSequenceFallback(ops: ops).paragraphs
        XCTAssertEqual(
            AnnotationAggregation.allAnnotations(ops: ops, paragraphs: paragraphs),
            AnnotationAggregation.allAnnotations(ops: ops))
    }
}
