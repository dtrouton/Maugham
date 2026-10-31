import XCTest
@testable import MaughamCore
@testable import Maugham

/// Report plan 9b Task 7: `list_figures`, the read-only figure listing.
@MainActor
final class ListFiguresToolTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("listfigures-\(UUID().uuidString)")
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
    }

    /// One chapter; the figures are made by the test.
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
        return Book(ds: ds, store: store, registry: registry, id: ProjectIdentifier.id(for: projectURL))
    }

    private func call(_ book: Book, kind: String? = nil) async throws -> [ListFiguresTool.Figure] {
        let kindPart = kind.map { ",\"kind\":\"\($0)\"" } ?? ""
        let json = try await ListFiguresTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(book.id)\"\(kindPart)}".utf8), registry: book.registry)
        return try JSONDecoder().decode(ListFiguresTool.Result.self, from: json).figures
    }

    /// A table whose A1 reads `research:model!B2*2`, through its open host.
    private func pinnedTable(_ book: Book, named name: String, csv: URL) async throws -> (FigureRecord, ResearchItem) {
        let item = try await book.store.addResearchAsset(parentId: nil, fromURL: csv)
        let record = try await book.store.createFigure(kind: .table, name: name, piece: nil)
        let host = try await book.ds.openFigure(figureId: record.id)
        let a1 = CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
        let names = FormulaNames(research: [(item.id, item.title)])
        guard case .success(let f) = FormulaParser.parse("research:model!B2*2", in: host.state.table, names: names)
        else { throw FigureEditInvalid(reason: "the formula did not parse") }
        try await host.setCell(Cell(content: .formula(f)), at: a1)
        await book.ds.awaitOpenFigureRenderForTesting()
        await book.ds.closeFigure(figureId: record.id)
        return (record, item)
    }

    private func outsideCSV(_ body: String) throws -> URL {
        let outside = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let csv = outside.appendingPathComponent("model.csv")
        try Data(body.utf8).write(to: csv)
        return csv
    }

    /// Every file under the project's op-log directory with its bytes.
    private func opLogSnapshot() -> [String: Data] {
        let root = file(".maugham/ops")
        var out: [String: Data] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if let data = try? Data(contentsOf: url) { out[url.path] = data }
        }
        return out
    }

    func test_aUsedTableAnUnusedImageAndAParkedTableAreThreeEntries() async throws {
        let book = try await openBook()
        let cash = try await book.store.createFigure(kind: .table, name: "cash", piece: nil)
        let photo = try await book.store.createFigure(kind: .image, name: "photo", piece: nil)
        let shelved = try await book.store.createFigure(kind: .table, name: "shelved", piece: nil)
        _ = try await book.store.sendToResearch(figureId: shelved.id, scope: .shared)
        await book.ds.awaitOpenFigureRenderForTesting()

        let figures = try await call(book)
        XCTAssertEqual(Set(figures.map(\.id)), [cash.id, photo.id, shelved.id])
        let byId = Dictionary(uniqueKeysWithValues: figures.map { ($0.id, $0) })
        let used = try XCTUnwrap(byId[cash.id])
        XCTAssertEqual(used.status, "used")
        XCTAssertEqual(used.kind, "table")
        XCTAssertEqual(used.number, "Table 1")
        XCTAssertEqual(used.caption, "Cash flow")
        XCTAssertEqual(used.used_in, [ListFiguresTool.Use(document: "Chapter A", document_id: "doc-a", line: 2)])
        XCTAssertFalse(used.reads_research)
        XCTAssertFalse(used.changed)
        let unused = try XCTUnwrap(byId[photo.id])
        XCTAssertEqual(unused.status, "unused")
        XCTAssertEqual(unused.kind, "image")
        XCTAssertEqual(unused.number, "—")
        XCTAssertEqual(try XCTUnwrap(byId[shelved.id]).status, "in_research")

        let tables = try await call(book, kind: "table")
        XCTAssertEqual(Set(tables.map(\.id)), [cash.id, shelved.id])
        let images = try await call(book, kind: "image")
        XCTAssertEqual(images.map(\.id), [photo.id])
        await book.ds.close()
    }

    func test_aPinnedFiguresChangedResearchSourceReportsChanged() async throws {
        let book = try await openBook()
        let csv = try outsideCSV("Year,Revenue\n2025,10\n2026,20\n")
        let (record, item) = try await pinnedTable(book, named: "summary", csv: csv)

        var figure = try await call(book).first { $0.id == record.id }
        XCTAssertEqual(figure?.pins, [ListFiguresTool.Pin(source: item.id, source_name: item.title, status: "current")])
        XCTAssertEqual(figure?.reads_research, true)
        XCTAssertEqual(figure?.changed, false)

        try Data("Year,Revenue\n2025,10\n2026,99\n".utf8).write(to: file(try XCTUnwrap(item.path)))
        figure = try await call(book).first { $0.id == record.id }
        XCTAssertEqual(figure?.pins.map(\.status), ["source_changed"])
        XCTAssertEqual(figure?.changed, true)
        await book.ds.close()
    }

    func test_theToolWritesNothing() async throws {
        let book = try await openBook()
        _ = try await book.store.createFigure(kind: .table, name: "cash", piece: nil)
        await book.ds.awaitOpenFigureRenderForTesting()
        let manifestBefore = try Data(contentsOf: file(ProjectManifest.fileName))
        let before = opLogSnapshot()
        XCTAssertFalse(before.isEmpty, "premise: there are op logs to compare")
        _ = try await call(book)
        XCTAssertEqual(opLogSnapshot(), before)
        XCTAssertEqual(try Data(contentsOf: file(ProjectManifest.fileName)), manifestBefore)
        await book.ds.close()
    }

    func test_anUnknownKindIsRefused() async throws {
        let book = try await openBook()
        do {
            _ = try await call(book, kind: "chart")
            XCTFail("expected a refusal")
        } catch {}
        await book.ds.close()
    }
}
