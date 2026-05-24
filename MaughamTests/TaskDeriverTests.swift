import XCTest
@testable import Maugham

final class TaskDeriverTests: XCTestCase {

    // MARK: - Helpers

    private static let testDate: Date = {
        ISO8601DateFormatter().date(from: "2026-05-23T18:00:00Z")!
    }()

    private func makeOp(
        opId: String,
        kind: OpKind,
        docId: String = "doc_test",
        at: Date? = nil,
        provenance: Op.Provenance? = nil
    ) -> Op {
        Op(
            opId: opId,
            docId: docId,
            at: at ?? Self.testDate,
            device: "test-device",
            session: "test-session",
            kind: kind,
            changes: [],
            sequence: nil,
            provenance: provenance)
    }

    // MARK: - 1. Empty inputs

    func test_derive_emptyOpsAndParagraphs_returnsEmpty() {
        let (tasks, rebal) = TaskDeriver.derive(ops: [], paragraphs: [:], docId: "doc_test")
        XCTAssertTrue(tasks.isEmpty)
        XCTAssertTrue(rebal.isEmpty)
    }

    // MARK: - 2. Inline markdown checkbox: open

    func test_derive_singleInlineCheckbox_returnsOpenTask() {
        let pid = "abcd"
        let (tasks, _) = TaskDeriver.derive(
            ops: [],
            paragraphs: [pid: "- [ ] foo"],
            docId: "doc_test")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].kind, .inlineMarkdown)
        XCTAssertEqual(tasks[0].status, .open)
        XCTAssertEqual(tasks[0].body, "foo")
        XCTAssertEqual(tasks[0].anchor?.docId, "doc_test")
        XCTAssertEqual(tasks[0].anchor?.paragraphId, pid)
    }

    // MARK: - 3. Inline checked: done

    func test_derive_inlineCheckedBox_returnsDoneTask() {
        let pid = "bcde"
        let (tasks, _) = TaskDeriver.derive(
            ops: [],
            paragraphs: [pid: "- [x] done thing"],
            docId: "doc_test")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].status, .done)
        XCTAssertEqual(tasks[0].body, "done thing")
    }

    // MARK: - 4. Pane-created task

    func test_derive_paneCreatedTaskOp_returnsPaneTask() {
        let createOp = makeOp(
            opId: "op_create_1",
            kind: .taskCreate,
            provenance: Op.Provenance(
                sessionId: "s1",
                taskId: "op_create_1",
                taskBody: "revise act 2",
                taskPriority: 1.0,
                taskKind: "pane_created"))
        let (tasks, _) = TaskDeriver.derive(
            ops: [createOp],
            paragraphs: [:],
            docId: "doc_test")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].kind, .paneCreated)
        XCTAssertEqual(tasks[0].id, "op_create_1")
        XCTAssertEqual(tasks[0].body, "revise act 2")
        XCTAssertEqual(tasks[0].status, .open)
        XCTAssertEqual(tasks[0].priority, 1.0)
    }

    // MARK: - 5. Priority override on inline (synthetic id)

    func test_derive_priorityOpOverridesDefault() {
        let pid = "cdef"
        let docId = "doc_test"
        let synthId = "inline:\(docId):\(pid):\(TaskDeriver.bodyHash("foo"))"
        let prioOp = makeOp(
            opId: "op_prio_1",
            kind: .taskPriorityChange,
            provenance: Op.Provenance(
                taskId: synthId,
                taskPriority: 42.5))
        let (tasks, _) = TaskDeriver.derive(
            ops: [prioOp],
            paragraphs: [pid: "- [ ] foo"],
            docId: docId)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].priority, 42.5)
    }

    // MARK: - 6. Parent change nests child

    func test_derive_parentChangeOp_nestsChildUnderParent() {
        let parentCreate = makeOp(
            opId: "op_parent",
            kind: .taskCreate,
            provenance: Op.Provenance(
                taskId: "op_parent",
                taskBody: "parent task",
                taskPriority: 1.0,
                taskKind: "pane_created"))
        let pid = "dfgh"
        let docId = "doc_test"
        let childSynth = "inline:\(docId):\(pid):\(TaskDeriver.bodyHash("child thing"))"
        let parentOp = makeOp(
            opId: "op_parent_change",
            kind: .taskParentChange,
            provenance: Op.Provenance(
                taskId: childSynth,
                taskParentId: "op_parent"))

        let (tasks, _) = TaskDeriver.derive(
            ops: [parentCreate, parentOp],
            paragraphs: [pid: "- [ ] child thing"],
            docId: docId)
        XCTAssertEqual(tasks.count, 2)
        // Parent then child interleave
        XCTAssertEqual(tasks[0].id, "op_parent")
        XCTAssertNil(tasks[0].parentTaskId)
        XCTAssertEqual(tasks[1].id, childSynth)
        XCTAssertEqual(tasks[1].parentTaskId, "op_parent")
    }

    // MARK: - 7. Archive

    func test_derive_archiveOp_marksArchived() {
        let createOp = makeOp(
            opId: "op_a",
            kind: .taskCreate,
            provenance: Op.Provenance(
                taskId: "op_a",
                taskBody: "to archive",
                taskPriority: 1.0,
                taskKind: "pane_created"))
        let archiveOp = makeOp(
            opId: "op_arch",
            kind: .taskArchive,
            provenance: Op.Provenance(taskId: "op_a"))
        let (tasks, _) = TaskDeriver.derive(
            ops: [createOp, archiveOp],
            paragraphs: [:],
            docId: "doc_test")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].status, .archived)
    }

    // MARK: - 8. Filter by status

    func test_derive_filterByStatus_excludesOthers() {
        // Open one inline, done one inline, archived one pane.
        let p1 = "qmpr"
        let p2 = "rstv"
        let openOp: [Op] = []
        let createA = makeOp(
            opId: "op_ar",
            kind: .taskCreate,
            provenance: Op.Provenance(
                taskId: "op_ar",
                taskBody: "archived task",
                taskPriority: 1.0,
                taskKind: "pane_created"))
        let archOp = makeOp(
            opId: "op_arch",
            kind: .taskArchive,
            provenance: Op.Provenance(taskId: "op_ar"))
        let (tasks, _) = TaskDeriver.derive(
            ops: openOp + [createA, archOp],
            paragraphs: [p1: "- [ ] open one", p2: "- [x] done one"],
            docId: "doc_test")
        XCTAssertEqual(tasks.count, 3)

        let openOnly = tasks.filter { $0.status == .open }
        XCTAssertEqual(openOnly.count, 1)
        XCTAssertEqual(openOnly[0].body, "open one")

        let doneOnly = tasks.filter { $0.status == .done }
        XCTAssertEqual(doneOnly.count, 1)
        XCTAssertEqual(doneOnly[0].body, "done one")

        let archivedOnly = tasks.filter { $0.status == .archived }
        XCTAssertEqual(archivedOnly.count, 1)
    }

    // MARK: - 9. Filter by doc scope: deriver returns one doc's projection per call

    func test_derive_filterByDocScope_excludesOtherDocs() {
        // Deriver is called per-doc; verify anchor docId matches caller arg.
        let pidA = "vwxy"
        let (tasksA, _) = TaskDeriver.derive(
            ops: [],
            paragraphs: [pidA: "- [ ] from doc a"],
            docId: "doc_a")
        XCTAssertEqual(tasksA.count, 1)
        XCTAssertEqual(tasksA[0].anchor?.docId, "doc_a")

        let pidB = "z023"
        let (tasksB, _) = TaskDeriver.derive(
            ops: [],
            paragraphs: [pidB: "- [ ] from doc b"],
            docId: "doc_b")
        XCTAssertEqual(tasksB.count, 1)
        XCTAssertEqual(tasksB[0].anchor?.docId, "doc_b")
    }

    // MARK: - 10. Project aggregation: project log derive call

    func test_derive_filterByProjectScope_aggregates() {
        // Project-scope deriver call with no paragraphs, just .taskCreate ops on __project__.
        let createOp = makeOp(
            opId: "op_proj_1",
            kind: .taskCreate,
            docId: "__project__",
            provenance: Op.Provenance(
                taskId: "op_proj_1",
                taskBody: "project task",
                taskPriority: 1.0,
                taskKind: "pane_created"))
        let (tasks, _) = TaskDeriver.derive(
            ops: [createOp],
            paragraphs: [:],
            docId: "__project__")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].kind, .paneCreated)
        XCTAssertEqual(tasks[0].body, "project task")
    }

    // MARK: - 11. Rebalance precision drift

    func test_derive_rebalanceFiresWhenPrioritiesConverge() {
        // Two pane tasks under same (nil) parent with priorities differing < 1e-9.
        let create1 = makeOp(
            opId: "op_p1",
            kind: .taskCreate,
            provenance: Op.Provenance(
                taskId: "op_p1",
                taskBody: "task one",
                taskPriority: 1.0,
                taskKind: "pane_created"))
        let create2 = makeOp(
            opId: "op_p2",
            kind: .taskCreate,
            provenance: Op.Provenance(
                taskId: "op_p2",
                taskBody: "task two",
                taskPriority: 1.0 + 1e-12, // way under 1e-9 delta
                taskKind: "pane_created"))
        let (tasks, rebal) = TaskDeriver.derive(
            ops: [create1, create2],
            paragraphs: [:],
            docId: "doc_test")
        XCTAssertEqual(tasks.count, 2)
        XCTAssertGreaterThan(rebal.count, 0,
            "Rebalance ops should be emitted when sibling delta < 1e-9")
        // Priorities should now be evenly spaced (1.0, 2.0)
        XCTAssertEqual(tasks[0].priority, 1.0)
        XCTAssertEqual(tasks[1].priority, 2.0)
        // Rebalance ops must be .taskPriorityChange
        for op in rebal {
            XCTAssertEqual(op.kind, .taskPriorityChange)
        }
    }

    // MARK: - 12. Unknown parent → parent-less

    func test_derive_unknownParent_isParentLess() {
        let pid = "1234"
        let docId = "doc_test"
        let childSynth = "inline:\(docId):\(pid):\(TaskDeriver.bodyHash("orphan child"))"
        // Parent never exists; only a parentChange op.
        let parentOp = makeOp(
            opId: "op_pc",
            kind: .taskParentChange,
            provenance: Op.Provenance(
                taskId: childSynth,
                taskParentId: "op_nonexistent"))
        let (tasks, _) = TaskDeriver.derive(
            ops: [parentOp],
            paragraphs: [pid: "- [ ] orphan child"],
            docId: docId)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks[0].parentTaskId,
            "Child referencing unknown parent renders as parent-less")
    }

    // MARK: - 13. Fountain [[todo:]] boneyard → open

    func test_derive_fountainTodoBoneyard_returnsOpenTask() {
        let pid = "5678"
        let (tasks, _) = TaskDeriver.derive(
            ops: [],
            paragraphs: [pid: "Some scene description [[todo: revise dialog]] more text"],
            docId: "doc_test")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].kind, .fountainBoneyard)
        XCTAssertEqual(tasks[0].status, .open)
        XCTAssertEqual(tasks[0].body, "revise dialog")
    }

    // MARK: - 14. Fountain [[done:]] → done

    func test_derive_fountainDoneBoneyard_returnsDoneTask() {
        let pid = "9abc"
        let (tasks, _) = TaskDeriver.derive(
            ops: [],
            paragraphs: [pid: "Action line [[done: fixed it]] continuing"],
            docId: "doc_test")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].kind, .fountainBoneyard)
        XCTAssertEqual(tasks[0].status, .done)
        XCTAssertEqual(tasks[0].body, "fixed it")
    }

    // MARK: - 15. bodyHash stable across normalization

    func test_bodyHash_stableAcrossNormalization() {
        let h1 = TaskDeriver.bodyHash("  Foo Bar  ")
        let h2 = TaskDeriver.bodyHash("foo  bar")
        let h3 = TaskDeriver.bodyHash("FOO BAR")
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h2, h3)
        XCTAssertEqual(h1.count, 8, "bodyHash returns first 8 hex chars")
    }

    // MARK: - 16. bodyHash distinct for distinct bodies

    func test_bodyHash_distinct_forDistinctBodies() {
        XCTAssertNotEqual(TaskDeriver.bodyHash("foo"), TaskDeriver.bodyHash("bar"))
    }

    // MARK: - 17. inline id is body-hash keyed, not line-index

    func test_derive_inlineId_isBodyHashKeyed_notLineIndex() {
        let pid = "dghj"
        let docId = "doc_test"
        // Priority op keyed to bodyHash("foo")
        let synthFoo = "inline:\(docId):\(pid):\(TaskDeriver.bodyHash("foo"))"
        let prioOp = makeOp(
            opId: "op_prio_foo",
            kind: .taskPriorityChange,
            provenance: Op.Provenance(
                taskId: synthFoo,
                taskPriority: 99.0))
        // Initially paragraph has "- [ ] foo\n- [ ] bar"
        // Then we insert "- [ ] zzz" above. Op is still keyed to bodyHash("foo").
        let (tasks, _) = TaskDeriver.derive(
            ops: [prioOp],
            paragraphs: [pid: "- [ ] zzz\n- [ ] foo\n- [ ] bar"],
            docId: docId)
        XCTAssertEqual(tasks.count, 3)
        let fooTask = tasks.first(where: { $0.body == "foo" })
        XCTAssertNotNil(fooTask)
        XCTAssertEqual(fooTask?.priority, 99.0,
            "Priority op survives reorder because it keys on body-hash")
    }

    // MARK: - 18. Duplicate inline body collapses to one task

    func test_derive_duplicateInlineBody_collapsesToOneTask() {
        let pid = "kmnp"
        let (tasks, _) = TaskDeriver.derive(
            ops: [],
            paragraphs: [pid: "- [ ] foo\n- [ ] foo"],
            docId: "doc_test")
        XCTAssertEqual(tasks.count, 1,
            "Duplicate normalized bodies collapse per spec §3.2")
        XCTAssertEqual(tasks[0].body, "foo")
    }
}
