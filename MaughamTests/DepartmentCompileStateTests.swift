import XCTest
import MaughamCore
@testable import Maugham

/// **What the desk says about publish problems** (report foundations plan 2,
/// Task 8) — the pure state, asserted from literals.
@MainActor
final class DepartmentCompileStateTests: XCTestCase {

    private typealias Diagnostic = TectonicLogParser.Diagnostic

    private static func problem(_ level: TectonicLogParser.Level, _ message: String,
                                piece: String = "ch-1", paragraph: String? = "a1b2")
    -> Diagnostic {
        Diagnostic(level: level, file: nil, line: nil, message: message,
                   contextLines: [], pieceID: piece, paragraphID: paragraph)
    }

    private static let texWarning = Diagnostic(
        level: .warning, file: "main.tex", line: 12,
        message: "Overfull \\hbox", contextLines: [])

    private static let publication = Publication(
        publicationID: "pub-0.1", version: "0.1", label: nil,
        format: .pdf, outputPath: "Exports/x.pdf", snapshotID: "s",
        checkpointID: "", republishedFrom: nil, compiledAt: Date(),
        maughamVersion: "0.0.0-test", tectonicVersion: "n/a",
        language: nil, allowStale: false, imprint: nil)

    // MARK: - A refusal for problems

    func test_aReportRefusedForProblemsIsARefusalCountingItsErrors() {
        let problems = [Self.problem(.error, "@fig:x is not a label"),
                        Self.problem(.error, "[@smith] is not a source"),
                        Self.problem(.error, "duplicate label tbl:y"),
                        Self.problem(.warning, "[^3] is never used")]
        let state = DepartmentCompileState.settled(after: .failed(
            errors: problems,
            logExcerpt: CompileOrchestrator.publishProblemsLogExcerpt + "3 errors"))

        XCTAssertEqual(state.phase,
                       .refused("Couldn't publish: 3 problems in the manuscript"))
        XCTAssertEqual(state.statusLine, "Couldn't publish: 3 problems in the manuscript")
        XCTAssertFalse(state.isFailure,
            "a manuscript with broken references is not a fault — nothing broke")
        XCTAssertEqual(state.problems, problems,
            "Show Problems carries every problem, errors and warnings, in order")
        XCTAssertTrue(state.offersShowProblems)
    }

    func test_oneProblemIsSingular() {
        let state = DepartmentCompileState.settled(after: .failed(
            errors: [Self.problem(.error, "x")],
            logExcerpt: CompileOrchestrator.publishProblemsLogExcerpt))
        XCTAssertEqual(state.statusLine, "Couldn't publish: 1 problem in the manuscript")
    }

    // MARK: - A book published with warnings

    func test_aCompletedBookWithWarningsSaysSoAndKeepsOnlyTheProblems() {
        let warnings = [Self.problem(.warning, "[^1] is never used"),
                        Self.texWarning,
                        Self.problem(.warning, "label on a paragraph is ignored",
                                     piece: "ch-2", paragraph: nil)]
        let state = DepartmentCompileState.settled(
            after: .completed(Self.publication, warnings: warnings))

        XCTAssertEqual(state.phase, .completed(Self.publication))
        XCTAssertEqual(state.statusLine, "Published, with 2 warnings")
        XCTAssertEqual(state.problems, [warnings[0], warnings[2]],
            "the typesetter's own warning names no piece and stays dropped")
        XCTAssertTrue(state.offersShowProblems)
        XCTAssertFalse(state.isFailure)
    }

    func test_oneWarningIsSingular() {
        let state = DepartmentCompileState.settled(
            after: .completed(Self.publication, warnings: [Self.problem(.warning, "x")]))
        XCTAssertEqual(state.statusLine, "Published, with 1 warning")
    }

    func test_aBookWithOnlyTypesetterWarningsReadsAsItAlwaysDid() {
        let state = DepartmentCompileState.settled(
            after: .completed(Self.publication, warnings: [Self.texWarning]))
        XCTAssertEqual(state.statusLine,
                       DepartmentCompileState.completedLine(Self.publication))
        XCTAssertEqual(state.problems, [])
        XCTAssertFalse(state.offersShowProblems)
    }

    // MARK: - A real failure keeps its problems

    func test_aTypesetterFailureIsStillAFailureAndKeepsItsProblems() {
        let tool = Diagnostic(level: .error, file: "main.tex", line: 3,
                              message: "Undefined control sequence", contextLines: [])
        let problem = Self.problem(.warning, "@sec:z is not a label")
        let state = DepartmentCompileState.settled(after: .failed(
            errors: [tool, problem], logExcerpt: "tectonic exited 1"))

        XCTAssertEqual(state.phase, .failed("Undefined control sequence"))
        XCTAssertTrue(state.isFailure)
        XCTAssertEqual(state.problems, [problem])
        XCTAssertTrue(state.offersShowProblems)
    }

    func test_theOtherRefusalsAndOutcomesCarryNoProblems() {
        let diag = Diagnostic(level: .error, file: nil, line: nil,
                              message: "no such imprint", contextLines: [])
        XCTAssertFalse(DepartmentCompileState.settled(after: .failed(
            errors: [diag],
            logExcerpt: CompileOrchestrator.unknownImprintLogExcerpt)).offersShowProblems)
        XCTAssertFalse(DepartmentCompileState.settled(after: .cancelled).offersShowProblems)
        XCTAssertFalse(DepartmentCompileState().offersShowProblems)
    }
}
