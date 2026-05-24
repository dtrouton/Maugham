import XCTest
@testable import Maugham

/// Regression tests for the load-time sequence/paragraph recovery paths
/// that surfaced when the editor showed only the first line of a 5-line
/// checklist whose paragraph had been split + reinserted across multiple
/// typing bursts. The .md autosave kept up; the op log's last explicit
/// sequence lagged behind. The fix:
///
/// 1. Crash-recovery synthesized op now captures a sequence from the
///    parsed .md.
/// 2. Load detects stale-sequence-vs-parsed (parsed has ids not in
///    sequence, OR sequence has ids not in parsed) and prefers parsed's
///    ordering, dropping orphan paragraphs from the in-memory map.
@MainActor
final class DocumentLoadSequenceRecoveryTests: XCTestCase {

    private struct Fixture {
        let projectURL: URL
        let mdURL: URL
        let docId: String
        let opLogURL: URL
    }

    /// Builds a project directory with a doc whose op log + .md disagree
    /// on the current paragraph sequence. Mimics the production
    /// "user split a paragraph mid-session" failure mode.
    private func makeDivergentFixture() throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DLSRT-\(UUID().uuidString)")
        let projectURL = tmp
        let manuscriptDir = tmp.appendingPathComponent("manuscript")
        let opsDir = tmp.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(
            at: manuscriptDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: opsDir, withIntermediateDirectories: true)
        let mdURL = manuscriptDir.appendingPathComponent("chapter-1.md")
        let docId = "doc-divergent-test"
        let opLogURL = opsDir.appendingPathComponent("\(docId).jsonl")

        // .md has one paragraph anchored as `mnj6` with 5 lines.
        let mdContent = """
        <!-- ¶mnj6 -->

        - [ ] Write the big opening
        - [ ] npoooo
        - [ ] Task
        - [ ] Write the inciting incident
        - [ ] hhhh
        """
        try mdContent.write(to: mdURL, atomically: true, encoding: .utf8)

        // Op log: bootstrap op claimed paragraph `c1hx`. A later typing
        // burst added `mnj6` but did NOT set `sequence` (the bug we're
        // recovering from). So the deriver's sequence stays at ["c1hx"]
        // and paragraph `mnj6` is in `paragraphs` but unreachable via
        // displayText.
        let bootstrapOp = """
        {"op_id":"01OPBOOTSTRAP","doc_id":"doc-divergent-test","at":"2026-05-24T20:00:00.000Z","device":"d","session":"s","kind":"bootstrap","changes":[{"paragraph_id":"c1hx","prior":null,"next":"- [ ] Write the big opening"}],"sequence":["c1hx"]}
        """
        let staleSeqBurst = """
        {"op_id":"01OPSTALESEQ","doc_id":"doc-divergent-test","at":"2026-05-24T20:01:00.000Z","device":"d","session":"s","kind":"typing_burst","changes":[{"paragraph_id":"mnj6","prior":null,"next":"- [ ] Write the big opening\\n- [ ] npoooo\\n- [ ] Task\\n- [ ] Write the inciting incident\\n- [ ] hhhh"}]}
        """
        // Note: staleSeqBurst has no `sequence` field — that's the bug.
        let logContent = bootstrapOp + "\n" + staleSeqBurst + "\n"
        try logContent.write(to: opLogURL, atomically: true, encoding: .utf8)

        // The Document.load path expects a project.maugham.json existence
        // check; supply a minimal one so `resolveProjectURL` finds it.
        let manifestURL = tmp.appendingPathComponent("project.maugham.json")
        let manifest = """
        {"name":"DLSRT","type":"novel","created":"2026-05-24T20:00:00Z","modified":"2026-05-24T20:01:00Z","structure":[{"id":"\(docId)","title":"Chapter 1","type":"document","path":"manuscript/chapter-1.md"}]}
        """
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        return Fixture(
            projectURL: projectURL, mdURL: mdURL,
            docId: docId, opLogURL: opLogURL)
    }

    func test_load_recoversFromStaleSequence_displayingAllFiveLines() async throws {
        let f = try makeDivergentFixture()
        let doc = try await Document.load(
            url: f.mdURL, device: "test", session: "s", presenter: nil)
        // Before the recovery fix, displayText was "- [ ] Write the big
        // opening" (the c1hx text only). The recovery should restore the
        // .md-canonical state.
        let expected = """
        - [ ] Write the big opening
        - [ ] npoooo
        - [ ] Task
        - [ ] Write the inciting incident
        - [ ] hhhh
        """
        XCTAssertEqual(doc.displayText, expected)
    }

    func test_load_recoversFromStaleSequence_dropsOrphanParagraphFromTaskDerive() async throws {
        let f = try makeDivergentFixture()
        let doc = try await Document.load(
            url: f.mdURL, device: "test", session: "s", presenter: nil)
        // Inline tasks should be exactly 5 (one per `- [ ]` line in the
        // sole surviving paragraph `mnj6`). Before the orphan-paragraph
        // drop, the deriver also walked the stale `c1hx` paragraph and
        // produced a 6th inline task ("Write the big opening" twice).
        let tasks = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let inlineTasks = tasks.filter { $0.kind == .inlineMarkdown }
        XCTAssertEqual(inlineTasks.count, 5,
            "Orphan paragraphs (not in sequence) must not produce inline tasks")
    }
}
