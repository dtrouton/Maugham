import XCTest
import MaughamCore
@testable import Maugham

/// Task 7 — ⌘Z undo of a History-Rewind restore.
///
/// A rewind restore (`restoreToOp`) rewinds manuscript text, reopens accepts
/// stranded past the target (D3), and archives open annotations on removed
/// paragraphs (the orphan sweep). `restoreToOpUndoable` wraps that in a single
/// grouped ⌘Z action that reverses the WHOLE rewind:
///   - text back to the pre-restore tip (a fresh compensating `restoreToOp`
///     stamped `.undoRewind` so it never opens a task-rewind window),
///   - each D3-reopened accept re-accepted status-only (preserving the original
///     `userResponse`),
///   - each sweep-archived annotation reopened.
/// Redo re-runs `restoreToOp` from scratch so it can never disagree with a
/// fresh rewind.
///
/// These are `async throws` MainActor tests using `awaitPendingUndoWork()`
/// (the T6 InlineArchiveUndo idiom): `um.undo()` runs its handler synchronously
/// and hops the async compensating restore onto `_lastUndoWorkTask`. Default
/// `groupsByEvent`, NO manual undo grouping (a `removeAllActions` inside a
/// manual group corrupts NSUndoManager state — the T5 crash).
@MainActor
final class RewindUndoTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let doc: Document
        let pid: String
    }

    /// Builds a wired Document over `initialMd` and returns it plus its single
    /// bootstrap paragraph id (4-char alphabet-restricted, tripwire 8).
    private func makeHarness(_ initialMd: String) async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewindUndo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let relativePath = "manuscript/c1.md"
        try initialMd.write(
            to: tmp.appendingPathComponent(relativePath),
            atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: "doc-x", title: "Chapter 1", type: .document, path: relativePath)
        let manifest = ProjectManifest(
            type: .novel, title: "Rewind Undo Test", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let ds = try await DocumentStore.open(url: tmp)
        let docURL = tmp.appendingPathComponent(relativePath)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: relativePath)

        let pid = try await doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId
        return Harness(doc: doc, pid: pid)
    }

    /// The annotation with `id`, across ALL statuses (`annotations()` defaults
    /// to `.open` only, which would hide an accepted / archived one).
    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    // MARK: - Full round-trip: text + status + userResponse

    func test_restore_undo_returnsTextAndStatusesToPreRestoreState() async throws {
        let h = try await makeHarness("Original sentence here.")
        let doc = h.doc, pid = h.pid

        // Target = the op id BEFORE the accept (right after suggestion creation),
        // so the rewind rewinds past the accept AND the later typing burst.
        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Improved sentence here.")
        let beforeAcceptOpId = try await doc.opLog().last!.opId

        let originalUserResponse = "LGTM — accepted"
        try await doc.acceptAnnotation(id: annId, userResponse: originalUserResponse)
        XCTAssertEqual(doc.paragraph(id: pid), "Improved sentence here.")

        // A typing burst AFTER the accept: the pre-restore tip carries it, so
        // the undo must bring it back too.
        doc.setParagraph(id: pid, text: "Improved sentence here. And more.")
        try await doc.flushBurstNow()

        let preParagraphs = doc.paragraphs
        let preStatus = annotation(doc, annId)?.status
        XCTAssertEqual(preStatus, .accepted)

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: beforeAcceptOpId, undoManager: um)

        XCTAssertNotEqual(doc.paragraphs, preParagraphs, "rewound past the accept + typing")
        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.")
        XCTAssertEqual(annotation(doc, annId)?.status, .open, "D3 reopened the stranded accept")

        um.undo(); await doc.awaitPendingUndoWork()

        XCTAssertEqual(doc.paragraphs, preParagraphs, "text back to the pre-restore tip")
        XCTAssertEqual(annotation(doc, annId)?.status, preStatus, "re-accepted status-only")
        XCTAssertEqual(annotation(doc, annId)?.userResponse, originalUserResponse,
            "the re-accept preserved the original userResponse")
    }

    // MARK: - Sweep-archived annotation reopens on undo

    func test_restore_undo_reopensSweepArchivedAnnotations() async throws {
        let h = try await makeHarness("First paragraph.")
        let doc = h.doc
        // Target BEFORE the second paragraph exists — the rewind removes it.
        let targetOpId = try await doc.opLog().last!.opId

        doc.setFullText("First paragraph.\n\nSecond paragraph.\n")
        try await doc.flushBurstNow()
        let burst = try await doc.opLog().last(where: { $0.kind == .typingBurst })
        let p2Id = try XCTUnwrap(
            burst?.changes.first(where: { $0.next.contains("Second") })?.paragraphId,
            "couldn't find the second paragraph's id in the burst op")

        // An OPEN comment anchored to the paragraph the rewind will remove.
        let annId = try await doc.addAnnotation(
            kind: .comment, paragraphId: p2Id, body: "a note on p2")
        XCTAssertEqual(annotation(doc, annId)?.status, .open)

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: targetOpId, undoManager: um)

        XCTAssertFalse(doc.sequence.contains(p2Id), "rewind removed the paragraph")
        XCTAssertEqual(annotation(doc, annId)?.status, .archived,
            "the orphan sweep archived the annotation on the removed paragraph")

        um.undo(); await doc.awaitPendingUndoWork()

        XCTAssertTrue(doc.sequence.contains(p2Id), "undo restored the paragraph")
        XCTAssertEqual(annotation(doc, annId)?.status, .open,
            "undo reopened the sweep-archived annotation")
    }

    // MARK: - Redo re-runs the restore

    func test_restore_undo_redo_reRunsRestore() async throws {
        let h = try await makeHarness("Original sentence here.")
        let doc = h.doc, pid = h.pid

        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Improved sentence here.")
        let beforeAcceptOpId = try await doc.opLog().last!.opId
        try await doc.acceptAnnotation(id: annId)
        doc.setParagraph(id: pid, text: "Improved sentence here. And more.")
        try await doc.flushBurstNow()

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: beforeAcceptOpId, undoManager: um)
        let postRestoreParagraphs = doc.paragraphs
        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.")

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertNotEqual(doc.paragraphs, postRestoreParagraphs, "undo restored pre-rewind text")
        XCTAssertTrue(um.canRedo, "undo must nest a redo registration")

        um.redo(); await doc.awaitPendingUndoWork()
        // The redo re-runs restoreToOp from scratch (a fresh rewind, not a
        // replay): the manuscript text returns to the post-restore state AND
        // the annotation derives `.open` again — a redo can never disagree
        // with a fresh rewind. The status half pins the stranded-accept
        // detector's status-only clause: the intervening undo re-accepted via
        // an EMPTY-changes `claudeAccept`, and the detector must judge
        // strandedness against the changes-carrying accept it stands in for.
        XCTAssertEqual(doc.paragraphs, postRestoreParagraphs,
            "redo re-runs restoreToOp → post-restore text again")
        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.",
            "redo rewound the paragraph past the accept again")
        XCTAssertEqual(annotation(doc, annId)?.status, .open,
            "redo reopened the stranded accept again — never disagrees with a fresh rewind")
    }

    // MARK: - Manual second restore after undo — same fresh-rewind agreement

    func test_restore_undo_thenManualSecondRestore_reopensAccept() async throws {
        // Same defect class as redo, reached WITHOUT ⇧⌘Z: restore → ⌘Z → the
        // user runs History Rewind again to the same target. The second
        // restoreToOp must re-detect the (status-only re-accepted) stranded
        // accept and reopen it, just like the first restore did.
        let h = try await makeHarness("Original sentence here.")
        let doc = h.doc, pid = h.pid

        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Improved sentence here.")
        let beforeAcceptOpId = try await doc.opLog().last!.opId
        try await doc.acceptAnnotation(id: annId)

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: beforeAcceptOpId, undoManager: um)
        XCTAssertEqual(annotation(doc, annId)?.status, .open)

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.paragraph(id: pid), "Improved sentence here.")
        XCTAssertEqual(annotation(doc, annId)?.status, .accepted,
            "undo re-accepted (status-only)")

        _ = try await doc.restoreToOp(opId: beforeAcceptOpId)
        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.")
        XCTAssertEqual(annotation(doc, annId)?.status, .open,
            "a manual second restore to the same target reopens the accept again")
    }

    // MARK: - Task dimension: undo closes the task-rewind window

    /// Sorted task-state fingerprint for pre/post comparison.
    private func taskFingerprint(_ doc: Document) -> [String] {
        doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
            .map { "\($0.id)|\($0.status.rawValue)|\($0.body)" }
            .sorted()
    }

    func test_restore_undo_restoresTaskDimension() async throws {
        // Rewind past BOTH a typing burst and pane-task ops. ⌘Z must bring
        // back text AND the pane tasks: the compensating `.undoRewind` restore
        // correctly opens no new task window, and the appended `.rewind`
        // closer marker folds the excluded task ops back into the derive.
        let h = try await makeHarness("Original sentence here.")
        let doc = h.doc, pid = h.pid
        let targetOpId = try await doc.opLog().last!.opId

        let task = doc.createPaneTask(body: "pane thing", parentTaskId: nil)
        doc.setTaskStatus(id: task.id, status: .done)
        doc.setParagraph(id: pid, text: "Original sentence here. And more.")
        try await doc.flushBurstNow()
        let preRewindTasks = taskFingerprint(doc)
        XCTAssertTrue(preRewindTasks.contains { $0.hasPrefix("\(task.id)|done") })

        let um = UndoManager()
        let result = try await doc.restoreToOpUndoable(opId: targetOpId, undoManager: um)
        XCTAssertTrue(result.rewoundTaskOps, "the rewound range contained task ops")
        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.")
        XCTAssertFalse(taskFingerprint(doc).contains { $0.hasPrefix(task.id) },
            "the rewind excluded the pane task")

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here. And more.",
            "text back to the pre-restore tip")
        XCTAssertEqual(taskFingerprint(doc), preRewindTasks,
            "pane tasks match the pre-rewind derive — the task window closed")
    }

    func test_markerOnlyRestore_undo_restoresTaskState_andRedoReExcludes() async throws {
        // Task ops only, no text change: the restore takes the marker branch
        // (text-inert `.checkpointRestore` so TaskDeriver can slice). Before
        // this fix its registered undo did nothing; now it must reverse the
        // task window — and redo must re-run the restore and re-exclude.
        let h = try await makeHarness("Prose that never changes.")
        let doc = h.doc
        try await doc.flushBurstNow()
        let targetOpId = try await doc.opLog().last!.opId

        let task = doc.createPaneTask(body: "created after target", parentTaskId: nil)
        let preRewindTasks = taskFingerprint(doc)
        XCTAssertTrue(preRewindTasks.contains { $0.hasPrefix(task.id) })
        let preParagraphs = doc.paragraphs

        let um = UndoManager()
        let result = try await doc.restoreToOpUndoable(opId: targetOpId, undoManager: um)
        XCTAssertNotNil(result.restoreOp, "marker-only rewind still appends a task marker")
        XCTAssertTrue(result.rewoundTaskOps)
        XCTAssertEqual(doc.paragraphs, preParagraphs, "no text changed")
        XCTAssertFalse(taskFingerprint(doc).contains { $0.hasPrefix(task.id) },
            "the marker excluded the task")

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(taskFingerprint(doc), preRewindTasks,
            "undo of a marker-only rewind restores the task state")
        XCTAssertEqual(doc.paragraphs, preParagraphs, "text untouched throughout")
        XCTAssertTrue(um.canRedo, "the undo nested a redo registration")

        um.redo(); await doc.awaitPendingUndoWork()
        XCTAssertFalse(taskFingerprint(doc).contains { $0.hasPrefix(task.id) },
            "redo re-ran the restore from scratch and re-excluded the task")

        // Re-arm: a second ⌘Z after ⇧⌘Z restores again (live-manager forward).
        XCTAssertTrue(um.canUndo)
        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(taskFingerprint(doc), preRewindTasks,
            "the ⌘Z/⇧⌘Z cycle re-arms")
    }

    // MARK: - Foreign op advanced the doc → loud no-op

    func test_restore_undo_afterForeignOps_isLoudNoOp() async throws {
        let h = try await makeHarness("Original sentence here.")
        let doc = h.doc, pid = h.pid

        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Improved sentence here.")
        let beforeAcceptOpId = try await doc.opLog().last!.opId
        try await doc.acceptAnnotation(id: annId)

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: beforeAcceptOpId, undoManager: um)
        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.")

        // A cross-device merge lands AFTER the restore, changing the live text so
        // it no longer equals the post-restore state the undo captured. The undo
        // must decline (History Rewind is the tool for that tangle), not clobber.
        let foreign = Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: "other-mac", session: "other-session",
            kind: .externalEdit,
            changes: [.init(paragraphId: pid,
                            prior: "Original sentence here.",
                            next: "Edited elsewhere entirely.")],
            sequence: nil, provenance: nil)
        doc._opLogMirror.append(foreign)
        doc.setParagraph(id: pid, text: "Edited elsewhere entirely.")
        let diverged = doc.paragraphs

        um.undo(); await doc.awaitPendingUndoWork()

        XCTAssertEqual(doc.paragraphs, diverged,
            "the fire-time guard declined — the diverged text is not clobbered")
    }
}
