import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// Report plan 4 Task 4: the Word compile writes a native `.docx`. A fixture
/// Report with every element is compiled for real and read back through
/// `DOCXValidator` (the structural causes of Word's repair prompt) and
/// AppKit's own Word reader; then the parts, the `reference.docx` override,
/// figures Word can't embed (R-S3), a bilingual book, the gate, and the page
/// (R-S4).
@MainActor
final class DOCXCompilerTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = TestTemp.root.appendingPathComponent("DOCXCompiler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture images

    private static func png() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 192, pixelsHigh: 96, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<192 { for y in 0..<96 { rep.setColor(x < 96 ? .systemBlue : .systemOrange, atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// A one-page PDF whose media box is `media` and crop box `crop`.
    private static func pdf(media: CGRect, crop: CGRect) throws -> Data {
        let data = NSMutableData()
        var mediaBox = media
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        var cropBox = crop
        let cropData = Data(bytes: &cropBox, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextCropBox: cropData as CFData] as CFDictionary)
        context.setFillColor(NSColor.systemGreen.cgColor)
        context.fill(media)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="40"><rect width="120" height="40" fill="red"/></svg>
        """

    /// Says `<svg` (so it passes the opening sniff) but is cut short.
    private static let brokenSVG = #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="#

    // MARK: - fixture project

    private struct Fixture {
        let store: ProjectStore
        let url: URL
        var publish: URL { url.appendingPathComponent(".maugham/publish", isDirectory: true) }
    }

    private static let chapterOne = """
        # Introduction {#sec:intro}

        This report studies *revenue* and **cost** [@smith2026, p. 12].

        ![Revenue & cost[^cap]]({up}research/revenue-chart.png){#fig:rev}

        | Quarter | Sales |
        |:--|--:|
        | Q1[^cell] | 100 |
        | Q2 | 120 |
        Table: Sales by quarter {#tbl:sales}

        > A quoted finding.

        - First point
        - Second point

        1. Step one
        2. Step two

        ```
        let total = 220
        ```

        * * *

        A note here[^1].

        [^1]: The first note.

        [^cap]: A caption note.

        [^cell]: A cell note.
        """

    private static let chapterTwo = """
        ## Findings

        See @fig:rev, @tbl:sales and @sec:intro; a note[^1].

        ![The same chart again]({up}research/revenue-chart.png)

        ![A scanned chart]({up}research/scan.pdf){#fig:scan}

        ![A diagram]({up}research/diagram.svg)

        [^1]: The second chapter's note.
        """

    /// A two-chapter Report (numbered sections, a citation source) whose
    /// research folder holds a PNG, a PDF (300 × 300 media, 300 × 150 crop)
    /// and an SVG. `texts` replace the chapters' text.
    private func makeReport(_ texts: [String] = [chapterOne, chapterTwo],
                            svg: String = svg, report: Bool = true) async throws -> Fixture {
        let url = try await ProjectFactory.createNovelProject(
            named: "Word-\(UUID().uuidString.prefix(6))", in: tmp)
        let store = try await ProjectStore.load(from: url)
        if report { store.manifest.profile = .report }
        store.manifest.switches = ProjectSwitches(numberSections: true)
        store.manifest.research.append(ResearchItem(
            id: "r-smith", title: "Annual Report", type: .asset,
            citation: CitationInfo(key: "smith2026", authors: ["Smith, Jane"],
                                   sourceTitle: "Annual Report", year: 2026)))
        try await store.saveManifest()

        let research = url.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        try Self.png().write(to: research.appendingPathComponent("revenue-chart.png"))
        try Self.pdf(media: CGRect(x: 0, y: 0, width: 300, height: 300),
                     crop: CGRect(x: 0, y: 0, width: 300, height: 150))
            .write(to: research.appendingPathComponent("scan.pdf"))
        try svg.write(to: research.appendingPathComponent("diagram.svg"), atomically: true, encoding: .utf8)

        if texts.count > 1 {
            _ = try await store.addStructureItem(parentId: nil, title: "Chapter 2", kind: .document(.markdown))
        }
        let chapters = store.manifest.structure.filter { $0.path != nil }
        XCTAssertGreaterThanOrEqual(chapters.count, texts.count, "premise: enough chapters")
        for (i, item) in chapters.enumerated() {
            let path = try XCTUnwrap(item.path)
            let up = String(repeating: "../", count: path.split(separator: "/").count - 1)
            let docURL = url.appendingPathComponent(path)
            let text = i < texts.count ? texts[i] : "Another chapter."
            try text.replacingOccurrences(of: "{up}", with: up)
                .write(to: docURL, atomically: true, encoding: .utf8)
            let doc = try await Document.load(url: docURL, actor: .author, session: "word", presenter: nil)
            await doc.close()
        }
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".maugham/publish"),
                                                withIntermediateDirectories: true)
        return Fixture(store: store, url: url)
    }

    private func compile(_ fx: Fixture, language: String = "en-US",
                         label: String = "word") async throws -> (url: URL, result: DOCXCompiler.Result) {
        var config = PublishConfig(metadata: .init(title: "Fixture Report", author: "Tester"))
        config.metadata.language = language
        let compiler = try DOCXCompiler(
            projectURL: fx.url, astSource: ProjectStoreASTSource(projectStore: fx.store),
            config: config, jobManager: CompileJobManager(), maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a")
        let result = try await compiler.compile(label: label)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors.map(\.message))")
        return (URL(fileURLWithPath: result.outputPath), result)
    }

    private func part(_ name: String, of docx: URL) throws -> String {
        String(decoding: try XCTUnwrap(try ZipArchive.read(docx)[name], "no \(name)"), as: UTF8.self)
    }

    private func xml(_ name: String, of docx: URL) throws -> XMLDocument {
        try XMLDocument(xmlString: DOCXValidator.keepingSpaces(try part(name, of: docx)))
    }

    private func style(_ id: String, in styles: XMLDocument) -> XMLElement? {
        DOCXValidator.elements(styles, "w:style").first { DOCXValidator.attr($0, "w:styleId") == id }
    }

    // MARK: - the whole report

    func test_aReportWithEveryElement_passesTheValidator_andImportsWithItsWords() async throws {
        let fx = try await makeReport()
        let (docx, result) = try await compile(fx)
        XCTAssertEqual(docx.pathExtension, "docx")
        XCTAssertTrue(docx.path.hasPrefix(fx.url.appendingPathComponent("Exports").path), docx.path)
        XCTAssertEqual(result.problems, [], "every figure staged: \(result.problems.map(\.message))")
        XCTAssertEqual(DOCXValidator.problems(in: docx), [])

        let document = try xml("word/document.xml", of: docx)
        let kinds = ["w:tbl", "w:drawing", "w:footnoteReference", "w:numPr", "w:bookmarkStart", "w:instrText"]
        for kind in kinds {
            XCTAssertFalse(DOCXValidator.elements(document, kind).isEmpty, "the fixture has a \(kind)")
        }
        let styles = Set(DOCXValidator.elements(document, "w:pStyle").compactMap { DOCXValidator.attr($0, "w:val") })
        XCTAssertTrue(styles.isSuperset(of: ["Heading1", "Heading2", "Caption", "Quote", "Code", "Bibliography"]),
                      "\(styles)")
        XCTAssertEqual(DOCXValidator.elements(document, "w:drawing").count, 4,
                       "the chart twice, the PDF and the SVG")
        let media = try ZipArchive.read(docx).keys.filter { $0.hasPrefix("word/media/") }
        XCTAssertEqual(media.count, 3, "the chart used twice is one file: \(media)")
        XCTAssertTrue(media.allSatisfy { $0.hasSuffix(".png") }, "PDF and SVG became PNGs: \(media)")

        let text = try DOCXValidator.importedText(of: docx)
        for words in ["Introduction", "studies revenue and cost", "(Smith 2026, p. 12)", "Sales by quarter",
                      "A quoted finding", "Second point", "Step two", "let total = 220", "Findings",
                      "Figure 1", "Table 1", "Annual Report"] {
            XCTAssertTrue(text.contains(words), "AppKit's reader lost \"\(words)\":\n\(text)")
        }
    }

    /// **The validator's own control**: each check fires on a package with
    /// exactly its defect planted into the fixture's good one.
    func test_theValidatorCatchesEachPlantedDefect() async throws {
        let fx = try await makeReport()
        let (docx, _) = try await compile(fx)
        let good = try ZipArchive.read(docx)
        XCTAssertEqual(DOCXValidator.problems(in: docx), [], "premise: the fixture is clean")

        func planted(_ part: String, _ old: String, _ new: String, first: String = "[Content_Types].xml") throws -> [String] {
            var parts = good
            let text = String(decoding: try XCTUnwrap(parts[part]), as: UTF8.self)
            let range = try XCTUnwrap(text.range(of: old), "premise: \(part) has \(old)")
            parts[part] = Data(text.replacingCharacters(in: range, with: new).utf8)
            let order = [first] + parts.keys.filter { $0 != first }.sorted()
            let file = tmp.appendingPathComponent(UUID().uuidString + ".docx")
            try ZipArchive.write(order.map { .init(path: $0, data: parts[$0]!, compress: true) }, to: file)
            return DOCXValidator.problems(in: file)
        }
        let cases: [(String, String, String, String, String)] = [
            ("[Content_Types].xml", #"<Override PartName="/word/styles.xml""#, #"<Override PartName="/word/nothing.xml""#,
             "word/styles.xml has no content type", "[Content_Types].xml"),
            ("word/_rels/document.xml.rels", #"Target="media/"#, #"Target="media/missing-"#,
             "which is not in the package", "[Content_Types].xml"),
            ("word/document.xml", #"<w:bookmarkEnd w:id="0"/>"#, "", "has 0 ends", "[Content_Types].xml"),
            ("word/document.xml", #"<w:footnoteReference w:id="1"/>"#, #"<w:footnoteReference w:id="99"/>"#,
             "footnote reference 99 has no footnote", "[Content_Types].xml"),
            ("word/document.xml", #"<wp:docPr id="2""#, #"<wp:docPr id="1""#, "docPr id is used twice",
             "[Content_Types].xml"),
            ("word/document.xml", #"<w:gridCol w:w="4320"/>"#, "", "over a 1-column grid", "[Content_Types].xml"),
            ("word/document.xml", #"<w:numId w:val="2"/>"#, #"<w:numId w:val="77"/>"#, "numId 77",
             "[Content_Types].xml"),
            ("word/document.xml", #"<w:pStyle w:val="Caption"/>"#, #"<w:pStyle w:val="Nope"/>"#,
             "w:pStyle Nope isn't defined", "[Content_Types].xml"),
            ("word/document.xml", #"r:embed="rIdImg"#, #"r:embed="rIdGone"#, "which document.xml.rels doesn't define",
             "[Content_Types].xml"),
            ("word/document.xml", #"<w:pStyle w:val="Caption"/>"#, #"<w:pStyle w:val="CodeChar"/>"#,
             "names a character style, not a paragraph one", "[Content_Types].xml"),
            ("word/document.xml", "</w:sectPr></w:body>", "</w:sectPr><w:p/></w:body>",
             "w:sectPr is not the body's last child", "[Content_Types].xml"),
            ("word/settings.xml", "<w:footnotePr>", #"<w:updateFields w:val="true"/><w:footnotePr>"#,
             "update fields", "[Content_Types].xml"),
            ("word/document.xml", "<w:body>", "<w:body>", "not [Content_Types].xml", "word/document.xml"),
        ]
        for (part, old, new, expected, first) in cases {
            let problems = try planted(part, old, new, first: first)
            XCTAssertTrue(problems.contains { $0.contains(expected) },
                          "planting \(new.isEmpty ? "no " + old : new) in \(part): \(problems)")
        }
    }

    // MARK: - the parts

    func test_theParts_contentTypesFirst_everyPartTyped_coreAndSettings() async throws {
        let fx = try await makeReport(["Just a paragraph."])
        let (docx, _) = try await compile(fx)
        let names = Set(try ZipArchive.read(docx).keys)
        XCTAssertEqual(names, ["[Content_Types].xml", "_rels/.rels", "word/document.xml",
                               "word/_rels/document.xml.rels", "word/styles.xml", "word/numbering.xml",
                               "word/footnotes.xml", "word/settings.xml", "docProps/core.xml",
                               "docProps/app.xml"],
                       "no custom.xml without a label to carry")
        XCTAssertEqual(try DOCXValidator.open(docx).firstEntry, "[Content_Types].xml")

        let types = try part("[Content_Types].xml", of: docx)
        for name in names where name.hasSuffix(".xml") && name != "[Content_Types].xml" {
            XCTAssertTrue(types.contains(#"<Override PartName="/\#(name)""#), "\(name) has an Override:\n\(types)")
        }
        XCTAssertFalse(types.contains("Extension=\"png\""), "no media, no image default")

        let core = try part("docProps/core.xml", of: docx)
        XCTAssertTrue(core.contains("<dc:title>Fixture Report</dc:title>"), core)
        XCTAssertTrue(core.contains("<dc:creator>Tester</dc:creator>"), core)
        XCTAssertNotNil(core.range(of: #"<dcterms:created xsi:type="dcterms:W3CDTF">\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ</dcterms:created>"#,
                                   options: .regularExpression), core)

        let settings = try part("word/settings.xml", of: docx)
        XCTAssertTrue(settings.contains(#"<w:footnotePr><w:footnote w:id="-1"/><w:footnote w:id="0"/></w:footnotePr>"#), settings)
        XCTAssertFalse(settings.contains("updateFields"), settings)

        let rels = try xml("word/_rels/document.xml.rels", of: docx)
        let ids = DOCXValidator.elements(rels, "Relationship").compactMap { DOCXValidator.attr($0, "Id") }
        XCTAssertEqual(Set(ids).count, ids.count, "\(ids)")
    }

    /// Task 5's hook: the export label goes into `docProps/custom.xml`, which
    /// is written, typed and related only when there is one.
    func test_customPropertiesArePackagedOnlyWhenGiven() throws {
        let body = DOCXBodyEmitter.emit(bodies: [], config: PublishConfig(), page: .a4)
        let metadata = DOCXPackage.Metadata(title: "T", author: "A", created: Date(timeIntervalSince1970: 0))
        let styles = DOCXPackage.Styles.builtIn(language: "en")
        let without = try DOCXPackage.entries(body: body, styles: styles, metadata: metadata, customProperties: [])
        XCTAssertFalse(without.map(\.path).contains("docProps/custom.xml"))

        let with = try DOCXPackage.entries(body: body, styles: styles, metadata: metadata,
                                           customProperties: [.init(name: "Export label", value: "Draft 1 & more")])
        let custom = try XCTUnwrap(with.first { $0.path == "docProps/custom.xml" })
        let text = String(decoding: custom.data, as: UTF8.self)
        XCTAssertTrue(text.contains(#"pid="2" name="Export label"><vt:lpwstr>Draft 1 &amp; more</vt:lpwstr>"#), text)
        let file = tmp.appendingPathComponent("custom.docx")
        try ZipArchive.write(with, to: file)
        XCTAssertEqual(DOCXValidator.problems(in: file), [])
        let rels = try part("_rels/.rels", of: file)
        XCTAssertTrue(rels.contains(#"Target="docProps/custom.xml""#), rels)
        XCTAssertEqual(with.first?.path, "[Content_Types].xml")
    }

    // MARK: - styles

    func test_theBuiltInStylesDefineEveryStyleTheEmitterNames_withOutlineLevels() throws {
        let styles = try XMLDocument(xmlString: DOCXPackage.Styles.builtIn(language: "en").xml)
        for id in ["Normal", "Heading1", "Heading2", "Heading3", "Caption", "Quote", "Code", "CodeChar",
                   "Bibliography", "FootnoteText", "FootnoteReference", "TableGrid"] {
            XCTAssertNotNil(style(id, in: styles), "\(id) is defined")
        }
        for level in 1...3 {
            let heading = try XCTUnwrap(style("Heading\(level)", in: styles))
            let outline = DOCXValidator.elements(heading, "w:outlineLvl").first
            XCTAssertEqual(outline.flatMap { DOCXValidator.attr($0, "w:val") }, "\(level - 1)",
                           "Heading\(level) is in Word's outline")
        }
    }

    /// A Word-made reference whose Heading1 is Georgia, declaring the
    /// namespaces Word declares.
    private static let referenceStyles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
        xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" mc:Ignorable="w14">\
        <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="24"/></w:rPr></w:rPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>\
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
        <w:link w:val="Heading1Char"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr>\
        <w:rPr><w:rFonts w:ascii="Georgia" w:hAnsi="Georgia"/><w14:ligatures w14:val="standard"/></w:rPr></w:style>\
        <w:style w:type="character" w:customStyle="1" w:styleId="Heading1Char"><w:name w:val="Heading 1 Char"/>\
        <w:link w:val="Heading1"/></w:style>\
        </w:styles>
        """

    private func writeReference(_ entries: [ZipArchive.Entry], in fx: Fixture) throws {
        try ZipArchive.write(entries, to: fx.publish.appendingPathComponent("reference.docx"))
    }

    func test_aReferenceDocx_changesTheHeading1Font_andKeepsTheBuiltInsItLacks() async throws {
        let fx = try await makeReport()
        try writeReference([
            .init(path: "[Content_Types].xml", data: Data("<Types/>".utf8), compress: false),
            .init(path: "word/styles.xml", data: Data(Self.referenceStyles.utf8), compress: true),
        ], in: fx)
        let (docx, result) = try await compile(fx)
        XCTAssertEqual(result.warnings, [], "a good reference warns of nothing")
        XCTAssertEqual(DOCXValidator.problems(in: docx), [])

        let styles = try xml("word/styles.xml", of: docx)
        let heading = try XCTUnwrap(style("Heading1", in: styles))
        let fonts = DOCXValidator.elements(heading, "w:rFonts").first
        XCTAssertEqual(fonts.flatMap { DOCXValidator.attr($0, "w:ascii") }, "Georgia", "the reference wins")
        XCTAssertNotNil(style("Heading1Char", in: styles), "the reference's own styles come with it")
        for id in ["Caption", "Quote", "TableGrid", "FootnoteText", "Heading2"] {
            XCTAssertNotNil(style(id, in: styles), "the built-in \(id) is kept")
        }
        let sizes = DOCXValidator.elements(DOCXValidator.elements(styles, "w:docDefaults").first, "w:sz")
        XCTAssertEqual(sizes.compactMap { DOCXValidator.attr($0, "w:val") }, ["24"], "its docDefaults")
        let languages = DOCXValidator.elements(DOCXValidator.elements(styles, "w:docDefaults").first, "w:lang")
        XCTAssertEqual(languages.compactMap { DOCXValidator.attr($0, "w:val") }, ["en-US"],
                       "its docDefaults carry the book's own language")
        let defaults = DOCXValidator.elements(styles, "w:style").filter {
            DOCXValidator.attr($0, "w:type") == "paragraph" && DOCXValidator.attr($0, "w:default") == "1"
        }
        XCTAssertEqual(defaults.count, 1, "one default paragraph style")
    }

    func test_aMalformedReference_warns_andFallsBackToTheBuiltInStyles() async throws {
        let fx = try await makeReport(["# Intro\n\nText."])
        try Data("not a zip at all".utf8).write(to: fx.publish.appendingPathComponent("reference.docx"))
        let (docx, result) = try await compile(fx)
        XCTAssertEqual(result.warnings.count, 1, "\(result.warnings.map(\.message))")
        XCTAssertEqual(result.warnings.first?.level, .warning)
        XCTAssertTrue(result.warnings.first?.message.contains("reference.docx") ?? false,
                      "\(result.warnings.map(\.message))")
        XCTAssertEqual(DOCXValidator.problems(in: docx), [])
        XCTAssertEqual(try part("word/styles.xml", of: docx), DOCXPackage.Styles.builtIn(language: "en-US").xml)

        // A zip whose styles don't parse falls back the same way.
        try writeReference([.init(path: "word/styles.xml", data: Data("<w:styles".utf8), compress: false)], in: fx)
        let (again, second) = try await compile(fx, label: "again")
        XCTAssertEqual(second.warnings.count, 1, "\(second.warnings.map(\.message))")
        XCTAssertEqual(try part("word/styles.xml", of: again), DOCXPackage.Styles.builtIn(language: "en-US").xml)
    }

    /// A German Word writes its own ids (`Standard`, `berschrift1`,
    /// `Beschriftung`) and keeps Word's built-in names: the names match, so
    /// those styles ARE Normal, Heading1 and Caption, and what pointed at the
    /// old ids follows.
    private static let localisedStyles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:style w:type="paragraph" w:default="1" w:styleId="Standard"><w:name w:val="Normal"/></w:style>\
        <w:style w:type="paragraph" w:styleId="berschrift1"><w:name w:val="heading 1"/>\
        <w:basedOn w:val="Standard"/><w:next w:val="Standard"/><w:link w:val="berschrift1Zchn"/>\
        <w:pPr><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:rFonts w:ascii="Georgia" w:hAnsi="Georgia"/></w:rPr></w:style>\
        <w:style w:type="character" w:customStyle="1" w:styleId="berschrift1Zchn"><w:name w:val="Überschrift 1 Zchn"/>\
        <w:link w:val="berschrift1"/></w:style>\
        <w:style w:type="paragraph" w:styleId="Beschriftung"><w:name w:val="Caption"/><w:basedOn w:val="Standard"/>\
        <w:rPr><w:color w:val="FF0000"/></w:rPr></w:style>\
        </w:styles>
        """

    func test_aLocalisedReference_matchesTheBuiltInsByName_andRepointsItsLinks() async throws {
        let fx = try await makeReport()
        try writeReference([.init(path: "word/styles.xml", data: Data(Self.localisedStyles.utf8), compress: true)],
                           in: fx)
        let (docx, result) = try await compile(fx)
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(DOCXValidator.problems(in: docx), [])

        let styles = try xml("word/styles.xml", of: docx)
        let ids = DOCXValidator.elements(styles, "w:style").compactMap { DOCXValidator.attr($0, "w:styleId") }
        for id in ["Normal", "Heading1", "Caption"] {
            XCTAssertEqual(ids.filter { $0 == id }.count, 1, "one \(id): \(ids)")
        }
        XCTAssertFalse(ids.contains("berschrift1") || ids.contains("Standard") || ids.contains("Beschriftung"), "\(ids)")
        let heading = try XCTUnwrap(style("Heading1", in: styles))
        XCTAssertEqual(DOCXValidator.elements(heading, "w:rFonts").first.flatMap { DOCXValidator.attr($0, "w:ascii") },
                       "Georgia", "the German heading is the Heading1 the document uses")
        for pointer in ["w:basedOn", "w:next"] {
            XCTAssertEqual(DOCXValidator.elements(heading, pointer).first.flatMap { DOCXValidator.attr($0, "w:val") },
                           "Normal", "\(pointer) follows the rename")
        }
        let linked = try XCTUnwrap(style("berschrift1Zchn", in: styles))
        XCTAssertEqual(DOCXValidator.elements(linked, "w:link").first.flatMap { DOCXValidator.attr($0, "w:val") },
                       "Heading1")
        let caption = try XCTUnwrap(style("Caption", in: styles))
        XCTAssertEqual(DOCXValidator.elements(caption, "w:color").first.flatMap { DOCXValidator.attr($0, "w:val") },
                       "FF0000", "the reference's caption, not the built-in")
    }

    /// M3: Word's `w:lang` is BCP 47, so `en_US` is written `en-US`.
    func test_theProofingLanguage_isWrittenWithAHyphen() {
        XCTAssertTrue(DOCXPackage.Styles.builtIn(language: "en_US").xml.contains(#"<w:lang w:val="en-US"/>"#))
        XCTAssertFalse(DOCXPackage.Styles.builtIn(language: "").xml.contains("w:lang"))
    }

    // MARK: - figures Word can't embed (R-S3)

    /// M5: the same bytes as `.jpg` and `.jpeg` are one file under one
    /// relationship id.
    func test_theSameJPEGUnderTwoExtensions_isOneMediaFileAndOneRelationship() async throws {
        let fx = try await makeReport(["![A]({up}research/photo.jpg)\n\n![B]({up}research/photo.jpeg)"])
        let image = try XCTUnwrap(NSBitmapImageRep(data: try Self.png()))
        let jpeg = try XCTUnwrap(image.representation(using: .jpeg, properties: [:]))
        for name in ["photo.jpg", "photo.jpeg"] {
            try jpeg.write(to: fx.url.appendingPathComponent("research/" + name))
        }
        let (docx, result) = try await compile(fx)
        XCTAssertEqual(result.problems, [])
        let media = try ZipArchive.read(docx).keys.filter { $0.hasPrefix("word/media/") }
        XCTAssertEqual(media.count, 1, "\(media)")
        XCTAssertTrue(media.first?.hasSuffix(".jpg") ?? false, "\(media)")
        let rels = try part("word/_rels/document.xml.rels", of: docx)
        XCTAssertEqual(rels.components(separatedBy: "media/").count - 1, 1, rels)
        XCTAssertEqual(DOCXValidator.elements(try xml("word/document.xml", of: docx), "w:drawing").count, 2)
        XCTAssertEqual(DOCXValidator.problems(in: docx), [])
    }

    /// The PDF's crop box is 300 × 150 inside a 300 × 300 media box: the PNG,
    /// and the drawing, are 2 : 1.
    func test_aPDFFigure_becomesAPNGOfItsCropBoxAspect() async throws {
        let fx = try await makeReport(["![A scanned chart]({up}research/scan.pdf)"])
        let (docx, result) = try await compile(fx)
        XCTAssertEqual(result.problems, [])
        let media = try ZipArchive.read(docx).filter { $0.key.hasPrefix("word/media/") }
        XCTAssertEqual(media.count, 1)
        let (name, data) = try XCTUnwrap(media.first)
        XCTAssertTrue(name.hasSuffix(".png"), name)
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(Double(image.pixelsWide) / Double(image.pixelsHigh), 2, accuracy: 0.01)
        XCTAssertEqual(image.pixelsWide, Int((300.0 * 200 / 72).rounded()), "200 dpi")

        let extent = try XCTUnwrap(DOCXValidator.elements(try xml("word/document.xml", of: docx), "wp:extent").first)
        let cx = Double(DOCXValidator.attr(extent, "cx") ?? "") ?? 0
        let cy = Double(DOCXValidator.attr(extent, "cy") ?? "") ?? 1
        XCTAssertEqual(cx / cy, 2, accuracy: 0.01, "the drawing is sized from the same box")
        XCTAssertEqual(cx, 300.0 / 72 * 914_400, accuracy: 914_400 / 100, "its natural size, 300 pt")
        XCTAssertEqual(DOCXValidator.problems(in: docx), [])
    }

    func test_anSVGFigure_becomesAPNG() async throws {
        let fx = try await makeReport(["![A diagram]({up}research/diagram.svg)"])
        let (docx, result) = try await compile(fx)
        XCTAssertEqual(result.problems, [])
        let media = try ZipArchive.read(docx).filter { $0.key.hasPrefix("word/media/") }
        let (name, data) = try XCTUnwrap(media.first)
        XCTAssertTrue(name.hasSuffix(".png"), name)
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(Double(image.pixelsWide) / Double(image.pixelsHigh), 3, accuracy: 0.01)
        XCTAssertEqual(DOCXValidator.problems(in: docx), [])
    }

    func test_anSVGThatWontRender_isRefused_withNoDanglingRelationship() async throws {
        let fx = try await makeReport(["Before.\n\n![A diagram]({up}research/diagram.svg)\n\nAfter."],
                                      svg: Self.brokenSVG, report: false)
        let (docx, result) = try await compile(fx)
        XCTAssertEqual(result.problems.count, 1, "\(result.problems.map(\.message))")
        guard case .imageUnreadable(let why)? = result.problems.first?.kind else {
            return XCTFail("an imageUnreadable problem: \(result.problems)")
        }
        XCTAssertTrue(why.contains("diagram.svg"), why)
        let parts = try ZipArchive.read(docx)
        XCTAssertTrue(parts.keys.filter { $0.hasPrefix("word/media/") }.isEmpty, "\(parts.keys)")
        let rels = try part("word/_rels/document.xml.rels", of: docx)
        XCTAssertFalse(rels.contains("media/"), rels)
        XCTAssertEqual(DOCXValidator.problems(in: docx), [])
        XCTAssertTrue(try DOCXValidator.importedText(of: docx).contains("research/diagram.svg"),
                      "the figure falls back to its literal")
    }

    // MARK: - the page (R-S4)

    /// R-S4 and R-S5: the tag's region decides; a tag that names none
    /// follows this Mac's region (injected here).
    func test_thePage_isA4_unlessTheRegionIsUSOrCanada() async throws {
        for region in ["US", "GB", nil] as [String?] {
            XCTAssertEqual(DOCXCompiler.page(forLanguage: "en-US", fallbackRegion: region), .letter)
            XCTAssertEqual(DOCXCompiler.page(forLanguage: "fr-CA", fallbackRegion: region), .letter)
            XCTAssertEqual(DOCXCompiler.page(forLanguage: "en_us", fallbackRegion: region), .letter)
            XCTAssertEqual(DOCXCompiler.page(forLanguage: "en-GB", fallbackRegion: region), .a4,
                           "the tag's own region wins over the Mac's")
        }
        XCTAssertEqual(DOCXCompiler.page(forLanguage: "en", fallbackRegion: "US"), .letter)
        XCTAssertEqual(DOCXCompiler.page(forLanguage: "en", fallbackRegion: "ca"), .letter)
        XCTAssertEqual(DOCXCompiler.page(forLanguage: "en", fallbackRegion: "GB"), .a4)
        XCTAssertEqual(DOCXCompiler.page(forLanguage: "sr-Latn", fallbackRegion: "US"), .letter,
                       "a script is not a region")
        XCTAssertEqual(DOCXCompiler.page(forLanguage: "sr-Latn", fallbackRegion: "RS"), .a4)
        XCTAssertEqual(DOCXCompiler.page(forLanguage: "", fallbackRegion: "US"), .letter)
        XCTAssertEqual(DOCXCompiler.page(forLanguage: "", fallbackRegion: "GB"), .a4)
        XCTAssertEqual(DOCXCompiler.page(forLanguage: "", fallbackRegion: nil), .a4)
        XCTAssertEqual(DOCXPage.letter.sideMarginTwips * 2 + DOCXBodyEmitter.columnTwips, 12_240)
        XCTAssertEqual(DOCXPage.a4.sideMarginTwips * 2 + DOCXBodyEmitter.columnTwips, 11_906)

        let fx = try await makeReport(["Text."])
        for (language, size) in [("en-US", #"<w:pgSz w:w="12240" w:h="15840"/>"#),
                                 ("en-GB", #"<w:pgSz w:w="11906" w:h="16838"/>"#)] {
            let (docx, _) = try await compile(fx, language: language, label: language)
            let document = try part("word/document.xml", of: docx)
            XCTAssertTrue(document.contains(size), "\(language): \(document.suffix(300))")
        }
    }

    // MARK: - through the door

    private func orchestrator(_ fx: Fixture) async throws -> (CompileOrchestrator, PublishingStores) {
        PublishingStores._resetForTesting()
        let stores = PublishingStores.sharedFor(projectID: ProjectIdentifier.id(for: fx.url), projectURL: fx.url)
        var cfg = try await stores.configStore.load() ?? PublishConfig()
        cfg.metadata.title = "Door"
        cfg.metadata.author = "Tester"
        cfg.metadata.language = "en"
        try await stores.configStore.save(cfg)
        let orchestrator = CompileOrchestrator(
            projectURL: fx.url, astSource: ProjectStoreASTSource(projectStore: fx.store),
            configStore: stores.configStore, publicationStore: stores.publicationStore,
            snapshotStore: stores.snapshotStore, jobManager: stores.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        return (orchestrator, stores)
    }

    private func exported(_ fx: Fixture) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            atPath: fx.url.appendingPathComponent("Exports").path)) ?? []).filter { $0.hasSuffix(".docx") }
    }

    func test_aReportWithAnUnknownKey_refusesAtTheGate() async throws {
        let fx = try await makeReport(["Intro.\n\nRevenue grew [@nobody]."])
        let (door, stores) = try await orchestrator(fx)
        let outcome = try await door.compile(format: .docx, label: nil)
        guard case .failed(let errors, let excerpt) = outcome else {
            return XCTFail("a Report with an unknown key must refuse: \(outcome)")
        }
        XCTAssertTrue(excerpt.hasPrefix(CompileOrchestrator.publishProblemsLogExcerpt), excerpt)
        XCTAssertTrue(errors.contains { $0.message.contains("nobody") }, "\(errors.map(\.message))")
        let pubs = try await stores.publicationStore.load()
        XCTAssertEqual(pubs, [])
        XCTAssertEqual(exported(fx), [])
    }

    func test_aBilingualBook_exportsOneDocumentWithBothBodies() async throws {
        let fx = try await makeReport(["# Intro {#sec:intro}\n\nSee @sec:intro and @tbl:one.\n\n"
                                       + "| A |\n|---|\n| 1 |\nTable: One {#tbl:one}"], report: false)
        let item = try XCTUnwrap(fx.store.manifest.structure.first { $0.path != nil })
        let doc = try await Document.load(url: fx.url.appendingPathComponent(try XCTUnwrap(item.path)),
                                          actor: .author, session: "word", presenter: nil)
        let ids = doc.sequence
        XCTAssertEqual(ids.count, 3, "premise: three paragraphs")
        for (id, text) in zip(ids, ["# Uvod {#sec:intro}", "Vidi @sec:intro i @tbl:one.",
                                    "| A |\n|---|\n| 1 |\nTable: Jedan {#tbl:one}"]) {
            try await TranslationStore.append(
                TranslationRecord(paragraphId: id, language: "sr", text: text,
                                  sourceHash: TranslationHash.hash(doc.paragraphs[id] ?? ""),
                                  verbatim: false),
                forDocId: item.id, identity: LocalIdentities.current.translator,
                identities: .current, in: fx.url)
        }
        await doc.close()

        let (door, _) = try await orchestrator(fx)
        let outcome = try await door.compile(format: .docx, label: nil, languages: ["en", "sr"])
        guard case .completed(let publication, _) = outcome else {
            return XCTFail("a bilingual book exports: \(outcome)")
        }
        XCTAssertEqual(publication.format, .docx)
        XCTAssertEqual(publication.language, "en+sr")
        let docx = fx.url.appendingPathComponent(publication.outputPath)
        XCTAssertTrue(docx.lastPathComponent.contains("en+sr"), docx.lastPathComponent)
        XCTAssertEqual(DOCXValidator.problems(in: docx), [])
        let text = try DOCXValidator.importedText(of: docx)
        XCTAssertTrue(text.contains("See Section 1 and Table 1"), text)
        XCTAssertTrue(text.contains("Table 1. One"), text)
        // M2: the sr body's element words are its own.
        XCTAssertTrue(text.contains("Vidi Odeljak 1 i Tabela 1"), text)
        XCTAssertTrue(text.contains("Tabela 1. Jedan"), text)
        XCTAssertFalse(text.contains("Table 1. Jedan"), text)
        let breaks = try part("word/document.xml", of: docx).components(separatedBy: #"<w:br w:type="page"/>"#)
        XCTAssertEqual(breaks.count, 2, "one page break between the two bodies")
    }
}
