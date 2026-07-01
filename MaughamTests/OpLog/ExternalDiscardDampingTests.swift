import XCTest
import MaughamCore
@testable import Maugham

/// F7 — external-discard ping-pong damping.
///
/// The discard handler auto-rewrites the `.md` with op-log truth on every
/// while-open external edit. If op-log sync lags the `.md` (iCloud's normal
/// failure mode) or a version-skewed peer keeps writing anchored files, two
/// devices bounce rewrites indefinitely — each bounce also writing a backup.
/// After `discardDampThreshold` discards with DISTINCT bytes in a session the
/// handler stops auto-rewriting (still snapshotting; op log still authoritative
/// in memory) until a local edit re-arms it.
@MainActor
final class ExternalDiscardDampingTests: XCTestCase {

    private struct Fixture {
        let projectURL: URL
        let docId: String
        let docURL: URL
        let clean: String
    }

    /// A Novel project whose on-disk `.md` already equals op-log truth, so
    /// `Document.load` writes no divergence snapshot — isolating the discard
    /// path under test.
    private func makeLoadedDoc(
        paragraphs: [String: String], sequence: [String]
    ) async throws -> (Document, Fixture) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EDD-\(UUID().uuidString)")
        let docPath = "manuscript/c1.md"
        let docURL = tmp.appendingPathComponent(docPath)
        try FileManager.default.createDirectory(
            at: docURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let docId = "doc-damp"
        let clean = MarkdownDisplayFilter.stripAnchors(
            Materializer.materialize(paragraphs: paragraphs, sequence: sequence))
        try clean.write(to: docURL, atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: docId, title: "Item", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(),
            modified: Date(), structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        try await seedOpLogBootstrap(
            projectURL: tmp, docId: docId,
            paragraphs: paragraphs, sequence: sequence)

        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let fx = Fixture(projectURL: tmp, docId: docId, docURL: docURL, clean: clean)
        // Precondition: no snapshot from load.
        XCTAssertTrue(conflictFiles(fx).isEmpty)
        return (doc, fx)
    }

    private func conflictFiles(_ fx: Fixture) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: fx.projectURL.appendingPathComponent(".maugham/conflicts"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }

    /// Deliver a distinct external edit: write the bytes to disk (as an outside
    /// editor would) and drive the presenter callback.
    private func deliverExternal(_ bytes: String, to doc: Document, fx: Fixture) async throws {
        try bytes.write(to: fx.docURL, atomically: true, encoding: .utf8)
        try await doc.handleExternalDiskChange(diskMd: bytes)
    }

    private func onDisk(_ fx: Fixture) throws -> String {
        try String(contentsOf: fx.docURL, encoding: .utf8)
    }

    func test_thirdDistinctDiscard_snapshotsButDoesNotRewrite() async throws {
        let id = ParagraphID.mint()
        let (doc, fx) = try await makeLoadedDoc(
            paragraphs: [id: "Canonical."], sequence: [id])

        // 1st + 2nd distinct discard → the .md is rewritten back to op-log truth.
        try await deliverExternal("External one.\n", to: doc, fx: fx)
        XCTAssertEqual(try onDisk(fx), fx.clean,
            "first discard must rewrite the .md with op-log truth")
        try await deliverExternal("External two.\n", to: doc, fx: fx)
        XCTAssertEqual(try onDisk(fx), fx.clean,
            "second discard must still rewrite")

        // 3rd distinct discard → snapshot only, the external bytes survive on disk.
        try await deliverExternal("External three.\n", to: doc, fx: fx)
        XCTAssertEqual(try onDisk(fx), "External three.\n",
            "third distinct discard must NOT rewrite — the external bytes stay on disk")

        // A snapshot was written on every discard (retention cap is 20, so all kept).
        XCTAssertEqual(conflictFiles(fx).count, 3,
            "each discard snapshots the external bytes forensically")
    }

    func test_byteIdenticalRepeat_doesNotAdvanceTheCounter() async throws {
        let id = ParagraphID.mint()
        let (doc, fx) = try await makeLoadedDoc(
            paragraphs: [id: "Canonical."], sequence: [id])

        // Two distinct discards, then the SAME bytes as the second re-delivered.
        try await deliverExternal("External one.\n", to: doc, fx: fx)
        try await deliverExternal("External two.\n", to: doc, fx: fx)
        // Re-deliver "External two." — a byte-identical repeat must not count as
        // a new distinct discard, so this stays under the threshold and rewrites.
        try await deliverExternal("External two.\n", to: doc, fx: fx)
        XCTAssertEqual(try onDisk(fx), fx.clean,
            "a byte-identical repeat must not advance the distinct-discard count")

        // A genuinely new (3rd distinct) discard now trips the threshold.
        try await deliverExternal("External three.\n", to: doc, fx: fx)
        XCTAssertEqual(try onDisk(fx), "External three.\n",
            "the third DISTINCT discard damps")
    }

    func test_localEdit_reArmsRewriting() async throws {
        let id = ParagraphID.mint()
        let (doc, fx) = try await makeLoadedDoc(
            paragraphs: [id: "Canonical."], sequence: [id])

        // Trip the damper.
        try await deliverExternal("External one.\n", to: doc, fx: fx)
        try await deliverExternal("External two.\n", to: doc, fx: fx)
        try await deliverExternal("External three.\n", to: doc, fx: fx)
        XCTAssertEqual(try onDisk(fx), "External three.\n", "precondition: damped")

        // A local edit re-arms rewriting.
        doc.setFullText("Canonical, locally edited.")

        // The next external discard rewrites again (op-log truth, now including
        // the local edit) rather than leaving the external bytes on disk.
        let expectedClean = MarkdownDisplayFilter.stripAnchors(doc.materialize())
        try await deliverExternal("External four.\n", to: doc, fx: fx)
        XCTAssertEqual(try onDisk(fx), expectedClean,
            "a local edit must re-arm discard rewriting")
        XCTAssertFalse(try onDisk(fx).contains("External four"))
    }
}
