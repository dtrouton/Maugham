import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **The figure host's batch verbs** (report plan 7c Task 1): `setCells` and
/// `sortRows` change many cells or rows behind ONE door check, render ONCE
/// and register ONE ⌘Z for the visit, whose drift guard covers every cell
/// or row it wrote. The refusal at the door is pinned beside the other
/// mutators' (`FigureDocumentTests.test_anAuthorOfPieceAMayNotChangeAFigureOfPieceB`),
/// the entry pins beside the other pins (`FigurePinTests`).
@MainActor
final class FigureBatchVerbTests: XCTestCase {

    private var projectURL: URL!
    private var renders: [String] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figbatch-\(UUID().uuidString)")
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
        renders = []
        DocumentStore.figureHostAppendedForTesting = { [weak self] id in self?.renders.append(id) }
    }

    override func tearDown() async throws {
        DocumentStore.figureHostAppendedForTesting = nil
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// A book with one chapter, a window, and a 3×3 table figure open in it.
    private func openTable() async throws -> (DocumentStore, FigureDocument) {
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
        let record = try await projectStore.createFigure(kind: .table, name: "t", piece: nil)
        let host = try await store.openFigure(figureId: record.id)
        await store.awaitOpenFigureRenderForTesting()
        return (store, host)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func ops(of figureId: String) throws -> [Op] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return try OpLogStore.opLogFileURLs(forDocId: figureId, in: projectURL).flatMap { url in
            try Data(contentsOf: url)
                .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
                .compactMap { line -> Op? in
                    let data = Data(line)
                    return OpLogChain.isSealLine(data) ? nil : try? dec.decode(Op.self, from: data)
                }
        }.sorted { $0.opId < $1.opId }
    }

    private func text(_ s: String) -> Cell { Cell(content: .value(.text(s))) }
    private func number(_ n: Double) -> Cell { Cell(content: .value(.number(n))) }

    private func key(_ host: FigureDocument, _ r: Int, _ c: Int) -> CellKey {
        CellKey(row: host.state.table.rows[r], column: host.state.table.columns[c])
    }

    /// The literal value of each cell, what a caller with no formulas would hand.
    private func literal(_ host: FigureDocument) -> (CellKey) -> CellValue {
        { key in
            if case .value(let v)? = host.state.table[key]?.content { return v }
            return .empty
        }
    }

    private func notices(during body: () async throws -> Void) async rethrows -> [String] {
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let m = note.userInfo?[MaughamEvent.noticeMessageKey] as? String { seen.append(m) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return seen
    }

    // MARK: - setCells

    /// **Many cells, one visit**: an op per cell that changes (none for one
    /// already holding its value), one render, and one ⌘Z that restores
    /// every cell — itself one render — whose redo writes them all again.
    func test_setCellsIsOneRender_andOneUndoRestoresEveryCell_andRedoWritesThemAgain() async throws {
        let (store, host) = try await openTable()
        let a1 = key(host, 0, 0), b1 = key(host, 0, 1), a2 = key(host, 1, 0), c3 = key(host, 2, 2)
        try await host.setCell(text("old"), at: a1)
        try await host.setCell(text("same"), at: c3)
        let before = try ops(of: host.figureId).count
        let um = UndoManager()
        renders = []

        try await host.setCells(
            [a1: nil, b1: number(1), a2: text("two"), c3: text("same")],
            actionName: "Format Cells", undoManager: um)

        XCTAssertEqual(try ops(of: host.figureId).count, before + 3, "an op per cell that changes")
        XCTAssertEqual(renders, [host.figureId], "one render for the visit")
        XCTAssertNil(host.state.table[a1])
        XCTAssertEqual(host.state.table[b1], number(1))
        XCTAssertEqual(host.state.table[a2], text("two"))
        XCTAssertEqual(um.undoActionName, "Format Cells")

        renders = []
        um.undo()
        await host.awaitPendingUndoWork()
        XCTAssertEqual(host.state.table[a1], text("old"), "one ⌘Z restores every cell")
        XCTAssertNil(host.state.table[b1])
        XCTAssertNil(host.state.table[a2])
        XCTAssertEqual(host.state.table[c3], text("same"))
        XCTAssertEqual(try ops(of: host.figureId).count, before + 6, "undo appends the three inverses")
        XCTAssertEqual(renders, [host.figureId], "and renders once")
        XCTAssertFalse(um.canUndo, "one step, not three")

        um.redo()
        await host.awaitPendingUndoWork()
        XCTAssertNil(host.state.table[a1])
        XCTAssertEqual(host.state.table[b1], number(1))
        XCTAssertEqual(host.state.table[a2], text("two"))
        XCTAssertTrue(um.canUndo, "and the redo is undoable again")
        await store.closeFigure(figureId: host.figureId)
    }

    /// **The drift guard covers every cell**: a later write to one cell of
    /// the visit declines the whole ⌘Z, and nothing is appended.
    func test_aSetCellsUndoDeclinesWhenAnyOneCellChangedSince() async throws {
        let (store, host) = try await openTable()
        let a1 = key(host, 0, 0), b2 = key(host, 1, 1)
        let um = UndoManager()
        try await host.setCells([a1: text("a"), b2: text("b")], actionName: "Edit Cells", undoManager: um)
        try await host.setCell(text("later"), at: b2)
        let count = try ops(of: host.figureId).count

        let said = await notices {
            um.undo()
            await host.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, ["Couldn't undo the change to the figure — it changed on another device."])
        XCTAssertEqual(host.state.table[a1], text("a"), "the untouched cell is not undone alone")
        XCTAssertEqual(host.state.table[b2], text("later"))
        XCTAssertEqual(try ops(of: host.figureId).count, count, "nothing was appended")
        await store.closeFigure(figureId: host.figureId)
    }

    /// A cell whose row is gone refuses the whole batch before anything is written.
    func test_setCellsNamingAGoneRowWritesNothing() async throws {
        let (store, host) = try await openTable()
        let a1 = key(host, 0, 0), b2 = key(host, 1, 1)
        try await host.deleteRow(b2.row)
        let count = try ops(of: host.figureId).count
        renders = []
        let um = UndoManager()
        do {
            try await host.setCells([a1: text("a"), b2: text("b")], actionName: "Edit Cells", undoManager: um)
            XCTFail("a gone row was written")
        } catch is FigureEditInvalid {}
        XCTAssertNil(host.state.table[a1])
        XCTAssertEqual(try ops(of: host.figureId).count, count, "nothing was appended")
        XCTAssertEqual(renders, [], "nothing rendered")
        XCTAssertFalse(um.canUndo)
        await store.closeFigure(figureId: host.figureId)
    }

    /// A batch that changes nothing writes, renders and registers nothing.
    func test_setCellsThatChangeNothingWriteNothing() async throws {
        let (store, host) = try await openTable()
        let a1 = key(host, 0, 0)
        try await host.setCell(text("a"), at: a1)
        let count = try ops(of: host.figureId).count
        renders = []
        let um = UndoManager()
        try await host.setCells([a1: text("a"), key(host, 1, 1): nil], actionName: "Edit Cells", undoManager: um)
        XCTAssertEqual(try ops(of: host.figureId).count, count)
        XCTAssertEqual(renders, [])
        XCTAssertFalse(um.canUndo)
        await store.closeFigure(figureId: host.figureId)
    }

    // MARK: - sortRows

    /// A header, five body rows and a total row; column A holds the numbers.
    private func sortable(_ host: FigureDocument) async throws -> [RowID] {
        for _ in 0..<4 { _ = try await host.insertRow(after: host.state.table.rows.last) }
        let rows = host.state.table.rows
        XCTAssertEqual(rows.count, 7, "precondition")
        try await host.setHeaderRows(1)
        try await host.setTotalRow(true)
        let a = host.state.table.columns[0], b = host.state.table.columns[1]
        var edits: [CellKey: Cell?] = [CellKey(row: rows[0], column: a): text("Amount")]
        for (row, n) in zip(rows[1...5], [30.0, 10, 50, 20, 40]) {
            edits[CellKey(row: row, column: a)] = number(n)
            edits[CellKey(row: row, column: b)] = text("row \(Int(n))")
        }
        edits[CellKey(row: rows[6], column: a)] = number(150)
        try await host.setCells(edits, actionName: "Edit Cells", undoManager: nil)
        return rows
    }

    /// **Sort is moves**: the body sorted, header and total where they were,
    /// each row's cells with it, one render, and one ⌘Z back to the old order.
    func test_sortRowsMovesTheBody_keepsHeaderAndTotal_rendersOnce_andOneUndoPutsItBack() async throws {
        let (store, host) = try await openTable()
        let rows = try await sortable(host)
        let a = host.state.table.columns[0], b = host.state.table.columns[1]
        let before = try ops(of: host.figureId).count
        let um = UndoManager()
        renders = []

        try await host.sortRows(
            by: a, ascending: true, values: literal(host), actionName: "Sort Ascending", undoManager: um)

        let sorted = [rows[0], rows[2], rows[4], rows[1], rows[5], rows[3], rows[6]]
        XCTAssertEqual(host.state.table.rows, sorted)
        XCTAssertEqual(host.state.table[CellKey(row: rows[2], column: b)], text("row 10"), "cells move with their row")
        XCTAssertEqual(renders, [host.figureId], "one render")
        let written = try ops(of: host.figureId).dropFirst(before)
        XCTAssertFalse(written.isEmpty)
        XCTAssertTrue(written.allSatisfy { if case .moveRow? = $0.figure?.structure { true } else { false } },
                      "a sort writes row moves only")

        renders = []
        um.undo()
        await host.awaitPendingUndoWork()
        XCTAssertEqual(host.state.table.rows, rows, "one ⌘Z restores the order")
        XCTAssertEqual(renders, [host.figureId])
        XCTAssertFalse(um.canUndo)

        um.redo()
        await host.awaitPendingUndoWork()
        XCTAssertEqual(host.state.table.rows, sorted, "redo sorts again")
        await store.closeFigure(figureId: host.figureId)
    }

    func test_sortRowsDescending_aroundATombstone() async throws {
        let (store, host) = try await openTable()
        let rows = try await sortable(host)
        try await host.deleteRow(rows[3])  // the 50
        let um = UndoManager()
        try await host.sortRows(
            by: host.state.table.columns[0], ascending: false, values: literal(host),
            actionName: "Sort Descending", undoManager: um)
        XCTAssertEqual(host.state.table.rows, [rows[0], rows[5], rows[1], rows[4], rows[2], rows[6]])
        um.undo()
        await host.awaitPendingUndoWork()
        XCTAssertEqual(host.state.table.rows, [rows[0], rows[1], rows[2], rows[4], rows[5], rows[6]])
        await store.closeFigure(figureId: host.figureId)
    }

    /// An order already sorted writes, renders and registers nothing.
    func test_sortingSortedRowsWritesNothing() async throws {
        let (store, host) = try await openTable()
        _ = try await sortable(host)
        let a = host.state.table.columns[0]
        try await host.sortRows(by: a, ascending: true, values: literal(host), actionName: "Sort", undoManager: nil)
        let count = try ops(of: host.figureId).count
        renders = []
        let um = UndoManager()
        try await host.sortRows(by: a, ascending: true, values: literal(host), actionName: "Sort", undoManager: um)
        XCTAssertEqual(try ops(of: host.figureId).count, count)
        XCTAssertEqual(renders, [])
        XCTAssertFalse(um.canUndo)
        await store.closeFigure(figureId: host.figureId)
    }

    /// **The sort's drift guard**: a row moved since declines the ⌘Z.
    func test_aSortUndoDeclinesOnceTheOrderChanged() async throws {
        let (store, host) = try await openTable()
        let rows = try await sortable(host)
        let um = UndoManager()
        try await host.sortRows(
            by: host.state.table.columns[0], ascending: true, values: literal(host),
            actionName: "Sort", undoManager: um)
        try await host.moveRow(rows[1], after: rows[0])
        let order = host.state.table.rows
        let count = try ops(of: host.figureId).count

        let said = await notices {
            um.undo()
            await host.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, ["Couldn't undo the change to the figure — it changed on another device."])
        XCTAssertEqual(host.state.table.rows, order)
        XCTAssertEqual(try ops(of: host.figureId).count, count, "nothing was appended")
        await store.closeFigure(figureId: host.figureId)
    }
}
