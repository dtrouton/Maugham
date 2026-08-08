import XCTest
import MaughamCore
@testable import Maugham

/// Mutable holder for a bridged async result (all access is MainActor-confined
/// within a single test, so `@unchecked Sendable` is sound here).
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Batch "Archive all done" × ⌘Z — the final-review CRITICAL fix.
///
/// `TasksPane.archiveAllDone` opens ONE manual undo group and calls
/// `Document.archiveTask` per done task. An INLINE task's archive splices
/// manuscript text, whose D1 choreography clears stale native typing actions
/// (`removeAllActions`) — and a `removeAllActions` INSIDE an open manual group
/// corrupts NSUndoManager (the T5 crash class: unbalanced group, earlier
/// inverses erased). The fix is batch-aware: when the batch contains ≥1 inline
/// task, ONE clear fires BEFORE `beginUndoGrouping` and every per-call clear
/// inside the batch is suppressed (`archiveTask(suppressUndoStackClear:)`).
///
/// These are **synchronous** XCTest methods on the AnnotationAcceptUndo
/// sync/pump shape: `NSUndoManager.undo()` runs its handlers synchronously and
/// each hops its async work onto a task; the run loop is pumped so those land,
/// exactly as the AppKit responder chain drives undo in the running app. The
/// undo manager uses default `groupsByEvent` — note this suite deliberately
/// DOES drive the manual-group path (that's the production shape under test);
/// the production fix moves the clear before the group so the combination is
/// legal again.
@MainActor
final class ArchiveAllDoneUndoTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let doc: Document
        let taskPid: String
    }

    /// A doc whose first paragraph is a CHECKED inline task (pre-anchored,
    /// tripwire: 6-char alphabet-restricted task anchor) and whose second is
    /// plain prose, wired through a real DocumentStore.
    private func makeHarness() async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ARCHIVE-ALL-UNDO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        let stored = """
        - [x] inline done thing <!--t-aaaaaa-->

        Some other prose.
        """
        try stored.write(
            to: tmp.appendingPathComponent(docPath),
            atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document, path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let doc = try await Document.load(
            url: tmp.appendingPathComponent(docPath),
            device: "m", session: "s", presenter: nil)
        let taskPid = try await doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId
        return Harness(doc: doc, taskPid: taskPid)
    }

    /// A TasksPane over a stub project with `doc` registered, mirroring
    /// `TasksPaneIntegrationTests.makePane(for:registering:)` — we never render
    /// the view; `archiveAllDone` is `internal` exactly so tests can drive the
    /// REAL batch path.
    private func makePane(for doc: Document) async throws -> TasksPane {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PANE-UNDO-STUB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "Stub", author: "T",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: url.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        ds.register(document: doc, for: "stub/\(doc.docId).md")
        return TasksPane(
            store: store,
            documentStore: ds,
            activeDocId: doc.docId,
            projectURL: url)
    }

    // MARK: - Sync ⟷ async bridges (AnnotationAcceptUndoTests shape)

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

    private func status(_ doc: Document, _ id: String) -> TaskStatus? {
        doc.tasks(filter: .init(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases))).first { $0.id == id }?.status
    }

    // MARK: - Batch with an inline member: no corruption, one ⌘Z restores all

    func test_archiveAllDone_withInlineMember_singleUndoRestoresWholeBatch() throws {
        let h = try bridge { try await self.makeHarness() }
        let doc = h.doc
        let inlineId = "inline:\(doc.docId):aaaaaa"

        // A second done task, pane-created, so the batch is ≥2 with one inline.
        let paneTask = doc.createPaneTask(body: "pane done thing", parentTaskId: nil)
        doc.setTaskStatus(id: paneTask.id, status: .done)
        XCTAssertEqual(status(doc, inlineId), .done)
        XCTAssertEqual(status(doc, paneTask.id), .done)
        let originalTaskParagraph = doc.paragraph(id: h.taskPid)

        let um = UndoManager()
        let pane = try bridge { try await self.makePane(for: doc) }
        // The real batch path: ONE manual group; the inline member's D1 clear
        // must have fired BEFORE the group opened (a clear inside the group is
        // the T5 NSUndoManager corruption this test pins).
        pane.archiveAllDone(in: .document, undoManager: um)

        XCTAssertEqual(status(doc, inlineId), .archived)
        XCTAssertEqual(status(doc, paneTask.id), .archived)
        XCTAssertNil(doc.paragraph(id: h.taskPid),
            "sole-task paragraph collapses on the inline archive")

        // Let groupsByEvent close its event group before undoing. `archiveAllDone`
        // is fully synchronous (its manual group is begun AND ended inside the
        // call), so the only thing left outstanding is the enclosing EVENT
        // group — and that close is not readable as a value. `canUndo` reads
        // true the instant the registration lands, group still open; and
        // measured 2026-08-08 a `waitUntil { um.canUndo && um.groupingLevel
        // == 0 }` never goes true here, burning its whole deadline instead.
        pumpFor(0.2)  // fixed window: the event-group close — see the note above
        XCTAssertTrue(um.canUndo, "the batch registered exactly one undoable group")

        um.undo()
        waitUntil {
            self.status(doc, inlineId) == .done
                && self.status(doc, paneTask.id) == .done
        }
        XCTAssertEqual(status(doc, inlineId), .done,
            "one ⌘Z restored the inline member (pre-archive status)")
        XCTAssertEqual(status(doc, paneTask.id), .done,
            "…and the pane member, in the SAME ⌘Z — the batch group held together")
        XCTAssertEqual(doc.paragraph(id: h.taskPid), originalTaskParagraph,
            "the spliced task paragraph text is back")
    }

    // MARK: - Empty batch: no group, no phantom undo action (final-review Minor-6)

    func test_archiveAllDone_emptyBatch_opensNoUndoGroup() throws {
        let h = try bridge { try await self.makeHarness() }
        let doc = h.doc
        // Flip the sole task OPEN (no undo manager → nothing registers on
        // `um`) so the Done scope is empty.
        doc.setTaskStatus(id: "inline:\(doc.docId):aaaaaa", status: .open)

        let um = UndoManager()
        let pane = try bridge { try await self.makePane(for: doc) }

        pane.archiveAllDone(in: .document, undoManager: um)
        pumpFor(0.1)  // fixed window: asserting nothing happens (no group opened)
        XCTAssertFalse(um.canUndo,
            "an empty batch must not open a group / leave a do-nothing ⌘Z entry")
    }
}
