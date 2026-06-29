import XCTest
import MaughamCore
@testable import Maugham

/// ADR 0019: the manuscript `.md` becomes clean (anchors live only in the op
/// log). `Document.load` must therefore stop depending on the `.md`'s anchors
/// for an EXISTING doc — an existing op log is authoritative; only a doc with
/// NO op log (a brand-new or imported plain file) bootstraps from its `.md`.
///
/// The `.md` is still written ANCHORED at this stage (Task 3 makes it clean),
/// so these tests SIMULATE a clean `.md` by overwriting the file with an
/// anchor-stripped version after bootstrap. That proves load ignores the
/// `.md`'s (missing) anchors and takes content + order from the op log.
@MainActor
final class LoadFromOpLogNotMdTests: XCTestCase {

    private struct Fixture {
        let projectURL: URL
        let docPath: String
        let docId: String
        var docURL: URL { projectURL.appendingPathComponent(docPath) }
    }

    /// Build a minimal Novel project with one unanchored manuscript file and a
    /// matching manifest, so `Document.load` resolves the manifest doc-id (not
    /// the hash fallback). Mirrors `BootstrapWiringTests.makeUnanchoredProject`.
    private func makeProject(
        docId: String = "doc-load-from-oplog",
        body: String = "First paragraph.\n\nSecond paragraph.\n"
    ) throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LFO-\(UUID().uuidString)")
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

    // MARK: - Case 1: existing doc + clean .md does NOT re-bootstrap

    /// An existing doc whose `.md` has been stripped of its anchors (the clean
    /// shape Task 3 ships) must NOT re-bootstrap on reload, and its content +
    /// order must come from the op log — not the anchor-less `.md`.
    func test_existingDoc_cleanMd_doesNotReBootstrap_loadsFromOpLog() async throws {
        let fx = try makeProject()

        // First load: bootstraps the unanchored .md, mints anchors, emits one
        // .bootstrap op into the per-doc op log.
        let first = try await Document.load(
            url: fx.docURL, device: "test", session: "s", presenter: nil)
        let opStore = OpLogStore(projectURL: fx.projectURL)
        let opsAfterFirst = try await opStore.load(docId: fx.docId)
        XCTAssertEqual(
            opsAfterFirst.filter { $0.kind == .bootstrap }.count, 1,
            "first load must bootstrap exactly once")
        let opLogContentAfterFirst = first.materialize()

        // Simulate Task 3's clean .md: overwrite the file with an
        // anchor-stripped version. Now the on-disk .md has NO ¶id anchors.
        let stripped = MarkdownDisplayFilter.stripAnchors(opLogContentAfterFirst)
        let parsedClean = ParagraphParser.parse(stripped)
        XCTAssertTrue(
            parsedClean.allSatisfy { $0.id == nil },
            "precondition: the simulated clean .md must carry no anchors")
        try stripped.write(to: fx.docURL, atomically: true, encoding: .utf8)

        // Second load against the CLEAN .md.
        let second = try await Document.load(
            url: fx.docURL, device: "test", session: "s", presenter: nil)

        // (a) No fresh bootstrap op: the op log is authoritative, the clean
        //     .md must not be read as "needs bootstrap".
        let opsAfterSecond = try await opStore.load(docId: fx.docId)
        XCTAssertEqual(
            opsAfterSecond.filter { $0.kind == .bootstrap }.count, 1,
            "an existing op log must NOT re-bootstrap from a clean .md")

        // (b) Content + order come from the op log, not the anchor-less .md.
        let fromOpLog = Deriver.deriveWithSequenceFallback(ops: opsAfterSecond)
        let expected = Materializer.materialize(
            paragraphs: fromOpLog.paragraphs, sequence: fromOpLog.sequence)
        XCTAssertEqual(
            second.materialize(), expected,
            "loaded content/order must equal the op-log derivation")
        XCTAssertTrue(second.displayText.contains("First paragraph."))
        XCTAssertTrue(second.displayText.contains("Second paragraph."))
    }

    // MARK: - Case 2: new/imported plain .md (no op log) DOES bootstrap

    /// A brand-new or imported plain `.md` with NO op-log files is the
    /// sanctioned import read: load mints ids, creates the op log, and the
    /// content is present.
    func test_newImportedDoc_noOpLog_doesBootstrap() async throws {
        let fx = try makeProject(docId: "doc-imported-plain")

        // Precondition: a clean .md (no anchors) and NO op-log files at all.
        let onDisk = try String(contentsOf: fx.docURL, encoding: .utf8)
        XCTAssertTrue(
            ParagraphParser.parse(onDisk).allSatisfy { $0.id == nil },
            "precondition: imported file is anchor-less")
        XCTAssertTrue(
            OpLogStore.opLogFileURLs(forDocId: fx.docId, in: fx.projectURL).isEmpty,
            "precondition: no op log exists yet")

        let doc = try await Document.load(
            url: fx.docURL, device: "test", session: "s", presenter: nil)

        // Op log created with exactly one bootstrap op.
        let opStore = OpLogStore(projectURL: fx.projectURL)
        let ops = try await opStore.load(docId: fx.docId)
        let bootstraps = ops.filter { $0.kind == .bootstrap }
        XCTAssertEqual(
            bootstraps.count, 1, "an importless doc must bootstrap once")
        XCTAssertEqual(bootstraps[0].changes.count, 2)
        XCTAssertEqual(bootstraps[0].sequence?.count, 2)

        // ids minted + written back to the .md.
        let afterMd = try String(contentsOf: fx.docURL, encoding: .utf8)
        XCTAssertTrue(
            ParagraphParser.parse(afterMd).allSatisfy { $0.id != nil },
            "bootstrap must mint anchors back to the .md")

        // Content present.
        XCTAssertTrue(doc.displayText.contains("First paragraph."))
        XCTAssertTrue(doc.displayText.contains("Second paragraph."))
    }
}
