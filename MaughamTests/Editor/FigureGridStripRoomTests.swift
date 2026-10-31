import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The suggestion strip's room, proven before the strip exists** (report
/// plan 9c-2 Task 1, spec risk §11.1). The in-place grid reserves a strip
/// above its rows while the figure has an open live cell note
/// (`FigureCardModel.hasOpenCellNotes`). That presence changes only at a
/// `figureCardVersion` edge, through the same one-paragraph re-layout a
/// growing table takes — never per selection, so the writer's arrows across
/// marked and unmarked cells re-lay out nothing. The strip part goes both
/// ways; the rows part still only grows (R7c-2).
///
/// A mounted `EditorSurface` (the shared fixture), the flag set on the card
/// the editor's provider reports, a version landed by the coordinator's verb.
/// Arrows go through the grid's real `keyDown`; nothing presses and waits.
@MainActor
final class FigureGridStripRoomTests: FigureGridMountedTestCase {
    // MARK: - Pure: the panel's parts

    /// **(d)** The parts stack toolbar, formula bar, strip, grid, bottom bar,
    /// top to bottom, filling the panel; the strip is `stripHeight` and the
    /// grid keeps exactly its viewport. Without a strip there is no strip
    /// part and the grid follows the formula bar.
    func test_thePartsStackToolbarFormulaStripGridBottom() throws {
        let row = FigureCardMetrics.rowHeight(for: .defaults)
        let room = FigureGridPanel.room(rows: 3, strip: true, typography: .defaults)
        XCTAssertEqual(room - FigureGridPanel.room(rows: 3, strip: false, typography: .defaults),
                       FigureGridPanel.stripHeight, "the strip adds its own height, nothing else")
        let size = FigureGridPanel.frame(lineBottom: 0, room: room, columnX: 0, columnWidth: 600).size

        let parts = FigureGridPanel.parts(in: size, strip: true)
        let strip = try XCTUnwrap(parts.strip)
        XCTAssertEqual(parts.toolbar.minY, 0)
        XCTAssertEqual(parts.formulaBar.minY, parts.toolbar.maxY)
        XCTAssertEqual(strip.minY, parts.formulaBar.maxY, "the strip sits under the formula bar")
        XCTAssertEqual(strip.height, FigureGridPanel.stripHeight)
        XCTAssertEqual(strip.width, size.width)
        XCTAssertEqual(parts.grid.minY, strip.maxY, "the grid sits under the strip")
        XCTAssertEqual(parts.grid.height, FigureGridLayout.viewportHeight(rows: 3, rowHeight: row),
                       "the grid keeps exactly its viewport")
        XCTAssertEqual(parts.bottomBar.minY, parts.grid.maxY)
        XCTAssertEqual(parts.bottomBar.maxY, size.height)

        let bare = FigureGridPanel.parts(in: size, strip: false)
        XCTAssertNil(bare.strip)
        XCTAssertEqual(bare.grid.minY, bare.formulaBar.maxY)
        XCTAssertEqual(bare.grid.height, parts.grid.height + FigureGridPanel.stripHeight,
                       "no strip: the grid takes the space")
    }

    // MARK: - (a) the flag arriving at a card edge

    /// **(a)** A card version flipping the flag on re-lays out exactly the
    /// expanded line, once, and moves the text below down by `stripHeight`;
    /// the text above, the caret and the other line of the same figure
    /// (whose card height the flag never moves) stay where they are. The
    /// panel grows by the strip and carves it under the formula bar.
    func test_aCardEdgeFlippingTheFlagOnReLaysOutTheExpandedLineOnce() async throws {
        let notes = OpenCellNotes(false)
        let m = try await mount(openCellNotes: notes)
        let line = location(m, "![Cash](")
        let other = location(m, "![Cash again]")
        let body = spacing(m, at: location(m, "Middle prose"))
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        let grid = try await opened(m)
        let panel = try XCTUnwrap(grid.panel)
        let bare = FigureGridPanel.room(rows: 3, strip: false, typography: .defaults)
        XCTAssertEqual(grid.room, bare, "premise: no strip yet")
        XCTAssertFalse(panel.showsStrip)
        let caret = m.textView.selectedRange()
        let above = lineTop(m, at: location(m, "Paragraph 40"))
        let below = lineTop(m, at: location(m, "Middle prose"))
        let refreshes = m.coordinator.figureRoomRefreshCount

        notes.value = true
        m.coordinator.setFigureCardVersion(m.coordinator.figureCardVersion + 1)

        XCTAssertEqual(m.coordinator.figureRoomRefreshCount - refreshes, 1, "the expanded line only, once")
        XCTAssertEqual(grid.room, bare + FigureGridPanel.stripHeight)
        XCTAssertEqual(spacing(m, at: line) - body, grid.room, "the line holds the strip's room")
        XCTAssertEqual(spacing(m, at: other) - body, cardRoom(m), "the other line keeps its card")
        XCTAssertEqual(lineTop(m, at: location(m, "Middle prose")), below + FigureGridPanel.stripHeight,
                       accuracy: 0.5, "the text below moves down by the strip")
        XCTAssertEqual(lineTop(m, at: location(m, "Paragraph 40")), above, accuracy: 0.5, "the text above stays")
        XCTAssertEqual(m.textView.selectedRange(), caret, "the caret is still")
        XCTAssertTrue(panel.showsStrip)
        XCTAssertEqual(panel.frame.height, grid.room - 2 * FigureGridPanel.gap, accuracy: 0.5)
        XCTAssertEqual(controllerGridFrame(grid)?.minY ?? 0,
                       2 * FigureGridBars.barHeight + FigureGridPanel.stripHeight, accuracy: 0.5,
                       "the grid sits under the strip")

        // The same version again, or a new one with no flip, moves nothing.
        let settled = m.coordinator.figureRoomRefreshCount
        m.coordinator.setFigureCardVersion(m.coordinator.figureCardVersion + 1)
        XCTAssertEqual(m.coordinator.figureRoomRefreshCount, settled, "no flip, no re-layout")
    }

    /// **(a), mid-burst**: the flag landing while a typing burst is in
    /// flight keeps the painted room until the settle, then re-lays out the
    /// expanded line once; the typing is undisturbed.
    func test_aFlipMidBurstWaitsForTheSettle() async throws {
        let notes = OpenCellNotes(false)
        let m = try await mount(openCellNotes: notes)
        m.coordinator.restyleSettleDelayMs = 0   // the settle runs on the next main-actor turn
        let line = location(m, "![Cash](")
        let body = spacing(m, at: location(m, "Middle prose"))
        let typeAt = NSMaxRange(m.text.range(of: "Paragraph 40 of plain prose before the table."))
        park(m, caret: typeAt, showing: line)
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        let grid = try await opened(m)
        await m.coordinator.deferredRestyleTask?.value
        let bare = grid.room
        let refreshes = m.coordinator.figureRoomRefreshCount
        let panel = try XCTUnwrap(grid.panel)
        let frameBefore = panel.frame

        m.textView.insertText(" and", replacementRange: NSRange(location: typeAt, length: 0))
        XCTAssertTrue(m.coordinator.isInTypingBurst, "premise: a burst is in flight")
        XCTAssertTrue(m.coordinator.figureGrid === grid, "premise: the grid is still open")
        notes.value = true
        m.coordinator.setFigureCardVersion(m.coordinator.figureCardVersion + 1)
        let typedLine = location(m, "![Cash](")

        XCTAssertEqual(m.coordinator.figureRoomRefreshCount, refreshes, "nothing re-laid out mid-burst")
        XCTAssertEqual(spacing(m, at: typedLine) - body, bare, "mid-burst the line keeps its painted room")
        XCTAssertTrue(m.coordinator.figureRoomsWaitForTheSettle)
        XCTAssertEqual(grid.room, bare, "the room waits for the settle")
        XCTAssertEqual(panel.frame.height, frameBefore.height, accuracy: 0.5,
                       "the panel waits with the paragraph: it never covers the line below")
        XCTAssertFalse(panel.showsStrip)

        await m.coordinator.deferredRestyleTask?.value   // the settle edge
        XCTAssertEqual(m.coordinator.figureRoomRefreshCount - refreshes, 1, "once, at the settle")
        XCTAssertEqual(spacing(m, at: typedLine) - body, bare + FigureGridPanel.stripHeight)
        XCTAssertEqual(grid.room, bare + FigureGridPanel.stripHeight)
        XCTAssertEqual(panel.frame.height, grid.room - 2 * FigureGridPanel.gap, accuracy: 0.5,
                       "panel and paragraph moved together, at the settle")
        XCTAssertTrue(panel.showsStrip)
        XCTAssertTrue(m.text.contains("before the table. and"), "the typing landed")
    }

    // MARK: - (b) selection never moves the room

    /// **(b), Review Focus 1**: with the strip reserved, many arrow keys
    /// across the table's cells (through the grid's real `keyDown`) cause no
    /// room refresh and no text-storage edit at all — the strip's presence is
    /// the figure's, never the selection's.
    func test_arrowKeysAcrossCellsReLayOutNothing() async throws {
        let notes = OpenCellNotes(true)
        let m = try await mount(openCellNotes: notes)
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        let controller = try XCTUnwrap(grid.controller)
        XCTAssertTrue(m.window.firstResponder === controller.gridView, "premise: the grid has the keys")
        let room = grid.room
        let refreshes = m.coordinator.figureRoomRefreshCount
        var edits = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: m.textView.textStorage, queue: nil) { _ in MainActor.assumeIsolated { edits += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        var visited = Set<CellKey>()
        let path: [UInt16] = [124, 124, 125, 125, 123, 123, 126, 126, 124, 125, 124, 125, 123, 126, 123, 126]
        for _ in 0..<3 {
            for keyCode in path {
                controller.gridView.keyDown(with: arrow(m, keyCode))
                if let anchor = controller.model.selection?.anchor { visited.insert(anchor) }
            }
        }

        XCTAssertGreaterThanOrEqual(visited.count, 9, "premise: the arrows crossed every cell")
        XCTAssertEqual(m.coordinator.figureRoomRefreshCount, refreshes, "no room refresh")
        XCTAssertEqual(edits, 0, "no paragraph-style (or any) storage edit")
        XCTAssertFalse(m.coordinator.figureRoomsWaitForTheSettle, "nothing parked for a settle")
        XCTAssertEqual(grid.room, room, "the room is the figure's, not the selection's")
    }

    // MARK: - (c) the flag going away

    /// **(c)** The figure's last open cell note answered: at the next card
    /// edge the strip's room is given back — that line re-laid out once, the
    /// text below back where it was — while the rows part never shrinks.
    func test_theFlagGoingFalseGivesTheStripBack_rowsStayGrowOnly() async throws {
        let notes = OpenCellNotes(true)
        let m = try await mount(openCellNotes: notes)
        let line = location(m, "![Cash](")
        let body = spacing(m, at: location(m, "Middle prose"))
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        let grid = try await opened(m)
        let withStrip = FigureGridPanel.room(rows: 3, strip: true, typography: .defaults)
        XCTAssertEqual(grid.room, withStrip, "expanded with notes: the strip's room from the first")
        XCTAssertEqual(spacing(m, at: line) - body, withStrip)
        XCTAssertTrue(try XCTUnwrap(grid.panel).showsStrip, "mounted with the strip")
        let below = lineTop(m, at: location(m, "Middle prose"))
        let refreshes = m.coordinator.figureRoomRefreshCount

        notes.value = false
        m.coordinator.setFigureCardVersion(m.coordinator.figureCardVersion + 1)

        let bare = FigureGridPanel.room(rows: 3, strip: false, typography: .defaults)
        XCTAssertEqual(m.coordinator.figureRoomRefreshCount - refreshes, 1, "that line only, once")
        XCTAssertEqual(grid.room, bare, "the strip's room is given back")
        XCTAssertEqual(spacing(m, at: line) - body, bare)
        XCTAssertEqual(lineTop(m, at: location(m, "Middle prose")), below - FigureGridPanel.stripHeight,
                       accuracy: 0.5, "the text below moves back up")
        XCTAssertFalse(try XCTUnwrap(grid.panel).showsStrip)

        // The rows part grows with the table and never shrinks with the strip.
        let host = try XCTUnwrap(grid.controller?.host)
        _ = try await host.insertRow(after: host.state.table.rows.last!, undoManager: nil)
        await m.store.documentStore?.settleFigureCards()
        await m.cards.idle()
        notes.value = true
        m.coordinator.setFigureCardVersion(m.coordinator.figureCardVersion + 1)
        XCTAssertEqual(grid.room, FigureGridPanel.room(rows: 4, strip: true, typography: .defaults))
        try await host.deleteRow(host.state.table.rows.last!, undoManager: nil)
        await m.store.documentStore?.settleFigureCards()
        await m.cards.idle()
        notes.value = false
        m.coordinator.setFigureCardVersion(m.coordinator.figureCardVersion + 1)
        XCTAssertEqual(grid.room, FigureGridPanel.room(rows: 4, strip: false, typography: .defaults),
                       "the strip goes; the four-row room stays (R7c-2)")
        XCTAssertEqual(spacing(m, at: line) - body, grid.room)
    }

    /// **Review I1: the give-back never scrolls the grid.** A 30-row table
    /// scrolled to its bottom (the cell just answered): the strip going away
    /// lays the panel out once with its new frame and flag, so the grid keeps
    /// its height and its scroll.
    func test_theStripGoingAwayLeavesALongGridsScrollAlone() async throws {
        let notes = OpenCellNotes(true)
        let m = try await mount(rows: 30, openCellNotes: notes)
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        let controller = try XCTUnwrap(grid.controller)
        let table = controller.host.state.table
        let gridHeight = controller.gridView.frame.height
        controller.gridView.scrollTo(CellKey(row: table.rows.last!, column: table.columns.first!))
        let scrolled = controller.gridView.scrollOffset
        XCTAssertGreaterThan(scrolled.y, 0, "premise: scrolled to the bottom")

        notes.value = false
        m.coordinator.setFigureCardVersion(m.coordinator.figureCardVersion + 1)
        XCTAssertFalse(try XCTUnwrap(grid.panel).showsStrip, "premise: the strip went")
        XCTAssertEqual(controller.gridView.scrollOffset, scrolled, "the grid's scroll is left alone")
        XCTAssertEqual(controller.gridView.frame.height, gridHeight, accuracy: 0.5, "the grid keeps its height")

        notes.value = true
        m.coordinator.setFigureCardVersion(m.coordinator.figureCardVersion + 1)
        XCTAssertTrue(try XCTUnwrap(grid.panel).showsStrip)
        XCTAssertEqual(controller.gridView.scrollOffset, scrolled, "nor does its return")
    }

    /// **Folded with the strip, then expanded again**: the folded line holds
    /// its card's room (the flag never moves a card's height); the next
    /// expansion takes the strip's room from the first.
    func test_theFlagAcrossAFoldAndAReExpand() async throws {
        let notes = OpenCellNotes(true)
        let m = try await mount(openCellNotes: notes)
        let line = location(m, "![Cash](")
        let body = spacing(m, at: location(m, "Middle prose"))
        let withStrip = FigureGridPanel.room(rows: 3, strip: true, typography: .defaults)
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        _ = try await opened(m)
        XCTAssertEqual(spacing(m, at: line) - body, withStrip)

        m.coordinator.foldFigureGrid(commit: true)
        await m.coordinator.figureGridFolding?.value
        XCTAssertNil(m.coordinator.figureGrid)
        XCTAssertEqual(spacing(m, at: line) - body, cardRoom(m), "folded: the card's room, no strip")

        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        let again = try XCTUnwrap(m.coordinator.figureGrid)
        XCTAssertEqual(again.room, withStrip, "re-expanded: the strip's room from the first")
        XCTAssertEqual(spacing(m, at: line) - body, withStrip)
        _ = try await opened(m)
        XCTAssertTrue(try XCTUnwrap(again.panel).showsStrip)
        XCTAssertEqual(again.room, withStrip, "the mount agrees")
    }

    /// **The rows grow while the strip stays put** — separate edges: a row
    /// added at one card edge grows the rows part with the strip still
    /// reserved, re-laying out the line once; the strip's part never moved.
    func test_rowsGrowAtTheirOwnEdgeWhileTheStripStaysPut() async throws {
        let notes = OpenCellNotes(true)
        // One line of the figure: a second line's card would grow too.
        let m = try await mount("Opening.\n\n![Cash](../figures/t.csv){#tbl:t}\n\nMiddle prose.",
                                openCellNotes: notes)
        let line = location(m, "![Cash](")
        let body = spacing(m, at: location(m, "Middle prose"))
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        let grid = try await opened(m)
        XCTAssertEqual(grid.room, FigureGridPanel.room(rows: 3, strip: true, typography: .defaults))
        let host = try XCTUnwrap(grid.controller?.host)
        _ = try await host.insertRow(after: host.state.table.rows.last!, undoManager: nil)
        await m.store.documentStore?.settleFigureCards()
        await m.cards.idle()
        let refreshes = m.coordinator.figureRoomRefreshCount

        m.coordinator.setFigureCardVersion(m.cards.version)

        XCTAssertEqual(grid.room, FigureGridPanel.room(rows: 4, strip: true, typography: .defaults),
                       "the rows part grew; the strip is still there")
        XCTAssertTrue(grid.reservesStrip)
        XCTAssertTrue(try XCTUnwrap(grid.panel).showsStrip)
        XCTAssertEqual(spacing(m, at: line) - body, grid.room)
        XCTAssertEqual(m.coordinator.figureRoomRefreshCount - refreshes, 1, "that line, once")
        XCTAssertEqual(try XCTUnwrap(grid.panel).frame.height, grid.room - 2 * FigureGridPanel.gap, accuracy: 0.5)
    }

    // MARK: - Helpers

    private func arrow(_ m: Mounted, _ keyCode: UInt16) -> NSEvent {
        let scalar: Character = switch keyCode {
        case 123: "\u{F702}"
        case 124: "\u{F703}"
        case 125: "\u{F701}"
        default: "\u{F700}"
        }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                timestamp: 0, windowNumber: m.window.windowNumber, context: nil,
                                characters: String(scalar), charactersIgnoringModifiers: String(scalar),
                                isARepeat: false, keyCode: keyCode)!
    }

    /// The top of the line holding `location`, in text-view coordinates.
    private func lineTop(_ m: Mounted, at location: Int) -> CGFloat {
        let lm = m.textView.layoutManager!
        lm.ensureLayout(for: m.textView.textContainer!)
        let glyph = lm.glyphIndexForCharacter(at: location)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + m.textView.textContainerOrigin.y
    }

    private func controllerGridFrame(_ grid: FigureGridExpansion) -> CGRect? {
        grid.controller?.gridView.frame
    }
}
