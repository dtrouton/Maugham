import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The coverage gate counts the text cells of the tables an edition uses**
/// (report plan 9e-1 Task 6, R7): a missing or stale cell of an unparked
/// table used in an included piece blocks a language edition exactly as a
/// paragraph does, `allow_stale` falls back with the usual suffix, a table
/// used in two pieces counts once — and `EditionStatus` (the desk's rows and
/// `translation_status`) counts the same cells and paragraphs the gate does.
@MainActor
final class TableFigureCoverageGateTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("cellgate-\(UUID().uuidString)")
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

    private struct Book {
        let ds: DocumentStore
        let store: ProjectStore
        let registry: ProjectRegistry
        let id: String
        let cash: FigureRecord
        let spare: FigureRecord
    }

    /// Two chapters, both placing `cash` (Item | Amount / Rent | 100: text
    /// cells A1, B1, A2); a table `spare` no line uses.
    private func openBook() async throws -> Book {
        try "Opening.\n\n![Cash flows](../figures/cash.csv){#tbl:cash}\n"
            .write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        try "Later.\n\n![Cash again](../figures/cash.csv)\n"
            .write(to: file("manuscript/b.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-a", title: "Chapter A", type: .document, path: "manuscript/a.md"),
                StructureItem(id: "doc-b", title: "Chapter B", type: .document, path: "manuscript/b.md"),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let ds = try await DocumentStore.open(url: projectURL)
        for path in ["manuscript/a.md", "manuscript/b.md"] {
            let doc = try await Document.load(url: file(path), actor: .author, session: "boot", presenter: nil)
            await doc.close()
        }
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = ds
        ds.projectStore = store
        let registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)

        var table = FigureTable(rows: 2, columns: 2)
        table.headerRows = 1
        table.setCell(Cell(content: .value(.text("Item"))), at: CellKey(row: table.rows[0], column: table.columns[0]))
        table.setCell(Cell(content: .value(.text("Amount"))), at: CellKey(row: table.rows[0], column: table.columns[1]))
        table.setCell(Cell(content: .value(.text("Rent"))), at: CellKey(row: table.rows[1], column: table.columns[0]))
        table.setCell(Cell(content: .value(.number(100))), at: CellKey(row: table.rows[1], column: table.columns[1]))
        let cash = try await store.createFigure(kind: .table, name: "cash", piece: nil, table: table)
        let spare = try await store.createFigure(kind: .table, name: "spare", piece: nil, table: table)
        await ds.awaitOpenFigureRenderForTesting()
        return Book(ds: ds, store: store, registry: registry,
                    id: ProjectIdentifier.id(for: projectURL), cash: cash, spare: spare)
    }

    private func json(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj)
    }

    private func write(_ book: Book, document: String, _ entries: [[String: Any]]) async throws {
        _ = try await WriteTranslationTool.handle(paramsJSON: try json([
            "project_id": book.id, "document_id": document, "language": "es", "entries": entries,
        ]), registry: book.registry)
    }

    /// Every paragraph of `docId` translated into es (verbatim: fresh).
    private func translateParagraphs(_ book: Book, _ docId: String) async throws {
        let state = try currentParagraphState(projectId: book.id, documentId: docId, registry: book.registry)
        try await write(book, document: docId, state.sequence.map { ["paragraph_id": $0, "verbatim": true] })
    }

    private func check(_ book: Book, excluding: Set<String> = [], figures: PublishFigures? = nil)
        async throws -> TranslationCoverage.Report {
        let snapshot: PublishFigures
        if let figures { snapshot = figures } else { snapshot = await book.store.publishFigures() }
        return try TranslationCoverage.check(
            projectStore: book.store, language: "es", excludedSectionIDs: excluding, figures: snapshot)
    }

    // MARK: - The gate

    /// **Missing cells block, and a table in two chapters is one gap** —
    /// named by A1 in the gate's own sentence; the unused table never counts.
    func test_missingCellsOfAUsedTableBlock_once_forTwoPieces() async throws {
        let book = try await openBook()
        try await translateParagraphs(book, "doc-a")
        try await translateParagraphs(book, "doc-b")

        let report = try await check(book)
        XCTAssertTrue(report.gaps.isEmpty, "premise: every paragraph is translated: \(report.gaps)")
        XCTAssertEqual(report.figureGaps, [
            .init(figureId: book.cash.id, name: "cash", stale: [], missing: ["A1", "B1", "A2"]),
        ], "cash once, though two chapters use it; spare is unused")
        XCTAssertNil(report.zeroLayerError)
        guard case .blocked(let errors, let excerpt) = TranslationCoverage.applyGate(
            report: report, language: "es", allowStale: false) else { return XCTFail("not blocked") }
        XCTAssertEqual(errors.map(\.message), ["Table cash: A1, B1, A2 untranslated"])
        XCTAssertEqual(excerpt, "translation_stale: es")
    }

    /// **A stale cell blocks; `allow_stale` falls back with the usual
    /// suffix** (Review Focus 2): "Rent" edited to "Rents" after translation.
    func test_aStaleCellBlocks_andAllowStaleFallsBackWithTheUsualWarning() async throws {
        let book = try await openBook()
        try await translateParagraphs(book, "doc-a")
        try await translateParagraphs(book, "doc-b")
        try await write(book, document: book.cash.id, [
            ["a1": "A1", "text": "Concepto"], ["a1": "B1", "text": "Importe"], ["a1": "A2", "text": "Alquiler"],
        ])
        let clean = try await check(book)
        XCTAssertFalse(clean.isBlocked, "\(clean.figureGaps)")
        guard case .passed(let none) = TranslationCoverage.applyGate(
            report: clean, language: "es", allowStale: true) else { return XCTFail("blocked") }
        XCTAssertTrue(none.isEmpty, "\(none.map(\.message))")

        let host = try await book.ds.openFigure(figureId: book.cash.id)
        let rent = CellKey(row: host.state.table.rows[1], column: host.state.table.columns[0])
        try await host.setCell(Cell(content: .value(.text("Rents"))), at: rent)
        await book.ds.awaitOpenFigureRenderForTesting()

        let stale = try await check(book)
        XCTAssertEqual(stale.figureGaps, [.init(figureId: book.cash.id, name: "cash", stale: ["A2"], missing: [])])
        guard case .blocked(let errors, _) = TranslationCoverage.applyGate(
            report: stale, language: "es", allowStale: false) else { return XCTFail("not blocked") }
        XCTAssertEqual(errors.map(\.message), ["Table cash: A2 stale"])

        let snapshot = await book.store.publishFigures()
        guard case .passed(let warnings) = try TranslationCoverage.gateEveryTongue(
            projectStore: book.store, figures: snapshot, tags: ["es"],
            excludedSectionIDs: [], allowStale: true) else { return XCTFail("blocked under allow_stale") }
        XCTAssertEqual(warnings.map(\.message),
                       ["[es] Table cash: A2 stale" + TranslationCoverage.sourceTextFallbackSuffix])
        XCTAssertTrue(warnings.allSatisfy(TranslationCoverage.isSourceTextFallback))
        await book.ds.closeFigure(figureId: book.cash.id)
    }

    /// **Only unparked tables of included pieces count**: excluding one of the
    /// two chapters keeps the gap (the other still uses cash); excluding both,
    /// or the table parked, gates no cell.
    func test_aParkedTableOrOneOnlyInExcludedPiecesIsNotGated() async throws {
        let book = try await openBook()
        try await translateParagraphs(book, "doc-a")
        try await translateParagraphs(book, "doc-b")

        let oneExcluded = try await check(book, excluding: ["doc-a"])
        XCTAssertEqual(oneExcluded.figureGaps.map(\.figureId), [book.cash.id])
        let bothExcluded = try await check(book, excluding: ["doc-a", "doc-b"])
        XCTAssertTrue(bothExcluded.figureGaps.isEmpty, "\(bothExcluded.figureGaps)")

        var parked = await book.store.publishFigures()
        parked.parked.insert(book.cash.id)
        let report = try await check(book, figures: parked)
        XCTAssertTrue(report.figureGaps.isEmpty, "\(report.figureGaps)")
        XCTAssertFalse(report.isBlocked)
    }

    /// **The table's records count toward the layer**: a book whose only es
    /// translation is a table cell has a layer, so the gate itemises the
    /// untranslated paragraphs rather than refusing as "no translation layer".
    func test_aCellTranslationAloneIsATranslationLayer() async throws {
        let book = try await openBook()
        try await write(book, document: book.cash.id, [["a1": "A1", "text": "Concepto"]])
        let report = try await check(book)
        XCTAssertNil(report.zeroLayerError)
        XCTAssertEqual(Set(report.gaps.map(\.pieceID)), ["doc-a", "doc-b"])
        XCTAssertEqual(report.figureGaps.first?.missing, ["B1", "A2"])
    }

    // MARK: - Status agrees with the gate

    /// **The desk, `translation_status` and the gate count the same things**:
    /// chapter A translated, chapter B with no file at all, cash untranslated.
    /// The gate refuses over B's paragraphs and cash's three cells; the status
    /// counts B's paragraphs `missing` (not zero: es has a layer in this book)
    /// and cash's three cells, once.
    func test_statusCountsWhatTheGateRefusesOver() async throws {
        let book = try await openBook()
        try await translateParagraphs(book, "doc-a")

        let report = try await check(book)
        let gateMissing = report.gaps.reduce(0) { $0 + $1.missing.count }
        let gateStale = report.gaps.reduce(0) { $0 + $1.stale.count }
        let gateCells = report.figureGaps.reduce(0) { $0 + $1.missing.count + $1.stale.count }
        XCTAssertEqual(report.gaps.map(\.pieceID), ["doc-b"])
        XCTAssertEqual(gateCells, 3)

        let data = try await TranslationStatusTool.handle(
            paramsJSON: try json(["project_id": book.id]), registry: book.registry)
        let status = try JSONDecoder().decode(TranslationStatusTool.Result.self, from: data)
        let docB = try XCTUnwrap(status.rows.first { $0.document_id == "doc-b" && $0.language == "es" },
                                 "a chapter with no file of its own still reports the edition's language")
        XCTAssertEqual(docB.missing, gateMissing, "doc-b's paragraphs, as the gate counts them")
        XCTAssertEqual(status.rows.reduce(0) { $0 + $1.missing }, gateMissing)
        XCTAssertEqual(status.rows.reduce(0) { $0 + $1.stale }, gateStale)
        XCTAssertEqual(status.figures, [
            .init(figure_id: book.cash.id, name: "cash", language: "es",
                  fresh: 0, stale: 0, missing: 3, verbatim: 0, orphans: 0),
        ], "cash once; spare unused")

        let desk = await EditionStatus.languageRows(in: book.store, projectURL: projectURL)
        let es = try XCTUnwrap(desk.rows.first { $0.language == "es" })
        XCTAssertEqual(es.missing, gateMissing + gateCells, "the desk's missing is everything the gate names")
        XCTAssertEqual(es.stale, gateStale)
        XCTAssertTrue(desk.unreadable.isEmpty, "\(desk.unreadable)")
    }

    /// **No layer anywhere is "not started", as the gate's zero-layer guard
    /// says**: a translator named for fr, nothing written — the gate refuses
    /// as "no translation layer" and the status reports zeros, documents and
    /// table alike.
    func test_aLanguageWithNoLayerReadsNotStartedForDocumentsAndTables() async throws {
        let book = try await openBook()
        _ = try await book.store.translatorRole(for: "fr")
        let snapshot = await book.store.publishFigures()
        let fr = try TranslationCoverage.check(projectStore: book.store, language: "fr", figures: snapshot)
        XCTAssertNotNil(fr.zeroLayerError)

        let data = try await TranslationStatusTool.handle(
            paramsJSON: try json(["project_id": book.id]), registry: book.registry)
        let status = try JSONDecoder().decode(TranslationStatusTool.Result.self, from: data)
        let rows = status.rows.filter { $0.language == "fr" }
        XCTAssertEqual(Set(rows.map(\.document_id)), ["doc-a", "doc-b"])
        XCTAssertTrue(rows.allSatisfy { $0.fresh + $0.stale + $0.missing == 0 }, "\(rows)")
        XCTAssertEqual(status.figures, [
            .init(figure_id: book.cash.id, name: "cash", language: "fr",
                  fresh: 0, stale: 0, missing: 0, verbatim: 0, orphans: 0),
        ])
    }
}
