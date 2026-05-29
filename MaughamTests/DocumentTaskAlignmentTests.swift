import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class DocumentTaskAlignmentTests: XCTestCase {

    // MARK: - Fixture

    private func makeProject(initialMd: String = "Hello.") throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ALIGN-\(UUID().uuidString)")
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

    /// Extract every `<!--t-XXXXXX-->` anchor id from text.
    private func anchorIds(in s: String) -> [String] {
        let pattern = #"<!--t-([0123456789abcdefghjkmnpqrstvwxyz]{6})-->"#
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        let matches = regex.matches(
            in: s, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    /// Drive `setFullText` with the displayed form. The displayed form is
    /// anchor-free (mirrors what the NSTextView shows after RenderFilter
    /// strips anchors). Returns the resulting paragraph text for the
    /// supplied paragraph id (after restoration).
    private func displayedFormFromParagraph(_ s: String) -> String {
        // Strip task anchors so we simulate what the editor surface sees.
        return RenderFilter.stripTaskAnchorsInline(s)
    }

    /// Force a derive + persistence by reading tasks once.
    private func deriveTasks(_ doc: Document) {
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
    }

    // MARK: - Tests

    func test_bodyEditPreservesAnchor() async throws {
        let doc = try await makeDocument()
        let pid = try await firstParagraphId(of: doc)
        // Plant an anchored line.
        doc.setParagraph(id: pid, text: "- [ ] foo <!--t-aaaaaa-->")
        deriveTasks(doc)
        // Build display form (anchor-free), edit, drive via setFullText.
        let displayed = "- [ ] Tighten foo"
        doc.setFullText(displayed)
        deriveTasks(doc)
        let para = doc.paragraph(id: pid)!
        XCTAssertTrue(para.contains("<!--t-aaaaaa-->"),
            "body edit must preserve anchor; got: \(para)")
        XCTAssertTrue(para.contains("Tighten foo"))
    }

    func test_insertNewLineBetweenAnchored_leavesNewUnanchored() async throws {
        let doc = try await makeDocument()
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: """
        - [ ] foo <!--t-aaaaaa-->
        - [ ] bar <!--t-bbbbbb-->
        """)
        deriveTasks(doc)
        // Writer adds a middle line. Build the displayed (anchor-free) text.
        let displayed = """
        - [ ] foo
        - [ ] baz
        - [ ] bar
        """
        doc.setFullText(displayed)
        deriveTasks(doc)
        let para = doc.paragraph(id: pid)!
        // Original anchors preserved.
        XCTAssertTrue(para.contains("<!--t-aaaaaa-->"))
        XCTAssertTrue(para.contains("<!--t-bbbbbb-->"))
        // baz line got a freshly minted anchor (3 total).
        XCTAssertEqual(anchorIds(in: para).count, 3)
        // foo / bar stay attached to their bodies.
        let lines = para.split(separator: "\n").map(String.init)
        let fooLine = lines.first { $0.contains(" foo") }!
        XCTAssertTrue(fooLine.contains("<!--t-aaaaaa-->"))
        let barLine = lines.first { $0.contains(" bar") }!
        XCTAssertTrue(barLine.contains("<!--t-bbbbbb-->"))
    }

    func test_deleteOneOfThreeDuplicatesInParagraph_archivesOne() async throws {
        let doc = try await makeDocument()
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: """
        - [ ] foo <!--t-aaaaaa-->
        - [ ] foo <!--t-bbbbbb-->
        - [ ] foo <!--t-cccccc-->
        """)
        deriveTasks(doc)
        // Delete the middle line. Display form:
        let displayed = """
        - [ ] foo
        - [ ] foo
        """
        doc.setFullText(displayed)
        deriveTasks(doc)
        let para = doc.paragraph(id: pid)!
        let remaining = Set(anchorIds(in: para))
        XCTAssertEqual(remaining.count, 2)
        let all: Set<String> = ["aaaaaa", "bbbbbb", "cccccc"]
        let archived = all.subtracting(remaining)
        XCTAssertEqual(archived.count, 1, "exactly one anchor archived")
        // Verify a .taskArchive op fired for the missing anchor.
        let archivedId = archived.first!
        let synth = "inline:\(doc.docId):\(archivedId)"
        let archives = doc.opLogSnapshot.filter {
            $0.kind == .taskArchive && $0.provenance?.taskId == synth
        }
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(archives.first?.provenance?.userResponse, "user-deleted")
    }

    func test_reorderTwoLinesWithinParagraph_preservesBothAnchors() async throws {
        let doc = try await makeDocument()
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: """
        - [ ] foo <!--t-aaaaaa-->
        - [ ] bar <!--t-bbbbbb-->
        """)
        deriveTasks(doc)
        let displayed = """
        - [ ] bar
        - [ ] foo
        """
        doc.setFullText(displayed)
        deriveTasks(doc)
        let para = doc.paragraph(id: pid)!
        XCTAssertEqual(Set(anchorIds(in: para)), ["aaaaaa", "bbbbbb"])
        let lines = para.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("bar"))
        XCTAssertTrue(lines[0].contains("<!--t-bbbbbb-->"))
        XCTAssertTrue(lines[1].contains("foo"))
        XCTAssertTrue(lines[1].contains("<!--t-aaaaaa-->"))
        // No archive ops — both anchors are still alive.
        let archives = doc.opLogSnapshot.filter { $0.kind == .taskArchive }
        XCTAssertEqual(archives.count, 0)
    }

    func test_crossParagraphCutPaste_anchorFollowsBody() async throws {
        // Setup: two paragraphs where the source paragraph A has an
        // anchored task line plus other content, and the destination
        // paragraph B has unrelated content. The writer cuts the task
        // line out of A and pastes it into B. Per-paragraph alignment
        // can't see the move (A loses the line, B gains it), so V2's
        // Pass 2 cross-paragraph correlation — gated on cursor info —
        // must catch it.
        let initial = """
        Some lead-in.
        - [ ] foo <!--t-aaaaaa-->
        And a tail.

        prose paragraph that is plenty long enough.
        """
        let doc = try await makeDocument(initialMd: initial)
        let log = try await doc.opLog()
        guard let bootstrap = log.first(where: { $0.kind == .bootstrap }) else {
            XCTFail("missing bootstrap"); return
        }
        XCTAssertGreaterThanOrEqual(bootstrap.changes.count, 2)
        let aPid = bootstrap.changes[0].paragraphId
        let bPid = bootstrap.changes[1].paragraphId
        deriveTasks(doc)
        XCTAssertTrue(doc.paragraph(id: aPid)!.contains("foo"))

        // After cut/paste: A loses its middle line; B gains it on a new
        // tail line. Two paragraphs separated by blank line.
        let displayedWithBreak = """
        Some lead-in.
        And a tail.

        prose paragraph that is plenty long enough.
        - [ ] foo
        """
        // Pre-edit cursor: inside the foo line of A. The prior
        // displayed form was "Some lead-in.\n- [ ] foo\nAnd a tail.\n\n
        // prose paragraph that is plenty long enough." The foo line
        // starts at offset 14 (after "Some lead-in.\n") so cursor 18 is
        // inside foo.
        let preEdit = 18
        // Post-edit cursor: at end of the new B (right inside the
        // pasted foo line).
        let postEdit = (displayedWithBreak as NSString).length - 1
        doc.setFullText(
            displayedWithBreak,
            preEditCursor: preEdit,
            postEditCursor: postEdit)
        deriveTasks(doc)

        // The anchor must survive (Pass 2 cross-paragraph correlation).
        let materialized = doc.materialize()
        XCTAssertTrue(materialized.contains("<!--t-aaaaaa-->"),
            "cross-paragraph move must preserve anchor; got: \(materialized)")
        // Anchor must travel with the body: it should be attached to a
        // line that contains "- [ ] foo".
        let bPara = doc.paragraph(id: bPid) ?? ""
        XCTAssertTrue(
            bPara.contains("- [ ] foo") && bPara.contains("<!--t-aaaaaa-->"),
            "anchor should land on the pasted line in B; got: \(bPara)")
        let archives = doc.opLogSnapshot.filter {
            $0.kind == .taskArchive
                && $0.provenance?.taskId == "inline:\(doc.docId):aaaaaa"
        }
        XCTAssertEqual(archives.count, 0,
            "cross-paragraph move should rescind the deletion")
    }

    func test_searchReplaceAcrossDoc_preservesAnchors() async throws {
        // Multiple anchored tasks with a common token in their bodies.
        // Search/replace "tighten" → "polish" globally. Per-paragraph
        // alignment should preserve all anchors via LCS (Pass 1b) since
        // line positions are stable.
        let doc = try await makeDocument()
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: """
        - [ ] tighten A <!--t-aaaaaa-->
        - [ ] tighten B <!--t-bbbbbb-->
        - [ ] tighten C <!--t-cccccc-->
        """)
        deriveTasks(doc)
        let displayed = """
        - [ ] polish A
        - [ ] polish B
        - [ ] polish C
        """
        doc.setFullText(displayed)
        deriveTasks(doc)
        let para = doc.paragraph(id: pid)!
        XCTAssertEqual(Set(anchorIds(in: para)),
            ["aaaaaa", "bbbbbb", "cccccc"],
            "all three anchors preserved despite body rename; got: \(para)")
        let archives = doc.opLogSnapshot.filter { $0.kind == .taskArchive }
        XCTAssertEqual(archives.count, 0)
    }

    func test_deleteWholeParagraphContainingTask_archivesAnchor() async throws {
        // Two paragraphs; second is sole task; writer deletes second paragraph.
        let initial = """
        prose paragraph

        - [ ] zap <!--t-aaaaaa-->
        """
        let doc = try await makeDocument(initialMd: initial)
        deriveTasks(doc)
        // Display form sees both paragraphs sans anchors.
        let displayed = "prose paragraph"
        doc.setFullText(displayed)
        deriveTasks(doc)
        let archives = doc.opLogSnapshot.filter {
            $0.kind == .taskArchive
                && $0.provenance?.taskId == "inline:\(doc.docId):aaaaaa"
        }
        XCTAssertEqual(archives.count, 1,
            "whole-paragraph delete should archive the inline anchor")
        XCTAssertEqual(archives.first?.provenance?.userResponse, "user-deleted")
    }

    func test_crossParagraphCutPaste_withoutCursor_anchorLost() async throws {
        // Same setup as the cross-paragraph test, but WITHOUT cursor info.
        // Pass 2 is gated on both cursors being non-nil; nil cursors
        // degrade alignment to per-paragraph (spec §2.4.3) and the anchor
        // is archived as a user-deleted line.
        let initial = """
        Some lead-in.
        - [ ] foo <!--t-aaaaaa-->
        And a tail.

        prose paragraph that is plenty long enough.
        """
        let doc = try await makeDocument(initialMd: initial)
        deriveTasks(doc)

        let displayed = """
        Some lead-in.
        And a tail.

        prose paragraph that is plenty long enough.
        - [ ] foo
        """
        // No cursor info — Pass 2 disabled.
        doc.setFullText(displayed)
        deriveTasks(doc)
        let archives = doc.opLogSnapshot.filter {
            $0.kind == .taskArchive
                && $0.provenance?.taskId == "inline:\(doc.docId):aaaaaa"
        }
        XCTAssertEqual(archives.count, 1,
            "without cursor info, V2 alignment cannot detect the move")
    }

    func test_alignmentEmitsArchiveOps_forUnpairedPriorAnchors() async throws {
        // Multiple anchored tasks; writer deletes all of them. Each gets
        // an archive op with cause = user-deleted.
        let doc = try await makeDocument()
        let pid = try await firstParagraphId(of: doc)
        doc.setParagraph(id: pid, text: """
        - [ ] one <!--t-aaaaaa-->
        - [ ] two <!--t-bbbbbb-->
        """)
        deriveTasks(doc)
        let displayed = "now I'm just writing prose."
        doc.setFullText(displayed)
        deriveTasks(doc)
        let archives = doc.opLogSnapshot.filter { $0.kind == .taskArchive }
        XCTAssertEqual(archives.count, 2)
        let archivedIds = Set(archives.compactMap { $0.provenance?.taskId })
        XCTAssertEqual(archivedIds, [
            "inline:\(doc.docId):aaaaaa",
            "inline:\(doc.docId):bbbbbb"
        ])
        for op in archives {
            XCTAssertEqual(op.provenance?.userResponse, "user-deleted")
        }
    }

    func test_cursorAccessors_recordWithoutInvalidatingCache() async throws {
        // recordCursorAt / recordPostEditCursor must be cheap and NOT
        // bump any version. Tripwire #6 — no parallel observable state.
        let doc = try await makeDocument()
        let preVersion = doc.tasksVersion
        let preAnnotationsVersion = doc.annotationsVersion
        doc.recordCursorAt(42)
        doc.recordPostEditCursor(99)
        XCTAssertEqual(doc.tasksVersion, preVersion)
        XCTAssertEqual(doc.annotationsVersion, preAnnotationsVersion)
    }
}
