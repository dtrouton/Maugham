import XCTest
import PDFKit
@testable import Maugham

/// Compile-time probes pinning three starter-template/emission defects found
/// in real publishing use (2026-07-19), each verified against the bundled
/// tectonic before fixing:
///
/// 1. ToC branch: the starter's `\ifx`-based `[notoc]` dispatch compared a
///    `\newcommand`-defined macro (which is `\long`) against a `\def`'d
///    argument (which is not). `\ifx` compares prefixes too, so the test never
///    matched, every piece silently took the notoc branch, the ToC stayed
///    empty, and the documented `\pieceheading` hook never fired.
/// 2. Fence + `[`: fenced-block lines were joined with bare `\\`; a line
///    starting with `[` parsed as its optional argument and killed the
///    compile ("Missing number, treated as zero").
/// 3. Style-file scoping: renewals made at style-file scope (including robust
///    kernel commands like `\textbf`, via `\renewcommand` or
///    `\RenewDocumentCommand`) revert at the emitter's `\endgroup` under the
///    bundled tectonic. This pins that scoping contract so a future tectonic/
///    kernel upgrade that changes ltcmd scoping is caught, not shipped.
@MainActor
final class StarterTemplateDefectProbeTests: XCTestCase {

    var tmp: URL!
    var projectURL: URL!

    private func tectonicAvailable() -> Bool {
        let testBundlePath = Bundle(for: StarterTemplateDefectProbeTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        return (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil
    }

    override func setUp() async throws {
        guard tectonicAvailable() else {
            throw XCTSkip("tectonic binary not bundled in test host — compile probes require bundled binary")
        }
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("StarterDefectProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "DefectProbe", in: tmp)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private struct FixedSource: ProjectASTBuilder.Source {
        let pieces: [ProjectASTBuilder.PieceRef]
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] { pieces }
    }

    private func compile(source: ProjectASTBuilder.Source,
                         config: PublishConfig) async throws -> (PDFCompiler.Result, PDFDocument) {
        let compiler = try PDFCompiler(
            projectURL: projectURL,
            astSource: source,
            config: config,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported compile errors: \(result.errors)\n\nLog:\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\nLog:\n\(result.logExcerpt)")
        let pdf = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: result.outputPath)),
                                "produced file at \(result.outputPath) is not a valid PDF")
        return (result, pdf)
    }

    private func fullText(of pdf: PDFDocument) -> String {
        (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
    }

    // MARK: - 1. ToC branch

    /// Default config (no `include_in_toc` override) must produce a ToC entry
    /// per piece: the piece title appears at least twice in the PDF text (ToC
    /// line + section heading). An `include_in_toc:false` piece appears
    /// exactly once (heading only). Distinctive titles avoid false hits from
    /// frontmatter/metadata text.
    func test_defaultConfig_pieceTitlesAppearInToc() async throws {
        let source = FixedSource(pieces: [
            .init(pieceID: "one", title: "Zqalphaprobe", mode: .prose,
                  displayText: "First body paragraph."),
            .init(pieceID: "two", title: "Zqbetaprobe", mode: .prose,
                  displayText: "Second body paragraph."),
        ])
        let config = PublishConfig(
            metadata: .init(title: "ToC Probe Book", author: "Tester"),
            sections: ["two": .init(includeInToc: false)])

        let (_, pdf) = try await compile(source: source, config: config)
        let text = fullText(of: pdf)

        let alphaCount = text.components(separatedBy: "Zqalphaprobe").count - 1
        let betaCount = text.components(separatedBy: "Zqbetaprobe").count - 1
        XCTAssertGreaterThanOrEqual(alphaCount, 2,
            "default-toc piece title must appear in BOTH the ToC and its heading; "
          + "found \(alphaCount) occurrence(s) — the starter's \\ifx toc-dispatch "
          + "is taking the notoc branch. PDF text:\n\(text.prefix(2000))")
        XCTAssertEqual(betaCount, 1,
            "include_in_toc:false piece title must appear exactly once (heading only); "
          + "found \(betaCount). PDF text:\n\(text.prefix(2000))")
    }

    /// Same dispatch defect, screenplay side: a fountain piece under default
    /// config must land in the ToC too (`screenplay.tex` had the identical
    /// `\ifx`/`\long` mismatch).
    func test_defaultConfig_fountainPieceTitleAppearsInToc() async throws {
        let source = FixedSource(pieces: [
            .init(pieceID: "s1", title: "Zqscriptprobe", mode: .fountain,
                  displayText: "INT. HOUSE - DAY\n\nAaron pours coffee."),
        ])
        let (_, pdf) = try await compile(
            source: source,
            config: PublishConfig(metadata: .init(title: "Script Probe", author: "Tester")))
        let text = fullText(of: pdf)
        let count = text.components(separatedBy: "Zqscriptprobe").count - 1
        XCTAssertGreaterThanOrEqual(count, 2,
            "fountain piece title must appear in BOTH the ToC and its heading; "
          + "found \(count) occurrence(s). PDF text:\n\(text.prefix(2000))")
    }

    // MARK: - 2. Fenced line starting with `[`

    /// A fenced block whose second line starts with `[` must compile. Before
    /// the `\newline` fix the joined `\\`+`[options]` parsed as an optional
    /// argument: "Missing number, treated as zero" — a hard compile failure.
    func test_fenceLineStartingWithBracket_compiles() async throws {
        let source = FixedSource(pieces: [
            .init(pieceID: "one", title: "Config Chapter", mode: .prose,
                  displayText: "Some prose first.\n\n```\nkey = value\n[options]\nmore = data\n```\n\nAnd after."),
        ])
        let (result, pdf) = try await compile(
            source: source,
            config: PublishConfig(metadata: .init(title: "Fence Probe", author: "Tester")))
        XCTAssertGreaterThan(pdf.pageCount, 0, "PDF has no pages")
        // The emitted body must carry the scan-proof break form.
        let body = try String(
            contentsOf: projectURL.appendingPathComponent(".maugham/publish/build/body.tex"),
            encoding: .utf8)
        XCTAssertTrue(body.contains("key = value\\newline [options]"),
                      "fence lines must join with \\newline; body.tex:\n\(body)")
        _ = result
    }

    // MARK: - 3. Style-file scoping pin

    /// A style file that renews the robust kernel command `\textbf` (both the
    /// `\renewcommand` and `\RenewDocumentCommand` spellings) restyles ITS
    /// piece only: the renewal reverts at the emitter's `\endgroup`, so the
    /// next piece's bold is pristine. Verified against bundled tectonic 0.15.0
    /// (LaTeX kernel 2021-11-15); this pin exists so a tectonic upgrade that
    /// changes ltcmd scoping fails loudly here instead of silently restyling
    /// writers' books.
    func test_styleFileRenewalOfRobustCommand_doesNotRestyleLaterPieces() async throws {
        let piecesDir = projectURL.appendingPathComponent(".maugham/publish/pieces")
        try FileManager.default.createDirectory(at: piecesDir, withIntermediateDirectories: true)
        let style = """
            \\renewcommand{\\textbf}[1]{QQRENEWED #1 QQRENEWED}
            \\RenewDocumentCommand{\\emph}{m}{QQRDCEM #1 QQRDCEM}
            """
        try style.write(to: piecesDir.appendingPathComponent("loud.tex"),
                        atomically: true, encoding: .utf8)

        let source = FixedSource(pieces: [
            .init(pieceID: "one", title: "Styled", mode: .prose,
                  displayText: "Bold **alphaword** and em *emone* here."),
            .init(pieceID: "two", title: "Plain", mode: .prose,
                  displayText: "Bold **betaword** and em *emtwo* here."),
        ])
        let config = PublishConfig(
            metadata: .init(title: "Scope Pin Book", author: "Tester"),
            sections: ["one": .init(styleFile: "loud.tex")])

        let (_, pdf) = try await compile(source: source, config: config)
        let text = fullText(of: pdf)

        XCTAssertTrue(text.contains("QQRENEWED alphaword QQRENEWED"),
                      "styled piece must use the renewed \\textbf; PDF text:\n\(text.prefix(2000))")
        XCTAssertTrue(text.contains("QQRDCEM emone QQRDCEM"),
                      "styled piece must use the \\RenewDocumentCommand'd \\emph; PDF text:\n\(text.prefix(2000))")
        XCTAssertFalse(text.contains("QQRENEWED betaword"),
                       "style-file \\renewcommand of \\textbf leaked past \\endgroup into the next piece")
        XCTAssertFalse(text.contains("QQRDCEM emtwo"),
                       "style-file \\RenewDocumentCommand of \\emph leaked past \\endgroup into the next piece")
    }
}
