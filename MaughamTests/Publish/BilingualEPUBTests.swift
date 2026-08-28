import XCTest
import MaughamCore
@testable import Maugham

/// P2 Task 4: the EPUB is a SEQUENCE of bodies, each in its own language.
///
/// The compiler stops building sections from one AST and builds them from one
/// AST PER BODY, in order. For a single body nothing about the archive moves —
/// same `section-%03d.xhtml` filenames, same `s<i>` ids, byte-identical
/// `content.opf` and `nav.xhtml`. For two or more the filenames and ids carry
/// the body's tag, `<dc:language>` is emitted once per body in order, the nav
/// grows a heading per body, and every section document declares its own
/// language on `<html>`.
///
/// **The single-body byte-identity claim has one declared exception**, pinned
/// by `test_theSingleBodySectionDocumentsGainTheLanguageAttributes`: the
/// SECTION documents gain `xml:lang`/`lang` on `<html>` even for one body,
/// because a section that does not say what language it is in is exactly the
/// defect this task exists to fix. `content.opf`, `nav.xhtml` and the section
/// FILENAMES are byte-identical; the section documents' `<html>` open tag is
/// not, and that is deliberate.
@MainActor
final class BilingualEPUBTests: XCTestCase {

    var tmp: URL!
    var publish: URL!
    var build: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BilingualEPUB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
        publish = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        build = publish.appendingPathComponent("build", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixtures

    /// Two pieces, language-ignorant: a single-body compile must keep working
    /// with a source that has never heard of languages (BodyPlan constraint 2).
    private struct TwoPieces: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "Opening", mode: .prose,
                   displayText: "The opening paragraph."),
             .init(pieceID: "p2", title: "Closing", mode: .prose,
                   displayText: "The closing paragraph.")]
        }
    }

    /// A source that answers with different text per language — the seam this
    /// task owns is that each body reads its OWN source.
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

    /// The fixture the byte-identity literals below were captured from. An
    /// ISBN is set so `dc:identifier` is deterministic; the compile timestamp
    /// is the only volatile field left, and `normalized` folds it.
    private func baseConfig() -> PublishConfig {
        var cfg = PublishConfig(metadata: .init(title: "Bilingual Fixture", author: "Tester"))
        cfg.metadata.language = "en"
        cfg.metadata.isbn = "978-0-000-00000-0"
        cfg.nextVersion = "0.1"
        cfg.languageOverrides = ["sr": .init(metadata: ["title": "Prevedeni Naslov"])]
        return cfg
    }

    private func twoBodyPlan(_ cfg: PublishConfig, sourceTag: String = "en") throws -> BodyPlan {
        let set = try LanguageSet(language: nil, languages: ["source", "sr"], sourceTag: sourceTag)
        return try BodyPlan.make(
            set: set, resolved: cfg, source: PerLanguagePiece(tag: nil),
            publishDir: publish, wrap: { $0 })
    }

    private func compileSingleBody(_ cfg: PublishConfig,
                                   source: ProjectASTBuilder.Source = TwoPieces())
    async throws -> URL {
        let compiler = try EPUBCompiler(
            projectURL: tmp, astSource: source, config: cfg,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors.map(\.message))")
        XCTAssertFalse(result.outputPath.isEmpty, "the compile produced no file")
        return URL(fileURLWithPath: result.outputPath)
    }

    private func compileTwoBodies(_ cfg: PublishConfig, sourceTag: String = "en")
    async throws -> URL {
        let compiler = try EPUBCompiler(
            projectURL: tmp, bodies: try twoBodyPlan(cfg, sourceTag: sourceTag).bodies,
            config: cfg, jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors.map(\.message))")
        XCTAssertFalse(result.outputPath.isEmpty, "the compile produced no file")
        return URL(fileURLWithPath: result.outputPath)
    }

    /// Folds the one field that cannot be pinned: the compile's own timestamp,
    /// which appears as `dcterms:modified` and `maugham:compiled_at`.
    private func normalized(_ xml: String) -> String {
        let pattern = try! NSRegularExpression(
            pattern: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#)
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return pattern.stringByReplacingMatches(
            in: xml, range: range, withTemplate: "FIXED-STAMP")
    }

    private func sectionNames(_ names: [String]) -> [String] {
        names.filter { $0.hasPrefix("OEBPS/section-") }.sorted()
    }

    // MARK: - one body: content.opf is byte-identical

    /// Captured at `f1b646b5` — BEFORE this task — by running that commit's own
    /// `EPUBOPFWriter.opfXML` over the package its `EPUBCompiler` builds for
    /// this fixture (`swiftc EPUBOPFWriter.swift EPUBPackage.swift
    /// XHTMLEscape.swift`, 2026-08-28). Pinned as a literal rather than against
    /// a re-render of the same writer, so a change to the document's shape
    /// fails here instead of agreeing with itself.
    func test_theSingleBodyPackageDocumentIsByteIdenticalToTheOneBeforeTheBodies() async throws {
        let epub = try await compileSingleBody(baseConfig())
        let opf = try epubEntryText("OEBPS/content.opf", inEPUBAt: epub)
        XCTAssertEqual(normalized(opf), """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" prefix="maugham: https://maugham.app/ns/">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="book-id">urn:isbn:978-0-000-00000-0</dc:identifier>
                <dc:title>Bilingual Fixture</dc:title>
                <dc:creator>Tester</dc:creator>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">FIXED-STAMP</meta>
                <meta property="maugham:version">0.1</meta>
                <meta property="maugham:checkpoint_id"></meta>
                <meta property="maugham:compiled_at">FIXED-STAMP</meta>
              </metadata>
              <manifest>
                <item id="styles" href="styles.css" media-type="text/css"/>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="s1" href="section-001.xhtml" media-type="application/xhtml+xml"/>
                <item id="s2" href="section-002.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="nav"/>
                <itemref idref="s1"/>
                <itemref idref="s2"/>
              </spine>
            </package>
            """,
            "a one-body EPUB's content.opf must be byte-identical to the one "
            + "compiled before bodies existed")
    }

    // MARK: - one body: nav.xhtml is byte-identical

    /// Same capture, same commit. One body gets ONE flat `<ol>` and no `<h2>`.
    func test_theSingleBodyNavigationDocumentIsByteIdenticalToTheOneBeforeTheBodies() async throws {
        let epub = try await compileSingleBody(baseConfig())
        let nav = try epubEntryText("OEBPS/nav.xhtml", inEPUBAt: epub)
        XCTAssertEqual(nav, """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><meta charset="utf-8"/><title>Bilingual Fixture</title></head>
            <body>
            <nav epub:type="toc" id="toc">
              <h1>Contents</h1>
              <ol>
                <li><a href="section-001.xhtml">Opening</a></li>
                <li><a href="section-002.xhtml">Closing</a></li>
              </ol>
            </nav>
            </body></html>
            """,
            "a one-body EPUB's nav.xhtml must be byte-identical, and must carry "
            + "no per-body heading")
    }

    // MARK: - one body: the section filenames do not move

    func test_theSingleBodySectionFilenamesAreUnchanged() async throws {
        let epub = try await compileSingleBody(baseConfig())
        let names = try epubEntryNames(inEPUBAt: epub)
        XCTAssertEqual(sectionNames(names),
                       ["OEBPS/section-001.xhtml", "OEBPS/section-002.xhtml"],
                       "the archive held: \(names.sorted())")
    }

    // MARK: - one body: the declared byte change

    /// The ONE thing that is not byte-identical for a single body, and it is
    /// deliberate: a section document now says what language it is written in.
    /// Everything else about the document is the text captured at `f1b646b5`.
    func test_theSingleBodySectionDocumentsGainTheLanguageAttributes() async throws {
        let epub = try await compileSingleBody(baseConfig())
        let section = try epubEntryText("OEBPS/section-001.xhtml", inEPUBAt: epub)
        XCTAssertTrue(section.contains(
            #"<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">"#),
            "the section's <html> must declare its language. It was:\n\(section)")
        // The rest of the document is unmoved: same head, same wrapper.
        XCTAssertTrue(section.hasPrefix("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html
            """), section)
        XCTAssertTrue(section.contains("""
            <head>
              <meta charset="utf-8"/>
              <title>Opening</title>
              <link rel="stylesheet" type="text/css" href="styles.css"/>
            </head>
            <body>
            """), section)
    }

    // MARK: - two bodies: one section file per language

    func test_twoBodiesShipOneSectionFilePerLanguage() async throws {
        let epub = try await compileTwoBodies(baseConfig())
        let names = try epubEntryNames(inEPUBAt: epub)
        XCTAssertEqual(sectionNames(names),
                       ["OEBPS/section-en-001.xhtml", "OEBPS/section-sr-001.xhtml"],
                       "the archive held: \(names.sorted())")
    }

    // MARK: - two bodies: each reads its own source

    func test_theTranslatedSectionCarriesTheTranslatedText() async throws {
        let epub = try await compileTwoBodies(baseConfig())
        let en = try epubEntryText("OEBPS/section-en-001.xhtml", inEPUBAt: epub)
        let sr = try epubEntryText("OEBPS/section-sr-001.xhtml", inEPUBAt: epub)
        XCTAssertTrue(en.contains(PerLanguagePiece.sourceSentence), en)
        XCTAssertTrue(sr.contains(PerLanguagePiece.translatedSentence),
                      "the sr section must carry the TRANSLATED text: \(sr)")
        XCTAssertFalse(sr.contains(PerLanguagePiece.sourceSentence),
                       "the sr section carries the source text — the bodies share a source")
    }

    // MARK: - two bodies: both languages declared, in order

    func test_bothLanguagesAreDeclaredInTheOrderTheBodiesRender() async throws {
        let epub = try await compileTwoBodies(baseConfig())
        let opf = try epubEntryText("OEBPS/content.opf", inEPUBAt: epub)
        let declared = opf.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("<dc:language>") }
        XCTAssertEqual(declared,
                       ["<dc:language>en</dc:language>", "<dc:language>sr</dc:language>"],
                       "one <dc:language> per body, in order, the first primary. "
                       + "content.opf was:\n\(opf)")
    }

    // MARK: - two bodies: each section declares its own language

    func test_eachSectionDeclaresItsOwnLanguage() async throws {
        let epub = try await compileTwoBodies(baseConfig())
        let en = try epubEntryText("OEBPS/section-en-001.xhtml", inEPUBAt: epub)
        let sr = try epubEntryText("OEBPS/section-sr-001.xhtml", inEPUBAt: epub)
        XCTAssertTrue(en.contains(#"xml:lang="en" lang="en""#), en)
        XCTAssertTrue(sr.contains(#"xml:lang="sr" lang="sr""#),
                      "the translated half must not inherit the source's language: \(sr)")
    }

    // MARK: - two bodies: the nav grows a heading per body

    func test_theNavigationDocumentHeadsEachBodyWithItsLanguage() async throws {
        let epub = try await compileTwoBodies(baseConfig())
        let nav = try epubEntryText("OEBPS/nav.xhtml", inEPUBAt: epub)
        guard let en = nav.range(of: "<h2>en</h2>"),
              let sr = nav.range(of: "<h2>sr</h2>") else {
            return XCTFail("nav.xhtml is missing a per-body heading:\n\(nav)")
        }
        XCTAssertTrue(en.lowerBound < sr.lowerBound,
                      "the headings must follow the bodies' order:\n\(nav)")
        // Each heading owns the list beneath it.
        XCTAssertTrue(nav.contains("""
              <h2>en</h2>
              <ol>
                <li><a href="section-en-001.xhtml">Opening</a></li>
              </ol>
              <h2>sr</h2>
              <ol>
                <li><a href="section-sr-001.xhtml">Opening</a></li>
              </ol>
            """), nav)
    }

    // MARK: - two bodies: the spine reads in order

    func test_theSpineListsEveryBodysSectionsInOrder() async throws {
        let epub = try await compileTwoBodies(baseConfig())
        let opf = try epubEntryText("OEBPS/content.opf", inEPUBAt: epub)
        let spine = opf.components(separatedBy: "<spine>")[1]
        let refs = spine.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("<itemref") }
        XCTAssertEqual(refs, [
            #"<itemref idref="nav"/>"#,
            #"<itemref idref="s-en-1"/>"#,
            #"<itemref idref="s-sr-1"/>"#,
        ], "the spine must read the bodies in the plan's order. content.opf:\n\(opf)")
    }

    // MARK: - two bodies: the piece appears once per body

    func test_thePieceAppearsOncePerBody() async throws {
        let epub = try await compileTwoBodies(baseConfig())
        XCTAssertEqual(try pieceIDs(inEPUBAt: epub), ["p1"],
                       "both bodies render the same piece")
        XCTAssertEqual(try pieceIDOccurrences(inEPUBAt: epub).count, 2,
                       "one occurrence per body × piece — the translated half is "
                       + "a second rendering of the same piece, not a different one")
    }

    // MARK: - a tag that cannot be a filename

    /// The source body's `displayTag` is `config.metadata.language`, free-form
    /// config text; every other tag is validated by `LanguageSet`. A tag that
    /// cannot be an archive entry name falls back to the body's ordinal —
    /// `PDFCompiler.fileTag(for:at:)`'s rule, the same allowlist. The tag the
    /// document DECLARES is still the writer's own spelling: only the filename
    /// is sanitised.
    func test_aTagThatCannotBeAFilenameFallsBackToItsOrdinal() async throws {
        var cfg = baseConfig()
        cfg.metadata.language = "en US"
        let epub = try await compileTwoBodies(cfg, sourceTag: "en US")
        let names = try epubEntryNames(inEPUBAt: epub)
        XCTAssertEqual(sectionNames(names),
                       ["OEBPS/section-1-001.xhtml", "OEBPS/section-sr-001.xhtml"],
                       "the archive held: \(names.sorted())")
        let first = try epubEntryText("OEBPS/section-1-001.xhtml", inEPUBAt: epub)
        XCTAssertTrue(first.contains(#"xml:lang="en US" lang="en US""#),
                      "only the filename is sanitised — the declaration keeps the "
                      + "writer's own spelling: \(first)")
    }

    // MARK: - the package cannot hold two answers about its primary language

    /// `languages` is DERIVED: its head is `metadata.language` by construction,
    /// so no caller can hand the package a primary `<dc:language>` that
    /// disagrees with the metadata the rest of the document was folded to.
    func test_thePackagesPrimaryLanguageIsAlwaysItsMetadatasOwn() {
        let pkg = EPUBPackage(
            metadata: .init(title: "X", author: "Y", language: "en"),
            sections: [], cover: nil,
            languages: ["sr", "de"])
        XCTAssertEqual(pkg.languages, ["en", "de"],
                       "the head must come from the metadata, not from the caller")
        XCTAssertEqual(pkg.languages.first, pkg.metadata.language)
    }

    func test_aPackageGivenNoLanguagesDeclaresItsMetadatasOwn() {
        let pkg = EPUBPackage(
            metadata: .init(title: "X", author: "Y", language: "fr"),
            sections: [], cover: nil)
        XCTAssertEqual(pkg.languages, ["fr"])
    }

    // MARK: - the bodies array must be able to make a document

    func test_anEmptyBodiesArrayIsRefused() {
        XCTAssertThrowsError(try EPUBCompiler(
            projectURL: tmp, bodies: [], config: baseConfig(),
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a")) { error in
            XCTAssertEqual(error as? EPUBCompiler.NoBodies, EPUBCompiler.NoBodies())
        }
    }

    // MARK: - P3 Task 3: anchors and cross-links in the shipped archive

    /// P3 Task 3. A screenplay that hands its op-log PARAGRAPHS as well as its
    /// display text, so `ProjectASTBuilder` can hang a `¶id` on each node — the
    /// premise every anchor below rests on. The ids are the SAME in both
    /// languages, which is what makes a cross-link resolvable
    /// (`p-en-aaaa` ↔ `p-sr-aaaa`). Mirrors `BilingualPDFTests.AnchoredScreenplay`.
    private struct AnchoredScreenplay: LanguageRebindableSource {
        let tag: String?
        static let source: [(id: String, text: String)] = [
            ("aaaa", "INT. ROOM - DAY"),
            ("bbbb", "He waits by the window."),
        ]
        static let translated: [(id: String, text: String)] = [
            ("aaaa", "INT. SOBA - DAN"),
            ("bbbb", "Ceka kraj prozora."),
        ]
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

    private func anchoredTwoBodyPlan(_ cfg: PublishConfig) throws -> BodyPlan {
        let set = try LanguageSet(language: nil, languages: ["source", "sr"], sourceTag: "en")
        return try BodyPlan.make(
            set: set, resolved: cfg, source: AnchoredScreenplay(tag: nil),
            publishDir: publish, wrap: { $0 })
    }

    private func compileAnchoredTwoBodies() async throws -> URL {
        let cfg = baseConfig()
        let compiler = try EPUBCompiler(
            projectURL: tmp, bodies: try anchoredTwoBodyPlan(cfg).bodies,
            config: cfg, jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors.map(\.message))")
        return URL(fileURLWithPath: result.outputPath)
    }

    /// The end-to-end claim: every paragraph in the shipped archive carries its
    /// own `¶id` under its OWN body's tag, and each body's slugline links into
    /// the other body's section file at the same paragraph.
    func test_eachBodysSectionAnchorsUnderItsOwnTagAndLinksToTheOther() async throws {
        let epub = try await compileAnchoredTwoBodies()
        let en = try epubEntryText("OEBPS/section-en-001.xhtml", inEPUBAt: epub)
        let sr = try epubEntryText("OEBPS/section-sr-001.xhtml", inEPUBAt: epub)

        XCTAssertTrue(en.contains(#"<p class="scene-heading" id="p-en-aaaa">"#
            + #"<a href="section-sr-001.xhtml#p-sr-aaaa">INT. ROOM - DAY</a></p>"#), en)
        XCTAssertTrue(en.contains(#"<p class="action" id="p-en-bbbb">He waits by the window.</p>"#), en)
        XCTAssertTrue(sr.contains(#"<p class="scene-heading" id="p-sr-aaaa">"#
            + #"<a href="section-en-001.xhtml#p-en-aaaa">INT. SOBA - DAN</a></p>"#), sr)
    }

    /// Neither body links to itself — a self-link is a link that goes nowhere,
    /// and is exactly what a compiler passing its own tag as an "other" would
    /// produce.
    func test_neitherBodyCrossLinksToItself() async throws {
        let epub = try await compileAnchoredTwoBodies()
        let en = try epubEntryText("OEBPS/section-en-001.xhtml", inEPUBAt: epub)
        let sr = try epubEntryText("OEBPS/section-sr-001.xhtml", inEPUBAt: epub)
        XCTAssertFalse(en.contains(#"href="section-en-"#), en)
        XCTAssertFalse(sr.contains(#"href="section-sr-"#), sr)
    }

    /// A link into a file the archive does not hold is a broken link. The href's
    /// filename is checked against the entries the compile actually shipped —
    /// which is what makes the shared `sectionFilename` rule load-bearing rather
    /// than decorative.
    func test_theCrossLinkNamesAFileTheArchiveActuallyHolds() async throws {
        let epub = try await compileAnchoredTwoBodies()
        let en = try epubEntryText("OEBPS/section-en-001.xhtml", inEPUBAt: epub)
        let pattern = try NSRegularExpression(pattern: ##"href="([^"#]+)#"##)
        let range = NSRange(en.startIndex..<en.endIndex, in: en)
        let targets = pattern.matches(in: en, range: range).compactMap {
            Range($0.range(at: 1), in: en).map { String(en[$0]) }
        }
        XCTAssertEqual(targets, ["section-sr-001.xhtml"], en)
        let names = try epubEntryNames(inEPUBAt: epub)
        for target in targets {
            XCTAssertTrue(names.contains("OEBPS/" + target),
                          "the slugline links to \(target), which the archive does not hold: \(names)")
        }
    }

    /// The single-body control: the section is still anchored — the ids are
    /// there for a template or a reader to address — and carries not one link,
    /// because there is no other body to link to.
    func test_aSingleBodySectionIsAnchoredAndCarriesNoLink() async throws {
        let epub = try await compileSingleBody(baseConfig(), source: AnchoredScreenplay(tag: nil))
        let section = try epubEntryText("OEBPS/section-001.xhtml", inEPUBAt: epub)
        XCTAssertTrue(section.contains(
            #"<p class="scene-heading" id="p-en-aaaa">INT. ROOM - DAY</p>"#), section)
        XCTAssertFalse(section.contains("<a "), section)
    }
}
