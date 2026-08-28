import XCTest
import PDFKit
@testable import Maugham

/// PROBE (durable test): does the bundled tectonic ship a package that backs
/// `\st{...}` (the LaTeX command `LaTeXBodyEmitter` emits for GFM
/// `~~strikethrough~~`)? Before this probe, NO macro backed `\st` — a
/// published doc containing strikethrough would fail to compile with an
/// undefined-control-sequence error. Decision tree (see task-8 brief): try
/// `soul`+`\st` first; if unavailable, `ulem`+`\sout` (renaming the emitter's
/// macro); if NEITHER ships, degrade to a `\providecommand{\st}[1]{#1}`
/// plain-text fallback.
///
/// `test_soul_stCompiles` / `test_ulem_soutCompiles` probe the raw LaTeX
/// distribution directly (minimal standalone source, no Maugham emission
/// pipeline) so the verdict is about the bundled tectonic, not our code.
/// `test_realProject_strikethroughProseCompiles` then proves the WIRED
/// result: a real project, the actual bundled `preamble.tex`, and the real
/// `LaTeXBodyEmitter` output compile end-to-end.
@MainActor
final class StrikethroughCompileProbeTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrikethroughProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Step 1: raw package probes

    /// Minimal standalone document: does `\usepackage{soul}` + `\st{gone}`
    /// compile under the bundled tectonic?
    func test_soul_stCompiles() async throws {
        let result = try await compileMinimal(
            preambleLine: "\\usepackage{soul}",
            body: "\\st{gone}")
        XCTAssertEqual(result.exitCode, 0,
            "soul package failed to compile under bundled tectonic — log tail:\n"
          + "\(result.combinedLog.suffix(3000))")
    }

    /// Fallback probe: does `\usepackage{ulem}` + `\sout{gone}` compile?
    /// Recorded regardless of the `soul` outcome so the decision tree is
    /// documented by real compile evidence either way.
    func test_ulem_soutCompiles() async throws {
        let result = try await compileMinimal(
            preambleLine: "\\usepackage{ulem}",
            body: "\\sout{gone}")
        XCTAssertEqual(result.exitCode, 0,
            "ulem package failed to compile under bundled tectonic — log tail:\n"
          + "\(result.combinedLog.suffix(3000))")
    }

    /// Compiles a minimal `\documentclass{article}` source with one extra
    /// preamble line and one body line, directly via `TectonicInvoker` — no
    /// ProjectStore/PDFCompiler machinery, since this probes the LaTeX
    /// distribution itself rather than Maugham's emission pipeline.
    private func compileMinimal(preambleLine: String, body: String) async throws -> TectonicInvoker.Result {
        let binary = try XCTUnwrap(
            TectonicProbe.binaryURL(),
            "the probe reported ready, so the binary must be locatable")
        let cache = try TectonicCache.ensureCacheExists()
        let invoker = TectonicInvoker(binaryURL: binary, cacheURL: cache)
        let source = """
        \\documentclass{article}
        \(preambleLine)
        \\begin{document}
        \(body)
        \\end{document}
        """
        let texURL = tmp.appendingPathComponent("probe-\(UUID().uuidString).tex")
        try source.write(to: texURL, atomically: true, encoding: .utf8)
        return try await invoker.compile(texFile: texURL, workingDirectory: tmp)
    }

    // MARK: - Step 2: the wired result, end-to-end

    private struct StrikethroughSource: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "one", title: "Opening", mode: .prose,
                   displayText: "Cut ~~this clause~~ entirely.")]
        }
    }

    /// Proves the WIRED path: a real project installed with the actual
    /// bundled `preamble.tex` (unmodified — no per-test preamble override),
    /// real `LaTeXBodyEmitter` output for `~~this clause~~`, compiled through
    /// `PDFCompiler`. This is the test that was failing before the macro was
    /// wired into the starter preamble (undefined `\st`), and proves the
    /// fallback `\providecommand` also protects pre-existing per-project
    /// preambles that predate this package.
    func test_realProject_strikethroughProseCompiles() async throws {
        let projectURL = try await ProjectFactory.createNovelProject(named: "StrikeE2E", in: tmp)
        PublishingStores._resetForTesting()
        defer { PublishingStores._resetForTesting() }

        let compiler = try PDFCompiler(
            projectURL: projectURL,
            astSource: StrikethroughSource(),
            config: PublishConfig(metadata: .init(title: "Strike Book", author: "Tester")),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test")

        let result = try await compiler.compile(label: nil)

        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported compile errors: \(result.errors)\n\nLog:\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\nLog:\n\(result.logExcerpt)")

        let pdf = PDFDocument(url: URL(fileURLWithPath: result.outputPath))
        XCTAssertNotNil(pdf, "produced file at \(result.outputPath) is not a valid PDF")
        XCTAssertGreaterThan(pdf?.pageCount ?? 0, 0, "PDF has no pages")

        // The body carries the real emitter output for the strikethrough run.
        // (P2: `build/body.tex` is now the wrapper over the document's bodies —
        // the emitted book lives at `build/body.<tag>.tex`, `en` for this fixture.)
        let bodyURL = projectURL.appendingPathComponent(".maugham/publish/build/body.en.tex")
        let body = try String(contentsOf: bodyURL, encoding: .utf8)
        XCTAssertTrue(body.contains("\\st{this clause}"),
                      "body.tex missing expected \\st{...} emission; body.tex:\n\(body)")
    }
}
