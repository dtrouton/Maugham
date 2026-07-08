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

    /// Spin the main run loop for a fixed interval (services the MainActor
    /// executor + the groupsByEvent group-close observer).
    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Pump the main run loop until `predicate` holds (or `timeout` elapses).
    private func waitUntil(
        _ predicate: @MainActor () -> Bool, timeout: TimeInterval = 3
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
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
        pump(0.25)  // let the default event group close so undo() has a group to pop

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
        try bridge { try await doc.acceptAnnotation(id: annId, undoManager: um) }
        pump(0.25)

        um.undo()
        waitUntil { self.annotation(doc, annId)?.status == .open }
        XCTAssertEqual(annotation(doc, annId)?.status, .open)
        XCTAssertTrue(um.canRedo, "revert must nest a re-accept registration onto the redo stack")

        um.redo()
        waitUntil { doc.paragraph(id: pid) == "The night was pitch-black and stormy." }
        XCTAssertEqual(doc.paragraph(id: pid), "The night was pitch-black and stormy.")
        XCTAssertEqual(annotation(doc, annId)?.status, .accepted)

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
}
