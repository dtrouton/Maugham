import XCTest
import MaughamCore
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

    /// Regex pattern for the synthetic id form `inline:<docId>:<6-char anchor>`.
    /// Used in assertions where the anchor id is fresh-minted (not literal).
    private static let anchorAlphabet = "0123456789abcdefghjkmnpqrstvwxyz"

    private func isMintedInlineId(_ id: String, docId: String) -> Bool {
        let expectedPrefix = "inline:\(docId):"
        guard id.hasPrefix(expectedPrefix) else { return false }
        let anchor = String(id.dropFirst(expectedPrefix.count))
        guard anchor.count == 6 else { return false }
        return anchor.allSatisfy { Self.anchorAlphabet.contains($0) }
    }

    // MARK: - 1. Empty inputs

    func test_derive_emptyOpsAndParagraphs_returnsEmpty() {
        let (tasks, rebal, mints) = TaskDeriver.derive(
            ops: [], paragraphs: [:], docId: "doc_test")
        XCTAssertTrue(tasks.isEmpty)
        XCTAssertTrue(rebal.isEmpty)
        XCTAssertTrue(mints.isEmpty)
    }

    // MARK: - 2. Inline markdown checkbox: open

    func test_derive_singleInlineCheckbox_returnsOpenTask() {
        let pid = "abcd"
        let (tasks, _, mints) = TaskDeriver.derive(
            ops: [],
            paragraphs: [pid: "- [ ] foo"],
            docId: "doc_test")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].kind, .inlineMarkdown)
        XCTAssertEqual(tasks[0].status, .open)
        XCTAssertEqual(tasks[0].body, "foo")
        XCTAssertEqual(tasks[0].anchor?.docId, "doc_test")
        XCTAssertEqual(tasks[0].anchor?.paragraphId, pid)
        XCTAssertTrue(isMintedInlineId(tasks[0].id, docId: "doc_test"))
        XCTAssertEqual(mints.count, 1, "unanchored line triggers a mint")
    }

    // MARK: - 3. Inline checked: done

    func test_derive_inlineCheckedBox_returnsDoneTask() {
        let pid = "bcde"
        let (tasks, _, _) = TaskDeriver.derive(
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
        let (tasks, _, _) = TaskDeriver.derive(
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

    // MARK: - 5. Priority override on inline (anchor id)

    func test_derive_priorityOpOverridesDefault() {
        let pid = "cdef"
        let docId = "doc_test"
        // Use an anchored line so the synth id is deterministic.
        let synthId = "inline:\(docId):aaaaaa"
        let prioOp = makeOp(
            opId: "op_prio_1",
            kind: .taskPriorityChange,
            provenance: Op.Provenance(
                taskId: synthId,
                taskPriority: 42.5))
        let (tasks, _, mints) = TaskDeriver.derive(
            ops: [prioOp],
            paragraphs: [pid: "- [ ] foo <!--t-aaaaaa-->"],
            docId: docId)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].id, synthId)
        XCTAssertEqual(tasks[0].priority, 42.5)
        XCTAssertTrue(mints.isEmpty, "anchored line does not trigger a mint")
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
        let childSynth = "inline:\(docId):bbbbbb"
        let parentOp = makeOp(
            opId: "op_parent_change",
            kind: .taskParentChange,
            provenance: Op.Provenance(
                taskId: childSynth,
                taskParentId: "op_parent"))

        let (tasks, _, _) = TaskDeriver.derive(
            ops: [parentCreate, parentOp],
            paragraphs: [pid: "- [ ] child thing <!--t-bbbbbb-->"],
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
        let (tasks, _, _) = TaskDeriver.derive(
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
        let (tasks, _, _) = TaskDeriver.derive(
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
        let (tasksA, _, _) = TaskDeriver.derive(
            ops: [],
            paragraphs: [pidA: "- [ ] from doc a"],
            docId: "doc_a")
        XCTAssertEqual(tasksA.count, 1)
        XCTAssertEqual(tasksA[0].anchor?.docId, "doc_a")

        let pidB = "z023"
        let (tasksB, _, _) = TaskDeriver.derive(
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
        let (tasks, _, _) = TaskDeriver.derive(
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
        let (tasks, rebal, _) = TaskDeriver.derive(
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
        let childSynth = "inline:\(docId):cccccc"
        // Parent never exists; only a parentChange op.
        let parentOp = makeOp(
            opId: "op_pc",
            kind: .taskParentChange,
            provenance: Op.Provenance(
                taskId: childSynth,
                taskParentId: "op_nonexistent"))
        let (tasks, _, _) = TaskDeriver.derive(
            ops: [parentOp],
            paragraphs: [pid: "- [ ] orphan child <!--t-cccccc-->"],
            docId: docId)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks[0].parentTaskId,
            "Child referencing unknown parent renders as parent-less")
    }

    // MARK: - 13. Fountain [[todo:]] boneyard → open

    func test_derive_fountainTodoBoneyard_returnsOpenTask() {
        let pid = "5678"
        let (tasks, _, _) = TaskDeriver.derive(
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
        let (tasks, _, _) = TaskDeriver.derive(
            ops: [],
            paragraphs: [pid: "Action line [[done: fixed it]] continuing"],
            docId: "doc_test")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].kind, .fountainBoneyard)
        XCTAssertEqual(tasks[0].status, .done)
        XCTAssertEqual(tasks[0].body, "fixed it")
    }

    // MARK: - 15. Anchored inline id survives line reorder

    func test_derive_anchoredInlineId_survivesReorder() {
        let pid = "dghj"
        let docId = "doc_test"
        // Anchor `ddddde` is keyed on the persistent anchor, not body or position.
        let synthFoo = "inline:\(docId):ddddde"
        let prioOp = makeOp(
            opId: "op_prio_foo",
            kind: .taskPriorityChange,
            provenance: Op.Provenance(
                taskId: synthFoo,
                taskPriority: 99.0))
        // Paragraph re-ordered; the anchored "foo" line is now in the middle.
        let (tasks, _, _) = TaskDeriver.derive(
            ops: [prioOp],
            paragraphs: [pid: "- [ ] zzz\n- [ ] foo <!--t-ddddde-->\n- [ ] bar"],
            docId: docId)
        XCTAssertEqual(tasks.count, 3)
        let fooTask = tasks.first(where: { $0.body == "foo" })
        XCTAssertNotNil(fooTask)
        XCTAssertEqual(fooTask?.priority, 99.0,
            "Priority op survives reorder because anchor id is stable")
    }

    // MARK: - 16. Duplicate inline bodies — distinct anchors yield distinct tasks

    func test_derive_duplicateInlineBody_doesNotCollapse_whenAnchoredDistinctly() {
        let pid = "kmnp"
        let (tasks, _, _) = TaskDeriver.derive(
            ops: [],
            paragraphs: [pid: "- [ ] foo <!--t-aaaaaa-->\n- [ ] foo <!--t-bbbbbb-->"],
            docId: "doc_test")
        XCTAssertEqual(tasks.count, 2,
            "two anchored duplicates must be distinct tasks")
        XCTAssertEqual(Set(tasks.map(\.id)),
            ["inline:doc_test:aaaaaa", "inline:doc_test:bbbbbb"])
    }

    // MARK: - 17. Unanchored inline task mints an anchor (plan Step 4.2)

    func test_derive_unanchoredInlineTask_mintsAnchor() {
        let paraId = "mpqr"  // 4-char paragraph id (Tripwire #8)
        let paragraphs = [paraId: "- [ ] foo"]
        let result = TaskDeriver.derive(
            ops: [], paragraphs: paragraphs, docId: "doc-x")
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.mintedAnchors.count, 1)
        let minted = result.mintedAnchors[0]
        XCTAssertEqual(minted.paragraphId, paraId)
        XCTAssertEqual(minted.body, "foo")
        XCTAssertEqual(minted.anchorId.count, 6)
        XCTAssertEqual(result.tasks[0].id, "inline:doc-x:\(minted.anchorId)")
    }

    // MARK: - 18. Anchored inline task preserves its anchor

    func test_derive_anchoredInlineTask_preservesAnchor() {
        let paraId = "nptq"
        let paragraphs = [paraId: "- [ ] foo <!--t-9k2x6a-->"]
        let result = TaskDeriver.derive(
            ops: [], paragraphs: paragraphs, docId: "doc-x")
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks[0].id, "inline:doc-x:9k2x6a")
        XCTAssertTrue(result.mintedAnchors.isEmpty,
            "anchored tasks should NOT trigger minting")
    }

    // MARK: - 19. Duplicate-body anchored distinctly → two tasks

    func test_derive_duplicateBodyAnchoredDistinctly_yieldsTwoTasks() {
        let paraId = "pqrs"
        let paragraphs = [paraId: """
        - [ ] foo <!--t-aaaaaa-->
        - [ ] foo <!--t-bbbbbb-->
        """]
        let result = TaskDeriver.derive(
            ops: [], paragraphs: paragraphs, docId: "doc-x")
        XCTAssertEqual(result.tasks.count, 2,
            "two anchored duplicates must be distinct tasks")
        XCTAssertEqual(Set(result.tasks.map(\.id)),
            ["inline:doc-x:aaaaaa", "inline:doc-x:bbbbbb"])
    }

    // MARK: - 20. MintedAnchor.lineIndex on markdown line tasks

    func test_derive_unanchoredMarkdownTask_mintedAnchorHasCorrectLineIndex() {
        let pid = "qrst"
        let paragraphs = [pid: "- [ ] alpha\n- [ ] beta"]
        let result = TaskDeriver.derive(
            ops: [], paragraphs: paragraphs, docId: "doc-x")
        XCTAssertEqual(result.mintedAnchors.count, 2)
        let alpha = result.mintedAnchors.first(where: { $0.body == "alpha" })
        let beta = result.mintedAnchors.first(where: { $0.body == "beta" })
        XCTAssertEqual(alpha?.lineIndex, 0)
        XCTAssertEqual(beta?.lineIndex, 1)
        XCTAssertEqual(alpha?.kind, .inlineMarkdown)
        XCTAssertNil(alpha?.intraLineOffset, "markdown line-style is whole-line")
    }

    // MARK: - 21. MintedAnchor.intraLineOffset on Fountain inline tasks

    func test_derive_unanchoredFountainTodo_mintedAnchorHasIntraLineOffset() {
        let pid = "rstv"
        let paragraphs = [pid: "Anna walked [[todo: tighten]] across the room."]
        let result = TaskDeriver.derive(
            ops: [], paragraphs: paragraphs, docId: "doc-x")
        XCTAssertEqual(result.mintedAnchors.count, 1)
        let mint = result.mintedAnchors[0]
        XCTAssertEqual(mint.kind, .fountainBoneyard)
        XCTAssertEqual(mint.body, "tighten")
        XCTAssertEqual(mint.lineIndex, 0)
        XCTAssertNotNil(mint.intraLineOffset,
            "Fountain inline form needs intra-line offset for Task 5 splice")
        // The closing `]]` is at position 28 (0-based, just past "tighten]]").
        // intraLineOffset is the offset immediately after `]]` relative to the
        // start of the line — which equals the absolute UTF-16 offset here.
        // "Anna walked [[todo: tighten]]" is 29 UTF-16 chars; offset after ]] = 29.
        XCTAssertEqual(mint.intraLineOffset, 29)
    }

    // MARK: - 22. Mixed anchored + unanchored — only unanchored mint

    func test_derive_mixedAnchoredAndUnanchored_onlyUnanchoredAreMinted() {
        let pid = "stvw"
        let paragraphs = [pid: """
        - [ ] anchored <!--t-aaaaaa-->
        - [ ] fresh
        """]
        let result = TaskDeriver.derive(
            ops: [], paragraphs: paragraphs, docId: "doc-x")
        XCTAssertEqual(result.tasks.count, 2)
        XCTAssertEqual(result.mintedAnchors.count, 1)
        XCTAssertEqual(result.mintedAnchors[0].body, "fresh")
        XCTAssertEqual(result.mintedAnchors[0].lineIndex, 1)
        XCTAssertTrue(result.tasks.contains { $0.id == "inline:doc-x:aaaaaa" })
    }
}
