import XCTest
import MaughamCore
@testable import Maugham

/// Load-time content + orphan-drop tests.
///
/// ADR 0019: the manuscript `.md` is the DERIVED form; `Document.load` takes
/// content + order ONLY from the op log, never from the `.md`'s anchors. The
/// op log a real burst writes always carries its `sequence` (Task 1), so these
/// fixtures give every burst its sequence and assert the op-log derivation —
/// including the surviving op-log-only cleanup: orphan paragraphs (ids the
/// deriver accumulated but the current `sequence` no longer references) are
/// dropped so the inline-task deriver doesn't surface phantom rows.
///
/// (Before ADR 0019 these exercised a `.md`-anchor recovery path — load read
/// the parsed `.md` to repair a stale/missing op-log sequence. That path is
/// gone; the op log is authoritative.)
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

        // Op log (the source of truth): bootstrap op claimed paragraph
        // `c1hx`; a later typing_burst replaced it with the 5-line checklist
        // paragraph `mnj6` AND captured the current `sequence` (["mnj6"]) —
        // exactly what a real burst writes (Task 1). `c1hx` lingers in the
        // deriver's `paragraphs` accumulator as an orphan (no longer in
        // `sequence`); load's orphan-drop must remove it.
        let bootstrapOp = """
        {"op_id":"01OPBOOTSTRAP","doc_id":"doc-divergent-test","at":"2026-05-24T20:00:00.000Z","device":"d","session":"s","kind":"bootstrap","changes":[{"paragraph_id":"c1hx","prior":null,"next":"- [ ] Write the big opening"}],"sequence":["c1hx"]}
        """
        let burst = """
        {"op_id":"01OPSTALESEQ","doc_id":"doc-divergent-test","at":"2026-05-24T20:01:00.000Z","device":"d","session":"s","kind":"typing_burst","changes":[{"paragraph_id":"mnj6","prior":null,"next":"- [ ] Write the big opening\\n- [ ] npoooo\\n- [ ] Task\\n- [ ] Write the inciting incident\\n- [ ] hhhh"}],"sequence":["mnj6"]}
        """
        let logContent = bootstrapOp + "\n" + burst + "\n"
        try logContent.write(to: opLogURL, atomically: true, encoding: .utf8)

        // A valid manifest so `resolveDocId`/`resolveProjectURL` resolve the
        // op log (a manifest missing required title/author/schemaVersion would
        // fail to decode → hash-fallback docId → op log not found).
        let manifestURL = tmp.appendingPathComponent("project.maugham.json")
        let manifest = ProjectManifest(
            type: .novel, title: "DLSRT", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: docId, title: "Chapter 1", type: .document,
                path: "manuscript/chapter-1.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: manifestURL)

        return Fixture(
            projectURL: projectURL, mdURL: mdURL,
            docId: docId, opLogURL: opLogURL)
    }

    func test_load_recoversFromStaleSequence_displayingAllFiveLines() async throws {
        let f = try makeDivergentFixture()
        let doc = try await Document.load(
            url: f.mdURL, device: "test", session: "s", presenter: nil)
        // The op log's current sequence (["mnj6"]) drives the display; the
        // orphan `c1hx` paragraph is dropped. displayText is mnj6's 5 lines.
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

    /// Reproduces the 9-tasks-instead-of-6 phantom from the second
    /// smoke run: the user split a single-paragraph checklist into
    /// 6 separate paragraphs. sequence ends up with all 6 current ids
    /// (op log captured the latest burst's sequence correctly), AND
    /// parsed .md has the same 6 ids. But the deriver's `paragraphs`
    /// map still carries entries for two pre-split paragraph ids
    /// (`c1hx`, `z3j6`) that the deriver accumulated from earlier
    /// typing_burst ops and never removed. Those orphan paragraphs each
    /// still contain `- [ ]` lines from before the split, so the
    /// inline-task deriver walks them too and surfaces phantom rows.
    ///
    /// The Recovery #3 path doesn't fire (parsed ⊆ sequence and
    /// sequence ⊆ parsed). The fix is the new Recovery #4 orphan-drop:
    /// restrict `paragraphs.keys` to `Set(sequence)` unconditionally.
    func test_load_dropsOrphanParagraphsWhenSequenceAndParsedAgree() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DLSRT-orphan-\(UUID().uuidString)")
        let manuscriptDir = tmp.appendingPathComponent("manuscript")
        let opsDir = tmp.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(
            at: manuscriptDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: opsDir, withIntermediateDirectories: true)
        let mdURL = manuscriptDir.appendingPathComponent("chapter-1.md")
        let docId = "doc-orphan-test"

        // .md has 2 paragraphs.
        let mdContent = """
        <!-- ¶newa -->

        - [ ] current item A

        <!-- ¶newb -->

        - [ ] current item B
        """
        try mdContent.write(to: mdURL, atomically: true, encoding: .utf8)

        // Op log: bootstrap minted `oldx`; later typing_burst created
        // newa/newb AND captured the new sequence. But `oldx` is still
        // in `paragraphs` (the deriver never removed it). Both `newa`
        // and `newb` agree with the .md.
        let bootstrap = """
        {"op_id":"01OPBOOTSTRAP","doc_id":"doc-orphan-test","at":"2026-05-25T08:00:00.000Z","device":"d","session":"s","kind":"bootstrap","changes":[{"paragraph_id":"oldx","prior":null,"next":"- [ ] STALE phantom"}],"sequence":["oldx"]}
        """
        let burst = """
        {"op_id":"01OPSPLITBURST","doc_id":"doc-orphan-test","at":"2026-05-25T08:01:00.000Z","device":"d","session":"s","kind":"typing_burst","changes":[{"paragraph_id":"newa","prior":null,"next":"- [ ] current item A"},{"paragraph_id":"newb","prior":null,"next":"- [ ] current item B"}],"sequence":["newa","newb"]}
        """
        let logContent = bootstrap + "\n" + burst + "\n"
        try logContent.write(
            to: opsDir.appendingPathComponent("\(docId).jsonl"),
            atomically: true, encoding: .utf8)

        let manifestURL = tmp.appendingPathComponent("project.maugham.json")
        let manifest = ProjectManifest(
            type: .novel, title: "DLSRT-orphan", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: docId, title: "Chapter 1", type: .document,
                path: "manuscript/chapter-1.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: manifestURL)

        let doc = try await Document.load(
            url: mdURL, device: "test", session: "s", presenter: nil)

        // Inline tasks: exactly 2 — one per paragraph in the .md.
        // Before the orphan drop the deriver also walked `oldx` and
        // produced a 3rd phantom task "STALE phantom".
        let tasks = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let inlineTasks = tasks.filter { $0.kind == .inlineMarkdown }
        XCTAssertEqual(inlineTasks.count, 2,
            "Orphan `oldx` paragraph must not produce phantom inline tasks even when sequence agrees with parsed .md")
        XCTAssertFalse(inlineTasks.contains { $0.body == "STALE phantom" },
            "STALE phantom task body must not surface")
    }
}
