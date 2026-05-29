import XCTest
@testable import Maugham

final class CompileJobTests: XCTestCase {

    func testPhase_hasFourCases() {
        XCTAssertEqual(CompileJob.Phase.fetchingPackages.rawValue, "fetching_packages")
        XCTAssertEqual(CompileJob.Phase.renderingBody.rawValue,    "rendering_body")
        XCTAssertEqual(CompileJob.Phase.compiling.rawValue,        "compiling")
        XCTAssertEqual(CompileJob.Phase.writingOutput.rawValue,    "writing_output")
    }

    func testStatus_hasExpectedCases() {
        let cases: [CompileJob.Status] = [
            .inProgress(phase: .compiling),
            .completed(outputPath: "p.pdf", warnings: [], errors: []),
            .failed(errors: [], logExcerpt: "..."),
            .cancelled
        ]
        XCTAssertEqual(cases.count, 4)
    }

    func testJob_storesIdentifier_andStartedAt() {
        let job = CompileJob(
            jobID: "job-1", startedAt: Date(timeIntervalSince1970: 1),
            status: .inProgress(phase: .compiling))
        XCTAssertEqual(job.jobID, "job-1")
        XCTAssertEqual(job.startedAt, Date(timeIntervalSince1970: 1))
    }

    func testIsTerminal_returnsTrueForCompletedFailedCancelled() {
        XCTAssertTrue(CompileJob.Status.completed(
            outputPath: "p", warnings: [], errors: []).isTerminal)
        XCTAssertTrue(CompileJob.Status.failed(errors: [], logExcerpt: "").isTerminal)
        XCTAssertTrue(CompileJob.Status.cancelled.isTerminal)
        XCTAssertFalse(CompileJob.Status.inProgress(phase: .compiling).isTerminal)
    }
}
