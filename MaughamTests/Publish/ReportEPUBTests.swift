import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// Report foundations plan 2, Task 6: a real EPUB compile of a fixture report
/// — a labelled figure from research used twice, an SVG figure, a captioned
/// table, footnotes, a citation, cross-references from the second chapter
/// into the first, `numberSections` and both lists — unzipped through
/// `EPUBInspection` and read as what a reading system gets.
@MainActor
final class ReportEPUBTests: XCTestCase {

    private var tmp: URL!
    private var store: ProjectStore!

    private static func png() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<8 { for y in 0..<4 { rep.setColor(x < 4 ? .systemBlue : .systemOrange, atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private static let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>
        """

    override func setUp() async throws {
        tmp = TestTemp.root.appendingPathComponent("ReportEPUB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = try await makeReport()
    }

    override func tearDown() async throws {
        if let store {
            // Restore read access to anything a test locked, so cleanup works.
            let research = store.url.appendingPathComponent("research")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: research.path)) ?? [] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: research.appendingPathComponent(name).path)
            }
        }
        store = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeReport() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(named: "EPUB Report", in: tmp)
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
        try Self.svg.write(to: research.appendingPathComponent("diagram.svg"), atomically: true, encoding: .utf8)

        _ = try await store.addStructureItem(parentId: nil, title: "Chapter 2",
                                             kind: .document(.markdown))
        let chapters = store.manifest.structure.filter { $0.path != nil }
        XCTAssertGreaterThanOrEqual(chapters.count, 2, "premise: the novel has two chapters")
        let first = try XCTUnwrap(chapters.first?.path)
        let up = String(repeating: "../", count: first.split(separator: "/").count - 1)
        let one = """
            # Introduction {#sec:intro}

            This report studies revenue [@smith2026, p. 12].

            ![Revenue & cost[^cap]](\(up)research/revenue-chart.png){#fig:rev}

            | Quarter | Sales |
            |:--|--:|
            | Q1[^cell] | 100 |
            Table: Sales by quarter {#tbl:sales}

            A note here[^1].

            [^1]: The first note.

            [^cap]: A caption note.

            [^cell]: A cell note.
            """
        let two = """
            ## Findings

            See @fig:rev, @tbl:sales and @sec:intro; a note[^1].

            ![The same chart again](\(up)research/revenue-chart.png)

            ![A diagram](\(up)research/diagram.svg)

            [^1]: The second chapter's note.
            """
        for (i, item) in chapters.enumerated() {
            let docURL = url.appendingPathComponent(try XCTUnwrap(item.path))
            try (i == 0 ? one : i == 1 ? two : "Another chapter.")
                .write(to: docURL, atomically: true, encoding: .utf8)
            let doc = try await Document.load(url: docURL, actor: .author, session: "report",
                                              presenter: nil)
            await doc.close()
        }
        return store
    }

    private func compile(label: String = "epub") async throws -> URL {
        let config = PublishConfig(metadata: .init(title: "Fixture Report", author: "Tester"))
        let compiler = try EPUBCompiler(
            projectURL: store.url, astSource: ProjectStoreASTSource(projectStore: store),
            config: config, jobManager: CompileJobManager(), maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a")
        let result = try await compiler.compile(label: label)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors.map(\.message))")
        return URL(fileURLWithPath: result.outputPath)
    }

    private func parses(_ xml: String, _ name: String) {
        XCTAssertNoThrow(try XMLDocument(xmlString: xml, options: []), "\(name) is not well-formed XML:\n\(xml)")
    }

    // MARK: the package

    func test_thePackageShipsItsImagesOnceEach_andStillValidatesStructurally() async throws {
        let epub = try await compile()
        let names = try epubEntryNames(inEPUBAt: epub)
        XCTAssertEqual(names.first, "mimetype", "mimetype must be the first entry: \(names)")
        let images = names.filter { $0.hasPrefix("OEBPS/images/") && !$0.hasSuffix("/") }
        XCTAssertEqual(images.count, 2, "the chart used twice is one file, plus the SVG: \(names)")
        XCTAssertEqual(images.filter { $0.range(of: #"^OEBPS/images/[0-9a-f]{16}\.png$"#,
                                                options: .regularExpression) != nil }.count, 1, "\(images)")
        XCTAssertEqual(images.filter { $0.range(of: #"^OEBPS/images/[0-9a-f]{16}\.svg$"#,
                                                options: .regularExpression) != nil }.count, 1, "\(images)")

        let opf = try epubEntryText("OEBPS/content.opf", inEPUBAt: epub)
        parses(opf, "content.opf")
        for image in images {
            let name = String(image.dropFirst("OEBPS/images/".count))
            let type = name.hasSuffix(".svg") ? "image/svg+xml" : "image/png"
            XCTAssertTrue(opf.contains(#"href="images/\#(name)" media-type="\#(type)"/>"#), opf)
        }
        XCTAssertTrue(opf.contains(#"<item id="refs" href="references.xhtml" media-type="application/xhtml+xml"/>"#), opf)
        XCTAssertTrue(opf.contains(#"<itemref idref="refs"/>"#), opf)
        for name in names where name.hasSuffix(".xhtml") {
            parses(try epubEntryText(name, inEPUBAt: epub), name)
        }
    }

    // MARK: the sections

    func test_theSectionsRenderNotesFiguresTablesAndCrossFileReferences() async throws {
        let epub = try await compile()
        let one = try epubEntryText("OEBPS/section-001.xhtml", inEPUBAt: epub)
        let two = try epubEntryText("OEBPS/section-002.xhtml", inEPUBAt: epub)

        XCTAssertTrue(one.contains("xmlns:epub=\"http://www.idpf.org/2007/ops\""), one)
        XCTAssertTrue(one.contains(#"<span class="section-number">1</span> Introduction"#), one)
        XCTAssertTrue(one.contains("(Smith 2026, p. 12)"), one)
        XCTAssertTrue(one.range(of: #"<img id="lbl-fig-rev" src="images/[0-9a-f]{16}\.png" alt="Revenue &amp; cost"/>"#,
                                options: .regularExpression) != nil, one)
        XCTAssertTrue(one.contains(#"<figcaption><span class="caption-number">Figure 1.</span> Revenue &amp; cost"#), one)
        XCTAssertTrue(one.contains(#"<caption id="lbl-tbl-sales"><span class="caption-number">Table 1.</span> Sales by quarter</caption>"#), one)
        // Book order: the caption note, the cell note, then the prose note.
        for n in 1...3 {
            XCTAssertTrue(one.contains(##"<a epub:type="noteref" role="doc-noteref" href="#fn-\##(n)" id="fnref-\##(n)">\##(n)</a>"##), one)
            XCTAssertTrue(one.contains(#"<aside epub:type="footnote" role="doc-footnote" id="fn-\#(n)">"#), one)
        }

        // The second chapter's [^1] continues the count, and its aside is its own.
        XCTAssertTrue(two.contains(##"href="#fn-4" id="fnref-4">4</a>"##), two)
        XCTAssertTrue(two.contains(##"<aside epub:type="footnote" role="doc-footnote" id="fn-4"><p><a href="#fnref-4">4</a> The second chapter&apos;s note.</p></aside>"##), two)
        XCTAssertFalse(two.contains(#"id="fn-1""#), two)
        // Cross-references link into the FIRST chapter's file.
        XCTAssertTrue(two.contains(#"<a href="section-001.xhtml#lbl-fig-rev">Figure 1</a>"#), two)
        XCTAssertTrue(two.contains(#"<a href="section-001.xhtml#lbl-tbl-sales">Table 1</a>"#), two)
        XCTAssertTrue(two.contains(#"<a href="section-001.xhtml#lbl-sec-intro">Section 1</a>"#), two)
        XCTAssertTrue(two.contains(#"<span class="section-number">1.1</span> Findings"#), two)
        XCTAssertTrue(two.contains(#"<img id="fig-2" src="images/"#), two)
        XCTAssertTrue(two.contains(#"<span class="caption-number">Figure 3.</span> A diagram"#), two)
    }

    // MARK: References and the nav

    func test_referencesAreTheirOwnSection_andTheNavCarriesTheLists() async throws {
        let epub = try await compile()
        let refs = try epubEntryText("OEBPS/references.xhtml", inEPUBAt: epub)
        XCTAssertTrue(refs.contains(#"<p class="reference">Smith, Jane. 2026. <em>Annual Report</em>.</p>"#), refs)

        let nav = try epubEntryText("OEBPS/nav.xhtml", inEPUBAt: epub)
        XCTAssertTrue(nav.contains(#"<li><a href="references.xhtml">References</a></li>"#), nav)
        XCTAssertTrue(nav.contains(#"<nav epub:type="loi" id="loi">"#), nav)
        XCTAssertTrue(nav.contains(#"<li><a href="section-001.xhtml#lbl-fig-rev">Figure 1. Revenue &amp; cost</a></li>"#), nav)
        XCTAssertTrue(nav.contains(#"<li><a href="section-002.xhtml#fig-2">Figure 2. The same chart again</a></li>"#), nav)
        XCTAssertTrue(nav.contains(#"<li><a href="section-002.xhtml#fig-3">Figure 3. A diagram</a></li>"#), nav)
        XCTAssertTrue(nav.contains(#"<nav epub:type="lot" id="lot">"#), nav)
        XCTAssertTrue(nav.contains(#"<li><a href="section-001.xhtml#lbl-tbl-sales">Table 1. Sales by quarter</a></li>"#), nav)
    }

    /// The lists are off when their switches are: no loi, no lot.
    func test_theNavCarriesNoListsWhenTheSwitchesAreOff() async throws {
        store.manifest.switches = ProjectSwitches(numberSections: true, listOfFigures: false,
                                                  listOfTables: false)
        try await store.saveManifest()
        let nav = try epubEntryText("OEBPS/nav.xhtml", inEPUBAt: try await compile())
        XCTAssertFalse(nav.contains("epub:type=\"loi\""), nav)
        XCTAssertFalse(nav.contains("epub:type=\"lot\""), nav)
    }

    // MARK: link integrity

    /// Compiles the fixture as two bodies (`en`, `sr`) over the same source,
    /// the shape a bilingual edition takes: per-body files, tagged ids.
    private func compileTwoBodies() async throws -> URL {
        let config = PublishConfig(metadata: .init(title: "Fixture Report", author: "Tester"))
        let source = ProjectStoreASTSource(projectStore: store)
        let compiler = try EPUBCompiler(
            projectURL: store.url,
            bodies: ["en", "sr"].map { BodyPlan.Body(tag: $0, displayTag: $0, source: source, config: config) },
            config: config, jobManager: CompileJobManager(), maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a", identity: "en+sr")
        let result = try await compiler.compile(label: "two")
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors.map(\.message))")
        return URL(fileURLWithPath: result.outputPath)
    }

    /// Every link in the package lands: each `href="F#X"` in the nav and the
    /// sections names a file F that ships and an `id="X"` inside it; each
    /// `href="#X"` an id in its own file; each `src` a file that ships; and
    /// no file repeats an id.
    private func assertEveryLinkLands(in epub: URL, file: StaticString = #filePath,
                                      line: UInt = #line) throws -> Int {
        let entries = Set(try epubEntryNames(inEPUBAt: epub))
        let documents = entries.filter { $0.hasPrefix("OEBPS/") && $0.hasSuffix(".xhtml") }
        func captures(_ pattern: String, in text: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: pattern)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
        var ids: [String: [String]] = [:]
        var texts: [String: String] = [:]
        for doc in documents {
            let name = String(doc.dropFirst("OEBPS/".count))
            let text = try epubEntryText(doc, inEPUBAt: epub)
            texts[name] = text
            ids[name] = captures(#"\sid="([^"]+)""#, in: text)
            let repeated = Dictionary(grouping: ids[name]!, by: { $0 }).filter { $0.value.count > 1 }.keys
            XCTAssertTrue(repeated.isEmpty, "\(name) repeats ids \(repeated.sorted())", file: file, line: line)
        }
        var checked = 0
        for (name, text) in texts {
            for href in captures(#"href="([^"]+)""#, in: text) where !href.contains(":") && href != "styles.css" {
                let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let target = parts[0].isEmpty ? name : parts[0]
                guard entries.contains("OEBPS/" + target) else {
                    XCTFail("\(name): \(href) names a file the package doesn't ship", file: file, line: line)
                    continue
                }
                if parts.count == 2 {
                    XCTAssertTrue(ids[target]?.contains(parts[1]) == true,
                                  "\(name): \(href) has no id=\"\(parts[1])\" in \(target)", file: file, line: line)
                }
                checked += 1
            }
            for src in captures(#"src="([^"]+)""#, in: text) {
                XCTAssertTrue(entries.contains("OEBPS/" + src), "\(name): src \(src) doesn't ship",
                              file: file, line: line)
            }
        }
        return checked
    }

    func test_everyLinkLands_inASingleBodyReport() async throws {
        let checked = try assertEveryLinkLands(in: try await compile())
        XCTAssertGreaterThan(checked, 15, "premise: the fixture links a lot")
    }

    func test_everyLinkLands_inATwoBodyReport() async throws {
        let epub = try await compileTwoBodies()
        let checked = try assertEveryLinkLands(in: epub)
        XCTAssertGreaterThan(checked, 30, "premise: two bodies, twice the links")
        let sr = try epubEntryText("OEBPS/section-sr-002.xhtml", inEPUBAt: epub)
        XCTAssertTrue(sr.contains(#"<a href="section-sr-001.xhtml#lbl-sr-fig-rev">Figure 1</a>"#), sr)
        let names = try epubEntryNames(inEPUBAt: epub)
        XCTAssertTrue(names.contains("OEBPS/references-en.xhtml") && names.contains("OEBPS/references-sr.xhtml"),
                      "\(names)")
    }

    // MARK: the per-body prepare

    /// R-S3/R-P2-7: an image the prepare cannot read is an `imageUnreadable`
    /// problem in the body's resolution, and its figure is unresolved — the
    /// literal source, never a broken `<img>`.
    func test_anUnreadableImage_isAProblem_andItsFigureRendersLiterally() async throws {
        let chart = store.url.appendingPathComponent("research/revenue-chart.png")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: chart.path)
        let body = BodyPlan.Body(tag: nil, displayTag: "en",
                                 source: ProjectStoreASTSource(projectStore: store),
                                 config: PublishConfig())
        let prepared = try EPUBCompiler.prepare(body: body, bodyTag: nil)
        let unreadable = prepared.resolution.problems.filter {
            if case .imageUnreadable = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(unreadable.count, 2, "both uses of the chart: \(prepared.resolution.problems)")
        XCTAssertEqual(prepared.images.map { ($0.filename as NSString).pathExtension }, ["svg"],
                       "only the SVG is packaged: \(prepared.images)")
        let section = try epubEntryText("OEBPS/section-001.xhtml", inEPUBAt: try await compile())
        XCTAssertFalse(section.contains("<img"), section)
        XCTAssertTrue(section.contains("![Revenue &amp; cost"), section)
    }
}
