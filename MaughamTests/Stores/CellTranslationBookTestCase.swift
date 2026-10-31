import XCTest
@testable import Maugham
@testable import MaughamCore

/// **A book with one translated table** (report plan 9e-1 Tasks 7–9): one
/// chapter whose second paragraph is the line of a table `cash`
/// (Item | Amount / Rent | 100), the window's two stores over it, and cell
/// translations written through the one write door
/// (`TranslationWritePipeline.performCells`). The card, pane and lifecycle
/// suites share it.
@MainActor
class CellTranslationBookTestCase: XCTestCase {

    var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("cellbook-\(UUID().uuidString)")
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

    func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    /// The book, its stores and the table figure's id.
    func openBook() async throws -> (DocumentStore, ProjectStore, String) {
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

    /// The figure's table as the store reads it now.
    func table(_ store: ProjectStore, _ figureId: String) async throws -> FigureTable {
        let figures = await store.publishFigures()
        return try XCTUnwrap(figures.states[figureId]?.table, "premise: the figure reads")
    }

    /// Item (A1) and Rent (A2), the table's two translatable labels.
    func labels(_ table: FigureTable) -> (item: CellKey, rent: CellKey) {
        (CellKey(row: table.rows[0], column: table.columns[0]),
         CellKey(row: table.rows[1], column: table.columns[0]))
    }

    func write(_ entries: [TranslationWritePipeline.CellEntry], language: String = "es",
               figureId: String, table: FigureTable, actor: DeviceActor = .translator) async throws {
        _ = try await TranslationWritePipeline.performCells(
            entries: entries, language: language, figureId: figureId,
            table: table, projectURL: projectURL, actor: actor,
            identities: try XCTUnwrap(Document.localIdentitiesForTesting),
            deviceState: try XCTUnwrap(Document.deviceStateForTesting))
    }
}
