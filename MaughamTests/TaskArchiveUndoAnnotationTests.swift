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
}
