import XCTest
@testable import MaughamCore

/// M4 P1 Task 2 — compiler-run provenance on the wire and in the projection:
/// the four flat optional scalars a compiler-authored annotation op carries
/// (`compiler_run_id`, `compiler_round`, `compiler_fresh_eyes`,
/// `compiler_fingerprint`) and the three the deriver projects onto
/// `Annotation` (fresh eyes is wire-only — nothing reads it off a note).
///
/// Paragraph ids here are 4-char and drawn from `ParagraphID`'s alphabet
/// (tripwire 8) so a test that later crosses the `.md` ↔ op-log boundary
/// cannot be rejected by `ParagraphID.parseComment`.
final class CompilerProvenanceTests: XCTestCase {

    // MARK: - Fixtures

    private func commentOp(
        opId: String, pid: String = "ab12",
        body: String = "the pivot lands a beat early",
        compilerRunId: String? = nil,
        compilerRound: Int? = nil,
        compilerFreshEyes: Bool? = nil,
        compilerFingerprint: String? = nil
    ) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 1),
           device: "mac", session: "s1",
           kind: .claudeComment,
           changes: [.init(paragraphId: pid, prior: "Source.", next: "")],
           provenance: Op.Provenance(
               sessionId: "s1",
               annotationBody: body,
               compilerRunId: compilerRunId,
               compilerRound: compilerRound,
               compilerFreshEyes: compilerFreshEyes,
               compilerFingerprint: compilerFingerprint))
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
        XCTAssertEqual(a?.body, "the pivot lands a beat early")
    }

    // MARK: - The projection

    func test_aCreationOpFromACompilerRunSurfacesItsRunRoundAndFingerprint() {
        let a = derive([commentOp(
            opId: "01AAAA", compilerRunId: "run-7", compilerRound: 3,
            compilerFreshEyes: true, compilerFingerprint: "sha-abc")]).first
        XCTAssertEqual(a?.compilerRunId, "run-7")
        XCTAssertEqual(a?.compilerRound, 3)
        XCTAssertEqual(a?.compilerFingerprint, "sha-abc")
    }

    func test_aHandWrittenNoteProjectsAllThreeAsNil() {
        let a = derive([commentOp(opId: "01AAAA")]).first
        XCTAssertNil(a?.compilerRunId)
        XCTAssertNil(a?.compilerRound)
        XCTAssertNil(a?.compilerFingerprint)
    }

    /// Fresh eyes is a fact about the RUN, not about the note: it rides the
    /// wire so a run's ops can be read back whole, and is deliberately not
    /// projected. A stored property would invite a surface to badge notes with
    /// it, which is a claim about the note the run never made.
    func test_freshEyesIsWireOnlyAndNeverReachesTheProjection() {
        let op = commentOp(opId: "01AAAA", compilerRunId: "run-7",
                           compilerFreshEyes: true)
        XCTAssertEqual(op.provenance?.compilerFreshEyes, true)
        let a = derive([op]).first
        let labels = Mirror(reflecting: a!).children.compactMap(\.label)
        XCTAssertFalse(
            labels.contains { $0.lowercased().contains("fresheyes") },
            "Annotation grew a fresh-eyes field: \(labels)")
    }

    // MARK: - isCompilerAuthored

    func test_isCompilerAuthoredIsTrueExactlyWhenARunIdIsPresent() {
        // Truth table over the run id, which is the sole determinant: the
        // round and the fingerprint say WHICH run, never WHETHER.
        XCTAssertFalse(derive([commentOp(opId: "01AAAA")]).first!.isCompilerAuthored)
        XCTAssertTrue(derive([commentOp(opId: "01BBBB", compilerRunId: "run-1")])
            .first!.isCompilerAuthored)
        XCTAssertTrue(derive([commentOp(
            opId: "01CCCC", compilerRunId: "run-1", compilerRound: 2,
            compilerFingerprint: "sha-abc")]).first!.isCompilerAuthored)
        // Round and fingerprint without a run id is not authorship.
        XCTAssertFalse(derive([commentOp(
            opId: "01DDDD", compilerRound: 2, compilerFingerprint: "sha-abc")])
            .first!.isCompilerAuthored)
    }

    // MARK: - Wire tolerance

    /// A hand-written op-log line from before this milestone — none of the
    /// four new keys — still decodes, with all four nil. The op log is
    /// append-only, so this tolerance is the whole compatibility story: no
    /// `OpKind` case was added, hence no schema bump.
    func test_aLegacyProvenanceLineDecodesWithAllFourNewFieldsNil() throws {
        let legacy = Data(
            #"{"annotation_body":"hi","review_pass_id":"line","session_id":"s1"}"#.utf8)
        let decoded = try JSONDecoder().decode(Op.Provenance.self, from: legacy)
        XCTAssertNil(decoded.compilerRunId)
        XCTAssertNil(decoded.compilerRound)
        XCTAssertNil(decoded.compilerFreshEyes)
        XCTAssertNil(decoded.compilerFingerprint)
        XCTAssertEqual(decoded.annotationBody, "hi")
        XCTAssertEqual(decoded.reviewPassId, "line")
    }

    /// The four new fields go on the wire under their snake_case keys and
    /// survive a re-encode byte-identically.
    func test_theNewProvenanceFieldsRoundTripByteStable() throws {
        let op = commentOp(
            opId: "01AAAA", compilerRunId: "run-7", compilerRound: 3,
            compilerFreshEyes: true, compilerFingerprint: "sha-abc")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let first = try enc.encode(op)
        let wire = String(decoding: first, as: UTF8.self)
        XCTAssertTrue(wire.contains(#""compiler_run_id":"run-7""#), wire)
        XCTAssertTrue(wire.contains(#""compiler_round":3"#), wire)
        XCTAssertTrue(wire.contains(#""compiler_fresh_eyes":true"#), wire)
        XCTAssertTrue(wire.contains(#""compiler_fingerprint":"sha-abc""#), wire)

        let back = try JSONDecoder().decode(Op.self, from: first)
        XCTAssertEqual(back.provenance?.compilerRunId, "run-7")
        XCTAssertEqual(back.provenance?.compilerRound, 3)
        XCTAssertEqual(back.provenance?.compilerFreshEyes, true)
        XCTAssertEqual(back.provenance?.compilerFingerprint, "sha-abc")
        XCTAssertEqual(try enc.encode(back), first)
    }

    /// `false` is a value, not an absence: a run that explicitly was NOT fresh
    /// eyes must survive the round trip as `false` rather than collapsing to
    /// nil (which would read as "written before the field existed").
    func test_anExplicitlyFalseFreshEyesSurvivesTheRoundTrip() throws {
        let prov = Op.Provenance(compilerRunId: "run-7", compilerFreshEyes: false)
        let data = try JSONEncoder().encode(prov)
        XCTAssertTrue(String(decoding: data, as: UTF8.self)
            .contains(#""compiler_fresh_eyes":false"#))
        let back = try JSONDecoder().decode(Op.Provenance.self, from: data)
        XCTAssertEqual(back.compilerFreshEyes, false)
    }

    // MARK: - No schema bump

    /// This task adds no `OpKind` case, and `OpKind`'s SCHEMA CONTRACT scopes
    /// the bump to exactly that. Additive all-optional `Provenance` fields
    /// cannot be silently dropped by an older build, because the op log is
    /// append-only — ops are never re-saved.
    func test_theSchemaVersionDidNotMoveForThisTask() {
        XCTAssertEqual(ProjectManifest.currentSchemaVersion, 7)
    }
}
