import AppKit
import Observation
import MaughamCore

// MARK: - The table commands (report plan 7c Task 9, R7c-10)
//
// Format ▸ Table in the menu bar and the grid's right-click menu carry the
// same commands in the same order (`FigureTableMenu.sections`), each enabled
// by one pure answer (`FigureTableMenuState`) over the grid's table, its
// selection and its gate. The menu bar's items post one key-window event
// (`MaughamEvent.postFigureTableCommand`) that the window's editor routes to
// the expanded grid's controller; the right-click menu calls the controller
// directly. ⌘⌥↑↓←→ and ⌘D (Fill Down) are bound on the menu-bar items only —
// the grid's own `keyDown` answers nil for them — so each has one delivery
// path. ⌘R is Fill Right only while the grid has the keys (R7d-1): the grid
// claims it in `performKeyEquivalent`, which AppKit asks before the menu bar
// (`FigureGridView.performKeyEquivalent`), so the File menu's ⌘R (Check
// Writing) is the one binding of the chord and Fill Right's menu item carries
// no key glyph.

/// **One table command** — what a menu item asks the expanded grid to do.
enum FigureTableCommand: Hashable {
    case format(FigureGridFormatChoice)
    case fewerDecimals, moreDecimals
    case align(CellAlignment)
    case headerRow, totalRow
    case sum
    case insertRowAbove, insertRowBelow, insertColumnLeft, insertColumnRight
    case deleteRows, deleteColumns
    case moveRowsUp, moveRowsDown, moveColumnsLeft, moveColumnsRight
    case sortAscending, sortDescending
    case fillDown, fillRight
    case importCSV

    var title: String {
        switch self {
        case .format(let choice): choice.title
        case .fewerDecimals: "Fewer Decimal Places"
        case .moreDecimals: "More Decimal Places"
        case .align(let alignment):
            switch alignment {
            case .left: "Align Left"
            case .center: "Align Centre"
            case .right: "Align Right"
            case .automatic: "Align Automatically"
            }
        case .headerRow: "Header Row"
        case .totalRow: "Total Row"
        case .sum: "Sum Column Above"
        case .insertRowAbove: "Insert Row Above"
        case .insertRowBelow: "Insert Row Below"
        case .insertColumnLeft: "Insert Column Left"
        case .insertColumnRight: "Insert Column Right"
        case .deleteRows: "Delete Row"
        case .deleteColumns: "Delete Column"
        case .moveRowsUp: "Move Row Up"
        case .moveRowsDown: "Move Row Down"
        case .moveColumnsLeft: "Move Column Left"
        case .moveColumnsRight: "Move Column Right"
        case .sortAscending: "Sort Ascending by Column"
        case .sortDescending: "Sort Descending by Column"
        case .fillDown: "Fill Down"
        case .fillRight: "Fill Right"
        case .importCSV: "Import from CSV\u{2026}"
        }
    }
}

/// **The menus' one order** — Format ▸ Table and the right-click menu are
/// both built from it, so they cannot drift (`FigureGridMenuTests` pins it).
enum FigureTableMenu {
    enum Entry: Hashable {
        case command(FigureTableCommand)
        /// "Number Format ▸" and its choices.
        case numberFormats
    }

    static let numberFormatTitle = "Number Format"

    static let sections: [[Entry]] = [
        [.numberFormats, .command(.fewerDecimals), .command(.moreDecimals)],
        [.command(.align(.left)), .command(.align(.center)), .command(.align(.right))],
        [.command(.headerRow), .command(.totalRow), .command(.sum)],
        [.command(.fillDown), .command(.fillRight)],
        [.command(.insertRowAbove), .command(.insertRowBelow),
         .command(.insertColumnLeft), .command(.insertColumnRight),
         .command(.deleteRows), .command(.deleteColumns)],
        [.command(.moveRowsUp), .command(.moveRowsDown),
         .command(.moveColumnsLeft), .command(.moveColumnsRight)],
        [.command(.sortAscending), .command(.sortDescending)],
        [.command(.importCSV)],
    ]

    /// Every command the menus carry, in order (the number formats in place).
    static var commands: [FigureTableCommand] {
        sections.flatMap { section in
            section.flatMap { entry -> [FigureTableCommand] in
                switch entry {
                case .command(let command): [command]
                case .numberFormats: FigureGridFormatChoice.allCases.map { .format($0) }
                }
            }
        }
    }

    /// **The right-click menu**, from the same sections, each item enabled
    /// and ticked by `state`; a chosen item calls `perform`. No key
    /// equivalents: the menu bar's items are the keys' one path.
    @MainActor
    static func contextMenu(state: FigureTableMenuState, target: FigureTableMenuTarget) -> NSMenu {
        let menu = NSMenu(title: "Table")
        menu.autoenablesItems = false
        func item(_ command: FigureTableCommand) -> NSMenuItem {
            let item = NSMenuItem(title: command.title, action: #selector(FigureTableMenuTarget.perform(_:)),
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = FigureTableMenuTarget.Box(command)
            item.isEnabled = state.isEnabled(command)
            item.state = state.isOn(command) ? .on : .off
            return item
        }
        for (i, section) in sections.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for entry in section {
                switch entry {
                case .command(let command): menu.addItem(item(command))
                case .numberFormats:
                    let formats = NSMenu(title: numberFormatTitle)
                    formats.autoenablesItems = false
                    for choice in FigureGridFormatChoice.allCases { formats.addItem(item(.format(choice))) }
                    let parent = NSMenuItem(title: numberFormatTitle, action: nil, keyEquivalent: "")
                    parent.submenu = formats
                    parent.isEnabled = state.isEnabled(.format(.general))
                    menu.addItem(parent)
                }
            }
        }
        return menu
    }
}

/// The right-click menu's target (an `NSMenuItem` holds its target weakly,
/// so the controller holds this).
@MainActor
final class FigureTableMenuTarget: NSObject {
    final class Box: NSObject {
        let command: FigureTableCommand
        init(_ command: FigureTableCommand) { self.command = command }
    }

    var onCommand: ((FigureTableCommand) -> Void)?

    @objc func perform(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? Box else { return }
        onCommand?(box.command)
    }
}

/// **Which table commands may run now** — pure, over the grid's table, its
/// selection and the gate's mode (`FigureGridGate`), so each row of the
/// rule is pinned without a window. A read-only grid enables nothing.
///
/// - The header and total rows stay put: a row is moved or deleted only
///   inside the body (switch Header Row or Total Row off to remove one), and
///   a sort reorders the body alone (R7c-7).
/// - Nothing deletes the last row or the last column.
struct FigureTableMenuState: Equatable {
    var mayEdit = false
    var hasSelection = false
    var header = false
    var total = false
    var canSort = false
    var canDeleteRows = false
    var canDeleteColumns = false
    var canMoveUp = false
    var canMoveDown = false
    var canMoveLeft = false
    var canMoveRight = false
    /// The active cell's format, ticked in Number Format.
    var format: FigureGridFormatChoice?

    static func of(table: FigureTable, selection: FigureGridSelection?, mode: FigureGridGate.Mode) -> Self {
        var state = Self()
        state.mayEdit = mode == .editable
        state.header = table.headerRows > 0
        state.total = table.hasTotalRow
        guard state.mayEdit else { return state }
        let rows = table.rows.count, columns = table.columns.count
        let bodyStart = min(table.headerRows, rows)
        let bodyEnd = rows - (table.hasTotalRow && rows > bodyStart ? 1 : 0)
        state.canSort = bodyEnd - bodyStart > 1
        guard let selection,
              let ar = table.rowIndex(of: selection.anchor.row), let fr = table.rowIndex(of: selection.focus.row),
              let ac = table.columnIndex(of: selection.anchor.column),
              let fc = table.columnIndex(of: selection.focus.column) else { return state }
        let (r0, r1, c0, c1) = (min(ar, fr), max(ar, fr), min(ac, fc), max(ac, fc))
        let inBody = r0 >= bodyStart && r1 < bodyEnd
        state.hasSelection = true
        state.format = FigureGridFormatChoice.choice(of: table[selection.anchor]?.format.number ?? .general)
        state.canDeleteRows = inBody && r1 - r0 + 1 < rows
        state.canDeleteColumns = c1 - c0 + 1 < columns
        state.canMoveUp = inBody && r0 > bodyStart
        state.canMoveDown = inBody && r1 < bodyEnd - 1
        state.canMoveLeft = c0 > 0
        state.canMoveRight = c1 < columns - 1
        return state
    }

    func isEnabled(_ command: FigureTableCommand) -> Bool {
        guard mayEdit else { return false }
        switch command {
        case .format, .fewerDecimals, .moreDecimals, .align, .sum, .fillDown, .fillRight: return hasSelection
        case .headerRow, .totalRow, .insertRowAbove, .insertRowBelow, .insertColumnLeft, .insertColumnRight,
             .importCSV:
            return true
        case .deleteRows: return canDeleteRows
        case .deleteColumns: return canDeleteColumns
        case .moveRowsUp: return canMoveUp
        case .moveRowsDown: return canMoveDown
        case .moveColumnsLeft: return canMoveLeft
        case .moveColumnsRight: return canMoveRight
        case .sortAscending, .sortDescending: return canSort && hasSelection
        }
    }

    /// Ticked: the header and total rows when on, the active cell's format.
    func isOn(_ command: FigureTableCommand) -> Bool {
        switch command {
        case .headerRow: return header
        case .totalRow: return total
        case .format(let choice): return hasSelection && choice == format
        default: return false
        }
    }
}

/// **Whether this window's editor has a table grid expanded, and what its
/// menu may do** (R7c-10) — window-scoped, owned by `ProjectWindow`, set
/// one-way by the editor's coordinator at expand, at fold and when what the
/// commands may do changes (a selection's kind, the table, the gate); never
/// on `EditorHost` (tripwire 6). Format ▸ Table reads `menu` through
/// `focusedSceneValue`; the Insert menu reads `holdsTheKeys`
/// (`InsertMenuGate`), so each reads only the property it needs.
@MainActor
@Observable
final class FigureGridPresence {
    /// A grid is expanded (opening or open): it has the keys, not the text.
    private(set) var holdsTheKeys = false
    /// What Format ▸ Table may do; nil before the grid has opened and after it folds.
    private(set) var menu: FigureTableMenuState?

    func expanded() {
        if !holdsTheKeys { holdsTheKeys = true }
    }

    func show(_ state: FigureTableMenuState) {
        if menu != state { menu = state }
    }

    func folded() {
        if holdsTheKeys { holdsTheKeys = false }
        if menu != nil { menu = nil }
    }
}

extension MaughamEvent {
    static let figureTableCommandKey = "maugham.figureTable.command"

    /// **The one spelling of a Format ▸ Table post**: the key window's
    /// manuscript editor routes `command` to its expanded grid.
    static func postFigureTableCommand(_ command: FigureTableCommand) {
        post(.maughamFigureTableCommand, to: .keyWindow, payload: [figureTableCommandKey: command])
    }
}
