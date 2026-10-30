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
///
/// Report plan 7a final review I2/I3: the fixture also holds a table figure
/// (`figures/cash.csv`, labelled `tbl:cash`, on disk), so every compile runs
/// its kernel `table` float through tectonic, the versioned compile's gate
/// lets a Report with a table figure through, and `@tbl:cash` reads
/// "Table 3".
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
        let figures = url.appendingPathComponent("figures")
        try FileManager.default.createDirectory(at: figures, withIntermediateDirectories: true)
        try "Year,Cash\n2026,100\n".write(to: figures.appendingPathComponent("cash.csv"),
                                          atomically: true, encoding: .utf8)

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
            | [draft] | x |
            | [@ghost] | y |
            Table: Sales_by quarter & cost {#tbl:sales}

            | [note] | b |
            |---|---|
            | *star* | z |

            ![Programme cash](\(up)figures/cash.csv){#tbl:cash}

            The cash flows are in @tbl:cash.

            - [draft] first item
            - second item

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
            projectURL: store.url, astSource: ProjectStoreASTSource(projectStore: store, figures: .none),
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
                         "#120_x", "The first note.", "A caption note.", "A cell note.",
                         // I1/m4: rows, a header and a list item opening with `[`.
                         "[draft] x", "[@ghost] y", "[note] b", "star z", "[draft] first item",
                         // R-S9: the uncaptioned table still prints its number.
                         "Table 2",
                         // Report plan 7a I3: the table figure's float and its reference.
                         "Table 3: Programme cash", "The cash flows are in Table 3"] {
            XCTAssertTrue(text.contains(expected), "missing \(expected) in:\n\(text)", file: file, line: line)
        }
        // `[@ghost]` is an unknown key and prints literally; no known key does.
        // The table figure prints its own source line until plan 9 emits its
        // cells, so that one line is set aside before the check.
        let tableFigureSource = "{#tbl:cash}"
        XCTAssertTrue(text.contains(tableFigureSource), "premise: the literal source line", file: file, line: line)
        let checked = text.replacingOccurrences(of: tableFigureSource, with: "")
        for forbidden in ["??", "[@smith", "@fig", "@tbl", "@sec", "[^", "{#"] {
            XCTAssertFalse(checked.contains(forbidden), "printed \(forbidden) in:\n\(text)", file: file, line: line)
        }
    }

    // MARK: - the templates

    /// I1 in a non-Report book: `[@ghost]` is only a warning there, so the
    /// compile goes ahead — and a row opening with it must not kill it.
    func test_aNonReportBook_withARowOpeningWithAnUnknownKey_compiles() async throws {
        store.manifest.profile = nil
        try await store.saveManifest()
        let result = try await compile(label: "novel")
        let text = try text(of: result)
        XCTAssertTrue(text.contains("[@ghost] y") && text.contains("[draft] x"), text)
        XCTAssertTrue(text.contains("Table 1") && text.contains("Table 2") && text.contains("Table 3"), text)
    }

    func test_theCurrentStarter_rendersTheReport() async throws {
        let starter = try String(contentsOf: publish.appendingPathComponent("preamble.tex"), encoding: .utf8)
        XCTAssertTrue(starter.contains("\\usepackage{graphicx}") && starter.contains("\\usepackage{longtable}"),
                      "premise: the starter loads both packages")
        let result = try await compile(label: "starter")
        let text = try text(of: result)
        assertReportText(text)
        XCTAssertTrue(text.contains("List of Figures") && text.contains("List of Tables"), text)
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "Programme cash").count - 1, 3,
                                    "the list of tables, the caption and the literal source: \(text)")
        // I2: the door's own resolution for a PDF raises no image problem for
        // the table figure. Its line names no registered figure here (the
        // fixture registers none), so since plan 9a it is not found, beside
        // the fixture's `[@ghost]`.
        let config = PublishConfig(metadata: .init(title: "Fixture Report", author: "Tester"))
        let bodies = try PDFCompiler.resolve(bodies: [BodyPlan.Body(
            tag: nil, displayTag: "en", source: ProjectStoreASTSource(projectStore: store, figures: .none), config: config)])
        XCTAssertEqual(bodies[0].resolution.problems.filter { $0.isError(profile: .report) }.map(\.kind),
                       [.figureNotFound("../figures/cash.csv"), .unknownCitationKey("ghost")],
                       "the table figure is no unreadable image")
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

    // MARK: - table figures (report plan 9a Task 5)

    /// A Report whose one chapter holds a 60-row table figure — header, a
    /// text cell of TeX specials, numbers, a `SUM` total — registered as the
    /// snapshot a publish door takes, so the compile lays it out.
    private func makeLongTableFigureReport() async throws -> (ProjectStore, PublishFigures) {
        let url = try await ProjectFactory.createNovelProject(named: "Long Table", in: tmp)
        let store = try await ProjectStore.load(from: url)
        store.manifest.profile = .report
        store.manifest.switches = ProjectSwitches(numberSections: false, listOfFigures: false,
                                                  listOfTables: false)
        try await store.saveManifest()

        var table = FigureTable(rows: 62, columns: 2)
        table.headerRows = 1
        table.hasTotalRow = true
        func set(_ r: Int, _ c: Int, _ value: CellValue) {
            table.setCell(Cell(content: .value(value)), at: CellKey(row: table.rows[r], column: table.columns[c]))
        }
        set(0, 0, .text("LedgerItem")); set(0, 1, .text("LedgerAmount"))
        for r in 1...60 {
            set(r, 0, .text(r == 1 ? "[draft] <5% & #1_x" : "Row \(r)"))
            set(r, 1, .number(Double(r * 10)))
        }
        set(61, 0, .text("Total"))
        guard case .success(let sum) = FormulaParser.parse("SUM(B2:B61)", in: table)
        else { throw FigureEditInvalid(reason: "the formula did not parse") }
        table.setCell(Cell(content: .formula(sum)), at: CellKey(row: table.rows[61], column: table.columns[1]))
        // A headless table whose last row is its total, opening with `[`.
        var short = FigureTable(rows: 2, columns: 1)
        short.hasTotalRow = true
        short.setCell(Cell(content: .value(.text("[early] 7"))), at: CellKey(row: short.rows[0], column: short.columns[0]))
        short.setCell(Cell(content: .value(.text("ShortTotal"))), at: CellKey(row: short.rows[1], column: short.columns[0]))
        let id = "fig-1a2b3c4d", shortID = "fig-5e6f7a8b"
        var book = Workbook(pins: FigurePinIndex())
        book.setTable(table, id: id)
        book.setTable(short, id: shortID)
        let figures = PublishFigures(
            records: [FigureRecord(id: id, name: "ledger", kind: .table, piece: nil, path: "figures/ledger.csv"),
                      FigureRecord(id: shortID, name: "short", kind: .table, piece: nil, path: "figures/short.csv")],
            states: [id: FigureState(kind: .table, table: table), shortID: FigureState(kind: .table, table: short)],
            workbook: book, pinStatus: [:], sourceChanged: [], parked: [])

        let chapters = store.manifest.structure.filter { $0.path != nil }
        let first = try XCTUnwrap(chapters.first?.path, "premise: the novel has a chapter")
        let up = String(repeating: "../", count: first.split(separator: "/").count - 1)
        for item in chapters {
            let docURL = url.appendingPathComponent(try XCTUnwrap(item.path))
            let text = item.path == first
                ? "The ledger follows.\n\n![The ledger](\(up)figures/ledger.csv){#tbl:ledger}\n\nSee @tbl:ledger.\n\n![Short](\(up)figures/short.csv)"
                : "Another chapter."
            try text.write(to: docURL, atomically: true, encoding: .utf8)
            let doc = try await Document.load(url: docURL, actor: .author, session: "report",
                                              presenter: nil)
            await doc.close()
        }
        return (store, figures)
    }

    /// The table figure's cells reach the PDF through tectonic: its 60 rows
    /// run past a page, the header repeats on the table's second page, the
    /// total prints its computed sum, and the specials print literally; a
    /// headless table figure (`MaughamTableNoHead`) compiles beside it.
    func test_aLongTableFigure_repeatsItsHeaderOnItsSecondPage() async throws {
        let (store, figures) = try await makeLongTableFigureReport()
        let config = PublishConfig(metadata: .init(title: "Long Table", author: "Tester"))
        let compiler = try PDFCompiler(
            projectURL: store.url, astSource: ProjectStoreASTSource(projectStore: store, figures: figures),
            config: config, jobManager: CompileJobManager(), maughamVersion: "0.0.0-test")
        let result = try await compiler.compile(label: "ledger")
        XCTAssertTrue(result.errors.isEmpty && !result.outputPath.isEmpty,
                      "\(result.errors.map(\.message))\n\(result.logExcerpt.suffix(3000))")
        let pages = try pages(of: result)
        let all = pages.joined(separator: "\n---\n")
        let first = try XCTUnwrap(pages.firstIndex { $0.contains("Table 1: The ledger") }, all)
        XCTAssertTrue(pages[first].contains("LedgerItem LedgerAmount"), all)
        guard pages.indices.contains(first + 1) else {
            return XCTFail("premise: 60 rows run past a page: \(all)")
        }
        XCTAssertTrue(pages[first + 1].contains("LedgerItem LedgerAmount"),
                      "the header repeats on the table's second page: \(pages[first + 1])")
        XCTAssertTrue(all.contains("[draft] <5% & #1_x 10"), all)
        XCTAssertTrue(all.contains("Row 60 600"), all)
        XCTAssertTrue(all.contains("Total 18300"), "the total's computed sum: \(all)")
        XCTAssertTrue(all.contains("See Table 1"), all)
        XCTAssertFalse(all.contains("ledger.csv") || all.contains("{#"), "no literal source line: \(all)")
        // The headless form compiles too: caption, its row, its ruled total.
        XCTAssertTrue(all.contains("Table 2: Short [early] 7 ShortTotal"), all)
        XCTAssertFalse(all.contains("short.csv"), all)
    }

    // MARK: - element words (R-S16)

    /// The bodies of an en+sr edition, each folded to its language as
    /// `BodyPlan` folds them, over the same text.
    private func bilingualBodies(_ config: PublishConfig) -> [BodyPlan.Body] {
        let source = ProjectStoreASTSource(projectStore: store, figures: .none)
        return [nil, "sr"].map { tag -> BodyPlan.Body in
            var folded = config
            folded.metadata = config.effectiveMetadata(language: tag)
            return BodyPlan.Body(tag: tag, displayTag: tag ?? "en", source: source, config: folded)
        }
    }

    /// The pages of the compiled PDF, each as whitespace-folded text.
    private func pages(of result: PDFCompiler.Result) throws -> [String] {
        let doc = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: result.outputPath)))
        return (0..<doc.pageCount).map { i in
            (doc.page(at: i)?.string ?? "").components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// A Serbian body's caption (the kernel's `\figurename`) and its
    /// cross-reference (the resolution's text) both read "Slika 1"; the
    /// English body before it still reads "Figure 1" in both, and the
    /// Serbian names do not leak back into it.
    func test_aSerbianBody_readsSlikaInItsCaptionAndItsCrossReference() async throws {
        let config = PublishConfig(metadata: .init(title: "Fixture Report", author: "Tester"))
        let compiler = try PDFCompiler(
            projectURL: store.url, bodies: bilingualBodies(config), config: config,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test", identity: "en+sr")
        let result = try await compiler.compile(label: "bilingual")
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors.map(\.message))\n\(result.logExcerpt.suffix(3000))")
        let pages = try pages(of: result)
        let firstSerbian = try XCTUnwrap(pages.firstIndex { $0.contains("Slika") }, pages.joined(separator: "\n---\n"))
        let en = pages[..<firstSerbian].joined(separator: " ")
        let sr = pages[firstSerbian...].joined(separator: " ")

        XCTAssertTrue(sr.contains("Slika 1:"), "the caption: \(sr)")
        XCTAssertTrue(sr.contains("See Slika 1, Tabela 1 and Odeljak 1.1"), "the cross-references: \(sr)")
        XCTAssertTrue(sr.contains("Tabela 1:") && sr.contains("Literatura"), sr)
        XCTAssertFalse(sr.contains("Figure") || sr.contains("References"), "no English in the Serbian body: \(sr)")

        XCTAssertTrue(en.contains("Figure 1:") && en.contains("See Figure 1, Table 1 and Section 1.1"), en)
        XCTAssertTrue(en.contains("List of Figures") && en.contains("References"), en)
        XCTAssertFalse(en.contains("Slika") || en.contains("Tabela"), "the English body: \(en)")
        let tex = try String(contentsOf: publish.appendingPathComponent("build/body.sr.tex"), encoding: .utf8)
        XCTAssertTrue(tex.contains("\\renewcommand{\\figurename}{Slika}"), "premise: set in the body")
    }

    /// A word the config names wins over the table, in the real PDF too.
    func test_aConfigOverride_winsOverTheTableInThePDF() async throws {
        var config = PublishConfig(metadata: .init(title: "Fixture Report", author: "Tester"))
        config.languageOverrides["sr"] = .init(metadata: ["figure": "Grafikon"])
        let compiler = try PDFCompiler(
            projectURL: store.url, bodies: bilingualBodies(config), config: config,
            jobManager: CompileJobManager(), maughamVersion: "0.0.0-test", identity: "en+sr")
        let result = try await compiler.compile(label: "override")
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors.map(\.message))")
        let text = try pages(of: result).joined(separator: " ")
        XCTAssertTrue(text.contains("Grafikon 1:") && text.contains("See Grafikon 1, Tabela 1"), text)
        XCTAssertFalse(text.contains("Slika"), text)
    }
}
