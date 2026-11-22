import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The edition's compile bar** (shell p4 Task 5's home for Compile… and the
/// imprint picker): the Department desk's compile claims, moved onto the live
/// bar when the desk was deleted (shell p4 Task 7). Mounted and read, never
/// pressed (tripwire 33).
@MainActor
final class EditionCompileBarTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        await waitOut(0.05)
        windows.removeAll()
    }

    private func mount(imprints: [String] = [],
                       compileRun: CompileRunState = CompileRunState()) async -> NSWindow {
        let bar = EditionCompileBar(
            imprints: imprints, selectedImprint: nil, selectImprint: { _ in },
            compileRun: compileRun, editionLanguage: nil, editions: { ["en"] },
            runCompile: { _ in }, cancelCompile: {}, showProblems: {})
        let window = TestWindow.mount(
            AnyView(bar.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)),
            size: CGSize(width: 700, height: 120))
        windows.append(window)
        await pumpUntil(deadline: 5) {
            ((try? self.axButtonLabels(in: window)) ?? []).contains(CompileBarCopy.compileTitle)
        }
        return window
    }

    /// **The picker is drawn only where there is a choice to make**: over a
    /// project with imprints it stands on the book; with none, no picker.
    func test_theImprintPickerIsDrawnOnlyWhenTheProjectDefinesOne() async throws {
        let withOne = await mount(imprints: ["special"])
        XCTAssertTrue(try axTexts(in: withOne).contains { $0.contains(CompileBarCopy.bookImprintTitle) },
                      "the picker stands on the book")
        let withNone = await mount()
        XCTAssertFalse(try axTexts(in: withNone).contains { $0 == CompileBarCopy.bookImprintTitle },
                       "no imprints, no picker")
    }

    /// **Compile… is one door**, a real control a keyboard reaches.
    func test_compileIsADoorOnTheBar() async throws {
        let window = await mount()
        XCTAssertEqual(try axButtonLabels(in: window).filter { $0 == CompileBarCopy.compileTitle }.count, 1)
    }

    /// What the compile is doing is drawn on the bar, in `statusLine`'s words.
    func test_theCompilesOwnLineIsDrawnOnTheBar() async throws {
        let running = CompileRunState(
            phase: .running(format: .epub, languages: ["en"], imprint: "special"), isRunning: true)
        let window = await mount(compileRun: running)
        let expected = try XCTUnwrap(running.statusLine)
        XCTAssertTrue(try axTexts(in: window).contains { $0.contains(expected) },
                      "nothing on the bar reads \u{201C}\(expected)\u{201D}")
    }

    /// **Cancel is gated on `isRunning`, never on the phase**: drawn while a
    /// compile runs — including after a refused second press, whose line still
    /// says something is compiling — and absent when none does.
    func test_cancelIsDrawnWhileACompileRunsEvenAfterARefusal() async throws {
        let running = await mount(compileRun: CompileRunState(
            phase: .running(format: .pdf, languages: [], imprint: nil), isRunning: true))
        XCTAssertEqual(try axButtonLabels(in: running).filter { $0 == CompileBarCopy.cancelCompileLabel }.count, 1)

        let refused = CompileRunState(phase: .refused(CompileRunState.alreadyRunning), isRunning: true)
        let afterARefusal = await mount(compileRun: refused)
        XCTAssertEqual(try axButtonLabels(in: afterARefusal)
            .filter { $0 == CompileBarCopy.cancelCompileLabel }.count, 1,
            "the run the press was refused for is still going")
        let line = try XCTUnwrap(refused.statusLine)
        XCTAssertTrue(line.contains("still compiling"), line)
        XCTAssertTrue(try axTexts(in: afterARefusal).contains { $0.contains(line) })

        let idle = await mount()
        XCTAssertFalse(try axButtonLabels(in: idle).contains(CompileBarCopy.cancelCompileLabel))
    }

    /// **Show Problems is drawn beside a compile that left problems, and
    /// nowhere else.**
    func test_showProblemsIsDrawnWhenTheLastCompileLeftProblems() async throws {
        let problem = TectonicLogParser.Diagnostic(
            level: .error, file: nil, line: nil, message: "@fig:x is not a label",
            contextLines: [], pieceID: "ch-1", paragraphID: "a1b2")
        let failed = CompileRunState.settled(after: .failed(
            errors: [problem, problem, problem],
            logExcerpt: PublishOrchestrator.publishProblemsLogExcerpt))
        let window = await mount(compileRun: failed)
        XCTAssertEqual(try axButtonLabels(in: window).filter { $0 == CompileRunState.showProblemsTitle }.count, 1)
        let idle = await mount()
        XCTAssertFalse(try axButtonLabels(in: idle).contains(CompileRunState.showProblemsTitle))
    }
}
