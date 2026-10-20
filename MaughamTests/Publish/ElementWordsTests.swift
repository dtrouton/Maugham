import XCTest
import MaughamCore
@testable import Maugham

/// R-S16: the element words — "Figure", "Table", "Section", "References",
/// "List of Figures", "List of Tables" — follow each body's language: the
/// built-in table (en, es, sr Latin, fr, de, it, pt), the publish config's
/// override (`metadata.element_words`, folded per language through
/// `language_overrides`), English for any other language. One resolution per
/// body carries one set of words, and every surface reads them from it.
final class ElementWordsTests: XCTestCase {

    // MARK: - the table

    func test_theTableCoversItsSevenLanguages_andEnglishIsTheDefault() {
        XCTAssertEqual(ElementWords.builtIn(language: "en"), .english)
        XCTAssertEqual(ElementWords.english.figure, "Figure")
        XCTAssertEqual(ElementWords.english.listOfTables, "List of Tables")
        let sr = ElementWords.builtIn(language: "sr")
        XCTAssertEqual([sr.figure, sr.table, sr.section, sr.references, sr.listOfFigures, sr.listOfTables],
                       ["Slika", "Tabela", "Odeljak", "Literatura", "Spisak slika", "Spisak tabela"])
        XCTAssertEqual(ElementWords.builtIn(language: "es").figure, "Figura")
        XCTAssertEqual(ElementWords.builtIn(language: "fr").table, "Tableau")
        XCTAssertEqual(ElementWords.builtIn(language: "de").figure, "Abbildung")
        XCTAssertEqual(ElementWords.builtIn(language: "it").table, "Tabella")
        XCTAssertEqual(ElementWords.builtIn(language: "pt").table, "Tabela")
        for tag in ["en", "es", "sr", "fr", "de", "it", "pt"] {
            XCTAssertNotNil(ElementWords.table[tag], "\(tag) is in the table")
        }
    }

    func test_anUnknownLanguage_readsEnglish() {
        XCTAssertEqual(ElementWords.builtIn(language: "xx"), .english)
        XCTAssertEqual(ElementWords.builtIn(language: "ja"), .english)
        XCTAssertEqual(ElementWords.builtIn(language: ""), .english)
    }

    func test_aRegionalTag_readsItsLanguage_butAnotherScriptReadsEnglish() {
        XCTAssertEqual(ElementWords.builtIn(language: "sr-Latn"), ElementWords.builtIn(language: "sr"))
        XCTAssertEqual(ElementWords.builtIn(language: "pt-BR").table, "Tabela")
        XCTAssertEqual(ElementWords.builtIn(language: "DE"), ElementWords.builtIn(language: "de"))
        XCTAssertEqual(ElementWords.builtIn(language: "sr-Cyrl"), .english,
                       "the table is Latin script: a Cyrillic body must not print Latin words")
    }

    // MARK: - the config override

    func test_theConfigOverride_winsOverTheTable_keyByKey() {
        var metadata = PublishConfig.Metadata(language: "sr")
        metadata.elementWords = .init(figure: "Grafikon", references: "Izvori")
        let words = ElementWords.forBody(metadata)
        XCTAssertEqual(words.figure, "Grafikon")
        XCTAssertEqual(words.references, "Izvori")
        XCTAssertEqual(words.table, "Tabela", "a word the override leaves out comes from the table")
    }

    func test_aBlankOverride_isNoOverride() {
        var metadata = PublishConfig.Metadata(language: "en")
        metadata.elementWords = .init(figure: "  ")
        XCTAssertEqual(ElementWords.forBody(metadata).figure, "Figure")
    }

    func test_theOverrideDecodesFromSnakeCase_andAnOldConfigStillDecodes() throws {
        let json = """
        {"title":"T","author":"A","language":"en","keywords":[],
         "element_words":{"figure":"Fig.","list_of_figures":"Figures","list_of_tables":null}}
        """
        let m = try JSONDecoder().decode(PublishConfig.Metadata.self, from: Data(json.utf8))
        XCTAssertEqual(m.elementWords?.figure, "Fig.")
        XCTAssertEqual(m.elementWords?.listOfFigures, "Figures")
        XCTAssertNil(m.elementWords?.listOfTables)
        let old = try JSONDecoder().decode(PublishConfig.Metadata.self, from: Data(
            #"{"title":"T","author":"A","language":"en","keywords":[]}"#.utf8))
        XCTAssertNil(old.elementWords)
    }

    func test_theOverrideEncodesItsShape_withExplicitNulls() throws {
        var m = PublishConfig.Metadata()
        let none = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        XCTAssertTrue(none.contains(#""element_words":null"#), none)
        m.elementWords = .init(table: "Tab.")
        let some = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        for key in ["figure", "section", "references", "list_of_figures", "list_of_tables"] {
            XCTAssertTrue(some.contains(#""\#(key)":null"#), "\(key) in \(some)")
        }
        XCTAssertTrue(some.contains(#""table":"Tab.""#), some)
        XCTAssertEqual(try JSONDecoder().decode(PublishConfig.Metadata.self,
                                                from: try JSONEncoder().encode(m)), m)
    }

    /// The per-language fold is the existing one: `language_overrides.<tag>
    /// .metadata` carries the same snake_case keys, flat, as it carries
    /// `title`; the book's own block is in the book's language and does not
    /// reach a translated body.
    func test_thePerLanguageFold_carriesTheWords() {
        var config = PublishConfig(metadata: .init(language: "en"))
        config.metadata.elementWords = .init(figure: "Fig.")
        config.languageOverrides["sr"] = .init(metadata: ["table": "Tab.", "list_of_tables": "Tabele"])
        let sr = config.effectiveMetadata(language: "sr")
        XCTAssertNil(sr.elementWords?.figure, "the English block stays with the English body")
        XCTAssertEqual(sr.elementWords?.table, "Tab.")
        XCTAssertEqual(sr.elementWords?.listOfTables, "Tabele")
        XCTAssertEqual(ElementWords.forBody(sr).figure, "Slika")
        XCTAssertEqual(ElementWords.forBody(sr).table, "Tab.")
        XCTAssertEqual(ElementWords.forBody(config.effectiveMetadata(language: nil)).figure, "Fig.")
        XCTAssertEqual(ElementWords.forBody(config.effectiveMetadata(language: "en")).figure, "Fig.",
                       "a body in the book's own language keeps the book's block")
    }

    // MARK: - one resolution, one set of words

    private struct Book: ProjectASTBuilder.Source {
        var context: PublishContext
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            let paragraphs = [("a1b2", "# Intro {#sec:intro}"),
                              ("c3d4", "![Chart](x.png){#fig:one}"),
                              ("e5f6", "| a |\n|---|\n| 1 |\nTable: Sales {#tbl:sales}"),
                              ("g7h8", "See @fig:one, @tbl:sales and @sec:intro.")]
            return [.init(pieceID: "p", title: "P", mode: .prose,
                          displayText: paragraphs.map(\.1).joined(separator: "\n\n"),
                          paragraphs: paragraphs.map { (id: $0.0, text: $0.1) })]
        }
        func publishContext() -> PublishContext { context }
    }

    private static let context = PublishContext(
        library: CitationLibrary(items: []), profile: .report,
        switches: (numberSections: true, listOfFigures: true, listOfTables: true),
        projectURL: nil, piecePaths: [:])

    private func label(_ s: String) -> ManuscriptLabel { ManuscriptLabel(reference: s)! }

    func test_theResolutionText_isTheBodysWords() throws {
        let sr = ElementWords.builtIn(language: "sr")
        let r = try PublishResolution.forCompile(source: Book(context: Self.context), bodyTag: nil,
                                                 imageAllowed: ["png"], words: sr)
        XCTAssertEqual(r.words, sr)
        XCTAssertEqual(r.targets[label("fig:one")]?.text, "Slika 1")
        XCTAssertEqual(r.targets[label("tbl:sales")]?.text, "Tabela 1")
        XCTAssertEqual(r.targets[label("sec:intro")]?.text, "Odeljak 1")
        XCTAssertEqual(r.listOfFigures.first?.target.text, "Slika 1")
        let en = try PublishResolution.forCompile(source: Book(context: Self.context), bodyTag: nil,
                                                  imageAllowed: ["png"])
        XCTAssertEqual(en.targets[label("fig:one")]?.text, "Figure 1", "English by default")
    }

    /// The gate's resolve is the one place a body's words are chosen: from its
    /// own folded config.
    func test_theGateResolvesEachBodyWithItsOwnConfigsWords() throws {
        var config = PublishConfig(metadata: .init(language: "en"))
        config.languageOverrides["sr"] = .init(metadata: ["figure": "Grafikon"])
        let source = Book(context: Self.context)
        let bodies = [
            BodyPlan.Body(tag: nil, displayTag: "en", source: source,
                          config: config),
            BodyPlan.Body(tag: "sr", displayTag: "sr", source: source,
                          config: { var c = config; c.metadata = config.effectiveMetadata(language: "sr"); return c }()),
        ]
        let resolved = try PublishProblemGate.resolve(bodies: bodies, imageAllowed: ["png"])
        XCTAssertEqual(resolved[0].resolution.targets[label("fig:one")]?.text, "Figure 1")
        XCTAssertEqual(resolved[1].resolution.targets[label("fig:one")]?.text, "Grafikon 1")
        XCTAssertEqual(resolved[1].resolution.targets[label("tbl:sales")]?.text, "Tabela 1")
    }

    // MARK: - the PDF body

    private func resolution(_ words: ElementWords) throws -> (ProjectAST, PublishResolution) {
        let book = Book(context: Self.context)
        let ast = try ProjectASTBuilder.build(from: book)
        return (ast, try PublishResolution.forCompile(source: book, built: ast, bodyTag: nil,
                                                      imageAllowed: ["png"], words: words))
    }

    func test_aPDFBodyWithElements_setsTheCaptionNamesFromItsWords() throws {
        let (ast, r) = try resolution(ElementWords.builtIn(language: "sr"))
        let tex = LaTeXBodyEmitter.emit(ast, resolution: r, figureFiles: ["p": [1: "build/figures/a.png"]])
        for line in ["\\providecommand{\\figurename}{}\\renewcommand{\\figurename}{Slika}",
                     "\\providecommand{\\tablename}{}\\renewcommand{\\tablename}{Tabela}",
                     "\\providecommand{\\listfigurename}{}\\renewcommand{\\listfigurename}{Spisak slika}",
                     "\\providecommand{\\listtablename}{}\\renewcommand{\\listtablename}{Spisak tabela}"] {
            XCTAssertTrue(tex.contains(line), "missing \(line) in:\n\(tex)")
        }
        // Set before the lists that print them.
        let names = try XCTUnwrap(tex.range(of: "\\renewcommand{\\listfigurename}"))
        let list = try XCTUnwrap(tex.range(of: "\\listoffigures"))
        XCTAssertLessThan(names.lowerBound, list.lowerBound)
        XCTAssertTrue(tex.contains("\\MaughamCrossLink{lbl-fig-one}{Slika 1}"), tex)
        XCTAssertTrue(tex.contains("\\hypertarget{lbl-fig-one}{}"),
                      "the figure still owns its label under the words: \(tex)")
        XCTAssertTrue(tex.contains("\\hypertarget{lbl-tbl-sales}{}"), tex)
    }

    /// English too: a template's babel may have renamed the captions, and the
    /// cross-reference says "Figure".
    func test_anEnglishBodyWithElements_setsTheCaptionNamesAnyway() throws {
        let (ast, r) = try resolution(.english)
        let tex = LaTeXBodyEmitter.emit(ast, resolution: r)
        XCTAssertTrue(tex.contains("\\renewcommand{\\figurename}{Figure}"), tex)
        XCTAssertTrue(tex.contains("\\renewcommand{\\listtablename}{List of Tables}"), tex)
    }

    func test_aBodyWithoutElements_setsNoCaptionNames() throws {
        let book = PlainBook()
        let ast = try ProjectASTBuilder.build(from: book)
        let r = try PublishResolution.forCompile(source: book, built: ast, bodyTag: nil,
                                                 imageAllowed: ["png"],
                                                 words: ElementWords.builtIn(language: "sr"))
        let tex = LaTeXBodyEmitter.emit(ast, resolution: r)
        XCTAssertFalse(tex.contains("figurename") || tex.contains("tablename"), tex)
    }

    private struct PlainBook: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p", title: "P", mode: .prose, displayText: "# Intro\n\nPlain prose.",
                   paragraphs: [(id: "a1b2", text: "# Intro"), (id: "c3d4", text: "Plain prose.")])]
        }
        func publishContext() -> PublishContext { ElementWordsTests.context }
    }

    func test_theWordsAreEscaped_inBothTargets() throws {
        var words = ElementWords.english
        words.figure = "Fig. & <co>"
        words.references = "Works_cited & co"
        let (ast, r) = try resolution(words)
        let tex = LaTeXBodyEmitter.emit(ast, resolution: r)
        XCTAssertTrue(tex.contains("\\renewcommand{\\figurename}{Fig. \\& <co>}"), tex)
        let html = XHTMLBodyEmitter.emit(ast, resolution: r, figureFiles: ["p": [1: "images/a.png"]])
        XCTAssertTrue(html.contains("Fig. &amp; &lt;co&gt; 1."), html)
        XCTAssertFalse(html.contains("<co>"), html)
        XCTAssertTrue(XHTMLBodyEmitter.references([[.init(text: "x", italic: false)]], heading: words.references)
            .contains("<h1>Works_cited &amp; co</h1>"))
    }

    func test_thePDFReferencesHeading_isTheBodysWord() throws {
        struct Cited: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p", title: "P", mode: .prose, displayText: "As shown [@smith2026].",
                       paragraphs: [(id: "a1b2", text: "As shown [@smith2026].")])]
            }
            func publishContext() -> PublishContext {
                var c = ElementWordsTests.context
                c.library = CitationLibrary(items: [ResearchItem(
                    id: "r", title: "Annual", type: .asset,
                    citation: CitationInfo(key: "smith2026", authors: ["Smith, Jane"], year: 2026))])
                return c
            }
        }
        var words = ElementWords.builtIn(language: "sr")
        words.references = "Izvori_ & co"
        let ast = try ProjectASTBuilder.build(from: Cited())
        let r = try PublishResolution.forCompile(source: Cited(), built: ast, bodyTag: nil,
                                                 imageAllowed: [], words: words)
        let tex = LaTeXBodyEmitter.emit(ast, resolution: r)
        XCTAssertTrue(tex.contains("\\section*{Izvori\\_ \\& co}"), tex)
        XCTAssertTrue(tex.contains("\\addcontentsline{toc}{section}{Izvori\\_ \\& co}"), tex)
        XCTAssertFalse(tex.contains("References"), tex)
        XCTAssertFalse(tex.contains("figurename"), "no figure, no table, no list: no caption names")
    }

    // MARK: - the EPUB body

    func test_anEPUBBody_captionsAndCrossReferencesInItsWords() throws {
        let (ast, r) = try resolution(ElementWords.builtIn(language: "sr"))
        let html = XHTMLBodyEmitter.emit(ast, resolution: r, figureFiles: ["p": [1: "images/a.png"]],
                                         labelHrefs: [label("fig:one"): "s.xhtml#lbl-fig-one"])
        XCTAssertTrue(html.contains("<figcaption><span class=\"caption-number\">Slika 1.</span> Chart</figcaption>"),
                      html)
        XCTAssertTrue(html.contains("<span class=\"caption-number\">Tabela 1.</span>"), html)
        XCTAssertTrue(html.contains(">Slika 1</a>"), html)
        XCTAssertTrue(html.contains("id=\"lbl-fig-one\""), "the label id still lands: \(html)")
        XCTAssertEqual(XHTMLBodyEmitter.listTitle(.fig, number: 1, caption: [.text("Chart")],
                                                  resolution: r, pieceID: "p"), "Slika 1. Chart")
    }
}
