import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **The visit recorder** (report plan 7d Task 5): between `beginVisit` and
/// `endVisit` the figure host records every op it commits — forward edits,
/// batches, sorts and the grid's own undos and redos — and `undoVisit` /
/// `redoVisit` take the whole visit back and put it back as one step, through
/// the inner path every figure ⌘Z takes (one render, drift-guarded, R7d-10).
@MainActor
final class FigureVisitTests: XCTestCase {

    private var projectURL: URL!
    private var renders: [String] = []
    /// The window's project store, held: the window holds it weakly.
    private var projectStore: ProjectStore?

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figvisit-\(UUID().uuidString)")
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
        projectStore = nil
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
        self.projectStore = projectStore
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

    private func literal(_ host: FigureDocument) -> (CellKey) -> CellValue {
        { key in
            if case .value(let v)? = host.state.table[key]?.content { return v }
            return .empty
        }
    }

    private func freshRow(_ host: FigureDocument) -> RowID {
        RowID(TableID.mint(excluding: Set(host.state.table.rowSlots.map(\.id.raw)
            + host.state.table.columnSlots.map(\.id.raw))))
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

    private let drifted = "Couldn't undo the change to the figure — it changed on another device."

    // MARK: - Recording

    /// **The visit is every op appended while it was open, in order** — a
    /// cell, an insert, a batch, a sort and an `applyChanges` — and nothing
    /// before or after; one `undoVisit` restores the table exactly in one
    /// render, and `redoVisit` puts it back with the same ids.
    func test_aVisitRecordsEveryOp_undoVisitRestoresExactly_andRedoVisitKeepsTheIds() async throws {
        let (store, host) = try await openTable()
        try await host.setCell(text("before the visit"), at: key(host, 0, 0))
        let before = host.state
        let count = try ops(of: host.figureId).count

        host.beginVisit()
        let a = host.state.table.columns[0]
        try await host.setCell(number(3), at: key(host, 0, 0))
        let inserted = try await host.insertRow(after: host.state.table.rows.last)
        try await host.setCells(
            [key(host, 1, 0): number(1), key(host, 2, 0): number(2), CellKey(row: inserted, column: a): number(0)],
            actionName: "Edit Cells", undoManager: nil)
        try await host.sortRows(by: a, ascending: true, values: literal(host), actionName: "Sort", undoManager: nil)
        let new = freshRow(host)
        try await host.applyChanges([
            FigureReturnDiff.Change(kind: .figureStructure, payload: FigureOpPayload(
                structure: .insertRow(new, after: host.state.table.rows.last))),
            FigureReturnDiff.Change(kind: .figureCellSet, payload: FigureOpPayload(
                cell: CellKey(row: new, column: a), next: text("pasted"), prior: nil)),
        ], expecting: host.state, actionName: "Paste", undoManager: nil)
        let visited = host.state
        let visitOps = try ops(of: host.figureId).dropFirst(count)
        let visit = try XCTUnwrap(host.endVisit())
        let outside = CellKey(row: before.table.rows[2], column: before.table.columns[2])
        try await host.setCell(text("after the visit"), at: outside)

        XCTAssertEqual(visit.ops.map(\.kind), visitOps.map(\.kind), "every op the visit appended, in order")
        XCTAssertEqual(visit.ops.map(\.payload), visitOps.compactMap(\.figure))
        XCTAssertGreaterThan(visit.ops.count, 6, "the sort's moves are in it")

        renders = []
        let undone = await host.undoVisit(visit)
        XCTAssertTrue(undone)
        XCTAssertEqual(host.state.table.rows, before.table.rows, "the rows as they were")
        XCTAssertEqual(host.state.table.rowSlots.filter { $0.id == inserted || $0.id == new }.count, 2,
                       "the inserted rows stand as tombstones")
        var expected = before.table.cells
        expected[outside] = text("after the visit")
        XCTAssertEqual(host.state.table.cells, expected, "every cell as it was; the write after the visit stands")
        XCTAssertEqual(renders, [host.figureId], "one render")

        renders = []
        let redone = await host.redoVisit(visit)
        XCTAssertTrue(redone)
        XCTAssertEqual(host.state.table.rows, visited.table.rows, "the same rows in the same order, same ids")
        var again = visited.table.cells
        again[outside] = text("after the visit")
        XCTAssertEqual(host.state.table.cells, again)
        XCTAssertEqual(renders, [host.figureId], "one render")

        let undoneAgain = await host.undoVisit(visit)
        XCTAssertTrue(undoneAgain, "the visit undoes again after its redo")
        XCTAssertEqual(host.state.table.rows, before.table.rows)
        await store.closeFigure(figureId: host.figureId)
    }

    /// **The grid's own undos and redos are in the visit** (they come through
    /// `commit` like any edit): a cell typed, undone, redone and typed again
    /// is four ops, and the visit's undo takes the cell to before the visit.
    func test_theGridsOwnUndoAndRedoAreRecorded_andTheVisitStillUndoesWhole() async throws {
        let (store, host) = try await openTable()
        let a1 = key(host, 0, 0), b1 = key(host, 0, 1)
        try await host.setCell(text("old"), at: a1)
        let before = host.state
        let gridUndo = UndoManager()

        host.beginVisit()
        try await host.setCell(text("one"), at: a1, undoManager: gridUndo)
        gridUndo.undo()
        await host.awaitPendingUndoWork()
        XCTAssertEqual(host.state.table[a1], text("old"), "precondition: the grid's ⌘Z ran")
        gridUndo.redo()
        await host.awaitPendingUndoWork()
        XCTAssertEqual(host.state.table[a1], text("one"), "precondition: the grid's redo ran")
        try await host.setCell(text("two"), at: b1, undoManager: gridUndo)
        let visit = try XCTUnwrap(host.endVisit())

        XCTAssertEqual(visit.ops.map(\.payload.next), [text("one"), text("old"), text("one"), text("two")],
                       "the edit, its undo, its redo, the next edit")
        let undone = await host.undoVisit(visit)
        XCTAssertTrue(undone)
        XCTAssertEqual(host.state.table.cells, before.table.cells, "the whole visit taken back")
        await store.closeFigure(figureId: host.figureId)
    }

    /// **An empty visit is nil**, and a visit ended is ended: a second end
    /// is nil too.
    func test_anEmptyVisitIsNil() async throws {
        let (store, host) = try await openTable()
        host.beginVisit()
        XCTAssertNil(host.endVisit())
        try await host.setCell(text("outside"), at: key(host, 0, 0))
        XCTAssertNil(host.endVisit(), "nothing records between visits")
        await store.closeFigure(figureId: host.figureId)
    }

    /// **Visits don't nest**: a begin while one is open keeps recording the
    /// open visit, so nothing it held is lost.
    func test_aBeginWhileAVisitIsOpenKeepsRecordingIt() async throws {
        let (store, host) = try await openTable()
        host.beginVisit()
        try await host.setCell(text("first"), at: key(host, 0, 0))
        host.beginVisit()
        try await host.setCell(text("second"), at: key(host, 0, 1))
        let visit = try XCTUnwrap(host.endVisit())
        XCTAssertEqual(visit.ops.map(\.payload.next), [text("first"), text("second")])
        XCTAssertNil(host.endVisit())
        await store.closeFigure(figureId: host.figureId)
    }

    // MARK: - Drift (R7d-10)

    /// **A visit's undo declines whole once anything it touched changed
    /// since**, said with the existing sentence, appending nothing.
    func test_aVisitUndoDeclinesWholeOnceATouchedCellChanged() async throws {
        let (store, host) = try await openTable()
        let a1 = key(host, 0, 0), b1 = key(host, 0, 1)
        host.beginVisit()
        try await host.setCell(text("a"), at: a1)
        try await host.setCell(text("b"), at: b1)
        let visit = try XCTUnwrap(host.endVisit())
        try await host.setCell(text("since"), at: b1)
        let count = try ops(of: host.figureId).count

        var undone = true
        let said = await notices { undone = await host.undoVisit(visit) }
        XCTAssertFalse(undone)
        XCTAssertEqual(said, [drifted])
        XCTAssertEqual(host.state.table[a1], text("a"), "declined whole: not even the untouched-since cell")
        XCTAssertEqual(try ops(of: host.figureId).count, count, "nothing was appended")
        await store.closeFigure(figureId: host.figureId)
    }

    /// Control: a write since to a cell the visit never touched does not
    /// decline it.
    func test_aVisitUndoRunsPastAWriteOutsideWhatItTouched() async throws {
        let (store, host) = try await openTable()
        let a1 = key(host, 0, 0), c3 = key(host, 2, 2)
        host.beginVisit()
        try await host.setCell(text("a"), at: a1)
        let visit = try XCTUnwrap(host.endVisit())
        try await host.setCell(text("elsewhere"), at: c3)

        let undone = await host.undoVisit(visit)
        XCTAssertTrue(undone)
        XCTAssertNil(host.state.table[a1])
        XCTAssertEqual(host.state.table[c3], text("elsewhere"))
        await store.closeFigure(figureId: host.figureId)
    }

    /// **The redo declines whole too** once what the undo wrote changed.
    func test_aVisitRedoDeclinesOnceWhatTheUndoWroteChanged() async throws {
        let (store, host) = try await openTable()
        let a1 = key(host, 0, 0)
        host.beginVisit()
        let row = try await host.insertRow(after: host.state.table.rows.last)
        try await host.setCell(text("a"), at: a1)
        let visit = try XCTUnwrap(host.endVisit())
        let undone = await host.undoVisit(visit)
        XCTAssertTrue(undone)
        try await host.setCell(text("since"), at: a1)
        let count = try ops(of: host.figureId).count

        var redone = true
        let said = await notices { redone = await host.redoVisit(visit) }
        XCTAssertFalse(redone)
        XCTAssertEqual(said, [drifted])
        XCTAssertNil(host.state.table.rowIndex(of: row), "the row stays undone")
        XCTAssertEqual(try ops(of: host.figureId).count, count, "nothing was appended")
        await store.closeFigure(figureId: host.figureId)
    }
}
