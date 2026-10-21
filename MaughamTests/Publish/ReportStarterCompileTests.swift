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

    private func pdf(_ store: ProjectStore) async throws -> PDFDocument {
        let compiler = try PDFCompiler(
            projectURL: store.url, astSource: ProjectStoreASTSource(projectStore: store),
            config: try installedConfig(store), jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: "starter")
        XCTAssertTrue(result.errors.isEmpty && !result.outputPath.isEmpty,
                      "\(result.errors.map(\.message))\n\(result.logExcerpt.suffix(3000))")
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

        // The page follows the region, by the same rule as Word's.
        let paper = PublishStarter.reportPaper(language: try installedConfig(store).metadata.language,
                                               region: Locale.current.region?.identifier)
        let width = try XCTUnwrap(doc.page(at: 0)?.bounds(for: .mediaBox).width)
        XCTAssertEqual(width, paper == "letterpaper" ? 612 : 595.28, accuracy: 1, "\(paper)")

        // Word: the same project, through the starter's config.
        let compiler = try DOCXCompiler(
            projectURL: store.url, astSource: ProjectStoreASTSource(projectStore: store),
            config: try installedConfig(store), jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let result = try await compiler.compile(label: "word")
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors.map(\.message))")
        XCTAssertEqual(DOCXValidator.problems(in: URL(fileURLWithPath: result.outputPath)), [])
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
