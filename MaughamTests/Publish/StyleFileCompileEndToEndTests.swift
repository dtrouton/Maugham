import XCTest
import PDFKit
@testable import Maugham

/// End-to-end guard that a piece with a `style_file` actually compiles through
/// tectonic. Specifically proves that the scoped-group emission
/// (`\begingroup \input{pieces/tribute.tex} \begin{prose}[notoc]{…} … \end{prose} \endgroup`)
/// compiles against the real starter `prose.tex` — including the combined
/// styleFile + [notoc] path that was not covered by any previous compile test.
@MainActor
final class StyleFileCompileEndToEndTests: XCTestCase {

    var tmp: URL!
    var projectURL: URL!

    private func tectonicAvailable() -> Bool {
        let testBundlePath = Bundle(for: StyleFileCompileEndToEndTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        return (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil
    }

    override func setUp() async throws {
        guard tectonicAvailable() else {
            throw XCTSkip("tectonic binary not bundled in test host — full E2E requires bundled binary")
        }
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("StyleFileE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "StyleFile", in: tmp)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// A 2-piece prose source: "one" (default toc) and "two" (no-toc + style_file).
    private struct TwoPieceSource: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [
                .init(pieceID: "one", title: "Opening",
                      mode: .prose, displayText: "First piece opening paragraph."),
                .init(pieceID: "two", title: "Tribute",
                      mode: .prose, displayText: "Second piece with a scene break.\n\n***\n\nAfter the break."),
            ]
        }
    }

    /// Proves the combined styleFile + [notoc] path compiles against the real
    /// starter `prose.tex`. Specifically:
    ///
    /// 1. Writes a real `pieces/tribute.tex` with safe scoped overrides
    ///    (`\renewcommand{\pieceheading}` and `\renewcommand{\scenebreak}`).
    /// 2. Sets `config.sections["two"].styleFile = "tribute.tex"` AND
    ///    `config.sections["two"].includeInToc = false`.
    /// 3. Compiles to PDF via `PDFCompiler`.
    /// 4. Asserts compile succeeds, PDF is valid and has ≥1 page.
    /// 5. Asserts `build/body.tex` contains `\input{pieces/tribute.tex}`,
    ///    `\begingroup`, and `\begin{prose}[notoc]{Tribute}` — proving the
    ///    scoped-group + notoc forms are emitted together.
    func test_pieceWithStyleFile_compiles() async throws {
        // Write the pieces/ directory and tribute.tex with safe scoped overrides.
        // These commands are all \renewcommand — no \usepackage or \geometry.
        let piecesDir = projectURL
            .appendingPathComponent(".maugham/publish/pieces")
        try FileManager.default.createDirectory(
            at: piecesDir, withIntermediateDirectories: true)

        let tributeContent = """
            % Safe scoped overrides for the "Tribute" piece.
            % Opts into section numbering for this piece only.
            \\renewcommand{\\pieceheading}[1]{\\section{#1}}
            % Replace the default asterism with an em-dash break.
            \\renewcommand{\\scenebreak}{%
              \\par\\vspace{1em}\\centering ---\\vspace{1em}\\par\\noindent}
            """
        let tributeURL = piecesDir.appendingPathComponent("tribute.tex")
        try tributeContent.write(to: tributeURL, atomically: true, encoding: .utf8)

        // Configure: piece "two" gets both styleFile AND include_in_toc:false —
        // the combined path (\begingroup + [notoc]) that was not previously E2E-covered.
        let config = PublishConfig(
            metadata: .init(title: "Style File Book", author: "Tester"),
            sections: [
                "two": .init(includeInToc: false, styleFile: "tribute.tex")
            ])

        let compiler = try PDFCompiler(
            projectURL: projectURL,
            astSource: TwoPieceSource(),
            config: config,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test")

        let result = try await compiler.compile(label: nil)

        // (a) Compile succeeded — no errors, non-empty output path.
        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported compile errors: \(result.errors)\n\nLog:\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\nLog:\n\(result.logExcerpt)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath),
                      "PDF not found at \(result.outputPath)")

        // (b) The produced file is a valid PDF with at least one page.
        let pdf = PDFDocument(url: URL(fileURLWithPath: result.outputPath))
        XCTAssertNotNil(pdf, "produced file at \(result.outputPath) is not a valid PDF")
        XCTAssertGreaterThan(pdf?.pageCount ?? 0, 0, "PDF has no pages")

        // (c) body.tex carries the expected scoped-group + notoc emission for piece "two".
        let bodyURL = projectURL
            .appendingPathComponent(".maugham/publish/build/body.tex")
        let body = try String(contentsOf: bodyURL, encoding: .utf8)
        XCTAssertTrue(body.contains("\\begingroup"),
                      "body.tex missing \\begingroup for styled piece; body.tex:\n\(body)")
        XCTAssertTrue(body.contains("\\input{pieces/tribute.tex}"),
                      "body.tex missing \\input{pieces/tribute.tex}; body.tex:\n\(body)")
        XCTAssertTrue(body.contains("\\begin{prose}[notoc]{Tribute}"),
                      "body.tex missing combined [notoc]+styleFile form; body.tex:\n\(body)")
        XCTAssertTrue(body.contains("\\endgroup"),
                      "body.tex missing \\endgroup for styled piece; body.tex:\n\(body)")

        // (d) Piece "one" (no styleFile, default toc) still uses the plain form.
        XCTAssertTrue(body.contains("\\begin{prose}{Opening}"),
                      "first piece (no styleFile) must use plain toc form; body.tex:\n\(body)")
        XCTAssertFalse(body.contains("\\begin{prose}[notoc]{Opening}"),
                       "first piece must NOT have [notoc]; body.tex:\n\(body)")
    }
}
