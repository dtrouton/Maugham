import XCTest
import MaughamCore
@testable import Maugham

/// Spec §2.7 — the Archive action mutates manuscript text. Tests cover:
///   2.1 line-style mid-paragraph         → delete the line
///   2.2 line-style sole task in paragraph → paragraph collapses
///   2.3 inline mid-sentence              → splice + collapse one whitespace
///   2.4 inline at start of sentence      → splice + drop trailing space
///   2.5 inline at end of paragraph       → splice + drop leading space
///   2.6 inline with no surrounding ws    → splice segment only (word-glue)
///   2.7 two adjacent inline tasks        → only target spliced, neighbor stays
/// Plus a regression test for pane-created tasks (no inline anchor → op-only).
@MainActor
final class DocumentArchiveTextMutationTests: XCTestCase {

    // MARK: - Fixture (mirrors DocumentTaskAlignmentTests).

    private func makeProject(initialMd: String) throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ARCHIVE-\(UUID().uuidString)")
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

    private func makeDocument(initialMd: String) async throws -> Document {
        let (project, path) = try makeProject(initialMd: initialMd)
        return try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
    }

    /// Return the paragraph_ids the bootstrap minted, in document order.
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

    // MARK: - Case 2.1: line-style mid-paragraph

    func test_archive_lineStyleMidParagraph_deletesLine() async throws {
        let stored = """
        - [x] foo <!--t-aaaaaa-->
        - [ ] bar <!--t-bbbbbb-->
        - [ ] baz <!--t-cccccc-->
        """
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        XCTAssertEqual(pids.count, 1, "single paragraph fixture")
        let pid = pids[0]

        doc.archiveTask(id: synthId(for: doc, anchor: "bbbbbb"))

        XCTAssertEqual(doc.paragraph(id: pid), """
            - [x] foo <!--t-aaaaaa-->
            - [ ] baz <!--t-cccccc-->
            """)
        let archive = doc.opLogSnapshot.first { op in
            op.kind == .taskArchive
                && op.provenance?.taskId == synthId(for: doc, anchor: "bbbbbb")
        }
        XCTAssertNotNil(archive, "archive op must be emitted")
    }

    // MARK: - Case 2.2: line-style sole task in paragraph

    func test_archive_lineStyleSoleTaskInParagraph_collapsesParagraph() async throws {
        // Two paragraphs separated by a blank line. The first paragraph
        // contains ONLY one anchored task line; archiving it should drop
        // the whole paragraph from the sequence.
        let stored = """
        - [x] foo <!--t-aaaaaa-->

        - [ ] bar <!--t-bbbbbb-->
        """
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        XCTAssertEqual(pids.count, 2, "two-paragraph fixture")
        let solePid = pids[0]
        let survivorPid = pids[1]

        doc.archiveTask(id: synthId(for: doc, anchor: "aaaaaa"))

        XCTAssertNil(doc.paragraph(id: solePid),
            "sole-task paragraph should collapse")
        XCTAssertEqual(doc.paragraph(id: survivorPid),
            "- [ ] bar <!--t-bbbbbb-->")
    }

    // MARK: - Case 2.3: inline mid-sentence

    func test_archive_inlineMidSentence_splicesAndCollapsesSpace() async throws {
        let stored = "Anna walked across the room [[todo: tighten this]]<!--t-9k2x6a--> and saw the cat."
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let pid = pids[0]

        doc.archiveTask(id: synthId(for: doc, anchor: "9k2x6a"))

        XCTAssertEqual(doc.paragraph(id: pid),
            "Anna walked across the room and saw the cat.")
    }

    // MARK: - Case 2.4: inline at start of sentence

    func test_archive_inlineAtStartOfSentence_splicesTrailingSpace() async throws {
        let stored = "[[todo: tighten this]]<!--t-9k2x6a--> Anna walked across the room."
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let pid = pids[0]

        doc.archiveTask(id: synthId(for: doc, anchor: "9k2x6a"))

        XCTAssertEqual(doc.paragraph(id: pid),
            "Anna walked across the room.")
    }

    // MARK: - Case 2.5: inline at end of paragraph

    func test_archive_inlineAtEndOfParagraph_splicesLeadingSpace() async throws {
        let stored = "Anna walked across the room. [[todo: revisit later]]<!--t-9k2x6a-->"
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let pid = pids[0]

        doc.archiveTask(id: synthId(for: doc, anchor: "9k2x6a"))

        XCTAssertEqual(doc.paragraph(id: pid),
            "Anna walked across the room.")
    }

    // MARK: - Case 2.6: inline with no surrounding whitespace (word-glue)

    func test_archive_inlineNoSurroundingWhitespace_splicesSegmentOnly() async throws {
        let stored = "Anna[[todo: name choice]]<!--t-9k2x6a-->walked."
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let pid = pids[0]

        doc.archiveTask(id: synthId(for: doc, anchor: "9k2x6a"))

        XCTAssertEqual(doc.paragraph(id: pid), "Annawalked.")
    }

    // MARK: - Case 2.7: two adjacent inline tasks — only target spliced

    func test_archive_twoAdjacentInlineTasks_onlyTargetSpliced() async throws {
        let stored = "[[todo: A]]<!--t-aaaaaa-->[[todo: B]]<!--t-bbbbbb--> some text."
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let pid = pids[0]

        doc.archiveTask(id: synthId(for: doc, anchor: "aaaaaa"))

        // After splicing the first anchored segment, B's anchor and its
        // bracketed body remain intact (no whitespace collapse since the
        // surviving neighbour was directly adjacent).
        XCTAssertEqual(doc.paragraph(id: pid),
            "[[todo: B]]<!--t-bbbbbb--> some text.")
    }

    // MARK: - Pane-created task (no inline anchor) — op-only archive

    func test_archive_paneCreatedTask_emitsOpWithoutTextMutation() async throws {
        let stored = "Just some prose."
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let pid = pids[0]

        let task = doc.createPaneTask(body: "pane thing", parentTaskId: nil)
        let priorText = doc.paragraph(id: pid)

        doc.archiveTask(id: task.id)

        XCTAssertEqual(doc.paragraph(id: pid), priorText,
            "pane-created archive must not mutate paragraph text")
        XCTAssertTrue(doc.opLogSnapshot.contains { op in
            op.kind == .taskArchive
                && op.provenance?.taskId == task.id
        }, "archive op must still emit for pane-created tasks")
    }

    // MARK: - Multi-anchor-per-line: archiving one preserves the other

    func test_archive_multiAnchorPerLine_archivesOnlyTarget() async throws {
        // Both anchors sit on the same line; only `aaaaaa` is archived.
        // The line-style detection must reject this case (two anchors on
        // one line) so the inline splice path handles it cleanly.
        let stored = "First [[todo: A]]<!--t-aaaaaa--> middle [[todo: B]]<!--t-bbbbbb--> last."
        let doc = try await makeDocument(initialMd: stored)
        let pids = try await paragraphIds(of: doc)
        let pid = pids[0]

        doc.archiveTask(id: synthId(for: doc, anchor: "aaaaaa"))

        XCTAssertEqual(doc.paragraph(id: pid),
            "First middle [[todo: B]]<!--t-bbbbbb--> last.")
    }

    // MARK: - didSplice only if the splice wrote (P3c plan 2 Task 8)

    /// **A splice that did not write is not a splice.** On a read-only
    /// recovery view both text primitives refuse, so the paragraph is
    /// unchanged — and `archiveTask` used to set `didSplice` anyway,
    /// registering the COMPOUND undo for text that never moved and leaving the
    /// D2 flag armed for the next, unrelated editor push. Now it reads the
    /// paragraph back.
    func test_anInlineArchiveThatWroteNothingArmsNoCompoundUndo() async throws {
        let stored = "Anna walked [[todo: tighten]]<!--t-9k2x6a--> away."
        let (project, path) = try makeProject(initialMd: stored)
        defer { try? FileManager.default.removeItem(at: project) }
        let docURL = project.appendingPathComponent(path)
        let first = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil)
        let docId = first.docId
        try await first.flushBurstNow()
        await first.close()
        // Squat a second device's file so only the read-only partial view opens
        // (`ReadOnlyRecoveryTests`' shape): every mutation there refuses.
        let badURL = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: DeviceSlug.make(from: "bad"), in: project)
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)
        let doc = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil,
            recovery: .readOnlyPartial)
        XCTAssertTrue(doc.isReadOnlyRecovery, "premise: a view that writes nothing")
        let pid = try await paragraphIds(of: doc)[0]
        let before = doc.paragraph(id: pid)
        XCTAssertNotNil(before)

        doc.archiveTask(id: synthId(for: doc, anchor: "9k2x6a"), undoManager: UndoManager())

        XCTAssertEqual(doc.paragraph(id: pid), before, "premise: the splice wrote nothing")
        XCTAssertFalse(doc._undoCoherentApplyPending,
                       "no splice, so no undo-coherent push is pending")
        await doc.close()
    }

    /// The other direction: a splice that wrote arms the flag for the push it
    /// is about to make, exactly as before.
    func test_anInlineArchiveThatWroteArmsTheCompoundUndo() async throws {
        let stored = "Anna walked [[todo: tighten]]<!--t-9k2x6a--> away."
        let doc = try await makeDocument(initialMd: stored)
        defer { try? FileManager.default.removeItem(at: doc.opStore.projectURL) }
        let pid = try await paragraphIds(of: doc)[0]

        doc.archiveTask(id: synthId(for: doc, anchor: "9k2x6a"), undoManager: UndoManager())

        XCTAssertEqual(doc.paragraph(id: pid), "Anna walked away.")
        XCTAssertTrue(doc._undoCoherentApplyPending,
                      "the splice wrote, so its push is undo-coherent")
        await doc.close()
    }
}
