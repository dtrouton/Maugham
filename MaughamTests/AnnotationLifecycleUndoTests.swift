import XCTest
import MaughamCore
@testable import Maugham

/// Mutable holder for a bridged async result (all access is MainActor-confined
/// within a single test, so `@unchecked Sendable` is sound here).
private final class LifecycleResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// ⌘Z undo of the *non-text* annotation resolutions: reject / archive /
/// withdraw / edit. Unlike accept (which mutates the manuscript and lives in
/// its own regression-scarred path), these only append lifecycle/edit ops, so
/// their undo goes through the shared `OpUndoRegistrar` and the compensating
/// `reopenAnnotation` / `AnnotationInverse.editRevertOp` factory ops.
///
/// Synchronous XCTest methods, same idiom as `AnnotationAcceptUndoTests`:
/// `NSUndoManager.undo()` runs its handler synchronously and the handler hops
/// the async op-append onto a task; the run loop is pumped so that task lands.
@MainActor
final class AnnotationLifecycleUndoTests: XCTestCase {

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
            .appendingPathComponent("ALU-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId = "doc-lifecycle-undo-test"
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

    @discardableResult
    private func bridge<T>(
        timeout: TimeInterval = 15, _ body: @escaping @MainActor () async throws -> T
    ) throws -> T {
        let box = LifecycleResultBox<T>()
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
    /// `.open` only, which would hide a resolved one).
    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    /// Add a plain comment (no manuscript-text mutation) and return its op id.
    private func addComment(_ doc: Document, _ pid: String, body: String) throws -> String {
        try bridge {
            try await doc.addAnnotation(kind: .comment, paragraphId: pid, body: body)
        }
    }

    // MARK: - Tests

    func test_reject_undo_reopens() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "A single paragraph.") }
        let doc = h.doc
        let cid = try addComment(doc, h.pid, body: "note")
        let um = UndoManager()

        try bridge { try await doc.rejectAnnotation(id: cid, userResponse: "no", undoManager: um) }
        // **Fixed on purpose, and the one wait in this file worth explaining.**
        // The op append AND the undo registration both completed inside
        // `bridge`, so the status below is already settled — the only thing
        // this wait ever buys is `groupsByEvent` closing the event group, so
        // `undo()` has a group to pop. That close is not readable as a value.
        // `canUndo` is not it: it reads true the instant `registerUndo` runs,
        // while the group is still open. `groupingLevel` looks like it should
        // be it, but measured 2026-08-08 a `waitUntil { um.canUndo &&
        // um.groupingLevel == 0 }` here never goes true and burns its whole
        // deadline — converting these sites cost the four undo suites +81s
        // against a 8.3s baseline, all of it timeout. So: a window, not a poll.
        pumpFor(0.25)  // fixed window: the event-group close — see the note above
        XCTAssertEqual(annotation(doc, cid)?.status, .rejected)
        XCTAssertTrue(um.canUndo)

        um.undo()
        waitUntil { self.annotation(doc, cid)?.status == .open }
        XCTAssertEqual(annotation(doc, cid)?.status, .open)
        XCTAssertEqual(doc._opLogMirror.last?.kind, .annotationReopen)

        um.removeAllActions()
        try bridge { await h.documentStore.close() }
    }

    func test_reject_undo_redo_reRejects_preservingUserResponse() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "A single paragraph.") }
        let doc = h.doc
        let cid = try addComment(doc, h.pid, body: "note")
        let um = UndoManager()

        try bridge { try await doc.rejectAnnotation(id: cid, userResponse: "no", undoManager: um) }
        pumpFor(0.25)  // fixed window: the event-group close
        um.undo()
        waitUntil { self.annotation(doc, cid)?.status == .open }
        XCTAssertTrue(um.canRedo, "reject-undo must nest a re-reject onto the redo stack")

        um.redo()
        waitUntil { self.annotation(doc, cid)?.status == .rejected }
        XCTAssertEqual(annotation(doc, cid)?.status, .rejected)
        XCTAssertEqual(annotation(doc, cid)?.userResponse, "no",
            "redo's re-reject must forward the original userResponse")

        // Re-arm: redo forwards the LIVE undo manager into the forward
        // re-reject, which registers a FRESH undo pair — ⌘Z/⇧⌘Z cycles
        // indefinitely (accept's precedent), not a dead action after one redo.
        // let the re-registration's event group close
        pumpFor(0.25)  // fixed window: the event-group close
        XCTAssertTrue(um.canUndo,
            "redo's forward re-reject must re-register undo — the cycle re-arms")

        um.undo()
        waitUntil { self.annotation(doc, cid)?.status == .open }
        XCTAssertEqual(annotation(doc, cid)?.status, .open,
            "a second ⌘Z after ⇧⌘Z must reopen again")

        um.removeAllActions()
        try bridge { await h.documentStore.close() }
    }

    func test_archive_undo_reopens() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "A single paragraph.") }
        let doc = h.doc
        let cid = try addComment(doc, h.pid, body: "note")
        let um = UndoManager()

        try bridge { try await doc.archiveAnnotation(id: cid, undoManager: um) }
        pumpFor(0.25)  // fixed window: the event-group close
        XCTAssertEqual(annotation(doc, cid)?.status, .archived)

        um.undo()
        waitUntil { self.annotation(doc, cid)?.status == .open }
        XCTAssertEqual(annotation(doc, cid)?.status, .open)
        XCTAssertEqual(doc._opLogMirror.last?.kind, .annotationReopen)

        um.removeAllActions()
        try bridge { await h.documentStore.close() }
    }

    func test_withdraw_undo_restoresAnnotation() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "A single paragraph.") }
        let doc = h.doc
        // Withdraw is author self-service on a human-authored annotation.
        let cid = try bridge {
            try await doc.addReviewerAnnotation(
                kind: .comment, paragraphId: h.pid, span: nil,
                body: "reviewer note", authorName: "Denver")
        }
        let um = UndoManager()

        try bridge { try await doc.withdrawReviewerAnnotation(
            id: cid, authorName: "Denver", undoManager: um) }
        pumpFor(0.25)  // fixed window: the event-group close
        XCTAssertNil(annotation(doc, cid), "withdraw drops it from the projection")

        um.undo()
        waitUntil { self.annotation(doc, cid)?.status == .open }
        XCTAssertEqual(annotation(doc, cid)?.status, .open, "undo of withdraw restores it")
        XCTAssertEqual(doc._opLogMirror.last?.kind, .annotationReopen)

        um.removeAllActions()
        try bridge { await h.documentStore.close() }
    }

    /// RULING-22 / M5-AN-036 — the withdraw's ⌘Z gives back the annotation and
    /// NOTHING ELSE. `annotationReopen` is one op kind serving two inverses and
    /// `AnnotationDeriver` honours it through both its passes, so undoing
    /// "delete my annotation" used to cancel an archive the writer had made
    /// separately and never asked to undo: one ⌘Z taking two of their
    /// decisions. The note comes back ARCHIVED, which is how they left it.
    func test_withdraw_undo_returnsAnArchivedNoteArchived() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "A single paragraph.") }
        let doc = h.doc
        let cid = try bridge {
            try await doc.addReviewerAnnotation(
                kind: .comment, paragraphId: h.pid, span: nil,
                body: "reviewer note", authorName: "Denver")
        }
        try bridge { try await doc.archiveAnnotation(id: cid) }
        XCTAssertEqual(annotation(doc, cid)?.status, .archived,
                       "precondition: the writer archived it themselves")

        let um = UndoManager()
        try bridge { try await doc.withdrawReviewerAnnotation(
            id: cid, authorName: "Denver", undoManager: um) }
        pumpFor(0.25)  // fixed window: the event-group close
        XCTAssertNil(annotation(doc, cid))

        um.undo()
        waitUntil { self.annotation(doc, cid) != nil }
        XCTAssertEqual(annotation(doc, cid)?.status, .archived,
                       "the archive the writer never undid is still theirs")

        um.removeAllActions()
        try bridge { await h.documentStore.close() }
    }

    /// Same rule for a rejection — and the reason they wrote comes back with
    /// it, because a resolution restored without its reason is a different
    /// resolution.
    func test_withdraw_undo_returnsARejectedNoteRejected_withItsReason() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "A single paragraph.") }
        let doc = h.doc
        let cid = try bridge {
            try await doc.addReviewerAnnotation(
                kind: .comment, paragraphId: h.pid, span: nil,
                body: "reviewer note", authorName: "Denver")
        }
        try bridge { try await doc.rejectAnnotation(
            id: cid, userResponse: "not in this scene") }

        let um = UndoManager()
        try bridge { try await doc.withdrawReviewerAnnotation(
            id: cid, authorName: "Denver", undoManager: um) }
        pumpFor(0.25)

        um.undo()
        waitUntil { self.annotation(doc, cid) != nil }
        XCTAssertEqual(annotation(doc, cid)?.status, .rejected)
        XCTAssertEqual(annotation(doc, cid)?.userResponse, "not in this scene")

        um.removeAllActions()
        try bridge { await h.documentStore.close() }
    }

    /// The control, and the reason this is a status CAPTURE rather than a
    /// change to the reopen factory: reopening an ARCHIVED annotation directly
    /// — the pane's own Reopen, and the phone's — still means open. Only the
    /// withdraw's undo carries the extra obligation, and only the Mac has
    /// undo, so `AnnotationInverse` (cross-surface, tripwire 19) is untouched.
    func test_aDirectReopenOfAnArchivedNoteStillOpensIt() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "A single paragraph.") }
        let doc = h.doc
        let cid = try bridge {
            try await doc.addReviewerAnnotation(
                kind: .comment, paragraphId: h.pid, span: nil,
                body: "reviewer note", authorName: "Denver")
        }
        try bridge { try await doc.archiveAnnotation(id: cid) }
        try bridge { try await doc.reopenAnnotation(id: cid) }
        XCTAssertEqual(annotation(doc, cid)?.status, .open)

        try bridge { await h.documentStore.close() }
    }

    func test_edit_undo_restoresPriorBody() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "A single paragraph.") }
        let doc = h.doc
        let originalBody = "reviewer note"
        let cid = try bridge {
            try await doc.addReviewerAnnotation(
                kind: .comment, paragraphId: h.pid, span: nil,
                body: originalBody, authorName: "Denver")
        }
        let um = UndoManager()

        try bridge { try await doc.editReviewerAnnotation(
            id: cid, newBody: "new", newSuggestedText: nil,
            authorName: "Denver", undoManager: um) }
        pumpFor(0.25)  // fixed window: the event-group close
        XCTAssertEqual(annotation(doc, cid)?.body, "new")

        um.undo()
        waitUntil { self.annotation(doc, cid)?.body == originalBody }
        XCTAssertEqual(annotation(doc, cid)?.body, originalBody)

        um.redo()
        waitUntil { self.annotation(doc, cid)?.body == "new" }
        XCTAssertEqual(annotation(doc, cid)?.body, "new")

        um.removeAllActions()
        try bridge { await h.documentStore.close() }
    }

    func test_reopen_onDriftedStatus_isLoudNoOp() throws {
        let h = try bridge { try await self.makeHarness(initialMd: "A single paragraph.") }
        let doc = h.doc
        let cid = try addComment(doc, h.pid, body: "note")
        let um = UndoManager()

        try bridge { try await doc.rejectAnnotation(id: cid, userResponse: nil, undoManager: um) }
        pumpFor(0.25)  // fixed window: the event-group close
        // Simulate another device already reopening it.
        try bridge { try await doc.reopenAnnotation(id: cid) }
        XCTAssertEqual(annotation(doc, cid)?.status, .open)
        let opCount = doc._opLogMirror.count

        // The stale undo action must decline: status is already .open, not .rejected.
        um.undo()
        pumpFor(0.3)  // fixed window: asserting nothing happens (no op appended)
        XCTAssertEqual(doc._opLogMirror.count, opCount,
            "a stale reopen-undo on already-open status must append nothing")

        um.removeAllActions()
        try bridge { await h.documentStore.close() }
    }
}
