import XCTest
import MaughamCore
@testable import Maugham

/// ADR 0018 / Task 6: closed-doc task derivation must read paragraphs from the
/// op log, NEVER the on-disk `.md`. A stale `.md` that no longer contains an
/// inline `- [ ]` task must be invisible to task derivation; only the op-log
/// content drives what tasks are surfaced.
@MainActor
final class TasksOpLogSourceTests: XCTestCase {

    func test_closedDocTasks_readOpLog_notStaleMd() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TasksOpLog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/ch1.md"
        let docId   = "doc-tasks-adr0018"
        let docURL  = tmp.appendingPathComponent(docPath)

        // --- seed op log ---------------------------------------------------
        // 1. Write initial content so Bootstrap can seed the op log.
        try "Hello world.".write(to: docURL, atomically: true, encoding: .utf8)

        // 2. Write the manifest.
        let item = StructureItem(
            id: docId, title: "Ch1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        // 3. Bootstrap: Document.load → Bootstrap.run → seeds op log.
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        // 4. Obtain the bootstrap paragraph id and inject an inline task via
        //    the op log (setParagraph + flush).
        let log = try await doc.opLog()
        guard let bootstrap = log.first(where: { $0.kind == .bootstrap }),
              let pid = bootstrap.changes.first?.paragraphId else {
            return XCTFail("no bootstrap paragraph")
        }
        doc.setParagraph(id: pid, text: "- [ ] op-log-only task")
        try await doc.flushBurstNow()

        // --- corrupt the .md -----------------------------------------------
        // Overwrite the on-disk .md with content that has NO inline task.
        // The op log is now the ONLY correct source of truth.
        try "No tasks here.".write(to: docURL, atomically: true, encoding: .utf8)

        // --- closed-doc aggregation ----------------------------------------
        // Load a fresh ProjectStore (no DocumentStore → doc is "closed").
        let store = try await ProjectStore.load(from: tmp)
        // Do NOT attach a DocumentStore — the doc must be treated as closed.

        let tasks = store.listTasksAcrossProject(
            filter: TaskFilter(scope: .project, statuses: Set(TaskStatus.allCases)))

        XCTAssertTrue(
            tasks.contains { $0.kind == .inlineMarkdown && $0.body == "op-log-only task" },
            "closed-doc task derivation must find the task from the op log, "
            + "not be fooled by the stale .md that lacks the task line")
    }
}
