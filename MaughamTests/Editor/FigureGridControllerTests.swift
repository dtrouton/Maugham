import XCTest
import AppKit
import SwiftUI
@testable import Maugham
@testable import MaughamCore

/// **The grid's controller and its bars** (report plan 7c Task 5): the one
/// grid file that calls figure mutators. Driven through its verbs — the keys
/// it hands its model (`handle`) and the bars' acts (`perform`) — over a real
/// store, host and mounted `FigureGridView`; no button is pressed (tripwire 33).
@MainActor
final class FigureGridControllerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var projectURL: URL!
    /// The window's project store, held: the window holds it weakly.
    private var projectStore: ProjectStore?
    private var renders: [String] = []
    private var window: NSWindow?
    private var controllers: [FigureGridController] = []
    /// The window's document store, held: the store and the hosts hold it weakly.
    private var stores: [DocumentStore] = []
    private let um = UndoManager()

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("gridcontroller-\(UUID().uuidString)")
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
        FigureGridController.writeTurnForTesting = nil
        projectStore = nil
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// A book with one chapter, a window, a 10×4 table figure `t` and a 3×3 `other`.
    private func openBook() async throws -> (DocumentStore, ProjectStore, FigureRecord) {
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
        _ = try await projectStore.createFigure(kind: .table, name: "other", piece: nil)
        return (store, projectStore, record)
    }

    /// The visit on `t`, its grid mounted in a key window.
    private func openGrid(
        commitCaption: @escaping @MainActor (String) -> Bool = { _ in true }
    ) async throws -> (DocumentStore, FigureGridController) {
        let (store, projectStore, record) = try await openBook()
        let controller = try await FigureGridController.open(
            figureId: record.id, store: store, projectStore: projectStore, typography: .defaults,
            line: .init(number: "Table 1", caption: "Old caption", commitCaption: commitCaption),
            undoManager: { [um] in um })
        controllers.append(controller)
        await store.awaitOpenFigureRenderForTesting()
        let grid = controller.gridView
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 520, height: 360))
        grid.frame = CGRect(x: 0, y: 0, width: 520,
                            height: FigureGridLayout.viewportHeight(rows: 10, rowHeight: grid.rowHeight))
        container.addSubview(grid)
        window = TestWindow.make(KeyTestWindow.self, contentRect: container.frame, contentView: container)
        grid.reloadData()
        renders = []
        return (store, controller)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func key(_ c: FigureGridController, _ a1: String) -> CellKey {
        let p = A1.parse(a1)!
        let table = c.host.state.table
        return CellKey(row: table.rows[p.row], column: table.columns[p.column])
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

    private func number(_ x: Double) -> Cell { Cell(content: .value(.number(x))) }

    // MARK: - Review Focus 4: a format over a range, one ⌘Z

    /// **Select B2:D9, choose Currency, ⌘Z** (Review Focus 4): all 24 cells
    /// take the format in one visit — one render, one ⌘Z — and one ⌘Z gives
    /// every one back, itself one render.
    func test_aFormatOverB2toD9IsOneRender_andOneUndoRestoresAll24Cells() async throws {
        let (_, c) = try await openGrid()
        try await c.host.setCell(number(5), at: key(c, "C4"))
        await c.settleWrites()
        let before = c.host.state.table
        renders = []

        c.handle(.click(key(c, "B2"), extend: false))
        c.handle(.click(key(c, "D9"), extend: true))
        XCTAssertEqual(c.bars.addressLabel.stringValue, "B2:D9")
        c.perform(.format(.currency))
        await c.settleWrites()

        let cells = try XCTUnwrap(c.model.selection).cells(in: c.host.state.table)
        XCTAssertEqual(cells.count, 24)
        for k in cells {
            XCTAssertEqual(c.host.state.table[k]?.format.number, .currency(symbol: nil, decimals: 2))
        }
        XCTAssertEqual(c.host.state.table[key(c, "C4")]?.content, .value(.number(5)), "the value is kept")
        XCTAssertEqual(renders, [c.figureId], "one render for 24 cells")
        XCTAssertEqual(um.undoActionName, "Format Cells")
        XCTAssertEqual(c.bars.formatPopUp.titleOfSelectedItem, "Currency", "the menu shows the active cell's format")
        XCTAssertTrue(c.figureGridDisplay(at: key(c, "C4")).hasSuffix("5.00"),
                      "the grid's cached string follows the host: \(c.figureGridDisplay(at: key(c, "C4")))")

        renders = []
        um.undo()
        await c.host.awaitPendingUndoWork()
        XCTAssertEqual(c.host.state.table, before, "one ⌘Z restores all 24 cells")
        XCTAssertEqual(renders, [c.figureId], "in one render")
        XCTAssertFalse(um.canUndo, "one step")
    }

    // MARK: - The cell editor and the formula bar

    /// Typing in the cell commits through the host on Return and moves down;
    /// the formula bar follows the typing.
    func test_typingInTheCellCommitsOnReturnAndTheBarFollows() async throws {
        let (_, c) = try await openGrid()
        c.handle(.click(key(c, "B2"), extend: false))
        c.handle(.type("4"))
        XCTAssertTrue(c.gridView.window?.firstResponder === c.gridView.cellEditor.currentEditor(),
                      "the cell editor has the keys")
        c.handle(.editTextChanged("42"))
        XCTAssertEqual(c.bars.formulaField.stringValue, "42")
        c.handle(.returnKey(backward: false))
        await c.settleWrites()

        XCTAssertEqual(c.host.state.table[key(c, "B2")]?.content, .value(.number(42)))
        XCTAssertEqual(c.bars.addressLabel.stringValue, "B3", "Return moved down")
        XCTAssertTrue(c.gridView.window?.firstResponder === c.gridView, "the grid has the keys back")
        XCTAssertTrue(um.canUndo, "on the window's undo manager (R7c-1)")
    }

    /// **Editing in the formula bar is editing the cell**: the bar's text is
    /// committed to the active cell on Return, which moves down.
    func test_aFormulaBarEditCommitsToTheActiveCell() async throws {
        let (_, c) = try await openGrid()
        c.handle(.click(key(c, "B2"), extend: false))
        c.perform(.formulaTextChanged("1"))
        c.perform(.formulaTextChanged("12"))
        c.perform(.formulaTextChanged("=12*2"))
        XCTAssertTrue(c.perform(.formulaCommand(.returnKey(backward: false))))
        await c.settleWrites()

        guard case .formula? = c.host.state.table[key(c, "B2")]?.content else {
            return XCTFail("the bar's formula was not written: \(String(describing: c.host.state.table[key(c, "B2")]))")
        }
        XCTAssertEqual(c.figureGridValue(at: key(c, "B2")), .number(24))
        XCTAssertEqual(c.bars.addressLabel.stringValue, "B3")
        c.handle(.click(key(c, "B2"), extend: false))
        XCTAssertEqual(c.bars.formulaField.stringValue, "=12*2", "the bar shows the formula")
    }

    /// **A formula that will not read writes nothing**: the message is shown,
    /// the edit stays open on its cell holding the text, the move after the
    /// commit does not happen, and the caret sits at the error's offset —
    /// counted in UTF-16 as the field counts, not in Characters.
    func test_aFormulaThatWillNotReadWritesNothing_andShowsTheErrorAtItsOffset() async throws {
        let (_, c) = try await openGrid()
        c.handle(.click(key(c, "B2"), extend: false))
        let text = "=\"😀\"+"
        c.handle(.type("="))
        c.handle(.editTextChanged(text))
        let count = try ops(of: c.figureId)

        c.handle(.returnKey(backward: false))
        await c.settleWrites()

        XCTAssertEqual(try ops(of: c.figureId), count, "nothing written")
        XCTAssertNotNil(c.bars.errorMessage)
        XCTAssertEqual(c.bars.addressLabel.stringValue, "B2", "the move after the refused commit did not run")
        XCTAssertEqual(c.model.edit, .composing(FigureGridEdit(cell: key(c, "B2"), text: text, inCell: true), reference: nil))
        guard case .failure(let error) = FigureCellEntry.cell(
            from: text, prior: nil, table: c.host.state.table, names: .empty, locale: TableLocale(languageTag: "en-GB", fallbackRegion: "GB"))
        else { return XCTFail("the fixture's formula reads") }
        XCTAssertGreaterThan(error.offset, 2, "the error is past the emoji, so the units differ")
        let caret = try XCTUnwrap(c.gridView.cellEditor.currentEditor()).selectedRange
        XCTAssertEqual(caret.location, FigureGridFormatting.utf16Offset(ofCharacter: error.offset, in: text))
        XCTAssertNotEqual(caret.location, error.offset)

        c.handle(.escape)
        XCTAssertNil(c.bars.errorMessage, "Esc discards the edit and its message")
        XCTAssertEqual(try ops(of: c.figureId), count)
    }

    /// Committing text that is what the cell already shows writes nothing (a
    /// date in General would come back formatted as a date).
    func test_committingUnchangedTextWritesNothing() async throws {
        let (_, c) = try await openGrid()
        try await c.host.setCell(Cell(content: .value(.date(45_000))), at: key(c, "B2"))
        await c.settleWrites()
        let before = c.host.state.table
        let count = try ops(of: c.figureId)

        c.handle(.click(key(c, "B2"), extend: false))
        c.handle(.editInPlace)
        c.handle(.returnKey(backward: false))
        await c.settleWrites()

        XCTAssertEqual(c.host.state.table, before)
        XCTAssertEqual(try ops(of: c.figureId), count)
    }

    // MARK: - The toolbar

    /// **Σ**: each cell of the selection's bottom row sums its column above
    /// it, from under the header row — one ⌘Z, one render.
    func test_sumAddsUpTheColumnAboveTheSelectionUnderTheHeader() async throws {
        let (_, c) = try await openGrid()
        c.perform(.headerRow(true))
        try await c.host.setCell(Cell(content: .value(.text("Qty"))), at: key(c, "B1"))
        for (row, n) in [(2, 1.0), (3, 2), (4, 3)] {
            try await c.host.setCell(number(n), at: key(c, "B\(row)"))
            try await c.host.setCell(number(n * 10), at: key(c, "C\(row)"))
        }
        await c.settleWrites()
        renders = []

        c.handle(.click(key(c, "B5"), extend: false))
        c.handle(.click(key(c, "C5"), extend: true))
        c.perform(.sum)
        await c.settleWrites()

        XCTAssertEqual(c.figureGridValue(at: key(c, "B5")), .number(6))
        XCTAssertEqual(c.figureGridValue(at: key(c, "C5")), .number(60))
        c.handle(.click(key(c, "B5"), extend: false))
        XCTAssertEqual(c.bars.formulaField.stringValue, "=SUM(B2:B4)")
        XCTAssertEqual(renders, [c.figureId])
        XCTAssertEqual(um.undoActionName, "Sum")
        XCTAssertTrue(c.bars.headerRow.state == .on, "the toolbar shows the header row")
    }

    /// Decimals, alignment and ⌫ over a range are one ⌘Z each; a cleared
    /// cell keeps its chosen format.
    func test_decimalsAlignAndClearActOnTheSelection() async throws {
        let (_, c) = try await openGrid()
        try await c.host.setCell(number(1.5), at: key(c, "A1"))
        try await c.host.setCell(number(2.5), at: key(c, "A2"))
        await c.settleWrites()
        c.handle(.click(key(c, "A1"), extend: false))
        c.handle(.click(key(c, "A2"), extend: true))

        c.perform(.format(.number))
        c.perform(.decimals(1))
        c.perform(.align(.right))
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[key(c, "A2")]?.format.number, .number(decimals: 3, grouping: true))
        XCTAssertEqual(c.host.state.table[key(c, "A1")]?.alignment, .right)
        XCTAssertEqual(c.bars.alignment.selectedSegment, 2)

        c.handle(.deleteBackward)
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[key(c, "A1")]?.content, .value(.empty))
        XCTAssertEqual(c.host.state.table[key(c, "A1")]?.format.number, .number(decimals: 3, grouping: true))
        XCTAssertEqual(um.undoActionName, "Clear Cells")
        um.undo()
        await c.host.awaitPendingUndoWork()
        XCTAssertEqual(c.host.state.table[key(c, "A1")]?.content, .value(.number(1.5)), "one ⌘Z gives both back")
        XCTAssertEqual(c.host.state.table[key(c, "A2")]?.content, .value(.number(2.5)))
    }

    /// A column letter selects the column; ⌘⌥↓ inserts a row under the
    /// active cell and selects it.
    func test_aLetterSelectsItsColumn_andAnInsertedRowIsSelected() async throws {
        let (_, c) = try await openGrid()
        c.handle(.selectColumn(key(c, "B1").column))
        XCTAssertEqual(c.bars.addressLabel.stringValue, "B1:B10")

        c.handle(.click(key(c, "C3"), extend: false))
        c.handle(.insert(.down))
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table.rows.count, 11)
        XCTAssertEqual(c.bars.addressLabel.stringValue, "C4", "the new row, beside the active cell")
        XCTAssertEqual(c.host.state.table.rowIndex(of: try XCTUnwrap(c.model.selection).anchor.row), 3)
    }

    /// A change the host makes outside the controller (another window, an
    /// undo) reaches the grid's values through the observation.
    func test_aHostChangeElsewhereReachesTheGrid() async throws {
        let (_, c) = try await openGrid()
        c.handle(.click(key(c, "A1"), extend: false))
        try await c.host.setCell(number(7), at: key(c, "A1"))
        for _ in 0..<100 where c.bars.formulaField.stringValue != "7" { await Task.yield() }
        XCTAssertEqual(c.figureGridValue(at: key(c, "A1")), .number(7))
        XCTAssertEqual(c.bars.formulaField.stringValue, "7")
    }

    // MARK: - The bottom bar

    /// **The name commits through `renameFigure`; a refusal is said and the
    /// field shows the name again.**
    func test_aRefusedNameIsSaidAndTheFieldReverts_anAcceptedOneSticks() async throws {
        let (_, c) = try await openGrid()
        XCTAssertEqual(c.bars.nameField.stringValue, "t")
        XCTAssertEqual(c.bars.numberLabel.stringValue, "Table 1")

        let said = await notices {
            c.bars.nameField.stringValue = "other"
            c.perform(.name("other"))
            await c.settleWrites()
        }
        XCTAssertEqual(said, ["Another figure is already called other."])
        XCTAssertEqual(c.bars.nameField.stringValue, "t", "the field reverts")
        XCTAssertEqual(c.name, "t")

        c.perform(.name("cash"))
        await c.settleWrites()
        XCTAssertEqual(c.name, "cash")
        XCTAssertEqual(projectStore?.manifest.figures?.first { $0.id == c.figureId }?.name, "cash")
        XCTAssertEqual(c.bars.nameField.stringValue, "cash")
    }

    /// Done folds, committing an open edit first (R7c-8).
    func test_doneCommitsTheOpenEditAndFolds() async throws {
        let (_, c) = try await openGrid()
        var folded = 0
        c.onFold = { folded += 1 }
        c.handle(.click(key(c, "A1"), extend: false))
        c.handle(.type("9"))
        c.perform(.done)
        await c.settleWrites()
        XCTAssertEqual(folded, 1)
        XCTAssertEqual(c.host.state.table[key(c, "A1")]?.content, .value(.number(9)))
    }

    /// **A commit the table changed under is never dropped** (review I1,
    /// R7c-8): `=D1*2` read when Return was pressed; column A is deleted
    /// elsewhere before the write's turn, so D1 is past the table. Nothing is
    /// written, and the edit opens again on its cell with the text and the
    /// message, as a fresh parse error would.
    func test_aCommitThatNoLongerReadsAtItsTurnReopensWithTheText() async throws {
        let (_, c) = try await openGrid()
        let b2 = key(c, "B2"), columnA = key(c, "A1").column
        FigureGridController.writeTurnForTesting = { try? await c.host.deleteColumn(columnA) }
        c.handle(.click(b2, extend: false))
        c.handle(.type("="))
        c.handle(.editTextChanged("=D1*2"))
        let said = await notices {
            c.handle(.returnKey(backward: false))
            await c.settleWrites()
        }
        XCTAssertEqual(c.host.state.table.columns.count, 3, "precondition: the column went")
        XCTAssertNil(c.host.state.table[b2], "nothing written")
        XCTAssertEqual(c.model.edit, .composing(FigureGridEdit(cell: b2, text: "=D1*2", inCell: true), reference: nil))
        XCTAssertEqual(c.gridView.cellEditor.stringValue, "=D1*2", "the typing is back in the cell")
        XCTAssertNotNil(c.bars.errorMessage)
        XCTAssertEqual(said, [])
    }

    /// The same drift while the writer is already editing another cell: the
    /// open edit is left alone, and a notice carries the text.
    func test_aDriftedCommitWhileEditingElsewhereIsSaidWithItsText() async throws {
        let (_, c) = try await openGrid()
        let columnA = key(c, "A1").column
        FigureGridController.writeTurnForTesting = {
            try? await c.host.deleteColumn(columnA)
            let table = c.host.state.table
            c.handle(.click(CellKey(row: table.rows[4], column: table.columns[0]), extend: false))
            c.handle(.type("5"))
        }
        c.handle(.click(key(c, "B2"), extend: false))
        c.handle(.type("="))
        c.handle(.editTextChanged("=D1*2"))
        let said = await notices {
            c.handle(.returnKey(backward: false))
            await c.settleWrites()
        }
        XCTAssertEqual(said.count, 1)
        XCTAssertTrue(said.first?.contains("=D1*2") == true, "the notice carries the text: \(said)")
        guard case .editing(let e) = c.model.edit else { return XCTFail("the writer's edit was taken: \(c.model.edit)") }
        XCTAssertEqual(e.text, "5")
    }

    /// **Done with a formula that will not read keeps the grid open** (R7c-8):
    /// the refused commit ends the effect list, so the fold after it never runs.
    func test_doneWithAFormulaThatWillNotReadKeepsTheGridOpen() async throws {
        let (_, c) = try await openGrid()
        var folded = 0
        c.onFold = { folded += 1 }
        c.handle(.click(key(c, "A1"), extend: false))
        c.handle(.type("="))
        c.handle(.editTextChanged("=SUM("))
        c.perform(.done)
        await c.settleWrites()
        XCTAssertEqual(folded, 0, "the grid stays open")
        XCTAssertNotNil(c.bars.errorMessage)
        XCTAssertNil(c.host.state.table[key(c, "A1")])
    }

    // MARK: - The caption, through Route A

    final class Box {
        var text: String
        init(_ text: String) { self.text = text }
    }

    private func mountText(_ text: String, locked: Bool) throws -> (MaughamTextView, EditorCoordinator) {
        let box = Box(text)
        let control = EditorControl()
        control.lockEditing = locked
        let configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: control)
        let window = TestWindow.mount(EditorSurface(text: Binding(get: { box.text }, set: { box.text = $0 }),
                                                    configuration: configuration),
                                      size: CGSize(width: 600, height: 400), as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let textView = try XCTUnwrap(Self.textView(in: window.contentView))
        return (textView, try XCTUnwrap(textView.delegate as? EditorCoordinator))
    }

    private static func textView(in view: NSView?) -> MaughamTextView? {
        guard let view else { return nil }
        if let tv = view as? MaughamTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    /// **The caption commits through the coordinator's Route A**: one
    /// replace of the caption range, one ⌘Z named for it, the caption kept on
    /// one line with its `](` opened, the rest of the line untouched.
    func test_theCaptionCommitsThroughRouteA() async throws {
        let text = "Intro.\n\n![Old caption](figures/t.csv){#tbl:t}\n\nAfter.\n"
        let (textView, coordinator) = try mountText(text, locked: false)
        let line = (text as NSString).range(of: "![").location
        let (_, c) = try await openGrid { coordinator.replaceFigureCaption(ofLineAt: line, with: $0) }

        c.perform(.caption("Cash](by\nmonth"))

        XCTAssertEqual(textView.string, "Intro.\n\n![Cash] (by month](figures/t.csv){#tbl:t}\n\nAfter.\n")
        XCTAssertEqual(textView.undoManager?.undoActionName, "Edit Caption")
        XCTAssertEqual(c.bars.committedCaption, "Cash] (by month", "the bar holds what the line holds")
        XCTAssertEqual(c.bars.captionField.stringValue, "Cash] (by month")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, text, "one ⌘Z")
    }

    /// **The membrane refuses the caption**: the text is untouched and the
    /// field shows the caption again.
    func test_aCaptionTheMembraneRefusesLeavesTheTextAndRevertsTheField() async throws {
        let text = "![Old caption](figures/t.csv){#tbl:t}\n"
        let (textView, coordinator) = try mountText(text, locked: true)
        let (_, c) = try await openGrid { coordinator.replaceFigureCaption(ofLineAt: 0, with: $0) }

        c.bars.captionField.stringValue = "New"
        c.perform(.caption("New"))

        XCTAssertEqual(textView.string, text)
        XCTAssertEqual(c.bars.captionField.stringValue, "Old caption")
        XCTAssertEqual(c.bars.committedCaption, "Old caption")
    }

    func test_theCaptionRangeIsTheFigureLinesAlone() {
        XCTAssertEqual(FigureIngest.captionRange(inLine: "![Cash](figures/c.csv){#tbl:c}\n"), NSRange(location: 2, length: 4))
        XCTAssertEqual(FigureIngest.captionRange(inLine: "  ![😀 a](figures/c.csv)"), NSRange(location: 4, length: 4))
        XCTAssertEqual(FigureIngest.captionRange(inLine: "![](figures/c.csv)"), NSRange(location: 2, length: 0))
        XCTAssertNil(FigureIngest.captionRange(inLine: "Words ![Cash](figures/c.csv)"))
        XCTAssertNil(FigureIngest.captionRange(inLine: "| a | b |"))
    }

    // MARK: - Pure: the toolbar's arithmetic

    func test_formatChoicesKeepDecimals_andDecimalsStepWithinBounds() {
        XCTAssertEqual(FigureGridFormatChoice.currency.applied(to: .number(decimals: 3, grouping: true)),
                       .currency(symbol: nil, decimals: 3))
        XCTAssertEqual(FigureGridFormatChoice.currency.applied(to: .general), .currency(symbol: nil, decimals: 2))
        XCTAssertEqual(FigureGridFormatChoice.currency.applied(to: .currency(symbol: "$", decimals: 0)),
                       .currency(symbol: "$", decimals: 0), "the same kind is left as it is")
        XCTAssertEqual(FigureGridFormatChoice.percent.applied(to: .date(.iso)), .percent(decimals: 0))
        XCTAssertEqual(FigureGridFormatChoice.choice(of: .compact(decimals: 1)), .compact)

        XCTAssertEqual(FigureGridFormatting.decimals(.general, by: 1), .number(decimals: 1, grouping: false))
        XCTAssertEqual(FigureGridFormatting.decimals(.general, by: -1), .number(decimals: 0, grouping: false))
        XCTAssertEqual(FigureGridFormatting.decimals(.percent(decimals: 0), by: -1), .percent(decimals: 0))
        XCTAssertEqual(FigureGridFormatting.decimals(.currency(symbol: nil, decimals: 10), by: 1),
                       .currency(symbol: nil, decimals: 10))
        XCTAssertEqual(FigureGridFormatting.decimals(.date(.day), by: 1), .date(.day))
    }

    func test_aCharacterOffsetBecomesTheFieldsUTF16Offset() {
        XCTAssertEqual(FigureGridFormatting.utf16Offset(ofCharacter: 2, in: "=😀+x"), 3)
        XCTAssertEqual(FigureGridFormatting.utf16Offset(ofCharacter: 1, in: "=1+"), 1)
        XCTAssertEqual(FigureGridFormatting.utf16Offset(ofCharacter: 9, in: "=😀"), 3, "past the end is the end")
        XCTAssertEqual(FigureGridFormatting.utf16Offset(ofCharacter: 1, in: "=e\u{301}+"), 1)
        XCTAssertEqual(FigureGridFormatting.utf16Offset(ofCharacter: 2, in: "=e\u{301}+"), 3)
    }
}
