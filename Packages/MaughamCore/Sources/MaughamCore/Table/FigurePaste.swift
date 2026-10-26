import Foundation

/// **A paste into a table figure's grid** (report plan 7d, rulings R7d-2 and
/// R7d-3): the ops that put a block of cells at a cell, growing the table when
/// the block runs past its edge. Pure; the host appends the answer as one
/// visit with one ⌘Z (`FigureDocument.applyChanges`).
public enum FigurePaste {

    /// A live position in a grid, counted from 0.
    public struct Position: Equatable, Sendable {
        public var row: Int
        public var column: Int
        public init(row: Int, column: Int) { self.row = row; self.column = column }
    }

    /// The cells to paste, row by row. A nil cell clears its target; a row
    /// shorter than the widest leaves the targets past its end alone (a ragged
    /// tab-separated copy), while the block is as wide as its widest row.
    public struct Block: Equatable, Sendable {
        public var cells: [[Cell?]]
        /// **Where the block was copied from in this same table**, its top-left
        /// cell's live position at copy time — Maugham's own pasteboard type
        /// (R7d-3). When set, a formula is translated by how far it moved
        /// (Excel's relative paste); nil (text from another app, or another
        /// figure) pastes a formula as given.
        public var copiedFrom: Position?

        public init(cells: [[Cell?]], copiedFrom: Position? = nil) {
            self.cells = cells
            self.copiedFrom = copiedFrom
        }

        public var height: Int { cells.count }
        public var width: Int { cells.map(\.count).max() ?? 0 }
    }

    /// A paste's ops, and where they landed.
    public struct Plan: Equatable, Sendable {
        /// Column inserts, then row inserts, then cell sets in reading order —
        /// each made against the state the ones before it leave.
        public var changes: [FigureReturnDiff.Change]
        public var insertedRows: [RowID]
        public var insertedColumns: [ColumnID]
        /// The pasted rectangle in the grown table, to select after the paste.
        public var pasted: FigureGridSelection
    }

    public enum Outcome: Equatable, Sendable {
        case paste(Plan)
        /// The paste would leave more cells than a figure may hold
        /// (`TableCSV.figureCellLimit`, R7d-2): `cells` is the count that is
        /// over it — the block's cells, or the table's filled cells after.
        case tooLarge(cells: Int)
        /// The anchor's row or column is not live.
        case anchorGone
    }

    /// **The ops that paste `block` with its top-left at `anchor`** in
    /// `state`'s table:
    /// - **growth**: rows the block runs past the last row are inserted after
    ///   it, and columns past the last column after that, with fresh ids from
    ///   `mintRow`/`mintColumn` (never one the table has held);
    /// - **a total row is never pasted over** (report plan 7d, controller's
    ///   ruling on R7d-2): with `hasTotalRow` the body ends above it, so rows
    ///   the block runs past the body are inserted before the total row, which
    ///   stays last with its cells as they were; a paste anchored ON the total
    ///   row goes into new body rows just above it (as Excel's table grows when
    ///   you write under its last body row) — `Plan.pasted` then starts at the
    ///   first of them;
    /// - **`area`** is the selection pasted into: when it is a whole multiple
    ///   of the block's size the block tiles it (one cell copied into a range
    ///   fills the range — Excel); otherwise the block pastes once;
    /// - **formulas** of a block copied from this table move by how far each
    ///   cell moved (`Block.copiedFrom`), against the grown table — `$` parts
    ///   stay, a ref pushed off the grid is `#REF!`;
    /// - a target that already holds the cell is left out;
    /// - **refused** (`tooLarge`) when the pasted rectangle, or the table's
    ///   filled cells after the paste, number more than
    ///   `TableCSV.figureCellLimit`.
    public static func changes(
        state: FigureState, anchor: CellKey, block: Block, area: (rows: Int, columns: Int)? = nil,
        names: FormulaNames = .empty,
        mintRow: () -> RowID = { RowID(TableID.mint(excluding: [])) },
        mintColumn: () -> ColumnID = { ColumnID(TableID.mint(excluding: [])) }
    ) -> Outcome {
        let table = state.table
        guard let anchorRow = table.rowIndex(of: anchor.row), let ac = table.columnIndex(of: anchor.column) else {
            return .anchorGone
        }
        // Where the body ends: above a total row (FigureSort's rule), else at the last row.
        let bodyEnd = table.rowCountAboveTotal
        // The block's first row: the anchor's, or — anchored on the total row — the first new body row.
        let ar = min(anchorRow, bodyEnd)
        let bh = block.height, bw = block.width
        guard bh > 0, bw > 0 else {
            return .paste(Plan(changes: [], insertedRows: [], insertedColumns: [],
                               pasted: FigureGridSelection(anchor: anchor, focus: anchor)))
        }
        // Excel tiles only into a whole multiple of the block.
        var height = bh, width = bw
        if let area, area.rows >= bh, area.columns >= bw, area.rows % bh == 0, area.columns % bw == 0 {
            height = area.rows
            width = area.columns
        }
        let limit = TableCSV.figureCellLimit
        guard height * width <= limit else { return .tooLarge(cells: height * width) }

        // The filled cells after: those outside the rectangle, and the rectangle's own.
        func cell(_ r: Int, _ c: Int) -> Cell?? {
            let row = block.cells[r % bh]
            let column = c % bw
            return column < row.count ? .some(row[column]) : nil
        }
        func filled(_ cell: Cell?) -> Bool {
            switch cell?.content {
            case nil, .value(.empty)?: false
            case .value(.text(let t))?: !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: true
            }
        }
        var after = 0
        for (key, value) in table.cells where filled(value) {
            guard let r = table.rowIndex(of: key.row), let c = table.columnIndex(of: key.column) else { continue }
            let inside = (ar..<min(ar + height, bodyEnd)).contains(r) && (ac..<(ac + width)).contains(c)
            if !inside { after += 1 }
            else if cell(r - ar, c - ac) == nil { after += 1 }   // a ragged row leaves it
        }
        for r in 0..<height {
            for c in 0..<width {
                if let pasted = cell(r, c), filled(pasted) { after += 1 }
            }
        }
        guard after <= limit else { return .tooLarge(cells: after) }

        // Growth.
        var sim = FigureReturnDiff.Simulation(state: state)
        var used = Set(table.rowSlots.map(\.id.raw)).union(table.columnSlots.map(\.id.raw))
        var insertedColumns: [ColumnID] = []
        var lastColumn = table.columns.last
        for _ in 0..<max(0, ac + width - table.columns.count) {
            var id = mintColumn()
            while used.contains(id.raw) { id = mintColumn() }
            used.insert(id.raw)
            sim.emit(.figureStructure, FigureOpPayload(structure: .insertColumn(id, after: lastColumn)))
            insertedColumns.append(id)
            lastColumn = id
        }
        var insertedRows: [RowID] = []
        var lastRow = bodyEnd > 0 ? table.rows[bodyEnd - 1] : nil   // nil: before the total row, first
        for _ in 0..<max(0, ar + height - bodyEnd) {
            var id = mintRow()
            while used.contains(id.raw) { id = mintRow() }
            used.insert(id.raw)
            sim.emit(.figureStructure, FigureOpPayload(structure: .insertRow(id, after: lastRow)))
            insertedRows.append(id)
            lastRow = id
        }

        // Cells, against the grown table.
        let grown = sim.state.table
        let rows = grown.rows, columns = grown.columns
        for r in 0..<height {
            for c in 0..<width {
                guard var next = cell(r, c) else { continue }
                if let from = block.copiedFrom, case .formula(let f)? = next?.content {
                    let source = Position(row: from.row + r % bh, column: from.column + c % bw)
                    next?.content = .formula(FormulaParser.translate(
                        f, rows: ar + r - source.row, columns: ac + c - source.column, in: grown, names: names))
                }
                let key = CellKey(row: rows[ar + r], column: columns[ac + c])
                let now = sim.state.table[key]
                guard now != next else { continue }
                sim.emit(.figureCellSet, FigureOpPayload(cell: key, next: next, prior: now))
            }
        }
        let first = CellKey(row: rows[ar], column: anchor.column)
        let focus = CellKey(row: rows[ar + height - 1], column: columns[ac + width - 1])
        return .paste(Plan(changes: sim.ops, insertedRows: insertedRows, insertedColumns: insertedColumns,
                           pasted: FigureGridSelection(anchor: first, focus: focus)))
    }
}

extension FigureTable {
    /// The live rows above a total row — all of them when there is none, or
    /// when the table is all header (`FigureSort`'s rule for the total row).
    var rowCountAboveTotal: Int {
        let count = rows.count
        return hasTotalRow && count > headerRows ? count - 1 : count
    }
}
