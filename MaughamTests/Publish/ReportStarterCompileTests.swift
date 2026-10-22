import XCTest
import AppKit
import PDFKit
import MaughamCore
@testable import Maugham

/// Report plan 4, Task 7 (review focus 5): a Report made by New Project
/// publishes with its OWN starter — the config the factory installed, the
/// Report template — to a PDF with a title page, the contents, the lists and
/// numbered sections, and exports to Word with no structural problem.
///
/// The single-document shape suppresses its piece title (the project's name,
/// already on the title page), so the name prints exactly once.
@MainActor
final class ReportStarterCompileTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        try await TectonicProbe.requireReady()
        tmp = TestTemp.root.appendingPathComponent("ReportStarter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private static func png() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<8 { for y in 0..<4 { rep.setColor(x < 4 ? .systemBlue : .systemOrange, atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private static let body = """
        # Introduction

        Revenue grew [@smith2026, p. 4]. See @fig:chart and @tbl:sales.

        ![Revenue by quarter]({up}research/chart.png){#fig:chart}

        | Quarter | Sales |
        |:--|--:|
        | Q1 | 100 |
        | Q2 | 120 |
        Table: Sales by quarter {#tbl:sales}

        ## Method

        We counted.
        """

    /// A Report from the factory, its first piece written and bootstrapped,
    /// a cited source and a chart in `research/`.
    private func makeReport(_ name: String, shape: ProjectFactory.ReportShape) async throws -> ProjectStore {
        let url = try await ProjectFactory.createReportProject(named: name, in: tmp, shape: shape)
        let store = try await ProjectStore.load(from: url)
        store.manifest.research.append(ResearchItem(
            id: "r-smith", title: "Annual Report", type: .asset,
            citation: CitationInfo(key: "smith2026", authors: ["Smith, Jane"],
                                   sourceTitle: "Annual Report", year: 2026)))
        try await store.saveManifest()
        try Self.png().write(to: url.appendingPathComponent("research/chart.png"))

        let path = try XCTUnwrap(store.manifest.structure.first?.path)
        let up = String(repeating: "../", count: path.split(separator: "/").count - 1)
        let docURL = url.appendingPathComponent(path)
        try Self.body.replacingOccurrences(of: "{up}", with: up)
            .write(to: docURL, atomically: true, encoding: .utf8)
        let doc = try await Document.load(url: docURL, actor: .author, session: "report", presenter: nil)
        await doc.close()
        return store
    }

    /// The config the starter installed — never a hand-made one.
    private func installedConfig(_ store: ProjectStore) throws -> PublishConfig {
        try XCTUnwrap(try PublishConfigStore.read(in: store.url), "the factory installed a config")
    }

    private var lastPDFName = ""

    private func pdf(_ store: ProjectStore) async throws -> PDFDocument {
        let compiler = try PDFCompiler(
            projectURL: store.url, astSource: ProjectStoreASTSource(projectStore: store),
            config: try installedConfig(store), jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        return try await run(compiler)
    }

    private func run(_ compiler: PDFCompiler) async throws -> PDFDocument {
        let result = try await compiler.compile(label: "starter")
        XCTAssertTrue(result.errors.isEmpty && !result.outputPath.isEmpty,
                      "\(result.errors.map(\.message))\n\(result.logExcerpt.suffix(3000))")
        lastPDFName = URL(fileURLWithPath: result.outputPath).lastPathComponent
        return try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: result.outputPath)))
    }

    private func text(_ doc: PDFDocument) -> String {
        (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func test_aNewSingleDocumentReport_publishesWithItsStarter_andExportsToWord() async throws {
        let store = try await makeReport("Quarterly Fixture", shape: .singleDocument)
        let doc = try await pdf(store)
        let text = text(doc)
        for expected in ["Quarterly Fixture", "Contents", "List of Figures", "List of Tables",
                         "1 Introduction", "1.1 Method", "Figure 1", "Table 1",
                         "(Smith 2026, p. 4)", "References"] {
            XCTAssertTrue(text.contains(expected), "missing \(expected) in:\n\(text)")
        }
        XCTAssertFalse(text.contains("??"), text)
        XCTAssertEqual(occurrences(of: "Quarterly Fixture", in: text), 1,
                       "the piece title is suppressed: the name is on the title page only\n\(text)")

        // The page follows the region at compile time, by Word's own rule
        // (R-S7), through the line PDFCompiler writes for a Report only.
        let letter = DOCXCompiler.page(forLanguage: try installedConfig(store).metadata.language,
                                       fallbackRegion: Locale.current.region?.identifier) == .letter
        let width = try XCTUnwrap(doc.page(at: 0)?.bounds(for: .mediaBox).width)
        XCTAssertEqual(width, letter ? 612 : 595.28, accuracy: 1, "letter: \(letter)")
        let metadata = try String(contentsOf: store.url.appendingPathComponent(".maugham/publish/build/metadata.tex"),
                                  encoding: .utf8)
        XCTAssertTrue(metadata.contains("\\def\\MaughamPaper{\(letter ? "letterpaper" : "a4paper")}"), metadata)
        // M2: the config still says "Untitled"; the title page names the project.
        XCTAssertEqual(try installedConfig(store).metadata.title, "Untitled", "premise: the starter's title")
        XCTAssertFalse(text.contains("Untitled"), text)
        XCTAssertTrue(lastPDFName.hasPrefix("Quarterly Fixture-v"), "the file is named after the project: \(lastPDFName)")

        // Word: the same project, through the starter's config.
        let compiler = try DOCXCompiler(
            projectURL: store.url, astSource: ProjectStoreASTSource(projectStore: store),
            config: try installedConfig(store), jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let result = try await compiler.compile(label: "word")
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors.map(\.message))")
        let docx = URL(fileURLWithPath: result.outputPath)
        XCTAssertEqual(DOCXValidator.problems(in: docx), [])
        // The same title rule names the Word file and its core.xml title.
        XCTAssertTrue(docx.lastPathComponent.hasPrefix("Quarterly Fixture-"), docx.lastPathComponent)
        let core = String(decoding: try XCTUnwrap(try ZipArchive.read(docx)["docProps/core.xml"]), as: UTF8.self)
        XCTAssertTrue(core.contains("<dc:title>Quarterly Fixture</dc:title>"), core)
    }

    /// Whole-branch I2: a Report's EPUB asks the same title rule as its PDF
    /// and Word file (`PublishContext.reportTitled`) — the file and its
    /// `dc:title` name the project while the starter's config still says
    /// "Untitled".
    func test_aReportsEPUB_isTitledByTheProject() async throws {
        let store = try await makeReport("Quarterly Fixture", shape: .singleDocument)
        XCTAssertEqual(try installedConfig(store).metadata.title, "Untitled", "premise: the starter's title")
        let compiler = try EPUBCompiler(
            projectURL: store.url, astSource: ProjectStoreASTSource(projectStore: store),
            config: try installedConfig(store), jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors.map(\.message))")
        let epub = URL(fileURLWithPath: result.outputPath)
        XCTAssertTrue(epub.lastPathComponent.hasPrefix("Quarterly Fixture-v"), epub.lastPathComponent)
        let opf = String(decoding: try XCTUnwrap(try ZipArchive.read(epub)["OEBPS/content.opf"]), as: UTF8.self)
        XCTAssertTrue(opf.contains("<dc:title>Quarterly Fixture</dc:title>"), opf)
        XCTAssertFalse(opf.contains("Untitled"), opf)
    }

    /// I1: a single-document Report that gained a document through the
    /// binder prints that document's title and contents line; only the first
    /// piece — the report itself, titled with the project's name — is silent.
    func test_aSingleDocumentReport_withAnAddedDocument_printsOnlyTheLaterTitle() async throws {
        let store = try await makeReport("Solo Fixture", shape: .singleDocument)
        let added = try await store.addStructureItem(parentId: nil, title: "Appendix", kind: .document(.markdown))
        let path = try XCTUnwrap(added.path)
        let url = store.url.appendingPathComponent(path)
        try "Raw counts by quarter.".write(to: url, atomically: true, encoding: .utf8)
        let doc = try await Document.load(url: url, actor: .author, session: "report", presenter: nil)
        await doc.close()
        XCTAssertEqual(store.manifest.structure.count, 2, "premise: two pieces")

        let text = text(try await pdf(store))
        XCTAssertEqual(occurrences(of: "Solo Fixture", in: text), 1,
                       "the first piece's title is still silent\n\(text)")
        XCTAssertEqual(occurrences(of: "Appendix", in: text), 2,
                       "the added piece prints its heading and its contents line\n\(text)")
        XCTAssertTrue(text.contains("Raw counts by quarter."), text)
    }

    /// A two-language source with one piece, titled per language.
    private struct TwoTongues: LanguageRebindableSource {
        let tag: String?
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: tag == nil ? "Solo Titleword" : "Solo Naslovword", mode: .prose,
                   displayText: tag == nil ? "Sourcesentence here." : "Prevedenarecenica ovde.")]
        }
        func rebound(toLanguage tag: String?) -> ProjectASTBuilder.Source { TwoTongues(tag: tag) }
    }

    /// Fix round 2: in a bilingual single-document Report each body is the
    /// report again, so each body's first piece title is silent — the flag
    /// re-arms at every `MaughamBody`.
    func test_aBilingualSingleDocumentReport_silencesEachBodysFirstTitle() async throws {
        let url = try await ProjectFactory.createReportProject(named: "Two Fixture", in: tmp, shape: .singleDocument)
        let store = try await ProjectStore.load(from: url)
        let config = try installedConfig(store)
        let set = try LanguageSet(language: nil, languages: ["source", "sr"], sourceTag: "en")
        let plan = try BodyPlan.make(set: set, resolved: config, source: TwoTongues(tag: nil),
                                     publishDir: url.appendingPathComponent(".maugham/publish"), wrap: { $0 })
        let compiler = try PDFCompiler(projectURL: url, bodies: plan.bodies, config: config,
                                       jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let text = text(try await run(compiler))
        XCTAssertTrue(text.contains("Sourcesentence") && text.contains("Prevedenarecenica"), "premise: both bodies\n\(text)")
        XCTAssertFalse(text.contains("Titleword"), "the source body's first title is silent\n\(text)")
        XCTAssertFalse(text.contains("Naslovword"), "the translated body's first title is silent too\n\(text)")
    }

    /// R-S7's gate: a book without the Report profile writes no paper line,
    /// and its `metadata.tex` is exactly the metadata block it always was.
    func test_aNovelsMetadata_isByteIdenticalToTheBlock() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "Plain Fixture", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let config = try installedConfig(store)
        _ = try await pdf(store)
        let metadata = try String(contentsOf: url.appendingPathComponent(".maugham/publish/build/metadata.tex"),
                                  encoding: .utf8)
        XCTAssertEqual(metadata, PDFCompiler.metadataBlock(config: config, label: "starter"))
        XCTAssertFalse(metadata.contains("MaughamPaper"))
        XCTAssertTrue(metadata.contains("\\renewcommand{\\Title}{Untitled}"), "no title fallback for a novel")
        XCTAssertTrue(lastPDFName.hasPrefix("Untitled-v"), "a novel's file keeps the config's title: \(lastPDFName)")
    }

    func test_aNewSectionsReport_printsItsSectionTitle_andTheLists() async throws {
        let store = try await makeReport("Annual Fixture", shape: .sections)
        let text = text(try await pdf(store))
        for expected in ["Annual Fixture", "Contents", "List of Figures", "1 Introduction", "Figure 1"] {
            XCTAssertTrue(text.contains(expected), "missing \(expected) in:\n\(text)")
        }
        // The piece title "Introduction" prints (contents + heading) beside
        // the numbered "1 Introduction" heading inside it.
        XCTAssertGreaterThan(occurrences(of: "Introduction", in: text), 2, text)
    }
}
