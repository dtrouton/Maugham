import XCTest
import AppKit
@testable import MaughamCore
@testable import Maugham

/// **One grid per host, anywhere** (report plan 7d final review I1, I2, I4,
/// M2–M4): two project windows on one project share one `DocumentStore`, so
/// one figure host per table — and R7d-9 holds across them: a table expanded
/// in one window is never expanded in the other (its card says where it is
/// being edited, and a double-click or Return brings that grid front), so
/// two visits never cross. Review mode carries through ⤢ into the figure
/// window; the collapsed visit's decline is neutral when this Mac's own
/// window changed the cells; the ⤢ gap holds the figure; a hand-off leaves
/// with its last window; the window's line follows the editor's own line.
/// Acts are asked of the controller or the coordinator, never clicked
/// (tripwire 33).
@MainActor
final class FigureGridOneGridPerHostTests: FigureGridMountedTestCase {

    private var windowGrids: [FigureWindowGrid] = []

    override func tearDown() async throws {
        for grid in windowGrids {
            grid.finish()
            await grid.finishing?.value
        }
        windowGrids = []
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func expanded(_ m: Mounted) async throws -> FigureGridController {
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        return try XCTUnwrap(grid.controller)
    }

    private func cell(_ c: FigureGridController, _ column: Int, _ row: Int) -> CellKey {
        let table = c.host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    /// `text` typed into `key` and committed with Return.
    private func write(_ c: FigureGridController, _ key: CellKey, _ text: String) async {
        c.handle(.click(key, extend: false))
        c.handle(.type(text))
        c.handle(.editTextChanged(text))
        c.handle(.returnKey(backward: false))
        await c.settleWrites()
    }

    /// The figure window's grid over `m`'s stores, registered with `windows`
    /// as the window's root view registers it.
    private func openWindowGrid(_ m: Mounted, _ windows: FigureWindows) async throws
        -> (FigureWindowGrid, FigureGridController, FigureWindows.Registration) {
        let figureId = try XCTUnwrap(m.figure?.id)
        let ds = try XCTUnwrap(m.store.documentStore)
        let grid = FigureWindowGrid()
        windowGrids.append(grid)
        let registration = windows.opened(figureId, finish: { grid.finish() }, close: {})
        grid.open(figureId: figureId, store: ds, projectStore: m.store, windows: windows, close: {})
        await grid.opening?.value
        return (grid, try XCTUnwrap(grid.controller, grid.container.message), registration)
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

    private func heldLabels(_ m: Mounted) throws -> [String] {
        let overlay = try XCTUnwrap(m.coordinator.figureThumbnailOverlay)
        overlay.display()
        return overlay.lastHeldLabels
    }

    // MARK: - I1: one grid per host across project windows

    /// **Two project windows on one project** (final review I1): A expands
    /// the table; B's card says "Editing in another window" and its
    /// double-click (Return) brings A's grid front, expanding nothing. A's
    /// fold collapses A's own visit — one step on A's text, taking back only
    /// A's cells; B, expanding after, begins and owns its own, which its own
    /// ⌘Z takes back alone. (Before: B's expand was ignored by the host but
    /// B still ended the open visit — A's — onto B's stack.)
    func test_aTableExpandedInOneProjectWindowIsNeverExpandedInAnother() async throws {
        let windows = FigureWindows()
        let a = try await mount(windows: windows)
        let b = try await mount(windows: windows, sharing: a)
        let line = location(a, "![Cash](")
        park(b, caret: location(b, "Middle prose"), showing: line)
        XCTAssertEqual(try heldLabels(b), [], "premise: nothing held")

        let ca = try await expanded(a)
        XCTAssertTrue(a.coordinator.figureGrid?.recordsAVisit == true, "A owns the visit")
        // Both of B's lines naming the figure say so.
        let labelled = await RunLoopPump.until(deadline: 2) {
            let labels = (try? self.heldLabels(b)) ?? []
            return !labels.isEmpty && labels.allSatisfy { $0 == FigureThumbnailOverlay.editingInAnotherWindow }
        }
        XCTAssertTrue(labelled, "B's card says where it is being edited: \((try? heldLabels(b)) ?? [])")
        XCTAssertEqual(FigureThumbnailOverlay.editingInAnotherWindow, "Editing in another window")
        XCTAssertEqual(try heldLabels(a), [], "A's own grid is not another's: its second line is a card")

        XCTAssertTrue(b.coordinator.expandFigureGrid(lineAt: line), "the card answers")
        XCTAssertNil(b.coordinator.figureGrid, "never a second grid on the host")
        XCTAssertTrue(a.window.firstResponder === ca.gridView, "A's grid came front with the keys")
        b.textView.setSelectedRange(NSRange(location: line + 3, length: 0))
        XCTAssertTrue(b.coordinator.handleFigureGridCommand(#selector(NSResponder.insertNewline(_:)),
                                                            in: b.textView))
        XCTAssertNil(b.coordinator.figureGrid, "Return inside the line expands nothing either")

        let a1 = cell(ca, 1, 1), b2 = cell(ca, 2, 2)
        await write(ca, a1, "1")
        ca.perform(.done)
        XCTAssertNil(a.coordinator.figureGrid)
        let stepA = try XCTUnwrap(a.coordinator.lastFigureVisitStep, "A's visit is A's step")

        // B expands at once — its visit begins only after A's has ended.
        let cb = try await expanded(b)
        XCTAssertTrue(b.coordinator.figureGrid?.recordsAVisit == true, "B owns a visit of its own")
        await stepA.settled?.value
        await write(cb, b2, "2")
        cb.perform(.done)
        let stepB = try XCTUnwrap(b.coordinator.lastFigureVisitStep)
        await b.coordinator.figureGridFolding?.value
        await stepB.settled?.value
        XCTAssertEqual(cb.host.state.table[a1]?.content, .value(.number(1)))
        XCTAssertEqual(cb.host.state.table[b2]?.content, .value(.number(2)))

        b.textView.undoManager?.undo()
        await cb.host.awaitPendingUndoWork()
        XCTAssertNil(cb.host.state.table[b2], "B's ⌘Z took back B's visit")
        XCTAssertEqual(cb.host.state.table[a1]?.content, .value(.number(1)), "and never A's cells")

        a.textView.undoManager?.undo()
        await ca.host.awaitPendingUndoWork()
        XCTAssertNil(ca.host.state.table[a1], "A's ⌘Z took back A's visit")
    }

    /// The host's half (I1): a begin while a visit is open answers false and
    /// records nothing new for its caller, and only the visit's own stack
    /// ends it.
    func test_onlyTheGridThatBeganAVisitEndsIt() async throws {
        let m = try await mount()
        let ds = try XCTUnwrap(m.store.documentStore)
        let host = try await ds.openFigure(figureId: try XCTUnwrap(m.figure?.id))
        let mine = UndoManager(), theirs = UndoManager()
        XCTAssertTrue(host.beginVisit(undoManager: mine))
        XCTAssertFalse(host.beginVisit(undoManager: theirs), "a visit is open: the second grid owns none")
        let a1 = CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
        try await host.setCell(Cell(content: .value(.number(3))), at: a1, undoManager: mine)
        XCTAssertNil(host.endVisit(ownedBy: theirs), "not theirs to end")
        XCTAssertTrue(host.visitHasRecorded, "the open visit goes on")
        let visit = try XCTUnwrap(host.endVisit(ownedBy: mine))
        XCTAssertEqual(visit.ops.count, 1)
    }

    // MARK: - I2: review mode carries into the window

    /// **⤢ from a review-mode grid** (final review I2): the grid is read-only
    /// in place, ⤢ still offered; the window it opens is read-only for the
    /// same reason, and follows the opening editor's review toggle.
    func test_reviewModeCarriesIntoTheFigureWindow_andFollowsTheToggle() async throws {
        let windows = FigureWindows()
        var asked: [String] = []
        let m = try await mount(windows: windows, openWindow: { asked.append($0) })
        let figureId = try XCTUnwrap(m.figure?.id)
        m.coordinator.setManualReviewMode(true)
        let c = try await expanded(m)
        XCTAssertEqual(c.mode, .readOnly(.reviewMode), "premise: review mode in place")
        XCTAssertFalse(c.bars.openInWindow.isHidden)

        c.perform(.openInWindow)
        XCTAssertEqual(asked, [figureId])
        XCTAssertEqual(windows.handoff(for: figureId)?.isReviewMode, true, "review mode is handed over")
        await m.coordinator.figureGridFolding?.value

        let (_, w, _) = try await openWindowGrid(m, windows)
        XCTAssertEqual(w.mode, .readOnly(.reviewMode), "the window opens read-only")
        m.coordinator.setManualReviewMode(false)
        XCTAssertEqual(w.mode, .editable, "and follows the toggle off")
        m.coordinator.setManualReviewMode(true)
        XCTAssertEqual(w.mode, .readOnly(.reviewMode), "and on again")
    }

    // MARK: - I4: the neutral decline

    /// **This Mac's own window changed a cell the visit wrote** (final review
    /// I4): type in place, ⤢, retype the cell in the window, close it, ⌘Z
    /// in the text — declined whole, and said neutrally, never "another device".
    func test_aVisitRetypedInThisMacsWindowDeclinesNeutrally() async throws {
        let windows = FigureWindows()
        let m = try await mount(windows: windows, openWindow: { _ in })
        let c = try await expanded(m)
        let b2 = cell(c, 2, 2)
        await write(c, b2, "4")
        c.perform(.openInWindow)
        let step = try XCTUnwrap(m.coordinator.lastFigureVisitStep, "the visit collapsed at ⤢")
        await m.coordinator.figureGridFolding?.value
        await step.settled?.value

        let (grid, w, registration) = try await openWindowGrid(m, windows)
        await write(w, b2, "5")
        grid.finish()
        await grid.finishing?.value
        windows.closed(registration)

        let said = await notices {
            m.textView.undoManager?.undo()
            await c.host.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, ["Couldn't undo the table edit — it has changed since."])
        XCTAssertEqual(c.host.state.table[b2]?.content, .value(.number(5)), "declined whole")
    }

    // MARK: - M3, M4: the ⤢ gap and the hand-off's life

    /// **The ⤢ gap** (T9 review M3): from the hand-off until the window
    /// registers, the figure is held — a double-click expands nothing. The
    /// window's close takes the hand-off with it (T9 review M5), so a later
    /// window never inherits a stale piece or review mode.
    func test_theFigureIsHeldWhileItsWindowOpens_andTheHandoffLeavesWithIt() async throws {
        let windows = FigureWindows()
        let m = try await mount(windows: windows, openWindow: { _ in })
        let figureId = try XCTUnwrap(m.figure?.id)
        let line = location(m, "![Cash](")
        let c = try await expanded(m)
        c.perform(.openInWindow)
        XCTAssertNil(m.coordinator.figureGrid)
        XCTAssertTrue(windows.isHeld(figureId), "held while its window opens")
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        XCTAssertNil(m.coordinator.figureGrid, "never re-expanded in the gap")

        let registration = windows.opened(figureId, close: {})
        XCTAssertNotNil(windows.handoff(for: figureId))
        windows.closed(registration)
        XCTAssertNil(windows.handoff(for: figureId), "the hand-off left with its last window")
        XCTAssertFalse(windows.isHeld(figureId))
        await m.coordinator.figureGridFolding?.value
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        XCTAssertNotNil(m.coordinator.figureGrid, "and the card expands again")
    }

    // MARK: - M2: the window's line follows the editor's own line

    /// **An unlabelled figure line** (final review M2): the editor showing
    /// the figure's line tells the window its "Table N" and caption from
    /// that line — no label needed.
    func test_anUnlabelledLineStillReachesTheWindow() async throws {
        let windows = FigureWindows()
        let m = try await mount("Intro.\n\n![Cash flow](../figures/t.csv)\n\nThe end.", windows: windows)
        let figureId = try XCTUnwrap(m.figure?.id)
        var told: [String] = []
        let listener = windows.listen(figureId, line: { told.append("\($0) · \($1)") }, access: {})
        defer { windows.stopListening(listener) }
        _ = windows.opened(figureId, close: {})
        m.coordinator.setReferenceIndexVersion(m.coordinator.referenceIndexVersion + 1)
        XCTAssertEqual(told.count, 1, "\(told)")
        XCTAssertTrue(told.last?.hasSuffix(" · Cash flow") == true, "\(told)")
    }

    /// The index's half (M2): a `tbl:` label naming the figure counts only
    /// where it is defined in the figure's own piece.
    func test_theIndexTargetMustBeInTheFiguresOwnPiece() async throws {
        let m = try await mount()
        let record = try XCTUnwrap(m.figure)
        let chapter = try XCTUnwrap(m.store.manifest.structure.first?.id)
        let index = ReferenceIndex.build(
            structure: m.store.manifest.structure, research: [],
            text: { piece in piece.id == chapter ? "![Cash flow](../figures/t.csv){#tbl:t}\n" : "" },
            words: .english)
        XCTAssertEqual(EditorCoordinator.figureWindowTarget(for: record, in: index)?.detail, "Cash flow")
        var elsewhere = record
        elsewhere.piece = "another-piece"
        XCTAssertNil(EditorCoordinator.figureWindowTarget(for: elsewhere, in: index),
                     "a label in another piece is another line")
    }
}
