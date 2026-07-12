import XCTest
import MaughamCore
@testable import Maugham

/// E1 (2026-07-11 maintainability review §2): task ops — and their ⌘Z
/// compensating ops — are appended to disk in a detached fire-and-forget
/// `Task` (`Document.appendTaskOpInternal`). A prompt quit after a task
/// mutation could return from `close()` before that append landed, silently
/// reverting the state on relaunch. `close()` must drain the in-flight task
/// appends before husking so a task op is durable once `close()` returns.
@MainActor
final class TaskOpDurabilityTests: XCTestCase {

    /// A pane task exists ONLY as a `.taskCreate` op appended via the
    /// fire-and-forget path — the cleanest exercise of the durability
    /// contract. The `_testDelayTaskAppends` hook slows the detached append
    /// so the race is deterministic: without the close-time drain, `close()`
    /// returns and the reload reads disk BEFORE the delayed append lands, so
    /// the task is missing.
    func test_close_drainsInFlightTaskAppends_opOnDiskAfterClose() async throws {
        Document._testDelayTaskAppends = .milliseconds(400)
        defer { Document._testDelayTaskAppends = nil }

        let (dir, docURL) = try makeTestProject(
            prefix: "taskop-durability", initialMd: "Hello.\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        let doc = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil)
        let created = doc.createPaneTask(body: "buy milk", parentTaskId: nil)
        await doc.close()   // must drain the in-flight append before husking

        // Reload from DISK only — if the append was dropped, the task is gone.
        let reloaded = try await Document.load(
            url: docURL, device: "m2", session: "s2", presenter: nil)
        let tasks = reloaded.tasks(filter: TaskFilter(
            scope: .document(docId: reloaded.docId),
            statuses: Set(TaskStatus.allCases)))
        XCTAssertTrue(tasks.contains { $0.id == created.id },
            "task op must be durable once close() returns")
        await reloaded.close()
    }
}
