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
            logExcerpt: PublishOrchestrator.publishProblemsLogExcerpt + "3 errors"))

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
            logExcerpt: PublishOrchestrator.publishProblemsLogExcerpt))
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
        XCTAssertEqual(state.statusLine,
                       DepartmentCompileState.completedLine(Self.publication) + ", with 2 warnings",
                       "R-S13: the version stays, and the warnings join its line")
        XCTAssertTrue(state.statusLine?.contains("0.1") ?? false,
                      "the line still names the version: \(state.statusLine ?? "")")
        XCTAssertEqual(state.problems, [warnings[0], warnings[2]],
            "the typesetter's own warning names no piece and stays dropped")
        XCTAssertTrue(state.offersShowProblems)
        XCTAssertFalse(state.isFailure)
    }

    func test_oneWarningIsSingular() {
        let state = DepartmentCompileState.settled(
            after: .completed(Self.publication, warnings: [Self.problem(.warning, "x")]))
        XCTAssertEqual(state.statusLine,
                       DepartmentCompileState.completedLine(Self.publication) + ", with 1 warning")
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

    /// m5: a dry run keeps its problems, though the desk never asks for one.
    func test_aDryRunKeepsItsProblems() {
        let problem = Self.problem(.warning, "x")
        let state = DepartmentCompileState.settled(
            after: .dryRunPassed(warnings: [problem, Self.texWarning]))
        XCTAssertEqual(state.problems, [problem])
        XCTAssertEqual(state.report, DepartmentCompileState.dryRunLine)
    }

    // MARK: - What an open list follows (I3)

    func test_onlyACompileThatJustSettledHandsOnItsProblems() {
        let problem = Self.problem(.error, "x")
        let running = DepartmentCompileState(
            phase: .running(format: .pdf, languages: [], imprint: nil), isRunning: true)
        let refused = DepartmentCompileState.settled(after: .failed(
            errors: [problem], logExcerpt: PublishOrchestrator.publishProblemsLogExcerpt))
        let clean = DepartmentCompileState.settled(
            after: .completed(Self.publication, warnings: []))

        XCTAssertEqual(DepartmentCompileState.settledProblems(from: running, to: refused),
                       [problem])
        XCTAssertEqual(DepartmentCompileState.settledProblems(from: running, to: clean), [],
                       "a clean recompile settles with nothing — the list clears")
        XCTAssertNil(DepartmentCompileState.settledProblems(
            from: running, to: DepartmentCompileState.settled(after: .cancelled)),
            "a cancel says nothing new about the book")
        XCTAssertNil(DepartmentCompileState.settledProblems(from: refused, to: clean),
            "nothing was running, so nothing settled")
        var stillRunning = running
        stillRunning.phase = .refused(DepartmentCompileState.alreadyRunning)
        XCTAssertNil(DepartmentCompileState.settledProblems(from: running, to: stillRunning),
            "a second press refused mid-run is not a settle")
    }

    /// M3 (final review): a compile turned away before the problem gate ran
    /// — a version collision, a coverage block, an unknown imprint — judged
    /// nothing about the manuscript, so an open problems list stays as it is.
    func test_aRefusalThatNeverReachedTheProblemGate_leavesAnOpenListAlone() {
        let running = DepartmentCompileState(
            phase: .running(format: .pdf, languages: [], imprint: nil), isRunning: true)
        func failed(_ message: String, _ excerpt: String) -> DepartmentCompileState {
            DepartmentCompileState.settled(after: .failed(
                errors: [Diagnostic(level: .error, file: nil, line: nil, message: message, contextLines: [])],
                logExcerpt: excerpt))
        }
        let collision = failed("version 1.0 already exists", "version_collision: 1.0/en/pdf")
        let coverage = failed("3 paragraphs are untranslated", "translation_stale: sr")
        let imprint = failed("no imprint named x", PublishOrchestrator.unknownImprintLogExcerpt + "x")
        XCTAssertEqual(collision.phase, .failed("version 1.0 already exists"), "premise: a failure")
        XCTAssertEqual(imprint.phase, .refused("no imprint named x"), "premise: a refusal")
        for state in [collision, coverage, imprint] {
            XCTAssertNil(DepartmentCompileState.settledProblems(from: running, to: state),
                         "\(state.phase) judged nothing: the open list keeps its problems")
        }
    }

    /// The other side of M3: a compiler failure — the typesetter, EPUB
    /// packaging, an occupied destination — comes AFTER the problem gate,
    /// which judged the book and found nothing, so an open list clears as it
    /// would after a clean compile. The orchestrator prefixes such a failure's
    /// log with `compileFailedLogExcerpt` (pinned end to end by
    /// `PublishProblemGateTests.test_aCompileThatFailsForItsOwnReasonStillCarriesTheProblems`).
    func test_aCompilerFailureOnABookThatPassedTheGate_clearsAnOpenList() {
        let running = DepartmentCompileState(
            phase: .running(format: .pdf, languages: [], imprint: nil), isRunning: true)
        for log in ["note: Running TeX ...\n! Undefined control sequence.", "",
                    "output_path_occupied: Book-v1.0.pdf"] {
            let state = DepartmentCompileState.settled(after: .failed(
                errors: [Diagnostic(level: .error, file: "template.tex", line: 3,
                                    message: "Undefined control sequence", contextLines: [])],
                logExcerpt: PublishOrchestrator.compileFailedLogExcerpt + log))
            XCTAssertEqual(state.phase, .failed("Undefined control sequence"), "premise: a failure")
            XCTAssertEqual(DepartmentCompileState.settledProblems(from: running, to: state), [],
                           "\(log.prefix(20)): the gate judged the book clean — the list clears")
        }
    }

    /// Fail-safe: a failure whose excerpt is not KNOWN to come after the gate
    /// — a new refusal nobody listed, a bare tool log that skipped the
    /// orchestrator's prefix — leaves an open list alone. Planted offender.
    func test_anUnknownFailureExcerpt_leavesAnOpenListAlone() {
        let running = DepartmentCompileState(
            phase: .running(format: .pdf, languages: [], imprint: nil), isRunning: true)
        for excerpt in ["brand_new_failure: x", "note: Running TeX ...", "", "invalid_config: metadata.title"] {
            let state = DepartmentCompileState.settled(after: .failed(
                errors: [Diagnostic(level: .error, file: nil, line: nil, message: "x", contextLines: [])],
                logExcerpt: excerpt))
            XCTAssertNil(DepartmentCompileState.settledProblems(from: running, to: state),
                         "\(excerpt): not known to have reached the gate — the list stays")
        }
        XCTAssertEqual(PublishOrchestrator.afterTheProblemGateLogExcerpts,
                       [PublishOrchestrator.publishProblemsLogExcerpt,
                        PublishOrchestrator.compileFailedLogExcerpt])
    }

    func test_theOtherRefusalsAndOutcomesCarryNoProblems() {
        let diag = Diagnostic(level: .error, file: nil, line: nil,
                              message: "no such imprint", contextLines: [])
        XCTAssertFalse(DepartmentCompileState.settled(after: .failed(
            errors: [diag],
            logExcerpt: PublishOrchestrator.unknownImprintLogExcerpt)).offersShowProblems)
        XCTAssertFalse(DepartmentCompileState.settled(after: .cancelled).offersShowProblems)
        XCTAssertFalse(DepartmentCompileState().offersShowProblems)
    }
}
