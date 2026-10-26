import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **Cut, copy and paste in the table grid** (report plan 7d Task 3, rulings
/// R7d-2 and R7d-3): driven through the controller's verbs and through the
/// Edit menu's actions sent to the grid as first responder — the path ⌘C,
/// ⌘X and ⌘V take — over a real store and host, on a private pasteboard
/// (never the general one). No button is pressed (tripwire 33).
@MainActor
final class FigureGridClipboardTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var projectURL: URL!
    private var projectStore: ProjectStore?
    private var renders: [String] = []
    private var window: NSWindow?
    private var controllers: [FigureGridController] = []
    private var stores: [DocumentStore] = []
    /// The visit's own undo stack (plan 7d Task 6): the first grid opened.
    private var um: UndoManager { controllers[0].gridUndo }
    private var board: NSPasteboard!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("gridclipboard-\(UUID().uuidString)")
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
        board = NSPasteboard(name: .init("figure-grid-clipboard-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        for c in controllers {
            await c.settleWrites()
            c.close()
        }
        controllers = []
        for store in stores { await store.close() }
        stores = []
        window?.close()
        window = nil
        board.releaseGlobally()
        board = nil
        DocumentStore.figureHostAppendedForTesting = nil
        FigureGridController.writeTurnForTesting = nil
        FigureGridController.afterPlanForTesting = nil
        projectStore = nil
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// A book with one chapter, a 10×4 table figure `t` and a 3×3 `other`;
    /// the visit on `t` with its grid mounted in a key window.
    private func openGrid() async throws -> (FigureGridController, DocumentStore, ProjectStore, FigureRecord) {
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
        stores.append(store)
        let record = try await projectStore.createFigure(kind: .table, name: "t", piece: nil, rows: 10, columns: 4)
        let other = try await projectStore.createFigure(kind: .table, name: "other", piece: nil)
        let c = try await visit(record.id, store, projectStore)
        let grid = c.gridView
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 520, height: 360))
        grid.frame = CGRect(x: 0, y: 0, width: 520,
                            height: FigureGridLayout.viewportHeight(rows: 10, rowHeight: grid.rowHeight))
        container.addSubview(grid)
        window = TestWindow.make(KeyTestWindow.self, contentRect: container.frame, contentView: container)
        grid.reloadData()
        XCTAssertTrue(window?.makeFirstResponder(grid) ?? false)
        renders = []
        return (c, store, projectStore, other)
    }

    private func visit(_ figureId: String, _ store: DocumentStore, _ projectStore: ProjectStore) async throws
        -> FigureGridController {
        let c = try await FigureGridController.open(
            figureId: figureId, store: store, projectStore: projectStore, typography: .defaults,
            line: .init(number: "Table 1", caption: "Caption", commitCaption: { _ in true }))
        c.pasteboard = board
        controllers.append(c)
        await store.awaitOpenFigureRenderForTesting()
        return c
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func key(_ c: FigureGridController, _ a1: String) -> CellKey {
        let p = A1.parse(a1)!
        let table = c.host.state.table
        return CellKey(row: table.rows[p.row], column: table.columns[p.column])
    }

    private func select(_ c: FigureGridController, _ from: String, _ to: String? = nil) {
        c.handle(.click(key(c, from), extend: false))
        if let to { c.handle(.click(key(c, to), extend: true)) }
    }

    /// `text` typed into `a1` through the formula bar and committed.
    private func type(_ c: FigureGridController, _ a1: String, _ text: String) async {
        select(c, a1)
        c.perform(.formulaTextChanged(text))
        c.perform(.formulaCommand(.returnKey(backward: false)))
        await c.settleWrites()
    }

    /// What the formula bar shows for `a1`.
    private func bar(_ c: FigureGridController, _ a1: String) -> String {
        select(c, a1)
        return c.bars.formulaField.stringValue
    }

    private func ops(of figureId: String) throws -> Int {
        try OpLogStore.opLogFileURLs(forDocId: figureId, in: projectURL).reduce(0) { n, url in
            n + (try Data(contentsOf: url)).split(separator: UInt8(0x0A)).filter { !OpLogChain.isSealLine(Data($0)) }.count
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

    /// **An Edit menu action as ⌘C/⌘X/⌘V sends it**: with the grid first
    /// responder, the action's target found up the responder chain, the item
    /// validated there, then sent.
    private func sendFromTheGrid(_ action: Selector, _ c: FigureGridController) throws {
        let window = try XCTUnwrap(c.gridView.window)
        XCTAssertTrue(window.firstResponder === c.gridView, "premise: the grid has the keys")
        var target: NSResponder? = window.firstResponder
        while let current = target, !current.responds(to: action) { target = current.nextResponder }
        XCTAssertTrue(target === c.gridView, "\(action) stops at the grid")
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        XCTAssertTrue(c.gridView.validateUserInterfaceItem(item), "\(action) is enabled")
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: nil))
    }

    private func putTabSeparated(_ rows: [[String]], html: Bool = true) {
        board.clearContents()
        if html { board.setString(TableHTML.html(rows: rows), forType: .html) }
        board.setString(TableClipboard.tabSeparated(rows), forType: .string)
    }

    // MARK: - Review Focus 1: copy B2:D9 out; paste a block from Excel at C8

    /// **Copy B2:D9** (Review Focus 1): Numbers gets the values the grid
    /// shows — a formula's result, never its text — as tab-separated text
    /// and as an HTML table; Maugham's own flavour rides beside them.
    func test_copyB2toD9PutsTheDisplayedValuesOnThePasteboard() async throws {
        let (c, _, _, _) = try await openGrid()
        await type(c, "B2", "1200")
        await type(c, "C3", "=B2*2")
        await type(c, "D9", "Total")
        let opsBefore = try ops(of: c.figureId)
        select(c, "B2", "D9")
        try sendFromTheGrid(#selector(NSText.copy(_:)), c)

        let display = (2...9).map { row in ["B", "C", "D"].map { c.figureGridDisplay(at: key(c, "\($0)\(row)")) } }
        XCTAssertEqual(display[1][1], c.figureGridDisplay(at: key(c, "C3")))
        XCTAssertFalse(display[1][1].hasPrefix("="), "the formula's value, not its text: \(display[1][1])")
        XCTAssertTrue(display[1][1].contains("2"), "\(display[1][1])")
        let tsv = try XCTUnwrap(board.string(forType: .string))
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: tsv), display, "plain text is the displayed values")
        XCTAssertEqual(board.string(forType: .tabularText), tsv)
        XCTAssertEqual(TableHTML.rows(fromHTML: try XCTUnwrap(board.string(forType: .html))), display)
        XCTAssertNotNil(board.data(forType: FigureGridClipboard.cellsType), "Maugham's own cells ride beside")
        XCTAssertEqual(try ops(of: c.figureId), opsBefore, "a copy writes nothing")
    }

    /// **A 4×3 block copied from Excel, pasted at C8 of the 10-row, 4-column
    /// table** (Review Focus 1): the table grows a row and a column to fit,
    /// the values land as typing reads them, the pasted cells are selected —
    /// one render, and one ⌘Z removes the growth and the values.
    func test_anExcelBlockPastedAtC8GrowsTheTable_andOneUndoTakesItAllBack() async throws {
        let (c, _, _, _) = try await openGrid()
        let before = c.host.state.table
        putTabSeparated([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["10", "11", "12"]])
        select(c, "C8")
        try sendFromTheGrid(#selector(NSText.paste(_:)), c)
        await c.settleWrites()

        let table = c.host.state.table
        XCTAssertEqual(table.rows.count, 11, "a row added for the block's last")
        XCTAssertEqual(table.columns.count, 5, "and a column")
        XCTAssertEqual(table[key(c, "C8")]?.content, .value(.number(1)))
        XCTAssertEqual(table[key(c, "E11")]?.content, .value(.number(12)))
        XCTAssertEqual(c.bars.addressLabel.stringValue, "C8:E11", "the pasted cells are selected")
        XCTAssertEqual(renders, [c.figureId], "one render")
        XCTAssertEqual(um.undoActionName, "Paste")

        renders = []
        um.undo()
        await c.host.awaitPendingUndoWork()
        XCTAssertEqual(c.host.state.table.rows, before.rows, "one ⌘Z removes the growth")
        XCTAssertEqual(c.host.state.table.columns, before.columns)
        XCTAssertEqual(c.host.state.table.cells, before.cells, "and the values")
        XCTAssertFalse(um.canUndo, "one step")
        um.redo()
        await c.host.awaitPendingUndoWork()
        XCTAssertEqual(c.host.state.table[key(c, "E11")]?.content, .value(.number(12)), "⇧⌘Z pastes again")
    }

    // MARK: - Formulas: the same figure translates, another pastes values

    /// **A formula copied and pasted in the same table moves with the paste**
    /// (R7d-3, Excel): `=A1` copied from B2 and pasted at C4 reads `=B3`; a
    /// `$` part stays.
    func test_aFormulaPastedInTheSameTableIsTranslated() async throws {
        let (c, _, _, _) = try await openGrid()
        await type(c, "B2", "=A1+$A$1")
        select(c, "B2")
        try sendFromTheGrid(#selector(NSText.copy(_:)), c)
        select(c, "C4")
        try sendFromTheGrid(#selector(NSText.paste(_:)), c)
        await c.settleWrites()
        XCTAssertEqual(bar(c, "C4"), "=B3+$A$1")
        XCTAssertEqual(bar(c, "B2"), "=A1+$A$1", "the source is untouched")
    }

    /// **A formula copied from ANOTHER figure pastes as the value it showed**
    /// (the controller's ruling): no reference into another table is
    /// carried across; plain values and formats come as they are.
    func test_aFormulaFromAnotherFigurePastesAsItsValue() async throws {
        let (c, store, projectStore, other) = try await openGrid()
        let o = try await visit(other.id, store, projectStore)
        await type(o, "A1", "5")
        await type(o, "B1", "=A1*2")
        select(o, "A1", "B1")
        XCTAssertTrue(o.copySelection())

        select(c, "A2")
        c.paste()
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[key(c, "A2")]?.content, .value(.number(5)))
        XCTAssertEqual(c.host.state.table[key(c, "B2")]?.content, .value(.number(10)),
                       "the other table's formula came as its value")
    }

    /// **One cell copied into a range fills it** (Excel's tiling).
    func test_oneCellPastedIntoARangeFillsIt() async throws {
        let (c, _, _, _) = try await openGrid()
        await type(c, "A2", "=A1+1")
        select(c, "A2")
        XCTAssertTrue(c.copySelection())
        select(c, "B3", "C4")
        c.paste()
        await c.settleWrites()
        XCTAssertEqual(bar(c, "B3"), "=B2+1")
        XCTAssertEqual(bar(c, "C4"), "=C3+1")
        XCTAssertEqual(um.undoActionName, "Paste")
    }

    // MARK: - What a paste reads, in order

    /// **Maugham's own flavour, then HTML, then tab-separated, then plain
    /// text** (the task's contract): each read when the ones before it are
    /// absent.
    func test_aPasteReadsItsOwnTypeThenHTMLThenTabSeparatedThenPlainText() throws {
        let own = FigureGridClipboard.Cells(
            figureId: "f", originRow: 0, originColumn: 0,
            cells: [[Cell(content: .value(.number(1)))]], values: [[.number(1)]])
        FigureGridClipboard.write(own, display: [["one"]], to: board)
        XCTAssertEqual(FigureGridClipboard.read(from: board), .cells(own))

        board.clearContents()
        board.setString("<table><tr><td>h</td></tr></table>", forType: .html)
        board.setString("t\tu\n", forType: .tabularText)
        board.setString("p", forType: .string)
        XCTAssertEqual(FigureGridClipboard.read(from: board), .text([["h"]]))

        board.clearContents()
        board.setString("<p>no table</p>", forType: .html)
        board.setString("t\t\"u\nv\"\n", forType: .tabularText)
        board.setString("p", forType: .string)
        XCTAssertEqual(FigureGridClipboard.read(from: board), .text([["t", "u\nv"]]), "a fragment without a table falls through")

        board.clearContents()
        board.setString("\"quoted\" words", forType: .string)
        XCTAssertEqual(FigureGridClipboard.read(from: board), .text([["\"quoted\" words"]]),
                       "plain text without a tab keeps its quotes")

        board.clearContents()
        board.setString("a\t\"b\"\n", forType: .string)
        XCTAssertEqual(FigureGridClipboard.read(from: board), .text([["a", "b"]]),
                       "a spreadsheet's plain text is read with its quoting")

        board.clearContents()
        XCTAssertNil(FigureGridClipboard.read(from: board))
        XCTAssertFalse(FigureGridClipboard.canRead(board))
    }

    // MARK: - Cut

    /// **Cut** is a copy and a clear: the pasteboard holds the cells, they
    /// are emptied as one ⌘Z ("Cut"), and a paste elsewhere puts them back.
    func test_cutCopiesAndClearsAsOneUndo() async throws {
        let (c, _, _, _) = try await openGrid()
        // Seeded without the window's undo manager, so the cut is the one step on it.
        try await c.host.setCell(Cell(content: .value(.number(7))), at: key(c, "A2"))
        try await c.host.setCell(Cell(content: .value(.number(8))), at: key(c, "B2"))
        await c.hostSync?.value
        select(c, "A2", "B2")
        try sendFromTheGrid(#selector(NSText.cut(_:)), c)
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[key(c, "A2")])
        XCTAssertNil(c.host.state.table[key(c, "B2")])
        XCTAssertEqual(um.undoActionName, "Cut")
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: try XCTUnwrap(board.string(forType: .string))),
                       [["7", "8"]])

        um.undo()
        await c.host.awaitPendingUndoWork()
        XCTAssertEqual(c.host.state.table[key(c, "A2")]?.content, .value(.number(7)), "one ⌘Z gives the cut back")
        XCTAssertEqual(c.host.state.table[key(c, "B2")]?.content, .value(.number(8)))
        XCTAssertFalse(um.canUndo, "one step")

        select(c, "C5")
        c.paste()
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[key(c, "D5")]?.content, .value(.number(8)), "the cut cells paste")
    }

    /// **A cut pasted in the same table is a move** (review I1, Excel,
    /// Numbers and Sheets): `=SUM(B2:B4)` cut from B5 and pasted at D5 still
    /// sums B2:B4 — never translated to D2:D4. Pasted into another figure a
    /// cut comes as values, as a copy does.
    func test_aCutPastedInTheSameTableKeepsItsFormulasReferences() async throws {
        let (c, store, projectStore, other) = try await openGrid()
        await type(c, "B2", "1")
        await type(c, "B3", "2")
        await type(c, "B4", "3")
        await type(c, "B5", "=SUM(B2:B4)")
        select(c, "B5")
        try sendFromTheGrid(#selector(NSText.cut(_:)), c)
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[key(c, "B5")])
        select(c, "D5")
        try sendFromTheGrid(#selector(NSText.paste(_:)), c)
        await c.settleWrites()
        XCTAssertEqual(bar(c, "D5"), "=SUM(B2:B4)", "a cut moves the formula as it is")
        XCTAssertEqual(c.figureGridValue(at: key(c, "D5")), .number(6))

        let o = try await visit(other.id, store, projectStore)
        select(o, "A1")
        o.paste()
        await o.settleWrites()
        XCTAssertEqual(o.host.state.table[key(o, "A1")]?.content, .value(.number(6)),
                       "into another figure a cut pastes as its value")
    }

    // MARK: - Read-only

    /// **A read-only grid copies, and answers a cut or paste with the reason
    /// line** — enabled, so ⌘X and ⌘V are said rather than beeped — writing
    /// nothing; the cut copies nothing either.
    func test_aReadOnlyGridCopies_andRefusesCutAndPasteWithTheReason() async throws {
        let (c, _, _, _) = try await openGrid()
        await type(c, "A2", "7")
        c.setAccess(.readOnly(.reviewMode), captionMayEdit: false)
        let opsBefore = try ops(of: c.figureId)
        select(c, "A2")

        try sendFromTheGrid(#selector(NSText.copy(_:)), c)
        XCTAssertEqual(TableClipboard.rows(fromTabSeparated: try XCTUnwrap(board.string(forType: .string))), [["7"]],
                       "copy is allowed")

        board.clearContents()
        board.setString("x", forType: .string)
        c.bars.showReason(nil)
        try sendFromTheGrid(#selector(NSText.cut(_:)), c)
        XCTAssertEqual(c.bars.reasonMessage, FigureGridGate.Reason.reviewMode.sentence)
        XCTAssertEqual(board.string(forType: .string), "x", "a refused cut copies nothing")

        c.bars.showReason(nil)
        select(c, "B3")
        try sendFromTheGrid(#selector(NSText.paste(_:)), c)
        await c.settleWrites()
        XCTAssertEqual(c.bars.reasonMessage, FigureGridGate.Reason.reviewMode.sentence)
        XCTAssertEqual(c.host.state.table[key(c, "A2")]?.content, .value(.number(7)))
        XCTAssertNil(c.host.state.table[key(c, "B3")])
        XCTAssertEqual(try ops(of: c.figureId), opsBefore, "nothing written")
    }

    // MARK: - The limit

    /// **A paste past `TableCSV.figureCellLimit`** is refused with a notice
    /// and writes nothing (R7d-2).
    func test_aPastePastTheCellLimitIsRefusedWithANotice() async throws {
        let (c, _, _, _) = try await openGrid()
        let opsBefore = try ops(of: c.figureId)
        let rows = Array(repeating: Array(repeating: "1", count: 100), count: 101)
        putTabSeparated(rows, html: false)
        select(c, "A1")
        let said = await notices {
            c.paste()
            await c.settleWrites()
        }
        XCTAssertTrue(said.contains { $0.hasPrefix("Couldn't paste") && $0.contains("10,100") }, "\(said)")
        XCTAssertEqual(c.host.state.table.rows.count, 10, "the table did not grow")
        XCTAssertEqual(try ops(of: c.figureId), opsBefore, "nothing written")
        XCTAssertFalse(um.canUndo)
    }

    // MARK: - Planned at its turn (Task 2 review M1, M2)

    /// **A paste right after a ⌘Z** is planned once the undo has landed, so
    /// the writer's own undo never makes their paste "changed elsewhere".
    func test_aPasteRightAfterAnUndoLandsOverTheUndoneTable() async throws {
        let (c, _, _, _) = try await openGrid()
        await type(c, "A2", "1")
        await type(c, "B2", "2")
        putTabSeparated([["9"]], html: false)
        select(c, "A2")
        // The ⌘Z begins as the paste's turn comes, its inverse still landing.
        FigureGridController.writeTurnForTesting = { [um] in
            FigureGridController.writeTurnForTesting = nil
            um.undo()
        }
        let said = await notices {
            c.paste()
            await c.settleWrites()
            await c.host.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, [], "nothing refused")
        XCTAssertEqual(c.host.state.table[key(c, "A2")]?.content, .value(.number(9)))
        XCTAssertNil(c.host.state.table[key(c, "B2")], "the ⌘Z landed")
        XCTAssertEqual(um.undoActionName, "Paste")
    }

    /// **A table that moves between a paste's plan and its write** (another
    /// device's cell landing) is planned again once, not refused (M1): the
    /// paste lands and the other write stays.
    func test_aPasteWhoseTableMovesUnderItsPlanIsPlannedAgain() async throws {
        let (c, _, _, _) = try await openGrid()
        putTabSeparated([["9", "8"]], html: false)
        select(c, "A2")
        let elsewhere = key(c, "D7")
        FigureGridController.afterPlanForTesting = { [host = c.host] in
            FigureGridController.afterPlanForTesting = nil
            try? await host.setCell(Cell(content: .value(.number(5))), at: elsewhere)
        }
        let said = await notices {
            c.paste()
            await c.settleWrites()
        }
        XCTAssertEqual(said, [], "nothing refused")
        XCTAssertEqual(c.host.state.table[key(c, "B2")]?.content, .value(.number(8)))
        XCTAssertEqual(c.host.state.table[elsewhere]?.content, .value(.number(5)))
        XCTAssertEqual(um.undoActionName, "Paste")
    }

    /// **A batch refused before it wrote counts no rows as deleted** (M2): a
    /// row another device deleted is not this batch's; a part-way failure
    /// counts the run gone from the front only.
    func test_aRefusedBatchCountsNoRowAsDeleted() {
        struct DiskFull: Error {}
        let gone: Set<Int> = [1]
        XCTAssertEqual(FigureGridController.deletedBeforeFailure(
            [0, 1, 2], FigureEditInvalid(reason: "changed"), isGone: gone.contains), 0)
        XCTAssertEqual(FigureGridController.deletedBeforeFailure([0, 1, 2], DiskFull(), isGone: gone.contains), 0,
                       "row 1 went elsewhere; this batch wrote nothing")
        XCTAssertEqual(FigureGridController.deletedBeforeFailure(
            [0, 1, 2], DiskFull(), isGone: Set([0, 2]).contains), 1, "row 0 landed; row 2 is not this batch's")
    }
}

/// **⌘V in the grid expanded in the manuscript** (plan 7d Task 3): the paste
/// sent with the grid first responder is the grid's — the table takes the
/// cells and the text behind it is byte-identical.
@MainActor
final class FigureGridClipboardMountedTests: FigureGridMountedTestCase {
    func test_pasteInTheExpandedGridWritesTheTableAndNeverTheText() async throws {
        let m = try await mount()
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        let c = try XCTUnwrap(grid.controller)
        XCTAssertTrue(m.window.firstResponder === c.gridView, "premise: the grid has the keys")
        let board = NSPasteboard(name: .init("figure-grid-mounted-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        c.pasteboard = board
        board.clearContents()
        board.setString("41\t42\n", forType: .string)
        let text = m.textView.string

        let action = #selector(NSText.paste(_:))
        var target: NSResponder? = m.window.firstResponder
        while let current = target, !current.responds(to: action) { target = current.nextResponder }
        XCTAssertTrue(target === c.gridView, "⌘V stops at the grid")
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: nil))
        await c.settleWrites()

        let table = c.host.state.table
        let anchor = try XCTUnwrap(c.model.selection?.anchor)
        let column = try XCTUnwrap(table.columnIndex(of: anchor.column))
        XCTAssertEqual(table[anchor]?.content, .value(.number(41)))
        XCTAssertEqual(table[CellKey(row: anchor.row, column: table.columns[column + 1])]?.content, .value(.number(42)))
        XCTAssertEqual(m.textView.string, text, "the manuscript is byte-identical")
        XCTAssertTrue(m.window.firstResponder === c.gridView)
    }
}
