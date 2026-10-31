import XCTest
@testable import MaughamCore
@testable import Maugham

/// **A language body prints a table's translated text cells** (report plan
/// 9e-1 Task 5, spec §8): the one resolve door reads each translated body's
/// FRESH cell translations (`FigureUse.freshLabels`), the resolution hands
/// them to `FigureTableLayout`, and
/// the PDF, EPUB and Word bodies all draw from that one layout. A stale or
/// missing cell prints its source (the coverage gate says so); numbers and
/// formulas are shared; the source body is untouched.
@MainActor
final class TableFigureCellTranslationBodyTests: XCTestCase {

    // MARK: - Emitter level (no project)

    private let cashID = "fig-0a1b2c3d"
    private let cashLine = "![Cash flows](../figures/cash.csv){#tbl:cash}\n\nSee @tbl:cash."

    /// Item | Amount / Rent | 100 / Total | =SUM(B2:B2), header and total rows.
    private func cashTable() throws -> (FigureTable, item: CellKey, rent: CellKey, total: CellKey) {
        var t = FigureTable(rows: 3, columns: 2)
        t.headerRows = 1
        t.hasTotalRow = true
        let k = { (r: Int, c: Int) in CellKey(row: t.rows[r], column: t.columns[c]) }
        t.setCell(Cell(content: .value(.text("Item"))), at: k(0, 0))
        t.setCell(Cell(content: .value(.text("Amount"))), at: k(0, 1))
        t.setCell(Cell(content: .value(.text("Rent"))), at: k(1, 0))
        t.setCell(Cell(content: .value(.number(100))), at: k(1, 1))
        t.setCell(Cell(content: .value(.text("Total"))), at: k(2, 0))
        guard case .success(let f) = FormulaParser.parse("SUM(B2:B2)", in: t)
        else { throw FigureEditInvalid(reason: "the formula did not parse") }
        t.setCell(Cell(content: .formula(f)), at: k(2, 1))
        return (t, k(0, 0), k(1, 0), k(2, 0))
    }

    private func figures(_ table: FigureTable) -> PublishFigures {
        var book = Workbook(pins: FigurePinIndex())
        book.setTable(table, id: cashID)
        return PublishFigures(
            records: [FigureRecord(id: cashID, name: "cash", kind: .table, piece: nil, path: "figures/cash.csv")],
            states: [cashID: FigureState(kind: .table, table: table)],
            workbook: book, pinStatus: [:], sourceChanged: [], parked: [])
    }

    private func resolved(_ figures: PublishFigures, language: String?,
                          labels: [String: [CellKey: String]])
        throws -> (ProjectAST, PublishResolution) {
        let context = PublishContext(
            library: CitationLibrary(items: []), profile: .report,
            switches: (numberSections: false, listOfFigures: false, listOfTables: true),
            projectURL: URL(fileURLWithPath: "/nonexistent/report-9e1-cells"),
            piecePaths: ["a": "manuscript/a.md"], figures: figures)
        let source = SinglePieceSource(pieceID: "a", title: "A", mode: .prose, text: cashLine, context: context)
        let ast = try ProjectASTBuilder.build(from: source)
        let resolution = try PublishResolution.forCompile(
            source: source, bodyTag: nil, imageAllowed: ["png"], bodyLanguage: language,
            tableLocale: TableLocale(languageTag: language ?? "en-US"), cellLabels: labels)
        return (ast, resolution)
    }

    private func xhtml(_ figures: PublishFigures, language: String?,
                       labels: [String: [CellKey: String]] = [:]) throws -> String {
        let (ast, resolution) = try resolved(figures, language: language, labels: labels)
        return XHTMLBodyEmitter.emit(ast, resolution: resolution)
    }

    private func latex(_ figures: PublishFigures, language: String?,
                       labels: [String: [CellKey: String]] = [:]) throws -> String {
        let (ast, resolution) = try resolved(figures, language: language, labels: labels)
        return LaTeXBodyEmitter.emit(ast, resolution: resolution, isFirstBody: true)
    }

    private func docx(_ figures: PublishFigures, language: String?,
                       labels: [String: [CellKey: String]] = [:]) throws -> String {
        let (ast, resolution) = try resolved(figures, language: language, labels: labels)
        return DOCXBodyEmitter.emit(
            bodies: [DOCXBodyEmitter.Body(ast: ast, resolution: resolution, bodyTag: nil, figureFiles: [:])],
            config: PublishConfig(), page: .letter).documentXML
    }

    /// The es labels for Item and Rent; Total has none (missing or stale).
    private func spanish(_ item: CellKey, _ rent: CellKey) -> [String: [CellKey: String]] {
        [cashID: [item: "Concepto", rent: "Alquiler"]]
    }

    func test_anEsEPUBBodyPrintsTheTranslatedLabels() throws {
        let (t, item, rent, _) = try cashTable()
        let html = try xhtml(figures(t), language: "es", labels: spanish(item, rent))
        XCTAssertTrue(html.contains(">Concepto</th>"), html)
        XCTAssertTrue(html.contains(">Alquiler</td>"), html)
        XCTAssertTrue(html.contains(">Total</td>"), "a cell with no fresh translation prints its source: \(html)")
        XCTAssertTrue(html.contains(">Amount</th>"), html)
        XCTAssertFalse(html.contains(">Item<"), html)
        XCTAssertFalse(html.contains(">Rent<"), html)
    }

    func test_anEsWordBodyPrintsTheTranslatedLabels() throws {
        let (t, item, rent, _) = try cashTable()
        let xml = try docx(figures(t), language: "es", labels: spanish(item, rent))
        XCTAssertTrue(xml.contains(">Concepto</w:t>"), xml)
        XCTAssertTrue(xml.contains(">Alquiler</w:t>"), xml)
        XCTAssertTrue(xml.contains(">Total</w:t>"), xml)
        XCTAssertFalse(xml.contains(">Rent</w:t>"), xml)
    }

    func test_anEsPDFBodyPrintsTheTranslatedLabels() throws {
        let (t, item, rent, _) = try cashTable()
        let tex = try latex(figures(t), language: "es", labels: spanish(item, rent))
        XCTAssertTrue(tex.contains("Concepto"), tex)
        XCTAssertTrue(tex.contains("Alquiler"), tex)
        XCTAssertTrue(tex.contains("Total"), tex)
        XCTAssertFalse(tex.contains("Rent &") || tex.contains("Rent\\\\"), tex)
    }

    /// **The source body is byte-identical** with no labels handed in (what
    /// the resolve door gives a body with no language), in every format.
    func test_theSourceBodyIsByteIdenticalWithoutLabels() throws {
        let (t, item, rent, _) = try cashTable()
        let es = try xhtml(figures(t), language: "es", labels: spanish(item, rent))
        XCTAssertTrue(es.contains("Alquiler"), "premise: labels change an es body")
        let bare = try xhtml(figures(t), language: nil)
        XCTAssertTrue(bare.contains(">Rent</td>"), bare)
        XCTAssertFalse(bare.contains("Alquiler"))
        XCTAssertEqual(try latex(figures(t), language: nil), try latex(figures(t), language: nil, labels: [:]))
        XCTAssertFalse(try docx(figures(t), language: nil).contains("Alquiler"))
    }

    // MARK: - Through the store's snapshot and the compile's resolve

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("cellbody-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    /// One chapter whose second paragraph is the line of a table `cash`
    /// (Item | Amount / Rent | 100), the window's stores, and the figure's id.
    private func openBook() async throws -> (DocumentStore, ProjectStore, String) {
        try "Opening.\n\n![Cash flows](../figures/cash.csv){#tbl:cash}\n"
            .write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "Chapter A", type: .document,
                                      path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let ds = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = ds
        ds.projectStore = store

        var table = FigureTable(rows: 2, columns: 2)
        table.headerRows = 1
        table.setCell(Cell(content: .value(.text("Item"))), at: CellKey(row: table.rows[0], column: table.columns[0]))
        table.setCell(Cell(content: .value(.text("Amount"))), at: CellKey(row: table.rows[0], column: table.columns[1]))
        table.setCell(Cell(content: .value(.text("Rent"))), at: CellKey(row: table.rows[1], column: table.columns[0]))
        table.setCell(Cell(content: .value(.number(100))), at: CellKey(row: table.rows[1], column: table.columns[1]))
        let record = try await store.createFigure(kind: .table, name: "cash", piece: nil, table: table)
        XCTAssertEqual(record.path, "figures/cash.csv", "premise: the line names this figure")
        await ds.awaitOpenFigureRenderForTesting()
        return (ds, store, record.id)
    }

    private func writeSpanish(_ entries: [TranslationWritePipeline.CellEntry],
                              figureId: String, table: FigureTable) async throws {
        _ = try await TranslationWritePipeline.performCells(
            entries: entries, language: "es", figureId: figureId,
            table: table, projectURL: projectURL, actor: .translator,
            identities: try XCTUnwrap(Document.localIdentitiesForTesting),
            deviceState: try XCTUnwrap(Document.deviceStateForTesting))
    }

    /// The layouts each body of an en + es compile resolves, through the one
    /// door every compiler uses (`PublishProblemGate.resolve`).
    private func compiledLayouts(_ store: ProjectStore) async throws
        -> (source: FigureTableLayout, es: FigureTableLayout) {
        let source = ProjectStoreASTSource(projectStore: store, figures: await store.publishFigures())
        let bodies = try PublishProblemGate.resolve(bodies: [
            BodyPlan.Body(tag: nil, displayTag: "en", source: source, config: PublishConfig()),
            BodyPlan.Body(tag: "es", displayTag: "es", source: source.rebound(toLanguage: "es"),
                          config: PublishConfig()),
        ], imageAllowed: ["png"], macRegion: "US")
        let en = try XCTUnwrap(bodies[0].resolution.tableFigures["doc-a"]?.values.first, "premise: the line lays out")
        let es = try XCTUnwrap(bodies[1].resolution.tableFigures["doc-a"]?.values.first)
        return (en, es)
    }

    /// **The compile prints a fresh translation and falls back on a stale
    /// one**: the resolve door reads only fresh labels, derived against the
    /// snapshot's state; after "Rent" becomes "Rents" the es body prints
    /// "Rents" (the source) while the untouched header keeps its translation,
    /// and the source body never changes. The snapshot itself carries no
    /// translation (every figure reader pays nothing for them).
    func test_theCompilePrintsFreshTranslationsAndTheSourceForAStaleCell() async throws {
        let (ds, store, figureId) = try await openBook()
        let before = await store.publishFigures()
        let table = try XCTUnwrap(before.states[figureId]?.table)
        let item = CellKey(row: table.rows[0], column: table.columns[0])
        let rent = CellKey(row: table.rows[1], column: table.columns[0])
        try await writeSpanish([.init(key: item, text: "Concepto"), .init(key: rent, text: "Alquiler")],
                               figureId: figureId, table: table)

        var layouts = try await compiledLayouts(store)
        XCTAssertEqual(layouts.es.header, ["Concepto", "Amount"])
        XCTAssertEqual(layouts.es.body, [["Alquiler", "100"]])
        XCTAssertEqual(layouts.source.header, ["Item", "Amount"])
        XCTAssertEqual(layouts.source.body, [["Rent", "100"]])

        let host = try await ds.openFigure(figureId: figureId)
        try await host.setCell(Cell(content: .value(.text("Rents"))), at: rent)
        await ds.awaitOpenFigureRenderForTesting()

        layouts = try await compiledLayouts(store)
        XCTAssertEqual(layouts.es.header, ["Concepto", "Amount"])
        XCTAssertEqual(layouts.es.body, [["Rents", "100"]], "the stale cell prints its source")
        XCTAssertEqual(layouts.source.body, [["Rents", "100"]])
        await ds.closeFigure(figureId: figureId)
    }
}
