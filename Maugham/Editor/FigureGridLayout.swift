import AppKit
import MaughamCore

// **The in-place grid's geometry and drawing plan** (report plan 7c Task 4,
// R7c-9). Pure: positions, widths and a scroll offset in, rectangles and
// strings out, so where a click lands, which rows are drawn and what each
// shows are asserted as values. `FigureGridView` only feeds it and paints.
//
// The view is flipped. Its top band holds the column letters and its left
// gutter the row numbers; both stay put while the body scrolls under them
// (the band scrolls sideways with the columns, the gutter up and down with
// the rows). Rows and columns are counted by live position here; the view
// maps them to ids.

struct FigureGridLayout: Equatable {
    /// **R7c-2: the viewport shows at most this many rows** and scrolls past it.
    static let maxVisibleRows = 15
    /// A column's width when the table holds none for it.
    static let defaultColumnWidth: CGFloat = 96
    /// The narrowest a drag may make a column.
    static let minColumnWidth: CGFloat = 24
    /// How far either side of a column's right edge, in the letter band, a
    /// press starts a resize.
    static let resizeSlop: CGFloat = 3

    /// Every live column's width, left to right.
    var columnWidths: [CGFloat]
    var rowCount: Int
    var rowHeight: CGFloat
    /// The row-number gutter's width.
    var gutterWidth: CGFloat
    /// The view's size.
    var size: CGSize
    /// How far the body has scrolled, clamped by `clamped(_:)`.
    var scroll: CGPoint = .zero

    /// The letter band is one row tall.
    var bandHeight: CGFloat { rowHeight }

    /// **The viewport's height for a table of `rows` rows** (R7c-2): the
    /// letter band plus min(rows, 15) rows. The bars around it are Task 6's.
    static func viewportHeight(rows: Int, rowHeight: CGFloat) -> CGFloat {
        rowHeight + CGFloat(min(max(rows, 0), maxVisibleRows)) * rowHeight
    }

    /// The width each live column draws at: the table's own (points) or the default.
    static func widths(for table: FigureTable) -> [CGFloat] {
        table.columns.map { id in table.columnWidths[id].map { max(minColumnWidth, CGFloat($0)) } ?? defaultColumnWidth }
    }

    // MARK: Extents

    var contentWidth: CGFloat { columnWidths.reduce(0, +) }
    var contentHeight: CGFloat { CGFloat(rowCount) * rowHeight }
    /// The body's on-screen box (right of the gutter, under the band).
    var bodyRect: CGRect {
        CGRect(x: gutterWidth, y: bandHeight,
               width: max(0, size.width - gutterWidth), height: max(0, size.height - bandHeight))
    }
    var maxScroll: CGPoint {
        CGPoint(x: max(0, contentWidth - bodyRect.width), y: max(0, contentHeight - bodyRect.height))
    }

    /// `offset` held inside the content.
    func clamped(_ offset: CGPoint) -> CGPoint {
        let limit = maxScroll
        return CGPoint(x: min(max(0, offset.x), limit.x), y: min(max(0, offset.y), limit.y))
    }

    /// The left edge of column `c`, in content space.
    func columnX(_ c: Int) -> CGFloat { columnWidths.prefix(max(0, c)).reduce(0, +) }

    // MARK: Visible range

    /// **The rows the body shows at the current scroll**, partly shown ones included.
    var visibleRows: Range<Int> {
        guard rowCount > 0, rowHeight > 0, bodyRect.height > 0 else { return 0..<0 }
        let first = Int((scroll.y / rowHeight).rounded(.down))
        let last = Int(((scroll.y + bodyRect.height) / rowHeight).rounded(.up))
        let lower = min(max(0, first), rowCount), upper = min(max(lower, last), rowCount)
        return lower..<upper
    }

    /// The columns the body shows at the current scroll, partly shown ones included.
    var visibleColumns: Range<Int> {
        guard !columnWidths.isEmpty, bodyRect.width > 0 else { return 0..<0 }
        let left = scroll.x, right = scroll.x + bodyRect.width
        var x: CGFloat = 0, lower: Int?, upper = 0
        for (i, w) in columnWidths.enumerated() {
            if x + w > left, x < right { lower = lower ?? i; upper = i + 1 }
            x += w
        }
        guard let lower else { return 0..<0 }
        return lower..<upper
    }

    // MARK: Frames (view space)

    /// Cell (row, column)'s box in the view, wherever it is scrolled to.
    func cellFrame(row: Int, column: Int) -> CGRect {
        let w = columnWidths.indices.contains(column) ? columnWidths[column] : 0
        return CGRect(x: gutterWidth + columnX(column) - scroll.x,
                      y: bandHeight + CGFloat(row) * rowHeight - scroll.y,
                      width: w, height: rowHeight)
    }

    /// The box spanning two cells' rectangle, whichever corners.
    func rangeFrame(_ a: (row: Int, column: Int), _ b: (row: Int, column: Int)) -> CGRect {
        cellFrame(row: min(a.row, b.row), column: min(a.column, b.column))
            .union(cellFrame(row: max(a.row, b.row), column: max(a.column, b.column)))
    }

    /// Column `c`'s letter box in the band.
    func letterFrame(column c: Int) -> CGRect {
        let cell = cellFrame(row: 0, column: c)
        return CGRect(x: cell.minX, y: 0, width: cell.width, height: bandHeight)
    }

    /// Row `r`'s number box in the gutter.
    func numberFrame(row r: Int) -> CGRect {
        let cell = cellFrame(row: r, column: 0)
        return CGRect(x: 0, y: cell.minY, width: gutterWidth, height: rowHeight)
    }

    // MARK: Hits

    /// **The cell under `point`**, or nil in the band, the gutter or past the last row or column.
    func cell(at point: CGPoint) -> (row: Int, column: Int)? {
        guard bodyRect.contains(point), rowHeight > 0 else { return nil }
        let y = point.y - bandHeight + scroll.y
        let row = Int((y / rowHeight).rounded(.down))
        guard row >= 0, row < rowCount else { return nil }
        return column(atContentX: point.x - gutterWidth + scroll.x).map { (row, $0) }
    }

    /// **The column whose letter is under `point`** (the band, right of the
    /// gutter), or nil. A resize edge is asked first (`resizeBoundary`).
    func letterColumn(at point: CGPoint) -> Int? {
        guard point.y >= 0, point.y < bandHeight, point.x >= gutterWidth, point.x < size.width else { return nil }
        return column(atContentX: point.x - gutterWidth + scroll.x)
    }

    /// **The row whose number is under `point`** (the gutter, under the band), or nil.
    func numberRow(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.x < gutterWidth, point.y >= bandHeight, point.y < size.height, rowHeight > 0
        else { return nil }
        let row = Int(((point.y - bandHeight + scroll.y) / rowHeight).rounded(.down))
        return row >= 0 && row < rowCount ? row : nil
    }

    private func column(atContentX x: CGFloat) -> Int? {
        var left: CGFloat = 0
        for (i, w) in columnWidths.enumerated() {
            if x >= left, x < left + w { return i }
            left += w
        }
        return nil
    }

    /// **The column whose right edge `point` is resizing**: a press in the
    /// letter band within `resizeSlop` of a column's right edge. The nearest
    /// edge wins; nil elsewhere.
    func resizeBoundary(at point: CGPoint) -> Int? {
        guard point.y >= 0, point.y < bandHeight, point.x >= gutterWidth, point.x < size.width else { return nil }
        var best: (column: Int, distance: CGFloat)?
        for c in visibleColumns {
            let distance = abs(point.x - (gutterWidth + columnX(c + 1) - scroll.x))
            if distance <= Self.resizeSlop, distance < (best?.distance ?? .infinity) { best = (c, distance) }
        }
        return best?.column
    }

    /// The width column `c` takes when its right edge is dragged to `x` (view space).
    func width(ofColumn c: Int, draggedTo x: CGFloat) -> CGFloat {
        max(Self.minColumnWidth, (x - (gutterWidth + columnX(c) - scroll.x)).rounded())
    }

    /// **The scroll that brings cell (row, column) wholly into view**, moving
    /// as little as it can (the cell's top-left wins when it cannot fit).
    func scroll(revealing row: Int, column: Int) -> CGPoint {
        var next = scroll
        let top = CGFloat(row) * rowHeight, bottom = top + rowHeight
        if bottom > next.y + bodyRect.height { next.y = bottom - bodyRect.height }
        if top < next.y { next.y = top }
        if columnWidths.indices.contains(column) {
            let left = columnX(column), right = left + columnWidths[column]
            if right > next.x + bodyRect.width { next.x = right - bodyRect.width }
            if left < next.x { next.x = left }
        }
        return clamped(next)
    }
}

// MARK: - The drawing plan

/// **What the grid draws at one scroll**, as values (tripwire 4: the visible
/// rows only, their strings read from the cache the data source keeps).
/// Header rows bold, a rule under the header and over the total row, each
/// cell aligned as the card aligns (`FigureCardDrawing`'s text and painting).
struct FigureGridPlan: Equatable {
    typealias Text = FigureCardDrawing.Text

    /// The column letters across the band, visible columns only.
    var letters: [Text] = []
    /// The row numbers down the gutter, visible rows only.
    var numbers: [Text] = []
    /// The visible cells, row by row.
    var cells: [Text] = []
    /// Light lines between rows (y) and columns (x) across the body.
    var rowLines: [CGFloat] = []
    var columnLines: [CGFloat] = []
    /// The header's under-rule and the total row's over-rule, when on screen.
    var rules: [CGFloat] = []
    /// The selected rectangle and its active cell.
    var selection: CGRect?
    var active: CGRect?
    /// The reference a formula is composing.
    var reference: CGRect?
    /// The vertical scroll indicator, when the rows overflow the viewport.
    var scroller: CGRect?

    /// The thickness of the scroll indicator.
    static let scrollerWidth: CGFloat = 4

    /// The alignment a cell draws with: its own, else as the card aligns an
    /// automatic column — numbers and dates right, the rest left.
    static func alignment(of cell: Cell?, value: CellValue) -> CellAlignment {
        if let a = cell?.alignment, a != .automatic { return a }
        switch value {
        case .number, .date: return .right
        default: return .left
        }
    }

    /// The plan for `table` laid out by `layout`; `display` and `value` are
    /// asked for the visible cells only.
    static func make(layout: FigureGridLayout, table: FigureTable,
                     display: (CellKey) -> String, value: (CellKey) -> CellValue,
                     selection: FigureGridSelection?, reference: FigureGridReference?) -> FigureGridPlan {
        var plan = FigureGridPlan()
        let rows = table.rows, columns = table.columns
        let visibleRows = layout.visibleRows, visibleColumns = layout.visibleColumns
        let inset = FigureCardDrawing.cellInset
        let headerCount = min(table.headerRows, rows.count)
        let totalIndex = table.hasTotalRow && rows.count > headerCount ? rows.count - 1 : nil
        let body = layout.bodyRect

        for c in visibleColumns {
            plan.letters.append(Text(string: A1.columnLetters(c), rect: layout.letterFrame(column: c),
                                     alignment: .center))
            plan.columnLines.append(layout.cellFrame(row: 0, column: c).maxX)
        }
        for r in visibleRows where r < rows.count {
            let numberBox = layout.numberFrame(row: r)
            plan.numbers.append(Text(string: String(r + 1), rect: numberBox.insetBy(dx: inset, dy: 0),
                                     alignment: .right))
            plan.rowLines.append(numberBox.maxY)
            for c in visibleColumns where c < columns.count {
                let key = CellKey(row: rows[r], column: columns[c])
                let box = layout.cellFrame(row: r, column: c)
                plan.cells.append(Text(string: display(key),
                                       rect: CGRect(x: box.minX + inset, y: box.minY,
                                                    width: max(0, box.width - 2 * inset), height: box.height),
                                       alignment: alignment(of: table[key], value: value(key)),
                                       bold: r < headerCount))
            }
        }
        func ruleOnScreen(_ y: CGFloat) { if y >= body.minY, y <= body.maxY { plan.rules.append(y) } }
        if headerCount > 0, visibleRows.contains(headerCount - 1) {
            ruleOnScreen(layout.cellFrame(row: headerCount - 1, column: 0).maxY)
        }
        if let totalIndex, visibleRows.contains(totalIndex) {
            ruleOnScreen(layout.cellFrame(row: totalIndex, column: 0).minY)
        }

        func position(_ key: CellKey) -> (row: Int, column: Int)? {
            guard let r = table.rowIndex(of: key.row), let c = table.columnIndex(of: key.column) else { return nil }
            return (r, c)
        }
        if let selection, let a = position(selection.anchor), let f = position(selection.focus) {
            plan.selection = layout.rangeFrame(a, f)
            plan.active = layout.cellFrame(row: a.row, column: a.column)
        }
        if let reference, let a = position(reference.anchor), let f = position(reference.focus) {
            plan.reference = layout.rangeFrame(a, f)
        }
        if layout.contentHeight > body.height, layout.contentHeight > 0 {
            let share = body.height / layout.contentHeight
            let height = max(layout.rowHeight, (body.height * share).rounded())
            let travel = body.height - height
            let y = body.minY + (layout.maxScroll.y > 0 ? travel * layout.scroll.y / layout.maxScroll.y : 0)
            plan.scroller = CGRect(x: body.maxX - scrollerWidth - 1, y: y, width: scrollerWidth, height: height)
        }
        return plan
    }
}
