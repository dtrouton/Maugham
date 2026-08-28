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

    override func setUp() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
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
        // (P2: `build/body.tex` is now the wrapper over the document's bodies —
        // the emitted book lives at `build/body.<tag>.tex`, `en` for this fixture.)
        let body = try String(
            contentsOf: projectURL.appendingPathComponent(".maugham/publish/build/body.en.tex"),
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

    // MARK: - 4. Field-shaped six-piece style-scope escape (P0b)

    /// The field-shaped reproduction of the *Playlist Volume One* defect-4:
    /// in a six-piece compile, piece 2's per-piece style file did a
    /// style-file-scope `\renewcommand{\textbf}` whose body uses `\marginpar` —
    /// and piece 4 (fountain, WITH a title block) rendered its title block and
    /// scene headings restyled by that renewal two pieces later, while a solo
    /// compile of piece 4 was correct and begingroup/endgroup counts balanced.
    ///
    /// This test carries the exact triggering shape the field report described:
    /// `\marginpar` in the renewal body, a fountain title block whose
    /// `\Large\textbf{...}` title and `\scene{...}`
    /// (= `\textbf{\MakeUppercase{...}}`) headings are the field's two visible
    /// victims, and two trailing prose pieces using `**bold**`.
    ///
    /// **Outcome (2026-07-23): it does NOT reproduce** under the bundled
    /// tectonic + the current starter templates — the renewal reverts cleanly
    /// at the emitter's `\endgroup` (sentinel count stays 1). The field failure
    /// remains unexplained; the leading unproven suspect is the field project's
    /// fontspec custom-font environment (lazy bold/em family setup), which this
    /// harness cannot reproduce because sandboxed tectonic resolves fonts only
    /// from explicit file paths, not system names. The test is kept as a
    /// permanent probe: if a future tectonic/kernel/fontspec change ever lets
    /// this shape leak, it fails here loudly. The sanctioned fix either way is
    /// the required `\pieceheading`-hook scoping pattern (see EMISSION.md).
    ///
    /// Detection: the renewal body prepends the sentinel `ZZLEAK`. In a
    /// non-leaking world the sentinel appears exactly once (piece 2's own bold);
    /// any leak into a later piece prints `ZZLEAK` next to that piece's title,
    /// scene heading, or bold word.
    func test_sixPiece_marginparRenewalOfTextbf_doesNotRestyleLaterFountainOrProse() async throws {
        let piecesDir = projectURL.appendingPathComponent(".maugham/publish/pieces")
        try FileManager.default.createDirectory(at: piecesDir, withIntermediateDirectories: true)
        // Piece 2's style file: the field's triggering shape — a robust-command
        // renewal at style-file scope whose body is a \marginpar.
        let style = "\\renewcommand{\\textbf}[1]{\\marginpar{ZZLEAK #1}}"
        try style.write(to: piecesDir.appendingPathComponent("tribute.tex"),
                        atomically: true, encoding: .utf8)

        // Piece 4 is fountain WITH a full title block (Title:/Credit:/Author:)
        // plus a scene heading — the two field victims.
        let fountainWithTitleBlock = """
            Title: Distincttitleword
            Credit: written by
            Author: Distinctauthorword

            INT. SCENEDISTINCT ROOM - DAY

            A quiet action line.
            """

        let source = FixedSource(pieces: [
            .init(pieceID: "p1", title: "Opener", mode: .prose,
                  displayText: "Plain opening paragraph."),
            .init(pieceID: "p2", title: "Tribute", mode: .prose,
                  displayText: "Styled bold **boldtwoword** here."),
            .init(pieceID: "p3", title: "Interlude", mode: .prose,
                  displayText: "Another plain paragraph between."),
            .init(pieceID: "p4", title: "A Little Soul", mode: .fountain,
                  displayText: fountainWithTitleBlock),
            .init(pieceID: "p5", title: "Fifth", mode: .prose,
                  displayText: "Fifth piece bold **boldfiveword** here."),
            .init(pieceID: "p6", title: "Sixth", mode: .prose,
                  displayText: "Sixth piece bold **boldsixword** here."),
        ])
        let config = PublishConfig(
            metadata: .init(title: "Six Piece Field Repro", author: "Tester"),
            sections: ["p2": .init(styleFile: "tribute.tex")])

        let (_, pdf) = try await compile(source: source, config: config)
        let text = fullText(of: pdf)

        // Sanity: the renewal fired inside its own piece — the sentinel is
        // rendered somewhere. (In piece 2's own \marginpar the sentinel and its
        // word are hyphenated across the narrow margin, so match the sentinel
        // alone, not "ZZLEAK boldtwoword".)
        XCTAssertTrue(text.contains("ZZLEAK"),
                      "styled piece 2 must use the renewed \\textbf; PDF text:\n\(text.prefix(3000))")

        // Whole-book invariant AND the detection: a leak restyles a later
        // piece's `\textbf` into `\marginpar{ZZLEAK ...}`, printing the sentinel
        // next to that piece's title / scene / bold word — so a leak raises the
        // sentinel count above one. In a non-leaking world it appears exactly
        // once (piece 2). This is the field's defect-4 pin.
        let leakCount = text.components(separatedBy: "ZZLEAK").count - 1
        XCTAssertEqual(leakCount, 1,
            "style-file \\marginpar renewal of \\textbf must not escape piece 2's \\endgroup; "
          + "found \(leakCount) ZZLEAK sentinel(s) across the book — a count above one means the "
          + "renewal leaked into a later piece (title block / scene heading / bold). PDF text:\n\(text.prefix(3000))")

        // Named victims, for a precise failure message if the count trips: the
        // field's two visible casualties were piece 4's title block and scene
        // heading; pieces 5-6's `**bold**` are the trailing prose.
        XCTAssertFalse(text.contains("ZZLEAK Distinct"),
                       "renewal leaked into piece 4's fountain title block (two pieces later) — "
                     + "the field defect-4. PDF text:\n\(text.prefix(3000))")
        XCTAssertFalse(text.contains("ZZLEAK boldfive"),
                       "renewal leaked into piece 5's bold. PDF text:\n\(text.prefix(3000))")
        XCTAssertFalse(text.contains("ZZLEAK boldsix"),
                       "renewal leaked into piece 6's bold. PDF text:\n\(text.prefix(3000))")
    }

    // MARK: - 5. F6 title-block hook default-render equivalence

    /// F6 moved the fountain title block from hardcoded inline LaTeX to the
    /// `\screenplaytitleblock{body}` hook (declared `\providecommand`,
    /// default body reproduces the pre-F6 layout). This probe pins that the
    /// DEFAULT (no style override) compiled PDF text is unchanged: every
    /// field appears IN DECLARED ORDER, a following piece's content still
    /// appears, the title page still takes its own page, and no macro-call
    /// syntax leaks into the visible text. Five fields declared with Credit
    /// BEFORE Title exercise the order-preservation contract recorded on
    /// `emitTitlePage`: the hook must not hoist the Title field to the front
    /// (that regression shipped in the first cut of F6 and was caught in
    /// review precisely because this probe checked presence but not order).
    func test_titlePage_screenplayTitleBlockHook_defaultRenderUnchanged() async throws {
        let fountainWithTitleBlock = """
            Credit: written by
            Title: The Distinct Play
            Draft date: First draft
            Author: Distinct Author
            Contact: agent@example.com

            INT. HOUSE - DAY

            Distinctive action line.
            """
        let source = FixedSource(pieces: [
            .init(pieceID: "p1", title: "Title Card", mode: .fountain,
                  displayText: fountainWithTitleBlock),
            .init(pieceID: "p2", title: "After", mode: .prose,
                  displayText: "Prose piece right after the screenplay."),
        ])
        let (_, pdf) = try await compile(
            source: source,
            config: PublishConfig(metadata: .init(title: "Title Block Probe", author: "Tester")))
        let text = fullText(of: pdf)

        let declaredOrder = ["written by", "The Distinct Play", "First draft",
                             "Distinct Author", "agent@example.com"]
        for expected in declaredOrder {
            XCTAssertTrue(text.contains(expected),
                "title-page field \"\(expected)\" missing from rendered PDF text:\n\(text.prefix(2000))")
        }
        // Relative order: the fields must render in DECLARED order — Credit
        // ("written by") before Title, Title before Draft date, etc. A hook
        // shape that reassembles fields positionally (e.g. hoisting Title
        // first) passes the presence checks above but fails here.
        let indices = declaredOrder.map { field -> String.Index in
            guard let r = text.range(of: field) else {
                XCTFail("field \"\(field)\" missing (already asserted above)")
                return text.startIndex
            }
            return r.lowerBound
        }
        for i in 1..<indices.count {
            XCTAssertLessThan(indices[i - 1], indices[i],
                "title-page fields out of declared order: \"\(declaredOrder[i - 1])\" must "
              + "render before \"\(declaredOrder[i])\". PDF text:\n\(text.prefix(2000))")
        }
        XCTAssertTrue(text.contains("Distinctive action line."),
                      "the screenplay body must still render after the title page")
        XCTAssertTrue(text.contains("Prose piece right after the screenplay."),
                      "a following piece must still render after the fountain piece's title page")
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 2,
            "the title page must still take its own page (\\clearpage), not share with the body")

        // No macro-call syntax should ever reach the rendered text — a
        // regression here would mean the hook call itself is leaking as
        // literal text instead of compiling.
        XCTAssertFalse(text.contains("screenplaytitleblock"),
                       "the macro name must never appear in rendered PDF text")
    }
}
