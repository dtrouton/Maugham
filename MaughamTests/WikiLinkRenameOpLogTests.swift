import XCTest
import MaughamCore
@testable import Maugham

/// Wiki-link rename propagation (`propagateWikiLinkRename`) must route the
/// `[[oldTitle]]`→`[[newTitle]]` rewrite of OTHER manuscripts through the op
/// log — the #1 hard invariant (op log is the source of truth) — not a raw
/// `String.write(to:)` that bypasses the op stream (finding 0.1, the only
/// confirmed manuscript-corruption bug).
///
/// Two cases:
///  - CLOSED target: doc B (not open in the registry) referencing `[[A]]` gets
///    a real op appended to its log, its display form shows `[[A2]]`, and a
///    fresh `Document.load` round-trips with no reconcile divergence.
///  - OPEN target (anti-clobber): a live registered `Document` B reflects the
///    rewrite via an appended op and is not clobbered by a raw underneath-write.
@MainActor
final class WikiLinkRenameOpLogTests: XCTestCase {

    /// Build a project with `manuscript/<id>.md` files from (id, title, body)
    /// tuples, through the real on-disk shape the production loader reads.
    ///
    /// `statements` are written into the manifest as-is and their files are the
    /// caller's to create — the point of the seam is that a manifest entry can
    /// name a file this project has no op log for at all (a freshly promoted
    /// project's, whose `.maugham/` stayed behind).
    private func makeProject(
        docs: [(id: String, title: String, body: String)],
        statements: [Statement] = []
    ) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("WikiRenameOpLog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        var structure: [StructureItem] = []
        for d in docs {
            // 2-digit NN prefix so renameStructureItem can preserve it.
            let path = "manuscript/01-\(d.id).md"
            try d.body.write(
                to: tmp.appendingPathComponent(path),
                atomically: true, encoding: .utf8)
            structure.append(StructureItem(
                id: d.id, title: d.title, type: .document, path: path))
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: structure, research: [], statements: statements)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    /// The current relative path of the structure item with `id`.
    private func path(of store: ProjectStore, id: String) -> String {
        ProjectStore.collectDocuments(in: store.manifest.structure)
            .first(where: { $0.id == id })?.path ?? ""
    }

    // MARK: - Closed target

    func test_closedTarget_rewriteRoutesThroughOpLog() async throws {
        let project = try makeProject(docs: [
            (id: "a", title: "Alpha", body: "The protagonist.\n"),
            (id: "b", title: "Beta",
             body: "See [[Alpha]] for the backstory.\n"),
        ])
        let store = try await ProjectStore.load(from: project)
        let ds = try await DocumentStore.open(url: project)
        store.documentStore = ds
        // B is NOT registered: it is a CLOSED target.

        // Snapshot B's op count before the rename. A freshly-bootstrapped doc
        // has its bootstrap op; the rewrite must ADD an op on top of that.
        let bPath = path(of: store, id: "b")
        let bURL = project.appendingPathComponent(bPath)
        let opsBefore: Int = try await {
            let probe = try await Document.load(
                url: bURL, device: "probe", session: "probe", presenter: nil)
            let n = (try await probe.opLog()).count
            await probe.close()
            return n
        }()

        try await store.renameStructureItem(id: "a", newTitle: "Omega")

        // 1. B's op log carries the rewrite (a NON-bootstrap op was appended).
        let freshB = try await Document.load(
            url: bURL, device: "verify", session: "verify", presenter: nil)
        let opsAfter = try await freshB.opLog()
        XCTAssertGreaterThan(
            opsAfter.count, opsBefore,
            "Rename must append a rewrite op to closed doc B's op log, " +
            "not bypass it with a raw disk write.")
        XCTAssertTrue(
            opsAfter.contains(where: { $0.kind != .bootstrap }),
            "B's op log must contain a real edit op (not only bootstrap).")

        // 2. B's derived display text shows the new title.
        XCTAssertEqual(
            freshB.displayText,
            "See [[Omega]] for the backstory.")

        // 3. .md and op log are consistent — a SECOND fresh load (which
        //    reconciles the on-disk .md against the op log) derives the same
        //    text with no divergence/clobber.
        await freshB.close()
        let reloadB = try await Document.load(
            url: bURL, device: "verify2", session: "verify2", presenter: nil)
        XCTAssertEqual(
            reloadB.displayText,
            "See [[Omega]] for the backstory.",
            "Fresh reload must derive the rewritten link with no reconcile " +
            "divergence between the .md and the op log.")
        await reloadB.close()
    }

    // MARK: - Open target (anti-clobber)

    func test_openTarget_liveDocumentReflectsRewriteWithoutClobber() async throws {
        let project = try makeProject(docs: [
            (id: "a", title: "Alpha", body: "The protagonist.\n"),
            (id: "b", title: "Beta",
             body: "See [[Alpha]] for the backstory.\n"),
        ])
        let store = try await ProjectStore.load(from: project)
        let ds = try await DocumentStore.open(url: project)
        store.documentStore = ds

        // B is OPEN: a live Document registered in the DocumentStore.
        let bPath = path(of: store, id: "b")
        let bURL = project.appendingPathComponent(bPath)
        let liveB = try await Document.load(
            url: bURL, device: "live", session: "live",
            presenter: ds.presenter)
        ds.register(document: liveB, for: bPath)

        let opsBefore = (try await liveB.opLog()).count

        try await store.renameStructureItem(id: "a", newTitle: "Omega")

        // The SAME live instance reflects the new title (not clobbered by a
        // raw underneath-write of the old anchored bytes).
        XCTAssertEqual(
            liveB.displayText,
            "See [[Omega]] for the backstory.",
            "The live open Document must reflect the rewrite in displayText.")

        // An op was appended to the live doc's log (routed through setFullText,
        // flushed by close()). Flush the burst so the assertion is timing-safe.
        try await liveB.flushBurstNow()
        let opsAfter = (try await liveB.opLog()).count
        XCTAssertGreaterThan(
            opsAfter, opsBefore,
            "Rewriting an open doc must append an op, not bypass the op log.")

        await liveB.close()
    }

    // MARK: - Statements (S2)

    /// S2 (2026-08-02 sweep): renaming a document silently flipped a statement's
    /// `[[chapter]]` to unresolved while the graph tools kept listing it. The
    /// statement is a `Document`; the rewrite must arrive as ops.
    func test_renameRewritesLinksInsideAClosedStatement() async throws {
        let root = try makeProject(docs: [
            (id: "a", title: "Alpha", body: "The chapter."),
            (id: "b", title: "Beta", body: "Another.")])
        let store = try await ProjectStore.load(from: root)
        let statement = try await store.createStatement(kind: .intent, scope: .project)
        try await store.appendToStatement("Open with [[Alpha]].", to: statement,
                                          session: "test")

        try await store.renameStructureItem(id: "a", newTitle: "Omega")

        XCTAssertTrue(store.statementText(of: statement).contains("[[Omega]]"),
                      "the statement still says: \(store.statementText(of: statement))")
        XCTAssertFalse(store.statementText(of: statement).contains("[[Alpha]]"))
        let ops = OpLogStore.loadSyncMerged(forDocId: statement.id, in: root)
        XCTAssertTrue(ops.contains { op in
            op.changes.contains { $0.next.contains("[[Omega]]") }
        }, "the rewrite must be IN the op log, not a raw file write")
    }

    /// The live-pane arm: a statement open in the Plan persona's right column
    /// while the writer renames in the binder — an ordinary act, since Intent is
    /// a pane of the persona whose centre column is the canvas and the binder is
    /// its left one.
    ///
    /// The rewrite has to reach the `Document` **the pane is holding**. Loading
    /// a second one on the same path costs the writer the rewrite rather than
    /// merely duplicating work: each has its own `PendingBuffer`, and the pane's
    /// next burst writes its own stale `[[Alpha]]` back out over the rewrite.
    /// So the assertion is on the live instance first, and then on what the
    /// statement says once that pane has typed again and flushed.
    func test_renameRewritesLinksInsideAnOpenStatement() async throws {
        let root = try makeProject(docs: [
            (id: "a", title: "Alpha", body: "The chapter."),
            (id: "b", title: "Beta", body: "Another.")])
        let store = try await ProjectStore.load(from: root)
        let ds = try await DocumentStore.open(url: root)
        store.documentStore = ds
        let statement = try await store.createStatement(kind: .intent, scope: .project)
        try await store.appendToStatement("Open with [[Alpha]].", to: statement,
                                          session: "test")

        // Stand in for the Intent pane, through the store's own open seam
        // rather than a bare load: the gate around the load and the
        // registration is what `StatementEditorHost.load` does, and the
        // registration is the only way anything else can find this `Document`
        // (a statement is in no `DocumentStore` registry by design).
        await store.lockStatementOpen(statement.id)
        let pane = try await Document.load(
            url: root.appendingPathComponent(statement.path),
            device: MacDeviceID.current, session: "pane-test",
            presenter: ds.presenter)
        store.noteStatementDocumentOpened(pane, id: statement.id)
        store.unlockStatementOpen(statement.id)

        try await store.renameStructureItem(id: "a", newTitle: "Omega")

        XCTAssertTrue(
            pane.displayText.contains("[[Omega]]"),
            "the rewrite went into a SECOND Document on this path — the pane "
            + "cannot see it, so its next burst writes it out — found: "
            + pane.displayText)

        // The act that turns "merely odd" into lost work: the writer types on.
        pane.setFullText(pane.displayText + "\n\nTyped after.")
        try await pane.flushBurstNow()

        let text = store.statementText(of: statement)
        XCTAssertTrue(text.contains("[[Omega]]"),
                      "the pane's next burst wrote the rename back out — "
                      + "found: \(text)")
        XCTAssertFalse(text.contains("[[Alpha]]"), "found: \(text)")
        XCTAssertTrue(text.contains("Typed after."), "found: \(text)")

        store.forgetStatementDocument(id: statement.id)
        await pane.close()
        await ds.close()
    }

    /// The statement whose PROSE is only in its file, and whose op log does not
    /// exist yet — the shape a freshly promoted project arrives in
    /// (`stagePromotedIntent` moves the `.md` and leaves `.maugham/` behind, so
    /// the new project re-bootstraps from the rendered file on first open).
    ///
    /// The pre-check's derived read answers "" for it, and a pre-check that
    /// skipped on emptiness alone would leave the writer's intent saying the old
    /// name for ever — the manuscript loop has carried the same fall-through
    /// since it was written, for the same reason.
    func test_renameRewritesAStatementWhoseWordsAreOnlyInItsFile() async throws {
        let root = try makeProject(
            docs: [(id: "a", title: "Alpha", body: "The chapter.")],
            statements: [Statement(id: "stmt-cold", kind: .intent,
                                   scope: .project, path: "intent.md")])
        try "Open with [[Alpha]].\n".write(
            to: root.appendingPathComponent("intent.md"),
            atomically: true, encoding: .utf8)
        let store = try await ProjectStore.load(from: root)
        let statement = try XCTUnwrap(store.manifest.statements.first)

        // The premise, asserted rather than assumed: nothing has bootstrapped
        // this statement, so the only text about it the pre-check can see is
        // empty — and no pane holds a fresher one.
        XCTAssertTrue(
            store.derivedCache.displayText(forDocId: statement.id, in: root).isEmpty,
            "this test is only about a COLD statement; the derive answered "
            + "something, so it no longer reproduces the shape it is named for")

        try await store.renameStructureItem(id: "a", newTitle: "Omega")

        let text = store.statementText(of: statement)
        XCTAssertTrue(text.contains("[[Omega]]"),
                      "an empty derive skipped a statement whose file has "
                      + "prose in it — found: \(text)")
        XCTAssertFalse(text.contains("[[Alpha]]"), "found: \(text)")
    }

    // MARK: - Research notes (S2)

    /// The research-note half — pre-existing since 1C-c2, and recorded rather
    /// than fixed at the time (`Maugham/Canvas/AREA.md`): canvas promotion
    /// writes `[[…]]` into a research note and never into a manuscript, so a
    /// rename left exactly the links promotion had just made pointing nowhere.
    ///
    /// A research note is not op-logged, so the rewrite is a coordinated file
    /// write behind a flush rather than an op.
    func test_renameRewritesLinksInsideAResearchNoteBody() async throws {
        let root = try makeProject(docs: [
            (id: "a", title: "Alpha", body: "The chapter."),
            (id: "b", title: "Beta", body: "Another.")])
        let store = try await ProjectStore.load(from: root)
        let ds = try await DocumentStore.open(url: root)
        store.documentStore = ds

        let note = try await store.addResearchTextNote(
            parentId: nil, title: "Fog notes")
        let notePath = try XCTUnwrap(note.path)
        let noteURL = root.appendingPathComponent(notePath)
        try "Promoted from the canvas. See [[Alpha]].\n".write(
            to: noteURL, atomically: true, encoding: .utf8)

        try await store.renameStructureItem(id: "a", newTitle: "Omega")

        let body = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertTrue(body.contains("[[Omega]]"),
                      "the research note still says: \(body)")
        XCTAssertFalse(body.contains("[[Alpha]]"), "found: \(body)")

        await ds.close()
    }

    // MARK: - Composed statement titles (S2)

    /// The composed-title rule: a statement's NAME embeds its document's
    /// (`ArtifactIndex.statementTitle`), so renaming the document moves the
    /// statement's title too, and every `[[Craft Intent · Alpha]]` in the
    /// project has to move with it.
    ///
    /// **The link is planted in the RENAMED document's own body, deliberately.**
    /// The manuscript loop excludes the renamed document because its own
    /// `[[Alpha]]` self-references are handled by the resolver's title match on
    /// the next render — an argument about the document's OWN title, which says
    /// nothing about the title of a statement about it. `[[Craft Intent ·
    /// Alpha]]` resolves to nothing at all once the rename lands, wherever it
    /// was written.
    func test_renameRewritesComposedStatementTitleLinks() async throws {
        let root = try makeProject(docs: [
            (id: "a", title: "Alpha", body: "See [[Craft Intent · Alpha]]."),
            (id: "b", title: "Beta", body: "Nothing here.")])
        let store = try await ProjectStore.load(from: root)
        _ = try await store.createStatement(kind: .intent, scope: .document("a"))

        try await store.renameStructureItem(id: "a", newTitle: "Omega")

        let rewritten = store.derivedCache.materialize(forDocId: "a", in: root)
        XCTAssertTrue(rewritten.contains("[[Craft Intent · Omega]]"),
                      "found: \(rewritten)")
        XCTAssertFalse(rewritten.contains("[[Craft Intent · Alpha]]"),
                       "found: \(rewritten)")
    }

    /// The other side of the same rule: the composed title moves in a document
    /// that is NOT the renamed one either, and it moves alongside the plain
    /// document-title rewrite rather than instead of it.
    func test_composedTitleAndDocumentTitleBothMoveInAnotherDocument() async throws {
        let root = try makeProject(docs: [
            (id: "a", title: "Alpha", body: "The chapter."),
            (id: "b", title: "Beta",
             body: "See [[Alpha]] and [[Craft Intent · Alpha]].")])
        let store = try await ProjectStore.load(from: root)
        _ = try await store.createStatement(kind: .intent, scope: .document("a"))

        try await store.renameStructureItem(id: "a", newTitle: "Omega")

        let rewritten = store.derivedCache.displayText(forDocId: "b", in: root)
        XCTAssertTrue(rewritten.contains("[[Omega]]"), "found: \(rewritten)")
        XCTAssertTrue(rewritten.contains("[[Craft Intent · Omega]]"),
                      "found: \(rewritten)")
        XCTAssertFalse(rewritten.contains("Alpha"), "found: \(rewritten)")
    }
}
