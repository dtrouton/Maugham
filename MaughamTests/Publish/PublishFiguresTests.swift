import XCTest
@testable import Maugham
@testable import MaughamCore

/// **One figure snapshot per publish** (report plan 9a Task 1, spec §9):
/// `DocumentStore.publishFigures()` reads the book's figures with no window
/// (an MCP compile, a closed window), lays an open grid's fold over its read,
/// and says which figures are parked and where each pinned source stands; a
/// `ProjectStoreASTSource` carries it in `publishContext()` through a
/// language rebinding.
@MainActor
final class PublishFiguresTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("publishfigures-\(UUID().uuidString)")
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

    // MARK: - Fixture

    /// One chapter bootstrapped by this Mac's hand, and a window's stores.
    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        try "Words.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    /// A table `cash` whose A1 holds 5 and A2 reads `A1*2`, entered through
    /// its open host; returns the host still open.
    private func cash(_ store: DocumentStore, _ projectStore: ProjectStore) async throws
        -> (record: FigureRecord, host: FigureDocument, a1: CellKey, a2: CellKey) {
        let record = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let host = try await store.openFigure(figureId: record.id)
        let a1 = CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
        let a2 = CellKey(row: host.state.table.rows[1], column: host.state.table.columns[0])
        try await host.setCell(Cell(content: .value(.number(5))), at: a1)
        guard case .success(let f) = FormulaParser.parse("A1*2", in: host.state.table)
        else { throw FigureEditInvalid(reason: "the formula did not parse") }
        try await host.setCell(Cell(content: .formula(f)), at: a2)
        await store.awaitOpenFigureRenderForTesting()
        return (record, host, a1, a2)
    }

    // MARK: - Tests

    /// **A closed window still snapshots the figures**: the store has no
    /// presenter (the window's cards would answer nil), and the publish still
    /// reads the table and its formula's computed value.
    func test_aClosedWindowStillSnapshotsTheFigures() async throws {
        let (store, projectStore) = try await openBook()
        let (record, _, _, a2) = try await cash(store, projectStore)
        await store.closeFigure(figureId: record.id)
        await store.close()
        XCTAssertNil(store.presenter, "premise: no window")
        let cards = await store.figureCardInputs()
        XCTAssertNil(cards, "premise: the window's cards read nothing without a presenter")

        let figures = await store.publishFigures()
        XCTAssertEqual(figures.records.map(\.id), [record.id])
        XCTAssertNotNil(figures.states[record.id]?.table)
        XCTAssertEqual(figures.workbook?.value(at: CellAddress(table: record.id, key: a2)), .number(10))
        XCTAssertTrue(figures.parked.isEmpty)
    }

    /// **An open grid's edit, not yet rendered, is what publishes**: the
    /// snapshot lays the host's fold over the cache's read.
    func test_anOpenGridsUnfoldedEditIsWhatPublishes() async throws {
        let (store, projectStore) = try await openBook()
        let (record, host, a1, a2) = try await cash(store, projectStore)
        try await host.setCell(Cell(content: .value(.number(7))), at: a1)

        let figures = await store.publishFigures()
        XCTAssertEqual(figures.workbook?.value(at: CellAddress(table: record.id, key: a1)), .number(7))
        XCTAssertEqual(figures.workbook?.value(at: CellAddress(table: record.id, key: a2)), .number(14))
        await store.closeFigure(figureId: record.id)
    }

    /// **A figure sent to Research is listed parked.**
    func test_aParkedFigureIsListedParked() async throws {
        let (store, projectStore) = try await openBook()
        let (record, _, _, _) = try await cash(store, projectStore)
        let other = try await projectStore.createFigure(kind: .table, name: "other", piece: nil)
        await store.closeFigure(figureId: record.id)
        _ = try await projectStore.sendToResearch(figureId: record.id, scope: .shared)
        await store.awaitOpenFigureRenderForTesting()

        let figures = await store.publishFigures()
        XCTAssertEqual(figures.parked, [record.id])
        XCTAssertNotNil(figures.states[other.id], "premise: the unparked figure is read too")
    }

    /// **A pinned Research source that is gone is `sourceMissing`.**
    func test_aMissingPinSourceIsSourceMissing() async throws {
        let (store, projectStore) = try await openBook()
        let outside = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let csv = outside.appendingPathComponent("model.csv")
        try Data("Year,Revenue\n2025,10\n2026,20\n".utf8).write(to: csv)
        let item = try await projectStore.addResearchAsset(parentId: nil, fromURL: csv)
        let summary = try await projectStore.createFigure(kind: .table, name: "summary", piece: nil)
        let host = try await store.openFigure(figureId: summary.id)
        let a1 = CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
        let names = FormulaNames(research: [(item.id, item.title)])
        guard case .success(let f) = FormulaParser.parse("research:model!B2*2", in: host.state.table, names: names)
        else { throw FigureEditInvalid(reason: "the formula did not parse") }
        try await host.setCell(Cell(content: .formula(f)), at: a1)
        await store.awaitOpenFigureRenderForTesting()
        XCTAssertNotNil(host.state.pins[a1], "premise: the formula took its pin")

        let before = await store.publishFigures()
        XCTAssertEqual(before.pinStatus[summary.id]?[item.id], .current, "premise: the source reads")

        try FileManager.default.removeItem(at: file(try XCTUnwrap(item.path)))
        let figures = await store.publishFigures()
        XCTAssertEqual(figures.pinStatus[summary.id]?[item.id], .sourceMissing)
        await store.closeFigure(figureId: summary.id)
    }

    /// **The snapshot rides the source through a language rebinding.**
    func test_theSourceCarriesTheSnapshotThroughALanguageRebind() async throws {
        let (store, projectStore) = try await openBook()
        let (record, _, _, _) = try await cash(store, projectStore)
        let figures = await projectStore.publishFigures()
        XCTAssertEqual(figures.records.map(\.id), [record.id], "premise: a snapshot with a figure")

        let source = ProjectStoreASTSource(projectStore: projectStore, figures: figures)
        XCTAssertEqual(source.publishContext().figures.records, figures.records)
        let rebound = source.rebound(toLanguage: "es")
        XCTAssertEqual(rebound.publishContext().figures.records, figures.records)
        await store.closeFigure(figureId: record.id)
    }
}
