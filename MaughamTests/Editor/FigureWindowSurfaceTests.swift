import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **The figure window's surface** (report plan 7d Task 9, R7d-5, R7d-6,
/// R7d-7): the same grid in a window, against the project window's
/// `DocumentStore` — the caption read-only, the name editable, its own
/// undo stack for its life and no step anywhere at its close, the visit
/// finished when the window closes (with its project too — Review Focus 3),
/// and Send to Research closing it first. Real projects, a real registry and
/// real sessions; windows through `TestWindow`; acts asked of the controller
/// (a bar's or a menu's verb), never clicked (tripwire 33).
@MainActor
final class FigureWindowSurfaceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FigureWindowSurfaceTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private struct Project {
        let registry: ProjectSessionRegistry
        let lease: ProjectSessionRegistry.Lease
        let figure: FigureRecord
        let chapter: StructureItem
        var session: ProjectSession { lease.session }
    }

    /// A novel open in a project window, holding a 3×3 table `t` in its first chapter.
    private func openProject() async throws -> Project {
        let url = try await ProjectFactory.createNovelProject(
            named: "FigureSurface-\(UUID().uuidString.prefix(6))", in: TestTemp.root)
        let registry = ProjectSessionRegistry()
        let preferences = UserPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let canvas = CanvasModel()
        let lease = try await registry.acquire(url, as: .window(attach: { session in
            session.attachWindow(canvas: canvas, flash: { _ in }, preferences: preferences)
        }, isLive: { true })) { try await ProjectSession.open(url: url) }
        let store = lease.session.projectStore
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let figure = try await store.createFigure(kind: .table, name: "t", piece: chapter.id, rows: 3, columns: 3)
        return Project(registry: registry, lease: lease, figure: figure, chapter: chapter)
    }

    /// The figure window mounted on `project`'s table, its visit opened.
    private func openWindow(
        _ project: Project, handoff: FigureWindows.Handoff? = nil
    ) async throws -> (KeyTestWindow, FigureWindowGrid, FigureGridController) {
        if let handoff { project.session.figureWindows.handOff(project.figure.id, handoff) }
        let grid = FigureWindowGrid()
        let key = FigureWindowKey(projectURL: project.session.url, figureId: project.figure.id)
        let window = TestWindow.mount(FigureWindow(key: key, grid: grid).environment(project.registry),
                                      size: CGSize(width: 640, height: 400), as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let opened = await RunLoopPump.until(deadline: 5) { grid.controller != nil }
        XCTAssertTrue(opened, "the window's visit opened: \(grid.container.message)")
        return (window, grid, try XCTUnwrap(grid.controller))
    }

    private func handoff(_ project: Project) -> FigureWindows.Handoff {
        FigureWindows.Handoff(number: "Table 2", caption: "Cash flow", piece: project.chapter.id,
                              typography: .defaults)
    }

    private func cell(_ c: FigureGridController, _ column: Int, _ row: Int) -> CellKey {
        let table = c.host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    /// `text` typed into `key` and left open (no Return).
    private func typeOpen(_ c: FigureGridController, _ key: CellKey, _ text: String) {
        c.handle(.click(key, extend: false))
        c.handle(.type(text))
        c.handle(.editTextChanged(text))
    }

    // MARK: - The surface (R7d-6)

    /// The window shows the same grid in its panel with the keys; the bottom
    /// bar shows "Table N · caption" as the opening grid handed them over,
    /// the caption locked (it is the text's) and the name open; ⤢ is not
    /// offered in the window itself; Format ▸ Table reads its presence.
    func test_theWindowMountsTheGrid_theCaptionReadOnly_theNameEditable() async throws {
        let project = try await openProject()
        let (window, grid, c) = try await openWindow(project, handoff: handoff(project))

        XCTAssertTrue(grid.panel?.superview === grid.container, "the panel is the window's content")
        XCTAssertTrue(grid.panel?.gridView === c.gridView)
        XCTAssertTrue(window.firstResponder === c.gridView, "the grid has the keys")
        XCTAssertEqual(c.bars.numberLabel.stringValue, "Table 2")
        XCTAssertEqual(c.bars.captionField.stringValue, "Cash flow")
        XCTAssertFalse(c.bars.captionField.isEditable, "the caption is the text's (R7d-6)")
        XCTAssertTrue(c.bars.nameField.isEditable, "the name may be changed")
        XCTAssertTrue(c.bars.openInWindow.isHidden, "no ⤢ in the window")
        XCTAssertEqual(c.mode, .editable)
        XCTAssertEqual(grid.presence.menu, c.menuState, "Format ▸ Table reads the window's grid")
        XCTAssertTrue(c.menuState.isEnabled(.sendTo(.piece)), "the handed-over piece")

        c.perform(.caption("Something else"))
        XCTAssertEqual(c.bars.captionField.stringValue, "Cash flow", "a caption commit is refused")

        c.perform(.name("ledger"))
        await c.settleWrites()
        XCTAssertEqual(project.session.projectStore.manifest.figures?.first { $0.id == project.figure.id }?.name,
                       "ledger", "the name is renamed through the store")
        await project.registry.release(project.lease)
    }

    /// A view-only share makes the window's grid read-only, its name locked
    /// with the caption — read live, not a snapshot: the share flipping
    /// while the window is open turns it read-only and back.
    func test_aViewOnlyShareIsReadOnly_andAFlipWhileOpenReasks() async throws {
        let project = try await openProject()
        let windows = project.session.figureWindows
        windows.setShareIsReadOnly(true)
        let (_, _, c) = try await openWindow(project, handoff: handoff(project))
        XCTAssertEqual(c.mode, .readOnly(.viewOnlyShare))
        XCTAssertFalse(c.bars.nameField.isEditable)
        XCTAssertFalse(c.bars.captionField.isEditable)

        windows.setShareIsReadOnly(false)
        XCTAssertEqual(c.mode, .editable, "the share came back writable")
        XCTAssertTrue(c.bars.nameField.isEditable)
        windows.setShareIsReadOnly(true)
        XCTAssertEqual(c.mode, .readOnly(.viewOnlyShare), "and view-only again, mid-visit")
        await project.registry.release(project.lease)
    }

    /// **The line follows the book**: the index's "Table N" and caption,
    /// told while the window is open, reach its bottom bar (still locked).
    func test_theBottomBarFollowsTheLineAsTheBookChanges() async throws {
        let project = try await openProject()
        let (_, _, c) = try await openWindow(project, handoff: handoff(project))
        project.session.figureWindows.lineChanged(project.figure.id, number: "Table 3", caption: "Cash, revised")
        XCTAssertEqual(c.bars.numberLabel.stringValue, "Table 3")
        XCTAssertEqual(c.bars.captionField.stringValue, "Cash, revised")
        XCTAssertFalse(c.bars.captionField.isEditable)
        XCTAssertEqual(project.session.figureWindows.handoff(for: project.figure.id)?.caption, "Cash, revised")
        await project.registry.release(project.lease)
    }

    /// **Esc in a window closes nothing** (ruling 3): with nothing to cancel
    /// it does nothing; an open edit is still cancelled. Done closes the
    /// window, and the grid leaves ⌘W to the window.
    func test_escClosesNoWindow_doneDoes_andTheGridLeavesCommandW() async throws {
        let project = try await openProject()
        let (window, grid, c) = try await openWindow(project, handoff: handoff(project))
        let b2 = cell(c, 2, 2)
        typeOpen(c, b2, "4")
        c.handle(.escape)
        XCTAssertNil(c.host.state.table[b2], "Esc cancelled the open edit")
        c.handle(.escape)
        c.handle(.escape)
        XCTAssertTrue(window.isVisible, "Esc with nothing to cancel does nothing")
        XCTAssertFalse(grid.isFinished)
        let commandW = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        XCTAssertFalse(c.gridView.performKeyEquivalent(with: commandW), "⌘W is the window's")

        c.perform(.done)
        XCTAssertFalse(window.isVisible, "Done closes the window")
        XCTAssertTrue(grid.isFinished)
        await project.registry.release(project.lease)
    }

    // MARK: - Its own undo, and the close (R7d-5)

    /// A write in the window lands on the window's own stack and records no
    /// visit; closing the window commits an open edit, lands every write,
    /// ends the visit and registers no step anywhere.
    func test_theWindowKeepsItsOwnStack_andClosingCommitsAndAddsNoStep() async throws {
        let project = try await openProject()
        let (window, grid, c) = try await openWindow(project, handoff: handoff(project))
        let b2 = cell(c, 2, 2), b3 = cell(c, 2, 3)
        typeOpen(c, b2, "4")
        c.handle(.returnKey(backward: false))
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[b2]?.content, .value(.number(4)))
        XCTAssertTrue(c.gridUndo.canUndo, "on the window's own stack")
        XCTAssertFalse(c.host.visitHasRecorded, "a window records no visit: nothing collapses at its close")
        let windowUndo = window.undoManager
        XCTAssertFalse(windowUndo?.canUndo ?? false, "nothing on the window's stack")

        typeOpen(c, b3, "5")
        window.close()
        XCTAssertTrue(grid.isFinished, "the visit ends with the window")
        XCTAssertNil(grid.presence.menu, "Format ▸ Table stands down")
        await grid.finishing?.value
        XCTAssertEqual(c.host.state.table[b3]?.content, .value(.number(5)), "the open edit was committed")
        XCTAssertFalse(windowUndo?.canUndo ?? false, "closing added no step")
        XCTAssertFalse(project.session.figureWindows.isOpen(project.figure.id))
        await project.registry.release(project.lease)
    }

    /// **Review Focus 3**: the project's window closes — the figure window
    /// closes too, and its visit is finished (writes landed, closed).
    func test_reviewFocus3_closingTheProjectClosesTheWindowAndEndsItsVisit() async throws {
        let project = try await openProject()
        let (window, grid, c) = try await openWindow(project, handoff: handoff(project))
        typeOpen(c, cell(c, 1, 1), "9")

        await project.registry.release(project.lease)

        XCTAssertFalse(window.isVisible, "the figure window closed with its project")
        XCTAssertTrue(grid.isFinished)
        await grid.finishing?.value
        XCTAssertEqual(c.host.state.table[cell(c, 1, 1)]?.content, .value(.number(9)),
                       "the open edit landed before the visit closed")
    }

    // MARK: - Send to Research (R7d-7)

    /// From the window's grid: the window closes first, then the figure is
    /// parked in the piece's Research (a novel's chapter: shared, linked).
    func test_sendToResearchFromTheWindowClosesItAndParksTheFigure() async throws {
        let project = try await openProject()
        let (window, grid, c) = try await openWindow(project, handoff: handoff(project))

        c.performTableCommand(.sendTo(.piece))

        XCTAssertFalse(window.isVisible, "the window goes first")
        XCTAssertTrue(grid.isFinished)
        await grid.finishing?.value
        let parked = try await project.session.documentStore.figureIsParked(project.figure.id)
        XCTAssertTrue(parked, "the figure is in Research")
        let store = project.session.projectStore
        let item = try XCTUnwrap(store.manifest.research.first { $0.kind == .table })
        let chapter = try XCTUnwrap(store.manifest.structure.first { $0.id == project.chapter.id })
        XCTAssertEqual(chapter.linkedResearchIds ?? [], [item.id], "in the chapter's Research")
        await project.registry.release(project.lease)
    }
}

/// **The in-place card and the figure window** (report plan 7d Task 9,
/// R7d-9, R7d-7): one grid per host — a figure open in a window draws
/// "Editing in window" on its card and a double-click or Return brings that
/// window front; ⤢ folds the in-place grid first (its visit collapsed into
/// its step) and asks for the window; Send to Research folds first, with no
/// step, and the line leaves the text as plan 6b's send removes it.
@MainActor
final class FigureCardWindowTests: FigureGridMountedTestCase {

    private func expanded(_ m: Mounted) async throws -> FigureGridController {
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        return try XCTUnwrap(grid.controller)
    }

    private func cell(_ c: FigureGridController, _ column: Int, _ row: Int) -> CellKey {
        let table = c.host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    private func cardsInWindow(_ m: Mounted) throws -> Int {
        let overlay = try XCTUnwrap(m.coordinator.figureThumbnailOverlay)
        overlay.display()
        return overlay.lastCardsInWindow
    }

    /// **R7d-9**: while a window is open on the figure, its cards say
    /// "Editing in window", and a double-click on the card or Return on its
    /// line brings that window front instead of expanding; once the window
    /// closes, the card is a card again and expands.
    func test_aFigureInAWindow_saysSo_andItsCardFocusesTheWindow() async throws {
        let windows = FigureWindows()
        let m = try await mount(windows: windows)
        let figureId = try XCTUnwrap(m.figure?.id)
        let line = location(m, "![Cash](")
        park(m, caret: location(m, "Middle prose"), showing: line)
        XCTAssertEqual(try cardsInWindow(m), 0, "premise: no window")

        var focused = 0
        let registration = windows.opened(figureId, focus: { focused += 1 }, close: {})
        let overlay = try XCTUnwrap(m.coordinator.figureThumbnailOverlay)
        let before = overlay.displayRequests
        let repainted = await RunLoopPump.until(deadline: 2) { overlay.displayRequests > before }
        XCTAssertTrue(repainted, "the window's opening repaints the cards")
        XCTAssertGreaterThan(try cardsInWindow(m), 0, "the card says “Editing in window”")
        XCTAssertEqual(FigureThumbnailOverlay.editingInWindow, "Editing in window")

        // A double-click on the card.
        let point = CGPoint(x: m.textView.textContainerOrigin.x + 24, y: lineBottom(m, at: line) + 12)
        XCTAssertEqual(m.coordinator.figureCardLine(at: point), line, "premise: the point is in the card")
        XCTAssertTrue(m.coordinator.expandFigureGrid(atCardPoint: point))
        XCTAssertEqual(focused, 1, "the window comes front")
        XCTAssertNil(m.coordinator.figureGrid, "never expanded twice")

        // Return inside the line.
        m.textView.setSelectedRange(NSRange(location: line + 3, length: 0))
        XCTAssertTrue(m.coordinator.handleFigureGridCommand(#selector(NSResponder.insertNewline(_:)),
                                                            in: m.textView))
        XCTAssertEqual(focused, 2)
        XCTAssertNil(m.coordinator.figureGrid)

        windows.closed(registration)
        let cleared = await RunLoopPump.until(deadline: 2) { (try? self.cardsInWindow(m)) == 0 }
        XCTAssertTrue(cleared, "the card is a card again")
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line), "and expands")
        XCTAssertNotNil(m.coordinator.figureGrid)
    }

    /// **⤢**: the in-place grid folds first — its open edit committed and its
    /// visit collapsed into one step as Done's would be — then what only this
    /// editor knows is handed over and the window is asked for.
    func test_openInWindowFoldsFirst_collapsesTheVisit_andAsksForTheWindow() async throws {
        let windows = FigureWindows()
        var asked: [String] = []
        let m = try await mount(windows: windows, openWindow: { asked.append($0) })
        let figureId = try XCTUnwrap(m.figure?.id)
        let chapter = try XCTUnwrap(m.store.manifest.structure.first)
        let c = try await expanded(m)
        XCTAssertFalse(c.bars.openInWindow.isHidden, "⤢ is offered where a window can open")
        let number = c.line.number
        let b2 = cell(c, 2, 2)
        c.handle(.click(b2, extend: false))
        c.handle(.type("4"))
        c.handle(.editTextChanged("4"))

        c.perform(.openInWindow)

        XCTAssertNil(m.coordinator.figureGrid, "the in-place grid folded first")
        XCTAssertEqual(asked, [figureId], "then the window was asked for")
        XCTAssertNotNil(m.coordinator.lastFigureVisitStep, "the visit collapsed into its step, as usual")
        XCTAssertEqual(windows.handoff(for: figureId), FigureWindows.Handoff(
            number: number, caption: "Cash", piece: chapter.id, typography: .defaults))
        await m.coordinator.figureGridFolding?.value
        XCTAssertEqual(c.host.state.table[b2]?.content, .value(.number(4)), "the open edit was committed")
    }

    /// An edit that will not read keeps the grid here, its error shown, and
    /// no window opens; with no figure windows to open, ⤢ is not offered.
    func test_openInWindowStopsOnAnUnreadableEdit_andIsHiddenWithoutWindows() async throws {
        var asked: [String] = []
        let m = try await mount(windows: FigureWindows(), openWindow: { asked.append($0) })
        let c = try await expanded(m)
        c.handle(.click(cell(c, 1, 1), extend: false))
        c.handle(.type("="))
        c.handle(.editTextChanged("=SUM("))
        c.perform(.openInWindow)
        XCTAssertNotNil(m.coordinator.figureGrid, "the grid stays")
        XCTAssertEqual(asked, [], "no window")
        XCTAssertNotNil(c.bars.errorMessage)

        let plain = try await mount()
        let other = try await expanded(plain)
        XCTAssertTrue(other.bars.openInWindow.isHidden, "no figure windows: no ⤢")
    }

    /// A window opened on the figure from elsewhere (another project window)
    /// while it is expanded here folds this grid: never two grids on one host.
    func test_aWindowOpenedElsewhereFoldsTheInPlaceGrid() async throws {
        let windows = FigureWindows()
        let m = try await mount(windows: windows)
        _ = try await expanded(m)
        _ = windows.opened(try XCTUnwrap(m.figure?.id), close: {})
        let folded = await RunLoopPump.until(deadline: 2) { m.coordinator.figureGrid == nil }
        XCTAssertTrue(folded)
    }

    /// **Send to Research from the in-place grid** (R7d-7, ruling P1): the
    /// grid folds first — its open edit committed — with no step on the
    /// window's stack and the text given the keys; the figure is parked in
    /// the piece's Research (a novel's chapter: shared, linked) and its line
    /// leaves the manuscript as plan 6b's send removes it.
    func test_sendToResearchFoldsFirstWithNoStep_andTheLineLeaves() async throws {
        let m = try await mount()
        let figureId = try XCTUnwrap(m.figure?.id)
        let ds = try XCTUnwrap(m.store.documentStore)
        let chapter = try XCTUnwrap(m.store.manifest.structure.first)
        let chapterURL = m.store.url.appendingPathComponent(try XCTUnwrap(chapter.path))
        let doc = try await Document.load(url: chapterURL, actor: .author, session: "t", presenter: nil)
        doc.setFullText("Intro.\n\n![Cash](../figures/t.csv){#tbl:t}\n\nAfter.")
        await doc.close()

        let c = try await expanded(m)
        let b2 = cell(c, 2, 2)
        c.handle(.click(b2, extend: false))
        c.handle(.type("7"))
        c.handle(.editTextChanged("7"))

        c.performTableCommand(.sendTo(.piece))

        XCTAssertNil(m.coordinator.figureGrid, "it folds first")
        XCTAssertNil(m.coordinator.lastFigureVisitStep, "not undoable: no step (ruling P1)")
        XCTAssertTrue(m.window.firstResponder === m.textView, "the text takes the keys")
        await m.coordinator.figureGridFolding?.value
        let parked = try await ds.figureIsParked(figureId)
        XCTAssertTrue(parked, "the figure is in Research")
        XCTAssertEqual(c.host.state.table[b2]?.content, .value(.number(7)), "the open edit went with it")
        let item = try XCTUnwrap(m.store.manifest.research.first { $0.kind == .table })
        XCTAssertEqual(m.store.manifest.structure.first?.linkedResearchIds ?? [], [item.id],
                       "in the chapter's Research")
        let after = try await Document.load(url: chapterURL, actor: .author, session: "t", presenter: nil)
        let text = after.displayText
        await after.close()
        XCTAssertFalse(text.contains("![Cash]"), "the line left the text: \(text)")
        XCTAssertTrue(text.contains("Intro.") && text.contains("After."))
    }

    /// **The editor keeps the figure windows current** (concerns 1 and 4):
    /// the share as its control plane says, and at each `ReferenceIndex`
    /// version each open figure's "Table N" and caption from the whole book.
    func test_theEditorTellsTheWindowsTheShareAndTheLine() async throws {
        let windows = FigureWindows()
        let m = try await mount(windows: windows)
        let figureId = try XCTUnwrap(m.figure?.id)
        XCTAssertFalse(windows.shareIsReadOnly)
        m.coordinator.setShareIsReadOnly(true)
        XCTAssertTrue(windows.shareIsReadOnly, "the share flipped is told")
        m.coordinator.setShareIsReadOnly(false)
        XCTAssertFalse(windows.shareIsReadOnly)

        var told: [String] = []
        let listener = windows.listen(figureId, line: { told.append("\($0) · \($1)") }, access: {})
        defer { windows.stopListening(listener) }
        _ = windows.opened(figureId, close: {})
        let index = ReferenceIndex.build(
            structure: m.store.manifest.structure, research: [],
            text: { [chapter = m.store.manifest.structure.first?.id] piece in
                piece.id == chapter ? "Intro.\n\n![Cash flow](../figures/t.csv){#tbl:t}\n" : "Words.\n"
            }, words: .english)
        XCTAssertNotNil(index.target(for: try XCTUnwrap(ManuscriptLabel(reference: "tbl:t"))),
                        "premise: the line is a target")
        m.coordinator.referenceIndex = { index }
        m.coordinator.setReferenceIndexVersion(m.coordinator.referenceIndexVersion + 1)
        XCTAssertEqual(told, ["Table 1 · Cash flow"])
    }
}

/// **A figure window's grid never goes stale** (concern 2 and the gate):
/// its values reseed when another figure it reads changes, a park elsewhere
/// turns it read-only through the same card edge, and a trust change re-asks
/// through the door — the window's `FigureWindowGrid` opened over a
/// signed book's stores (no window needed: the grid is the frame's).
@MainActor
final class FigureWindowFreshnessTests: FigureGridMountedTestCase {

    override func setUp() async throws {
        try await super.setUp()
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: temp.url.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: temp.url.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: temp.url.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        for grid in grids {
            grid.finish()
            await grid.finishing?.value
        }
        grids = []
        try await super.tearDown()
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
    }

    private var grids: [FigureWindowGrid] = []

    private func openGrid(_ m: Mounted, _ figureId: String) async throws -> FigureGridController {
        let ds = try XCTUnwrap(m.store.documentStore)
        let grid = FigureWindowGrid()
        grids.append(grid)
        grid.open(figureId: figureId, store: ds, projectStore: m.store, windows: FigureWindows(), close: {})
        await grid.opening?.value
        return try XCTUnwrap(grid.controller, grid.container.message)
    }

    private func key(_ table: FigureTable, _ column: Int, _ row: Int) -> CellKey {
        CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    /// Another figure this one reads changes: the window's values reseed.
    func test_anotherFigureChangingReseedsTheWindowsValues() async throws {
        let m = try await mount()
        let ds = try XCTUnwrap(m.store.documentStore)
        let t = try XCTUnwrap(m.figure)
        let u = try await m.store.createFigure(kind: .table, name: "u", piece: nil)
        let uDoc = try await ds.openFigure(figureId: u.id)
        let u1 = key(uDoc.state.table, 1, 1)
        try await uDoc.setCell(Cell(content: .value(.number(5))), at: u1)
        let tDoc = try await ds.openFigure(figureId: t.id)
        let t1 = key(tDoc.state.table, 1, 1)
        let names = FormulaNames(figures: [.init(id: u.id, name: "u", table: uDoc.state.table)])
        guard case .success(let f) = FormulaParser.parse("u!A1*2", in: tDoc.state.table, names: names)
        else { return XCTFail("the formula did not parse") }
        try await tDoc.setCell(Cell(content: .formula(f)), at: t1)

        let c = try await openGrid(m, t.id)
        XCTAssertEqual(c.figureGridDisplay(at: t1), "10", "premise")

        try await uDoc.setCell(Cell(content: .value(.number(7))), at: u1)
        let reseeded = await RunLoopPump.until(deadline: 5) { c.figureGridDisplay(at: t1) == "14" }
        XCTAssertTrue(reseeded, "the window reads u again: \(c.figureGridDisplay(at: t1))")
    }

    /// A park elsewhere reaches the window as a card edge: read-only, parked.
    func test_aParkElsewhereTurnsTheWindowReadOnly() async throws {
        let m = try await mount()
        let t = try XCTUnwrap(m.figure)
        let c = try await openGrid(m, t.id)
        XCTAssertEqual(c.mode, .editable)
        _ = try await m.store.sendToResearch(figureId: t.id, scope: .shared)
        let parked = await RunLoopPump.until(deadline: 5) { c.mode == .readOnly(.parked) }
        XCTAssertTrue(parked, "the window's gate was asked again: \(c.mode)")
    }

    /// A trust change (another author admitted to the chapter, so this Mac
    /// yields on its figure) re-asks the window's gate through the door.
    func test_aTrustChangeReasksTheWindowsGate() async throws {
        let m = try await mount()
        let ds = try XCTUnwrap(m.store.documentStore)
        let c = try await openGrid(m, try XCTUnwrap(m.figure?.id))
        XCTAssertEqual(c.mode, .editable)
        let sam = LocalIdentities.softwareForTesting()
        _ = try await ds.admit(device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
                               permit: .author(.pieces([try XCTUnwrap(m.store.manifest.structure.first?.id)])))
        await ds.postureSettled()
        await c.postureChange?.value
        XCTAssertEqual(c.mode, .readOnly(.notYours))
    }
}
