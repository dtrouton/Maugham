import XCTest
import MaughamCore
@testable import Maugham

/// Regression tests for the live tasks-cache invalidation fast path.
/// Without this, the cache only invalidates at burst-flush time (30s
/// idle), so newly-typed `- [ ]` rows or pane-click flips don't surface
/// in the Tasks pane until the user idles or switches documents.
///
/// The fast path is opt-in via `changeTouchesTaskMarkup`: only fires
/// when prior OR next text contains `- [ ]`, `- [x]`, `[[todo:`, or
/// `[[done:` — non-checkbox typing stays off the observable-write hot
/// loop per the AttributeGraph cycle / reentrant-layout history.
@MainActor
final class DocumentTaskCacheLiveInvalidationTests: XCTestCase {

    private func makeDoc(text: String = "") async throws -> Document {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DTCLI-\(UUID().uuidString)")
        let manuscriptDir = tmp.appendingPathComponent("manuscript")
        try FileManager.default.createDirectory(
            at: manuscriptDir, withIntermediateDirectories: true)
        let mdURL = manuscriptDir.appendingPathComponent("doc.md")
        try text.write(to: mdURL, atomically: true, encoding: .utf8)
        return try await Document.load(
            url: mdURL, device: "test", session: "s", presenter: nil)
    }

    func test_setFullText_addingCheckbox_invalidatesTasksImmediately() async throws {
        let doc = try await makeDoc(text: "Just plain text.")
        // Read tasks once to ensure the cache is warm.
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let v1 = doc.tasksVersion

        // Type a checkbox via the editor binding path.
        doc.setFullText("- [ ] new task")

        // The cache must have invalidated synchronously. We assert
        // tasksVersion bumped (the invalidation signal) AND a subsequent
        // tasks() read surfaces the new task without any burst flush.
        XCTAssertGreaterThan(doc.tasksVersion, v1,
            "Adding `- [ ]` to paragraph text should invalidate tasks cache live")
        let tasks = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let inlineTasks = tasks.filter { $0.kind == .inlineMarkdown }
        XCTAssertEqual(inlineTasks.count, 1)
        XCTAssertEqual(inlineTasks.first?.body, "new task")
    }

    func test_setParagraph_togglingCheckbox_invalidatesTasksImmediately() async throws {
        let doc = try await makeDoc(text: "- [ ] open me")
        let pid = doc.opLogSnapshot.last(where: { $0.kind == .bootstrap })?
            .changes.first?.paragraphId ?? "missing"
        XCTAssertFalse(pid == "missing", "Bootstrap should have minted a paragraph id")

        // Warm cache + capture baseline.
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let v1 = doc.tasksVersion

        // Simulate a pane checkbox click flipping `[ ]` → `[x]`.
        doc.setParagraph(id: pid, text: "- [x] open me")

        XCTAssertGreaterThan(doc.tasksVersion, v1,
            "Pane checkbox click on inline task should invalidate tasks cache live")
        let tasks = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let inlineTasks = tasks.filter { $0.kind == .inlineMarkdown }
        XCTAssertEqual(inlineTasks.count, 1)
        XCTAssertEqual(inlineTasks.first?.status, .done)
    }

    func test_setFullText_plainText_doesNotInvalidateTasks() async throws {
        let doc = try await makeDoc(text: "Plain paragraph.")
        // Warm cache + capture baseline.
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let v1 = doc.tasksVersion

        // Non-checkbox typing — should NOT trip the fast path.
        doc.setFullText("Plain paragraph, with a tweak.")

        XCTAssertEqual(doc.tasksVersion, v1,
            "Non-checkbox typing must stay off the tasks-cache invalidation hot path")
    }

    func test_setFullText_fountainTodo_invalidatesTasksImmediately() async throws {
        let doc = try await makeDoc(text: "Some screenplay text.")
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let v1 = doc.tasksVersion

        doc.setFullText("Some screenplay text. [[todo: revise this scene]]")

        XCTAssertGreaterThan(doc.tasksVersion, v1,
            "Adding `[[todo:` should invalidate tasks cache live")
    }
}
