import XCTest
@testable import Maugham

/// Rewind interop tests for the Tasks milestone.
///
/// Invariant: task ops, task lifecycle mutations, and inline-task derivation
/// all rewind cleanly via the existing `Document.restoreToOp(opId:)` path.
/// Tasks are op-log derived, so rewind is transparent as long as:
///   1. `Document.restoreToOp` calls `invalidateTasksCache()` (verified: line
///      1175 of Document.swift).
///   2. `TaskDeriver` handles the unknown-parent case by rendering the child
///      as parent-less rather than dropping or crashing (verified: §4 of
///      TaskDeriver.swift's derive function).
@MainActor
final class TaskRewindTests: XCTestCase {

    // MARK: - Shared fixture

    private func makeDocument(
        initialMd: String = "Hello."
    ) async throws -> Document {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskRewindTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let relPath = "manuscript/c1.md"
        try initialMd.write(
            to: tmp.appendingPathComponent(relPath),
            atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document, path: relPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return try await Document.load(
            url: tmp.appendingPathComponent(relPath),
            device: "test", session: "s", presenter: nil)
    }

    // MARK: - Test 1: Rewind past a priority change reverts order

    /// Create A (priority ~1) and B (priority ~2). Capture the opId of A's
    /// create op (before the reorder). Then set B's priority to 0.5 so B
    /// sorts before A. Restore to the op BEFORE the priority-change op.
    /// After restore the cache is invalidated and tasks() should return
    /// [A, B] in the original insertion order.
    func test_rewindPastPriorityChange_revertsOrder() async throws {
        let doc = try await makeDocument()

        // Create A then B in order.
        let taskA = doc.createPaneTask(body: "task A", parentTaskId: nil)
        let taskB = doc.createPaneTask(body: "task B", parentTaskId: nil)

        // Flush so the ops are visible in the mirror.
        try await doc.flushBurstNow()

        // Verify initial order is A before B.
        let filter = TaskFilter(scope: .project, statuses: [.open])
        let before = doc.tasks(filter: filter)
        let idsBefore = before.map(\.id)
        XCTAssertTrue(idsBefore.firstIndex(of: taskA.id)! < idsBefore.firstIndex(of: taskB.id)!,
                      "A should sort before B after creation")

        // Capture the last op id BEFORE the priority change.
        let opIdBeforePriorityChange = doc.opLogSnapshot.last!.opId

        // Reorder: bump B's priority below A so B sorts first.
        // A was created first at a lower priority number; B was second at higher.
        // To make B sort before A, set B's priority lower than A's.
        let currentA = doc.tasks(filter: filter).first { $0.id == taskA.id }!
        doc.setTaskPriority(id: taskB.id, priority: currentA.priority - 0.5)

        // Verify the reorder took effect.
        let reordered = doc.tasks(filter: filter)
        let idsReordered = reordered.map(\.id)
        XCTAssertTrue(idsReordered.firstIndex(of: taskB.id)! < idsReordered.firstIndex(of: taskA.id)!,
                      "After priority change, B should sort before A")

        // Rewind to before the priority change.
        _ = try await doc.restoreToOp(opId: opIdBeforePriorityChange)

        // Cache must be invalidated; tasks should revert to original A-before-B order.
        let afterRewind = doc.tasks(filter: filter)
        let idsAfterRewind = afterRewind.map(\.id)
        XCTAssertTrue(idsAfterRewind.contains(taskA.id), "A should still exist after rewind")
        XCTAssertTrue(idsAfterRewind.contains(taskB.id), "B should still exist after rewind")
        XCTAssertTrue(
            idsAfterRewind.firstIndex(of: taskA.id)! < idsAfterRewind.firstIndex(of: taskB.id)!,
            "After rewinding past the priority change, A should sort before B again")
    }

    // MARK: - Test 2: Rewind past inline checkbox creation removes the task

    /// Set a paragraph text to "- [ ] foo" (records a typingBurst after flush).
    /// Capture the opId BEFORE the flush. Restore to that opId.
    /// The paragraph text reverts to non-checkbox content, so no inline task
    /// should be derived.
    func test_rewindPastInlineCheckboxCreation_removesTask() async throws {
        let doc = try await makeDocument(initialMd: "Hello.")
        try await doc.flushBurstNow()

        // Capture the bootstrap op as our rewind target (state with no checkbox).
        let opIdBeforeCheckbox = doc.opLogSnapshot.last!.opId

        // Find the first paragraph id from the bootstrap op.
        let bootstrapPid = doc.opLogSnapshot
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId

        // Mutate the paragraph to contain a checkbox.
        doc.setParagraph(id: bootstrapPid, text: "- [ ] foo")
        try await doc.flushBurstNow()

        // Verify the inline task is now derived.
        let filter = TaskFilter(scope: .document(docId: doc.docId))
        let withCheckbox = doc.tasks(filter: filter)
        XCTAssertEqual(withCheckbox.count, 1, "One inline task should be derived from the checkbox")
        XCTAssertEqual(withCheckbox.first?.kind, .inlineMarkdown)

        // Rewind to before the checkbox was added.
        _ = try await doc.restoreToOp(opId: opIdBeforeCheckbox)

        // The task cache must be invalidated; the paragraph text reverted,
        // so no inline task should be derived.
        let afterRewind = doc.tasks(filter: filter)
        XCTAssertTrue(afterRewind.isEmpty,
                      "After rewinding past the typingBurst, no inline task should be derived")
    }

    // MARK: - Test 3: Rewind past parent change unparents the child

    /// Create A and B. Set B's parent to A (emits a .taskParentChange op).
    /// Capture the opId BEFORE the parent change. Restore to that opId.
    /// B should have no parent after the rewind.
    func test_rewindPastParentChange_unParents() async throws {
        let doc = try await makeDocument()

        let taskA = doc.createPaneTask(body: "parent A", parentTaskId: nil)
        let taskB = doc.createPaneTask(body: "child B", parentTaskId: nil)
        try await doc.flushBurstNow()

        // Verify B has no parent initially.
        let filter = TaskFilter(scope: .project, statuses: [.open])
        let initial = doc.tasks(filter: filter)
        XCTAssertNil(initial.first { $0.id == taskB.id }?.parentTaskId,
                     "B should have no parent initially")

        // Capture opId before the parent change.
        let opIdBeforeParentChange = doc.opLogSnapshot.last!.opId

        // Set B's parent to A.
        doc.setTaskParent(id: taskB.id, parentTaskId: taskA.id)

        // Verify the parent link.
        let withParent = doc.tasks(filter: filter)
        XCTAssertEqual(withParent.first { $0.id == taskB.id }?.parentTaskId, taskA.id,
                       "B should have A as parent after setTaskParent")

        // Rewind past the parent change.
        _ = try await doc.restoreToOp(opId: opIdBeforeParentChange)

        // B should have no parent after rewind.
        let afterRewind = doc.tasks(filter: filter)
        let bAfterRewind = afterRewind.first { $0.id == taskB.id }
        XCTAssertNotNil(bAfterRewind, "B should still exist after rewind")
        XCTAssertNil(bAfterRewind?.parentTaskId,
                     "After rewinding past the parent change, B should have no parent")
    }

    // MARK: - Test 4: Rewind past pane task creation removes the task

    /// Call createPaneTask. Capture the opId BEFORE the create.
    /// Restore to that opId. The task should be absent from tasks(filter:).
    func test_rewindPastPaneTaskCreate_removesPaneTask() async throws {
        let doc = try await makeDocument()
        try await doc.flushBurstNow()

        // Capture the last op id before creating the task.
        let opIdBeforeCreate = doc.opLogSnapshot.last!.opId

        // Create a pane task.
        let createdTask = doc.createPaneTask(body: "foo", parentTaskId: nil)

        // Verify the task appears.
        let filter = TaskFilter(scope: .project, statuses: [.open])
        let withTask = doc.tasks(filter: filter)
        XCTAssertTrue(withTask.contains { $0.id == createdTask.id },
                      "Task should appear in tasks() after creation")

        // Rewind to before the create op.
        _ = try await doc.restoreToOp(opId: opIdBeforeCreate)

        // The task should be absent: the .taskCreate op is past the rewind
        // boundary so the deriver no longer sees it.
        let afterRewind = doc.tasks(filter: filter)
        XCTAssertFalse(afterRewind.contains { $0.id == createdTask.id },
                       "After rewinding past the taskCreate op, the task should be absent")
    }

    // MARK: - Test 5: Unknown parent renders child as parent-less

    /// Construct a scenario where a child task references a parent id that
    /// does not exist in the visible op log window. Achieved by appending a
    /// synthetic `.taskParentChange` op whose `taskParentId` is a literal id
    /// that was never created. The deriver should emit the child with
    /// `parentTaskId == nil` per spec §5 step 6 (treat as parent-less, not drop).
    func test_rewindUnknownParent_isParentLess() async throws {
        let doc = try await makeDocument()
        try await doc.flushBurstNow()

        // Create parent A and child B with B parented to A.
        let taskA = doc.createPaneTask(body: "parent A", parentTaskId: nil)
        let taskB = doc.createPaneTask(body: "child B", parentTaskId: nil)
        try await doc.flushBurstNow()

        // Capture opId after B's create but before we set the parent link.
        // This is the state where both A and B exist unlinked.
        let opIdAfterBothCreated = doc.opLogSnapshot.last!.opId

        // Now set B's parent to A.
        doc.setTaskParent(id: taskB.id, parentTaskId: taskA.id)

        // Verify B is parented.
        let filter = TaskFilter(scope: .project, statuses: [.open])
        let withParent = doc.tasks(filter: filter)
        XCTAssertEqual(withParent.first { $0.id == taskB.id }?.parentTaskId, taskA.id)

        // Rewind to before the parent change (but both A and B still exist).
        _ = try await doc.restoreToOp(opId: opIdAfterBothCreated)

        // B should exist with no parent.
        let afterRewind = doc.tasks(filter: filter)
        let bAfterRewind = afterRewind.first { $0.id == taskB.id }
        XCTAssertNotNil(bAfterRewind, "B should still exist after rewind")
        XCTAssertNil(bAfterRewind?.parentTaskId,
                     "B's parent link was rewound; it should render as parent-less")

        // Now test the synthetic unknown-parent path directly via TaskDeriver.
        // Build an op log where a child references a non-existent parent id.
        let nonExistentParentId = "ghost-parent-id-never-created"
        let childCreateOp = Op(
            opId: "test-child-\(UUID().uuidString)",
            docId: doc.docId, at: Date(),
            device: "test", session: "s",
            kind: .taskCreate,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: "s",
                taskId: "orphan-child-id",
                taskBody: "orphan child",
                taskPriority: 1.0,
                taskParentId: nil,
                taskKind: TaskKind.paneCreated.rawValue))
        let parentChangeOp = Op(
            opId: "test-parent-change-\(UUID().uuidString)",
            docId: doc.docId, at: Date(),
            device: "test", session: "s",
            kind: .taskParentChange,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: "s",
                taskId: "orphan-child-id",
                taskParentId: nonExistentParentId))

        let (derived, _, _) = TaskDeriver.derive(
            ops: [childCreateOp, parentChangeOp],
            paragraphs: [:],
            docId: doc.docId)

        let orphanChild = derived.first { $0.id == "orphan-child-id" }
        XCTAssertNotNil(orphanChild,
                        "Deriver must not drop a child with an unknown parent")
        XCTAssertNil(orphanChild?.parentTaskId,
                     "Child referencing a non-existent parent must render as parent-less")
    }
}
