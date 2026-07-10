// MaughamTests/OpLog/CrossSurfaceReopenRoundTripTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// Task 9 (unified-undo): the Mac-side leg of the reopen cross-surface
/// round-trip. `PhoneAnnotationIntegrationTests.test_macReopen_phoneReadsBack_derivesOpen`
/// (MaughamPhoneTests) covers "Mac writes reopen → phone derives `.open`";
/// this covers the opposite direction — "phone writes reopen → Mac derives
/// `.open`" — through the real `Document.load` path (not a bare
/// `AnnotationDeriver.derive` unit call), mirroring `CrossDeviceIntegrationTests`'
/// seeding style (real `OpLogStore`/`JSONLAppendStore<Op>` bytes on disk, per
/// tripwire 19: the phone's `annotation_reopen` op is consumed by the SAME
/// shared `AnnotationInverse`-classified `AnnotationDeriver.derive` the Mac's
/// `Document.annotations()` calls — neither surface reimplements the
/// reopen-resolution decision).
///
/// Tripwire 8: this crosses the `.md` ↔ op-log boundary via `Document.load`,
/// so the paragraph id uses the 4-char restricted alphabet.
@MainActor
final class CrossSurfaceReopenRoundTripTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("XREOPEN-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Mirrors `CrossDeviceIntegrationTests.makeManuscriptProject` /
    /// `AnnotationLifecycleUndoTests.makeHarness`: a minimal on-disk Novel
    /// project with a single manuscript file, so `Document.load` resolves the
    /// docId via the manifest and runs the real op-log load/reconcile path.
    private func makeManuscriptProject(initialMd: String, docId: String) throws -> URL {
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: docId, title: "C1", type: .document, path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp.appendingPathComponent(docPath)
    }

    /// A phone-shaped `annotation_reopen` op — same shape `AnnotationWriter
    /// .makeReopen` produces via `AnnotationInverse.reopenOp`: `device` is the
    /// `phone:<uuid>` form (drives the device slug the op lands under),
    /// `changes` is empty, and `provenance` carries the phone's forensic
    /// `appVersion`/`osVersion` stamping that Mac-authored reopens never set.
    func test_phoneReopenOp_macReadsBack_derivesOpen() async throws {
        let docId = "doc-xsurface-reopen"
        let pid = "k7m3"

        let initialMd = Materializer.materialize(
            paragraphs: [pid: "The sun set."], sequence: [pid])
        let docURL = try makeManuscriptProject(initialMd: initialMd, docId: docId)
        let projectURL = tmp!

        // Seed the bootstrap paragraph via the op log (ADR 0019: content/order
        // come only from the op log).
        try await seedOpLogBootstrap(
            projectURL: projectURL, docId: docId,
            paragraphs: [pid: "The sun set."], sequence: [pid])

        // Mac-authored creation + reject in the Mac's own per-device file.
        let creation = Op(
            opId: "01HQ8K2M9N4P5R6S8T0V2W3X4Y", docId: docId,
            at: Date(timeIntervalSince1970: 1_000), device: "mac", session: "s",
            kind: .claudeComment,
            changes: [Op.ParagraphChange(paragraphId: pid, prior: "The sun set.", next: "")],
            provenance: Op.Provenance(sessionId: "s", annotationBody: "tighten this"))
        let reject = Op(
            opId: "01HQR9F8K2P7N3DJ8WMVQXY5T0", docId: docId,
            at: Date(timeIntervalSince1970: 1_100), device: "mac", session: "s2",
            kind: .claudeReject, changes: [],
            provenance: Op.Provenance(sessionId: "s2", sourceAnnotationId: creation.opId, userResponse: "not needed"))

        // Phone-authored reopen — the shape `AnnotationWriter.makeReopen`
        // produces: forensic appVersion/osVersion set, changes empty, device
        // is the phone's `phone:<uuid>` form.
        let phoneReopen = Op(
            opId: "01HQR9F8K2P7N3DJ8WMVQXY5T1", docId: docId,
            at: Date(timeIntervalSince1970: 1_200), device: "phone:TEST", session: "s3",
            kind: .annotationReopen, changes: [],
            provenance: Op.Provenance(
                sessionId: "s3", sourceAnnotationId: creation.opId,
                appVersion: "0.17.0", osVersion: "iOS 17.4"))

        let store = OpLogStore(projectURL: projectURL)
        for op in [creation, reject, phoneReopen] { try await store.append(op) }

        // Real production load path.
        let doc = try await Document.load(
            url: docURL, device: "mac", session: "s", presenter: nil)

        let resolved = try XCTUnwrap(
            doc.annotations(filter: AnnotationFilter(statuses: nil))
                .first { $0.id == creation.opId })
        XCTAssertEqual(resolved.status, .open,
                       "a phone-authored reopen op must derive .open through the real Document.load path")
        XCTAssertNil(resolved.resolvedAt)
        XCTAssertNil(resolved.userResponse, "reopen clears the prior reject's user response")

        // Per-device partitioning (ADR 0012): the phone's reopen landed in ITS
        // OWN file, not the Mac's — the Mac's `load` glob merges the two.
        let slug = DeviceSlug.make(from: "phone:TEST")
        let phoneFileURL = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: slug, in: projectURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: phoneFileURL.path))

        await doc.close()
    }
}
