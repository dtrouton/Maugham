import XCTest
import MaughamCore
@testable import Maugham

/// F2 — an anchored `.md` (every paragraph carries a `<!-- ¶id -->` anchor) with
/// an EMPTY op log must bootstrap by SEEDING the op log from the file's EXISTING
/// ids (minting nothing, not rewriting the `.md`), so the doc opens with its
/// content and stable identity — instead of opening empty and letting the first
/// autosave clobber the manuscript with the empty render.
///
/// The torn state arises from a crash between Bootstrap's `.md` write and its op
/// append, a deleted `.maugham/`, or a backup restore that missed the hidden
/// `.maugham/` dir. These are the `Document.load`-level companions to
/// `BootstrapTests`' `Bootstrap.run`-level unit coverage.
@MainActor
final class AnchoredFileEmptyLogBootstrapTests: XCTestCase {

    private struct Fixture {
        let projectURL: URL
        let docPath: String
        let docId: String
        var docURL: URL { projectURL.appendingPathComponent(docPath) }
    }

    /// A minimal Novel project whose single manuscript file holds `body`, with a
    /// matching manifest so `Document.load` resolves the manifest doc-id (not the
    /// hash fallback). Mirrors `LoadFromOpLogNotMdTests.makeProject`.
    private func makeProject(docId: String, body: String) throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AFEL-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try body.write(
            to: tmp.appendingPathComponent(docPath),
            atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: docId, title: "Chapter 1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        return Fixture(projectURL: tmp, docPath: docPath, docId: docId)
    }

    /// Assemble an ANCHORED body: each paragraph is `<!-- ¶id -->` + blank line +
    /// text, matching what `ParagraphParser` recognizes as an anchored paragraph.
    private func anchoredBody(_ paras: [(id: String, text: String)]) -> String {
        paras.map { "<!-- ¶\($0.id) -->\n\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    // MARK: - anchored file + empty log → seed, content present, ids preserved

    func test_anchoredFile_noOpLog_load_seedsAndPreservesIds() async throws {
        let idA = ParagraphID.mint()
        let idB = ParagraphID.mint()
        let fx = try makeProject(
            docId: "doc-anchored-empty-log",
            body: anchoredBody([(idA, "Alpha."), (idB, "Bravo.")]))

        // Preconditions: the file is anchored, and there is NO op log.
        let onDisk = ParagraphParser.parse(
            try String(contentsOf: fx.docURL, encoding: .utf8))
        XCTAssertEqual(onDisk.compactMap(\.id), [idA, idB],
            "precondition: the file carries both anchors")
        XCTAssertTrue(
            OpLogStore.opLogFileURLs(forDocId: fx.docId, in: fx.projectURL).isEmpty,
            "precondition: no op log exists yet")

        let doc = try await Document.load(
            url: fx.docURL, device: "test", session: "s", presenter: nil)

        // Content present + identity preserved (no re-mint).
        XCTAssertTrue(doc.displayText.contains("Alpha."))
        XCTAssertTrue(doc.displayText.contains("Bravo."))
        XCTAssertEqual(doc.sequence, [idA, idB],
            "the seeded doc must keep the file's existing ids")

        // Exactly one bootstrap op carrying the existing ids + one checkpoint.
        let ops = try await OpLogStore(projectURL: fx.projectURL).load(docId: fx.docId)
        let bootstraps = ops.filter { $0.kind == .bootstrap }
        XCTAssertEqual(bootstraps.count, 1, "load must seed exactly one bootstrap op")
        XCTAssertEqual(bootstraps[0].sequence, [idA, idB])
        XCTAssertEqual(bootstraps[0].changes.map(\.paragraphId), [idA, idB])

        let cps = try await CheckpointStore(projectURL: fx.projectURL).load()
        XCTAssertEqual(cps.count, 1, "seed path must emit the initial checkpoint")
    }

    // MARK: - second load appends nothing (op log now authoritative)

    func test_anchoredFile_noOpLog_secondLoad_appendsNothing() async throws {
        let idA = ParagraphID.mint()
        let idB = ParagraphID.mint()
        let fx = try makeProject(
            docId: "doc-anchored-second-load",
            body: anchoredBody([(idA, "Alpha."), (idB, "Bravo.")]))

        _ = try await Document.load(
            url: fx.docURL, device: "test", session: "s", presenter: nil)
        let opsAfterFirst = try await OpLogStore(projectURL: fx.projectURL)
            .load(docId: fx.docId)
        XCTAssertEqual(opsAfterFirst.filter { $0.kind == .bootstrap }.count, 1)

        _ = try await Document.load(
            url: fx.docURL, device: "test", session: "s2", presenter: nil)
        let opsAfterSecond = try await OpLogStore(projectURL: fx.projectURL)
            .load(docId: fx.docId)
        XCTAssertEqual(opsAfterSecond.count, opsAfterFirst.count,
            "a non-empty op log must NOT re-bootstrap on the second load")
    }

    // MARK: - crash-mid-import: log deleted, anchored .md kept → recovers

    /// Run Bootstrap on an UN-anchored file (mints ids, writes the anchored
    /// `.md`, emits an op), delete the op-log file it wrote while KEEPING the
    /// anchored `.md` it produced, then reload. The content must survive with the
    /// SAME ids — the seed path re-materializes from the file's anchors.
    func test_crashMidImport_deletedLog_reload_contentSurvivesWithSameIds() async throws {
        let fx = try makeProject(
            docId: "doc-crash-import",
            body: "First paragraph.\n\nSecond paragraph.\n")

        _ = try await Bootstrap.run(
            projectURL: fx.projectURL, docId: fx.docId, mdURL: fx.docURL,
            device: "m", session: "s")

        // The ids Bootstrap minted, read back from the now-anchored `.md`.
        let mintedIds = ParagraphParser.parse(
            try String(contentsOf: fx.docURL, encoding: .utf8)).compactMap(\.id)
        XCTAssertEqual(mintedIds.count, 2, "Bootstrap must have minted two ids")

        // Simulate the crash-after-import gap: delete every op-log file but keep
        // the anchored `.md` Bootstrap produced.
        for url in OpLogStore.opLogFileURLs(forDocId: fx.docId, in: fx.projectURL) {
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertTrue(
            OpLogStore.opLogFileURLs(forDocId: fx.docId, in: fx.projectURL).isEmpty,
            "precondition: the op log is gone; only the anchored .md remains")

        let doc = try await Document.load(
            url: fx.docURL, device: "m", session: "s2", presenter: nil)

        XCTAssertEqual(doc.sequence, mintedIds,
            "recovery must keep the original ids, not re-mint")
        XCTAssertTrue(doc.displayText.contains("First paragraph."))
        XCTAssertTrue(doc.displayText.contains("Second paragraph."))
    }
}
