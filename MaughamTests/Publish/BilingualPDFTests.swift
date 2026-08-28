import XCTest
import PDFKit
import MaughamCore
@testable import Maugham

/// P2 Task 3: the PDF is a SEQUENCE of bodies.
///
/// `build/body.tex` stops being the book and becomes a wrapper: a guarded
/// `MaughamBody` definition followed by one `\begin{MaughamBody}{<tag>}…`
/// line per rendered language, each inputting its own metadata block and its
/// own emitted body. A template that wants to give each half its own title
/// page redefines `MaughamBody`; one that says nothing gets the starter's
/// `\clearpage`.
///
/// The single-body identities are what make this safe to ship: one body must
/// produce byte-identical `build/metadata.tex` and an equal page count to the
/// compile before the wrapper existed.
@MainActor
final class BilingualPDFTests: XCTestCase {

    var tmp: URL!
    var publish: URL!
    var build: URL!

    override func setUp() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BilingualPDF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
        publish = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        build = publish.appendingPathComponent("build", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixtures

    /// The starter fixture: three plain paragraphs, one piece. Deliberately
    /// language-ignorant — a single-body compile must keep working with a
    /// source that has never heard of languages (BodyPlan constraint 2).
    private struct StarterPiece: ProjectASTBuilder.Source {
        var text = "The first paragraph, plainly set.\n\n"
                 + "The second paragraph, also plain.\n\n"
                 + "The third paragraph closes the chapter."
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "Opening", mode: .prose, displayText: text)]
        }
    }

    /// A source that answers with different text per language — the seam Task 3
    /// owns (each body reads its OWN source), standing in for
    /// `ProjectStoreASTSource`'s translation substitution, which Task 8 already
    /// pins and which this task does not touch.
    private struct PerLanguagePiece: LanguageRebindableSource {
        let tag: String?
        static let sourceSentence = "Sourcelanguageparagraphone."
        static let translatedSentence = "Prevedeniparagrafjedan."
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "Opening", mode: .prose,
                   displayText: tag == nil ? Self.sourceSentence : Self.translatedSentence)]
        }
        func rebound(toLanguage tag: String?) -> ProjectASTBuilder.Source {
            PerLanguagePiece(tag: tag)
        }
    }

    /// P3 Task 2. A screenplay that hands its op-log PARAGRAPHS as well as its
    /// display text, so `ProjectASTBuilder` can hang a `¶id` on each node — the
    /// premise every anchor in this file rests on. Two sluglines and two
    /// actions; the ids are the SAME in both languages, which is exactly what
    /// makes a cross-link resolvable (`p-en-aaaa` ↔ `p-sr-aaaa`).
    private struct AnchoredScreenplay: LanguageRebindableSource {
        let tag: String?
        static let source: [(id: String, text: String)] = [
            ("aaaa", "INT. ROOM - DAY"),
            ("bbbb", "He waits by the window."),
            ("cccc", "EXT. STREET - NIGHT"),
            ("dddd", "She walks away."),
        ]
        static let translated: [(id: String, text: String)] = [
            ("aaaa", "INT. SOBA - DAN"),
            ("bbbb", "Ceka kraj prozora."),
            ("cccc", "EXT. ULICA - VECE"),
            ("dddd", "Ona odlazi."),
        ]
        /// Two `\\scene` nodes per body — the count the link census multiplies.
        static let sluglinesPerBody = 2
        var rows: [(id: String, text: String)] { tag == nil ? Self.source : Self.translated }
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "Opening", mode: .fountain,
                   displayText: rows.map(\.text).joined(separator: "\n\n"),
                   paragraphs: rows)]
        }
        func rebound(toLanguage tag: String?) -> ProjectASTBuilder.Source {
            AnchoredScreenplay(tag: tag)
        }
    }

    private func baseConfig() -> PublishConfig {
        var cfg = PublishConfig(metadata: .init(title: "Base Title", author: "Tester"))
        cfg.metadata.language = "en"
        cfg.languageOverrides = [
            "sr": .init(metadata: ["title": "Prevedeni Naslov"])
        ]
        return cfg
    }

    /// A two-body plan (`en` then `sr`) over `PerLanguagePiece`, built through
    /// the real `BodyPlan.make` so the compiler is driven by the value Task 5
    /// will hand it.
    private func twoBodyPlan(_ cfg: PublishConfig) throws -> BodyPlan {
        let set = try LanguageSet(language: nil, languages: ["source", "sr"], sourceTag: "en")
        return try BodyPlan.make(
            set: set, resolved: cfg, source: PerLanguagePiece(tag: nil),
            publishDir: publish, wrap: { $0 })
    }

    private func contents(_ relative: String) throws -> String {
        try String(contentsOf: build.appendingPathComponent(relative), encoding: .utf8)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: build.appendingPathComponent(relative).path)
    }

    private func buildListing() -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? []
        return names.sorted().joined(separator: ", ")
    }

    /// Copied from `PublishingEndToEndTests` (where it is `private`) rather than
    /// shared: the two suites are independent, and a `PDFDocument` page walk is
    /// four lines.
    private func pdfPlainText(at url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var out = ""
        for i in 0..<doc.pageCount { out += doc.page(at: i)?.string ?? "" }
        return out
    }

    /// P3 Task 2. The anchored fixture's config: the piece is kept OUT of the
    /// table of contents, because a ToC entry is itself a hyperref link and the
    /// link census below counts cross-links. With no ToC entries the baseline
    /// is a clean zero and the census measures only what this task emits.
    private func anchoredConfig() -> PublishConfig {
        var cfg = baseConfig()
        cfg.sections = ["p1": .init(includeInToc: false)]
        return cfg
    }

    private func anchoredTwoBodyPlan(_ cfg: PublishConfig) throws -> BodyPlan {
        let set = try LanguageSet(language: nil, languages: ["source", "sr"], sourceTag: "en")
        return try BodyPlan.make(
            set: set, resolved: cfg, source: AnchoredScreenplay(tag: nil),
            publishDir: publish, wrap: { $0 })
    }

    /// Every `Link` annotation in the PDF. hyperref renders `\hyperlink` as one,
    /// and a `\hypertarget` as none — a target is a destination, not a link — so
    /// this counts cross-links and nothing else.
    private func linkAnnotationCount(at url: URL) -> Int {
        guard let doc = PDFDocument(url: url) else { return -1 }
        var count = 0
        for i in 0..<doc.pageCount {
            count += (doc.page(at: i)?.annotations ?? []).filter { $0.type == "Link" }.count
        }
        return count
    }

    // MARK: - single body: the wrapper's shape

    func test_theWrapperIsTheGuardLineAndOneLinePerBody() async throws {
        let cfg = baseConfig()
        let compiler = try PDFCompiler(
            projectURL: tmp, astSource: StarterPiece(), config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        _ = try await compiler.compile(label: nil)

        XCTAssertEqual(try contents("body.tex"), """
            \\ifdefined\\MaughamBody\\else\\newenvironment{MaughamBody}[1]{\\clearpage}{}\\fi
            \\begin{MaughamBody}{en}\\input{build/metadata.en}\\input{build/body.en}\\end{MaughamBody}
            """,
            "build/body.tex is the wrapper, not the book: a guard line plus one line per body")
    }

    // MARK: - single body: the emitted body is untouched

    func test_theBodyFileIsExactlyWhatTheEmitterReturns() async throws {
        let cfg = baseConfig()
        let piece = StarterPiece()
        let compiler = try PDFCompiler(
            projectURL: tmp, astSource: piece, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        _ = try await compiler.compile(label: nil)

        let expected = LaTeXBodyEmitter.emit(
            try ProjectASTBuilder.build(from: piece), config: cfg)
        XCTAssertEqual(try contents("body.en.tex"), expected,
            "body.<tag>.tex is the emitter's output verbatim. P3 Task 2 note: the "
            + "compiler now passes an anchorTag, and this stays an equality against "
            + "the UNTAGGED emit because StarterPiece hands no paragraphs — an "
            + "unanchored source emits the same bytes tagged or not. "
            + "test_eachBodyIsAnchoredUnderItsOwnTagAndLinksToTheOthers is what "
            + "pins the tagged case.")
    }

    // MARK: - single body: metadata.tex is byte-identical

    /// Constraint 7. Pinned against a LITERAL rather than against a re-render
    /// of the same helper, so a change to the block's shape fails here instead
    /// of agreeing with itself. This is the exact text `PDFCompiler` wrote at
    /// `cacb84e7`, for this config.
    func test_theDocumentMetadataIsByteIdenticalToTheBlockWrittenBeforeTheWrapper() async throws {
        var cfg = baseConfig()
        cfg.metadata.subtitle = "A Subtitle"
        cfg.metadata.copyright = "© 2026"
        cfg.metadata.keywords = ["one", "two"]
        cfg.nextVersion = "0.4"
        let compiler = try PDFCompiler(
            projectURL: tmp, astSource: StarterPiece(), config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        _ = try await compiler.compile(label: "draft")

        XCTAssertEqual(try contents("metadata.tex"), """
            \\renewcommand{\\Title}{Base Title}
            \\renewcommand{\\Subtitle}{A Subtitle}
            \\renewcommand{\\Author}{Tester}
            \\renewcommand{\\Copyright}{© 2026}
            \\renewcommand{\\Keywords}{one, two}
            \\renewcommand{\\MaughamVersion}{0.4}
            \\renewcommand{\\MaughamLabel}{draft}
            \\providecommand{\\MaughamLanguage}{}
            \\renewcommand{\\MaughamLanguage}{en}
            """,
            "build/metadata.tex must still be the block the template's "
            + "\\InputIfFileExists{build/metadata} has always picked up")
        // And the first body's own copy is the same block.
        XCTAssertEqual(try contents("metadata.en.tex"), try contents("metadata.tex"),
                       "for one body the document metadata IS that body's metadata")
    }

    // MARK: - single body: the wrapper costs no pages

    /// Measured 2026-08-28 against the bundled tectonic: this fixture compiled
    /// to **3 pages** at `cacb84e7` (title page, table of contents, body) with
    /// the pre-wrapper single `build/body.tex`, and to **3 pages** with the
    /// wrapper. The starter's `frontmatter.tex` ends in `\newpage`, so the
    /// wrapper's `\clearpage` opens no page of its own.
    func test_theWrapperCostsNoPages() async throws {
        let compiler = try PDFCompiler(
            projectURL: tmp, astSource: StarterPiece(), config: baseConfig(),
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported errors: \(result.errors.map(\.message))\n\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\n\(result.logExcerpt)")
        let pdf = PDFDocument(url: URL(fileURLWithPath: result.outputPath))
        XCTAssertEqual(pdf?.pageCount, 3,
            "the wrapper changed the starter fixture's pagination; it measured 3 pages "
            + "before the wrapper existed and must still")
    }

    // MARK: - two bodies: each writes its own body file

    func test_twoBodiesEachWriteTheirOwnBodyFile() async throws {
        let cfg = baseConfig()
        let compiler = try PDFCompiler(
            projectURL: tmp, bodies: try twoBodyPlan(cfg).bodies, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        _ = try await compiler.compile(label: nil)

        XCTAssertTrue(exists("body.en.tex"), "build/ held: \(buildListing())")
        XCTAssertTrue(exists("body.sr.tex"), "build/ held: \(buildListing())")
        XCTAssertTrue(try contents("body.en.tex").contains(PerLanguagePiece.sourceSentence),
                      "the source body must carry the source text")
        XCTAssertTrue(try contents("body.sr.tex").contains(PerLanguagePiece.translatedSentence),
                      "the sr body must carry the TRANSLATED text — each body reads its own source")
        // Negative: the second body did not silently reuse the first one's text.
        XCTAssertFalse(try contents("body.sr.tex").contains(PerLanguagePiece.sourceSentence),
                       "the sr body carries the source text — the bodies share a source")
        XCTAssertEqual(try contents("body.tex"), """
            \\ifdefined\\MaughamBody\\else\\newenvironment{MaughamBody}[1]{\\clearpage}{}\\fi
            \\begin{MaughamBody}{en}\\input{build/metadata.en}\\input{build/body.en}\\end{MaughamBody}
            \\begin{MaughamBody}{sr}\\input{build/metadata.sr}\\input{build/body.sr}\\end{MaughamBody}
            """,
            "the wrapper names both bodies, in order")
    }

    // MARK: - two bodies: each writes its own metadata

    func test_twoBodiesEachWriteTheirOwnMetadata() async throws {
        let cfg = baseConfig()
        let compiler = try PDFCompiler(
            projectURL: tmp, bodies: try twoBodyPlan(cfg).bodies, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        _ = try await compiler.compile(label: nil)

        let en = try contents("metadata.en.tex")
        let sr = try contents("metadata.sr.tex")
        XCTAssertTrue(en.contains("\\renewcommand{\\MaughamLanguage}{en}"), en)
        XCTAssertTrue(sr.contains("\\renewcommand{\\MaughamLanguage}{sr}"), sr)
        XCTAssertTrue(en.contains("\\renewcommand{\\Title}{Base Title}"), en)
        XCTAssertTrue(sr.contains("\\renewcommand{\\Title}{Prevedeni Naslov}"),
                      "the sr body's metadata must carry the language override's title: \(sr)")
        // Constraint 7's sharp edge: the DOCUMENT-level block is the FIRST
        // body's, so the title page and hyperref metadata stay the source
        // edition's. A second body leaking here would retitle the whole book.
        XCTAssertEqual(try contents("metadata.tex"), en,
                       "document-level metadata must be the first body's, not the last body's")
    }

    // MARK: - two bodies: the PDF reads in order

    func test_thePDFCarriesTheSourceBodyBeforeTheTranslatedOne() async throws {
        let cfg = baseConfig()
        let compiler = try PDFCompiler(
            projectURL: tmp, bodies: try twoBodyPlan(cfg).bodies, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported errors: \(result.errors.map(\.message))\n\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\n\(result.logExcerpt)")

        let text = pdfPlainText(at: URL(fileURLWithPath: result.outputPath))
        guard let source = text.range(of: PerLanguagePiece.sourceSentence),
              let translated = text.range(of: PerLanguagePiece.translatedSentence) else {
            return XCTFail("the PDF is missing one of the two bodies. Plain text was:\n\(text)")
        }
        XCTAssertTrue(source.lowerBound < translated.lowerBound,
                      "the bodies must appear in the plan's order — source first, then sr")
    }

    // MARK: - a template may define the environment itself

    /// The whole point of the wrapper: a template that defines `MaughamBody`
    /// wins, and sees it once per body — which is how it gives each half its
    /// own title page. `\renewenvironment`, not `\newenvironment`, because the
    /// starter's own `preamble.tex` now ships the guarded default.
    func test_aTemplateDefiningTheEnvironmentSeesItOncePerBody() async throws {
        var text = try String(
            contentsOf: publish.appendingPathComponent("template.tex"), encoding: .utf8)
        text = text.replacingOccurrences(
            of: "\\begin{document}",
            with: "\\renewenvironment{MaughamBody}[1]{\\clearpage HALFMARKER #1\\par}{}\n\\begin{document}")
        try text.write(to: publish.appendingPathComponent("template.tex"),
                       atomically: true, encoding: .utf8)

        let cfg = baseConfig()
        let plan = try twoBodyPlan(cfg)
        let compiler = try PDFCompiler(
            projectURL: tmp, bodies: plan.bodies, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported errors: \(result.errors.map(\.message))\n\n\(result.logExcerpt)")

        let text2 = pdfPlainText(at: URL(fileURLWithPath: result.outputPath))
        let occurrences = text2.components(separatedBy: "HALFMARKER").count - 1
        XCTAssertEqual(occurrences, plan.bodies.count,
            "the template's own MaughamBody must run once per body (\(plan.bodies.count)); "
            + "the PDF's plain text was:\n\(text2)")
    }

    // MARK: - a template in a subdirectory

    /// Measured 2026-08-28 against the bundled tectonic: `\input` inside
    /// `build/body.tex` resolves relative to the **primary template's**
    /// directory, not to `body.tex`'s own directory and not to the process
    /// working directory. With CWD at the publish dir and
    /// `build/metadata.en.tex` on disk, a template at `templates/special.tex`
    /// fails `\input{build/metadata.en}` with
    /// `! LaTeX Error: File 'build/metadata.en' not found.` — so the wrapper
    /// carries one `../` per level of the template's own path.
    func test_aSubdirectoryTemplateCompilesEveryBody() async throws {
        var text = try String(
            contentsOf: publish.appendingPathComponent("template.tex"), encoding: .utf8)
        text = text
            .replacingOccurrences(of: "\\input{", with: "\\input{../")
            .replacingOccurrences(of: "\\InputIfFileExists{", with: "\\InputIfFileExists{../")
        let dest = publish.appendingPathComponent("templates/special.tex")
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: dest, atomically: true, encoding: .utf8)
        // The book's own template is broken, so a fallback to it fails loudly.
        try "\\undefined_command_xyz".write(
            to: publish.appendingPathComponent("template.tex"),
            atomically: true, encoding: .utf8)

        var cfg = baseConfig()
        cfg.template = "templates/special.tex"
        let compiler = try PDFCompiler(
            projectURL: tmp, bodies: try twoBodyPlan(cfg).bodies, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)

        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported errors: \(result.errors.map(\.message))\n\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\n\(result.logExcerpt)")
        XCTAssertEqual(try contents("body.tex"), """
            \\ifdefined\\MaughamBody\\else\\newenvironment{MaughamBody}[1]{\\clearpage}{}\\fi
            \\begin{MaughamBody}{en}\\input{../build/metadata.en}\\input{../build/body.en}\\end{MaughamBody}
            \\begin{MaughamBody}{sr}\\input{../build/metadata.sr}\\input{../build/body.sr}\\end{MaughamBody}
            """,
            "a template one directory down needs one ../ on every wrapper input")

        let plain = pdfPlainText(at: URL(fileURLWithPath: result.outputPath))
        XCTAssertTrue(plain.contains(PerLanguagePiece.sourceSentence),
                      "the subdirectory template's PDF is missing the source body:\n\(plain)")
        XCTAssertTrue(plain.contains(PerLanguagePiece.translatedSentence),
                      "the subdirectory template's PDF is missing the sr body:\n\(plain)")
    }

    // MARK: - a project that predates the wrapper

    /// The guard line's whole reason to exist. `PublishStarter.installIfMissing`
    /// never updates an existing project's files, so a book initialised before
    /// P2 has a `preamble.tex` that has never heard of `MaughamBody` — and its
    /// next compile reads a `build/body.tex` full of the environment. Stripping
    /// the definition from the installed starter reproduces exactly that book.
    func test_aProjectWhosePreambleNeverHeardOfTheEnvironmentStillCompiles() async throws {
        let preambleURL = publish.appendingPathComponent("preamble.tex")
        var preamble = try String(contentsOf: preambleURL, encoding: .utf8)
        let definition = "\\ifdefined\\MaughamBody\\else\\newenvironment{MaughamBody}[1]{\\clearpage}{}\\fi"
        XCTAssertTrue(preamble.contains(definition),
                      "the starter preamble no longer ships the definition this test strips")
        preamble = preamble.replacingOccurrences(of: definition, with: "")
        try preamble.write(to: preambleURL, atomically: true, encoding: .utf8)

        let compiler = try PDFCompiler(
            projectURL: tmp, astSource: StarterPiece(), config: baseConfig(),
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)

        XCTAssertTrue(result.errors.isEmpty,
                      "a pre-P2 project failed to compile — the emitted guard line is what "
                      + "stands in for the preamble it will never receive: "
                      + "\(result.errors.map(\.message))\n\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\n\(result.logExcerpt)")
    }

    // MARK: - a tag that cannot be a filename

    /// `displayTag` is a validated language tag in every production path but
    /// one: the source body's tag is `config.metadata.language`, free-form
    /// config text. A value that cannot be a LaTeX `\input` argument would emit
    /// TeX that cannot compile, so the wrapper falls back to the body's ordinal
    /// rather than failing a compile that works today.
    func test_aTagThatCannotBeAFilenameFallsBackToItsOrdinal() async throws {
        var cfg = baseConfig()
        cfg.metadata.language = "en US"
        let compiler = try PDFCompiler(
            projectURL: tmp, astSource: StarterPiece(), config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)

        XCTAssertTrue(exists("body.1.tex"),
                      "an unusable tag must fall back to the ordinal. build/ held: \(buildListing())")
        XCTAssertEqual(try contents("body.tex"), """
            \\ifdefined\\MaughamBody\\else\\newenvironment{MaughamBody}[1]{\\clearpage}{}\\fi
            \\begin{MaughamBody}{1}\\input{build/metadata.1}\\input{build/body.1}\\end{MaughamBody}
            """)
        XCTAssertTrue(result.errors.isEmpty,
                      "the compile must still succeed: \(result.errors.map(\.message))")
        // The METADATA still carries the writer's own spelling — only the
        // filename is sanitised.
        let meta = try contents("metadata.tex")
        XCTAssertTrue(meta.contains("\\renewcommand{\\MaughamLanguage}{en US}"), meta)
    }

    // MARK: - P3 Task 2: the compiler tags every body and names the others

    /// The wiring test, no compile needed: each body is emitted under its OWN
    /// tag and told about every OTHER body — so `body.en.tex` targets `p-en-…`
    /// and links to `p-sr-…`, and `body.sr.tex` is its mirror. A compiler that
    /// passed its own tag as a cross-link would make every slugline link to
    /// itself; a compiler that passed no tag would emit no anchors at all.
    func test_eachBodyIsAnchoredUnderItsOwnTagAndLinksToTheOthers() async throws {
        let cfg = anchoredConfig()
        let compiler = try PDFCompiler(
            projectURL: tmp, bodies: try anchoredTwoBodyPlan(cfg).bodies, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        _ = try await compiler.compile(label: nil)

        let en = try contents("body.en.tex")
        let sr = try contents("body.sr.tex")
        XCTAssertTrue(en.contains("\\hypertarget{p-en-aaaa}{}\n\\MaughamCrossLink{p-sr-aaaa}{\\scene{INT. ROOM - DAY}}"), en)
        XCTAssertTrue(en.contains("\\hypertarget{p-en-bbbb}{}\n\\action{He waits by the window.}"), en)
        XCTAssertTrue(sr.contains("\\hypertarget{p-sr-aaaa}{}\n\\MaughamCrossLink{p-en-aaaa}{\\scene{INT. SOBA - DAN}}"), sr)
        // Neither body links to itself.
        XCTAssertFalse(en.contains("\\MaughamCrossLink{p-en-"), en)
        XCTAssertFalse(sr.contains("\\MaughamCrossLink{p-sr-"), sr)
        // One cross-link per slugline, not one per node.
        XCTAssertEqual(en.components(separatedBy: "\\MaughamCrossLink{p-").count - 1,
                       AnchoredScreenplay.sluglinesPerBody, en)
    }

    /// The single-body control for the same wiring: the compiler still tags the
    /// body (the anchors are there for a template to link to) but has no other
    /// body to name, so not one `\MaughamCrossLink` is emitted.
    func test_aSingleBodyIsStillAnchoredAndCrossLinksNothing() async throws {
        let cfg = anchoredConfig()
        let compiler = try PDFCompiler(
            projectURL: tmp, astSource: AnchoredScreenplay(tag: nil), config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        _ = try await compiler.compile(label: nil)

        let en = try contents("body.en.tex")
        XCTAssertTrue(en.contains("\\hypertarget{p-en-aaaa}{}\n\\scene{INT. ROOM - DAY}"), en)
        XCTAssertFalse(en.contains("\\MaughamCrossLink{p-"), en)
    }

    // MARK: - P3 Task 2: anchors cost no pages

    /// Measured 2026-08-28 against the bundled tectonic, both numbers from this
    /// very fixture and this very config: **4 pages** at BASE (`9a55484f`, the
    /// emitter ignoring `Section.anchors` entirely — measured by having
    /// `PDFCompiler` pass no tag) and **4 pages** with every paragraph anchored
    /// and every slugline cross-linked. A `\hypertarget{…}{}` sets nothing and
    /// `\hyperlink` sets its content unchanged, so neither can move the
    /// pagination of a book already typeset — this is the test that says so.
    func test_anchoringEveryParagraphCostsNoPages() async throws {
        let cfg = anchoredConfig()
        let compiler = try PDFCompiler(
            projectURL: tmp, bodies: try anchoredTwoBodyPlan(cfg).bodies, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported errors: \(result.errors.map(\.message))\n\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\n\(result.logExcerpt)")
        let pdf = PDFDocument(url: URL(fileURLWithPath: result.outputPath))
        XCTAssertEqual(pdf?.pageCount, 4,
            "anchoring changed the fixture's pagination; it measured 4 pages at BASE, "
            + "before the emitter had heard of anchors, and must still")
    }

    // MARK: - P3 Task 2: the links are really in the PDF

    /// The end-to-end proof, through the starter's own `preamble.tex`: with
    /// `\MaughamCrossLink` defined as `\hyperlink`, every slugline in every body
    /// becomes a real PDF `Link` annotation pointing at the same scene in each
    /// other body. Two bodies × two sluglines × one other body each = 4.
    func test_everySluglineBecomesALinkAnnotationToEachOtherBody() async throws {
        let cfg = anchoredConfig()
        let plan = try anchoredTwoBodyPlan(cfg)
        let compiler = try PDFCompiler(
            projectURL: tmp, bodies: plan.bodies, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported errors: \(result.errors.map(\.message))\n\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\n\(result.logExcerpt)")
        // No undefined control sequence: the starter's preamble really does
        // define what the body invokes.
        XCTAssertFalse(result.logExcerpt.contains("Undefined control sequence"),
                       result.logExcerpt)

        let expected = plan.bodies.count
            * AnchoredScreenplay.sluglinesPerBody
            * (plan.bodies.count - 1)
        XCTAssertEqual(linkAnnotationCount(at: URL(fileURLWithPath: result.outputPath)),
                       expected,
                       "each of \(plan.bodies.count) bodies must contribute "
                       + "\(AnchoredScreenplay.sluglinesPerBody) linked sluglines "
                       + "× \(plan.bodies.count - 1) other bodies")
    }

    /// The control for the census above, and the disable experiment for the
    /// cross-link emission itself: the SAME fixture and the SAME starter
    /// preamble compiled as ONE body carries zero `Link` annotations. (The
    /// piece is out of the ToC precisely so this baseline is zero — a ToC entry
    /// is a link too.) Deleting the `crossLinkTags` argument at
    /// `PDFCompiler.swift`'s `LaTeXBodyEmitter.emit(ast, config: body.config,
    /// anchorTag: tag, crossLinkTags: others)` makes the two-body test above
    /// read zero as well, which is what this control distinguishes it from.
    func test_aSingleBodyCarriesNoLinkAnnotationsAtAll() async throws {
        let cfg = anchoredConfig()
        let compiler = try PDFCompiler(
            projectURL: tmp, astSource: AnchoredScreenplay(tag: nil), config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported errors: \(result.errors.map(\.message))\n\n\(result.logExcerpt)")
        XCTAssertEqual(linkAnnotationCount(at: URL(fileURLWithPath: result.outputPath)), 0,
                       "a single-language compile has no other body to link to")
    }

    // MARK: - P3 Task 2: a preamble that never heard of hyperref

    /// The prologue's whole reason to exist. `PublishStarter.installIfMissing`
    /// never updates an existing project's files, so a book initialised before
    /// P3 has a `preamble.tex` with no `\MaughamCrossLink` — and, if its author
    /// dropped hyperref, no `\hypertarget` either. This writes exactly such a
    /// preamble: minimal, no hyperref, no `soul`, no `MaughamBody`. The body's
    /// own three `\providecommand` lines are all that stand between it and an
    /// undefined control sequence.
    func test_aPreambleWithoutHyperrefStillCompiles() async throws {
        try """
            % A deliberately minimal preamble: no hyperref, no soul, and no
            % \\MaughamCrossLink — a project that predates every one of them.
            \\providecommand{\\Title}{Untitled}
            \\providecommand{\\Subtitle}{}
            \\providecommand{\\Author}{}
            \\providecommand{\\Copyright}{}
            \\providecommand{\\Keywords}{}
            \\providecommand{\\MaughamVersion}{0.1}
            \\providecommand{\\MaughamLabel}{}
            \\providecommand{\\MaughamLanguage}{en}
            \\usepackage[utf8]{inputenc}
            \\usepackage{geometry}
            \\geometry{margin=1in}
            \\newcommand{\\wikilink}[2]{\\textbf{#2}}
            """.write(to: publish.appendingPathComponent("preamble.tex"),
                      atomically: true, encoding: .utf8)

        let cfg = anchoredConfig()
        let compiler = try PDFCompiler(
            projectURL: tmp, bodies: try anchoredTwoBodyPlan(cfg).bodies, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)

        XCTAssertTrue(result.errors.isEmpty,
                      "a pre-P3 project failed to compile — the emitted providecommands "
                      + "are what stand in for the preamble it will never receive: "
                      + "\(result.errors.map(\.message))\n\n\(result.logExcerpt)")
        XCTAssertFalse(result.outputPath.isEmpty,
                       "empty outputPath means tectonic exit code != 0.\n\n\(result.logExcerpt)")
        // It degraded rather than linked: no hyperref, so no annotations — and
        // the sluglines still set.
        let url = URL(fileURLWithPath: result.outputPath)
        XCTAssertEqual(linkAnnotationCount(at: url), 0,
                       "without hyperref the cross-link must degrade to its content")
        let plain = pdfPlainText(at: url)
        XCTAssertTrue(plain.contains("INT. ROOM - DAY"), plain)
        XCTAssertTrue(plain.contains("INT. SOBA - DAN"), plain)
    }

    /// **A project that predates cross-links, but does load hyperref, LINKS.**
    ///
    /// This is the case the flat `{#2}` fallback got wrong, and it is the
    /// COMMON one: `PublishStarter.installIfMissing` returns early for an
    /// initialised project, so every book begun before this milestone keeps its
    /// old `preamble.tex` forever — hyperref and all — and never receives the
    /// starter's `\MaughamCrossLink` definition. Under the flat fallback those
    /// projects emitted a cross-link for every slugline and rendered every one
    /// of them dead, with nothing red anywhere to say so.
    ///
    /// The fixture is exactly that project: the starter's own preamble with the
    /// `\MaughamCrossLink` line deleted and nothing else touched.
    ///
    /// Disable experiment: restore `LaTeXBodyEmitter`'s fallback to
    /// `"\\providecommand{\\MaughamCrossLink}[2]{#2}"` and this fails with
    /// `XCTAssertEqual failed: ("0") is not equal to ("4") - a preamble that
    /// loads hyperref must link…`. The control is
    /// `test_aPreambleWithoutHyperrefStillCompiles` directly above, which reads
    /// 0 on the same fixture BECAUSE hyperref is absent — the two together are
    /// what say the `\ifdefined` test is doing the work rather than the links
    /// being unconditional.
    func test_aPreambleThatLoadsHyperrefLinksWithNoCrossLinkDefinitionOfItsOwn() async throws {
        let preambleURL = publish.appendingPathComponent("preamble.tex")
        let starter = try String(contentsOf: preambleURL, encoding: .utf8)
        let definition = "\\providecommand{\\MaughamCrossLink}[2]{\\hyperlink{#1}{#2}}"
        XCTAssertTrue(starter.contains(definition),
                      "premise: the starter defines the command this fixture strips")
        let stripped = starter.components(separatedBy: "\n")
            .filter { !$0.contains("\\providecommand{\\MaughamCrossLink}") }
            .joined(separator: "\n")
        XCTAssertFalse(stripped.contains("\\MaughamCrossLink}[2]{\\hyperlink"),
                       "premise: the definition is really gone")
        XCTAssertTrue(stripped.contains("hyperref"),
                      "premise: hyperref is still loaded \u{2014} that is the "
                      + "whole difference from the test above")
        try stripped.write(to: preambleURL, atomically: true, encoding: .utf8)

        let cfg = anchoredConfig()
        let plan = try anchoredTwoBodyPlan(cfg)
        let compiler = try PDFCompiler(
            projectURL: tmp, bodies: plan.bodies, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty,
                      "tectonic reported errors: \(result.errors.map(\.message))\n\n\(result.logExcerpt)")
        XCTAssertFalse(result.logExcerpt.contains("Undefined control sequence"),
                       result.logExcerpt)

        let expected = plan.bodies.count
            * AnchoredScreenplay.sluglinesPerBody
            * (plan.bodies.count - 1)
        XCTAssertEqual(linkAnnotationCount(at: URL(fileURLWithPath: result.outputPath)),
                       expected,
                       "a preamble that loads hyperref must link even with no "
                       + "\\MaughamCrossLink definition of its own \u{2014} this "
                       + "is every project that existed before the command did")
    }

    /// The starter really does ship the definition the test above strips —
    /// pinned so the two cannot drift apart silently.
    func test_theStarterPreambleDefinesTheCrossLinkAsAHyperlink() throws {
        let preamble = try String(
            contentsOf: publish.appendingPathComponent("preamble.tex"), encoding: .utf8)
        XCTAssertTrue(
            preamble.contains("\\providecommand{\\MaughamCrossLink}[2]{\\hyperlink{#1}{#2}}"),
            "the starter preamble must define \\MaughamCrossLink, and with "
            + "\\providecommand so a template of the project's own still wins:\n\(preamble)")
    }
}
