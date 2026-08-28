import XCTest
import PDFKit
@testable import Maugham

/// Render-guard for the starter "unnumbered piece titles by default + [notoc]
/// optional environment arg" change. Compiles a real 2-piece prose project
/// (second piece include_in_toc:false) through the bundled tectonic and asserts
/// it produces a PDF, and that body.tex carries the expected `\begin{prose}{...}`
/// (toc) and `\begin{prose}[notoc]{...}` (no-toc) forms.
@MainActor
final class StarterDefaultFlipTests: XCTestCase {

    var tmp: URL!
    var projectURL: URL!

    override func setUp() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("StarterFlip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // ProjectFactory.createNovelProject installs the publish starter automatically.
        projectURL = try await ProjectFactory.createNovelProject(named: "Flip", in: tmp)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// A two-piece prose source: piece "one" (toc) and piece "two" (notoc).
    private struct TwoPieceSource: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [
                .init(pieceID: "one", title: "Tank Park Salute",
                      mode: .prose, displayText: "First piece body paragraph."),
                .init(pieceID: "two", title: "Hidden Chapter",
                      mode: .prose, displayText: "Second piece body paragraph."),
            ]
        }
    }

    func test_notocSection_compilesAndEmitsExpectedBodyForms() async throws {
        // Second piece opts out of the ToC → emitter must produce [notoc].
        let config = PublishConfig(
            metadata: .init(title: "Flip Book", author: "Tester"),
            sections: ["two": .init(includeInToc: false)])

        let compiler = try PDFCompiler(
            projectURL: projectURL,
            astSource: TwoPieceSource(),
            config: config,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test")

        let result = try await compiler.compile(label: nil)

        // (a) Compile succeeded → a real PDF exists at outputPath.
        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported compile errors: \(result.errors)\n\nLog:\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\nLog:\n\(result.logExcerpt)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath),
                      "PDF not found at \(result.outputPath)")
        let pdf = PDFDocument(url: URL(fileURLWithPath: result.outputPath))
        XCTAssertNotNil(pdf, "produced file at \(result.outputPath) is not a valid PDF")
        XCTAssertGreaterThan(pdf?.pageCount ?? 0, 0, "PDF has no pages")

        // (b) the body carries the toc form for piece one and notoc for piece two.
        // (P2: `build/body.tex` is now the wrapper over the document's bodies —
        // the emitted book lives at `build/body.<tag>.tex`, `en` for this fixture.)
        let bodyURL = projectURL
            .appendingPathComponent(".maugham/publish/build/body.en.tex")
        let body = try String(contentsOf: bodyURL, encoding: .utf8)
        XCTAssertTrue(body.contains("\\begin{prose}{Tank Park Salute}"),
                      "expected toc form for first piece; body.tex:\n\(body)")
        XCTAssertTrue(body.contains("\\begin{prose}[notoc]{Hidden Chapter}"),
                      "expected [notoc] form for second piece; body.tex:\n\(body)")
    }
}
