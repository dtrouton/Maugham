import XCTest
import PDFKit
@testable import Maugham

/// Task 5: `PDFCompiler` compiles the template the CONFIG names.
///
/// Until this task the compiler hard-coded `"template.tex"` and handed that
/// literal to `LanguageSuffixedFile.resolve`, so an imprint whose whole point
/// is a different typography (`config.template = "special.tex"`) compiled the
/// book's template and produced the book's PDF under the imprint's filename —
/// the loudest possible silent wrong answer. These tests read the tectonic
/// intermediates rather than the moved output, because tectonic names its
/// `.log`/`.aux`/`.pdf` after the INPUT FILE: `build/special.log` existing
/// while `build/template.log` does not is the compiler's choice of template,
/// observed at the only place it is observable after the PDF has been moved
/// into `Exports/`.
@MainActor
final class ImprintTemplateCompileTests: XCTestCase {

    var tmp: URL!
    var publish: URL!
    var build: URL!

    override func setUp() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImprintTemplate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
        publish = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        build = publish.appendingPathComponent("build", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private struct OnePiece: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "Opening",
                   mode: .prose, displayText: "A single paragraph, plainly set.")]
        }
    }

    /// Copies the installed starter template to `name` under `.maugham/publish/`.
    ///
    /// When `name` sits in a subdirectory the `\input` lines are rewritten with
    /// a `../` prefix: **tectonic resolves `\input` relative to the template's
    /// OWN directory, not the process working directory** (measured 2026-08-27;
    /// a verbatim copy at `templates/special.tex` fails with
    /// `! LaTeX Error: File 'preamble.tex' not found.`). That is the same rule
    /// `template.tex`'s own comment states for language variants — a template
    /// owns its partial references — so the rewrite is the test standing in for
    /// a template author, not a workaround for anything in Maugham.
    private func installTemplate(named name: String) throws {
        var text = try String(
            contentsOf: publish.appendingPathComponent("template.tex"), encoding: .utf8)
        let dest = publish.appendingPathComponent(name)
        if name.contains("/") {
            text = text
                .replacingOccurrences(of: "\\input{", with: "\\input{../")
                .replacingOccurrences(of: "\\InputIfFileExists{", with: "\\InputIfFileExists{../")
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try text.write(to: dest, atomically: true, encoding: .utf8)
    }

    /// Replaces the book's own `template.tex` with LaTeX that cannot compile,
    /// so a fallback to the old literal fails loudly rather than quietly
    /// producing the book.
    private func breakTheBookTemplate() throws {
        try "\\undefined_command_xyz".write(
            to: publish.appendingPathComponent("template.tex"),
            atomically: true, encoding: .utf8)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(
            atPath: build.appendingPathComponent(relative).path)
    }

    // MARK: - the config names the template

    func test_theCompilerCompilesTheTemplateTheConfigNames() async throws {
        try installTemplate(named: "special.tex")
        try breakTheBookTemplate()

        let config = PublishConfig(
            metadata: .init(title: "Imprint Book", author: "Tester"),
            template: "special.tex")
        let compiler = try PDFCompiler(
            projectURL: tmp, astSource: OnePiece(), config: config,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)

        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported errors: \(result.errors.map(\.message))\n\nLog:\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\nLog:\n\(result.logExcerpt)")
        let pdf = PDFDocument(url: URL(fileURLWithPath: result.outputPath))
        XCTAssertGreaterThan(pdf?.pageCount ?? 0, 0,
                             "produced file at \(result.outputPath) is not a PDF with pages")

        XCTAssertTrue(exists("special.log"),
                      "tectonic's log is named after its input file; special.log absent means "
                      + "the compiler did not run special.tex. build/ held: \(buildListing())")
        // Negative: the hard-coded literal is gone. A compiler still reaching
        // for "template.tex" would leave template.log here (and, since that
        // template is now broken, would have failed above).
        XCTAssertFalse(exists("template.log"),
                       "the compiler compiled the book's template.tex, not the config's. "
                       + "build/ held: \(buildListing())")
    }

    // MARK: - the language suffix applies to the config's template

    func test_theLanguageSuffixAppliesToTheConfigsTemplate() async throws {
        try installTemplate(named: "special.tex")
        try installTemplate(named: "special.sr.tex")

        let config = PublishConfig(
            metadata: .init(title: "Imprint Book", author: "Tester"),
            template: "special.tex")
        let compiler = try PDFCompiler(
            projectURL: tmp, astSource: OnePiece(), config: config,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test",
            language: "sr")
        let result = try await compiler.compile(label: nil)

        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported errors: \(result.errors.map(\.message))\n\nLog:\n\(result.logExcerpt)")
        XCTAssertTrue(exists("special.sr.log"),
                      "the sr edition must compile special.sr.tex. build/ held: \(buildListing())")
        // Negative: the base was not the one compiled.
        XCTAssertFalse(exists("special.log"),
                       "the sr edition compiled the base special.tex beside its own variant. "
                       + "build/ held: \(buildListing())")
    }

    // MARK: - a template in a subdirectory

    /// The finding this test pins (measured against the bundled tectonic,
    /// 2026-08-27): **tectonic writes its outputs into `--outdir` FLAT, named
    /// after the input's BASENAME.** `publish/templates/special.tex` yields
    /// `build/special.pdf`, never `build/templates/special.pdf`. `generatedName`
    /// therefore derives from the template's last path component, not from its
    /// path with the extension swapped — the naive form throws at the
    /// stage→Exports move with a file-not-found for a path tectonic never wrote.
    func test_aTemplateInASubdirectoryLandsItsPDFFlatUnderBuild() async throws {
        try installTemplate(named: "templates/special.tex")
        try breakTheBookTemplate()

        let config = PublishConfig(
            metadata: .init(title: "Imprint Book", author: "Tester"),
            template: "templates/special.tex")
        let compiler = try PDFCompiler(
            projectURL: tmp, astSource: OnePiece(), config: config,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)

        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported errors: \(result.errors.map(\.message))\n\nLog:\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\nLog:\n\(result.logExcerpt)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath),
                      "the compiler reported \(result.outputPath) but nothing is there")
        let pdf = PDFDocument(url: URL(fileURLWithPath: result.outputPath))
        XCTAssertGreaterThan(pdf?.pageCount ?? 0, 0,
                             "produced file at \(result.outputPath) is not a PDF with pages")

        XCTAssertTrue(exists("special.log"),
                      "tectonic writes build/special.log for templates/special.tex. "
                      + "build/ held: \(buildListing())")
        // Negative: the mirrored subdirectory is a fiction. Nothing is written
        // under build/templates/, which is why generatedName must not look there.
        XCTAssertFalse(exists("templates/special.pdf"),
                       "tectonic mirrored the template's subdirectory under build/ after all — "
                       + "generatedName's basename rule needs revisiting. build/ held: \(buildListing())")
    }

    private func buildListing() -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? []
        return names.sorted().joined(separator: ", ")
    }
}
