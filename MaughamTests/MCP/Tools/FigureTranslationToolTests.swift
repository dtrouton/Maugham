import XCTest
@testable import MaughamCore
@testable import Maugham

/// Report plan 9e-1 Task 4: `write_translation`, `read_translation` and
/// `translation_status` over a table figure's text cells, addressed by A1 on
/// the wire and stored by id (ruling R8).
@MainActor
final class FigureTranslationToolTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figtranslate-\(UUID().uuidString)")
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

    /// One chapter whose second line places `cash` (Item | Amount, Rent | 100,
    /// Food | 200); a second table `spare` no line uses.
    private func openBook() async throws -> Book {
        try "Opening.\n\n![Cash flow](../figures/cash.csv){#tbl:cash}\n"
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
        let registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)

        var table = FigureTable(rows: 3, columns: 2)
        table.headerRows = 1
        let texts = [["Item", "Amount"], ["Rent", nil], ["Food", nil]]
        for (r, row) in texts.enumerated() {
            for (c, text) in row.enumerated() {
                let key = CellKey(row: table.rows[r], column: table.columns[c])
                table.setCell(Cell(content: .value(text.map { .text($0) } ?? .number(Double(r * 100)))),
                              at: key)
            }
        }
        let cash = try await store.createFigure(kind: .table, name: "cash", piece: nil, table: table)
        let spare = try await store.createFigure(kind: .table, name: "spare", piece: nil, table: table)
        await ds.awaitOpenFigureRenderForTesting()
        return Book(ds: ds, store: store, registry: registry,
                    id: ProjectIdentifier.id(for: projectURL), cash: cash, spare: spare)
    }

    private func json(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj)
    }

    @discardableResult
    private func write(_ book: Book, _ entries: [[String: Any]], figure: String? = nil)
        async throws -> WriteTranslationTool.Result {
        let data = try await WriteTranslationTool.handle(paramsJSON: try json([
            "project_id": book.id, "document_id": figure ?? book.cash.id,
            "language": "es", "entries": entries,
        ]), registry: book.registry)
        return try JSONDecoder().decode(WriteTranslationTool.Result.self, from: data)
    }

    private func read(_ book: Book, status: String? = nil) async throws -> ReadTranslationTool.Result {
        var params: [String: Any] = ["project_id": book.id, "document_id": book.cash.id, "language": "es"]
        if let status { params["status"] = status }
        let data = try await ReadTranslationTool.handle(paramsJSON: try json(params), registry: book.registry)
        return try JSONDecoder().decode(ReadTranslationTool.Result.self, from: data)
    }

    private func status(_ book: Book, documentId: String? = nil) async throws -> TranslationStatusTool.Result {
        var params: [String: Any] = ["project_id": book.id]
        if let documentId { params["document_id"] = documentId }
        let data = try await TranslationStatusTool.handle(paramsJSON: try json(params), registry: book.registry)
        return try JSONDecoder().decode(TranslationStatusTool.Result.self, from: data)
    }

    private func assertRefused(
        _ book: Book, _ entries: [[String: Any]], saying fragment: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await write(book, entries)
            XCTFail("accepted", file: file, line: line)
        } catch MCPError.invalidArgument(let message) {
            XCTAssertTrue(message.contains(fragment), message, file: file, line: line)
        } catch {
            XCTFail("threw \(error)", file: file, line: line)
        }
        XCTAssertTrue(TranslationStore.fileURLs(forDocId: book.cash.id, language: "es", in: projectURL)
            .isEmpty, "nothing written", file: file, line: line)
    }

    // MARK: - Tests

    /// **Written by A1, read back fresh by A1** — the store holds ids, the
    /// wire speaks addresses; numbers are never listed.
    func test_aCellWrittenByA1ReadsBackFresh() async throws {
        let book = try await openBook()
        let result = try await write(book, [
            ["a1": "A1", "text": "Concepto"],
            ["a1": "b1", "text": "Importe"],
            ["a1": "A2", "verbatim": true],
        ])
        XCTAssertEqual(result.written, 3)

        let stored = try TranslationStore.loadMerged(forDocId: book.cash.id, language: "es", in: projectURL)
        XCTAssertTrue(stored.allSatisfy { FigureCellTranslationKey.cellKey(fromParagraphId: $0.paragraphId) != nil },
                      "ids stored: \(stored.map(\.paragraphId))")

        let back = try await read(book)
        XCTAssertEqual(back.entries, [])
        let cells = try XCTUnwrap(back.cells)
        XCTAssertEqual(cells.map(\.a1), ["A1", "B1", "A2", "A3"], "text cells, row by row; no numbers")
        XCTAssertEqual(cells[0], .init(a1: "A1", source_text: "Item", translated_text: "Concepto",
                                       status: "fresh", verbatim: false))
        XCTAssertEqual(cells[2].translated_text, "Rent")
        XCTAssertEqual(cells[3].status, "missing")
        XCTAssertEqual(back.orphans, [])
        let missing = try await read(book, status: "missing")
        XCTAssertEqual(missing.cells?.map(\.a1), ["A3"])
    }

    /// **A source label edited after translation reads stale**, and a label
    /// turned into a number leaves an orphan that `cell` deletes.
    func test_aSourceEditReadsStaleAndAnOrphanIsDeletedByItsCellKey() async throws {
        let book = try await openBook()
        try await write(book, [["a1": "A1", "text": "Concepto"], ["a1": "A3", "text": "Comida"]])

        let host = try await book.ds.openFigure(figureId: book.cash.id)
        let table = host.state.table
        try await host.setCell(Cell(content: .value(.text("Items"))),
                               at: CellKey(row: table.rows[0], column: table.columns[0]))
        try await host.setCell(Cell(content: .value(.number(7))),
                               at: CellKey(row: table.rows[2], column: table.columns[0]))

        let back = try await read(book)
        XCTAssertEqual(back.cells?.first { $0.a1 == "A1" }?.status, "stale")
        XCTAssertEqual(back.cells?.first { $0.a1 == "A1" }?.source_text, "Items")
        XCTAssertNil(back.cells?.first { $0.a1 == "A3" }, "a number is not a text cell")
        let orphan = try XCTUnwrap(back.orphans?.first)
        XCTAssertEqual(orphan.a1, "A3")
        XCTAssertEqual(orphan.translated_text, "Comida")
        XCTAssertEqual(back.orphan_count, 1)

        try await write(book, [["cell": orphan.cell, "delete": true]])
        let purged = try await read(book)
        XCTAssertEqual(purged.orphans, [], "purged")
        await book.ds.closeFigure(figureId: book.cash.id)
    }

    /// **Addresses are validated against the current table** — outside it,
    /// on a number, or in the wrong field, the batch is refused and nothing
    /// is written.
    func test_badAddressesAreRefusedAndNothingIsWritten() async throws {
        let book = try await openBook()
        await assertRefused(book, [["a1": "A1", "text": "Concepto"], ["a1": "Z9", "text": "x"]],
                            saying: "not cells inside 'cash' (3 rows, 2 columns): Z9")
        await assertRefused(book, [["a1": "B2", "text": "cien"]], saying: "not text cells: B2")
        await assertRefused(book, [["paragraph_id": "k7mq", "text": "x"]],
                            saying: "'cash' is a table: address each cell by `a1`")
        await assertRefused(book, [["cell": "aaaaaaaa:bbbbbbbb", "text": "x"]],
                            saying: "`cell` names an orphan to delete")

        do {
            _ = try await WriteTranslationTool.handle(paramsJSON: try json([
                "project_id": book.id, "document_id": "doc-a", "language": "es",
                "entries": [["a1": "A1", "text": "x"]],
            ]), registry: book.registry)
            XCTFail("an A1 on a document was accepted")
        } catch MCPError.invalidArgument(let message) {
            XCTAssertTrue(message.contains("a document's entries use `paragraph_id`"), message)
        }
        do {
            try await write(book, [["a1": "A1", "text": "x"]], figure: "fig-0000dead")
            XCTFail("an unknown figure was accepted")
        } catch MCPError.invalidArgument(let message) {
            XCTAssertTrue(message.contains("is not a figure in this book"), message)
        }
    }

    /// **`translation_status` lists the used figures with cell counts** — an
    /// unused figure is left out, and an edition language the figure has no
    /// file in counts its every text cell missing.
    func test_translationStatusListsUsedFiguresWithCounts() async throws {
        let book = try await openBook()
        let before = try await status(book)
        XCTAssertEqual(before.figures, [], "no edition yet: no rows")

        // An edition: one paragraph of the chapter in es, then one of cash's cells.
        let state = try currentParagraphState(
            projectId: book.id, documentId: "doc-a", registry: book.registry)
        _ = try await WriteTranslationTool.handle(paramsJSON: try json([
            "project_id": book.id, "document_id": "doc-a", "language": "es",
            "entries": [["paragraph_id": state.sequence[0], "text": "Apertura."]],
        ]), registry: book.registry)
        let opened = try await status(book)
        XCTAssertEqual(opened.figures, [
            .init(figure_id: book.cash.id, name: "cash", language: "es",
                  fresh: 0, stale: 0, missing: 4, verbatim: 0, orphans: 0),
        ], "the edition's language counts the untranslated table missing; spare is unused")

        try await write(book, [["a1": "A1", "text": "Concepto"], ["a1": "A2", "verbatim": true]])
        let figures = try await status(book, documentId: "doc-a").figures
        XCTAssertEqual(figures, [
            .init(figure_id: book.cash.id, name: "cash", language: "es",
                  fresh: 2, stale: 0, missing: 2, verbatim: 1, orphans: 0),
        ])
        XCTAssertFalse(figures.contains { $0.figure_id == book.spare.id })
    }

    /// **`translation_status` given a figure id points at `figures`** (report
    /// plan 9e-1 final fix wave, M3) — `write_translation` and
    /// `read_translation` take a table's id, so Claude will try this one with
    /// it too; "not found in project manifest" would send it hunting for a
    /// document that was never missing. A made-up id still says not found.
    ///
    /// The disable experiment: drop the `isFigureDocId` branch in
    /// `TranslationStatusTool` and the first assertion fails on "document_id
    /// not found in project manifest".
    func test_translationStatusGivenAFigureIdPointsAtTheFiguresSection() async throws {
        let book = try await openBook()
        do {
            _ = try await status(book, documentId: book.cash.id)
            XCTFail("a figure id was accepted as a document")
        } catch MCPError.invalidArgument(let message) {
            XCTAssertTrue(message.contains("`figures` section"), message)
            XCTAssertTrue(message.contains(book.cash.id), message)
            XCTAssertFalse(message.contains("not found in project manifest"), message)
        }
        do {
            _ = try await status(book, documentId: "doc-zz")
            XCTFail("a made-up id was accepted")
        } catch MCPError.invalidArgument(let message) {
            XCTAssertEqual(message, "document_id not found in project manifest: doc-zz")
        }
    }
}
