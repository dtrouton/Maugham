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

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func waitUntil(
        _ predicate: @MainActor () -> Bool, timeout: TimeInterval = 3
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
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
        pump(0.25)
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
        pump(0.25)
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
        pump(0.25)  // let the re-registration's event group close
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
        pump(0.25)
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
        pump(0.25)
        XCTAssertNil(annotation(doc, cid), "withdraw drops it from the projection")

        um.undo()
        waitUntil { self.annotation(doc, cid)?.status == .open }
        XCTAssertEqual(annotation(doc, cid)?.status, .open, "undo of withdraw restores it")
        XCTAssertEqual(doc._opLogMirror.last?.kind, .annotationReopen)

        um.removeAllActions()
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
        pump(0.25)
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
        pump(0.25)
        // Simulate another device already reopening it.
        try bridge { try await doc.reopenAnnotation(id: cid) }
        XCTAssertEqual(annotation(doc, cid)?.status, .open)
        let opCount = doc._opLogMirror.count

        // The stale undo action must decline: status is already .open, not .rejected.
        um.undo()
        pump(0.3)
        XCTAssertEqual(doc._opLogMirror.count, opCount,
            "a stale reopen-undo on already-open status must append nothing")

        um.removeAllActions()
        try bridge { await h.documentStore.close() }
    }
}
