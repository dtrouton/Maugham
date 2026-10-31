import XCTest
@testable import MaughamCore
@testable import Maugham

/// Report plan 9c-1 Task 4: `add_comment`, `add_query`, `add_suggested_change`
/// and `add_craft_note` anchor to a table figure through `figure`.
@MainActor
final class FigureAnnotationCreationTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figcreate-\(UUID().uuidString)")
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

    private struct Book {
        let ds: DocumentStore
        let store: ProjectStore
        let registry: ProjectRegistry
        let id: String
        let figure: FigureRecord
    }

    /// A book with a 3x3 table `cash` (B2 = 100) and one image-less registry.
    private func openBook() async throws -> Book {
        try "Opening.\n".write(to: projectURL.appendingPathComponent("manuscript/a.md"),
                               atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        let ds = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: projectURL.appendingPathComponent("manuscript/a.md"),
            actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = ds
        ds.projectStore = store
        let figure = try await store.createFigure(kind: .table, name: "cash", piece: nil)
        let host = try await ds.openFigure(figureId: figure.id)
        let t = host.state.table
        try await host.setCell(Cell(content: .value(.number(100))),
                               at: CellKey(row: t.rows[1], column: t.columns[1]))
        await ds.closeFigure(figureId: figure.id)
        let registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        return Book(ds: ds, store: store, registry: registry,
                    id: ProjectIdentifier.id(for: projectURL), figure: figure)
    }

    private func call<T: MCPTool>(_ tool: T.Type, _ book: Book, _ rest: String) async throws -> String {
        let data = Data("{\"project_id\":\"\(book.id)\",\(rest)}".utf8)
        let out = try await tool.handle(paramsJSON: data, registry: book.registry)
        return try JSONDecoder().decode([String: String].self, from: out)["annotation_id"] ?? ""
    }

    private func failure<T: MCPTool>(_ tool: T.Type, _ book: Book, _ rest: String) async -> String {
        do { _ = try await call(tool, book, rest); return "" } catch { return "\(error)" }
    }

    private func notes(_ book: Book) async -> [Annotation] { await book.store.figureNotes(book.figure.id) }

    /// Every file under `figures/` with its bytes: a note must leave it as it was.
    private func figuresFolder() -> [String: Data] {
        let dir = projectURL.appendingPathComponent("figures")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.map {
            ($0, (try? Data(contentsOf: dir.appendingPathComponent($0))) ?? Data())
        })
    }

    // MARK: - Forms

    func test_aCommentOnACellAnchorsToItsIds() async throws {
        let book = try await openBook()
        let t = try await book.ds.withFigureHost(book.figure.id) { $0.state.table }
        let id = try await call(AddCommentTool.self, book, #""figure":"tbl:cash!B2","body":"Check this""#)
        let found = try await notes(book)
        let note = try XCTUnwrap(found.first)
        XCTAssertEqual(note.id, id)
        XCTAssertEqual(note.kind, .comment)
        XCTAssertEqual(note.author?.sourceKind, .claude)
        XCTAssertEqual(note.figureAnchor, FigureCellAnchor(row: t.rows[1], column: t.columns[1]))
        let stream = try OpLogStore.opLogFileURL(
            forDocId: book.figure.id,
            deviceSlug: DeviceSlug.make(from: Document.loadIdentities[.assistant].deviceId), in: projectURL)
        XCTAssertTrue(try String(contentsOf: stream, encoding: .utf8).contains(id), "the note is in the assistant's own stream")
    }

    func test_aRangeQueryAndAWholeFigureCommentAnchorAsAsked() async throws {
        let book = try await openBook()
        let t = try await book.ds.withFigureHost(book.figure.id) { $0.state.table }
        _ = try await call(AddQueryTool.self, book, #""figure":"tbl:cash!A1:B2","body":"Why?""#)
        _ = try await call(AddCommentTool.self, book, #""figure":"tbl:cash","body":"Whole""#)
        let found = try await notes(book)
        let query = try XCTUnwrap(found.first { $0.kind == .query })
        XCTAssertEqual(query.figureAnchor, FigureCellAnchor(
            row: t.rows[0], rowEnd: t.rows[1], column: t.columns[0], columnEnd: t.columns[1]))
        XCTAssertNil(try XCTUnwrap(found.first { $0.body == "Whole" }).figureAnchor)
    }

    func test_aCraftNoteIsAboutTheWholeFigureAndTakesNoCell() async throws {
        let book = try await openBook()
        _ = try await call(AddCraftNoteTool.self, book, #""figure":"tbl:cash","body":"Totals lead""#)
        let found = try await notes(book)
        XCTAssertEqual(found.map(\.kind), [.craftNote])
        let bad = await failure(AddCraftNoteTool.self, book, #""figure":"tbl:cash!B2","body":"x""#)
        XCTAssertTrue(bad.contains("whole figure"), bad)
    }

    func test_aSuggestionCarriesItsCellInMachineFormAndPriorAndWritesNothing() async throws {
        let book = try await openBook()
        let t = try await book.ds.withFigureHost(book.figure.id) { $0.state.table }
        let key = CellKey(row: t.rows[1], column: t.columns[1])
        let before = figuresFolder()
        _ = try await call(AddSuggestedChangeTool.self, book,
                           #""figure":"tbl:cash!B2","body":"Typo","suggested_value":"1234.5""#)
        _ = try await call(AddSuggestedChangeTool.self, book,
                           #""figure":"tbl:cash!C3","body":"Sum","suggested_value":"=SUM(B2:B3)""#)
        let found = try await notes(book)
        let number = try XCTUnwrap(found.first { $0.body == "Typo" })
        XCTAssertEqual(number.kind, .suggestedChange)
        XCTAssertEqual(number.suggestedCell?.content, .value(.number(1234.5)))
        XCTAssertEqual(number.figureAnchor?.row, key.row)
        let formula = try XCTUnwrap(found.first { $0.body == "Sum" })
        if case .formula? = formula.suggestedCell?.content {} else { XCTFail("a formula") }
        let after = try await book.ds.withFigureHost(book.figure.id) { $0.state.table }
        XCTAssertEqual(after.cells[key]?.content, .value(.number(100)), "the cell is not written")
        XCTAssertEqual(figuresFolder(), before, "a note touches nothing under figures/")
    }

    // MARK: - Errors

    func test_theErrors() async throws {
        let book = try await openBook()
        var msg = await failure(AddCommentTool.self, book, #""figure":"tbl:cahs","body":"x""#)
        XCTAssertTrue(msg.contains("nearest: cash"), msg)
        msg = await failure(AddCommentTool.self, book, #""figure":"fig:cash","body":"x""#)
        XCTAssertTrue(msg.contains("tbl:cash"), "kind mismatch names the label: \(msg)")
        msg = await failure(AddCommentTool.self, book, #""figure":"tbl:cash!Z99","body":"x""#)
        XCTAssertTrue(msg.contains("not a live cell"), msg)
        msg = await failure(AddSuggestedChangeTool.self, book,
                            #""figure":"tbl:cash!A1:B2","body":"x","suggested_value":"1""#)
        XCTAssertTrue(msg.contains("one cell"), msg)
        msg = await failure(AddSuggestedChangeTool.self, book,
                            #""figure":"tbl:cash!A1","body":"x","suggested_value":"=SUM(""#)
        XCTAssertTrue(msg.contains("does not parse"), msg)
        msg = await failure(AddSuggestedChangeTool.self, book,
                            #""figure":"tbl:cash!A1","body":"x","suggested_text":"1""#)
        XCTAssertTrue(msg.contains("suggested_value"), msg)
        msg = await failure(AddCommentTool.self, book,
                            #""figure":"tbl:cash","document_id":"doc-a","paragraph_id":"abcd","body":"x""#)
        XCTAssertTrue(msg.contains("not both"), msg)
        msg = await failure(AddCommentTool.self, book, #""body":"x""#)
        XCTAssertTrue(msg.contains("figure"), msg)
        let none = await notes(book)
        XCTAssertEqual(none, [], "no refusal wrote a note")
    }

    func test_aDeletedRowHasNoAddressAndAParkedFigureRefuses() async throws {
        let book = try await openBook()
        let host = try await book.ds.openFigure(figureId: book.figure.id)
        try await host.deleteRow(host.state.table.rows[2])
        await book.ds.closeFigure(figureId: book.figure.id)
        let msg = await failure(AddCommentTool.self, book, #""figure":"tbl:cash!A3","body":"x""#)
        XCTAssertTrue(msg.contains("not a live cell"), msg)

        _ = try await book.store.sendToResearch(figureId: book.figure.id, scope: .shared)
        let parked = await failure(AddCommentTool.self, book, #""figure":"tbl:cash","body":"x""#)
        XCTAssertTrue(parked.contains("parked"), parked)
        let none = await notes(book)
        XCTAssertEqual(none, [])
    }

    func test_theSchemasRequireNoParagraphFields() {
        for json in [AddCommentTool.inputSchemaJSON, AddQueryTool.inputSchemaJSON,
                     AddSuggestedChangeTool.inputSchemaJSON, AddCraftNoteTool.inputSchemaJSON] {
            XCTAssertTrue(json.contains(#""figure""#))
            XCTAssertTrue(json.contains(#""required":["project_id","body"]"#), json)
        }
    }
}
