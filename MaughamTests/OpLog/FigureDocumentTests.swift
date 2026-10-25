import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **The figure host** (report plan 6a Task 6): a figure is created through
/// `ProjectStore.createFigure`, opened through `FigureDocument.load` (which
/// writes nothing), and changed only through mutators that ask the FIGURE's
/// posture first, append one op carrying what it replaced, and register a
/// drift-guarded ⌘Z.
@MainActor
final class FigureDocumentTests: XCTestCase {

    private var projectURL: URL!
    private var identities: LocalIdentities!
    private var cacheURL: URL!

    private static let pieceA = "piece-a"
    private static let pieceB = "piece-b"

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figdoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        cacheURL = TestTemp.root.appendingPathComponent("figdoc-cache-\(UUID().uuidString).json")
        identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: cacheURL, identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
        try makeProject()
    }

    override func tearDown() async throws {
        ProjectStore.beforeFigureAppendForTesting = nil
        FigureDocument.afterReloadReadForTesting = nil
        FigureDocument.beforeCommitAppendForTesting = nil
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Fixture

    private func makeProject() throws {
        for path in ["manuscript/a.md", "manuscript/b.md"] {
            try "Words.\n".write(
                to: projectURL.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [
                StructureItem(id: Self.pieceA, title: "A", type: .document, path: "manuscript/a.md"),
                StructureItem(id: Self.pieceB, title: "B", type: .document, path: "manuscript/b.md"),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: projectURL.appendingPathComponent(ProjectManifest.fileName))
    }

    private func load(_ id: String, as actor: DeviceActor = .author) async throws -> FigureDocument {
        try await FigureDocument.load(
            figureId: id, projectURL: projectURL, actor: actor, session: "s", presenter: nil,
            documentStore: nil)
    }

    /// Every op in every file of the figure's stream, seals excluded.
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
        }
    }

    /// The bytes of every file of the stream, by name.
    private func streamBytes(of figureId: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for url in OpLogStore.opLogFileURLs(forDocId: figureId, in: projectURL) {
            out[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return out
    }

    private func text(_ s: String) -> Cell { Cell(content: .value(.text(s))) }

    private func firstKey(_ doc: FigureDocument) throws -> CellKey {
        CellKey(row: try XCTUnwrap(doc.state.table.rows.first),
                column: try XCTUnwrap(doc.state.table.columns.first))
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

    // MARK: - Create and load

    func test_createThenLoad_isAThreeByThreeTableWithNoHeaderRow() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "cashflow", piece: Self.pieceA)

        XCTAssertTrue(record.id.hasPrefix("fig-"), "a figure's id is minted, never its name")
        XCTAssertEqual(record.name, "cashflow")
        XCTAssertEqual(record.path, "figures/cashflow.csv")
        XCTAssertEqual(record.piece, Self.pieceA)
        let onDisk = try ProjectManifest.makeDecoder().decode(
            ProjectManifest.self,
            from: Data(contentsOf: projectURL.appendingPathComponent(ProjectManifest.fileName)))
        XCTAssertEqual(onDisk.figures, [record], "the record went through the manifest door")
        XCTAssertEqual(
            ProjectManifest.schemaVersion(
                ofFileAt: projectURL.appendingPathComponent(ProjectManifest.fileName)), 10,
            "a manifest with figures carries the content floor")

        let doc = try await load(record.id)
        XCTAssertEqual(doc.state.kind, .table)
        XCTAssertEqual(doc.state.table.rows.count, 3)
        XCTAssertEqual(doc.state.table.columns.count, 3)
        XCTAssertEqual(doc.state.table.headerRows, 0)
        XCTAssertEqual(doc.state.diagnostics, [])
        XCTAssertEqual(doc.state.createdBy, identities.author.deviceId,
                       "created by this device's author")
        await doc.close()
    }

    func test_aSecondFigureOfTheSameNameIsDeduplicatedAndKeepsItsBareShape() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let first = try await store.createFigure(kind: .table, name: "cashflow", piece: nil)
        let second = try await store.createFigure(kind: .table, name: "CashFlow", piece: nil)
        XCTAssertEqual(first.name, "cashflow")
        XCTAssertEqual(second.name, "CashFlow_2", "case-insensitive, as the render files are")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.manifest.figures?.count, 2)
    }

    func test_loadEmitsNoOp() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let before = try streamBytes(of: record.id)
        let opsBefore = try ops(of: record.id).count

        let doc = try await load(record.id)
        XCTAssertEqual(try streamBytes(of: record.id), before, "the load wrote nothing at all")
        XCTAssertEqual(try ops(of: record.id).count, opsBefore)
        let assistant = try await load(record.id, as: .assistant)
        XCTAssertEqual(try ops(of: record.id).count, opsBefore, "nor through another actor's door")
        XCTAssertEqual(assistant.state.table.rows.count, 3)
        await doc.close()
        await assistant.close()
    }

    // MARK: - Mutation

    func test_setCellAppendsOneOpCarryingThePriorCell() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let key = try firstKey(doc)

        try await doc.setCell(text("one"), at: key, undoManager: nil)
        let count = try ops(of: record.id).count
        try await doc.setCell(text("two"), at: key, undoManager: nil)

        let all = try ops(of: record.id)
        XCTAssertEqual(all.count, count + 1, "one op per edit")
        let last = try XCTUnwrap(all.last)
        XCTAssertEqual(last.kind, .figureCellSet)
        XCTAssertEqual(last.device, identities.author.deviceId)
        XCTAssertEqual(last.figure?.cell, key)
        XCTAssertEqual(last.figure?.prior, text("one"), "prior is the cell it replaced")
        XCTAssertEqual(last.figure?.next, text("two"))
        XCTAssertEqual(doc.state.table[key], text("two"))

        // And a fresh load reads what was written.
        let reread = try await load(record.id)
        XCTAssertEqual(reread.state.table[key], text("two"))
        await doc.close()
        await reread.close()
    }

    func test_undoAppendsTheInverseAndRestoresIt_redoReappliesIt() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let key = try firstKey(doc)
        let um = UndoManager()

        try await doc.setCell(text("one"), at: key, undoManager: um)
        XCTAssertTrue(um.canUndo)
        let afterEdit = try ops(of: record.id).count

        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertNil(doc.state.table[key], "undo restored the empty cell")
        let undone = try ops(of: record.id)
        XCTAssertEqual(undone.count, afterEdit + 1, "undo APPENDS a compensating op")
        XCTAssertEqual(undone.last?.figure?.next, nil)
        XCTAssertEqual(undone.last?.figure?.prior, text("one"))
        XCTAssertTrue(um.canRedo)

        um.redo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.state.table[key], text("one"), "redo re-applies it")
        XCTAssertEqual(try ops(of: record.id).count, afterEdit + 2)
        XCTAssertTrue(um.canUndo, "and the redo is undoable again")
        await doc.close()
    }

    func test_settingsAndMovesUndoToWhatTheyReplaced() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let um = UndoManager()
        um.groupsByEvent = false
        let rows = doc.state.table.rows

        um.beginUndoGrouping()
        try await doc.setHeaderRows(1, undoManager: um)
        um.endUndoGrouping()
        um.beginUndoGrouping()
        try await doc.moveRow(rows[0], after: rows[2], undoManager: um)
        um.endUndoGrouping()
        XCTAssertEqual(doc.state.table.headerRows, 1)
        XCTAssertEqual(doc.state.table.rows, [rows[1], rows[2], rows[0]])

        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.state.table.rows, rows, "the move went back")
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.state.table.headerRows, 0, "the setting went back")
        await doc.close()
    }

    /// **An undone insert redoes as a revive** (report plan 6b Task 4, ruling
    /// P-1): the same id back in its own slot — so a formula naming it by id
    /// reconnects — and the redo is undoable again.
    ///
    /// The manager groups by event (the default): a redo re-enters the
    /// mutator after an await, and its registration must land in an open
    /// group.
    func test_anUndoneInsertRedoesInItsOwnSlot() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let um = UndoManager()
        let before = doc.state.table.rows

        let row = try await doc.insertRow(after: before[0], undoManager: um)
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.state.table.rows, before, "undo deleted the inserted row")

        let said = await notices { um.redo(); await doc.awaitPendingUndoWork() }
        XCTAssertEqual(said, [], "the redo is not declined")
        XCTAssertEqual(doc.state.table.rows, [before[0], row, before[1], before[2]], "the same id, in its own slot")
        let last = try XCTUnwrap(try ops(of: record.id).last?.figure)
        XCTAssertEqual(last.structure, .reviveRow(row))
        XCTAssertEqual(last.removed, FigureRemovedSlice(), "revived empty")
        XCTAssertTrue(um.canUndo, "and the redo is undoable again")
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.state.table.rows, before)

        // The column's twin.
        let columns = doc.state.table.columns
        let column = try await doc.insertColumn(after: nil, undoManager: um)
        um.undo()
        await doc.awaitPendingUndoWork()
        um.redo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.state.table.columns, [column] + columns)
        await doc.close()
    }

    /// **A delete undoes to a revive** (ruling P-2): the column returns in its
    /// own slot with its cell and its width; redo deletes it again, and the
    /// redo's own undo brings it back again.
    func test_aDeleteUndoesToARevive_withItsCellsAndWidth() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let um = UndoManager()
        let columns = doc.state.table.columns
        let key = CellKey(row: doc.state.table.rows[2], column: columns[1])
        try await doc.setCell(text("kept"), at: key, undoManager: nil)
        try await doc.setColumnWidth(columns[1], 120, undoManager: nil)

        try await doc.deleteColumn(columns[1], undoManager: um)
        XCTAssertEqual(doc.state.table.columns, [columns[0], columns[2]])
        let delete = try XCTUnwrap(try ops(of: record.id).last?.figure)
        XCTAssertEqual(delete.removed, FigureRemovedSlice(
            cells: [.init(at: key.row.raw, cell: text("kept"))], width: 120), "the delete carries what it took")
        XCTAssertTrue(um.canUndo, "a delete registers an undo")

        for pass in 1...2 {
            um.undo()
            await doc.awaitPendingUndoWork()
            XCTAssertEqual(doc.state.table.columns, columns, "pass \(pass): back in its own slot")
            XCTAssertEqual(doc.state.table[key], text("kept"), "pass \(pass)")
            XCTAssertEqual(doc.state.table.columnWidths[columns[1]], 120, "pass \(pass)")
            um.redo()
            await doc.awaitPendingUndoWork()
            XCTAssertEqual(doc.state.table.columns, [columns[0], columns[2]], "pass \(pass): redo deletes it again")
        }
        await doc.close()
    }

    /// The same values whichever figure reads them: none.
    private struct NoPins: ResearchPinSource {
        func pinnedValue(home: String, research: String, row: Int, column: Int) -> CellValue? { nil }
    }

    /// What the formula at `key` evaluates to in the figure's own table.
    private func evaluated(_ doc: FigureDocument, _ key: CellKey) -> CellValue {
        var book = Workbook(pins: NoPins())
        book.setTable(doc.state.table, id: doc.figureId)
        return book.value(at: CellAddress(table: doc.figureId, key: key))
    }

    /// **Review Focus 5** (report plan 6b): undo of a row delete after
    /// another device inserted a neighbouring row and set a column width —
    /// the row returns in its own slot with its cells, their row and width
    /// stand, and the formula that showed `#REF!` shows its value again.
    func test_undoOfARowDeleteAfterAnotherDevicesNeighbourAndWidth_bringsTheRowAndItsValueBack() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let um = UndoManager()
        let rows = doc.state.table.rows, columns = doc.state.table.columns
        let source = CellKey(row: rows[1], column: columns[0])      // A2
        let reader = CellKey(row: rows[0], column: columns[1])      // B1 = A2
        try await doc.setCell(Cell(content: .value(.number(7))), at: source, undoManager: nil)
        let formula = try FormulaParser.parse("A2", in: doc.state.table).get()
        try await doc.setCell(Cell(content: .formula(formula)), at: reader, undoManager: nil)
        XCTAssertEqual(evaluated(doc, reader), .number(7), "control: the formula reads A2")

        try await doc.deleteRow(rows[1], undoManager: um)
        XCTAssertEqual(evaluated(doc, reader), .error(.ref), "the deleted row's value is #REF!")

        let neighbour = RowID("nbrnbr00")
        try await theirOp(doc, .figureStructure, FigureOpPayload(structure: .insertRow(neighbour, after: rows[1])))
        try await theirOp(doc, .figureSettings, FigureOpPayload(settings: .columnWidth(columns[2], 90, prior: nil)))
        XCTAssertEqual(doc.state.table.rows, [rows[0], neighbour, rows[2]], "precondition: their row arrived")

        let said = await notices { um.undo(); await doc.awaitPendingUndoWork() }
        XCTAssertEqual(said, [])
        XCTAssertEqual(doc.state.table.rows, [rows[0], rows[1], neighbour, rows[2]], "its own slot, before their row")
        XCTAssertEqual(doc.state.table[source], Cell(content: .value(.number(7))), "with its cell")
        XCTAssertEqual(doc.state.table.columnWidths[columns[2]], 90, "their width stands")
        XCTAssertEqual(evaluated(doc, reader), .number(7), "the formula shows its value again")
        XCTAssertEqual(doc.state.diagnostics, [])

        // Read back from disk, the same.
        let reread = try await load(record.id)
        XCTAssertEqual(reread.state.table, doc.state.table)
        await reread.close()
        await doc.close()
    }

    /// The brief's case literally: the deleted row holds a FORMULA another
    /// cell reads — `#REF!` while it is gone, its value once ⌘Z brings it
    /// back (the formula itself comes back in the slice).
    func test_undoOfADeletedRowHoldingAFormulaAnotherCellReads_bringsTheValueBack() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let um = UndoManager()
        let rows = doc.state.table.rows, columns = doc.state.table.columns
        let base = CellKey(row: rows[0], column: columns[0])        // A1 = 5
        let doubled = CellKey(row: rows[1], column: columns[0])     // A2 = A1*2
        let reader = CellKey(row: rows[2], column: columns[1])      // B3 = A2
        try await doc.setCell(Cell(content: .value(.number(5))), at: base, undoManager: nil)
        let double = try FormulaParser.parse("A1*2", in: doc.state.table).get()
        try await doc.setCell(Cell(content: .formula(double)), at: doubled, undoManager: nil)
        let read = try FormulaParser.parse("A2", in: doc.state.table).get()
        try await doc.setCell(Cell(content: .formula(read)), at: reader, undoManager: nil)
        XCTAssertEqual(evaluated(doc, reader), .number(10), "control")

        try await doc.deleteRow(rows[1], undoManager: um)
        XCTAssertEqual(evaluated(doc, reader), .error(.ref))
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.state.table[doubled], Cell(content: .formula(double)), "the formula is back")
        XCTAssertEqual(evaluated(doc, reader), .number(10), "and the cell reading it shows its value again")
        await doc.close()
    }

    /// A delete's REDO is drift-guarded too: once another device has typed
    /// into the row the undo revived, redo declines and their cell stands.
    func test_redoOfADeleteDeclinesOnceAnotherDeviceTypedIntoTheRevivedRow() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let um = UndoManager()
        let row = doc.state.table.rows[1]
        let key = CellKey(row: row, column: doc.state.table.columns[2])
        try await doc.deleteRow(row, undoManager: um)
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertNotNil(doc.state.table.rowIndex(of: row), "precondition: the undo revived it")
        try await theirOp(doc, .figureCellSet, FigureOpPayload(cell: key, next: text("theirs"), prior: nil))
        let count = try ops(of: record.id).count
        let said = await notices { um.redo(); await doc.awaitPendingUndoWork() }
        XCTAssertEqual(said, ["Couldn't undo the change to the figure — it changed on another device."])
        XCTAssertNotNil(doc.state.table.rowIndex(of: row), "the row stands")
        XCTAssertEqual(doc.state.table[key], text("theirs"), "and their cell with it")
        XCTAssertEqual(try ops(of: record.id).count, count, "nothing was appended")
        await doc.close()
    }

    /// A delete's undo is drift-guarded: once another device has revived the
    /// row, the undo declines and appends nothing.
    func test_undoOfADeleteAnotherDeviceRevivedDeclines() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let um = UndoManager()
        let row = doc.state.table.rows[1]
        try await doc.deleteRow(row, undoManager: um)
        try await theirOp(doc, .figureStructure, FigureOpPayload(structure: .reviveRow(row), removed: FigureRemovedSlice()))
        XCTAssertNotNil(doc.state.table.rowIndex(of: row), "precondition: their revive arrived")
        let count = try ops(of: record.id).count
        let said = await notices { um.undo(); await doc.awaitPendingUndoWork() }
        XCTAssertEqual(said, ["Couldn't undo the change to the figure — it changed on another device."])
        XCTAssertEqual(try ops(of: record.id).count, count, "nothing was appended")
        await doc.close()
    }

    /// **Review Focus 5**: an undo whose cell another device has since
    /// rewritten declines, rather than clobber the other device's value.
    func test_undoOfACellAnotherDeviceRewroteDeclines() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let key = try firstKey(doc)
        let um = UndoManager()
        try await doc.setCell(text("mine"), at: key, undoManager: um)

        let other = LocalIdentities.softwareForTesting()
        let theirs = OpLogStore(
            projectURL: projectURL, identities: other,
            state: OpLogDeviceState(fileURL: projectURL.appendingPathComponent("other-state.json")))
        try await theirs.append(Op(
            opId: ULID.generate(), docId: record.id, at: Date(), device: other.author.deviceId,
            session: "x", kind: .figureCellSet, changes: [],
            figure: FigureOpPayload(cell: key, next: text("theirs"), prior: text("mine"))))
        _ = try await theirs.sealChain(docId: record.id)
        try await doc.reload()
        XCTAssertEqual(doc.state.table[key], text("theirs"), "precondition: their write arrived")
        let count = try ops(of: record.id).count

        let said = await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, ["Couldn't undo the change to the figure — it changed on another device."])
        XCTAssertEqual(doc.state.table[key], text("theirs"), "their value stands")
        XCTAssertEqual(try ops(of: record.id).count, count, "nothing was appended")
        await doc.close()
    }

    /// Another device's op on this figure, appended and sealed under its own
    /// identity, then read into `doc`.
    private func theirOp(
        _ doc: FigureDocument, _ kind: OpKind, _ payload: FigureOpPayload
    ) async throws {
        let other = LocalIdentities.softwareForTesting()
        let theirs = OpLogStore(
            projectURL: projectURL, identities: other,
            state: OpLogDeviceState(fileURL: projectURL.appendingPathComponent("other-\(UUID().uuidString).json")))
        try await theirs.append(Op(
            opId: ULID.generate(), docId: doc.figureId, at: Date(), device: other.author.deviceId,
            session: "x", kind: kind, changes: [], figure: payload))
        _ = try await theirs.sealChain(docId: doc.figureId)
        try await doc.reload()
    }

    /// **Ruling R-6a-13 (Review Focus 5)**: the inverse of an insert is a
    /// delete, which takes every cell and pin in the row or column and which
    /// 6a cannot undo. So an undo of an insert declines once another device
    /// has typed into (or pinned) the inserted row or column — their content
    /// stands; an empty one still undoes (the control).
    func test_undoOfAnInsertDeclinesOnceAnotherDeviceFilledIt() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let um = UndoManager()
        um.groupsByEvent = false
        let declined = "Couldn't undo the change to the figure — it changed on another device."

        // A row another device typed into.
        um.beginUndoGrouping()
        let row = try await doc.insertRow(after: doc.state.table.rows.last, undoManager: um)
        um.endUndoGrouping()
        let rowKey = CellKey(row: row, column: try XCTUnwrap(doc.state.table.columns.first))
        try await theirOp(doc, .figureCellSet, FigureOpPayload(cell: rowKey, next: text("theirs"), prior: nil))
        XCTAssertEqual(doc.state.table[rowKey], text("theirs"), "precondition: their cell arrived")
        var count = try ops(of: record.id).count
        var said = await notices { um.undo(); await doc.awaitPendingUndoWork() }
        XCTAssertEqual(said, [declined])
        XCTAssertNotNil(doc.state.table.rowIndex(of: row), "the row stands")
        XCTAssertEqual(doc.state.table[rowKey], text("theirs"), "and their cell with it")
        XCTAssertEqual(try ops(of: record.id).count, count, "nothing was appended")

        // A column another device pinned research into (no cell value).
        um.beginUndoGrouping()
        let column = try await doc.insertColumn(after: doc.state.table.columns.last, undoManager: um)
        um.endUndoGrouping()
        let colKey = CellKey(row: try XCTUnwrap(doc.state.table.rows.first), column: column)
        let pin = FigureResearchPin(
            research: "r-1", row: 0, column: 0, value: .text("v"), sourceHash: "h", at: Date())
        try await theirOp(doc, .figurePinSet, FigureOpPayload(cell: colKey, pin: pin))
        XCTAssertNil(doc.state.table[colKey])
        XCTAssertNotNil(doc.state.pins[colKey], "precondition: their pin arrived")
        count = try ops(of: record.id).count
        said = await notices { um.undo(); await doc.awaitPendingUndoWork() }
        XCTAssertEqual(said, [declined])
        XCTAssertNotNil(doc.state.table.columnIndex(of: column), "the column stands")
        XCTAssertNotNil(doc.state.pins[colKey], "and their pin with it")
        XCTAssertEqual(try ops(of: record.id).count, count, "nothing was appended")

        // Control: an inserted row nobody touched still undoes.
        um.beginUndoGrouping()
        let empty = try await doc.insertRow(after: nil, undoManager: um)
        um.endUndoGrouping()
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertNil(doc.state.table.rowIndex(of: empty), "an empty inserted row undoes")
        await doc.close()
    }

    /// **Final review I-5**: a reload whose read began before a local edit
    /// reached the stream keeps that edit — it is not dropped from `state`
    /// until the echo's reload, so the next edit's `prior` is right.
    func test_aReloadKeepsALocalEditThatCommittedDuringItsRead() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let key = try firstKey(doc)
        FigureDocument.afterReloadReadForTesting = { d in
            FigureDocument.afterReloadReadForTesting = nil
            try? await d.setCell(self.text("typed during the read"), at: key, undoManager: nil)
        }

        try await doc.reload()

        XCTAssertEqual(doc.state.table[key], text("typed during the read"),
                       "the edit that committed during the read survives it")
        try await doc.setCell(text("next"), at: key, undoManager: nil)
        XCTAssertEqual(try ops(of: record.id).last?.figure?.prior, text("typed during the read"),
                       "and the next edit's prior is what the table held")
        try await doc.reload()
        XCTAssertEqual(doc.state.table[key], text("next"), "a later read agrees")
        await doc.close()
    }

    /// **Residual N-1**: an own op the read SAW but did not apply — here a
    /// scoped author's cell, held once its figure's record has left the
    /// manifest (`.unregisteredFigure`) — is not carried over the read. The
    /// window agrees with the derivation, not with what it wrote.
    func test_aReloadThatHoldsALocalEditDoesNotKeepShowingIt() async throws {
        let root = try makeForeignRoot()
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "a_table", piece: Self.pieceA)
        try narrow(identities.author.fingerprint, by: root, pieces: [Self.pieceA], mark: try appliedSoFar())
        let doc = try await load(record.id)
        let key = try firstKey(doc)
        try await doc.setCell(text("hers"), at: key, undoManager: nil)
        XCTAssertEqual(doc.state.table[key], text("hers"), "precondition: her edit applied")

        // The record leaves (another Mac's manifest): her line is now held.
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.figures = []
        try ProjectManifest.encodeForDisk(manifest).write(to: manifestURL)

        try await doc.reload()
        let fresh = try await load(record.id)
        XCTAssertGreaterThan(doc.provenance?.pendingLines ?? 0, 0, "precondition: the read held her line")
        XCTAssertNil(fresh.state.table[key], "precondition: a fresh read does not apply it")
        XCTAssertNil(doc.state.table[key], "the window does not keep showing a line the read held")
        XCTAssertEqual(doc.state, fresh.state, "it agrees with the derivation")
        await fresh.close()
        await doc.close()
    }

    // MARK: - Registry fixtures

    /// A foreign root that admits this device as a book author.
    private func makeForeignRoot() throws -> DeviceIdentity {
        let root = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: root.fingerprint, name: "The other Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: root.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1_000)),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: root.fingerprint, label: "Sam", ownName: "The other Mac",
                role: Permit.authorRole, admittedAt: Date(timeIntervalSince1970: 1_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        try writeThisDevicesRecord()
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: "Denver", ownName: "This Mac",
                role: Permit.authorRole, admittedAt: Date(timeIntervalSince1970: 2_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        return root
    }

    private func writeThisDevicesRecord() throws {
        try RegistryWriter.write(
            DeviceRecord(
                device: identities.author.fingerprint, name: "This Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, identities[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 2_000)),
            signedBy: identities.author, in: projectURL)
    }

    private func narrow(
        _ subject: String, by root: DeviceIdentity, pieces: [String],
        mark: [String: PermitMark.StreamMark] = [:]
    ) throws {
        try RegistryWriter.write(
            PermitEvent(
                event: PermitEvent.mintID(subject: subject), kind: .scopeChanged,
                subject: subject, role: Permit.authorRole, scope: Permit.piecesScope,
                pieces: pieces, mark: mark,
                at: Date(timeIntervalSince1970: 3_000), by: root.fingerprint),
            signedBy: root, in: projectURL)
    }

    private func appliedSoFar() throws -> [String: PermitMark.StreamMark] {
        try OpLogStore.appliedPositions(
            ofDeviceIds: Set(identities.all.map(\.deviceId)),
            in: projectURL,
            trust: try TrustResolution.resolve(
                projectURL: projectURL, identities: identities)).streams
    }

    // MARK: - The door

    /// **An author of piece A may not change a figure created in piece B** —
    /// every mutator throws `FigureEditRefused` naming `.figure`, and nothing
    /// is appended. A figure of her own piece she may change (the control).
    func test_anAuthorOfPieceAMayNotChangeAFigureOfPieceB() async throws {
        let root = try makeForeignRoot()
        let store = try await ProjectStore.load(from: projectURL)
        let theirs = try await store.createFigure(kind: .table, name: "b_table", piece: Self.pieceB)
        let hers = try await store.createFigure(kind: .table, name: "a_table", piece: Self.pieceA)
        try narrow(identities.author.fingerprint, by: root, pieces: [Self.pieceA], mark: try appliedSoFar())

        let doc = try await load(theirs.id)
        XCTAssertEqual(doc.state.table.rows.count, 3, "precondition: the figure reads")
        let key = try firstKey(doc)
        let before = try streamBytes(of: theirs.id)
        let um = UndoManager()

        let presses: [(String, () async throws -> Void)] = [
            ("setCell", { try await doc.setCell(self.text("x"), at: key, undoManager: um) }),
            ("insertRow", { _ = try await doc.insertRow(after: nil, undoManager: um) }),
            ("insertColumn", { _ = try await doc.insertColumn(after: nil, undoManager: um) }),
            ("deleteRow", { try await doc.deleteRow(key.row) }),
            ("deleteColumn", { try await doc.deleteColumn(key.column) }),
            ("reviveRow", { try await doc.reviveRow(key.row, removed: FigureRemovedSlice(), undoManager: um) }),
            ("reviveColumn", {
                try await doc.reviveColumn(key.column, removed: FigureRemovedSlice(), undoManager: um)
            }),
            ("moveRow", { try await doc.moveRow(key.row, after: doc.state.table.rows.last, undoManager: um) }),
            ("moveColumn", { try await doc.moveColumn(key.column, after: doc.state.table.columns.last, undoManager: um) }),
            ("setHeaderRows", { try await doc.setHeaderRows(1, undoManager: um) }),
            ("setTotalRow", { try await doc.setTotalRow(true, undoManager: um) }),
            ("setColumnWidth", { try await doc.setColumnWidth(key.column, 80, undoManager: um) }),
        ]
        for (name, press) in presses {
            do {
                try await press()
                XCTFail("\(name) was not refused")
            } catch let refused as FigureEditRefused {
                XCTAssertEqual(refused.what, .figure, name)
                XCTAssertEqual(refused.site, name)
            } catch {
                XCTFail("\(name) threw \(error), not FigureEditRefused")
            }
        }
        XCTAssertEqual(try streamBytes(of: theirs.id), before, "no op was appended")
        XCTAssertEqual(doc.state.table.rows.count, 3)
        XCTAssertNil(doc.state.table[key])
        XCTAssertFalse(um.canUndo, "and nothing was registered")

        // Creating one there is refused at the same door.
        do {
            _ = try await store.createFigure(kind: .table, name: "more", piece: Self.pieceB)
            XCTFail("creating a figure in somebody else's piece was not refused")
        } catch let refused as FigureEditRefused {
            XCTAssertEqual(refused.what, .figure)
        }

        let own = try await load(hers.id)
        try await own.setCell(text("hers"), at: try firstKey(own), undoManager: nil)
        XCTAssertEqual(own.state.table[try firstKey(own)], text("hers"), "her own piece's figure she may change")
        await doc.close()
        await own.close()
    }

    /// **The partition sees `.figure`**: a cell written into a figure of piece
    /// A by a device whose author is narrowed to piece B is set aside on a book
    /// author's Mac once piece A is claimed; the same device's write into a
    /// figure of piece B applies. The figure follows its piece exactly
    /// (Denver's ruling R-D4), and a book author's figure ops claim the piece
    /// as her text would (the revised ruling, final fix wave): the root MADE
    /// piece A's figure, its `figureCreate` and inserts, so piece A is claimed
    /// before Sam writes, and his line there is set aside, never held.
    func test_aFigureLineFromAPieceBOnlyDeviceIsSetAside() async throws {
        // This device is the book's root.
        try writeThisDevicesRecord()
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: "Denver", ownName: "This Mac",
                role: Permit.authorRole, admittedAt: Date(timeIntervalSince1970: 1_000),
                admittedBy: identities.author.fingerprint),
            signedBy: identities.author, in: projectURL)
        // Sam's Mac, admitted and narrowed to piece B.
        let sam = LocalIdentities.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: sam.author.fingerprint, name: "Sam's Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, sam[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 2_000)),
            signedBy: sam.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: sam.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
                role: Permit.authorRole, admittedAt: Date(timeIntervalSince1970: 2_000),
                admittedBy: identities.author.fingerprint),
            signedBy: identities.author, in: projectURL)
        try narrow(sam.author.fingerprint, by: identities.author, pieces: [Self.pieceB])

        let store = try await ProjectStore.load(from: projectURL)
        let ofA = try await store.createFigure(kind: .table, name: "of_a", piece: Self.pieceA)
        let ofB = try await store.createFigure(kind: .table, name: "of_b", piece: Self.pieceB)
        let readA = try await load(ofA.id)
        let readB = try await load(ofB.id)
        let keyA = try firstKey(readA)
        let keyB = try firstKey(readB)
        await readA.close()
        await readB.close()

        let samsStore = OpLogStore(
            projectURL: projectURL, identities: sam,
            state: OpLogDeviceState(fileURL: projectURL.appendingPathComponent("sam-state.json")))
        for (id, key) in [(ofA.id, keyA), (ofB.id, keyB)] {
            try await samsStore.append(Op(
                opId: ULID.generate(), docId: id, at: Date(), device: sam.author.deviceId,
                session: "sam", kind: .figureCellSet, changes: [],
                figure: FigureOpPayload(cell: key, next: text("sam"), prior: nil)))
            _ = try await samsStore.sealChain(docId: id)
        }

        // No word of piece A's text was written: the root's figure ops alone
        // claimed it.
        XCTAssertTrue(OpLogStore.opLogFileURLs(forDocId: Self.pieceA, in: projectURL).isEmpty,
                      "premise: piece A's text has no stream")
        let a = try await load(ofA.id)
        XCTAssertEqual(a.provenance?.pendingLines, 0, "claimed, so not held")
        XCTAssertNil(a.state.table[keyA], "Sam's line in piece A's figure is set aside")
        XCTAssertGreaterThan(a.provenance?.quarantinedLines ?? 0, 0, "and counted as set aside")
        XCTAssertEqual(a.state.table.rows.count, 3, "the book author's own lines stand")

        let b = try await load(ofB.id)
        XCTAssertEqual(b.state.table[keyB], text("sam"), "control: in his own piece's figure it applies")
        await a.close()
        await b.close()
    }

    /// **Ruling R-6a-12**: a figure's stream is written before its record and
    /// the two sync independently, so a receiving Mac routinely reads a
    /// scoped author's figure lines before the record naming her piece. Those
    /// lines are HELD — not applied, and not set aside as written by a device
    /// that may not write here — and the same lines apply once the record
    /// lands.
    func test_aScopedAuthorsFigureLineAheadOfItsRecordIsHeldThenAppliesWhenTheRecordLands() async throws {
        let sam = try rootWithSamNarrowedToPieceB()
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        let withoutRecord = try Data(contentsOf: manifestURL)

        let store = try await ProjectStore.load(from: projectURL)
        let ofB = try await store.createFigure(kind: .table, name: "of_b", piece: Self.pieceB)
        let read = try await load(ofB.id)
        let key = try firstKey(read)
        await read.close()
        let withRecord = try Data(contentsOf: manifestURL)

        let samsStore = OpLogStore(
            projectURL: projectURL, identities: sam,
            state: OpLogDeviceState(fileURL: projectURL.appendingPathComponent("sam-state.json")))
        try await samsStore.append(Op(
            opId: ULID.generate(), docId: ofB.id, at: Date(), device: sam.author.deviceId,
            session: "sam", kind: .figureCellSet, changes: [],
            figure: FigureOpPayload(cell: key, next: text("sam"), prior: nil)))
        _ = try await samsStore.sealChain(docId: ofB.id)

        // The stream has arrived; the record has not.
        try withoutRecord.write(to: manifestURL)
        let early = try await load(ofB.id)
        XCTAssertNil(early.state.table[key], "Sam's line is not applied before its record")
        XCTAssertGreaterThan(early.provenance?.pendingLines ?? 0, 0, "it is HELD")
        XCTAssertEqual(early.provenance?.quarantinedLines ?? -1, 0, "and never set aside")
        XCTAssertEqual(early.state.table.rows.count, 3, "the book author's own lines stand")
        await early.close()

        // The record lands: the same lines are judged again, and apply.
        try withRecord.write(to: manifestURL)
        let late = try await load(ofB.id)
        XCTAssertEqual(late.state.table[key], text("sam"), "applied once the record names his piece")
        XCTAssertEqual(late.provenance?.pendingLines ?? -1, 0)
        await late.close()
    }

    /// This device is the book's root; Sam's Mac is admitted and narrowed to
    /// piece B. Answers Sam's identities.
    private func rootWithSamNarrowedToPieceB() throws -> LocalIdentities {
        try writeThisDevicesRecord()
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: "Denver", ownName: "This Mac",
                role: Permit.authorRole, admittedAt: Date(timeIntervalSince1970: 1_000),
                admittedBy: identities.author.fingerprint),
            signedBy: identities.author, in: projectURL)
        let sam = LocalIdentities.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: sam.author.fingerprint, name: "Sam's Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, sam[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 2_000)),
            signedBy: sam.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: sam.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
                role: Permit.authorRole, admittedAt: Date(timeIntervalSince1970: 2_000),
                admittedBy: identities.author.fingerprint),
            signedBy: identities.author, in: projectURL)
        try narrow(sam.author.fingerprint, by: identities.author, pieces: [Self.pieceB])
        return sam
    }

    // MARK: - The window's door (ruling R-6a-8)

    /// A window on the book: this Mac roots the empty book at open.
    private func openWindow() async throws -> (DocumentStore, ProjectStore) {
        let store = try await DocumentStore.open(url: projectURL)
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        await store.postureSettled()
        return (store, projectStore)
    }

    /// Sam is admitted as the author of piece B, so this root yields on B.
    private func samWritesPieceB(_ store: DocumentStore) async throws {
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces([Self.pieceB])))
        await store.postureSettled()
    }

    /// **A figure follows its piece's window posture**: while the root yields
    /// piece B to Sam, B's text and B's figures are both refused — editing one
    /// and creating one; *Edit Anyway* on the piece lifts both.
    func test_aFigureInAYieldedPieceIsRefusedWhileItsTextIs_editAnywayLiftsBoth() async throws {
        let (store, projectStore) = try await openWindow()
        let record = try await projectStore.createFigure(kind: .table, name: "b_table", piece: Self.pieceB)
        try await samWritesPieceB(store)
        XCTAssertFalse(store.posture(forDocId: Self.pieceB).allows(.writeText),
                       "precondition: the piece's text is yielded")

        let doc = try await FigureDocument.load(
            figureId: record.id, projectURL: projectURL, actor: .author,
            session: "s", presenter: nil, documentStore: store)
        let key = try firstKey(doc)
        let before = try streamBytes(of: record.id)
        do {
            try await doc.setCell(text("x"), at: key, undoManager: nil)
            XCTFail("an edit in a yielded piece's figure was not refused")
        } catch let refused as FigureEditRefused {
            XCTAssertEqual(refused.what, .figure)
        }
        do {
            _ = try await projectStore.createFigure(kind: .table, name: "more", piece: Self.pieceB)
            XCTFail("creating a figure in a yielded piece was not refused")
        } catch is FigureEditRefused {}
        XCTAssertEqual(try streamBytes(of: record.id), before, "nothing was appended")
        XCTAssertEqual(projectStore.manifest.figures?.count, 1, "and nothing was created")

        store.overrideYield(docId: Self.pieceB)
        XCTAssertTrue(store.posture(forDocId: Self.pieceB).allows(.writeText),
                      "Edit Anyway lifts the piece's text")
        try await doc.setCell(text("x"), at: key, undoManager: nil)
        XCTAssertEqual(doc.state.table[key], text("x"), "and its figure")
        let more = try await projectStore.createFigure(kind: .table, name: "more", piece: Self.pieceB)
        XCTAssertEqual(more.piece, Self.pieceB, "and creating one there")
        await doc.close()
    }

    /// **An undo refused at the door declines out loud**: the edit was made
    /// while this Mac could write the figure; the yield began afterwards.
    func test_anUndoRefusedAtTheDoorDeclines() async throws {
        let (store, projectStore) = try await openWindow()
        let record = try await projectStore.createFigure(kind: .table, name: "b_table", piece: Self.pieceB)
        let doc = try await FigureDocument.load(
            figureId: record.id, projectURL: projectURL, actor: .author,
            session: "s", presenter: nil, documentStore: store)
        let key = try firstKey(doc)
        let um = UndoManager()
        try await doc.setCell(text("mine"), at: key, undoManager: um)
        try await samWritesPieceB(store)
        let count = try ops(of: record.id).count

        let said = await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, ["Couldn't change the table — this Mac can no longer change this figure."])
        XCTAssertEqual(doc.state.table[key], text("mine"), "the edit stands")
        XCTAssertEqual(try ops(of: record.id).count, count, "nothing was appended")
        await doc.close()
    }

    // MARK: - Image figures (report plan 6a Task 9)

    /// A real PNG outside the project, of one colour, so two colours hash apart.
    private func png(_ name: String, _ color: NSColor) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("figdoc-png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let url = dir.appendingPathComponent(name)
        try ImagePasteHandler.encodePNG(image).write(to: url)
        return url
    }

    private func figureFile(_ name: String) -> URL {
        projectURL.appendingPathComponent("figures").appendingPathComponent(name)
    }

    /// **An image figure is born from its picture**: the file is copied into
    /// `figures/`, the stream opens with `figureCreate(.image)` and one
    /// `figureImageSet` carrying the file's name and hash, and the record
    /// names `figures/<name>.<ext>` with the piece it was made in.
    func test_createImageFigure_copiesIntoFiguresAndRecordsTheFilesHash() async throws {
        let (store, projectStore) = try await openWindow()
        let source = try png("Site Map.png", .red)

        let record = try await projectStore.createImageFigure(fromURL: source, piece: Self.pieceA)

        XCTAssertEqual(record.name, "site-map")
        XCTAssertEqual(record.kind, .image)
        XCTAssertEqual(record.piece, Self.pieceA)
        XCTAssertEqual(record.path, "figures/site-map.png")
        XCTAssertEqual(try Data(contentsOf: figureFile("site-map.png")), try Data(contentsOf: source))
        let written = try ops(of: record.id)
        XCTAssertEqual(written.map(\.kind), [.figureCreate, .figureImageSet])
        let hash = try FigureImageResolver.contentHash(of: source)
        XCTAssertEqual(written.last?.figure?.image,
                       FigureImageRef(filename: "site-map.png", contentHash: hash))
        XCTAssertNil(written.last?.figure?.priorImage, "a first picture replaces nothing")

        let doc = try await store.openFigure(figureId: record.id)
        XCTAssertEqual(doc.state.image, FigureImageRef(filename: "site-map.png", contentHash: hash))
        await store.closeFigure(figureId: record.id)
    }

    /// Refused at the figure's door, nothing is copied or written.
    func test_createImageFigureInAYieldedPieceCopiesNothing() async throws {
        let (store, projectStore) = try await openWindow()
        try await samWritesPieceB(store)
        do {
            _ = try await projectStore.createImageFigure(fromURL: try png("a.png", .red), piece: Self.pieceB)
            XCTFail("an image figure in a yielded piece was not refused")
        } catch is FigureEditRefused {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: figureFile("a.png").path))
        XCTAssertTrue(projectStore.manifest.figures?.isEmpty ?? true)
    }

    /// **Replacing a picture is a recorded change, and ⌘Z puts the old one
    /// back**: the file is replaced under its own name, one `figureImageSet`
    /// carries the new hash and the prior picture; undo restores the old bytes
    /// and appends the inverse; redo puts the new picture back.
    func test_setImage_replacesTheFile_undoRestoresTheOldPicture_redoReappliesIt() async throws {
        let (store, projectStore) = try await openWindow()
        let first = try png("chart.png", .red)
        let record = try await projectStore.createImageFigure(fromURL: first, piece: Self.pieceA)
        let doc = try await store.openFigure(figureId: record.id)
        let file = figureFile("chart.png")
        let oldBytes = try Data(contentsOf: file)
        let old = try XCTUnwrap(doc.state.image)
        let second = try png("other name.png", .blue)
        let newBytes = try Data(contentsOf: second)
        let um = UndoManager()

        try await doc.setImage(fromURL: second, undoManager: um)

        XCTAssertEqual(try Data(contentsOf: file), newBytes, "the file was replaced in place")
        let next = FigureImageRef(filename: "chart.png",
                                  contentHash: try FigureImageResolver.contentHash(of: second))
        XCTAssertEqual(doc.state.image, next, "the file keeps its name, so every line still finds it")
        let set = try XCTUnwrap(try ops(of: record.id).last?.figure)
        XCTAssertEqual(set.image, next)
        XCTAssertEqual(set.priorImage, old)
        XCTAssertEqual(projectStore.manifest.figures?.first?.path, "figures/chart.png")
        XCTAssertTrue(um.canUndo)

        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(try Data(contentsOf: file), oldBytes, "undo put the old picture back")
        XCTAssertEqual(doc.state.image, old)
        XCTAssertEqual(try ops(of: record.id).last?.figure?.image, old, "and appended the inverse")

        um.redo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(try Data(contentsOf: file), newBytes, "redo put the new picture back")
        XCTAssertEqual(doc.state.image, next)
        XCTAssertTrue(um.canUndo, "and the redo is undoable again")

        let count = try ops(of: record.id).count
        try await doc.setImage(fromURL: second, undoManager: um)
        XCTAssertEqual(try ops(of: record.id).count, count, "the same picture again writes nothing")
        await store.closeFigure(figureId: record.id)
    }

    /// **A failed append keeps the file and the history agreeing** (final
    /// review T9): the replaced picture goes back on disk when the replace's
    /// op cannot be written, and an undo whose op cannot be written puts the
    /// newer picture back and says it did not happen (T6).
    func test_aFailedAppendPutsThePictureBackAndAFailedUndoSaysSo() async throws {
        struct Refused: Error {}
        let (store, projectStore) = try await openWindow()
        let first = try png("chart.png", .red)
        let record = try await projectStore.createImageFigure(fromURL: first, piece: Self.pieceA)
        let doc = try await store.openFigure(figureId: record.id)
        let file = figureFile("chart.png")
        let oldBytes = try Data(contentsOf: file)
        let old = try XCTUnwrap(doc.state.image)
        let second = try png("second.png", .blue)
        let newBytes = try Data(contentsOf: second)

        FigureDocument.beforeCommitAppendForTesting = { _ in throw Refused() }
        do {
            try await doc.setImage(fromURL: second, undoManager: nil)
            XCTFail("the append was refused, so the replace throws")
        } catch is Refused {}
        XCTAssertEqual(try Data(contentsOf: file), oldBytes, "the picture the op log names is back")
        XCTAssertEqual(doc.state.image, old)

        FigureDocument.beforeCommitAppendForTesting = nil
        let um = UndoManager()
        try await doc.setImage(fromURL: second, undoManager: um)
        XCTAssertEqual(try Data(contentsOf: file), newBytes)
        let count = try ops(of: record.id).count
        FigureDocument.beforeCommitAppendForTesting = { _ in throw Refused() }
        let said = await notices { um.undo(); await doc.awaitPendingUndoWork() }
        XCTAssertEqual(said, ["Couldn't change the figure — the change could not be saved."])
        XCTAssertEqual(try ops(of: record.id).count, count, "nothing was appended")
        XCTAssertEqual(try Data(contentsOf: file), newBytes, "and the file still holds what the op log names")
        XCTAssertNotEqual(doc.state.image, old)
        FigureDocument.beforeCommitAppendForTesting = nil
        await store.closeFigure(figureId: record.id)
    }

    /// A failed compensating append on a table edit is said too (T6).
    func test_aCellUndoWhoseAppendFailsSaysSo() async throws {
        struct Refused: Error {}
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let key = try firstKey(doc)
        let um = UndoManager()
        try await doc.setCell(text("one"), at: key, undoManager: um)
        FigureDocument.beforeCommitAppendForTesting = { _ in throw Refused() }
        let said = await notices { um.undo(); await doc.awaitPendingUndoWork() }
        FigureDocument.beforeCommitAppendForTesting = nil
        XCTAssertEqual(said, ["Couldn't change the figure — the change could not be saved."])
        XCTAssertEqual(doc.state.table[key], text("one"), "the cell is as it was")
        await doc.close()
    }

    /// A picture in another format would break every line pointing at the
    /// file's name: refused, nothing written.
    func test_aPictureOfAnotherFormatCannotReplaceTheFigures() async throws {
        let (store, projectStore) = try await openWindow()
        let record = try await projectStore.createImageFigure(
            fromURL: try png("chart.png", .red), piece: Self.pieceA)
        let doc = try await store.openFigure(figureId: record.id)
        let before = try streamBytes(of: record.id)
        let pdf = TestTemp.root.appendingPathComponent("figdoc-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 20, height: 20)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.fill(box); context.endPDFPage(); context.closePDF()
        defer { try? FileManager.default.removeItem(at: pdf) }

        do {
            try await doc.setImage(fromURL: pdf)
            XCTFail("a PDF replaced a PNG figure's picture")
        } catch is FigureEditInvalid {}
        XCTAssertEqual(try streamBytes(of: record.id), before)
        await store.closeFigure(figureId: record.id)
    }

    /// **A figure's first picture has no inverse**: nothing is registered on
    /// ⌘Z, and the record's path gains the file's extension.
    func test_aFirstPictureRegistersNoUndoAndGivesTheRecordItsExtension() async throws {
        let (store, projectStore) = try await openWindow()
        let record = try await projectStore.createFigure(kind: .image, name: "plan", piece: Self.pieceA)
        XCTAssertEqual(record.path, "figures/plan")
        let doc = try await store.openFigure(figureId: record.id)
        let um = UndoManager()

        try await doc.setImage(fromURL: try png("anything.png", .green), undoManager: um)

        XCTAssertFalse(um.canUndo, "a first picture replaces nothing, so there is no ⌘Z")
        XCTAssertEqual(doc.state.image?.filename, "plan.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: figureFile("plan.png").path))
        XCTAssertEqual(projectStore.manifest.figures?.first?.path, "figures/plan.png")
        await store.closeFigure(figureId: record.id)
    }

    // MARK: - Write order

    /// **The stream first, the record second**: an append that fails leaves no
    /// registry record — at most a stream nobody lists.
    func test_aFailedAppendLeavesNoRecord() async throws {
        struct Boom: Error {}
        let store = try await ProjectStore.load(from: projectURL)
        ProjectStore.beforeFigureAppendForTesting = { op in
            if op.kind == .figureStructure { throw Boom() }
        }
        do {
            _ = try await store.createFigure(kind: .table, name: "t", piece: nil)
            XCTFail("the injected append failure did not surface")
        } catch is Boom {}
        XCTAssertTrue(store.manifest.figures?.isEmpty ?? true, "no record in memory")
        let onDisk = try ProjectManifest.makeDecoder().decode(
            ProjectManifest.self,
            from: Data(contentsOf: projectURL.appendingPathComponent(ProjectManifest.fileName)))
        XCTAssertNil(onDisk.figures, "and none on disk")

        ProjectStore.beforeFigureAppendForTesting = nil
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        XCTAssertEqual(record.name, "t", "the name was never taken")
    }
}
