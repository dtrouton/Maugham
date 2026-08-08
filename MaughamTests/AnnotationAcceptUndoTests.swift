import XCTest
import MaughamCore
@testable import Maugham

/// Mutable holder for a bridged async result (all access is MainActor-confined
/// within a single test, so `@unchecked Sendable` is sound here).
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// ⌘Z undo of an accepted suggestion. Accepting a suggestion appends a
/// `claudeAccept` op and mutates the paragraph; the undo registered on accept
/// appends a `claudeAcceptRevert` op that restores the text and returns the
/// annotation to `.open` (AnnotationDeriver). Redo re-accepts via a nested
/// registration made synchronously inside the undo closure (so NSUndoManager
/// routes it to the redo stack).
///
/// These are **synchronous** XCTest methods, deliberately. `NSUndoManager.undo()`
/// runs its handler synchronously and the handler hops the async revert onto a
/// detached task; the run loop is pumped (`pump` / `waitUntil`) to let that task
/// land, exactly as the AppKit responder chain drives undo in the running app.
/// The undo manager uses default `groupsByEvent` (true, like an NSTextView's) —
/// `acceptAnnotation` calls `removeAllActions()` up front, and doing that inside
/// a MANUAL `beginUndoGrouping` corrupts NSUndoManager's grouping state, so these
/// tests deliberately do NOT open a manual group (production never does either).
@MainActor
final class AnnotationAcceptUndoTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let documentStore: DocumentStore
        let doc: Document
        let pid: String
    }

    /// Builds a wired Document (ProjectStore + DocumentStore) over `initialMd`,
    /// returning the doc + its single bootstrap paragraph id (4-char
    /// alphabet-restricted, tripwire 8).
    private func makeHarness(initialMd: String) async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AAU-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId = "doc-accept-undo-test"
        try initialMd.write(
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
        let ds = try await DocumentStore.open(url: tmp)
        pStore.documentStore = ds

        let doc = try await Document.load(
            url: tmp.appendingPathComponent(docPath),
            device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: docPath)

        let pid = try await doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId
        return Harness(documentStore: ds, doc: doc, pid: pid)
    }

    // MARK: - Sync ⟷ async bridges

    /// Run an async body to completion from a synchronous test, pumping the main
    /// run loop via `wait(for:)` so MainActor-hopped continuations progress.
    @discardableResult
    private func bridge<T>(
        timeout: TimeInterval = 15, _ body: @escaping @MainActor () async throws -> T
    ) throws -> T {
        let box = ResultBox<T>()
        let exp = expectation(description: "async-bridge")
        Task { @MainActor in
            do { box.result = .success(try await body()) }
            catch { box.result = .failure(error) }
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        return try box.result!.get()
    }

    /// The annotation with `id`, across ALL statuses (`annotations()` defaults to
    /// `.open` only, which would hide an accepted one).
    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    // MARK: - Tests

    func test_acceptRegistersUndo_undoRestoresTextAndReopens() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "The night was very dark and stormy.") }
        let doc = h.doc, pid = h.pid
        let annId = try bridge {
            try await doc.addAnnotation(
                kind: .suggestedChange, paragraphId: pid,
                body: "stronger", suggestedText: "pitch-black",
                span: SpanAnchor(quote: "very dark", prefix: "was ", suffix: " and", posHint: 14))
        }
        let um = UndoManager()
        try bridge { try await doc.acceptAnnotation(id: annId, undoManager: um) }
        // let the default event group close so undo() has a group to pop.
        // **Fixed on purpose.** The splice and the registration both completed
        // inside `bridge`, so the assertions below are already settled — the
        // only thing left to wait for is `groupsByEvent` closing the event
        // group, and that close is not readable as a value. `canUndo` is not
        // it (true the instant `registerUndo` runs, group still open), and
        // measured 2026-08-08 neither is `groupingLevel`: a
        // `waitUntil { um.canUndo && um.groupingLevel == 0 }` here never goes
        // true and burns its whole deadline. A window, not a poll.
        pumpFor(0.25)  // fixed window: the event-group close — see the note above

        XCTAssertEqual(doc.paragraph(id: pid), "The night was pitch-black and stormy.")
        XCTAssertTrue(doc.consumeUndoCoherentApplyFlag(), "accept must flag the next external apply as undo-coherent")
        XCTAssertTrue(um.canUndo)

        um.undo()
        waitUntil { doc.paragraph(id: pid) == "The night was very dark and stormy." }
        XCTAssertEqual(doc.paragraph(id: pid), "The night was very dark and stormy.")
        XCTAssertEqual(annotation(doc, annId)?.status, .open)

        um.removeAllActions()                         // drop the undo-stack Document retain
        try bridge { await h.documentStore.close() }  // tear down the autosave scheduler
    }

    func test_undoThenRedo_reAccepts() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "The night was very dark and stormy.") }
        let doc = h.doc, pid = h.pid
        let annId = try bridge {
            try await doc.addAnnotation(
                kind: .suggestedChange, paragraphId: pid,
                body: "stronger", suggestedText: "pitch-black",
                span: SpanAnchor(quote: "very dark", prefix: "was ", suffix: " and", posHint: 14))
        }
        let um = UndoManager()
        try bridge { try await doc.acceptAnnotation(id: annId, userResponse: "looks right", undoManager: um) }
        pumpFor(0.25)  // fixed window: the event-group close

        um.undo()
        waitUntil { self.annotation(doc, annId)?.status == .open }
        XCTAssertEqual(annotation(doc, annId)?.status, .open)
        XCTAssertTrue(um.canRedo, "revert must nest a re-accept registration onto the redo stack")

        um.redo()
        waitUntil { doc.paragraph(id: pid) == "The night was pitch-black and stormy." }
        XCTAssertEqual(doc.paragraph(id: pid), "The night was pitch-black and stormy.")
        XCTAssertEqual(annotation(doc, annId)?.status, .accepted)
        XCTAssertEqual(annotation(doc, annId)?.userResponse, "looks right",
            "redo's re-accept must forward the original accept's userResponse — "
            + "dropping it loses the writer's reply after ⌘Z + ⇧⌘Z")

        um.removeAllActions()
        try bridge { await h.documentStore.close() }
    }

    func test_revertOnNonAcceptedAnnotation_isLoudNoOp() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "Some text here.") }
        let doc = h.doc, pid = h.pid
        let annId = try bridge {
            try await doc.addAnnotation(
                kind: .suggestedChange, paragraphId: pid,
                body: "b", suggestedText: "Other text here.")
        }
        let textBefore = doc.paragraph(id: pid)
        try bridge { try await doc.revertAcceptedAnnotation(id: annId, undoManager: nil) }  // never accepted
        XCTAssertEqual(doc.paragraph(id: pid), textBefore)
        XCTAssertEqual(annotation(doc, annId)?.status, .open)

        try bridge { await h.documentStore.close() }
    }

    func test_acceptWithoutUndoManager_setsNoFlag() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "Some text here.") }
        let doc = h.doc, pid = h.pid
        let annId = try bridge {
            try await doc.addAnnotation(
                kind: .suggestedChange, paragraphId: pid,
                body: "b", suggestedText: "Other text here.")
        }
        try bridge { try await doc.acceptAnnotation(id: annId) }
        XCTAssertFalse(doc.consumeUndoCoherentApplyFlag())

        try bridge { await h.documentStore.close() }
    }

    /// ⌘Z depth-1 is a PINNED CONTRACT: each accept clears stale typing
    /// actions up front (the ⌘Z-crash fix), and with them any PRIOR accept's
    /// registration — so ⌘Z reaches only the MOST RECENT accept. Reaching an
    /// older accepted suggestion is the Annotations pane's Revert button
    /// (see `test_paneRevert_isUndoable_reacceptPreservesUserResponse`).
    func test_undoDepthIsOne_secondAcceptClearsFirstRegistration() throws {
        let h = try bridge { try await self.makeHarness(
            initialMd: "Para one stands.\n\nPara two stands.") }
        let doc = h.doc
        let pids = doc.sequence
        XCTAssertEqual(pids.count, 2)
        let (pid1, pid2) = (pids[0], pids[1])

        let ann1 = try bridge {
            try await doc.addAnnotation(
                kind: .suggestedChange, paragraphId: pid1,
                body: "b1", suggestedText: "Para one changed.")
        }
        let ann2 = try bridge {
            try await doc.addAnnotation(
                kind: .suggestedChange, paragraphId: pid2,
                body: "b2", suggestedText: "Para two changed.")
        }
        let um = UndoManager()
        try bridge { try await doc.acceptAnnotation(id: ann1, undoManager: um) }
        // Load-bearing between the two accepts, not just before the undo:
        // accept 2's up-front `removeAllActions()` must NOT fire inside accept
        // 1's still-open event group (that is the documented NSUndoManager
        // corruption). No value reports that close, so this is a window.
        pumpFor(0.25)  // fixed window: the event-group close
        try bridge { try await doc.acceptAnnotation(id: ann2, undoManager: um) }
        pumpFor(0.25)  // fixed window: the event-group close
        XCTAssertEqual(doc.paragraph(id: pid1), "Para one changed.")
        XCTAssertEqual(doc.paragraph(id: pid2), "Para two changed.")

        um.undo()
        waitUntil { self.annotation(doc, ann2)?.status == .open }
        XCTAssertEqual(doc.paragraph(id: pid2), "Para two stands.",
            "⌘Z must revert the most recent accept")
        XCTAssertEqual(annotation(doc, ann2)?.status, .open)
        XCTAssertEqual(annotation(doc, ann1)?.status, .accepted,
            "the older accept is out of ⌘Z's reach (depth-1 contract)")
        XCTAssertEqual(doc.paragraph(id: pid1), "Para one changed.")
        XCTAssertFalse(um.canUndo,
            "accept 2's up-front clear removed accept 1's registration — depth-1 is pinned")

        um.removeAllActions()
        try bridge { await h.documentStore.close() }
    }

    /// Drift detector behind the pane's Revert confirm: true iff the paragraph
    /// text changed since the accept (revert would clobber those edits).
    /// Whitespace-exact comparison, same as the underlying data.
    func test_acceptedTextDrifted_falseAfterAccept_trueAfterEdit() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "Alpha text stands.") }
        let doc = h.doc, pid = h.pid
        let annId = try bridge {
            try await doc.addAnnotation(
                kind: .suggestedChange, paragraphId: pid,
                body: "b", suggestedText: "Beta text stands.")
        }
        XCTAssertFalse(doc.acceptedTextDrifted(annotationId: annId),
            "not yet accepted → no drift (revert itself no-ops that case)")

        try bridge { try await doc.acceptAnnotation(id: annId) }
        XCTAssertFalse(doc.acceptedTextDrifted(annotationId: annId),
            "accepted, no subsequent edit → no drift")

        doc.setParagraph(id: pid, text: "Beta text stands, but edited since.")
        XCTAssertTrue(doc.acceptedTextDrifted(annotationId: annId),
            "post-accept edit → drift; the pane must confirm before reverting over it")

        try bridge { await h.documentStore.close() }
    }

    /// A DIRECT pane-revert (Revert button — not via ⌘Z) must itself be
    /// ⌘Z-undoable: undo re-accepts, and the re-accept carries the reverted
    /// accept op's original userResponse.
    func test_paneRevert_isUndoable_reacceptPreservesUserResponse() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "Original text here.") }
        let doc = h.doc, pid = h.pid
        let annId = try bridge {
            try await doc.addAnnotation(
                kind: .suggestedChange, paragraphId: pid,
                body: "b", suggestedText: "Replacement text here.")
        }
        let um = UndoManager()
        try bridge { try await doc.acceptAnnotation(
            id: annId, userResponse: "keep it", undoManager: um) }
        // Load-bearing before the revert below, which does its own up-front
        // `removeAllActions()` — that must not fire inside the accept's
        // still-open event group.
        pumpFor(0.25)  // fixed window: the event-group close
        XCTAssertEqual(doc.paragraph(id: pid), "Replacement text here.")

        // Direct revert with the window's manager — the pane path.
        try bridge { try await doc.revertAcceptedAnnotation(
            id: annId, undoManager: um) }
        pumpFor(0.25)  // fixed window: the event-group close
        XCTAssertEqual(doc.paragraph(id: pid), "Original text here.")
        XCTAssertEqual(annotation(doc, annId)?.status, .open)
        XCTAssertTrue(doc.consumeUndoCoherentApplyFlag(),
            "pane-revert must flag the next external apply as undo-coherent")
        XCTAssertTrue(um.canUndo, "pane-revert must register a re-accept undo action")

        um.undo()
        waitUntil { self.annotation(doc, annId)?.status == .accepted }
        XCTAssertEqual(doc.paragraph(id: pid), "Replacement text here.")
        XCTAssertEqual(annotation(doc, annId)?.status, .accepted)
        XCTAssertEqual(annotation(doc, annId)?.userResponse, "keep it",
            "undo of a pane-revert must restore the original accept's userResponse")

        um.removeAllActions()
        try bridge { await h.documentStore.close() }
    }
}
