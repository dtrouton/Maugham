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

    func test_paragraphOutputCarriesNoFigureKeys() async throws {
        let book = try await openBook()
        let items = try await list(book, #""document_id":"doc-a","statuses":["open"]"#)
        XCTAssertTrue(items.isEmpty)
        let bad = try? await list(book, #""figure":"tbl:cash","document_id":"doc-a""#)
        XCTAssertNil(bad, "both forms is refused")
    }
}
