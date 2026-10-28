import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import Maugham
@testable import MaughamCore

/// **Fill Down, Fill Right and Import from CSV… in the table grid** (report
/// plan 7d Task 4, rulings R7d-1 and R7d-8): driven through the controller's
/// table command — the verb Format ▸ Table's items and the right-click menu
/// reach — over a real store and host. The open panel is a value
/// (`FigureGridImport.panelConfiguration`); a test answers the choice through
/// `chooseImportFile` and never allocates a panel. No button is pressed
/// (tripwire 33). ⌘R on the real key path is `FigureGridFillKeyTests`.
@MainActor
final class FigureGridFillImportTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var projectURL: URL!
    private var renders: [String] = []
    private var window: NSWindow?
    private var controllers: [FigureGridController] = []
    private var stores: [DocumentStore] = []
    private var projectStore: ProjectStore?
    /// The visit's own undo stack (plan 7d Task 6): the first grid opened.
    private var um: UndoManager { controllers[0].gridUndo }

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("gridfill-\(UUID().uuidString)")
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
        for c in controllers {
            await c.settleWrites()
            c.close()
        }
        controllers = []
        for store in stores { await store.close() }
        stores = []
        window?.close()
        window = nil
        DocumentStore.figureHostAppendedForTesting = nil
        projectStore = nil
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// A book with one chapter, a `rows`×`columns` table figure `t` and a 3×3
    /// `other`; the visit on `t` with its grid mounted in a key window.
    private func openGrid(rows: Int = 6, columns: Int = 3) async throws
        -> (FigureGridController, DocumentStore, ProjectStore, FigureRecord) {
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
        let record = try await projectStore.createFigure(
            kind: .table, name: "t", piece: nil, rows: rows, columns: columns)
        let other = try await projectStore.createFigure(kind: .table, name: "other", piece: nil)
        let c = try await visit(record.id, store, projectStore)
        let grid = c.gridView
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 520, height: 360))
        grid.frame = CGRect(x: 0, y: 0, width: 520,
                            height: FigureGridLayout.viewportHeight(rows: rows, rowHeight: grid.rowHeight))
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

    private func type(_ c: FigureGridController, _ a1: String, _ text: String) async {
        select(c, a1)
        c.perform(.formulaTextChanged(text))
        c.perform(.formulaCommand(.returnKey(backward: false)))
        await c.settleWrites()
    }

    private func bar(_ c: FigureGridController, _ a1: String) -> String {
        select(c, a1)
        return c.bars.formulaField.stringValue
    }

    private func content(_ c: FigureGridController, _ a1: String) -> CellContent? {
        c.host.state.table[key(c, a1)]?.content
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

    /// `text` written as a file the writer picks, and the panel answered with it.
    private func choose(_ text: String, named name: String = "data.csv", for c: FigureGridController) throws -> URL {
        let url = TestTemp.root.appendingPathComponent("import-\(UUID().uuidString)-\(name)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        c.chooseImportFile = { chosen in chosen(url) }
        return url
    }

    // MARK: - Fill

    /// **Fill Down** (⌘D on Format ▸ Table's item): the top row of the
    /// selection into every row under it, a formula's relative references
    /// moving with it and its `$` parts staying — one render, one ⌘Z, which
    /// puts every filled cell back.
    func test_fillDownCopiesTheTopRowIntoTheSelection_andOneUndoTakesItBack() async throws {
        let (c, _, _, _) = try await openGrid()
        await type(c, "A1", "5")
        await type(c, "B1", "=A1*$A$1")
        await type(c, "B3", "keep me?")
        um.removeAllActions()
        renders = []
        select(c, "A1", "B4")
        c.performTableCommand(.fillDown)
        await c.settleWrites()

        for row in 2...4 {
            XCTAssertEqual(content(c, "A\(row)"), .value(.number(5)), "A\(row)")
            XCTAssertEqual(bar(c, "B\(row)"), "=A\(row)*$A$1", "B\(row)")
        }
        XCTAssertNil(c.host.state.table[key(c, "A5")], "below the selection is left")
        XCTAssertEqual(renders.count, 1, "one render")
        XCTAssertEqual(um.undoActionName, "Fill Down")

        um.undo()
        await c.host.awaitPendingUndoWork()
        await c.settleWrites()
        XCTAssertNil(c.host.state.table[key(c, "A2")])
        XCTAssertEqual(content(c, "B3"), .value(.text("keep me?")), "one ⌘Z put the filled cell back")
        XCTAssertEqual(bar(c, "B1"), "=A1*$A$1")
        XCTAssertFalse(um.canUndo && um.undoActionName == "Fill Down", "one step")
    }

    /// **Fill Right** from the command: the left column into the rest; a
    /// single cell fills from the cell to its left (Excel's).
    func test_fillRightCopiesTheLeftColumn_andOneCellFillsFromItsLeft() async throws {
        let (c, _, _, _) = try await openGrid()
        await type(c, "A2", "=A1+1")
        await type(c, "A3", "x")
        select(c, "A2", "C3")
        c.performTableCommand(.fillRight)
        await c.settleWrites()
        XCTAssertEqual(bar(c, "B2"), "=B1+1")
        XCTAssertEqual(bar(c, "C2"), "=C1+1")
        XCTAssertEqual(content(c, "C3"), .value(.text("x")))
        XCTAssertEqual(um.undoActionName, "Fill Right")

        await type(c, "A5", "9")
        select(c, "B5")
        c.performTableCommand(.fillRight)
        await c.settleWrites()
        XCTAssertEqual(content(c, "B5"), .value(.number(9)), "one cell fills from its left")
    }

    /// **A read-only grid fills nothing** and says why — the ⌘R and ⌘D
    /// paths both end at this command.
    func test_aReadOnlyGridRefusesAFillWithTheReason() async throws {
        let (c, _, _, _) = try await openGrid()
        await type(c, "A1", "5")
        c.setAccess(.readOnly(.reviewMode), captionMayEdit: false)
        let opsBefore = try ops(of: c.figureId)
        select(c, "A1", "A3")
        c.bars.showReason(nil)
        c.performTableCommand(.fillDown)
        c.figureGridViewFillRight(c.gridView)
        await c.settleWrites()
        XCTAssertEqual(c.bars.reasonMessage, FigureGridGate.Reason.reviewMode.sentence)
        XCTAssertNil(c.host.state.table[key(c, "A2")])
        XCTAssertEqual(try ops(of: c.figureId), opsBefore, "nothing written")
    }

    // MARK: - Import from CSV…

    /// **The open panel, as a value**: one CSV, TSV or text file, never a folder.
    func test_theImportPanelIsConfiguredForOneTableFile() {
        XCTAssertEqual(FigureGridImport.panelConfiguration, FigureCSVImportPanelConfiguration(
            allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText],
            canChooseFiles: true, canChooseDirectories: false, allowsMultipleSelection: false,
            prompt: "Import", message: "The file's cells replace the table's."))
    }

    /// **Review Focus 5**: a CSV with its columns reordered, imported into a
    /// table another figure reads — the reference survives (the column kept
    /// its id by its header and moved, and the other figure's formula follows
    /// it), and one ⌘Z puts the old contents back.
    func test_aCSVWithReorderedColumnsKeepsAnotherFiguresReference_andOneUndoRestores() async throws {
        let (c, store, projectStore, other) = try await openGrid(rows: 3, columns: 3)
        await type(c, "A1", "Name")
        await type(c, "B1", "Q1")
        await type(c, "C1", "Q2")
        await type(c, "A2", "North")
        await type(c, "B2", "10")
        await type(c, "C2", "20")
        await type(c, "A3", "South")
        await type(c, "B3", "30")
        await type(c, "C3", "40")
        c.performTableCommand(.headerRow)
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table.headerRows, 1, "premise: a header row")
        let q1 = c.host.state.table.columns[1]
        let before = c.host.state.table

        let o = try await visit(other.id, store, projectStore)
        await type(o, "A1", "=t!B3")
        um.removeAllActions()
        let reference = try XCTUnwrap(o.host.state.table[key(o, "A1")]?.content)

        _ = try choose("Q2,Name,Q1\n40,South,30\n21,North,11\n", for: c)
        renders = []
        c.performTableCommand(.importCSV)
        await c.settleWrites()

        let after = c.host.state.table
        XCTAssertEqual(after.columns.firstIndex(of: q1), 2, "Q1 kept its id and moved to the third column")
        XCTAssertEqual(after[CellKey(row: after.rows[1], column: q1)]?.content, .value(.number(30)))
        XCTAssertEqual(after.headerRows, 1)
        XCTAssertEqual(renders.count, 1, "one visit, one render")
        XCTAssertEqual(um.undoActionName, FigureGridImport.actionName)

        XCTAssertEqual(o.host.state.table[key(o, "A1")]?.content, reference, "the other figure's formula is untouched")
        guard case .formula(let formula) = reference else { return XCTFail("premise: a formula") }
        let names = try await store.tableImportContext().names
        XCTAssertEqual(FormulaParser.render(formula, in: o.host.state.table, names: names), "t!C2",
                       "the reference followed Q1 to its new place (South is now the first row)")

        um.undo()
        await c.host.awaitPendingUndoWork()
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table.columns, before.columns)
        XCTAssertEqual(c.host.state.table.rows, before.rows)
        for row in before.rows {
            for column in before.columns {
                let k = CellKey(row: row, column: column)
                XCTAssertEqual(c.host.state.table[k], before[k], "one ⌘Z restored \(k)")
            }
        }
    }

    /// **The header follows the read**: a text-only first row over numbers
    /// is a header; a first row holding a number is data; an all-text file
    /// cannot tell, so the table keeps its setting.
    func test_theImportedHeaderFollowsTheReadsDetection() {
        func read(_ text: String) -> FigureTable {
            TableCSV.read(text, locale: TableLocale(languageTag: "en"), names: .empty).table
        }
        XCTAssertEqual(FigureGridImport.headerRows(read: read("a,b\n1,2\n"), current: 0), 1)
        XCTAssertEqual(FigureGridImport.headerRows(read: read("1,b\nx,y\n"), current: 1), 0)
        XCTAssertEqual(FigureGridImport.headerRows(read: read("a,b\nx,y\n"), current: 1), 1)
        XCTAssertEqual(FigureGridImport.headerRows(read: read("a,b\nx,y\n"), current: 0), 0)
    }

    /// **More cells than a table may hold** is refused with a notice and
    /// writes nothing; so is an empty file.
    func test_aFilePastTheCellLimitOrEmptyIsRefusedWithANotice() async throws {
        let (c, _, _, _) = try await openGrid()
        let opsBefore = try ops(of: c.figureId)
        let row = Array(repeating: "1", count: 101).joined(separator: ",")
        let bigURL = try choose(Array(repeating: row, count: 100).joined(separator: "\n"), named: "big.csv", for: c)
        let big = try await notices {
            c.performTableCommand(.importCSV)
            await c.settleWrites()
        }
        XCTAssertEqual(big, ["Couldn't import “\(bigURL.lastPathComponent)” — 10,100 cells are more than a table can hold (10,000)."])

        let emptyURL = try choose("", named: "empty.csv", for: c)
        let empty = try await notices {
            c.performTableCommand(.importCSV)
            await c.settleWrites()
        }
        XCTAssertEqual(empty, ["Couldn't import “\(emptyURL.lastPathComponent)” — it holds no cells."])
        XCTAssertEqual(try ops(of: c.figureId), opsBefore, "nothing written")
        XCTAssertFalse(um.canUndo)
    }

    /// **A read-only grid imports nothing** and says why; the panel never shows.
    func test_aReadOnlyGridRefusesAnImportWithTheReason() async throws {
        let (c, _, _, _) = try await openGrid()
        var asked = false
        c.chooseImportFile = { _ in asked = true }
        c.setAccess(.readOnly(.reviewMode), captionMayEdit: false)
        c.bars.showReason(nil)
        c.performTableCommand(.importCSV)
        XCTAssertFalse(asked, "no panel on a read-only grid")
        XCTAssertEqual(c.bars.reasonMessage, FigureGridGate.Reason.reviewMode.sentence)

        let url = try choose("a,b\n1,2\n", for: c)
        let opsBefore = try ops(of: c.figureId)
        c.bars.showReason(nil)
        c.importCSV(from: url)
        await c.settleWrites()
        XCTAssertEqual(c.bars.reasonMessage, FigureGridGate.Reason.reviewMode.sentence)
        XCTAssertEqual(try ops(of: c.figureId), opsBefore)
    }

    /// A cell the read kept as text (a formula that would not read) is said.
    func test_cellsKeptAsTextAreSaid() async throws {
        let (c, _, _, _) = try await openGrid()
        let odd = try choose("a,b\n=nosuch!A1,2\n", named: "odd.csv", for: c)
        let seen = try await notices {
            c.performTableCommand(.importCSV)
            await c.settleWrites()
        }
        XCTAssertEqual(seen, ["Imported “\(odd.lastPathComponent)”; 1 cell couldn't be read as a formula and was kept as text."])
        XCTAssertEqual(content(c, "A2"), .value(.text("=nosuch!A1")))
    }

    /// **A file the table already holds** is said, and writes nothing (T4
    /// review M3): no step, no op.
    func test_anIdenticalImportSaysSoAndWritesNothing() async throws {
        let (c, _, _, _) = try await openGrid(rows: 2, columns: 2)
        await type(c, "A1", "north")
        await type(c, "B1", "south")
        await type(c, "A2", "east")
        await type(c, "B2", "west")
        um.removeAllActions()
        let opsBefore = try ops(of: c.figureId)
        let same = try choose("north,south\neast,west\n", named: "same.csv", for: c)
        let said = try await notices {
            c.performTableCommand(.importCSV)
            await c.settleWrites()
        }
        XCTAssertEqual(said, ["“\(same.lastPathComponent)” matches the table already — nothing changed."])
        XCTAssertEqual(try ops(of: c.figureId), opsBefore, "nothing written")
        XCTAssertFalse(um.canUndo, "no step")
    }

    /// **A file chosen after the grid folded** (the sheet still up when it
    /// went) is said, never dropped in silence, and writes nothing (T4 M5).
    func test_aFileChosenAfterTheGridFoldedIsSaid() async throws {
        let (c, _, _, _) = try await openGrid()
        let url = TestTemp.root.appendingPathComponent("import-\(UUID().uuidString)-late.csv")
        try "a,b\n1,2\n".write(to: url, atomically: true, encoding: .utf8)
        var answer: (@MainActor (URL?) -> Void)?
        c.chooseImportFile = { answer = $0 }
        c.performTableCommand(.importCSV)
        let chosen = try XCTUnwrap(answer, "premise: the panel is up")
        c.didFold()
        let opsBefore = try ops(of: c.figureId)
        let said = try await notices {
            chosen(url)
            await c.settleWrites()
        }
        XCTAssertEqual(said, ["Couldn't import “\(url.lastPathComponent)” — the table was closed first."])
        XCTAssertEqual(try ops(of: c.figureId), opsBefore)
    }

    /// **An import into a table with a total row** (final review M7): the
    /// file has no total row, so the table's is switched off — the file's
    /// last row stays data, never silently made the total — and one ⌘Z puts
    /// the total row back with the cells.
    func test_anImportIntoATotalRowTableSwitchesTheTotalRowOff() async throws {
        let (c, _, _, _) = try await openGrid(rows: 3, columns: 2)
        c.performTableCommand(.totalRow)
        await c.settleWrites()
        XCTAssertTrue(c.host.state.table.hasTotalRow, "premise: a total row")
        let before = c.host.state.table
        um.removeAllActions()

        _ = try choose("a,b\n1,2\n3,4\n", for: c)
        c.performTableCommand(.importCSV)
        await c.settleWrites()
        XCTAssertFalse(c.host.state.table.hasTotalRow, "the file's last row is data")
        XCTAssertEqual(content(c, "A3"), .value(.number(3)))
        XCTAssertEqual(um.undoActionName, FigureGridImport.actionName)

        um.undo()
        await c.host.awaitPendingUndoWork()
        await c.settleWrites()
        XCTAssertTrue(c.host.state.table.hasTotalRow, "one ⌘Z puts the total row back")
        XCTAssertEqual(c.host.state.table.rows, before.rows)
    }
}

/// **⌘R: Fill Right while the grid has the keys, Check Writing everywhere
/// else** (Review Focus 4, R7d-1). The key window's view walk — what AppKit
/// asks of a key window for a key equivalent before the menu bar — is pinned
/// on every run; the whole keyboard path through `NSApp.sendEvent` is
/// measured where the run may make the grid's window key (CI), and skipped
/// by name where it may not.
@MainActor
final class FigureGridFillKeyTests: FigureGridMountedTestCase {

    private func commandR(_ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: "r",
                         charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!
    }

    private func checkWritingRuns(during body: () async throws -> Void) async rethrows -> Int {
        var runs = 0
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamRunCompiler, object: nil, queue: nil
        ) { _ in runs += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return runs
    }

    /// The File menu's ⌘R item, as the app's menu bar holds it.
    private func checkWritingItem() -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.keyEquivalent == "r", item.keyEquivalentModifierMask == .command { return item }
                if let found = find(item.submenu) { return found }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    /// The expanded grid with A1 = 7 and A1:C1 selected, the grid first responder.
    private func gridWithARowToFill() async throws -> (Mounted, FigureGridController, [CellKey]) {
        let m = try await mount()
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        let c = try XCTUnwrap(grid.controller)
        let table = c.host.state.table
        let row = table.columns.map { CellKey(row: table.rows[0], column: $0) }
        c.handle(.click(row[0], extend: false))
        c.perform(.formulaTextChanged("7"))
        c.perform(.formulaCommand(.returnKey(backward: false)))
        await c.settleWrites()
        c.handle(.click(row[0], extend: false))
        c.handle(.click(row[2], extend: true))
        XCTAssertTrue(m.window.firstResponder === c.gridView, "premise: the grid has the keys")
        return (m, c, row)
    }

    /// **The key window's walk claims ⌘R for the grid, and only while the
    /// grid has the keys** — the walk `NSApp` makes of a key window's views
    /// for a key equivalent. In the grid: claimed, filled right, the text
    /// untouched, Check Writing never posted. In the text: the walk leaves it
    /// (the grid is folded and no view claims it), so the menu bar's ⌘R —
    /// Check Writing, the chord's one binding — is what answers it.
    func test_theWindowsWalkGivesTheGridCommandR_onlyWhileTheGridHasTheKeys() async throws {
        let (m, c, row) = try await gridWithARowToFill()
        let text = m.textView.string
        var claimed = false
        let inTheGrid = await checkWritingRuns {
            claimed = m.window.performKeyEquivalent(with: commandR(m.window))
            await c.settleWrites()
        }
        XCTAssertTrue(claimed, "the grid claimed ⌘R")
        XCTAssertEqual(c.host.state.table[row[1]]?.content, .value(.number(7)), "⌘R filled right")
        XCTAssertEqual(c.host.state.table[row[2]]?.content, .value(.number(7)))
        XCTAssertEqual(inTheGrid, 0, "⌘R in the grid never runs Check Writing")
        XCTAssertEqual(m.textView.string, text, "the manuscript is byte-identical")
        XCTAssertTrue(m.window.firstResponder === c.gridView)
        XCTAssertEqual(c.model.selection?.anchor, row[0], "the selection stays")

        // ⇧ held is another chord (⌘⇧R, Reread): the grid leaves it.
        XCTAssertFalse(FigureGridView.isFillRight(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: m.window.windowNumber, context: nil, characters: "R",
            charactersIgnoringModifiers: "R", isARepeat: false, keyCode: 15)!))

        m.coordinator.foldFigureGrid(commit: true)
        m.window.makeFirstResponder(m.textView)
        XCTAssertTrue(m.window.firstResponder === m.textView, "premise: the text has the keys")
        XCTAssertFalse(m.window.performKeyEquivalent(with: commandR(m.window)),
                       "no view claims ⌘R in the text: the menu bar answers it")
        let item = try XCTUnwrap(checkWritingItem(), "premise: the app's menu bar binds ⌘R")
        XCTAssertEqual(item.title, RunMenuTitles.check(for: nil))
    }

    /// **⌘R in the text runs Check Writing**, through `NSApp.sendEvent` —
    /// the keyboard's own path.
    func test_commandRInTheTextRunsCheckWriting() async throws {
        let m = try await mount()
        TestWindow.present(m.window, as: .key)
        XCTAssertTrue(m.window.firstResponder === m.textView, "premise: the text has the keys")
        let runs = await checkWritingRuns {
            NSApp.sendEvent(commandR(m.window))
        }
        XCTAssertEqual(runs, 1, "⌘R in the text runs Check Writing")
    }

    /// **⌘R with the grid focused fills right, on the keyboard's own path**
    /// (Review Focus 4): `NSApp.sendEvent` offers a key equivalent to the key
    /// window's views before the menu bar, so the grid's claim wins over File
    /// ▸ Check Writing's ⌘R. Needs the host to be the active app with the grid's
    /// window key — with no key window `NSApp` hands a ⌘ key to the menu bar
    /// alone (measured: Check Writing ran) — so a run that may not activate
    /// (`MAUGHAM_ALLOW_ACTIVATION`, CI sets it) skips by name; the walk itself
    /// is pinned above on every run.
    func test_commandRThroughTheApplicationReachesTheGridBeforeTheMenuBar() async throws {
        let (m, c, row) = try await gridWithARowToFill()
        _ = await TestWindow.activate(m.window)
        guard NSApp.keyWindow === m.window else {
            throw XCTSkip("the grid's window is not the app's key window (active: \(NSApp.isActive), "
                          + "activation allowed: \(TestWindow.activationAllowed)): "
                          + "NSApp.sendEvent gives a ⌘ key to the menu bar alone. CI's runner "
                          + "(TEST_RUNNER_MAUGHAM_ALLOW_ACTIVATION=1, the host the only app) measures the precedence; "
                          + "a local Mac with another app frontmost refuses the activation.")
        }
        XCTAssertTrue(m.window.firstResponder === c.gridView, "premise: the grid has the keys")
        let text = m.textView.string
        let runs = await checkWritingRuns {
            NSApp.sendEvent(commandR(m.window))
            await c.settleWrites()
        }
        XCTAssertEqual(c.host.state.table[row[2]]?.content, .value(.number(7)), "⌘R filled right")
        XCTAssertEqual(runs, 0, "the grid's claim came before File ▸ Check Writing's ⌘R")
        XCTAssertEqual(m.textView.string, text)
    }
}
