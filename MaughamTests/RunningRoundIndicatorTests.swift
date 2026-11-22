import XCTest
import MaughamCore
@testable import Maugham

/// **A running round, in the toolbar** (shell p4 Task 8): what it says, that
/// it is hidden while nothing runs, where it sits so it moves nothing when it
/// comes and goes, and that a second start — from any window on the project
/// — is refused aloud (review M12).
@MainActor
final class RunningRoundIndicatorTests: XCTestCase {

    private let titles = ["c3": "Chapter Three"]

    private func line(_ pipeline: TranslationPipeline.Status,
                      _ compiler: CompilerOrchestrator.RunState = .idle) -> RunningRound.Line? {
        RunningRound.line(pipeline: pipeline, compiler: compiler, titleOf: { self.titles[$0] })
    }

    func test_theIndicatorNamesTheRunningRound() {
        let serbian = LanguageName.title("sr")
        XCTAssertEqual(line(.running(docId: "c3", language: "sr", leg: .reread, book: nil)),
                       .init(text: "Translating \u{00b7} \(serbian) \u{00b7} \u{201C}Chapter Three\u{201D}, re-reading",
                             docId: "c3", language: "sr", compact: serbian))
        XCTAssertEqual(line(.running(docId: "c3", language: "sr", leg: .translate,
                                     book: .init(position: 3, count: 12)))?.text,
                       "Translating \u{00b7} \(serbian) \u{00b7} \u{201C}Chapter Three\u{201D} (3 of 12), translating")
        XCTAssertEqual(line(.idle, .running(docId: "c3", kind: .round, checking: .init(new: 1, revised: 0))),
                       .init(text: "Editor\u{2019}s round \u{00b7} \u{201C}Chapter Three\u{201D}, reading",
                             docId: "c3", language: nil, compact: "Round"))
    }

    /// **An editor's round by its pass's editor** when the round in flight
    /// says which pass (fix round (g)).
    func test_anEditorsRoundIsNamedByItsPass() {
        let named = RunningRound.line(pipeline: .idle,
                                      compiler: .running(docId: "c3", kind: .round, checking: .init(new: 1, revised: 0)),
                                      roundEditor: "Perkins", titleOf: { self.titles[$0] })
        XCTAssertEqual(named?.text, "Perkins\u{2019}s round \u{00b7} \u{201C}Chapter Three\u{201D}, reading")
        XCTAssertEqual(named?.compact, "Perkins")
        let lines = SourceScan.codeLines(of: try! SourceTree.read("Maugham/Views/ProjectWindow.swift"))
        XCTAssertTrue(lines.contains { $0.contains("compiler.runningRoundPassId.flatMap") },
                      "the window asks the round in flight for its lane")
    }

    /// **The width budget** (fix round (f)): the full sentence only where it
    /// fits beside the trailing group's other items; else the short form, so
    /// the language switch and the rest never overflow. Measured from
    /// intrinsic sizes, here a fixed 7 pt per character.
    func test_aTightToolbarDrawsTheShortForm() {
        let line = RunningRound.Line(text: String(repeating: "x", count: 40), docId: "c3",
                                     language: "sr", compact: "Serbian 3/12")
        let width: (String) -> CGFloat = { CGFloat($0.count) * 7 }
        // others: 72 + ("Serbian" 49 + 52) + 110 = 283; full: 280 + 22 = 302; reserve 560.
        XCTAssertTrue(RunningRound.drawsFull(line, windowWidth: 1145, languageSwitchTitle: "Serbian",
                                             viewSwitch: true, textWidth: width))
        XCTAssertFalse(RunningRound.drawsFull(line, windowWidth: 1144, languageSwitchTitle: "Serbian",
                                              viewSwitch: true, textWidth: width))
        XCTAssertTrue(RunningRound.drawsFull(line, windowWidth: 1044, languageSwitchTitle: nil,
                                             viewSwitch: true, textWidth: width),
                      "with no language switch there is more room")
        XCTAssertFalse(RunningRound.drawsFull(line, windowWidth: nil, languageSwitchTitle: nil,
                                              viewSwitch: false, textWidth: width),
                       "before the window is measured: the short form")
        let window = try! SourceTree.read("Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains("RunningRoundIndicator(line: runningRound, full: runningRoundIsFull,"))
    }

    func test_nothingRunningShowsNothing() {
        XCTAssertNil(line(.idle))
        XCTAssertNil(line(.idle, .running(docId: "c3", kind: .check, checking: .init(new: 1, revised: 0))),
                     "a check is not a round; To resolve's head says it runs")
        XCTAssertNil(line(.idle, .nothingNew(docId: "c3", kind: .round, at: Date())))
    }

    /// A translation round outranks an editor's round when both run.
    func test_aTranslationRoundIsNamedFirst() {
        let both = line(.running(docId: "c3", language: "sr", leg: .read, book: nil),
                        .running(docId: "x", kind: .round, checking: .init(new: 0, revised: 1)))
        XCTAssertEqual(both?.language, "sr")
    }

    /// **The indicator leads the trailing group**, so its coming and going
    /// moves nothing after it; the toolbar hides with focus mode as a whole.
    func test_theIndicatorLeadsTheTrailingGroupAndHidesWhenNothingRuns() throws {
        let lines = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ProjectWindow.swift"))
        let indicator = try XCTUnwrap(lines.firstIndex { $0.contains("if let runningRound {") })
        let reading = try XCTUnwrap(lines.firstIndex { $0.contains("if let readingOffer {") })
        let views = try XCTUnwrap(lines.firstIndex { $0.contains("if centreViewOffer != .none {") })
        let column = try XCTUnwrap(lines.firstIndex { $0.contains("RightColumnToggle(showInspector:") })
        XCTAssertTrue(indicator < reading && reading < views && views < column,
                      "running round, language switch, view switch, right column — in that order")
        XCTAssertTrue(lines.contains { $0.contains("pipeline: roster.pipeline.status, compiler: compiler.runState,") },
                      "it reads the session's roster, which every window on the project shares")
    }

    /// **A second start is refused aloud** (M12): the pipeline refuses a
    /// start while one runs, and the start says which round holds it rather
    /// than doing nothing.
    func test_aSecondStartIsRefusedAloud() {
        let pipeline = TranslationPipeline()
        XCTAssertNil(TranslationRunStart.refusedIfBusy(true, pipeline: pipeline))
        XCTAssertEqual(TranslationRunStart.refusedIfBusy(false, pipeline: pipeline),
                       TranslationRunStart.noTranslatorWired,
                       "an idle pipeline that refused was not wired — not busy (fix M8)")
        XCTAssertFalse(pipeline.runBook(documentIds: ["c3"], language: "sr"),
                       "control: an unwired pipeline refuses, as a running one does")
    }

    /// Every production start of a round goes through the refusal.
    func test_everyStartOfARoundSaysWhenItIsRefused() throws {
        var unguarded: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            for line in SourceScan.codeLines(of: try SourceTree.read(file))
            where line.contains("pipeline.run(") || line.contains("pipeline.runBook(") {
                if !line.contains("refusedIfBusy(") { unguarded.append("\(file): \(line)") }
            }
        }
        // A wrapped call names the refusal on the line before.
        XCTAssertEqual(unguarded.filter { !$0.contains("ResolveEditionItems.swift") }, [])
        let edition = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/Resolve/ResolveEditionItems.swift"))
        let call = try XCTUnwrap(edition.firstIndex { $0.contains("pipeline.runBook(") })
        XCTAssertTrue(edition[call - 1].contains("TranslationRunStart.refusedIfBusy("))
    }
}
