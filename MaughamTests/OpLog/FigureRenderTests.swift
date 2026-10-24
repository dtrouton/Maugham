import XCTest
@testable import Maugham
@testable import MaughamCore

/// **A table's render, and a figure following edits from elsewhere** (report
/// plan 6a Task 7).
///
/// `figures/<name>.csv` is the computed values, written through the window's
/// coordinated door on the host's load, after every op it appends, after
/// `createFigure`, and when the presenter reports the figure's stream changed.
/// It is never read back (tripwire 20): an edit made to it outside Maugham is
/// overwritten and never reaches the table (Review Focus 4).
@MainActor
final class FigureRenderTests: XCTestCase {

    private var projectURL: URL!
    private var identities: LocalIdentities!
    private var cacheURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figrender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        cacheURL = TestTemp.root.appendingPathComponent("figrender-cache-\(UUID().uuidString).json")
        identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: cacheURL, identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
        try "Words.\n".write(
            to: projectURL.appendingPathComponent("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "piece-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Fixture

    private func openWindow() async throws -> (DocumentStore, ProjectStore) {
        let store = try await DocumentStore.open(url: projectURL)
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func csv(_ record: FigureRecord) throws -> String {
        try String(contentsOf: projectURL.appendingPathComponent(record.path), encoding: .utf8)  // adr-0018-ok: test reads the derived render to assert what was written
    }

    private func spoil(_ record: FigureRecord) throws {
        try "edited,in,Excel\n=1+1,,\n".write(
            to: projectURL.appendingPathComponent(record.path), atomically: true, encoding: .utf8)
    }

    private func key(_ table: FigureTable, row: Int, column: Int) -> CellKey {
        CellKey(row: table.rows[row], column: table.columns[column])
    }

    private func number(_ x: Double) -> Cell { Cell(content: .value(.number(x))) }

    private func formula(_ text: String, in table: FigureTable, figures: [String: FigureTable] = [:]) throws -> Cell {
        switch FormulaParser.parse(text, in: table, figures: figures) {
        case .success(let f): return Cell(content: .formula(f))
        case .failure(let e): throw FigureEditInvalid(reason: e.message)
        }
    }

    // MARK: - The CSV

    /// **The computed values, by live order**: a formula renders its value,
    /// never its text.
    func test_theCSVIsTheComputedValues() throws {
        var table = FigureTable(rows: 2, columns: 2)
        table.setCell(number(2), at: key(table, row: 0, column: 0))
        table.setCell(try formula("A1*3", in: table), at: key(table, row: 0, column: 1))
        let record = FigureRecord(id: "fig-0a1b2c3d", name: "t", kind: .table, piece: nil, path: "figures/t.csv")
        let text = FigureRender.csv(
            record: record, state: FigureState(kind: .table, table: table),
            workbook: Workbook(pins: FigureRender.noResearchPins))
        XCTAssertEqual(text, "2,6\n,\n")
    }

    /// An image, a parked table and a kind this build does not know render
    /// nothing.
    func test_anImageAParkedTableAndAnUnknownKindRenderNothing() {
        let table = FigureTable(rows: 1, columns: 1)
        let book = Workbook(pins: FigureRender.noResearchPins)
        let image = FigureRecord(id: "fig-1", name: "i", kind: .image, piece: nil, path: "figures/i")
        XCTAssertNil(FigureRender.csv(record: image, state: FigureState(kind: .image), workbook: book))
        let tableRecord = FigureRecord(id: "fig-2", name: "t", kind: .table, piece: nil, path: "figures/t.csv")
        XCTAssertNil(FigureRender.csv(
            record: tableRecord,
            state: FigureState(kind: .table, table: table, parked: FigureParking(path: "research/t.csv", hash: "h")),
            workbook: book))
        let unknown = FigureRecord(id: "fig-3", name: "u", kind: .unknown("chart"), piece: nil, path: "figures/u.csv")
        XCTAssertNil(FigureRender.csv(record: unknown, state: FigureState(kind: .unknown("chart")), workbook: book))
        XCTAssertNotNil(FigureRender.csv(record: tableRecord, state: FigureState(kind: .table, table: table), workbook: book),
                        "control: a live table renders")
    }

    /// A record synced from another device is data: only a file directly in
    /// the figures folder is ever written.
    func test_onlyACSVDirectlyInTheFiguresFolderIsWritten() {
        func path(_ p: String) -> String? {
            FigureRender.renderPath(of: FigureRecord(id: "fig-1", name: "t", kind: .table, piece: nil, path: p))
        }
        XCTAssertEqual(path("figures/t.csv"), "figures/t.csv")
        XCTAssertNil(path("../t.csv"))
        XCTAssertNil(path("figures/../../t.csv"))
        XCTAssertNil(path("figures/a/t.csv"))
        XCTAssertNil(path("figures/.t.csv"))
        XCTAssertNil(path("research/t.csv"))
        XCTAssertNil(path("/figures/t.csv"))
        XCTAssertNil(path("figures/t.md"))
    }

    // MARK: - In a window

    /// **A new table has its render from the start.**
    func test_creatingATableRendersItsCSV() async throws {
        let (store, projectStore) = try await openWindow()
        let record = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        XCTAssertEqual(record.path, "figures/cash.csv")
        XCTAssertEqual(try csv(record), ",,\n,,\n,,\n")
        withExtendedLifetime(store) {}  // the window: `ProjectStore.documentStore` is weak
    }

    /// **A window opens a figure with its own store as the figure's door**,
    /// and every op the host appends — an edit, its undo — re-renders.
    func test_aWindowOpensAFigureWithItsOwnStore_andEveryOpRenders() async throws {
        let (store, projectStore) = try await openWindow()
        let record = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let doc = try await store.openFigure(figureId: record.id)
        XCTAssertTrue(doc.documentStore === store, "the window's store is the figure's door")
        let again = try await store.openFigure(figureId: record.id)
        XCTAssertTrue(again === doc, "an open figure is opened once")

        let um = UndoManager()
        try await doc.setCell(number(42), at: key(doc.state.table, row: 1, column: 2), undoManager: um)
        XCTAssertEqual(try csv(record), ",,\n,,42\n,,\n")
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(try csv(record), ",,\n,,\n,,\n", "the undo's compensating op renders too")
        await store.closeFigure(figureId: record.id)
    }

    /// **Review Focus 4: an edited CSV is overwritten and the table is
    /// unchanged** — by the next op, by the next presenter pass, and nothing
    /// ever reads the file as the table.
    func test_anEditedCSVIsOverwrittenAndTheTableIsUnchanged() async throws {
        let (store, projectStore) = try await openWindow()
        let record = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let doc = try await store.openFigure(figureId: record.id)
        try await doc.setCell(number(1), at: key(doc.state.table, row: 0, column: 0))

        try spoil(record)
        try await doc.setCell(number(2), at: key(doc.state.table, row: 0, column: 1))
        XCTAssertEqual(try csv(record), "1,2,\n,,\n,,\n", "the next op's render overwrote the edit")

        try spoil(record)
        store.presenterDidChangeSubitem(
            at: try XCTUnwrap(OpLogStore.opLogFileURLs(forDocId: record.id, in: projectURL).first))
        await store.flushFigureChangesForTesting()
        XCTAssertEqual(try csv(record), "1,2,\n,,\n,,\n", "and so did the presenter's pass")

        try spoil(record)
        let fresh = try await FigureDocument.load(
            figureId: record.id, projectURL: projectURL, actor: .author, session: "s",
            presenter: nil, documentStore: nil)
        XCTAssertEqual(fresh.state.table, doc.state.table, "a fresh load reads the stream, never the file")
        XCTAssertEqual(fresh.state.table.cells.count, 2)
        await fresh.close()
        await store.closeFigure(figureId: record.id)
    }

    /// **Another device's edit**: the presenter's figure arm re-reads the
    /// open figure, re-renders it, and re-renders the table whose formula
    /// reads it — which is not open.
    func test_anotherDevicesEditReloadsTheOpenFigureAndReRendersItsReaders() async throws {
        let (store, projectStore) = try await openWindow()
        let src = try await projectStore.createFigure(kind: .table, name: "src", piece: nil)
        let total = try await projectStore.createFigure(kind: .table, name: "total", piece: nil)
        let srcDoc = try await store.openFigure(figureId: src.id)
        let a1 = key(srcDoc.state.table, row: 0, column: 0)
        try await srcDoc.setCell(number(5), at: a1)
        let totalDoc = try await store.openFigure(figureId: total.id)
        try await totalDoc.setCell(
            try formula("src!A1*2", in: totalDoc.state.table, figures: ["src": srcDoc.state.table]),
            at: key(totalDoc.state.table, row: 0, column: 0))
        XCTAssertEqual(try csv(total), "10,,\n,,\n,,\n")
        await store.closeFigure(figureId: total.id)

        // Sam's Mac, admitted to the whole book, writes src!A1 = 7.
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac", permit: .bookAuthor)
        await store.postureSettled()
        await store.flushFigureChangesForTesting()
        let before = Set(OpLogStore.opLogFileURLs(forDocId: src.id, in: projectURL))
        let samStore = OpLogStore(
            projectURL: projectURL, identity: sam.author,
            state: OpLogDeviceState(fileURL: projectURL.appendingPathComponent("sam-state.json")))
        try await samStore.append(Op(
            opId: ULID.generate(), docId: src.id, at: Date(), device: sam.author.deviceId,
            session: "sams-mac", kind: .figureCellSet, changes: [],
            figure: FigureOpPayload(cell: a1, next: number(7), prior: number(5))))
        _ = try await samStore.sealChain(docId: src.id)
        let samFile = try XCTUnwrap(
            Set(OpLogStore.opLogFileURLs(forDocId: src.id, in: projectURL)).subtracting(before).first,
            "Sam's Mac wrote its own file")

        store.presenterDidChangeSubitem(at: samFile)
        await store.flushFigureChangesForTesting()

        XCTAssertEqual(srcDoc.state.table[a1], number(7), "the open figure re-read its stream")
        XCTAssertEqual(try csv(src), "7,,\n,,\n,,\n")
        XCTAssertEqual(try csv(total), "14,,\n,,\n,,\n", "the table reading it re-rendered")
        await store.closeFigure(figureId: src.id)
    }

    /// **A trust change drops the figure cache** (ruling R-6a-6): the cache
    /// is keyed by files and the registry, never by trust.
    func test_aTrustChangeDropsTheFigureCache() async throws {
        let (store, projectStore) = try await openWindow()
        let record = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let afterCreate = store.figureCache.deriveCount
        XCTAssertGreaterThan(afterCreate, 0, "precondition: the render read through the cache")
        await store.renderFigures(changed: [record.id])
        XCTAssertEqual(store.figureCache.deriveCount, afterCreate, "an unchanged stream is cached")

        store.invalidateTrust()
        await store.renderFigures(changed: [record.id])
        XCTAssertEqual(store.figureCache.deriveCount, afterCreate + 1, "a trust change re-derives")
    }

    /// **A figure the workbook cannot read is said, not skipped** (R-6a-7):
    /// it is listed by name, and the others still render.
    func test_anUnreadableFigureIsListedAndTheOthersStillRender() async throws {
        let (store, projectStore) = try await openWindow()
        let broken = try await projectStore.createFigure(kind: .table, name: "broken", piece: nil)
        let fine = try await projectStore.createFigure(kind: .table, name: "fine", piece: nil)
        let files = OpLogStore.opLogFileURLs(forDocId: broken.id, in: projectURL)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        }
        defer {
            for file in files {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            }
        }
        try FileManager.default.removeItem(at: projectURL.appendingPathComponent(fine.path))
        store.figureCache.invalidateAll()

        await store.renderFigures(changed: [fine.id])

        XCTAssertEqual(store.lastUnreadableFigures.map(\.name), ["broken"])
        XCTAssertEqual(try csv(fine), ",,\n,,\n,,\n", "the readable figure rendered")
    }
}
