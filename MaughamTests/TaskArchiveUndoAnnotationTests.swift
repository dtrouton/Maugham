import XCTest
import MaughamCore
@testable import Maugham

/// Task 8 — the compound INLINE-task archive undo must also REOPEN the
/// annotations its paragraph collapse swept.
///
/// Archiving an inline task whose paragraph holds nothing else collapses the
/// paragraph (`deleteParagraph`), which flags an orphan sweep. The compound
/// undo's `flushBurstNow()` fires that sweep as a SIDE EFFECT — archiving any
/// open annotation anchored to the removed paragraph — then `applyRestore`
/// brings the paragraph text (and the task) back. Before this fix the undo
/// left the annotation ARCHIVED: the text and task returned but the note on
/// them did not. The rewind path (`Document+RewindUndo`) already reopens
/// sweep-archived annotations; this mirrors that mechanism for the
/// task-archive compound undo.
///
/// `async throws` MainActor tests using `awaitPendingUndoWork()` (the T6
/// InlineArchiveUndo idiom). Default `groupsByEvent`, no manual undo grouping.
@MainActor
final class TaskArchiveUndoAnnotationTests: XCTestCase {

    // MARK: - Fixture (mirrors InlineArchiveUndoTests).

    private func makeProject(initialMd: String) throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TASK-ARCHIVE-UNDO-ANN-\(UUID().uuidString)")
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
                id: "doc-test", title: "C1", type: .document, path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    private func makeDocument(initialMd: String) async throws -> Document {
        let (project, path) = try makeProject(initialMd: initialMd)
        return try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
    }

    private func paragraphIds(of doc: Document) async throws -> [String] {
        let log = try await doc.opLog()
        let bootstrap = try XCTUnwrap(
            log.first(where: { $0.kind == .bootstrap }), "no bootstrap paragraph")
        return bootstrap.changes.map(\.paragraphId)
    }

    private func synthId(for doc: Document, anchor: String) -> String {
        "inline:\(doc.docId):\(anchor)"
    }

    private func status(_ doc: Document, _ id: String) -> TaskStatus? {
        doc.tasks(filter: .init(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases))).first { $0.id == id }?.status
    }

    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    // MARK: - The A6 finding: sweep-archived annotation reopens on undo.

    func test_inlineArchive_collapse_undo_reopensSweptAnnotation() async throws {
        // Paragraph 1 is SOLELY the task line → archive collapses it. A second
        // paragraph proves the survivor's annotation is untouched.
        let stored = """
        - [ ] foo <!--t-aaaaaa-->

        Some other prose.
        """
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        XCTAssertEqual(pids.count, 2, "two-paragraph fixture")
        let taskPid = pids[0]
        let survivorPid = pids[1]
        let originalText = doc.paragraph(id: taskPid)
        let inlineId = synthId(for: doc, anchor: "aaaaaa")

        // An OPEN comment anchored to the sole-task paragraph (the one that
        // collapses), plus a control comment on the survivor.
        let sweptAnnId = try await doc.addAnnotation(
            kind: .comment, paragraphId: taskPid, body: "note on the task line")
        let survivorAnnId = try await doc.addAnnotation(
            kind: .comment, paragraphId: survivorPid, body: "note on the survivor")
        XCTAssertEqual(annotation(doc, sweptAnnId)?.status, .open)
        XCTAssertEqual(annotation(doc, survivorAnnId)?.status, .open)

        let um = UndoManager()
        doc.archiveTask(id: inlineId, undoManager: um)
        XCTAssertNil(doc.paragraph(id: taskPid),
            "sole-task paragraph collapses on archive")
        XCTAssertEqual(status(doc, inlineId), .archived)

        um.undo(); await doc.awaitPendingUndoWork()

        // Text + task restored (the InlineArchiveUndo contract) …
        XCTAssertEqual(doc.paragraph(id: taskPid), originalText,
            "undo restores the deleted paragraph text")
        XCTAssertEqual(doc.sequence.first, taskPid,
            "restored paragraph re-inserts at its original sequence position")
        XCTAssertEqual(status(doc, inlineId), .open,
            "undo counters the archive's status override → open")

        // … AND the annotation the collapse-sweep archived is reopened.
        XCTAssertEqual(annotation(doc, sweptAnnId)?.status, .open,
            "undo reopens the annotation the paragraph-collapse sweep archived")
        XCTAssertEqual(annotation(doc, survivorAnnId)?.status, .open,
            "the survivor paragraph's annotation was never touched")
    }

    // MARK: - WB fix 1: close() during an in-flight compound undo stays consistent

    /// Whole-branch review (2026-07-11): Task 4's `drainTaskAppends()` at the top
    /// of `close()` awaits only the task-op appends ALREADY in flight. A compound
    /// undo (this file's scenario) runs in `_lastUndoWorkTask`'s async hop and its
    /// LATE appends — the status inverse via `appendTaskOpInternal`, the swept
    /// annotation's reopen — land AFTER that drain ran. Meanwhile the undo's TEXT
    /// side (`applyRestore` → `setFullText`) is `isClosed`-guarded and no-ops once
    /// husked. Without awaiting the undo hop, a quit between ⌘Z and `close()`
    /// husks mid-undo: the op side appends while the text side declines → a TORN
    /// op log on reload (paragraph gone, task un-archived / annotation reopened).
    ///
    /// The fix awaits `_lastUndoWorkTask` before husking, THEN drains the task
    /// appends the hop spawned, THEN flushes — so the undo either fully applies
    /// or (post-husk, via the fix-1b guards) fully declines; never torn.
    ///
    /// The delay makes the RED deterministic: without the drain-of-undo-work the
    /// hop's status-inverse disk append cannot land before we reload.
    func test_close_duringCompoundUndo_awaitsUndoWork_opLogStaysConsistent() async throws {
        let stored = """
        - [ ] foo <!--t-aaaaaa-->

        Some other prose.
        """
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let taskPid = pids[0]
        let inlineId = synthId(for: doc, anchor: "aaaaaa")

        // Open annotation on the sole-task paragraph → the collapse's sweep
        // archives it; the compound undo reopens it.
        let annId = try await doc.addAnnotation(
            kind: .comment, paragraphId: taskPid, body: "note on the task line")

        let um = UndoManager()
        doc.archiveTask(id: inlineId, undoManager: um)
        // Make the archive (taskArchive op) AND the collapse sweep (annotation
        // archive) durable BEFORE introducing the delay, so the reload baseline is
        // the archived state and only the UNDO's appends are subject to the race.
        await doc.drainTaskAppends()
        try await doc.flushBurstNow()            // fires the orphan sweep (annotation → archived)
        await doc.drainTaskAppends()
        XCTAssertEqual(status(doc, inlineId), .archived)
        XCTAssertEqual(annotation(doc, annId)?.status, .archived,
            "precondition: the collapse swept the annotation to archived")

        // Delay the detached task-op disk append so the undo hop's status-inverse
        // append cannot reach disk before close()+reload UNLESS close() drains it.
        Document._testDelayTaskAppends = .milliseconds(500)
        defer { Document._testDelayTaskAppends = nil }

        um.undo()                                // schedules the compound-undo hop
        await doc.close()                        // must await the hop + drain its appends

        // Reload from DISK. A CONSISTENT result = the undo FULLY applied: paragraph
        // restored, task open, annotation reopened. Any single facet lagging (e.g.
        // task still archived because its delayed inverse was dropped) is the tear.
        let reloaded = try await Document.load(
            url: doc.url, device: "m2", session: "s2", presenter: nil)
        XCTAssertNotNil(reloaded.paragraph(id: taskPid),
            "undo restored the collapsed paragraph (text side)")
        XCTAssertEqual(status(reloaded, inlineId), .open,
            "undo's status inverse is durable — task is open, not torn-archived")
        XCTAssertEqual(annotation(reloaded, annId)?.status, .open,
            "undo reopened the sweep-archived annotation, durably")
        await reloaded.close()
    }

    // MARK: - WB fix 1b: task/annotation op appends decline atomically on a husk

    /// The op-side mutation funnels (`appendTaskOpInternal`, `reopenAnnotation`)
    /// lacked the `isClosed` guard that `setParagraph`/`setFullText`/`deleteParagraph`
    /// carry. So a compound undo resuming AFTER a husk applied only half: the text
    /// side no-oped (guarded) while the op side appended to a cleared mirror / disk
    /// — a torn op log. Both must decline atomically on a husked doc.
    func test_appendTaskOpInternal_and_reopenAnnotation_noOpOnHuskedDoc() async throws {
        let stored = "- [ ] foo <!--t-aaaaaa-->\n\nSome other prose.\n"
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let taskPid = pids[0]
        let annId = try await doc.addAnnotation(
            kind: .comment, paragraphId: taskPid, body: "note")
        // Reject the annotation so there's a non-open status a stray reopen could
        // flip, and make it durable before we husk.
        try await doc.rejectAnnotation(id: annId)
        await doc.drainTaskAppends()
        try await doc.flushBurstNow()
        XCTAssertEqual(annotation(doc, annId)?.status, .rejected)

        await doc.close()   // husk: paragraphs/mirror/caches cleared, isClosed set

        // Post-husk op-side mutations must decline (mirror stays empty, nothing
        // reaches disk) — matching the already-guarded text side.
        let strayOpId = ULID.generate()
        doc.appendTaskOpInternal(Op(
            opId: strayOpId, docId: doc.docId, at: Date(),
            device: "m", session: "s", kind: .taskArchive,
            changes: [], sequence: nil,
            provenance: Op.Provenance(sessionId: "s", taskId: "inline:\(doc.docId):aaaaaa")))
        try await doc.reopenAnnotation(id: annId)
        await doc.drainTaskAppends()
        XCTAssertEqual(doc.opLogMirrorCount, 0,
            "appendTaskOpInternal/reopenAnnotation must no-op on a husked doc")

        // And nothing leaked to disk: the stray task op is absent and the
        // annotation stays rejected on reload.
        let reloaded = try await Document.load(
            url: doc.url, device: "m2", session: "s2", presenter: nil)
        let log = try await reloaded.opLog()
        XCTAssertFalse(log.contains { $0.opId == strayOpId },
            "the post-husk task op must not have reached disk")
        XCTAssertEqual(annotation(reloaded, annId)?.status, .rejected,
            "reopenAnnotation on a husked doc appended nothing — status stands")
        await reloaded.close()
    }
}
