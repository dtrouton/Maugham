import XCTest
@testable import Maugham

/// Integration coverage for `TasksPane` — exercises the backing model and
/// the drag/drop classifier directly, not the SwiftUI render path. The
/// drop classifier is a pure function (`TaskDropIntent.classify`) and
/// pane mutations route through `Document` / `ProjectStore`, so we can
/// validate the full behavior without a render harness.
@MainActor
final class TasksPaneIntegrationTests: XCTestCase {

    // MARK: - Fixture

    private func makeProject(initialMd: String = "Hello.") throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TASKS-PANE-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document,
                path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    private func makeDocument(initialMd: String = "Hello.") async throws -> Document {
        let (project, path) = try makeProject(initialMd: initialMd)
        return try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
    }

    private func firstParagraphId(of doc: Document) async throws -> String {
        let log = try await doc.opLog()
        guard let bootstrap = log.first(where: { $0.kind == .bootstrap }),
              let pid = bootstrap.changes.first?.paragraphId else {
            XCTFail("no bootstrap paragraph")
            throw NSError(domain: "test", code: 0)
        }
        return pid
    }

    // MARK: - 1. Reorder emits one .taskPriorityChange

    func test_dragDropReorder_emitsExactlyOneTaskPriorityChange() async throws {
        let doc = try await makeDocument()
        let a = doc.createPaneTask(body: "A first", parentTaskId: nil)
        let b = doc.createPaneTask(body: "B second", parentTaskId: nil)

        // Snapshot op count before the simulated drop.
        let countBefore = doc.opLogMirrorCount

        // Build the pane's visible task list and run the classifier as the
        // TasksPane would: drop B above A.
        let pool = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let intent = TaskDropIntent.classify(
            position: .top,
            targetId: a.id,
            targetParentTaskId: a.parentTaskId)
        let pane = try await makePane(for: doc)
        pane.apply(intent: intent, dragged: b, in: doc, allTasks: pool)

        // Exactly one .taskPriorityChange op (no parent change — same root).
        let newOps = doc.opLogSnapshot.dropFirst(countBefore)
        let priorityOps = newOps.filter { $0.kind == .taskPriorityChange }
        XCTAssertEqual(priorityOps.count, 1,
            "exactly one .taskPriorityChange expected")
        XCTAssertTrue(newOps.allSatisfy { $0.kind == .taskPriorityChange },
            "no other op kinds should be emitted for same-root reorder")

        // Visible order is now [B, A].
        let after = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: [.open]))
        XCTAssertEqual(after.map(\.id), [b.id, a.id],
            "B should appear above A after the reorder")
    }

    // MARK: - 1b. SwiftUI .onMove → handleListMove → reorder

    func test_handleListMove_dragSecondRowToFirst_emitsReorderAbove() async throws {
        // Mirrors what SwiftUI's `.onMove` produces when the user drags
        // row 1 (B) above row 0 (A). After the drop, `[B, A]`.
        let doc = try await makeDocument()
        let a = doc.createPaneTask(body: "A first", parentTaskId: nil)
        let b = doc.createPaneTask(body: "B second", parentTaskId: nil)

        let pool = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        XCTAssertEqual(pool.map(\.id), [a.id, b.id], "pre: A, B")

        let countBefore = doc.opLogMirrorCount
        let pane = try await makePane(for: doc, registering: doc)
        // SwiftUI semantic: dragging index 1 (B) to slot 0 means "drop
        // before the row currently at index 0". destination = 0.
        pane.handleListMove(
            from: IndexSet(integer: 1), to: 0, in: pool)

        let newKinds = doc.opLogSnapshot.dropFirst(countBefore).map(\.kind)
        XCTAssertEqual(newKinds.filter { $0 == .taskPriorityChange }.count, 1,
            "exactly one .taskPriorityChange expected")
        let after = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: [.open]))
        XCTAssertEqual(after.map(\.id), [b.id, a.id],
            "B should appear above A after the .onMove")
    }

    func test_handleListMove_dragFirstRowBelowSecond_emitsReorderBelow() async throws {
        let doc = try await makeDocument()
        let a = doc.createPaneTask(body: "A first", parentTaskId: nil)
        let b = doc.createPaneTask(body: "B second", parentTaskId: nil)

        let pool = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))

        let countBefore = doc.opLogMirrorCount
        let pane = try await makePane(for: doc, registering: doc)
        // SwiftUI semantic: dragging index 0 (A) past index 1 (B) to slot 2.
        // destination = 2 means "drop at the end" — the row at index 1
        // becomes the new "above" reference.
        pane.handleListMove(
            from: IndexSet(integer: 0), to: 2, in: pool)

        let newKinds = doc.opLogSnapshot.dropFirst(countBefore).map(\.kind)
        XCTAssertEqual(newKinds.filter { $0 == .taskPriorityChange }.count, 1,
            "exactly one .taskPriorityChange expected")
        let after = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: [.open]))
        XCTAssertEqual(after.map(\.id), [b.id, a.id],
            "A should appear below B after the .onMove")
    }

    func test_handleListMove_dropOnSelf_isNoOp() async throws {
        let doc = try await makeDocument()
        let a = doc.createPaneTask(body: "A", parentTaskId: nil)
        let b = doc.createPaneTask(body: "B", parentTaskId: nil)
        _ = (a, b)

        let pool = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let countBefore = doc.opLogMirrorCount
        let pane = try await makePane(for: doc, registering: doc)
        // Drop index 0 onto slot 0 (self): no-op.
        pane.handleListMove(
            from: IndexSet(integer: 0), to: 0, in: pool)
        // Drop index 0 onto slot 1 (right where it already is per
        // SwiftUI's "insert before slot N" semantics): also no-op.
        pane.handleListMove(
            from: IndexSet(integer: 0), to: 1, in: pool)
        XCTAssertEqual(doc.opLogMirrorCount, countBefore,
            "no ops should fire for a self-targeted move")
    }

    // MARK: - 2. Inline checkbox click → typingBurst (not taskStatusChange)

    func test_paneCheckboxClick_onInlineTask_flipsTextAndEmitsTypingBurst() async throws {
        let doc = try await makeDocument(initialMd: "Hello.")
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: "- [ ] inline thing")
        try await doc.flushBurstNow()

        let tasks = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: [.open]))
        XCTAssertEqual(tasks.count, 1)
        let inlineTask = tasks[0]

        let countBefore = doc.opLogMirrorCount
        // Simulate the pane checkbox click: TasksPane.toggleStatus rewrites
        // the underlying paragraph via setParagraph (mirroring the editor
        // markdown-checkbox click path).
        guard let current = doc.paragraph(id: pid) else {
            return XCTFail("paragraph vanished")
        }
        let flipped = flipInlineCheckbox(current)
        doc.setParagraph(id: pid, text: flipped)
        try await doc.flushBurstNow()

        // After the V2 mint pass, the paragraph now carries a task anchor
        // span (`<!--t-XXXXXX-->`); the bracket flip preserves it. Compare
        // by the anchor-stripped form to keep the assertion focused on
        // checkbox state.
        XCTAssertEqual(
            RenderFilter.stripTaskAnchorsInline(flipped),
            "- [x] inline thing")
        XCTAssertEqual(
            RenderFilter.stripTaskAnchorsInline(doc.paragraph(id: pid) ?? ""),
            "- [x] inline thing",
            "paragraph text should now reflect a flipped checkbox")
        XCTAssertTrue(flipped.contains("<!--t-"),
            "task anchor must survive the bracket flip")
        let newKinds = doc.opLogSnapshot.dropFirst(countBefore).map(\.kind)
        XCTAssertTrue(newKinds.contains(.typingBurst),
            "inline checkbox toggle must emit a typingBurst")
        XCTAssertFalse(newKinds.contains(.taskStatusChange),
            "inline checkbox toggle must NOT emit a taskStatusChange")
        _ = inlineTask  // suppress unused
    }

    // MARK: - 3. Pane task checkbox → taskStatusChange

    func test_paneCheckboxClick_onPaneTask_emitsTaskStatusChange() async throws {
        let doc = try await makeDocument()
        let task = doc.createPaneTask(body: "pane thing", parentTaskId: nil)

        let countBefore = doc.opLogMirrorCount
        doc.setTaskStatus(id: task.id, status: .done)

        let newOps = doc.opLogSnapshot.dropFirst(countBefore)
        XCTAssertEqual(newOps.count, 1)
        XCTAssertEqual(newOps.first?.kind, .taskStatusChange)
        XCTAssertEqual(newOps.first?.provenance?.taskStatus, "done")
    }

    // MARK: - 4. Pane-created task has no paragraph anchor

    func test_paneCreatedTask_hasNoParagraphAnchor() async throws {
        let doc = try await makeDocument()
        let task = doc.createPaneTask(body: "no anchor", parentTaskId: nil)
        XCTAssertNotNil(task.anchor, "anchor exists (the doc id)")
        XCTAssertEqual(task.anchor?.docId, doc.docId)
        XCTAssertNil(task.anchor?.paragraphId,
            "pane-created tasks have no paragraph anchor")

        // And the project-scope variant via ProjectStore.
        let (url, _) = try makeProject()
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let projTask = store.createProjectPaneTask(body: "project thing")
        XCTAssertEqual(projTask.anchor?.docId, ProjectStore.projectTasksDocId)
        XCTAssertNil(projTask.anchor?.paragraphId)
    }

    // MARK: - 5. Status filter

    func test_statusFilter_open_excludesDoneAndArchived() async throws {
        let doc = try await makeDocument()
        let openTask = doc.createPaneTask(body: "still open", parentTaskId: nil)
        let doneTask = doc.createPaneTask(body: "will be done", parentTaskId: nil)
        let archivedTask = doc.createPaneTask(body: "will be archived", parentTaskId: nil)
        doc.setTaskStatus(id: doneTask.id, status: .done)
        doc.archiveTask(id: archivedTask.id)

        let openOnly = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId), statuses: [.open]))
        XCTAssertEqual(openOnly.count, 1)
        XCTAssertEqual(openOnly.first?.id, openTask.id)
    }

    // MARK: - 6. Center-drop nests as child

    func test_dragOntoTaskCenter_nestsAsChild() async throws {
        let doc = try await makeDocument()
        let parent = doc.createPaneTask(body: "parent", parentTaskId: nil)
        let child = doc.createPaneTask(body: "to-be-child", parentTaskId: nil)

        let countBefore = doc.opLogMirrorCount
        let pool = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let intent = TaskDropIntent.classify(
            position: .middle,
            targetId: parent.id,
            targetParentTaskId: parent.parentTaskId)
        // Sanity-check the classifier returned a nest, not a reorder.
        XCTAssertEqual(intent, .nestUnder(parentId: parent.id))

        let pane = try await makePane(for: doc)
        pane.apply(intent: intent, dragged: child, in: doc, allTasks: pool)

        let newOps = doc.opLogSnapshot.dropFirst(countBefore)
        let parentOps = newOps.filter { $0.kind == .taskParentChange }
        XCTAssertEqual(parentOps.count, 1,
            "one .taskParentChange expected for a nest")
        XCTAssertEqual(parentOps.first?.provenance?.taskParentId, parent.id)

        let after = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let childAfter = after.first { $0.id == child.id }
        XCTAssertEqual(childAfter?.parentTaskId, parent.id)
    }

    // MARK: - 7. Strict single-level nesting (drop on child → reorder, NOT nest)

    func test_dropOnChildOfChild_doesNotCreateGrandchild() async throws {
        let doc = try await makeDocument()
        let parent = doc.createPaneTask(body: "parent", parentTaskId: nil)
        let child = doc.createPaneTask(body: "child", parentTaskId: parent.id)
        let dragged = doc.createPaneTask(body: "would-be-grandchild", parentTaskId: nil)

        // Classify a center-drop onto the existing child. Per spec §11, the
        // pure classifier must return a sibling reorder rather than a nest.
        let intent = TaskDropIntent.classify(
            position: .middle,
            targetId: child.id,
            targetParentTaskId: child.parentTaskId)
        switch intent {
        case .nestUnder:
            XCTFail("center-drop on a child must NOT nest deeper — spec §11")
        case .reorderAbove, .reorderBelow:
            break  // expected
        }

        // And confirm: applying the intent does not parent `dragged` under
        // the existing child. (It may parent under `parent.id`, the child's
        // own parent, since that's a sibling reorder. Either way, depth ≤ 1.)
        let pool = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let pane = try await makePane(for: doc)
        pane.apply(intent: intent, dragged: dragged, in: doc, allTasks: pool)

        let after = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let draggedAfter = after.first { $0.id == dragged.id }
        XCTAssertNotEqual(draggedAfter?.parentTaskId, child.id,
            "dragged task must not be a child of the existing child")

        // Depth invariant for ALL tasks: at most one level of nesting.
        for t in after {
            guard let pid = t.parentTaskId else { continue }
            let p = after.first { $0.id == pid }
            XCTAssertNil(p?.parentTaskId,
                "task \(t.id) is at depth ≥ 2 — spec §11 violated")
        }
    }

    // MARK: - 8. Deleting a paragraph leaves pane-created tasks alone

    func test_deletingParagraph_doesNotTouchPaneCreatedTasks() async throws {
        let doc = try await makeDocument(initialMd: "Hello.")
        // Create a paragraph that holds an inline task.
        let firstPid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: firstPid, text: "- [ ] inline marker")
        try await doc.flushBurstNow()

        // Add a second paragraph (we'll keep it around to anchor the doc).
        _ = doc.insertParagraph(after: firstPid, text: "kept around")

        // Independently, create a pane-created task on the doc.
        let paneTask = doc.createPaneTask(body: "pane task survives", parentTaskId: nil)

        // Sanity: both tasks are visible.
        let before = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        XCTAssertTrue(before.contains { $0.kind == .inlineMarkdown })
        XCTAssertTrue(before.contains { $0.id == paneTask.id })

        // Delete the paragraph that holds the inline task. This triggers the
        // orphan-annotation sweep (gated on SweepReason.removed) — but the
        // sweep walks _annotationsCache only and must NOT touch the tasks
        // cache.
        doc.deleteParagraph(id: firstPid)
        try await doc.flushBurstNow()

        let after = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        // Inline task vanishes (its source paragraph is gone).
        XCTAssertFalse(after.contains { $0.kind == .inlineMarkdown },
            "inline task should disappear when its paragraph is deleted")
        // Pane-created task survives.
        XCTAssertTrue(after.contains { $0.id == paneTask.id },
            "pane-created task must survive paragraph deletion")
        XCTAssertEqual(after.first { $0.id == paneTask.id }?.status, .open,
            "pane-created task status must not change")
    }

    // MARK: - Helpers

    /// Construct a TasksPane bound to a real Document + minimal stores.
    /// We never render this view; we call `.apply(...)` on it directly.
    private func makePane(for doc: Document) async throws -> TasksPane {
        return try await makePane(for: doc, registering: nil)
    }

    /// Optionally registers `registering` (typically the test document)
    /// with the pane's `DocumentStore` so `ownerDoc(of:)` lookups
    /// resolve. Without this, `handleListMove` returns early because the
    /// pane's stub store doesn't know about externally-created Documents.
    /// Tests that drive code paths going through `ownerDoc(of:)` need to
    /// pass `registering: doc`.
    private func makePane(
        for doc: Document, registering: Document?
    ) async throws -> TasksPane {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PANE-STUB-\(UUID().uuidString)")
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
        if let toRegister = registering {
            ds.register(document: toRegister, for: "stub/\(toRegister.docId).md")
        }
        return TasksPane(
            store: store,
            documentStore: ds,
            activeDocId: doc.docId,
            projectURL: url)
    }
}
