import XCTest
import MaughamCore
@testable import Maugham

/// F4 + F8 — the load-time divergence snapshot, and conflict-backup root
/// resolution.
///
/// F4: the backup-on-discard net only covered live presenter events. A file
/// edited while Maugham was CLOSED was silently overwritten by the first
/// autosave with no `.maugham/conflicts/` trace. `Document.load` now compares
/// the on-disk display form to the op-log-derived display form and, on
/// mismatch (and only when a log already existed — never the fresh-bootstrap
/// path), snapshots the on-disk bytes forensically before any autosave can
/// clobber them.
///
/// F8: `writeConflictBackup` computed the project root with a fixed two-level
/// `deletingLastPathComponent`, so a Collection piece at
/// `pieces/<NN>-<slug>/<file>.md` filed its backup under `pieces/.maugham/`
/// where nothing looks. It now resolves the root via `resolveProjectURL`.
@MainActor
final class LoadDivergenceSnapshotTests: XCTestCase {

    // MARK: - Fixtures

    private struct Fixture {
        let projectURL: URL
        let docPath: String
        let docId: String
        var docURL: URL { projectURL.appendingPathComponent(docPath) }
    }

    /// Build a project with a manifest at the root and a manuscript at
    /// `docPath` (created empty on disk unless `body` is supplied). Both a
    /// flat Novel layout (`manuscript/c1.md`) and a nested Collection layout
    /// (`pieces/01-intro/scene.md`) are expressed by varying `docPath`.
    private func makeProject(
        type: ProjectType = .novel,
        docId: String,
        docPath: String,
        body: String
    ) throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDS-\(UUID().uuidString)")
        let fileURL = tmp.appendingPathComponent(docPath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try body.write(to: fileURL, atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: docId, title: "Item", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: type, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        return Fixture(projectURL: tmp, docPath: docPath, docId: docId)
    }

    private func conflictFiles(_ dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
    }

    // MARK: - (a) external edit while closed → snapshot + op-log truth

    func test_externalEditWhileClosed_load_writesSnapshot_loadsOpLogTruth() async throws {
        let idA = ParagraphID.mint()
        let idB = ParagraphID.mint()
        let fx = try makeProject(
            docId: "doc-diverge-a", docPath: "manuscript/c1.md",
            body: "placeholder\n")
        try await seedOpLogBootstrap(
            projectURL: fx.projectURL, docId: fx.docId,
            paragraphs: [idA: "Alpha.", idB: "Bravo."],
            sequence: [idA, idB])

        // An outside editor rewrote the file while Maugham was closed.
        let external = "Totally different external text.\n"
        try external.write(to: fx.docURL, atomically: true, encoding: .utf8)

        let doc = try await Document.load(
            url: fx.docURL, device: "test", session: "s", presenter: nil)

        // Loaded content is the op-log truth, NOT the external bytes.
        XCTAssertTrue(doc.displayText.contains("Alpha."))
        XCTAssertTrue(doc.displayText.contains("Bravo."))
        XCTAssertFalse(doc.displayText.contains("Totally different external text"),
            "load must derive op-log truth, never the external bytes")

        // A forensic snapshot of the external bytes exists under the PROJECT's
        // .maugham/conflicts/.
        let conflictsDir = fx.projectURL.appendingPathComponent(".maugham/conflicts")
        let files = conflictFiles(conflictsDir)
        XCTAssertEqual(files.count, 1, "exactly one divergence snapshot expected")
        let contents = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertTrue(contents.contains(external),
            "the snapshot must preserve the exact on-disk external bytes")
    }

    // MARK: - (b) loading the same divergent file twice → one snapshot

    func test_loadingDivergentFileTwice_writesExactlyOneSnapshot() async throws {
        let idA = ParagraphID.mint()
        let fx = try makeProject(
            docId: "doc-diverge-b", docPath: "manuscript/c1.md",
            body: "placeholder\n")
        try await seedOpLogBootstrap(
            projectURL: fx.projectURL, docId: fx.docId,
            paragraphs: [idA: "Canonical."], sequence: [idA])

        let external = "External divergent bytes.\n"
        try external.write(to: fx.docURL, atomically: true, encoding: .utf8)

        _ = try await Document.load(
            url: fx.docURL, device: "test", session: "s1", presenter: nil)
        // The load did NOT rewrite the .md (no autosave fired), so the file is
        // still divergent on the second open.
        try external.write(to: fx.docURL, atomically: true, encoding: .utf8)
        _ = try await Document.load(
            url: fx.docURL, device: "test", session: "s2", presenter: nil)

        let conflictsDir = fx.projectURL.appendingPathComponent(".maugham/conflicts")
        XCTAssertEqual(conflictFiles(conflictsDir).count, 1,
            "repeated open of an unchanged divergent file must dedup to one snapshot")
    }

    // MARK: - (c) unmigrated anchored file EQUAL to op-log truth → no snapshot

    func test_unmigratedAnchoredFile_equalToOpLogTruth_noSnapshot() async throws {
        let idA = ParagraphID.mint()
        let idB = ParagraphID.mint()
        let fx = try makeProject(
            docId: "doc-diverge-c", docPath: "manuscript/c1.md",
            body: "placeholder\n")
        try await seedOpLogBootstrap(
            projectURL: fx.projectURL, docId: fx.docId,
            paragraphs: [idA: "Alpha.", idB: "Bravo."],
            sequence: [idA, idB])

        // Write the ANCHORED materialize form: the file is unmigrated (still
        // carries ¶id anchors) but its DISPLAY form equals the op-log truth.
        let anchored = Materializer.materialize(
            paragraphs: [idA: "Alpha.", idB: "Bravo."], sequence: [idA, idB])
        XCTAssertTrue(anchored.contains("<!-- ¶"),
            "precondition: the on-disk file is unmigrated (anchored)")
        try anchored.write(to: fx.docURL, atomically: true, encoding: .utf8)

        _ = try await Document.load(
            url: fx.docURL, device: "test", session: "s", presenter: nil)

        let conflictsDir = fx.projectURL.appendingPathComponent(".maugham/conflicts")
        XCTAssertTrue(conflictFiles(conflictsDir).isEmpty,
            "a still-anchored file whose content equals op-log truth must NOT snapshot")
    }

    // MARK: - (d) Collection piece → snapshot under the PROJECT root

    func test_collectionPiece_divergence_snapshotUnderProjectRoot() async throws {
        let idA = ParagraphID.mint()
        let fx = try makeProject(
            type: .collection, docId: "doc-diverge-d",
            docPath: "pieces/01-intro/scene.md", body: "placeholder\n")
        try await seedOpLogBootstrap(
            projectURL: fx.projectURL, docId: fx.docId,
            paragraphs: [idA: "Canonical piece text."], sequence: [idA])

        let external = "External piece edit.\n"
        try external.write(to: fx.docURL, atomically: true, encoding: .utf8)

        _ = try await Document.load(
            url: fx.docURL, device: "test", session: "s", presenter: nil)

        // Snapshot is under <project>/.maugham/conflicts/ …
        let projectConflicts = fx.projectURL
            .appendingPathComponent(".maugham/conflicts")
        let projectFiles = conflictFiles(projectConflicts)
        XCTAssertEqual(projectFiles.count, 1,
            "the snapshot must land under the PROJECT's .maugham/conflicts/")
        XCTAssertTrue(
            try projectFiles.map { try String(contentsOf: $0, encoding: .utf8) }
                .contains(external))

        // … NOT under pieces/.maugham/conflicts/ (the old two-level bug).
        let pieceConflicts = fx.projectURL
            .appendingPathComponent("pieces/.maugham/conflicts")
        XCTAssertTrue(conflictFiles(pieceConflicts).isEmpty,
            "backups must not land in the piece folder (F8)")
    }

    // MARK: - discard path also files a Collection piece under the project root

    func test_discardBackup_collectionPiece_landsUnderProjectRoot() async throws {
        let idA = ParagraphID.mint()
        let fx = try makeProject(
            type: .collection, docId: "doc-discard-collection",
            docPath: "pieces/02-body/scene.md", body: "placeholder\n")
        try await seedOpLogBootstrap(
            projectURL: fx.projectURL, docId: fx.docId,
            paragraphs: [idA: "Canonical piece text."], sequence: [idA])

        // Make the on-disk file match op-log truth so LOAD writes no snapshot —
        // isolating the discard-path backup under test.
        let clean = MarkdownDisplayFilter.stripAnchors(
            Materializer.materialize(
                paragraphs: [idA: "Canonical piece text."], sequence: [idA]))
        try clean.write(to: fx.docURL, atomically: true, encoding: .utf8)

        let doc = try await Document.load(
            url: fx.docURL, device: "test", session: "s", presenter: nil)
        XCTAssertTrue(conflictFiles(
            fx.projectURL.appendingPathComponent(".maugham/conflicts")).isEmpty,
            "precondition: load wrote no divergence snapshot")

        // Now discard a while-open external edit.
        let external = "External while-open edit.\n"
        try await doc.handleExternalDiskChange(diskMd: external)

        let projectFiles = conflictFiles(
            fx.projectURL.appendingPathComponent(".maugham/conflicts"))
        XCTAssertEqual(projectFiles.count, 1,
            "the discard backup must land under the PROJECT's .maugham/conflicts/")
        XCTAssertTrue(
            try projectFiles.map { try String(contentsOf: $0, encoding: .utf8) }
                .contains(external))
        XCTAssertTrue(conflictFiles(
            fx.projectURL.appendingPathComponent("pieces/.maugham/conflicts")).isEmpty,
            "the discard backup must not land in the piece folder (F8)")
    }
}
