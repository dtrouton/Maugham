import XCTest
import MaughamCore
@testable import Maugham

/// Task 6 — compound ⌘Z undo of an INLINE-task archive.
///
/// Archiving an inline task is compound: a `.taskArchive` op PLUS a paragraph
/// rewrite (`setParagraph`) or delete (`deleteParagraph`). The undo must
/// restore BOTH — the paragraph text (via the extracted `applyRestore`, which
/// re-inserts a deleted paragraph into `sequence`) and the open status (a
/// `.taskStatusChange` inverse that counters the archive's status override).
///
/// Pane-created archives are NOT compound (no manuscript text is touched); they
/// keep Task 4's op-only registration — pinned here so the branch split holds.
///
/// These are `async throws` tests using `awaitPendingUndoWork()` (the TaskUndo
/// idiom), not the AnnotationAcceptUndo pump/sync shape. Default `groupsByEvent`,
/// no manual undo grouping (a `removeAllActions` inside a manual group corrupts
/// NSUndoManager state — the T5 crash).
@MainActor
final class InlineArchiveUndoTests: XCTestCase {

    // MARK: - Fixture (mirrors DocumentArchiveTextMutationTests).

    private func makeProject(initialMd: String) throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("INLINE-ARCHIVE-UNDO-\(UUID().uuidString)")
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
        guard let bootstrap = log.first(where: { $0.kind == .bootstrap }) else {
            XCTFail("no bootstrap paragraph")
            throw NSError(domain: "test", code: 0)
        }
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

    // MARK: - Deleted-paragraph case (sole task in paragraph)

    func test_inlineArchive_undo_restoresParagraphAndOpenStatus() async throws {
        // Paragraph 1 is SOLELY the task line → archive collapses it. A second
        // paragraph proves sequence-aware re-insertion (pid1 comes back at
        // position 0, not appended at the tail).
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

        let um = UndoManager()
        doc.archiveTask(id: inlineId, undoManager: um)
        XCTAssertNil(doc.paragraph(id: taskPid),
            "sole-task paragraph collapses on archive")
        XCTAssertEqual(status(doc, inlineId), .archived)

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.paragraph(id: taskPid), originalText,
            "undo restores the deleted paragraph text")
        XCTAssertEqual(doc.sequence.first, taskPid,
            "restored paragraph re-inserts at its original sequence position")
        XCTAssertEqual(doc.paragraph(id: survivorPid), "Some other prose.",
            "the untouched paragraph is unaffected")
        XCTAssertEqual(status(doc, inlineId), .open,
            "undo counters the archive's status override → open")
    }

    // MARK: - Rewrite case (task shares a paragraph with prose)

    func test_inlineArchive_undo_restoresRewrittenParagraph() async throws {
        let stored = "Anna walked [[todo: tighten this]]<!--t-9k2x6a--> home."
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let pid = pids[0]
        let originalText = doc.paragraph(id: pid)
        let inlineId = synthId(for: doc, anchor: "9k2x6a")

        let um = UndoManager()
        doc.archiveTask(id: inlineId, undoManager: um)
        XCTAssertEqual(doc.paragraph(id: pid), "Anna walked home.",
            "archive splices the boneyard out, paragraph survives")
        XCTAssertEqual(status(doc, inlineId), .archived)

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.paragraph(id: pid), originalText,
            "undo restores the rewritten paragraph text")
        XCTAssertEqual(status(doc, inlineId), .open,
            "undo counters the archive's status override → open")
    }

    // MARK: - Undo then redo re-archives

    func test_inlineArchive_undo_redo_reArchives() async throws {
        let stored = """
        - [ ] foo <!--t-aaaaaa-->

        Some other prose.
        """
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let taskPid = pids[0]
        let inlineId = synthId(for: doc, anchor: "aaaaaa")

        let um = UndoManager()
        doc.archiveTask(id: inlineId, undoManager: um)

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertNotNil(doc.paragraph(id: taskPid))
        XCTAssertEqual(status(doc, inlineId), .open)
        XCTAssertTrue(um.canRedo, "undo must nest a re-archive registration")

        um.redo(); await doc.awaitPendingUndoWork()
        XCTAssertNil(doc.paragraph(id: taskPid),
            "redo re-splices → paragraph collapses again")
        XCTAssertEqual(status(doc, inlineId), .archived,
            "redo re-archives the task")

        // Re-arm: redo's forward re-archive forwarded the LIVE manager, so a
        // second ⌘Z restores again (a nil-forwarded manager — the T3 dead-cycle
        // regression — would fail here).
        XCTAssertTrue(um.canUndo,
            "redo's forward re-archive must re-register undo — the cycle re-arms")
        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertNotNil(doc.paragraph(id: taskPid),
            "a second ⌘Z after ⇧⌘Z restores the paragraph again")
        XCTAssertEqual(status(doc, inlineId), .open)
    }

    // MARK: - Foreign op advanced the doc → loud no-op

    func test_inlineArchive_undo_afterForeignOp_isLoudNoOp() async throws {
        let stored = """
        - [ ] foo <!--t-aaaaaa-->

        Some other prose.
        """
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let taskPid = pids[0]
        let survivorPid = pids[1]
        let inlineId = synthId(for: doc, anchor: "aaaaaa")

        let um = UndoManager()
        doc.archiveTask(id: inlineId, undoManager: um)
        XCTAssertNil(doc.paragraph(id: taskPid))

        // Simulate a cross-device merge landing AFTER our archive: a foreign
        // external_edit op (different device + session) touching another
        // paragraph. It advances the doc past our captured pre-archive tip.
        let foreign = Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: "other-mac", session: "other-session",
            kind: .externalEdit,
            changes: [.init(paragraphId: survivorPid,
                            prior: "Some other prose.",
                            next: "Some other prose, edited elsewhere.")],
            sequence: nil, provenance: nil)
        doc._opLogMirror.append(foreign)

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertNil(doc.paragraph(id: taskPid),
            "foreign-op guard declines: the deleted paragraph stays gone")
        XCTAssertEqual(status(doc, inlineId), .archived,
            "the status is NOT restored either — the whole compound undo declines")
    }

    // MARK: - Pane-created archive stays simple (op-only undo)

    func test_paneArchive_stillSimple() async throws {
        let stored = "Just some prose."
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let pid = pids[0]
        let priorText = doc.paragraph(id: pid)

        let task = doc.createPaneTask(body: "pane thing", parentTaskId: nil)
        let um = UndoManager()
        doc.archiveTask(id: task.id, undoManager: um)
        XCTAssertEqual(status(doc, task.id), .archived)
        XCTAssertEqual(doc.paragraph(id: pid), priorText,
            "pane-created archive must not mutate paragraph text")

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(status(doc, task.id), .open,
            "undo of a pane-created archive restores the prior status")
        XCTAssertEqual(doc.paragraph(id: pid), priorText,
            "no text machinery ran — the paragraph is untouched")
    }
}
