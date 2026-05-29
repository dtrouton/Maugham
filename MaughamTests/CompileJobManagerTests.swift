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
