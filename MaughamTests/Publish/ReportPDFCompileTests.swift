import XCTest
import AppKit
import PDFKit
import MaughamCore
@testable import Maugham

/// Report foundations plan 2, Task 5: a real tectonic compile of one fixture
/// report — a captioned table, a figure from research, footnotes (in prose, a
/// caption and a table cell), citations, cross-references, `numberSections`
/// and both lists — against three templates:
///
/// 1. the current starter (graphicx and longtable in its preamble);
/// 2. a pre-plan starter preamble with neither package, which reaches them
///    only through the lines `PDFCompiler` appends to `build/metadata.tex`;
/// 3. a redesigned template with no `build/metadata` line and neither package
///    (review focus 3): the figure degrades to its caption in a framed box and
///    the table to a float around a plain `tabular`.
///
/// Every one must compile, and the PDF's text (PDFKit) must read "Figure 1",
/// "Table 1", "References" and the author–date text, and never "??".
@MainActor
final class ReportPDFCompileTests: XCTestCase {

    private var tmp: URL!
    private var store: ProjectStore!

    /// A small opaque PNG, drawn rather than pasted.
    private static func png() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<8 { for y in 0..<4 { rep.setColor(x < 4 ? .systemBlue : .systemOrange, atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    override func setUp() async throws {
        try await TectonicProbe.requireReady()
        tmp = TestTemp.root.appendingPathComponent("ReportPDF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = try await makeReport()
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    /// The fixture: a novel project turned Report through the manifest's own
    /// write door, one chapter of report syntax bootstrapped into the op log,
    /// a cited source and an image in `research/`.
    private func makeReport() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(named: "Report Fixture", in: tmp)
        let store = try await ProjectStore.load(from: url)
        store.manifest.profile = .report
        store.manifest.switches = ProjectSwitches(numberSections: true, listOfFigures: true,
                                                  listOfTables: true)
        store.manifest.research.append(ResearchItem(
            id: "r-smith", title: "Annual Report", type: .asset,
            citation: CitationInfo(key: "smith2026", authors: ["Smith, Jane"],
                                   sourceTitle: "Annual Report", year: 2026)))
        try await store.saveManifest()

        let research = url.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        try Self.png().write(to: research.appendingPathComponent("revenue-chart.png"))

        let chapters = store.manifest.structure.filter { $0.path != nil }
        let first = try XCTUnwrap(chapters.first?.path, "premise: the novel has a chapter")
        let up = String(repeating: "../", count: first.split(separator: "/").count - 1)
        let text = """
            # Introduction {#sec:intro}

            This report studies revenue [@smith2026, p. 12]. See @fig:rev_q1, @tbl:sales and @sec:method.

            ![Revenue by quarter[^cap]](\(up)research/revenue-chart.png){#fig:rev_q1}

            | Quarter | Sales & costs |
            |:--|--:|
            | Q1[^cell] | 100% |
            | Q2 | #120_x |
            Table: Sales_by quarter & cost {#tbl:sales}

            ## Method {#sec:method}

            A note here[^1] and the source again [@smith2026].

            [^1]: The first note.

            [^cap]: A caption note.

            [^cell]: A cell note.
            """
        for item in chapters {
            let docURL = url.appendingPathComponent(try XCTUnwrap(item.path))
            try (item.path == first ? text : "Another chapter.")
                .write(to: docURL, atomically: true, encoding: .utf8)
            let doc = try await Document.load(url: docURL, actor: .author, session: "report",
                                              presenter: nil)
            await doc.close()
        }
        return store
    }

    private var publish: URL { store.url.appendingPathComponent(".maugham/publish") }

    private func compile(template: String = "template.tex", label: String) async throws -> PDFCompiler.Result {
        var config = PublishConfig(metadata: .init(title: "Fixture Report", author: "Tester"))
        config.template = template
        let compiler = try PDFCompiler(
            projectURL: store.url, astSource: ProjectStoreASTSource(projectStore: store),
            config: config, jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: label)
        XCTAssertTrue(result.errors.isEmpty && !result.outputPath.isEmpty,
                      "\(template) failed: \(result.errors.map(\.message))\n\(result.logExcerpt.suffix(3000))")
        return result
    }

    private func text(of result: PDFCompiler.Result) throws -> String {
        let doc = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: result.outputPath)))
        // Whitespace folded: a line break may fall inside "p. 12".
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// An image XObject is a stream, which can never sit in an object stream,
    /// so its dictionary is always readable in the raw file.
    private func embedsAnImage(_ result: PDFCompiler.Result) throws -> Bool {
        let data = try Data(contentsOf: URL(fileURLWithPath: result.outputPath))
        let raw = String(decoding: data, as: UTF8.self)
        return raw.contains("/Subtype/Image") || raw.contains("/Subtype /Image")
    }

    private func assertReportText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for expected in ["Figure 1", "Table 1", "References", "(Smith 2026, p. 12)", "(Smith 2026)",
                         "Smith, Jane. 2026.", "Annual Report", "Section 1.1",
                         "Revenue by quarter", "Sales_by quarter & cost", "Sales & costs", "100%",
                         "#120_x", "The first note.", "A caption note.", "A cell note."] {
            XCTAssertTrue(text.contains(expected), "missing \(expected) in:\n\(text)", file: file, line: line)
        }
        for forbidden in ["??", "[@", "@fig", "@tbl", "@sec", "[^", "{#"] {
            XCTAssertFalse(text.contains(forbidden), "printed \(forbidden) in:\n\(text)", file: file, line: line)
        }
    }

    // MARK: - the three templates

    func test_theCurrentStarter_rendersTheReport() async throws {
        let starter = try String(contentsOf: publish.appendingPathComponent("preamble.tex"), encoding: .utf8)
        XCTAssertTrue(starter.contains("\\usepackage{graphicx}") && starter.contains("\\usepackage{longtable}"),
                      "premise: the starter loads both packages")
        let result = try await compile(label: "starter")
        let text = try text(of: result)
        assertReportText(text)
        XCTAssertTrue(text.contains("List of Figures") && text.contains("List of Tables"), text)
        XCTAssertTrue(try embedsAnImage(result), "the figure's image is in the PDF")
        let metadata = try String(contentsOf: publish.appendingPathComponent("build/metadata.tex"),
                                  encoding: .utf8)
        XCTAssertTrue(metadata.contains("\\IfFileExists{graphicx.sty}{\\usepackage{graphicx}}{}"), metadata)
        XCTAssertTrue(metadata.contains("\\IfFileExists{longtable.sty}{\\usepackage{longtable}}{}"), metadata)
        let figures = try FileManager.default.contentsOfDirectory(
            atPath: publish.appendingPathComponent("build/figures").path)
        XCTAssertEqual(figures.count, 1, "\(figures)")
        XCTAssertFalse(figures[0].contains(" "), "the project's spaces never reach TeX: \(figures)")
    }

    /// The starter preamble as it was before this plan: no graphicx, no
    /// longtable (and no comment naming them).
    private func prePlanPreamble() throws -> String {
        let old = try String(contentsOf: publish.appendingPathComponent("preamble.tex"), encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.contains("graphicx") && !$0.contains("longtable") }
            .joined(separator: "\n")
        XCTAssertFalse(old.contains("graphicx") || old.contains("longtable"), "premise")
        return old
    }

    /// An existing project's preamble predates the plan: no graphicx, no
    /// longtable. `build/metadata.tex` brings both, so the image still renders.
    func test_aPrePlanPreamble_getsThePackagesThroughBuildMetadata() async throws {
        try prePlanPreamble().write(to: publish.appendingPathComponent("preamble.tex"),
                                    atomically: true, encoding: .utf8)
        let result = try await compile(label: "preplan")
        assertReportText(try text(of: result))
        XCTAssertTrue(try embedsAnImage(result), "graphicx arrived through build/metadata.tex")
    }

    /// Review focus 3: a redesigned template with no `build/metadata` line, over
    /// a preamble with neither package, still compiles. The figure is its
    /// caption in a framed box; the table is a float around a plain `tabular`.
    /// (It keeps a preamble that declares `\\Title` and friends: the
    /// per-body `build/metadata.<tag>` the wrapper reads `\\renewcommand`s
    /// them, as it has since bilingual bodies shipped.)
    func test_aRedesignedTemplateWithoutBuildMetadata_degradesAndCompiles() async throws {
        try prePlanPreamble().write(to: publish.appendingPathComponent("redesigned-preamble.tex"),
                                    atomically: true, encoding: .utf8)
        let redesigned = """
            \\documentclass[11pt]{article}
            \\input{redesigned-preamble}
            \\input{prose}
            \\input{screenplay}
            \\begin{document}
            \\input{frontmatter}
            \\input{build/body}
            \\input{backmatter}
            \\end{document}
            """
        XCTAssertFalse(redesigned.contains("metadata"), "premise")
        try redesigned.write(to: publish.appendingPathComponent("redesigned.tex"),
                             atomically: true, encoding: .utf8)
        let result = try await compile(template: "redesigned.tex", label: "redesigned")
        let text = try text(of: result)
        assertReportText(text)
        XCTAssertFalse(try embedsAnImage(result), "no graphicx, no image: the framed caption stands in")
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "Revenue by quarter").count - 1, 3,
                                    "the framed box, the caption and the list of figures: \(text)")
    }
}
