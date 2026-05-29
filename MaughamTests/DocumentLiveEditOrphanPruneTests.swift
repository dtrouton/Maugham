import XCTest
import MaughamCore
@testable import Maugham

/// Regression: merging two checkbox paragraphs into one during a live
/// edit session left the pre-merge paragraph_id's text lingering in
/// `paragraphs` (the deriver's accumulator only adds/updates, never
/// removes). The inline-task deriver walks every `paragraphs` entry,
/// so the merged-away paragraph surfaced its inline tasks again as
/// phantom rows in the Tasks pane.
///
/// The fix: `setFullText` (and any other path that mutates `sequence`)
/// prunes `paragraphs` entries whose ids left the new sequence. Same
/// invariant we enforce at load time (`paragraphs.keys ⊆ sequence`)
/// applied live during editing.
@MainActor
final class DocumentLiveEditOrphanPruneTests: XCTestCase {

    private func makeDoc(text: String = "") async throws -> Document {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DLEOP-\(UUID().uuidString)")
        let manuscriptDir = tmp.appendingPathComponent("manuscript")
        try FileManager.default.createDirectory(
            at: manuscriptDir, withIntermediateDirectories: true)
        let mdURL = manuscriptDir.appendingPathComponent("doc.md")
        try text.write(to: mdURL, atomically: true, encoding: .utf8)
        return try await Document.load(
            url: mdURL, device: "test", session: "s", presenter: nil)
    }

    /// Build a document with two paragraphs, each holding one inline
    /// checkbox. Returns (doc, paraIds).
    private func makeDocWithTwoCheckboxParagraphs() async throws
        -> (Document, [String])
    {
        let doc = try await makeDoc(text: "Hello.")
        // Replace the single bootstrap paragraph with two checklist
        // paragraphs via setFullText. ParagraphParser splits on blank
        // lines so the blank-line separator yields 2 parsed paragraphs.
        // Bootstrap minted the first id; we need a second id for the
        // second paragraph — embed both anchors explicitly.
        let bootstrapId = doc.opLogSnapshot.first(where: {
            $0.kind == .bootstrap
        })?.changes.first?.paragraphId ?? "abcd"
        let secondId = "wxyz"
        let stored = """
        <!-- ¶\(bootstrapId) -->

        - [ ] item A

        <!-- ¶\(secondId) -->

        - [ ] item B
        """
        doc.setFullText(stored)
        return (doc, [bootstrapId, secondId])
    }

    func test_mergingParagraphs_removesOrphanFromParagraphsMap() async throws {
        let (doc, ids) = try await makeDocWithTwoCheckboxParagraphs()
        let firstId = ids[0]
        _ = ids[1]

        // Sanity: both paragraphs derive one inline task each.
        let pre = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        XCTAssertEqual(pre.filter { $0.kind == .inlineMarkdown }.count, 2,
            "pre-merge: two inline tasks across two paragraphs")

        // Merge: simulate the user deleting the blank line between the
        // two paragraphs. The first paragraph absorbs both checkboxes;
        // the second paragraph_id leaves `sequence`.
        let merged = """
        <!-- ¶\(firstId) -->

        - [ ] item A
        - [ ] item B
        """
        doc.setFullText(merged)

        // After merge: one paragraph in sequence, two inline tasks
        // (one per `- [ ]` line in the surviving paragraph). The
        // dropped paragraph_id's text must NOT linger and re-surface
        // as a phantom 3rd task.
        let post = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let inlineTasks = post.filter { $0.kind == .inlineMarkdown }
        XCTAssertEqual(inlineTasks.count, 2,
            "merge should leave exactly two inline tasks (one per surviving `- [ ]` line); a 3rd phantom indicates the orphan paragraph_id's text lingered in `paragraphs`")
    }

    func test_deletingParagraph_removesOrphanFromParagraphsMap() async throws {
        let (doc, ids) = try await makeDocWithTwoCheckboxParagraphs()
        let firstId = ids[0]

        // Delete: keep only the first paragraph by removing the second
        // entirely from the next stored form.
        let trimmed = """
        <!-- ¶\(firstId) -->

        - [ ] item A
        """
        doc.setFullText(trimmed)

        let post = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let inlineTasks = post.filter { $0.kind == .inlineMarkdown }
        XCTAssertEqual(inlineTasks.count, 1,
            "delete should leave exactly one inline task; the removed paragraph's `- [ ] item B` must not surface as a phantom")
        XCTAssertEqual(inlineTasks.first?.body, "item A")
    }
}
