import AppKit
import MaughamCore

/// What the grid draws: the table, each cell's cached display string and
/// value, and the model's selection (report plan 7c Task 4). The controller
/// (Task 5) answers from its `FigureGridValues` and `FigureGridModel`.
@MainActor
protocol FigureGridDataSource: AnyObject {
    var figureGridTable: FigureTable { get }
    /// The cell's display string, from the cache (tripwire 4: never computed per draw).
    func figureGridDisplay(at key: CellKey) -> String
    func figureGridValue(at key: CellKey) -> CellValue
    var figureGridSelection: FigureGridSelection? { get }
    /// The reference a formula is composing, drawn as a dashed box.
    var figureGridReference: FigureGridReference? { get }
}

/// What the writer asked of the grid. The view mutates nothing: the
/// controller feeds keys to its model and writes through the figure host.
@MainActor
protocol FigureGridViewDelegate: AnyObject {
    /// A key, a click on a cell, or the cell editor's text changing. Answers
    /// whether it was handled; an unhandled key in the cell editor is the
    /// editor's own (a caret move, a deletion).
    @discardableResult
    func figureGridView(_ view: FigureGridView, handle key: FigureGridKey) -> Bool
    /// A column's resize ended at `width` points (the mouse-up; the drag itself writes nothing).
    func figureGridView(_ view: FigureGridView, didResizeColumn column: ColumnID, to width: CGFloat)
}

/// **The table figure's grid** (report plan 7c Task 4, R7c-9): column
/// letters, row numbers and the visible rows only, drawn from the data
/// source's cached strings in the card's typography (`FigureCardMetrics`,
/// painted through `FigureCardDrawing`); the selection; a fixed-height
/// scrolling viewport (R7c-2); an in-cell `NSTextField` (the window's field
/// editor, never an `EditorSurface`); column resize by a drag on a letter
/// band edge. Host-agnostic: the card room mounts it in place (Task 6) and
/// plan 7d's figure window reuses it.
///
/// Geometry and what is drawn are `FigureGridLayout` and `FigureGridPlan`,
/// pure; this view feeds them and paints.
@MainActor
final class FigureGridView: NSView, NSTextFieldDelegate, NSUserInterfaceValidations {
    weak var dataSource: FigureGridDataSource?
    weak var delegate: FigureGridViewDelegate?

    let font: NSFont
    let rowHeight: CGFloat
    /// The body's scroll offset, held inside the content.
    private(set) var scrollOffset: CGPoint = .zero

    /// The cell editor; shown only while a cell is being edited.
    let cellEditor = NSTextField()
    /// The cell the editor is open on.
    private(set) var editingCell: CellKey?

    /// A resize in flight: the column (position and id) and its live width.
    private var resizing: (column: Int, id: ColumnID, width: CGFloat)?
    /// The last cell a drag extended to, so a drag reports each cell once.
    private var dragCell: CellKey?

    init(typography: TypographySettings) {
        font = FigureCardMetrics.font(for: typography)
        rowHeight = FigureCardMetrics.rowHeight(for: typography)
        super.init(frame: .zero)
        cellEditor.isBordered = false
        cellEditor.isBezeled = false
        cellEditor.focusRingType = .none
        cellEditor.drawsBackground = true
        cellEditor.backgroundColor = .textBackgroundColor
        cellEditor.font = font
        cellEditor.usesSingleLineMode = true
        cellEditor.cell?.isScrollable = true
        cellEditor.cell?.wraps = false
        cellEditor.delegate = self
        cellEditor.isHidden = true
        addSubview(cellEditor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Layout

    /// The grid's geometry now, a live resize's width laid over the table's.
    var layout: FigureGridLayout {
        let table = dataSource?.figureGridTable ?? FigureTable(rows: 0, columns: 0)
        var widths = FigureGridLayout.widths(for: table)
        if let resizing, widths.indices.contains(resizing.column) { widths[resizing.column] = resizing.width }
        return FigureGridLayout(columnWidths: widths, rowCount: table.rows.count, rowHeight: rowHeight,
                                gutterWidth: gutterWidth(rows: table.rows.count), size: bounds.size,
                                scroll: scrollOffset)
    }

    /// Wide enough for the last row's number.
    private func gutterWidth(rows: Int) -> CGFloat {
        let digits = (String(max(rows, 1)) as NSString).size(withAttributes: [.font: font]).width
        return max(rowHeight * 1.5, (digits + 2 * FigureCardDrawing.cellInset).rounded(.up))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setScroll(scrollOffset)
    }

    // MARK: Updates (from the controller)

    /// **The table's shape or the selection changed**: re-clamp the scroll,
    /// re-place the editor, redraw.
    func reloadData() {
        setScroll(scrollOffset)
        needsDisplay = true
    }

    /// Redraw what `repaint` names among the visible rows.
    func repaint(_ repaint: FigureGridValues.Repaint) {
        guard let table = dataSource?.figureGridTable else { return }
        let layout = layout
        guard let keys = repaint.keys(visibleRows: layout.visibleRows, in: table) else {
            needsDisplay = true
            return
        }
        for key in keys {
            guard let r = table.rowIndex(of: key.row), let c = table.columnIndex(of: key.column) else { continue }
            setNeedsDisplay(layout.cellFrame(row: r, column: c).intersection(bounds))
        }
    }

    /// Scroll as little as brings `key` wholly into view.
    func scrollTo(_ key: CellKey) {
        guard let table = dataSource?.figureGridTable,
              let r = table.rowIndex(of: key.row), let c = table.columnIndex(of: key.column) else { return }
        setScroll(layout.scroll(revealing: r, column: c))
    }

    private func setScroll(_ offset: CGPoint) {
        let next = layout.clamped(offset)
        if next != scrollOffset {
            scrollOffset = next
            needsDisplay = true
        }
        placeCellEditor()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: The cell editor

    /// Open the cell editor on `cell` holding `text`, caret at the end, and give it the keys.
    func beginEditing(_ cell: CellKey, text: String) {
        editingCell = cell
        cellEditor.stringValue = text
        cellEditor.alignment = .left
        cellEditor.isHidden = false
        scrollTo(cell)
        placeCellEditor()
        window?.makeFirstResponder(cellEditor)
        moveEditorCaretToEnd()
    }

    /// Replace the open editor's text (a composed reference), caret at the end.
    func setEditingText(_ text: String) {
        guard editingCell != nil else { return }
        cellEditor.stringValue = text
        moveEditorCaretToEnd()
    }

    /// Close the cell editor; the grid takes the keys back if the editor had them.
    func endEditing() {
        guard editingCell != nil else { return }
        let editorHadKeys = cellEditor.currentEditor() != nil
        editingCell = nil
        cellEditor.abortEditing()
        cellEditor.isHidden = true
        if editorHadKeys { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    private func moveEditorCaretToEnd() {
        guard let editor = cellEditor.currentEditor() else { return }
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }

    private func placeCellEditor() {
        guard let key = editingCell, let table = dataSource?.figureGridTable,
              let r = table.rowIndex(of: key.row), let c = table.columnIndex(of: key.column) else {
            return
        }
        let box = layout.cellFrame(row: r, column: c)
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        cellEditor.frame = CGRect(x: box.minX + 1, y: box.minY + (box.height - lineHeight) / 2,
                                  width: max(0, box.width - 2), height: lineHeight)
    }

    func controlTextDidChange(_ notification: Notification) {
        delegate?.figureGridView(self, handle: .editTextChanged(cellEditor.stringValue))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        guard let key = Self.gridKey(forEditorCommand: selector, shift: shift) else { return false }
        return delegate?.figureGridView(self, handle: key) ?? false
    }

    /// **The grid key a cell-editor command means**: Return, Tab, Esc and the
    /// arrows go to the model first (it may commit and move, or compose a
    /// reference); anything else is the editor's own.
    static func gridKey(forEditorCommand selector: Selector, shift: Bool) -> FigureGridKey? {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): return .returnKey(backward: shift)
        case #selector(NSResponder.insertTab(_:)): return .tab(backward: false)
        case #selector(NSResponder.insertBacktab(_:)): return .tab(backward: true)
        case #selector(NSResponder.cancelOperation(_:)): return .escape
        case #selector(NSResponder.moveUp(_:)): return .arrow(.up, extend: false)
        case #selector(NSResponder.moveDown(_:)): return .arrow(.down, extend: false)
        case #selector(NSResponder.moveLeft(_:)): return .arrow(.left, extend: false)
        case #selector(NSResponder.moveRight(_:)): return .arrow(.right, extend: false)
        case #selector(NSResponder.moveUpAndModifySelection(_:)): return .arrow(.up, extend: true)
        case #selector(NSResponder.moveDownAndModifySelection(_:)): return .arrow(.down, extend: true)
        case #selector(NSResponder.moveLeftAndModifySelection(_:)): return .arrow(.left, extend: true)
        case #selector(NSResponder.moveRightAndModifySelection(_:)): return .arrow(.right, extend: true)
        default: return nil
        }
    }

    // MARK: Keys (the grid itself has them)

    override func keyDown(with event: NSEvent) {
        guard let key = Self.gridKey(for: event) else {
            super.keyDown(with: event)
            return
        }
        delegate?.figureGridView(self, handle: key)
    }

    /// **The grid key a key-down means** while the grid (not the cell editor)
    /// has the keys; nil passes it on. ⌘⌥ arrows are the Format ▸ Table menu
    /// items' alone (R7c-10, one delivery path), so they answer nil here.
    static func gridKey(for event: NSEvent) -> FigureGridKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command), option = flags.contains(.option), control = flags.contains(.control)
        let direction: FigureGridDirection? = switch event.keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
        if let direction {
            return command || option || control ? nil : .arrow(direction, extend: shift)
        }
        // ⌘ keys are the menus' (⌘A is Edit ▸ Select All, answered by `selectAll(_:)`).
        guard !command, !control else { return nil }
        switch event.keyCode {
        case 36, 76: return .returnKey(backward: shift)
        case 48: return .tab(backward: shift)
        case 53: return .escape
        case 51: return .deleteBackward
        case 120: return .editInPlace
        default: break
        }
        guard let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0)
                  && !(0xF700...0xF8FF).contains($0.value) }) else { return nil }
        return .type(characters)
    }

    // MARK: Edit menu actions

    // The Edit menu's key equivalents travel the responder chain before any
    // `keyDown`. The grid answers each one it sits in front of, so none falls
    // through to the manuscript text the grid is mounted in: Select All and
    // Delete go to the model; cut, copy and paste are plan 7d's and are
    // disabled until then. Undo and redo stay the window's (R7c-1).

    override func selectAll(_ sender: Any?) {
        delegate?.figureGridView(self, handle: .selectAll)
    }

    @objc func delete(_ sender: Any?) {
        delegate?.figureGridView(self, handle: .deleteBackward)
    }

    @objc func cut(_ sender: Any?) {}
    @objc func copy(_ sender: Any?) {}
    @objc func paste(_ sender: Any?) {}

    /// The clipboard actions the grid swallows until plan 7d.
    static let clipboardActions: Set<Selector> = [
        #selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)),
    ]

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action else { return false }
        if Self.clipboardActions.contains(action) { return false }
        return responds(to: action)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let layout = layout
        if let column = layout.resizeBoundary(at: point),
           let id = dataSource?.figureGridTable.columns[safe: column] {
            resizing = (column, id, layout.columnWidths[column])
            return
        }
        // The open editor keeps the keys: a click may compose a reference into it.
        if editingCell == nil { window?.makeFirstResponder(self) }
        if let key = Self.headerKey(at: point, in: layout, table: dataSource?.figureGridTable) {
            delegate?.figureGridView(self, handle: key)
            return
        }
        guard let key = key(at: point, in: layout) else { return }
        dragCell = key
        if event.clickCount == 2 {
            delegate?.figureGridView(self, handle: .doubleClick(key))
        } else {
            delegate?.figureGridView(self, handle: .click(key, extend: event.modifierFlags.contains(.shift)))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let resizing {
            self.resizing?.width = layout.width(ofColumn: resizing.column, draggedTo: point.x)
            needsDisplay = true
            placeCellEditor()
            return
        }
        guard dragCell != nil, let key = key(at: point, in: layout), key != dragCell else { return }
        dragCell = key
        delegate?.figureGridView(self, handle: .click(key, extend: true))
    }

    override func mouseUp(with event: NSEvent) {
        dragCell = nil
        guard let resizing else { return }
        self.resizing = nil
        delegate?.figureGridView(self, didResizeColumn: resizing.id, to: resizing.width)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : rowHeight
        let wanted = CGPoint(x: scrollOffset.x - event.scrollingDeltaX * step,
                             y: scrollOffset.y - event.scrollingDeltaY * step)
        let before = scrollOffset
        setScroll(wanted)
        // At an edge the text around the grid scrolls on.
        if scrollOffset == before { super.scrollWheel(with: event) }
    }

    override func resetCursorRects() {
        let layout = layout
        for c in layout.visibleColumns {
            let edge = layout.letterFrame(column: c).maxX
            addCursorRect(CGRect(x: edge - FigureGridLayout.resizeSlop, y: 0,
                                 width: 2 * FigureGridLayout.resizeSlop, height: layout.bandHeight),
                          cursor: .resizeLeftRight)
        }
    }

    /// **The key a press on a column letter or a row number means**: the
    /// whole column or row. Nil off the band and gutter (and past the table).
    static func headerKey(at point: CGPoint, in layout: FigureGridLayout, table: FigureTable?) -> FigureGridKey? {
        guard let table else { return nil }
        if let c = layout.letterColumn(at: point), let id = table.columns[safe: c] { return .selectColumn(id) }
        if let r = layout.numberRow(at: point), let id = table.rows[safe: r] { return .selectRow(id) }
        return nil
    }

    private func key(at point: CGPoint, in layout: FigureGridLayout) -> CellKey? {
        guard let table = dataSource?.figureGridTable, let hit = layout.cell(at: point),
              let row = table.rows[safe: hit.row], let column = table.columns[safe: hit.column] else { return nil }
        return CellKey(row: row, column: column)
    }

    // MARK: Drawing

    /// The plan at the current scroll; asks the data source for the visible cells only.
    func currentPlan() -> FigureGridPlan? {
        guard let dataSource else { return nil }
        return FigureGridPlan.make(layout: layout, table: dataSource.figureGridTable,
                                   display: dataSource.figureGridDisplay(at:),
                                   value: dataSource.figureGridValue(at:),
                                   selection: dataSource.figureGridSelection,
                                   reference: dataSource.figureGridReference)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let plan = currentPlan() else { return }
        let layout = layout
        let body = layout.bodyRect
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)

        // The band and the gutter.
        NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: layout.bandHeight).fill()
        CGRect(x: 0, y: 0, width: layout.gutterWidth, height: bounds.height).fill()

        // The body, clipped under the band and right of the gutter.
        NSGraphicsContext.saveGraphicsState()
        body.clip()
        if let selection = plan.selection {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            selection.fill()
        }
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        for y in plan.rowLines { CGRect(x: body.minX, y: y - 0.5, width: body.width, height: 1).fill() }
        for x in plan.columnLines { CGRect(x: x - 0.5, y: body.minY, width: 1, height: body.height).fill() }
        NSColor.separatorColor.setFill()
        for y in plan.rules { CGRect(x: body.minX, y: y - 1, width: body.width, height: 2).fill() }
        for cell in plan.cells where cell.rect.intersects(dirtyRect) {
            FigureCardDrawing.drawText(cell, font: cell.bold ? bold : font, color: .labelColor, alpha: 1)
        }
        if let active = plan.active {
            NSColor.controlAccentColor.setStroke()
            let box = NSBezierPath(rect: active.insetBy(dx: 1, dy: 1))
            box.lineWidth = 2
            box.stroke()
        }
        if let reference = plan.reference {
            NSColor.systemOrange.setStroke()
            let box = NSBezierPath(rect: reference.insetBy(dx: 1, dy: 1))
            box.lineWidth = 1.5
            box.setLineDash([4, 2], count: 2, phase: 0)
            box.stroke()
        }
        if let scroller = plan.scroller {
            NSColor.secondaryLabelColor.withAlphaComponent(0.4).setFill()
            NSBezierPath(roundedRect: scroller, xRadius: 2, yRadius: 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Letters and numbers, each clipped to its strip.
        NSGraphicsContext.saveGraphicsState()
        CGRect(x: body.minX, y: 0, width: body.width, height: layout.bandHeight).clip()
        for letter in plan.letters {
            FigureCardDrawing.drawText(letter, font: font, color: .secondaryLabelColor, alpha: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        CGRect(x: 0, y: body.minY, width: layout.gutterWidth, height: body.height).clip()
        for number in plan.numbers {
            FigureCardDrawing.drawText(number, font: font, color: .secondaryLabelColor, alpha: 1)
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: layout.bandHeight - 0.5, width: bounds.width, height: 1).fill()
        CGRect(x: layout.gutterWidth - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
