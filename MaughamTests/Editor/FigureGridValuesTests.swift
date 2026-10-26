import XCTest
@testable import Maugham
@testable import MaughamCore

/// **The in-place grid's values** (report plan 7c Task 3): seeded from the whole book at
/// expand, advanced incrementally per host state change (only what changed and its
/// dependents repaint, nothing assembled), re-seeded when another figure changes.
@MainActor
final class FigureGridValuesTests: XCTestCase {

    private var projectURL: URL!
    /// The window's project store, held: the window holds it weakly.
    private var projectStore: ProjectStore?
    private let gb = TableLocale(languageTag: "en-GB", fallbackRegion: "GB")

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("gridvalues-\(UUID().uuidString)")
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
        projectStore = nil
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// A book with one chapter, a window, and two 3×3 table figures: `grid` (the one the
    /// grid shows) and `other`, both open.
    private func openTwoTables() async throws -> (DocumentStore, grid: FigureDocument, other: FigureDocument) {
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
        self.projectStore = projectStore
        let grid = try await projectStore.createFigure(kind: .table, name: "grid", piece: nil)
        let other = try await projectStore.createFigure(kind: .table, name: "other", piece: nil)
        let gridHost = try await store.openFigure(figureId: grid.id)
        let otherHost = try await store.openFigure(figureId: other.id)
        await store.awaitOpenFigureRenderForTesting()
        return (store, gridHost, otherHost)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func key(_ host: FigureDocument, _ a1: String) -> CellKey {
        let p = A1.parse(a1)!
        return CellKey(row: host.state.table.rows[p.row], column: host.state.table.columns[p.column])
    }

    /// Types `text` into `a1` the way the grid will: `FigureCellEntry` over the cell there.
    private func type(_ text: String, at a1: String, in host: FigureDocument, store: DocumentStore,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let k = key(host, a1)
        let names = try await store.tableImportContext().names
        switch FigureCellEntry.cell(from: text, prior: host.state.table[k], table: host.state.table,
                                    names: names, locale: gb) {
        case .success(let cell): try await host.setCell(cell, at: k)
        case .failure(let e): XCTFail("refused \(text): \(e.message)", file: file, line: line)
        }
    }

    /// The values holder over `host`, counting how often it assembles the book.
    private func values(for host: FigureDocument, store: DocumentStore) -> (FigureGridValues, () -> Int) {
        var assembled = 0
        let values = FigureGridValues(figureId: host.figureId, state: host.state, locale: gb) { [weak store] in
            assembled += 1
            return try await store?.assembledFigures()
        }
        return (values, { assembled })
    }

    // MARK: - Seed and advance

    func test_theSeedComputesFormulas_andShowsEachInItsFormat() async throws {
        let (store, grid, other) = try await openTwoTables()
        try await type("10", at: "B1", in: grid, store: store)
        try await type("20", at: "B2", in: grid, store: store)
        try await type("=SUM(B1:B2)", at: "B3", in: grid, store: store)
        try await type("£5", at: "C1", in: grid, store: store)
        let (values, assembled) = self.values(for: grid, store: store)
        XCTAssertFalse(values.isSeeded)
        XCTAssertEqual(values.value(at: key(grid, "B3")), .empty, "no book yet: a formula shows nothing")

        let repaint = try await values.reseed()

        XCTAssertEqual(repaint, .everything)
        XCTAssertTrue(values.isSeeded)
        XCTAssertEqual(assembled(), 1)
        XCTAssertEqual(values.value(at: key(grid, "B3")), .number(30))
        XCTAssertEqual(values.display(at: key(grid, "B3")), "30")
        XCTAssertEqual(values.display(at: key(grid, "C1")), "£5")
        XCTAssertEqual(values.display(at: key(grid, "A1")), "")
        await store.closeFigure(figureId: grid.figureId)
        await store.closeFigure(figureId: other.figureId)
    }

    /// **An edit repaints the cell and what reads it, nothing else, and assembles nothing.**
    func test_advanceRepaintsOnlyTheChangedCellAndItsDependents_andAssemblesNothing() async throws {
        let (store, grid, other) = try await openTwoTables()
        try await type("10", at: "B1", in: grid, store: store)
        try await type("20", at: "B2", in: grid, store: store)
        try await type("=SUM(B1:B2)", at: "B3", in: grid, store: store)
        try await type("5", at: "C1", in: grid, store: store)
        try await type("=C1*2", at: "C2", in: grid, store: store)
        let (values, assembled) = self.values(for: grid, store: store)
        try await values.reseed()
        XCTAssertEqual(values.display(at: key(grid, "C2")), "10")

        try await type("15", at: "B1", in: grid, store: store)
        let repaint = values.advance(to: grid.state)

        XCTAssertEqual(repaint, .cells([key(grid, "B1"), key(grid, "B3")]), "C1 and C2 read nothing that changed")
        XCTAssertEqual(values.display(at: key(grid, "B3")), "35")
        XCTAssertEqual(values.display(at: key(grid, "C2")), "10")
        XCTAssertEqual(assembled(), 1, "an advance never assembles the book")
        XCTAssertEqual(values.advance(to: grid.state), .none, "the same state again repaints nothing")
        await store.closeFigure(figureId: grid.figureId)
        await store.closeFigure(figureId: other.figureId)
    }

    /// A format change keeps the value; the cell still repaints with its new display.
    func test_advanceRepaintsAFormatChange() async throws {
        let (store, grid, other) = try await openTwoTables()
        try await type("0.25", at: "B1", in: grid, store: store)
        let (values, _) = self.values(for: grid, store: store)
        try await values.reseed()
        XCTAssertEqual(values.display(at: key(grid, "B1")), "0.25")

        var cell = try XCTUnwrap(grid.state.table[key(grid, "B1")])
        cell.format = CellFormat(number: .percent(decimals: 0))
        try await grid.setCell(cell, at: key(grid, "B1"))

        XCTAssertEqual(values.advance(to: grid.state), .cells([key(grid, "B1")]))
        XCTAssertEqual(values.display(at: key(grid, "B1")), "25%")
        await store.closeFigure(figureId: grid.figureId)
        await store.closeFigure(figureId: other.figureId)
    }

    func test_aRowInsertRepaintsEverything() async throws {
        let (store, grid, other) = try await openTwoTables()
        let (values, _) = self.values(for: grid, store: store)
        try await values.reseed()
        _ = try await grid.insertRow(after: grid.state.table.rows[0])
        XCTAssertEqual(values.advance(to: grid.state), .everything)
        await store.closeFigure(figureId: grid.figureId)
        await store.closeFigure(figureId: other.figureId)
    }

    // MARK: - Re-seed

    /// **Another figure changed** (a `figureCardVersion` edge): the re-seed repaints this
    /// figure's cells that read it, and only those.
    func test_aReseedAfterAnotherFiguresChangeRepaintsOnlyTheCellsReadingIt() async throws {
        let (store, grid, other) = try await openTwoTables()
        try await type("7", at: "A1", in: other, store: store)
        try await type("=other!A1*2", at: "B1", in: grid, store: store)
        try await type("3", at: "C1", in: grid, store: store)
        let (values, assembled) = self.values(for: grid, store: store)
        try await values.reseed()
        XCTAssertEqual(values.display(at: key(grid, "B1")), "14")

        try await type("8", at: "A1", in: other, store: store)
        XCTAssertEqual(values.advance(to: grid.state), .none, "the grid's own host did not change")
        XCTAssertEqual(values.display(at: key(grid, "B1")), "14", "an advance alone does not see the other figure")

        let repaint = try await values.reseed()

        XCTAssertEqual(repaint, .cells([key(grid, "B1")]))
        XCTAssertEqual(values.display(at: key(grid, "B1")), "16")
        XCTAssertEqual(assembled(), 2)
        await store.closeFigure(figureId: grid.figureId)
        await store.closeFigure(figureId: other.figureId)
    }

    /// A re-seed overtaken by a later one changes nothing, and an advance made while it was
    /// assembling survives it.
    func test_anOvertakenReseedChangesNothing_andAnAdvanceDuringItSurvives() async throws {
        var table = FigureTable(rows: 2, columns: 2)
        let a1 = CellKey(row: table.rows[0], column: table.columns[0])
        table.setCell(Cell(content: .value(.number(1))), at: a1)
        let state = FigureState(kind: .table, table: table)
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        let values = FigureGridValues(figureId: "fig-gridaaaa", state: state, locale: gb) {
            calls += 1
            if calls == 1 { await withCheckedContinuation { gate = $0 } }
            var book = FigureWorkbook(workbook: Workbook(pins: FigurePinIndex()), unreadable: [])
            book.overlay(state, id: "fig-gridaaaa")
            return book
        }
        let slow = Task { try await values.reseed() }
        // Bounded: a seed that never reaches its gate fails, never hangs (T3 review).
        for _ in 0..<10_000 where gate == nil { await Task.yield() }
        guard gate != nil else { return XCTFail("the first seed never reached its gate") }
        let fast = try await values.reseed()
        XCTAssertEqual(fast, .everything)

        var edited = state
        edited.table.setCell(Cell(content: .value(.number(2))), at: a1)
        XCTAssertEqual(values.advance(to: edited), .cells([a1]))

        gate?.resume()
        let overtaken = try await slow.value
        XCTAssertEqual(overtaken, .none)
        XCTAssertEqual(values.value(at: a1), .number(2), "the overtaken seed's stale table never landed")
        let again = try await values.reseed()
        XCTAssertEqual(again, .none, "a fresh seed lays the latest state over the book")
        XCTAssertEqual(values.value(at: a1), .number(2))
    }

    // MARK: - Visible repaint

    func test_theRepaintNamesOnlyTheVisibleRowsChangedCells() {
        let table = FigureTable(rows: 10, columns: 2)
        let near = CellKey(row: table.rows[1], column: table.columns[0])
        let far = CellKey(row: table.rows[8], column: table.columns[1])
        let repaint = FigureGridValues.Repaint.cells([near, far])
        XCTAssertEqual(repaint.keys(visibleRows: 0..<5, in: table), [near])
        XCTAssertEqual(repaint.keys(visibleRows: 5..<10, in: table), [far])
        XCTAssertNil(FigureGridValues.Repaint.everything.keys(visibleRows: 0..<5, in: table))
        XCTAssertEqual(FigureGridValues.Repaint.none.keys(visibleRows: 0..<5, in: table), [])
    }
}
