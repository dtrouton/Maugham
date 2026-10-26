import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **Format ▸ Table and the grid's right-click menu** (report plan 7c Task 9,
/// R7c-10): one order for both menus; each item enabled by the pure
/// `FigureTableMenuState` over the gate and the selection; a posted command
/// (`MaughamEvent.postFigureTableCommand`, the menu bar's one path) reaching
/// the expanded grid's controller verb through the coordinator; the window's
/// `FigureGridPresence` set at expand, at a change of what the commands may
/// do and at fold; ⌘⌥ arrows bound once, on the menu items alone. Commands
/// are posted or verbs called — no menu item is clicked (tripwire 33).
@MainActor
final class FigureGridMenuTests: FigureGridMountedTestCase {

    // MARK: - Helpers

    private func expand(_ m: Mounted) async throws -> FigureGridController {
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        return try XCTUnwrap(grid.controller)
    }

    /// The cell at `column`, `row` (both from 0) of the host's table now.
    private func cell(_ c: FigureGridController, _ column: Int, _ row: Int) -> CellKey {
        let table = c.host.state.table
        return CellKey(row: table.rows[row], column: table.columns[column])
    }

    private func select(_ c: FigureGridController, _ from: CellKey, _ to: CellKey? = nil) {
        c.handle(.click(from, extend: false))
        if let to { c.handle(.click(to, extend: true)) }
    }

    private func post(_ c: FigureGridController, _ command: FigureTableCommand) async {
        MaughamEvent.postFigureTableCommand(command)
        await c.settleWrites()
    }

    private func number(_ x: Double) -> Cell { Cell(content: .value(.number(x))) }

    // MARK: - The pure state

    /// Read-only enables nothing (the ticks still show); editable enables by
    /// the selection: with none, only the inserts and the two rows.
    func test_theStateEnablesByTheGateAndTheSelection() {
        var table = FigureTable(rows: 4, columns: 3)
        table.headerRows = 1
        let a2 = CellKey(row: table.rows[1], column: table.columns[0])
        let selection = FigureGridSelection(anchor: a2, focus: a2)

        let readOnly = FigureTableMenuState.of(table: table, selection: selection, mode: .readOnly(.reviewMode))
        for command in FigureTableMenu.commands {
            XCTAssertFalse(readOnly.isEnabled(command), "\(command) is enabled on a read-only grid")
        }
        XCTAssertTrue(readOnly.isOn(.headerRow), "the header row is still ticked")

        let none = FigureTableMenuState.of(table: table, selection: nil, mode: .editable)
        let enabledWithNone = FigureTableMenu.commands.filter(none.isEnabled)
        XCTAssertEqual(enabledWithNone, [.headerRow, .totalRow, .insertRowAbove, .insertRowBelow,
                                         .insertColumnLeft, .insertColumnRight])

        let editable = FigureTableMenuState.of(table: table, selection: selection, mode: .editable)
        for command: FigureTableCommand in [.format(.percent), .moreDecimals, .align(.right), .sum,
                                             .deleteRows, .deleteColumns, .moveRowsDown, .moveColumnsRight,
                                             .sortAscending, .sortDescending] {
            XCTAssertTrue(editable.isEnabled(command), "\(command) is disabled over a selected body cell")
        }
        XCTAssertFalse(editable.isEnabled(.moveRowsUp), "the first body row does not move above the header")
        XCTAssertFalse(editable.isEnabled(.moveColumnsLeft), "the first column has nothing to its left")
        XCTAssertTrue(editable.isOn(.format(.general)), "the active cell's format is ticked")
        XCTAssertFalse(editable.isOn(.format(.percent)))
    }

    /// The header and total rows stay put: a selection touching one neither
    /// moves nor deletes rows; the last body row does not move down past the
    /// total; nothing deletes every row or every column.
    func test_rowsMoveAndDeleteInsideTheBodyOnly() {
        var table = FigureTable(rows: 5, columns: 3)
        table.headerRows = 1
        table.hasTotalRow = true
        func state(_ r0: Int, _ c0: Int, _ r1: Int, _ c1: Int) -> FigureTableMenuState {
            .of(table: table, selection: FigureGridSelection(
                anchor: CellKey(row: table.rows[r0], column: table.columns[c0]),
                focus: CellKey(row: table.rows[r1], column: table.columns[c1])), mode: .editable)
        }
        let header = state(0, 0, 0, 0)
        XCTAssertFalse(header.isEnabled(.moveRowsDown))
        XCTAssertFalse(header.isEnabled(.deleteRows), "the header row goes by switching Header Row off")
        XCTAssertFalse(state(0, 0, 1, 0).isEnabled(.deleteRows), "a selection reaching into the header")
        let total = state(4, 0, 4, 0)
        XCTAssertFalse(total.isEnabled(.moveRowsUp))
        XCTAssertFalse(total.isEnabled(.deleteRows), "the total row goes by switching Total Row off")
        let lastBody = state(3, 1, 3, 1)
        XCTAssertTrue(lastBody.isEnabled(.moveRowsUp))
        XCTAssertFalse(lastBody.isEnabled(.moveRowsDown), "never below the total row")
        XCTAssertTrue(lastBody.isEnabled(.moveColumnsLeft))
        XCTAssertTrue(lastBody.isEnabled(.moveColumnsRight))
        XCTAssertTrue(state(1, 0, 3, 1).isEnabled(.deleteRows), "the whole body")
        XCTAssertFalse(state(1, 0, 3, 2).isEnabled(.deleteColumns), "every column")
        XCTAssertFalse(state(3, 2, 3, 2).isEnabled(.moveColumnsRight), "the last column")

        let plain = FigureTable(rows: 2, columns: 1)
        let everything = FigureTableMenuState.of(table: plain, selection: FigureGridSelection(
            anchor: CellKey(row: plain.rows[0], column: plain.columns[0]),
            focus: CellKey(row: plain.rows[1], column: plain.columns[0])), mode: .editable)
        XCTAssertFalse(everything.isEnabled(.deleteRows), "every row")
        XCTAssertFalse(everything.isEnabled(.deleteColumns), "the only column")
    }

    // MARK: - The order

    /// **Format ▸ Table's order, pinned** — and the right-click menu is built
    /// from it, section for section, the number formats a submenu.
    func test_theMenusOrderIsPinned_andTheRightClickMenuFollowsIt() {
        let formats = FigureGridFormatChoice.allCases.map { FigureTableCommand.format($0) }
        XCTAssertEqual(FigureTableMenu.commands, formats + [
            .fewerDecimals, .moreDecimals,
            .align(.left), .align(.center), .align(.right),
            .headerRow, .totalRow, .sum,
            .insertRowAbove, .insertRowBelow, .insertColumnLeft, .insertColumnRight,
            .deleteRows, .deleteColumns,
            .moveRowsUp, .moveRowsDown, .moveColumnsLeft, .moveColumnsRight,
            .sortAscending, .sortDescending,
        ])

        var recorded: [FigureTableCommand] = []
        let target = FigureTableMenuTarget()
        target.onCommand = { recorded.append($0) }
        let menu = FigureTableMenu.contextMenu(state: FigureTableMenuState(), target: target)
        var titles: [String] = []
        for item in menu.items {
            if item.isSeparatorItem {
                titles.append("—")
            } else if let submenu = item.submenu {
                titles.append(item.title)
                for sub in submenu.items { target.perform(sub) }
            } else {
                titles.append(item.title)
                XCTAssertTrue(item.keyEquivalent.isEmpty, "\(item.title) carries a key: the menu bar's items are its path")
                target.perform(item)
            }
        }
        let expected = FigureTableMenu.sections.map { section in
            section.map { entry -> String in
                switch entry {
                case .numberFormats: FigureTableMenu.numberFormatTitle
                case .command(let command): command.title
                }
            }
        }.joined(separator: ["—"])
        XCTAssertEqual(titles, Array(expected))
        XCTAssertEqual(recorded, FigureTableMenu.commands, "each item carries its own command")
    }

    // MARK: - Posted commands reach the controller

    /// Each Format ▸ Table command, posted to the key window as its item
    /// posts it, reaches the expanded grid's controller and writes through
    /// the figure host.
    func test_postedCommandsReachTheControllersVerbs() async throws {
        let m = try await mount(rows: 4)
        let c = try await expand(m)
        let (r, k) = (c.host.state.table.rows, c.host.state.table.columns)

        select(c, cell(c, 0, 0))
        await post(c, .insertRowBelow)
        XCTAssertEqual(c.host.state.table.rows.count, 5, "Insert Row Below")
        XCTAssertEqual(c.host.state.table.rows[0], r[0])
        await post(c, .insertColumnRight)
        XCTAssertEqual(c.host.state.table.columns.count, 4, "Insert Column Right")
        XCTAssertEqual(c.host.state.table.columns[0], k[0])

        select(c, cell(c, 0, 1), cell(c, 2, 1))
        await post(c, .deleteRows)
        XCTAssertEqual(c.host.state.table.rows, r, "Delete Row took the inserted row")
        select(c, cell(c, 1, 0))
        await post(c, .deleteColumns)
        XCTAssertEqual(c.host.state.table.columns, k, "Delete Column took the inserted column")

        select(c, CellKey(row: r[0], column: k[1]))
        await post(c, .moveRowsDown)
        XCTAssertEqual(c.host.state.table.rows, [r[1], r[0], r[2], r[3]], "Move Row Down")
        XCTAssertEqual(c.model.selection?.anchor, CellKey(row: r[0], column: k[1]), "the selection rides its row")
        await post(c, .moveRowsUp)
        XCTAssertEqual(c.host.state.table.rows, r, "Move Row Up")
        await post(c, .moveColumnsLeft)
        XCTAssertEqual(c.host.state.table.columns, [k[1], k[0], k[2]], "Move Column Left")
        await post(c, .moveColumnsRight)
        XCTAssertEqual(c.host.state.table.columns, k, "Move Column Right")

        await post(c, .headerRow)
        XCTAssertEqual(c.host.state.table.headerRows, 1, "Header Row on")
        await post(c, .totalRow)
        XCTAssertTrue(c.host.state.table.hasTotalRow, "Total Row on")
        await post(c, .totalRow)
        XCTAssertFalse(c.host.state.table.hasTotalRow, "Total Row off")

        select(c, cell(c, 1, 1))
        await post(c, .format(.percent))
        XCTAssertEqual(c.host.state.table[cell(c, 1, 1)]?.format.number, .percent(decimals: 0), "Number Format")
        await post(c, .moreDecimals)
        XCTAssertEqual(c.host.state.table[cell(c, 1, 1)]?.format.number, .percent(decimals: 1), "More Decimal Places")
        await post(c, .align(.right))
        XCTAssertEqual(c.host.state.table[cell(c, 1, 1)]?.alignment, .right, "Align Right")
    }

    /// **Sort by the active cell's column**, the header row left in place,
    /// one ⌘Z.
    func test_aPostedSortOrdersTheBodyByTheActiveCellsColumn() async throws {
        let m = try await mount(rows: 4)
        let c = try await expand(m)
        try await c.host.setHeaderRows(1)
        let r = c.host.state.table.rows
        for (i, x) in [3.0, 1.0, 2.0].enumerated() {
            try await c.host.setCell(number(x), at: CellKey(row: r[i + 1], column: c.host.state.table.columns[1]))
        }
        await c.settleWrites()
        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.removeAllActions()

        select(c, cell(c, 1, 2))
        await post(c, .sortAscending)
        XCTAssertEqual(c.host.state.table.rows, [r[0], r[2], r[3], r[1]], "ascending, header kept")
        await post(c, .sortDescending)
        XCTAssertEqual(c.host.state.table.rows, [r[0], r[1], r[3], r[2]], "descending")
        XCTAssertEqual(undo.undoActionName, "Sort Descending")
    }

    /// A delete, a move or a sort commits the open edit first; one that will
    /// not read keeps the grid as it is, its edit open (R7c-8).
    func test_anOpenEditIsCommittedBeforeAMove_andAnUnreadableOneStopsIt() async throws {
        let m = try await mount(rows: 4)
        let c = try await expand(m)
        let r = c.host.state.table.rows
        let b2 = cell(c, 1, 1)
        select(c, b2)
        c.handle(.type("7"))
        await post(c, .moveRowsDown)
        XCTAssertEqual(c.host.state.table[b2]?.content, .value(.number(7)), "the typing was committed")
        XCTAssertEqual(c.host.state.table.rows, [r[0], r[2], r[1], r[3]], "then the row moved")

        c.handle(.type("=SUM("))
        await post(c, .moveRowsDown)
        XCTAssertEqual(c.host.state.table.rows, [r[0], r[2], r[1], r[3]], "an unreadable edit stops the move")
        if case .idle = c.model.edit { XCTFail("the unreadable edit is still open") }
    }

    /// A read-only grid takes no posted command, and with no grid expanded a
    /// post does nothing.
    func test_aReadOnlyGridTakesNoCommand_andNoGridNone() async throws {
        let m = try await mount(rows: 4)
        MaughamEvent.postFigureTableCommand(.insertRowBelow)   // nothing expanded
        m.coordinator.setReviewMode(true)
        m.coordinator.setManualReviewMode(true)
        let c = try await expand(m)
        let before = c.host.state.table
        for command: FigureTableCommand in [.insertRowBelow, .deleteRows, .moveRowsDown, .headerRow,
                                             .sortAscending, .format(.currency)] {
            await post(c, command)
        }
        XCTAssertEqual(c.host.state.table, before, "a read-only grid wrote nothing")
        XCTAssertEqual(c.bars.reasonMessage, FigureGridGate.Reason.reviewMode.sentence,
                       "the reason line is said")
    }

    // MARK: - The presence

    /// **Set one-way by the coordinator**: at expand (the Insert menu stands
    /// down at once), at mount, at a change of what the commands may do —
    /// not at every arrow — and at fold.
    func test_thePresenceFollowsExpandWhatTheCommandsMayDoAndFold() async throws {
        let presence = FigureGridPresence()
        let m = try await mount(rows: 4, presence: presence)
        XCTAssertFalse(presence.holdsTheKeys)
        XCTAssertNil(presence.menu)

        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        XCTAssertTrue(presence.holdsTheKeys, "expanded: the grid has the keys before the visit opens")
        let grid = try await opened(m)
        let c = try XCTUnwrap(grid.controller)
        XCTAssertEqual(presence.menu, c.menuState)
        XCTAssertEqual(presence.menu?.mayEdit, true)

        select(c, cell(c, 0, 1))
        // Set by the observation, on the main actor, before the arrow returns.
        nonisolated(unsafe) var changed = false
        withObservationTracking { _ = presence.menu } onChange: { changed = true }
        c.handle(.arrow(.down, extend: false))   // A2 → A3: the same commands
        XCTAssertFalse(changed, "an arrow that changes nothing the menu offers writes nothing")
        c.handle(.arrow(.down, extend: false))   // A3 → A4: the last row
        XCTAssertTrue(changed)
        XCTAssertEqual(presence.menu?.canMoveDown, false)

        m.coordinator.setReviewMode(true)
        m.coordinator.setManualReviewMode(true)
        XCTAssertEqual(presence.menu?.mayEdit, false, "read-only reaches the menu")

        m.coordinator.foldFigureGrid(commit: true)
        XCTAssertFalse(presence.holdsTheKeys, "folded: the Insert menu is back")
        XCTAssertNil(presence.menu)
    }

    /// The Insert menu's gate reads the presence (the rule is
    /// `InsertMenuGate`, pinned in `InsertCommandTests`; here, the window's
    /// one call passes it), and the presence is handed through `EditorHost`
    /// to the grid opening, never read there.
    func test_theWindowGatesTheInsertMenuOnThePresence() throws {
        let window = try SourceTree.read("Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains("gridHoldsTheKeys: figureGridPresence.holdsTheKeys"))
        XCTAssertTrue(window.contains(".modifier(FigureTableMenuModifier(presence: figureGridPresence))"))
        let host = try SourceTree.read("Maugham/Views/EditorHost.swift")
        XCTAssertTrue(host.contains("presence: figureGridPresence)"))
        XCTAssertFalse(host.contains("figureGridPresence?."), "EditorHost reads the presence (tripwire 6)")
        XCTAssertFalse(host.contains("figureGridPresence."), "EditorHost reads the presence (tripwire 6)")
    }

    // MARK: - The right-click menu

    /// A right-click outside the selection selects its cell first; the items
    /// are enabled by the gate and the selection, the rows ticked.
    func test_theRightClickMenuSelectsItsCellAndIsValidatedByTheGate() async throws {
        let m = try await mount(rows: 4)
        let c = try await expand(m)
        try await c.host.setHeaderRows(1)
        await c.settleWrites()
        let b3 = cell(c, 1, 2)
        let menu = try XCTUnwrap(c.figureGridView(c.gridView, menuAt: b3))
        XCTAssertEqual(c.model.selection?.anchor, b3, "the right-clicked cell is selected")
        func item(_ command: FigureTableCommand) -> NSMenuItem? {
            menu.items.first { $0.title == command.title }
        }
        XCTAssertEqual(item(.headerRow)?.state, .on)
        XCTAssertEqual(item(.totalRow)?.state, .off)
        XCTAssertEqual(item(.moveRowsUp)?.isEnabled, true)
        XCTAssertEqual(item(.moveColumnsLeft)?.isEnabled, true)
        XCTAssertTrue((item(.sum)?.target as? FigureTableMenuTarget)?.onCommand != nil,
                      "the items reach the controller")

        m.coordinator.setReviewMode(true)
        m.coordinator.setManualReviewMode(true)
        let readOnly = c.contextMenu(at: b3)
        XCTAssertTrue(readOnly.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled },
                      "a read-only grid's menu enables nothing")
    }

    // MARK: - The keys

    /// ⌘⌥↑↓←→ are bound once, on Format ▸ Table's items, listed in the
    /// cheatsheet — and the grid's own `keyDown` passes them on (one path).
    func test_theTableShortcutsAreBoundOnceListed_andNotTheGridsOwnKeys() throws {
        let app = try SourceTree.read("Maugham/MaughamApp.swift")
        let tokens = DocSyncTests.extractShortcutBindings(from: app).map(\.token)
        let cheatsheet = KeyboardShortcuts.all.flatMap(\.items).map(\.shortcut)
        for token in ["⌘⌥↑", "⌘⌥↓", "⌘⌥←", "⌘⌥→"] {
            XCTAssertEqual(tokens.filter { $0 == token }.count, 1, "\(token) is not bound once")
            XCTAssertTrue(cheatsheet.contains(token), "\(token) is missing from the ⌘/ cheatsheet")
        }
        for (code, glyph) in [(UInt16(126), "\u{F700}"), (125, "\u{F701}"), (123, "\u{F702}"), (124, "\u{F703}")] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: 0, context: nil, characters: glyph, charactersIgnoringModifiers: glyph,
                isARepeat: false, keyCode: code))
            XCTAssertNil(FigureGridView.gridKey(for: event), "the grid answers ⌘⌥ key \(code) itself")
        }
    }
}
