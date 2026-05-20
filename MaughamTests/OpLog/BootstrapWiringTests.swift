import XCTest
@testable import Maugham

/// Contract: every production manuscript-load path must run `Bootstrap.run`
/// on first open of a legacy (unanchored) `.md`, so that inline `<!-- ¶id -->`
/// anchors exist before any keystroke reaches the op log. Without anchors,
/// `RenderFilter.restoreComments` falls through to "mint fresh ID" on every
/// edit and the op log loses paragraph identity across saves.
///
/// As of `milestone-document-first-class` (2026-05-19) the contract reduces
/// to a single surface: `Document.load`. Both production entry points
/// — `EditorHost.loadDocumentIfNeeded` and
/// `AnnotationToolHelpers.withAnnotationDocument` — funnel through it.
///
/// These tests assert the contract at two levels:
///   1. Directly against `Document.load` (the unifying surface).
///   2. Through `withAnnotationDocument` (the MCP transient-load path),
///      which guards the closed-doc case the editor path doesn't cover.
@MainActor
final class BootstrapWiringTests: XCTestCase {

    private struct Fixture {
        let projectURL: URL
        let docPath: String
        let docId: String
        let projectStore: ProjectStore
        let registry: ProjectRegistry
        let projectId: String
    }

    /// Build a minimal project on disk with one unanchored manuscript file.
    /// "Unanchored" = the .md has paragraph text but no `<!-- ¶id -->`
    /// comments, simulating a legacy doc that's never seen the op log.
    private func makeUnanchoredProject(
        docId: String = "doc-wiring-test",
        body: String = "First paragraph.\n\nSecond paragraph.\n"
    ) async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BWT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
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

        let pStore = try await ProjectStore.load(from: tmp)
        let registry = ProjectRegistry()
        registry.register(url: tmp, store: pStore)
        let projectId = ProjectIdentifier.id(for: tmp)

        return Fixture(
            projectURL: tmp,
            docPath: docPath,
            docId: docId,
            projectStore: pStore,
            registry: registry,
            projectId: projectId)
    }

    /// Sanity check: the fixture starts unanchored. If a future change makes
    /// the fixture build pre-anchor the file, the wiring tests below would
    /// trivially pass without exercising Bootstrap.
    func test_fixture_isUnanchored() async throws {
        let fx = try await makeUnanchoredProject()
        let onDisk = try String(
            contentsOf: fx.projectURL.appendingPathComponent(fx.docPath),
            encoding: .utf8)
        let parsed = ParagraphParser.parse(onDisk)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertTrue(
            parsed.allSatisfy { $0.id == nil },
            "fixture must start without ¶id anchors so the wiring tests can " +
            "observe Bootstrap actually firing")
    }

    /// Contract surface 1: `Document.load` on an unanchored .md MUST
    /// (a) write `<!-- ¶id -->` anchors back to disk, and
    /// (b) emit a single `.bootstrap` op into the per-doc op log.
    /// This is the surface every production manuscript-load path funnels
    /// through.
    func test_documentLoad_bootstrapsUnanchoredManuscript() async throws {
        let fx = try await makeUnanchoredProject()
        let docURL = fx.projectURL.appendingPathComponent(fx.docPath)

        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        // (a) .md gained inline ¶id anchors.
        let afterMd = try String(contentsOf: docURL, encoding: .utf8)
        let parsed = ParagraphParser.parse(afterMd)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertTrue(
            parsed.allSatisfy { $0.id != nil },
            "Document.load must run Bootstrap and mint anchors")
        XCTAssertNotEqual(parsed[0].id, parsed[1].id)

        // (b) bootstrap op landed in the log for this doc id.
        let opStore = OpLogStore(projectURL: fx.projectURL)
        let ops = try await opStore.load(docId: doc.docId)
        let bootstrapOps = ops.filter { $0.kind == .bootstrap }
        XCTAssertEqual(
            bootstrapOps.count, 1,
            "expected exactly one bootstrap op after first load")
        XCTAssertEqual(bootstrapOps[0].changes.count, 2)
        XCTAssertEqual(bootstrapOps[0].sequence?.count, 2)
    }

    /// Idempotency under the wiring: a second `Document.load` against an
    /// already-anchored .md MUST NOT emit a duplicate bootstrap op. Bootstrap
    /// is supposed to be a one-time migration; if it ever re-runs it would
    /// invalidate every prior op record by re-minting paragraph ids.
    func test_documentLoad_doesNotReBootstrapAnchoredManuscript() async throws {
        let fx = try await makeUnanchoredProject()
        let docURL = fx.projectURL.appendingPathComponent(fx.docPath)

        // First load: bootstraps.
        _ = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let opStore = OpLogStore(projectURL: fx.projectURL)
        let initialOps = try await opStore.load(docId: fx.docId)
        XCTAssertEqual(initialOps.filter { $0.kind == .bootstrap }.count, 1)

        // Second load: must be a no-op for Bootstrap.
        _ = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let secondOps = try await opStore.load(docId: fx.docId)
        XCTAssertEqual(
            secondOps.filter { $0.kind == .bootstrap }.count, 1,
            "Bootstrap.run must be idempotent under repeated Document.load")
    }

    /// Contract surface 2: `withAnnotationDocument` (the MCP transient-load
    /// helper used by every annotation tool when the doc isn't open in the
    /// editor) MUST bootstrap a previously-untouched manuscript. This is the
    /// path that lets an MCP client annotate a closed doc; it goes through
    /// `Document.load` internally, but covering it explicitly catches future
    /// regressions where the MCP path is refactored to bypass Document.load
    /// (e.g., for a "read-only fast path" that skips the op log).
    func test_mcpTransientLoad_bootstrapsUnanchoredManuscript() async throws {
        let fx = try await makeUnanchoredProject()

        // The doc is NOT registered with a DocumentStore — withAnnotationDocument
        // must take the transient-load branch (case 2 in the helper).
        let result: String = try await withAnnotationDocument(
            projectId: fx.projectId,
            documentId: fx.docId,
            registry: fx.registry
        ) { doc in
            // Inside body: we observe the freshly-loaded transient Document.
            // Its op log should already contain a bootstrap op because
            // Document.load ran Bootstrap before we got here.
            let logged = try await doc.opLog()
            XCTAssertEqual(
                logged.filter { $0.kind == .bootstrap }.count, 1,
                "withAnnotationDocument must route through Document.load " +
                "and trigger Bootstrap on an unanchored .md")
            return doc.docId
        }
        XCTAssertEqual(result, fx.docId)

        // Post-condition (visible to the next caller, even after the transient
        // Document closes): anchors persisted, bootstrap op persisted.
        let onDisk = try String(
            contentsOf: fx.projectURL.appendingPathComponent(fx.docPath),
            encoding: .utf8)
        let parsed = ParagraphParser.parse(onDisk)
        XCTAssertTrue(parsed.allSatisfy { $0.id != nil })

        let opStore = OpLogStore(projectURL: fx.projectURL)
        let ops = try await opStore.load(docId: fx.docId)
        XCTAssertEqual(ops.filter { $0.kind == .bootstrap }.count, 1)
    }
}
