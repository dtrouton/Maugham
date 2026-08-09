import XCTest
@testable import Maugham

final class CompileJobManagerTests: XCTestCase {

    func testRegister_storesJob() async {
        let mgr = CompileJobManager()
        let id = await mgr.register(phase: .renderingBody)
        let job = await mgr.get(jobID: id)
        XCTAssertNotNil(job)
        XCTAssertEqual(job?.status, .inProgress(phase: .renderingBody))
    }

    func testUpdate_changesPhase() async {
        let mgr = CompileJobManager()
        let id = await mgr.register(phase: .compiling)
        await mgr.updatePhase(jobID: id, phase: .writingOutput)
        let job = await mgr.get(jobID: id)
        XCTAssertEqual(job?.status, .inProgress(phase: .writingOutput))
    }

    func testComplete_setsTerminalStatus() async {
        let mgr = CompileJobManager()
        let id = await mgr.register(phase: .compiling)
        await mgr.complete(jobID: id, outputPath: "x.pdf", warnings: [], errors: [])
        let job = await mgr.get(jobID: id)
        if case .completed(let p, _, _) = job?.status {
            XCTAssertEqual(p, "x.pdf")
        } else {
            XCTFail("not completed: \(String(describing: job?.status))")
        }
    }

    func testCancel_setsCancelled() async {
        let mgr = CompileJobManager()
        let id = await mgr.register(phase: .compiling)
        let result = await mgr.cancel(jobID: id)
        XCTAssertEqual(result, .cancelled)
        let job = await mgr.get(jobID: id)
        XCTAssertEqual(job?.status, .cancelled)
    }

    // F2 review fix 1: dry_run terminates in its own state, is terminal, and
    // cancels as already-completed.
    func testCompleteDryRun_setsDistinctTerminalStatus() async {
        let mgr = CompileJobManager()
        let id = await mgr.register(phase: .renderingBody)
        await mgr.completeDryRun(jobID: id, warnings: [])
        let job = await mgr.get(jobID: id)
        XCTAssertEqual(job?.status, .dryRunPassed(warnings: []))
        XCTAssertEqual(job?.status.isTerminal, true)
        let cancel = await mgr.cancel(jobID: id)
        XCTAssertEqual(cancel, .alreadyCompleted)
    }

    /// RULING-22 (fix for M7-PB-009): the writer's cancel is the record that
    /// stands — a compile that finishes anyway must not overwrite `.cancelled`
    /// with `.completed` (or `.failed`, or `.dryRunPassed`).
    func testCancel_survivesALateTerminalWrite() async {
        let m = CompileJobManager()
        let id = await m.register(phase: .renderingBody)
        _ = await m.cancel(jobID: id)
        await m.complete(jobID: id, outputPath: "/x", warnings: [], errors: [])
        var job = await m.get(jobID: id)
        if case .cancelled = job?.status {} else {
            XCTFail("complete overwrote .cancelled: \(String(describing: job?.status))")
        }
        await m.fail(jobID: id, errors: [], logExcerpt: "late")
        job = await m.get(jobID: id)
        if case .cancelled = job?.status {} else {
            XCTFail("fail overwrote .cancelled: \(String(describing: job?.status))")
        }
        await m.completeDryRun(jobID: id, warnings: [])
        job = await m.get(jobID: id)
        if case .cancelled = job?.status {} else {
            XCTFail("completeDryRun overwrote .cancelled: \(String(describing: job?.status))")
        }
    }

    func testCancel_alreadyCompleted_returnsAlreadyCompleted() async {
        let mgr = CompileJobManager()
        let id = await mgr.register(phase: .compiling)
        await mgr.complete(jobID: id, outputPath: "x", warnings: [], errors: [])
        let result = await mgr.cancel(jobID: id)
        XCTAssertEqual(result, .alreadyCompleted)
    }

    func testCancel_notFound_returnsNotFound() async {
        let mgr = CompileJobManager()
        let result = await mgr.cancel(jobID: "nonexistent")
        XCTAssertEqual(result, .notFound)
    }

    func testGC_removesTerminalJobsOlderThanWindow() async {
        let mgr = CompileJobManager()
        let oldDate = Date(timeIntervalSinceNow: -25 * 60 * 60)
        let id = await mgr.register(phase: .compiling, startedAt: oldDate)
        await mgr.complete(jobID: id, outputPath: "x", warnings: [], errors: [])

        await mgr.gcOlderThan(seconds: 24 * 60 * 60)

        let job = await mgr.get(jobID: id)
        XCTAssertNil(job)
    }
}
