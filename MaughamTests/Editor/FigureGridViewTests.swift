import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// The grid view mounted in a real window (report plan 7c Task 4): it draws
/// the visible rows only (tripwire 4), maps keys delivered on the real path
/// (`NSEvent.keyEvent` → `keyDown`, first responder asserted synchronously)
/// to the model's keys, and opens its cell editor as the window's field
/// editor. Clicks are the pure layout's (`FigureGridLayoutTests`), never
/// synthesised here (tripwire 33).
@MainActor
final class FigureGridViewTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // the grid draws in the production card font
    }

    /// Answers the view, recording every cell whose display it is asked for.
    private final class Source: FigureGridDataSource {
        var figureGridTable: FigureTable
        var figureGridSelection: FigureGridSelection?
        var figureGridReference: FigureGridReference?
        var askedRows = Set<Int>()
        init(table: FigureTable) { figureGridTable = table }
        func figureGridDisplay(at key: CellKey) -> String {
            let row = figureGridTable.rowIndex(of: key.row)!
            askedRows.insert(row)
            return "r\(row)"
        }
        func figureGridValue(at key: CellKey) -> CellValue { .empty }
    }

    private final class Recorder: FigureGridViewDelegate {
        var keys: [FigureGridKey] = []
        var handles = true
        func figureGridView(_ view: FigureGridView, handle key: FigureGridKey) -> Bool {
            keys.append(key)
            return handles
        }
        func figureGridView(_ view: FigureGridView, didResizeColumn column: ColumnID, to width: CGFloat) {}
        var clipboard: [FigureGridClipboardAction] = []
        var clipboardMayRun = true
        func figureGridView(_ view: FigureGridView, perform action: FigureGridClipboardAction) {
            clipboard.append(action)
        }
        func figureGridView(_ view: FigureGridView, mayPerform action: FigureGridClipboardAction) -> Bool {
            clipboardMayRun
        }
    }

    private var window: NSWindow?
    private let recorder = Recorder()
    /// The view holds its data source weakly; the suite keeps it alive.
    private var source: Source?

    /// Draw the view now, synchronously, through its own `draw(_:)` (a
    /// concealed window's `display()` may draw nothing).
    private func drawNow(_ view: NSView) {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    override func tearDown() {
        window?.close()
        window = nil
        source = nil
        super.tearDown()
    }

    private func mount(rows: Int) -> (FigureGridView, Source) {
        let source = Source(table: FigureTable(rows: rows, columns: 3))
        let grid = FigureGridView(typography: .defaults)
        grid.dataSource = source
        grid.delegate = recorder
        let height = FigureGridLayout.viewportHeight(rows: rows, rowHeight: grid.rowHeight)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: height))
        grid.frame = container.bounds
        container.addSubview(grid)
        window = TestWindow.make(KeyTestWindow.self, contentRect: container.frame, contentView: container)
        grid.reloadData()
        self.source = source
        return (grid, source)
    }

    // MARK: Drawing

    func test_aFortyRowTableDrawsOnlyTheRowsItsViewportShows() throws {
        let (grid, source) = mount(rows: 40)
        XCTAssertEqual(grid.layout.visibleRows, 0..<15, "R7c-2: fifteen rows show")
        drawNow(grid)
        XCTAssertEqual(source.askedRows, Set(0..<15), "only the visible rows' strings are read")

        source.askedRows = []
        let table = source.figureGridTable
        grid.scrollTo(CellKey(row: table.rows[30], column: table.columns[0]))
        let shown = grid.layout.visibleRows
        XCTAssertTrue(shown.contains(30))
        drawNow(grid)
        XCTAssertFalse(source.askedRows.isEmpty)
        XCTAssertTrue(source.askedRows.isSubset(of: Set(shown)), "scrolled: still the visible rows only")
        XCTAssertTrue(source.askedRows.allSatisfy { $0 >= 15 })
    }

    func test_aShortTableIsAsTallAsItsRowsAndDoesNotScroll() {
        let (grid, _) = mount(rows: 3)
        XCTAssertEqual(grid.layout.visibleRows, 0..<3)
        XCTAssertEqual(grid.layout.maxScroll.y, 0)
    }

    // MARK: Keys on the real path

    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window?.windowNumber ?? 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    func test_keysDeliveredToTheGridMapToTheModelsKeys() throws {
        let (grid, _) = mount(rows: 5)
        let window = try XCTUnwrap(self.window)
        window.makeFirstResponder(grid)
        XCTAssertTrue(window.firstResponder === grid)

        let cases: [(NSEvent, FigureGridKey)] = [
            (key(125, "\u{F701}"), .arrow(.down, extend: false)),
            (key(123, "\u{F702}", .shift), .arrow(.left, extend: true)),
            (key(48, "\t"), .tab(backward: false)),
            (key(48, "\u{19}", .shift), .tab(backward: true)),
            (key(36, "\r"), .returnKey(backward: false)),
            (key(36, "\r", .shift), .returnKey(backward: true)),
            (key(53, "\u{1b}"), .escape),
            (key(51, "\u{7f}"), .deleteBackward),
            (key(120, "\u{F705}"), .editInPlace),
            // A typing key opens an empty edit, which the cell editor then
            // reads (here the recorder opens none, so nothing is handed on).
            (key(7, "x"), .beginTyping),
            (key(117, "\u{F728}"), .deleteBackward),   // fn-⌫ clears, like ⌫ (final review C1)
            (key(51, "\u{7f}", .option), .deleteBackward),
            (key(125, "\u{F701}", .command), .jump(.down, extend: false)),
            (key(123, "\u{F702}", [.command, .shift]), .jump(.left, extend: true)),
            (key(115, "\u{F729}"), .jump(.left, extend: false)),
            (key(119, "\u{F72B}"), .jump(.right, extend: false)),
        ]
        for (event, expected) in cases {
            recorder.keys = []
            grid.keyDown(with: event)
            XCTAssertEqual(recorder.keys, [expected], "keyCode \(event.keyCode)")
        }
        XCTAssertTrue(window.firstResponder === grid, "the grid keeps the keys")
    }

    func test_commandOptionArrowsAreTheMenusAlone() {
        XCTAssertNil(FigureGridView.gridKey(for: key(125, "\u{F701}", [.command, .option])),
                     "R7c-10: one delivery path, the Format ▸ Table item")
        XCTAssertNil(FigureGridView.gridKey(for: key(8, "c", .command)), "⌘C is Edit ▸ Copy's")
        XCTAssertNil(FigureGridView.gridKey(for: key(0, "a", .command)), "⌘A is Edit ▸ Select All's")
    }

    /// **No key reaches the text the grid sits in** (final review C1): a key
    /// the grid has no meaning for is swallowed — never passed up the chain
    /// to the text view, which would edit or move its caret.
    func test_aKeyTheGridHasNoMeaningForNeverReachesTheText() throws {
        let (grid, text, window) = try mountInText(rows: 5)
        let unmeant: [NSEvent] = [
            key(51, "\u{7f}", .command),                  // ⌘⌫: delete to the line's start
            key(123, "\u{F702}", .option),                // ⌥←: a word left
            key(124, "\u{F703}", .control),
            key(40, "\u{0b}", .control),                  // ⌃K: kill to the line's end
            key(2, "\u{04}", .control),                   // ⌃D: forward delete
            key(121, "\u{F72D}"),                         // Page Down
            key(116, "\u{F72C}"),                         // Page Up
            key(122, "\u{F704}"),                         // F1
        ]
        for event in unmeant {
            recorder.keys = []
            grid.keyDown(with: event)
            XCTAssertEqual(recorder.keys, [], "keyCode \(event.keyCode) means nothing to the grid")
        }
        XCTAssertEqual(text.string, "Prose around the figure.", "the text behind the grid is untouched")
        XCTAssertEqual(text.selectedRange(), NSRange(location: 3, length: 0), "and its caret did not move")
        XCTAssertTrue(window.firstResponder === grid)
    }

    /// **The panel stops a key its bars' controls leave unhandled** (final
    /// review C1): a toolbar button focused under Full Keyboard Access
    /// passes on all but Space, and the panel sits in the text.
    func test_aKeyABarsControlLeavesNeverReachesTheText() throws {
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        text.string = "Prose around the figure."
        text.setSelectedRange(NSRange(location: 9, length: 0))
        let bars = FigureGridBars()
        let panel = FigureGridPanel(bars: bars, gridView: FigureGridView(typography: .defaults))
        panel.frame = CGRect(x: 0, y: 40, width: 500, height: 300)
        text.addSubview(panel)
        let window: KeyTestWindow = TestWindow.make(KeyTestWindow.self, contentRect: text.frame, contentView: text)
        self.window = window
        for event in [key(123, "\u{F702}", .option), key(117, "\u{F728}"), key(51, "\u{7f}"), key(7, "x")] {
            bars.sum.keyDown(with: event)
        }
        XCTAssertEqual(text.string, "Prose around the figure.", "the text behind the panel is untouched")
        XCTAssertEqual(text.selectedRange(), NSRange(location: 9, length: 0), "and its caret did not move")
    }

    /// The grid reads to VoiceOver as a table of its size whose one child is
    /// the active cell, with its address and what it shows.
    func test_accessibilityIsATableOfItsSizeWithTheActiveCell() throws {
        let (grid, source) = mount(rows: 5)
        let table = source.figureGridTable
        let b3 = CellKey(row: table.rows[2], column: table.columns[1])
        source.figureGridSelection = FigureGridSelection(anchor: b3, focus: b3)
        XCTAssertEqual(grid.accessibilityRole(), .table)
        XCTAssertEqual(grid.accessibilityRowCount(), 5)
        XCTAssertEqual(grid.accessibilityColumnCount(), 3)
        let cell = try XCTUnwrap(grid.accessibilityChildren()?.first as? NSAccessibilityElement)
        XCTAssertEqual(cell.accessibilityRole(), .cell)
        XCTAssertEqual(cell.accessibilityLabel(), "B3")
        XCTAssertEqual(cell.accessibilityValue() as? String, "r2")
        XCTAssertEqual(cell.accessibilityRowIndexRange(), NSRange(location: 2, length: 1))
        XCTAssertEqual(grid.accessibilityValue() as? String, "B3, r2")
    }

    // MARK: Edit menu actions on the real path

    /// The grid mounted inside a manuscript-like `NSTextView`, as Task 6 mounts
    /// it: the text view answers every Edit action, so each must stop at the grid.
    private func mountInText(rows: Int) throws -> (FigureGridView, NSTextView, NSWindow) {
        let source = Source(table: FigureTable(rows: rows, columns: 3))
        self.source = source
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        text.string = "Prose around the figure."
        text.setSelectedRange(NSRange(location: 3, length: 0))
        let grid = FigureGridView(typography: .defaults)
        grid.dataSource = source
        grid.delegate = recorder
        grid.frame = CGRect(x: 0, y: 40, width: 500,
                            height: FigureGridLayout.viewportHeight(rows: rows, rowHeight: grid.rowHeight))
        text.addSubview(grid)
        let window: KeyTestWindow = TestWindow.make(KeyTestWindow.self, contentRect: text.frame, contentView: text)
        self.window = window
        window.makeFirstResponder(grid)
        XCTAssertTrue(window.firstResponder === grid)
        return (grid, text, window)
    }

    /// Who an Edit menu item with a nil target reaches: the first responder
    /// and up the chain, as AppKit resolves it.
    private func menuTarget(_ action: Selector, in window: NSWindow) -> NSResponder? {
        var responder = window.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        return nil
    }

    /// The item's enabled state as the menu would validate it.
    private func isEnabled(_ action: Selector, keyEquivalent: String, in window: NSWindow) throws -> Bool {
        let target = try XCTUnwrap(menuTarget(action, in: window))
        let item = NSMenuItem(title: "", action: action, keyEquivalent: keyEquivalent)
        guard let validator = target as? NSUserInterfaceValidations else { return true }
        return validator.validateUserInterfaceItem(item)
    }

    func test_selectAllFromTheEditMenuSelectsTheTableNotTheText() throws {
        let (grid, text, window) = try mountInText(rows: 5)
        let action = #selector(NSText.selectAll(_:))
        XCTAssertTrue(menuTarget(action, in: window) === grid, "⌘A stops at the grid")
        XCTAssertTrue(try isEnabled(action, keyEquivalent: "a", in: window))
        recorder.keys = []
        XCTAssertTrue(NSApp.sendAction(action, to: menuTarget(action, in: window), from: nil))
        XCTAssertEqual(recorder.keys, [.selectAll])
        XCTAssertEqual(text.selectedRange(), NSRange(location: 3, length: 0), "the manuscript's selection is untouched")
        XCTAssertTrue(window.firstResponder === grid)
    }

    func test_deleteFromTheEditMenuClearsTheSelectionInTheModel() throws {
        let (grid, text, window) = try mountInText(rows: 5)
        let action = #selector(NSText.delete(_:))
        XCTAssertTrue(menuTarget(action, in: window) === grid)
        recorder.keys = []
        XCTAssertTrue(NSApp.sendAction(action, to: menuTarget(action, in: window), from: nil))
        XCTAssertEqual(recorder.keys, [.deleteBackward])
        XCTAssertEqual(text.string, "Prose around the figure.")
    }

    /// **Cut, copy and paste stop at the grid** (plan 7d Task 3): each is
    /// the delegate's, enabled as it says, and never reaches the text the
    /// grid sits in.
    func test_pasteCutAndCopyGoToTheDelegateAndNeverReachTheText() throws {
        let (grid, text, window) = try mountInText(rows: 5)
        let cases: [(Selector, String, FigureGridClipboardAction)] = [
            (#selector(NSText.paste(_:)), "v", .paste), (#selector(NSText.cut(_:)), "x", .cut),
            (#selector(NSText.copy(_:)), "c", .copy)]
        for (action, key, clipboard) in cases {
            XCTAssertTrue(menuTarget(action, in: window) === grid, "\(action) stops at the grid")
            recorder.clipboardMayRun = true
            XCTAssertTrue(try isEnabled(action, keyEquivalent: key, in: window), "\(action) enabled as the delegate says")
            recorder.clipboardMayRun = false
            XCTAssertFalse(try isEnabled(action, keyEquivalent: key, in: window), "\(action) disabled as the delegate says")
            recorder.clipboard = []
            XCTAssertTrue(NSApp.sendAction(action, to: menuTarget(action, in: window), from: nil))
            XCTAssertEqual(recorder.clipboard, [clipboard])
        }
        XCTAssertEqual(text.string, "Prose around the figure.", "nothing reaches the prose behind the grid")
        XCTAssertEqual(text.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertTrue(window.firstResponder === grid)
    }

    /// **⌘Z and ⇧⌘Z stop at the grid** (plan 7d Task 6): its delegate's
    /// stack, enabled and titled as the delegate says; with no delegate
    /// stack the items are off — never the window's, never the text's.
    func test_undoAndRedoGoToTheDelegate() throws {
        let (grid, _, window) = try mountInText(rows: 5)
        for action in [Selector(("undo:")), Selector(("redo:"))] {
            XCTAssertTrue(menuTarget(action, in: window) === grid, "\(action) stops at the grid")
            let item = NSMenuItem(title: "Undo", action: action, keyEquivalent: "z")
            XCTAssertFalse(grid.validateUserInterfaceItem(item), "the recorder has no stack: off")
        }
    }

    // MARK: The cell editor

    func test_theCellEditorIsTheWindowsFieldEditorOverTheCell() throws {
        let (grid, source) = mount(rows: 5)
        let window = try XCTUnwrap(self.window)
        window.makeFirstResponder(grid)
        let table = source.figureGridTable
        let cell = CellKey(row: table.rows[1], column: table.columns[2])

        grid.beginEditing(cell, text: "=A1")
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(fieldEditor.isFieldEditor, "an NSTextField's field editor, never an EditorSurface")
        XCTAssertTrue(fieldEditor.delegate === grid.cellEditor)
        XCTAssertEqual(fieldEditor.string, "=A1")
        XCTAssertEqual(fieldEditor.selectedRange(), NSRange(location: 3, length: 0), "caret at the end")
        XCTAssertTrue(grid.layout.cellFrame(row: 1, column: 2).contains(grid.cellEditor.frame))

        recorder.keys = []
        fieldEditor.insertText("+", replacementRange: fieldEditor.selectedRange())
        XCTAssertEqual(recorder.keys, [.editTextChanged("=A1+")])

        recorder.keys = []
        fieldEditor.keyDown(with: key(36, "\r"))
        XCTAssertEqual(recorder.keys, [.returnKey(backward: false)], "Return goes to the model first")

        recorder.keys = []
        recorder.handles = false
        fieldEditor.keyDown(with: key(123, "\u{F702}"))
        XCTAssertEqual(recorder.keys, [.arrow(.left, extend: false)])
        XCTAssertEqual(fieldEditor.selectedRange(), NSRange(location: 3, length: 0),
                       "an unhandled arrow is the editor's own caret move (4 → 3)")

        grid.endEditing()
        XCTAssertTrue(window.firstResponder === grid, "the grid takes the keys back")
        XCTAssertTrue(grid.cellEditor.isHidden)
        XCTAssertNil(grid.editingCell)
    }

    func test_editorCommandsMapToTheModelsKeys() {
        XCTAssertEqual(FigureGridView.gridKey(forEditorCommand: #selector(NSResponder.insertTab(_:)), shift: false),
                       .tab(backward: false))
        XCTAssertEqual(FigureGridView.gridKey(forEditorCommand: #selector(NSResponder.insertBacktab(_:)), shift: true),
                       .tab(backward: true))
        XCTAssertEqual(FigureGridView.gridKey(forEditorCommand: #selector(NSResponder.cancelOperation(_:)), shift: false),
                       .escape)
        XCTAssertEqual(FigureGridView.gridKey(
            forEditorCommand: #selector(NSResponder.moveUpAndModifySelection(_:)), shift: true), .arrow(.up, extend: true))
        XCTAssertNil(FigureGridView.gridKey(forEditorCommand: #selector(NSResponder.deleteBackward(_:)), shift: false),
                     "a deletion is the editor's own")
    }
}
