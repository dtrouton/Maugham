import XCTest
import MaughamCore
@testable import MaughamPhone

/// Integration coverage for the phone annotation-review round-trip (spec §7.2):
/// a phone-written lifecycle op, read back through the SAME deriver the Mac uses,
/// resolves the annotation correctly — and the detail view's race-collapse
/// re-derive excludes an annotation another device already resolved.
final class PhoneAnnotationIntegrationTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneAnnot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private let docId = "doc-0f677d7e"

    /// A creation op as the Mac would have written it: a `claude_comment` whose
    /// change carries the paragraph anchor + prior snapshot.
    private func macComment() -> Op {
        Op(opId: "01HQ8K2M9N4P5R6S8T0V2W3X4Y", docId: docId,
           at: Date(timeIntervalSince1970: 1_000), device: "mac", session: "s",
           kind: .claudeComment,
           changes: [Op.ParagraphChange(paragraphId: "k7m3", prior: "The sun set.", next: "")],
           provenance: Op.Provenance(sessionId: "s", annotationBody: "tighten this"))
    }

    /// PhoneOpAppendIntegrationTests: the phone rejects an annotation; reloading
    /// the merged op log (Mac creation + phone reject) and re-deriving classifies
    /// it `.rejected` with the writer's user response — proving the phone's op is
    /// readable and correctly resolved by the shared deriver.
    @MainActor
    func test_phoneReject_readsBackAsRejectedWithUserResponse() async throws {
        // Seed the Mac's per-device op-log file with the creation op.
        let opsDir = tmp.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(at: opsDir, withIntermediateDirectories: true)
        let macStore = JSONLAppendStore<Op>(
            fileURL: opsDir.appendingPathComponent("\(docId).mac.jsonl"))
        try await macStore.append(macComment())

        // The phone derives the open annotation and rejects it.
        let opsBefore = try await OpLogStore(projectURL: tmp).load(docId: docId)
        let annotation = try XCTUnwrap(AnnotationLoading.openAnnotations(ops: opsBefore).first)
        XCTAssertEqual(annotation.status, .open)

        let writer = AnnotationWriter(
            projectRoot: tmp, docId: docId, deviceId: "phone:TEST",
            appVersion: "0.1.0", osVersion: "iOS 17.4")
        try await writer.reject(annotation, reason: "Works as-is.")

        // Reload the MERGED stream (mac + phone files) and re-derive.
        let opsAfter = try await OpLogStore(projectURL: tmp).load(docId: docId)
        let paragraphs = Deriver.derive(ops: opsAfter).paragraphs
        let derived = AnnotationDeriver.derive(ops: opsAfter, paragraphs: paragraphs)
        let resolved = try XCTUnwrap(derived.first { $0.id == annotation.id })

        XCTAssertEqual(resolved.status, .rejected)
        XCTAssertEqual(resolved.userResponse, "Works as-is.")
        // The phone's reject op landed in its OWN per-device file.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: opsDir.appendingPathComponent(
                "\(docId).\(DeviceSlug.make(from: "phone:TEST").raw).jsonl").path))
    }

    /// Task 8 (annotation-undo-suggestion-grain, schema v2): `claudeAcceptRevert`
    /// is authored ONLY by the Mac (⌘Z / rewind) — the phone never writes it, so
    /// the load-bearing direction is "Mac writes revert op → phone reads it."
    /// This seeds a Mac-authored bootstrap + suggestion + accept + accept-revert
    /// into the per-device `.jsonl` file as real encoded bytes (the cross-device
    /// path, not in-memory structs), reloads through the SAME
    /// `OpLogStore`/`Deriver`/`AnnotationDeriver` chain
    /// `AnnotationLoading.allAnnotations` (and `AnnotationsListView`) use, and
    /// asserts the pre-accept paragraph text is restored and the annotation
    /// reopens. Mirrors `AcceptRevertOpTests.test_acceptThenRevert_derivesOpen`
    /// (MaughamCoreTests) but through the JSONL-encode/decode boundary.
    @MainActor
    func test_macAcceptRevertWithChanges_phoneReadsBack_restoresTextAndReopens() async throws {
        let opsDir = tmp.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(at: opsDir, withIntermediateDirectories: true)
        let macStore = JSONLAppendStore<Op>(
            fileURL: opsDir.appendingPathComponent("\(docId).mac.jsonl"))

        let bootstrap = Op(
            opId: "01AAAAAAAAAAAAAAAAAAAAAAAAA", docId: docId,
            at: Date(timeIntervalSince1970: 900), device: "mac", session: "s0",
            kind: .bootstrap,
            changes: [Op.ParagraphChange(paragraphId: "k7m3", prior: nil, next: "The sun set.")],
            sequence: ["k7m3"])
        let suggestion = Op(
            opId: "01BBBBBBBBBBBBBBBBBBBBBBBBB", docId: docId,
            at: Date(timeIntervalSince1970: 1_000), device: "mac", session: "s1",
            kind: .claudeSuggestion,
            changes: [Op.ParagraphChange(paragraphId: "k7m3", prior: "The sun set.", next: "The sun bled out.")],
            provenance: Op.Provenance(sessionId: "s1", annotationBody: "stronger image"))
        let accept = Op(
            opId: "01CCCCCCCCCCCCCCCCCCCCCCCCC", docId: docId,
            at: Date(timeIntervalSince1970: 1_100), device: "mac", session: "s1",
            kind: .claudeAccept,
            changes: [Op.ParagraphChange(paragraphId: "k7m3", prior: "The sun set.", next: "The sun bled out.")],
            provenance: Op.Provenance(
                sessionId: "s1", sourceAnnotationId: suggestion.opId, userResponse: "looks good"))
        // The Mac ⌘Z path: the revert carries the inverse ParagraphChange.
        let revert = Op(
            opId: "01DDDDDDDDDDDDDDDDDDDDDDDDD", docId: docId,
            at: Date(timeIntervalSince1970: 1_200), device: "mac", session: "s1",
            kind: .claudeAcceptRevert,
            changes: [Op.ParagraphChange(paragraphId: "k7m3", prior: "The sun bled out.", next: "The sun set.")],
            provenance: Op.Provenance(sessionId: "s1", sourceAnnotationId: suggestion.opId))

        for op in [bootstrap, suggestion, accept, revert] {
            try await macStore.append(op)
        }

        // Reload through the phone's real read path (OpLogStore → Deriver →
        // AnnotationDeriver, exactly as AnnotationLoading.allAnnotations does).
        let ops = try await OpLogStore(projectURL: tmp).load(docId: docId)
        let paragraphs = Deriver.derive(ops: ops).paragraphs
        XCTAssertEqual(paragraphs["k7m3"], "The sun set.",
                       "the revert's changes must restore the pre-accept paragraph text")

        let annotations = AnnotationLoading.allAnnotations(ops: ops)
        let reopened = try XCTUnwrap(annotations.first { $0.id == suggestion.opId })
        XCTAssertEqual(reopened.status, .open, "accept-revert reopens the annotation")
        XCTAssertNil(reopened.resolvedAt)
        XCTAssertNil(reopened.userResponse, "revert clears the prior accept's user response")
    }

    /// The rewind-path variant of `claudeAcceptRevert`: EMPTY `changes` (the
    /// checkpoint restore already reverted the text; a second text-apply would
    /// fight it — see `OpKind.claudeAcceptRevert`'s doc comment). Still a
    /// manuscript no-op on the phone read path too, but still reopens the
    /// annotation — the phone must not mistake "no changes" for "no-op lifecycle
    /// event."
    @MainActor
    func test_macAcceptRevertChangesFree_phoneReadsBack_reopensAsManuscriptNoOp() async throws {
        let opsDir = tmp.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(at: opsDir, withIntermediateDirectories: true)
        let macStore = JSONLAppendStore<Op>(
            fileURL: opsDir.appendingPathComponent("\(docId).mac.jsonl"))

        let bootstrap = Op(
            opId: "01AAAAAAAAAAAAAAAAAAAAAAAAA", docId: docId,
            at: Date(timeIntervalSince1970: 900), device: "mac", session: "s0",
            kind: .bootstrap,
            changes: [Op.ParagraphChange(paragraphId: "k7m3", prior: nil, next: "The sun set.")],
            sequence: ["k7m3"])
        let suggestion = Op(
            opId: "01BBBBBBBBBBBBBBBBBBBBBBBBB", docId: docId,
            at: Date(timeIntervalSince1970: 1_000), device: "mac", session: "s1",
            kind: .claudeSuggestion,
            changes: [Op.ParagraphChange(paragraphId: "k7m3", prior: "The sun set.", next: "The sun bled out.")],
            provenance: Op.Provenance(sessionId: "s1", annotationBody: "stronger image"))
        let accept = Op(
            opId: "01CCCCCCCCCCCCCCCCCCCCCCCCC", docId: docId,
            at: Date(timeIntervalSince1970: 1_100), device: "mac", session: "s1",
            kind: .claudeAccept,
            changes: [Op.ParagraphChange(paragraphId: "k7m3", prior: "The sun set.", next: "The sun bled out.")],
            provenance: Op.Provenance(sessionId: "s1", sourceAnnotationId: suggestion.opId))
        // Rewind already restored the manuscript via a separate checkpoint_restore
        // op (not modeled here — only the revert op's OWN contribution matters for
        // this assertion); the revert itself carries no changes.
        let revert = Op(
            opId: "01DDDDDDDDDDDDDDDDDDDDDDDDD", docId: docId,
            at: Date(timeIntervalSince1970: 1_200), device: "mac", session: "s1",
            kind: .claudeAcceptRevert, changes: [],
            provenance: Op.Provenance(sessionId: "s1", sourceAnnotationId: suggestion.opId))

        for op in [bootstrap, suggestion, accept, revert] {
            try await macStore.append(op)
        }

        let ops = try await OpLogStore(projectURL: tmp).load(docId: docId)
        let paragraphs = Deriver.derive(ops: ops).paragraphs
        XCTAssertEqual(paragraphs["k7m3"], "The sun bled out.",
                       "a changes-free revert does not itself touch manuscript text — the rewind's own checkpoint_restore is what does that")

        let annotations = AnnotationLoading.allAnnotations(ops: ops)
        let reopened = try XCTUnwrap(annotations.first { $0.id == suggestion.opId })
        XCTAssertEqual(reopened.status, .open, "accept-revert reopens the annotation even changes-free")
        XCTAssertNil(reopened.resolvedAt)
    }

    /// Task 9 (unified-undo): the OTHER direction of the reopen round-trip —
    /// `PhoneAnnotationReopenTests` proves the phone WRITES a readable reopen;
    /// this proves the phone READS a Mac-authored one. A Mac-shaped
    /// `annotation_reopen` op (⌘Z on the Annotations pane, written by
    /// `Document.reopenAnnotation` via the SAME shared `AnnotationInverse`
    /// factory the phone's `AnnotationWriter.makeReopen` calls — tripwire 19)
    /// lands in the Mac's own per-device stream file, encoded as real JSONL
    /// bytes. Reloading through the phone's read path (`OpLogStore.load` →
    /// `Deriver.derive` → `AnnotationDeriver.derive`, exactly what
    /// `AnnotationDetailView`'s `rederive()` and `AnnotationLoading` use) must
    /// resolve the annotation back to `.open` — the Mac's reopen op carries no
    /// forensic `appVersion`/`osVersion` (those fields are phone-only,
    /// `Document.reopenAnnotation` never populates them), so this also proves
    /// the phone's derive path tolerates a reopen op with nil forensic fields.
    @MainActor
    func test_macReopen_phoneReadsBack_derivesOpen() async throws {
        let opsDir = tmp.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(at: opsDir, withIntermediateDirectories: true)
        let macStore = JSONLAppendStore<Op>(
            fileURL: opsDir.appendingPathComponent("\(docId).mac.jsonl"))

        let creation = macComment()
        let archive = Op(
            opId: "01HQR9F8K2P7N3DJ8WMVQXY5T0", docId: docId,
            at: Date(timeIntervalSince1970: 1_100), device: "mac", session: "s2",
            kind: .claudeArchive, changes: [],
            provenance: Op.Provenance(sessionId: "s2", sourceAnnotationId: creation.opId))
        // Mac ⌘Z: Document.reopenAnnotation → AnnotationInverse.reopenOp,
        // device "mac", no appVersion/osVersion (Mac writes leave them nil).
        let reopen = Op(
            opId: "01HQR9F8K2P7N3DJ8WMVQXY5T1", docId: docId,
            at: Date(timeIntervalSince1970: 1_200), device: "mac", session: "s3",
            kind: .annotationReopen, changes: [],
            provenance: Op.Provenance(sessionId: "s3", sourceAnnotationId: creation.opId))

        for op in [creation, archive, reopen] { try await macStore.append(op) }

        let ops = try await OpLogStore(projectURL: tmp).load(docId: docId)
        let paragraphs = Deriver.derive(ops: ops).paragraphs
        let derived = AnnotationDeriver.derive(ops: ops, paragraphs: paragraphs)
        let resolved = try XCTUnwrap(derived.first { $0.id == creation.opId })

        XCTAssertEqual(resolved.status, .open,
                       "a Mac-authored reopen op must derive .open on the phone's read path too")
        XCTAssertNil(resolved.resolvedAt)
        XCTAssertNil(resolved.userResponse, "reopen clears the prior archive's (absent) user response")
        // Landed in the Mac's own per-device file, not a synthesized phone one.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: opsDir.appendingPathComponent("\(docId).mac.jsonl").path))
    }

    /// AnnotationDetailRaceTests (core): an annotation archived on another device
    /// is excluded from the open set — so the detail view's `.onAppear` re-derive
    /// finds it not-open and shows "Already resolved on another device."
    func test_raceCollapse_resolvedElsewhere_dropsFromOpen() {
        let creation = macComment()
        // The Mac archived it while the phone still showed it as open.
        let archive = Op(
            opId: "01HQR9F8K2P7N3DJ8WMVQXY5T0", docId: docId,
            at: Date(timeIntervalSince1970: 2_000), device: "mac", session: "s2",
            kind: .claudeArchive, changes: [],
            provenance: Op.Provenance(sessionId: "s2", sourceAnnotationId: creation.opId))

        // The re-derive helper the detail view uses no longer lists it as open.
        XCTAssertTrue(AnnotationLoading.openAnnotations(ops: [creation, archive]).isEmpty)

        // And the full derivation classifies it archived (what the detail shows).
        let paragraphs = Deriver.derive(ops: [creation, archive]).paragraphs
        let all = AnnotationDeriver.derive(ops: [creation, archive], paragraphs: paragraphs)
        XCTAssertEqual(all.first?.status, .archived)
    }
}
