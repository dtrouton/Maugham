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
            (key(7, "x"), .type("x")),
            (key(0, "a", .command), .selectAll),
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
        XCTAssertNil(FigureGridView.gridKey(for: key(8, "c", .command)), "⌘C is plan 7d's")
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
