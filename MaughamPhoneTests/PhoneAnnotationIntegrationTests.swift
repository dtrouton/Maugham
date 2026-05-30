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

    private let docId = "d_01HQ7T3JKM2N4P5R6S8VWX0Y2Z"

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
                "\(docId).\(DeviceSlug.make(from: "phone:TEST")).jsonl").path))
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
