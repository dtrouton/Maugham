import XCTest
@testable import MaughamCore
@testable import Maugham

/// Report plan 9c-1 Task 6: `list_annotations` and `get_annotation` read the notes on
/// a table figure: where they sit now, whether they are orphaned, what a suggestion proposes.
@MainActor
final class FigureAnnotationReadTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figread-\(UUID().uuidString)")
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
        let paragraphId: String
    }

    /// A book with a 3x3 table `cash` (B2 = 100) and one image-less registry.
    private func openBook(alsoInA: String = "") async throws -> Book {
        try ("Opening.\n\n![Cash flow](../figures/cash.csv){#tbl:cash}\n" + alsoInA).write(
            to: projectURL.appendingPathComponent("manuscript/a.md"), atomically: true, encoding: .utf8)
        try "Elsewhere.\n".write(to: projectURL.appendingPathComponent("manuscript/b.md"),
                                 atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md"),
                        StructureItem(id: "doc-b", title: "B", type: .document, path: "manuscript/b.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        let ds = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: projectURL.appendingPathComponent("manuscript/a.md"),
            actor: .author, session: "boot", presenter: nil)
        let paragraphId = try await doc.opLog().first(where: { $0.kind == .bootstrap })!.changes.first!.paragraphId
        await doc.close()
        let docB = try await Document.load(
            url: projectURL.appendingPathComponent("manuscript/b.md"),
            actor: .author, session: "boot", presenter: nil)
        await docB.close()
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
                    id: ProjectIdentifier.id(for: projectURL), figure: figure,
                    paragraphId: paragraphId)
    }

    private func make<T: MCPTool>(_ tool: T.Type, _ book: Book, _ rest: String) async throws -> String {
        let data = Data("{\"project_id\":\"\(book.id)\",\(rest)}".utf8)
        let out = try await tool.handle(paramsJSON: data, registry: book.registry)
        return try JSONDecoder().decode([String: String].self, from: out)["annotation_id"] ?? ""
    }

    private func list(_ book: Book, _ rest: String) async throws -> [[String: Any]] {
        let data = Data("{\"project_id\":\"\(book.id)\",\(rest)}".utf8)
        let out = try await ListAnnotationsTool.handle(paramsJSON: data, registry: book.registry)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [[String: Any]])
    }

    private func get(_ book: Book, _ rest: String) async throws -> [String: Any] {
        let data = Data("{\"project_id\":\"\(book.id)\",\(rest)}".utf8)
        let out = try await GetAnnotationTool.handle(paramsJSON: data, registry: book.registry)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    // MARK: - Anchors by current positions

    func test_aSuggestionReadsItsCellAndFollowsAnInsert() async throws {
        let book = try await openBook()
        let id = try await make(AddSuggestedChangeTool.self, book,
                                #""figure":"tbl:cash!C3","body":"Sum","suggested_value":"=SUM(B2:B3)""#)
        var items = try await list(book, #""figure":"tbl:cash""#)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["figure_anchor"] as? String, "tbl:cash!C3")
        XCTAssertEqual(items[0]["orphaned"] as? Bool, false)
        let cell = try XCTUnwrap(items[0]["suggested_cell"] as? [String: Any])
        XCTAssertEqual(cell["formula"] as? String, "=SUM(B2:B3)")
        XCTAssertEqual(cell["value"] as? String, "100")
        let raw = try XCTUnwrap(cell["raw"] as? [String: Any])
        XCTAssertEqual(raw["type"] as? String, "number")
        XCTAssertEqual(raw["value"] as? Double, 100)

        let t = try await book.ds.withFigureHost(book.figure.id) { $0.state.table }
        _ = try await book.ds.withFigureHost(book.figure.id) { try await $0.insertRow(after: t.rows[0]) }
        items = try await list(book, #""document_id":"\#(book.figure.id)""#)
        XCTAssertEqual(items.first?["figure_anchor"] as? String, "tbl:cash!C4", "by current positions, and the figure id works as document_id")

        let one = try await get(book, #""figure":"tbl:cash","annotation_id":"\#(id)""#)
        XCTAssertEqual(one["figure_anchor"] as? String, "tbl:cash!C4")
        XCTAssertNotNil(one["suggested_cell"])
        XCTAssertFalse((one["history"] as? [Any] ?? []).isEmpty, "the creation op is in the history")
    }

    func test_aWholeFigureNoteReadsTheLabelAlone() async throws {
        let book = try await openBook()
        _ = try await make(AddCommentTool.self, book, #""figure":"tbl:cash","body":"Whole""#)
        let items = try await list(book, #""figure":"cash""#)
        XCTAssertEqual(items.first?["figure_anchor"] as? String, "tbl:cash")
        XCTAssertNil(items.first?["suggested_cell"])
    }

    func test_anOrphanedNoteReadsOrphanedTrue() async throws {
        let book = try await openBook()
        _ = try await make(AddSuggestedChangeTool.self, book,
                           #""figure":"tbl:cash!C3","body":"Sum","suggested_value":"5""#)
        let t = try await book.ds.withFigureHost(book.figure.id) { $0.state.table }
        try await book.ds.withFigureHost(book.figure.id) { try await $0.deleteRow(t.rows[2]) }
        let items = try await list(book, #""figure":"tbl:cash""#)
        XCTAssertEqual(items.first?["orphaned"] as? Bool, true)
        XCTAssertEqual(items.first?["figure_anchor"] as? String, "tbl:cash")
        XCTAssertEqual(items.first?["is_stale"] as? Bool, true)
        XCTAssertNotNil(items.first?["suggested_cell"])
    }

    func test_statusAfterAcceptIsAccepted() async throws {
        let book = try await openBook()
        let id = try await make(AddSuggestedChangeTool.self, book,
                                #""figure":"tbl:cash!B2","body":"Typo","suggested_value":"1234.5""#)
        try await book.ds.withFigureHost(book.figure.id) { try await $0.acceptSuggestion(id: id, confirmChanged: true) }
        let openNow = try await list(book, #""figure":"tbl:cash""#)
        XCTAssertTrue(openNow.isEmpty, "open by default")
        let items = try await list(book, #""figure":"tbl:cash","statuses":["accepted"]"#)
        XCTAssertEqual(items.first?["status"] as? String, "accepted")
        let one = try await get(book, #""document_id":"\#(book.figure.id)","annotation_id":"\#(id)""#)
        XCTAssertEqual(one["status"] as? String, "accepted")
        let kinds = (one["history"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
        XCTAssertTrue(kinds.contains("claude_accept"), "\(kinds)")
    }

    // MARK: - A document's list

    private let figureKeys = ["figure_anchor", "orphaned", "suggested_cell"]

    func test_aDocumentListCarriesTheNotesOnTheFiguresItUses() async throws {
        let book = try await openBook()
        _ = try await make(AddCommentTool.self, book, #""figure":"tbl:cash","body":"Whole figure""#)
        _ = try await make(AddCommentTool.self, book,
                           #""document_id":"doc-a","paragraph_id":"\#(book.paragraphId)","body":"Paragraph""#)

        let items = try await list(book, #""document_id":"doc-a""#)
        XCTAssertEqual(Set(items.compactMap { $0["body"] as? String }), ["Paragraph", "Whole figure"])
        let figureRow = try XCTUnwrap(items.first { $0["body"] as? String == "Whole figure" })
        XCTAssertEqual(figureRow["figure_anchor"] as? String, "tbl:cash")
        let paragraphRow = try XCTUnwrap(items.first { $0["body"] as? String == "Paragraph" })
        for key in figureKeys { XCTAssertNil(paragraphRow[key], "a paragraph note has no \(key)") }
        XCTAssertEqual(paragraphRow["paragraph_id"] as? String, book.paragraphId)

        let other = try await list(book, #""document_id":"doc-b""#)
        XCTAssertTrue(other.isEmpty, "a document that does not use the figure lists neither")

        let narrowed = try await list(book, #""document_id":"doc-a","paragraph_id":"\#(book.paragraphId)""#)
        XCTAssertEqual(narrowed.compactMap { $0["body"] as? String }, ["Paragraph"], "paragraph_id: paragraph note only")

        let queries = try await list(book, #""document_id":"doc-a","kinds":["query"]"#)
        XCTAssertTrue(queries.isEmpty, "kinds apply to the figure rows")
        let archived = try await list(book, #""document_id":"doc-a","statuses":["archived"]"#)
        XCTAssertTrue(archived.isEmpty, "statuses apply to the figure rows")
        let comments = try await list(book, #""document_id":"doc-a","kinds":["comment"]"#)
        XCTAssertEqual(comments.count, 2)
    }

    // MARK: - An image figure (final review I1)

    /// An image takes whole-figure notes (`add_comment` with `fig:photo`), so
    /// both read tools read them back: by `figure`, by the figure's id, and in
    /// the list of a document whose text uses the picture. The anchor is the
    /// label alone; there is no cell.
    func test_aNoteOnAnImageReadsBackByFigureAndThroughTheDocumentUsingIt() async throws {
        let book = try await openBook(alsoInA: "\n![Photo](../figures/photo){#fig:photo}\n")
        let photo = try await book.store.createFigure(kind: .image, name: "photo", piece: nil)
        let id = try await make(AddCommentTool.self, book, #""figure":"fig:photo","body":"Crop it""#)

        let byFigure = try await list(book, #""figure":"fig:photo""#)
        XCTAssertEqual(byFigure.compactMap { $0["body"] as? String }, ["Crop it"])
        XCTAssertEqual(byFigure.first?["figure_anchor"] as? String, "fig:photo")
        XCTAssertNil(byFigure.first?["suggested_cell"])
        let byId = try await list(book, #""document_id":"\#(photo.id)""#)
        XCTAssertEqual(byId.compactMap { $0["body"] as? String }, ["Crop it"])

        let one = try await get(book, #""figure":"fig:photo","annotation_id":"\#(id)""#)
        XCTAssertEqual(one["body"] as? String, "Crop it")
        XCTAssertEqual(one["figure_anchor"] as? String, "fig:photo")

        let inDocument = try await list(book, #""document_id":"doc-a""#)
        XCTAssertTrue(inDocument.contains { $0["body"] as? String == "Crop it" },
                      "a document using the picture lists its notes: \(inDocument)")
    }

    // MARK: - get_annotation by a document's id (final review M4)

    /// A document's `list_annotations` carries the notes on the figures its
    /// text uses; `get_annotation` with that document's id finds each of them.
    func test_getByTheDocumentFindsAFigureNoteItsListReturned() async throws {
        let book = try await openBook()
        let id = try await make(AddSuggestedChangeTool.self, book,
                                #""figure":"tbl:cash!C3","body":"Sum","suggested_value":"5""#)
        let listed = try await list(book, #""document_id":"doc-a""#)
        XCTAssertTrue(listed.contains { $0["id"] as? String == id }, "premise: the document's list returns it")

        let one = try await get(book, #""document_id":"doc-a","annotation_id":"\#(id)""#)
        XCTAssertEqual(one["figure_anchor"] as? String, "tbl:cash!C3")
        XCTAssertNotNil(one["suggested_cell"])
        XCTAssertFalse((one["history"] as? [Any] ?? []).isEmpty)

        do {
            _ = try await get(book, #""document_id":"doc-b","annotation_id":"\#(id)""#)
            XCTFail("a document that does not use the figure does not find its note")
        } catch {
            XCTAssertTrue("\(error)".contains("annotation_id not found"), "\(error)")
        }
    }

    // MARK: - Errors and edges

    func test_getAnUnknownAnnotationOnAFigureIsRefused() async throws {
        let book = try await openBook()
        do {
            _ = try await get(book, #""figure":"tbl:cash","annotation_id":"nope""#)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("annotation_id not found: nope"), "\(error)")
        }
    }

    func test_getOnAnOrphanedNoteReadsOrphaned() async throws {
        let book = try await openBook()
        let id = try await make(AddSuggestedChangeTool.self, book,
                                #""figure":"tbl:cash!C3","body":"Sum","suggested_value":"5""#)
        let t = try await book.ds.withFigureHost(book.figure.id) { $0.state.table }
        try await book.ds.withFigureHost(book.figure.id) { try await $0.deleteRow(t.rows[2]) }
        let one = try await get(book, #""figure":"tbl:cash","annotation_id":"\#(id)""#)
        XCTAssertEqual(one["orphaned"] as? Bool, true)
        XCTAssertEqual(one["figure_anchor"] as? String, "tbl:cash")
        let cell = try XCTUnwrap(one["suggested_cell"] as? [String: Any])
        XCTAssertNotNil(cell["format"], "format rides with the cell as read_figure's does")
    }

    func test_theCallFormsAreRefusedWithTheirMessages() async throws {
        let book = try await openBook()
        func message(_ rest: String) async -> String {
            do { _ = try await list(book, rest); return "" } catch { return "\(error)" }
        }
        let both = await message(#""figure":"tbl:cash","document_id":"doc-a""#)
        XCTAssertTrue(both.contains("not both"), both)
        let neither = await message(#""kinds":["comment"]"#)
        XCTAssertTrue(neither.contains("Pass `document_id` (a document) or `figure` (a figure)"), neither)
    }
}
