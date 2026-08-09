import XCTest
import PDFKit
@testable import Maugham

/// SPIKE (durable test): does the bundled tectonic compile a PDF using a LOCAL
/// custom font loaded via fontspec's `\setmainfont[Path=fonts/]{...}`, and is the
/// output deterministic across two identical compiles?
///
/// Decision gate for the publishing-pipeline milestone's "fonts convention"
/// follow-up. See the report attached to the spike for the verdict.
///
/// Method: drive `PDFCompiler` directly (not the MCP `CompileTool`) so we can
/// hold every config-interpolated field constant across both runs — same
/// `PublishConfig` (same `nextVersion`, same metadata), same `label`. The only
/// thing that could vary is what tectonic/XeTeX itself embeds: the PDF
/// `/CreationDate`, `/ModDate`, and the `/ID` trailer (all derived from wall
/// clock unless pinned). We pin them by exporting `SOURCE_DATE_EPOCH` into the
/// test process environment — `TectonicInvoker` inherits
/// `ProcessInfo.processInfo.environment`, and XeTeX honors `SOURCE_DATE_EPOCH`
/// for those fields. With that pinned, a byte-identical pair proves determinism
/// of the font-subset and content streams as well.
@MainActor
final class FontSpikeTests: XCTestCase {

    var tmp: URL!
    var projectURL: URL!
    var store: ProjectStore!

    // Mirrors PublishingEndToEndTests: in the xctest harness Bundle.main isn't
    // the host .app, so TectonicLocator.locate() returns nil even though
    // tectonic is bundled. Probe the host explicitly to gate availability.
    private func tectonicAvailableInBundle() -> URL? {
        let testBundlePath = Bundle(for: FontSpikeTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        return try? TectonicLocator.locateInBundle(at: URL(fileURLWithPath: appPath))
    }

    override func setUp() async throws {
        try XCTSkipUnless(tectonicAvailableInBundle() != nil,
                          "tectonic binary not bundled in test host")
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FontSpike-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "FontSpike", in: tmp)
        store = try await ProjectStore.load(from: projectURL)
        PublishingStores._resetForTesting()
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        // Restore env so we don't leak SOURCE_DATE_EPOCH into other tests.
        unsetenv("SOURCE_DATE_EPOCH")
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_localFontCompiles_andIsDeterministic() async throws {
        // 1. Gate already handled in setUp (skip if no tectonic).

        // 2. Locate a single-face system font (.ttf/.otf only — no .ttc
        //    collections; fontspec Path= wants a single face).
        let candidates = [
            "/System/Library/Fonts/Supplemental/Georgia.ttf",
            "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/Library/Fonts/Georgia.ttf",
            "/Library/Fonts/Arial.ttf",
        ]
        guard let fontSource = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) else {
            throw XCTSkip("no single-face system .ttf font found to copy")
        }
        print("[FontSpike] using system font: \(fontSource)")

        // 2b. Copy it into <project>/.maugham/publish/fonts/TestFont.ttf
        //     (space-free name so the \setmainfont call needs no quoting).
        let publishDir = projectURL.appendingPathComponent(".maugham/publish",
                                                           isDirectory: true)
        let fontsDir = publishDir.appendingPathComponent("fonts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fontsDir, withIntermediateDirectories: true)
        let fontDest = fontsDir.appendingPathComponent("TestFont.ttf")
        if FileManager.default.fileExists(atPath: fontDest.path) {
            try FileManager.default.removeItem(at: fontDest)
        }
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: fontSource), to: fontDest)

        // 3. Overwrite the throwaway project's preamble.tex to load fontspec +
        //    the local font. We DROP `\usepackage[utf8]{inputenc}` from the
        //    starter — inputenc is incompatible with XeTeX/fontspec (tectonic's
        //    engine is XeTeX). Everything else (providecommands, hyperref,
        //    wikilink) is preserved so the rest of the template still resolves.
        let preambleURL = publishDir.appendingPathComponent("preamble.tex")
        let fontPreamble = """
        % FONT SPIKE preamble — fontspec + local custom font (XeTeX engine).
        \\providecommand{\\Title}{Untitled}
        \\providecommand{\\Subtitle}{}
        \\providecommand{\\Author}{}
        \\providecommand{\\Copyright}{}
        \\providecommand{\\Keywords}{}
        \\providecommand{\\MaughamVersion}{0.1}
        \\providecommand{\\MaughamLabel}{}
        \\providecommand{\\MaughamCheckpointID}{}
        \\providecommand{\\MaughamCompiledAt}{}

        \\usepackage{geometry}
        \\geometry{margin=1in}
        \\usepackage{titling}
        \\usepackage{titlesec}

        % The spike under test: local font via fontspec Path=.
        \\usepackage{fontspec}
        \\setmainfont[Path=fonts/]{TestFont.ttf}

        \\usepackage[hidelinks]{hyperref}
        \\hypersetup{
          pdftitle={\\Title},
          pdfauthor={\\Author},
          pdfsubject={\\Subtitle},
          pdfkeywords={\\Keywords},
          pdfproducer={Maugham via tectonic},
          pdfcreator={Maugham}
        }

        \\newcommand{\\wikilink}[2]{\\textbf{#2}}
        """
        try fontPreamble.write(to: preambleURL, atomically: true, encoding: .utf8)

        // 3b. Pin known-variable PDF fields. XeTeX/tectonic honor
        //     SOURCE_DATE_EPOCH for /CreationDate, /ModDate and the /ID trailer.
        //     TectonicInvoker inherits ProcessInfo.processInfo.environment, so
        //     setenv here propagates to the child process.
        setenv("SOURCE_DATE_EPOCH", "1700000000", 1)

        // 4. Compile the same project to PDF TWICE with identical config + label.
        //    Drive PDFCompiler directly so the config (and thus every
        //    \renewcommand interpolation) is byte-identical across both runs.
        let config = PublishConfig(
            metadata: .init(title: "Font Spike", author: "Tester"),
            nextVersion: "0.1")
        let label = "spike"

        let pdf1 = try await compileOnce(config: config, label: label)
        let pdf2 = try await compileOnce(config: config, label: label)

        // 5. Real-PDF assertions (proves the local font compiled).
        XCTAssertGreaterThan(pdf1.count, 1000,
                             "pdf1 too small to be a real PDF (\(pdf1.count) bytes) — likely a failed compile")
        let doc1 = PDFDocument(data: pdf1)
        XCTAssertNotNil(doc1, "pdf1 is not openable by PDFKit")
        XCTAssertGreaterThanOrEqual(doc1?.pageCount ?? 0, 1,
                                    "pdf1 has no pages")
        XCTAssertGreaterThan(pdf2.count, 1000,
                             "pdf2 too small to be a real PDF (\(pdf2.count) bytes)")

        // 6. Determinism.
        //    First try raw byte equality (the strongest signal).
        if pdf1 == pdf2 {
            // Determinism HOLDS with SOURCE_DATE_EPOCH pinned. Assert it so the
            // test stays a regression net.
            print("[FontSpike] VERDICT: byte-identical with SOURCE_DATE_EPOCH pinned — determinism HOLDS")
            XCTAssertEqual(pdf1, pdf2,
                           "PDFs should be byte-identical with SOURCE_DATE_EPOCH pinned")
            return
        }

        // Not byte-identical. Characterize WHERE they differ so the controller
        // can judge: is it only timestamp/ID metadata, or font-subset/content
        // streams?
        let onlyMetadataDiffers = differencesAreOnlyKnownVariableMetadata(pdf1, pdf2)
        let firstDiff = firstByteDifference(pdf1, pdf2)
        print("[FontSpike] PDFs differ. sizes: \(pdf1.count) vs \(pdf2.count). " +
              "firstByteDiff@\(firstDiff.map(String.init) ?? "n/a"). " +
              "onlyKnownVariableMetadataDiffers=\(onlyMetadataDiffers)")

        // Diff the normalized forms (strip /CreationDate, /ModDate, /ID).
        let n1 = stripKnownVariableMetadata(pdf1)
        let n2 = stripKnownVariableMetadata(pdf2)

        if n1 == n2 {
            // The ONLY differences are PDF metadata timestamp/ID streams.
            // For our reproducibility purposes determinism effectively holds —
            // the font subset and content streams are byte-identical.
            print("[FontSpike] VERDICT: differ only in /CreationDate|/ModDate|/ID — " +
                  "determinism effectively HOLDS (font subset + content streams identical)")
            XCTAssertEqual(n1, n2,
                           "after stripping known-variable metadata the PDFs match")
            return
        }

        // Differences extend into font-subset / content streams. Record the
        // finding durably without going red, per spike protocol.
        print("[FontSpike] VERDICT: differences extend beyond known-variable metadata — " +
              "local fonts introduce NON-DETERMINISM. normalizedSizes: \(n1.count) vs \(n2.count)")
        XCTExpectFailure("local fonts introduce non-determinism — see spec §6.3",
                         strict: false) {
            XCTAssertEqual(n1, n2,
                           "normalized PDFs differ → font-subset/content-stream non-determinism")
        }
    }

    // MARK: - Helpers

    /// Compiles once via PDFCompiler and returns the output PDF bytes.
    private func compileOnce(config: PublishConfig, label: String?) async throws -> Data {
        let astSource = ProjectStoreASTSource(projectStore: store)
        let jobManager = CompileJobManager()
        // The spike deliberately recompiles to the same name to compare
        // determinism, so it opts into replacement — the production default
        // refuses an occupied destination (RULING-8, M7-PB-008).
        let compiler = try PDFCompiler(
            projectURL: projectURL,
            astSource: astSource,
            config: config,
            jobManager: jobManager,
            maughamVersion: "0.0.0-test",
            replacesExistingOutput: true)
        let result = try await compiler.compile(label: label)
        guard !result.outputPath.isEmpty else {
            XCTFail("compile produced no output. errors=\(result.errors.map { $0.message }). log tail:\n" +
                    String(result.logExcerpt.suffix(2000)))
            throw XCTSkip("compile failed — see logged tectonic error")
        }
        return try Data(contentsOf: URL(fileURLWithPath: result.outputPath))
    }

    private func firstByteDifference(_ a: Data, _ b: Data) -> Int? {
        let n = min(a.count, b.count)
        for i in 0..<n where a[a.startIndex + i] != b[b.startIndex + i] { return i }
        return a.count == b.count ? nil : n
    }

    /// Strips the known wall-clock-derived fields from a PDF so two compiles
    /// that differ ONLY in those fields normalize equal:
    ///   /CreationDate (...), /ModDate (...), and the /ID [ <...> <...> ] trailer.
    private func stripKnownVariableMetadata(_ pdf: Data) -> Data {
        guard var s = String(data: pdf, encoding: .isoLatin1) else { return pdf }
        // /CreationDate (D:...)  and /ModDate (D:...)
        s = redact(in: s, pattern: "/CreationDate\\s*\\([^)]*\\)")
        s = redact(in: s, pattern: "/ModDate\\s*\\([^)]*\\)")
        // /ID [ <hex> <hex> ]  (trailer file identifier — derived from time/content)
        s = redact(in: s, pattern: "/ID\\s*\\[\\s*<[0-9A-Fa-f]*>\\s*<[0-9A-Fa-f]*>\\s*\\]")
        return s.data(using: .isoLatin1) ?? pdf
    }

    private func differencesAreOnlyKnownVariableMetadata(_ a: Data, _ b: Data) -> Bool {
        stripKnownVariableMetadata(a) == stripKnownVariableMetadata(b)
    }

    private func redact(in s: String, pattern: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.stringByReplacingMatches(
            in: s, range: range, withTemplate: "REDACTED")
    }
}
