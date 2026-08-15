import XCTest
@testable import MaughamCore

/// M3 P2 Task 1 — the wire and the projection: `annotation_stet` (a lifecycle
/// resolution: "leave it as it stands"), `annotation_triage` (a MARK on an
/// open note, deliberately not a resolution), and the review-pass stamp a
/// creation op carries.
///
/// Paragraph ids here are 4-char and drawn from `ParagraphID`'s alphabet
/// (tripwire 8) so a test that later crosses the `.md` ↔ op-log boundary
/// cannot be rejected by `ParagraphID.parseComment`.
final class AnnotationTriageStetDerivationTests: XCTestCase {

    // MARK: - Fixtures

    private func commentOp(
        opId: String, pid: String = "ab12",
        body: String = "undersells her",
        reviewPassId: String? = nil
    ) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 1),
           device: "mac", session: "s1",
           kind: .claudeComment,
           changes: [.init(paragraphId: pid, prior: "Source.", next: "")],
           provenance: Op.Provenance(
               sessionId: "s1",
               annotationBody: body,
               reviewPassId: reviewPassId))
    }

    private func lifecycleOp(opId: String, kind: OpKind, source: String,
                             userResponse: String? = nil) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 2),
           device: "mac", session: "s1",
           kind: kind, changes: [],
           provenance: Op.Provenance(
               sessionId: "s1",
               sourceAnnotationId: source,
               userResponse: userResponse))
    }

    private func triageOp(opId: String, source: String, rawMark: String?) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 3),
           device: "mac", session: "s1",
           kind: .annotationTriage, changes: [],
           provenance: Op.Provenance(
               sessionId: "s1",
               sourceAnnotationId: source,
               triageMark: rawMark))
    }

    private func derive(_ ops: [Op]) -> [Annotation] {
        AnnotationDeriver.derive(ops: ops, paragraphs: ["ab12": "Source."])
    }

    // MARK: - Control

    /// CONTROL: a fact independent of everything this task implements, so a
    /// green run of this file cannot mean "the file never compiled in".
    func test_control_aPlainCommentDerivesOpen() {
        let a = derive([commentOp(opId: "01AAAA")]).first
        XCTAssertEqual(a?.status, .open)
    }

    // MARK: - Stet: a lifecycle resolution

    func test_stetIsALifecycleKind() {
        XCTAssertTrue(AnnotationDeriver.isLifecycleKind(.annotationStet))
    }

    func test_aStetOpResolvesTheNoteToStetted() {
        let creation = commentOp(opId: "01AAAA")
        let stet = lifecycleOp(opId: "01BBBB", kind: .annotationStet,
                               source: "01AAAA", userResponse: "it stands")
        let a = try? XCTUnwrap(derive([creation, stet]).first)
        XCTAssertEqual(a?.status, .stetted)
        XCTAssertEqual(a?.userResponse, "it stands")
        XCTAssertNotNil(a?.resolvedAt, "a resolution stamps when it happened")
    }

    func test_aLaterReopenBeatsAStet_latestByOpIdWins() {
        let creation = commentOp(opId: "01AAAA")
        let stet = lifecycleOp(opId: "01BBBB", kind: .annotationStet, source: "01AAAA")
        let reopen = lifecycleOp(opId: "01CCCC", kind: .annotationReopen, source: "01AAAA")
        XCTAssertEqual(derive([creation, stet, reopen]).first?.status, .open)
        // …and the other direction: a stet appended after a reopen wins.
        let laterStet = lifecycleOp(opId: "01DDDD", kind: .annotationStet, source: "01AAAA")
        XCTAssertEqual(derive([creation, stet, reopen, laterStet]).first?.status, .stetted)
    }

    // MARK: - Triage: a mark, not a resolution

    func test_triageIsNotALifecycleKind() {
        XCTAssertFalse(AnnotationDeriver.isLifecycleKind(.annotationTriage),
            "a triaged note is still an open note — triage sorts the queue, it does not settle it")
    }

    func test_aTriagedNoteStaysOpenAndCarriesItsMark() {
        let creation = commentOp(opId: "01AAAA")
        let triage = triageOp(opId: "01BBBB", source: "01AAAA", rawMark: "do")
        let a = derive([creation, triage]).first
        XCTAssertEqual(a?.status, .open)
        XCTAssertEqual(a?.triage, .do)
    }

    func test_theLatestTriageOpWins() {
        let creation = commentOp(opId: "01AAAA")
        let first = triageOp(opId: "01BBBB", source: "01AAAA", rawMark: "do")
        let second = triageOp(opId: "01CCCC", source: "01AAAA", rawMark: "discuss")
        XCTAssertEqual(derive([creation, first, second]).first?.triage, .discuss)
        // Order in the array must not matter — latest is by opId, not position.
        XCTAssertEqual(derive([creation, second, first]).first?.triage, .discuss)
    }

    func test_aTriageOpWithNoMarkDerivesBackToUntriaged() {
        let creation = commentOp(opId: "01AAAA")
        let marked = triageOp(opId: "01BBBB", source: "01AAAA", rawMark: "decline")
        let cleared = triageOp(opId: "01CCCC", source: "01AAAA", rawMark: nil)
        XCTAssertEqual(derive([creation, marked]).first?.triage, .decline)
        XCTAssertNil(derive([creation, marked, cleared]).first?.triage)
    }

    func test_anUnrecognisedRawMarkDerivesNil() {
        let creation = commentOp(opId: "01AAAA")
        let alien = triageOp(opId: "01BBBB", source: "01AAAA", rawMark: "escalate_to_editor")
        XCTAssertNil(derive([creation, alien]).first?.triage,
            "the mark is a projection, never re-encoded — parse-or-nil, no `.unknown` case")
    }

    func test_anUntouchedNoteHasNoMark() {
        XCTAssertNil(derive([commentOp(opId: "01AAAA")]).first?.triage)
    }

    func test_everyTriageMarkRawValueIsOnTheWire() {
        XCTAssertEqual(TriageMark.allCases.map(\.rawValue), ["do", "decline", "discuss"])
    }

    // MARK: - The review-pass stamp

    func test_aCreationOpCarryingAPassIdSurfacesIt() {
        let a = derive([commentOp(opId: "01AAAA", reviewPassId: "line")]).first
        XCTAssertEqual(a?.reviewPassId, "line")
    }

    func test_aCreationOpWithoutAPassIdDerivesNil() {
        XCTAssertNil(derive([commentOp(opId: "01AAAA")]).first?.reviewPassId)
    }

    // MARK: - Wire tolerance

    /// A hand-written op-log line from before this milestone — no
    /// `review_pass_id`, no `triage_mark` — still decodes, with both nil.
    func test_aLegacyProvenanceLineDecodesWithBothNewFieldsNil() throws {
        let legacy = Data(#"{"annotation_body":"hi","source_annotation_id":"01AAAA"}"#.utf8)
        let decoded = try JSONDecoder().decode(Op.Provenance.self, from: legacy)
        XCTAssertNil(decoded.triageMark)
        XCTAssertNil(decoded.reviewPassId)
        XCTAssertEqual(decoded.annotationBody, "hi")
    }

    /// The two new fields go on the wire under their snake_case keys and
    /// survive a re-encode byte-identically.
    func test_theNewProvenanceFieldsRoundTripByteStable() throws {
        let op = Op(
            opId: "01AAAA", docId: "doc-1", at: Date(timeIntervalSince1970: 1),
            device: "mac", session: "s1", kind: .annotationTriage, changes: [],
            provenance: Op.Provenance(
                sessionId: "s1", sourceAnnotationId: "01ZZZZ",
                triageMark: "discuss", reviewPassId: "copyedit"))
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let first = try enc.encode(op)
        let wire = String(decoding: first, as: UTF8.self)
        XCTAssertTrue(wire.contains(#""triage_mark":"discuss""#), wire)
        XCTAssertTrue(wire.contains(#""review_pass_id":"copyedit""#), wire)

        let back = try JSONDecoder().decode(Op.self, from: first)
        XCTAssertEqual(back.provenance?.triageMark, "discuss")
        XCTAssertEqual(back.provenance?.reviewPassId, "copyedit")
        XCTAssertEqual(try enc.encode(back), first)
    }

    // MARK: - Neither kind touches the manuscript

    func test_neitherNewKindAppliesToTheManuscript() {
        XCTAssertFalse(Deriver.appliesToManuscript(.annotationStet))
        XCTAssertFalse(Deriver.appliesToManuscript(.annotationTriage))
    }

    func test_theNewKindsHaveTheirContractRawValues() {
        XCTAssertEqual(OpKind.annotationStet.rawValue, "annotation_stet")
        XCTAssertEqual(OpKind.annotationTriage.rawValue, "annotation_triage")
    }
}
