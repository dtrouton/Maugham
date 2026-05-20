import XCTest
@testable import Maugham

/// Cross-area integration tests for the `DocumentStore` presenter → `Document`
/// routing seam. Owned by neither Stores nor OpLog: these tests assert that
/// `presenterDidChangeSubitem` dispatches each `MaughamSidecarPath` case
/// correctly AND that the echo guards on the OpLog side hold against our
/// own writes.
///
/// The seam was previously a string-prefix cascade with two different echo
/// strategies (text-equality for `.md`, op-id set for op log JSONL). Each
/// strategy is load-bearing for a class of correctness — silent re-ingest
/// of our own autosaves on the `.md` side, false orphan-archive cascades
/// on the log side — and neither had cross-area regression coverage prior
/// to this file.
@MainActor
final class PresenterRoutingTests: XCTestCase {

    // MARK: - Fixture

    private struct Fixture {
        let projectURL: URL
        let docPath: String
        let docId: String
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let registry: ProjectRegistry
        let projectId: String
    }

    /// Build a minimal project with one already-anchored manuscript so that
    /// `Document.load` won't trigger Bootstrap as a side effect of the
    /// presenter routing under test.
    private func makeProject(
        initialMd: String = "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n",
        docId: String = "doc-presenter-test"
    ) async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        try initialMd.write(
            to: tmp.appendingPathComponent(docPath),
            atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: docId, title: "C1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let projectStore = try await ProjectStore.load(from: tmp)
        let docStore = try await DocumentStore.open(url: tmp)
        projectStore.documentStore = docStore
        let registry = ProjectRegistry()
        registry.register(url: tmp, store: projectStore)
        let projectId = ProjectIdentifier.id(for: tmp)

        return Fixture(
            projectURL: tmp,
            docPath: docPath,
            docId: docId,
            projectStore: projectStore,
            documentStore: docStore,
            registry: registry,
            projectId: projectId)
    }

    // MARK: - Echo guards (lastDiskEcho contract)

    /// Our own autosave write writes the .md; the presenter then fires; the
    /// echo guard MUST suppress it. Otherwise every autosave silently
    /// reingests itself as an `externalEdit` op.
    func test_ourAutosave_doesNotReingestAsExternalEdit() async throws {
        let fx = try await makeProject()
        let doc = try await Document.load(
            url: fx.projectURL.appendingPathComponent(fx.docPath),
            device: "test", session: "s", presenter: fx.documentStore.presenter)
        fx.documentStore.register(document: doc, for: fx.docPath)

        // Type something + close to force a deterministic autosave (close
        // flushes the autosave scheduler).
        doc.setFullText(doc.displayText + " edit.")
        await doc.close()

        let externalEditsBefore = (try await doc.opLog())
            .filter { $0.kind == .externalEdit }.count

        // Drive the presenter routing as if a sync event arrived for the
        // file we just wrote.
        fx.documentStore.presenterDidChangeSubitem(
            at: fx.projectURL.appendingPathComponent(fx.docPath))
        try await Task.sleep(for: .milliseconds(200))

        let externalEditsAfter = (try await doc.opLog())
            .filter { $0.kind == .externalEdit }.count

        XCTAssertEqual(externalEditsAfter, externalEditsBefore,
            "Our own autosave write must not be reingested as an externalEdit. " +
            "lastDiskEcho is supposed to short-circuit handleExternalDiskChange " +
            "for diskMd that equals the bytes we just wrote.")
    }

    /// `resolveConflictKeepMine` schedules an autosave + flushes it. After
    /// the flush completes, a presenter event for the same file MUST be an
    /// echo. The contract is: `performAutosave` updates `lastDiskEcho`
    /// synchronously inside its coordinated-write block, so by the time
    /// `flush()` resolves the echo state already covers the new bytes.
    func test_resolveKeepMine_doesNotReingestAsExternalEdit() async throws {
        let fx = try await makeProject()
        let doc = try await Document.load(
            url: fx.projectURL.appendingPathComponent(fx.docPath),
            device: "test", session: "s", presenter: fx.documentStore.presenter)
        fx.documentStore.register(document: doc, for: fx.docPath)

        // Synthesize a conflict by writing different external bytes and
        // routing it through the presenter. The conflict surfaces because
        // the external bytes strip the ¶id anchors.
        try "External edit with no anchors.\n".write(
            to: fx.projectURL.appendingPathComponent(fx.docPath),
            atomically: true, encoding: .utf8)
        fx.documentStore.presenterDidChangeSubitem(
            at: fx.projectURL.appendingPathComponent(fx.docPath))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(doc.pendingConflict,
            "preconditions: stripped-anchor external edit should surface a conflict")

        // Keep mine: the doc's derived state wins. The autosave rewrites
        // the .md with our anchored bytes; lastDiskEcho updates to match.
        let externalEditsBefore = (try await doc.opLog())
            .filter { $0.kind == .externalEdit }.count
        try await doc.resolveConflictKeepMine()

        // A presenter event from disk delivers our own just-written bytes.
        fx.documentStore.presenterDidChangeSubitem(
            at: fx.projectURL.appendingPathComponent(fx.docPath))
        try await Task.sleep(for: .milliseconds(200))

        let externalEditsAfter = (try await doc.opLog())
            .filter { $0.kind == .externalEdit }.count
        XCTAssertEqual(externalEditsAfter, externalEditsBefore,
            "After resolveConflictKeepMine flushes its autosave, the matching " +
            "presenter callback must be detected as an echo and not appended " +
            "as a new externalEdit op.")
        XCTAssertNil(doc.pendingConflict,
            "resolveConflictKeepMine must clear pendingConflict")
    }

    // MARK: - SweepReason contract (annotation-vanish regression)

    /// Regression test for the "annotations vanish 1-2 seconds after MCP
    /// add_annotation" bug. The mechanism we're guarding against:
    ///
    /// 1. Live Document is open + registered. User has typed paragraphs,
    ///    some not yet bursted to disk.
    /// 2. MCP `add_annotation` runs against the live Document via
    ///    `withAnnotationDocument` case 1.
    /// 3. The annotation op write triggers a presenter callback for the
    ///    op log file.
    /// 4. `handleExternalLogChange` ran a diff against the disk-reconstructed
    ///    sequence and flagged a sweep for any paragraph id "missing" from
    ///    the reconstruction.
    /// 5. Sweep archived every annotation on those in-memory-only paragraphs.
    ///
    /// With `SweepReason` carrying the *observed* removed set instead of
    /// "anything missing from sequence", a write that only adds ops can't
    /// flag a sweep — the prior/next sequence diff is empty.
    func test_mcpAddAnnotationLive_doesNotTriggerOrphanArchive() async throws {
        let fx = try await makeProject()
        let doc = try await Document.load(
            url: fx.projectURL.appendingPathComponent(fx.docPath),
            device: "test", session: "s", presenter: fx.documentStore.presenter)
        fx.documentStore.register(document: doc, for: fx.docPath)

        // Pull the paragraph ids actually in the doc.
        let pid = doc.displayText.split(separator: "\n\n").first.map(String.init)
        XCTAssertNotNil(pid, "preconditions")
        let firstParagraphId = "a3f9"
        // (We seeded the fixture with these specific anchor ids.)

        // Add an annotation on the first paragraph through MCP's helper —
        // this hits case 1 (live doc registered in DocumentStore).
        _ = try await withAnnotationDocument(
            projectId: fx.projectId,
            documentId: fx.docId,
            registry: fx.registry
        ) { liveDoc in
            try await liveDoc.addAnnotation(
                kind: .comment,
                paragraphId: firstParagraphId,
                body: "test annotation from mcp")
        }

        let comments = doc.annotations(filter: .init(statuses: nil))
            .filter { $0.kind == .comment }
        XCTAssertEqual(comments.count, 1)

        // Drive the presenter callback for the op log as if a sync event
        // arrived. The new annotation op IS already in `_opLogMirror`
        // (case 1 routes through the live doc), so handleExternalLogChange
        // should see no new ops and bail out without flagging a sweep.
        let opLogURL = fx.projectURL.appendingPathComponent(
            ".maugham/ops/\(fx.docId).jsonl")
        fx.documentStore.presenterDidChangeSubitem(at: opLogURL)
        try await Task.sleep(for: .milliseconds(200))

        // Also force a burst flush to run the sweep gate, in case any path
        // managed to flip `_pendingSweep` without us looking.
        try await doc.flushBurstNow()

        let archiveOps = (try await doc.opLog()).filter {
            $0.kind == .claudeArchive
                && $0.provenance?.synthesisSource == .paragraphDeleted
        }
        XCTAssertTrue(archiveOps.isEmpty,
            "An MCP add_annotation on a live doc must not synthesize " +
            "claude_archive ops with synthesisSource=paragraph_deleted. " +
            "If this fires, the sweep is keying off a sequence diff that " +
            "doesn't represent a real deletion — see SweepReason.")

        // And the annotation must still be open, not archived.
        let openAnns = doc.annotations()
        XCTAssertEqual(openAnns.count, 1,
            "annotation must remain open after presenter routing of its own write")
    }

    // MARK: - MaughamSidecarPath dispatch

    /// A change to `.maugham/sessions/foo.json` must not route to any
    /// manuscript handler, even if a Document happens to be registered.
    /// The typed enum routes it to `.sessionLog` which is a no-op today.
    func test_externalSidecarChange_unhandledPath_isNoOp() async throws {
        let fx = try await makeProject()
        let doc = try await Document.load(
            url: fx.projectURL.appendingPathComponent(fx.docPath),
            device: "test", session: "s", presenter: fx.documentStore.presenter)
        fx.documentStore.register(document: doc, for: fx.docPath)

        let externalEditsBefore = (try await doc.opLog())
            .filter { $0.kind == .externalEdit }.count

        let sessionURL = fx.projectURL
            .appendingPathComponent(".maugham/sessions/today.json")
        // We don't even create the file — `presenterDidChangeSubitem` is
        // path-driven, not contents-driven, and the routing should not
        // touch the manuscript regardless.
        fx.documentStore.presenterDidChangeSubitem(at: sessionURL)
        try await Task.sleep(for: .milliseconds(100))

        let externalEditsAfter = (try await doc.opLog())
            .filter { $0.kind == .externalEdit }.count
        XCTAssertEqual(externalEditsAfter, externalEditsBefore,
            "A session-log path change must not route to any Document.")
    }

    /// Pure-function classifier test: every canonical `.maugham/` subdir
    /// parses to its own case. Adding a new owner becomes adding a case
    /// here AND in `MaughamSidecarPath` together.
    func test_sidecarPathParser_roundTripsAllCanonicalSubdirs() {
        let project = URL(fileURLWithPath: "/tmp/foo-project")

        func cls(_ rel: String) -> MaughamSidecarPath {
            MaughamSidecarPath.classify(
                url: project.appendingPathComponent(rel),
                projectURL: project)
        }

        XCTAssertEqual(cls("project.maugham.json"), .manifest)
        XCTAssertEqual(cls(".maugham/ops/doc-abc.jsonl"),
            .opLog(docId: "doc-abc"))
        XCTAssertEqual(cls(".maugham/checkpoints.jsonl"), .checkpoints)

        // The pending companion file MUST NOT be treated as a routable op log.
        XCTAssertEqual(cls(".maugham/ops/doc-abc.pending.jsonl"),
            .unknownSidecar(relativePath: ".maugham/ops/doc-abc.pending.jsonl"))

        XCTAssertEqual(cls(".maugham/sessions/today.json"),
            .sessionLog(relativePath: ".maugham/sessions/today.json"))
        XCTAssertEqual(cls(".maugham/ui-state.json"),
            .uiState(relativePath: ".maugham/ui-state.json"))
        XCTAssertEqual(cls(".maugham/conflicts/c1.md-cloud-2026.md"),
            .conflictBackup(relativePath: ".maugham/conflicts/c1.md-cloud-2026.md"))
        XCTAssertEqual(cls(".maugham/scratch/tmp.json"),
            .scratch(relativePath: ".maugham/scratch/tmp.json"))
        XCTAssertEqual(cls(".maugham/trash/abc.json"),
            .trash(relativePath: ".maugham/trash/abc.json"))

        // Anything under the project but outside .maugham/ and not the
        // manifest is `.otherProjectFile` — the manuscript dispatch then
        // resolves it against the registry.
        XCTAssertEqual(cls("manuscript/c1.md"),
            .otherProjectFile(relativePath: "manuscript/c1.md"))

        // Outside the project entirely.
        let outside = URL(fileURLWithPath: "/tmp/other-project/manifest.json")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: outside, projectURL: project),
            .outsideProject)
    }
}
