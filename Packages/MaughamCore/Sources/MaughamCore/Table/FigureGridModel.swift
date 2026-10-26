import Foundation

// **The in-place grid's model** (report plan 7c, spec §6.3): what is
// selected, what is being edited, and what each key does. Pure and
// platform-free: the Mac's grid controller feeds it keys and executes the
// effects it answers (writes through the figure host, shows or hides the
// cell editor, repaints, scrolls). Selection is held by ids, so it survives
// rows and columns inserted, deleted or sorted elsewhere; `tableChanged`
// re-checks it against the table the host now holds. ⌘C/⌘V/⌘D/⌘R are plan
// 7d's; ⌘Z is the window's (ruling R7c-1).

/// An arrow's direction; for `.insert`, up/down is a row above/below and
/// left/right a column left/right.
public enum FigureGridDirection: Equatable, Sendable {
    case up, down, left, right
}

/// One key or gesture the grid hands its model.
public enum FigureGridKey: Equatable, Sendable {
    /// ← → ↑ ↓; `extend` with ⇧.
    case arrow(FigureGridDirection, extend: Bool)
    /// Tab, or ⇧Tab when `backward`.
    case tab(backward: Bool)
    /// Return, or ⇧Return when `backward`.
    case returnKey(backward: Bool)
    /// Characters typed while the grid (not the cell editor) has the keys.
    case type(String)
    /// The cell editor's whole text after the writer changed it.
    case editTextChanged(String)
    /// F2: edit inside the active cell.
    case editInPlace
    case escape
    /// ⌫
    case deleteBackward
    /// ⌘A
    case selectAll
    /// ⌘⌥ + arrow (delivered by the Format ▸ Table menu items, ruling R7c-10).
    case insert(FigureGridDirection)
    /// A click on a cell; `extend` with ⇧ or while dragging.
    case click(CellKey, extend: Bool)
    case doubleClick(CellKey)
    /// A click on a column's letter: the whole column.
    case selectColumn(ColumnID)
    /// A click on a row's number: the whole row.
    case selectRow(RowID)
}

/// What the controller does for a key, in order.
public enum FigureGridEffect: Equatable, Sendable {
    /// Select this one cell (anchor and focus).
    case moveSelection(to: CellKey)
    /// Move the selection's focus here, keeping its anchor.
    case extendSelection(to: CellKey)
    case scrollTo(CellKey)
    /// Open the cell editor on `cell` holding `text`, caret at its end.
    case beginEdit(cell: CellKey, text: String)
    /// Write `text` to `cell` as the writer typed it (the controller parses
    /// it; a refusal comes back through `reopenEdit`). The editor closes.
    case commitEdit(cell: CellKey, text: String)
    /// Close the cell editor, writing nothing.
    case cancelEdit
    /// A reference composed with the arrows or a click: its A1 text, and
    /// the cell editor's whole new text.
    case insertReference(String, editText: String)
    /// Empty these cells, row by row.
    case clear([CellKey])
    case insertRow(after: RowID?)
    case insertColumn(after: ColumnID?)
    /// Fold the grid back into its card.
    case fold
    /// The key is the open cell editor's own (a caret move, a deletion,
    /// select-all of its text): let it handle the key.
    case fieldEditorKeeps
}

/// The selected rectangle: the anchor is the active cell (it is what typing
/// edits and the formula bar shows), the focus the corner ⇧ moves.
public struct FigureGridSelection: Equatable, Sendable {
    public var anchor: CellKey
    public var focus: CellKey
    public init(anchor: CellKey, focus: CellKey) { self.anchor = anchor; self.focus = focus }

    /// The rectangle's cells in `table`, top to bottom, left to right; empty
    /// when either corner is not live.
    public func cells(in table: FigureTable) -> [CellKey] {
        guard let ar = table.rowIndex(of: anchor.row), let ac = table.columnIndex(of: anchor.column),
              let fr = table.rowIndex(of: focus.row), let fc = table.columnIndex(of: focus.column) else { return [] }
        let rows = table.rows[min(ar, fr)...max(ar, fr)], columns = table.columns[min(ac, fc)...max(ac, fc)]
        return rows.flatMap { r in columns.map { CellKey(row: r, column: $0) } }
    }

    /// "B3" or "B2:D9".
    public func address(in table: FigureTable) -> String? {
        FigureGridAddress.string(from: anchor, to: focus, in: table)
    }
}

/// An open cell edit.
public struct FigureGridEdit: Equatable, Sendable {
    public let cell: CellKey
    public internal(set) var text: String
    /// Began with F2, Return or a double-click (or F2 since): the arrows move
    /// the text caret. Begun by typing over the cell, the arrows commit and
    /// move, or compose a reference.
    public internal(set) var inCell: Bool
    public init(cell: CellKey, text: String, inCell: Bool) { self.cell = cell; self.text = text; self.inCell = inCell }
}

/// A reference composed with the arrows or clicks: the rectangle it names,
/// written at the end of the edit text after `prefix`.
public struct FigureGridReference: Equatable, Sendable {
    public var anchor: CellKey
    public var focus: CellKey
    public let prefix: String
    public init(anchor: CellKey, focus: CellKey, prefix: String) {
        self.anchor = anchor; self.focus = focus; self.prefix = prefix
    }
}

public enum FigureGridEditState: Equatable, Sendable {
    case idle
    case editing(FigureGridEdit)
    /// The edit text starts with `=`; `reference` is the one the arrows or a
    /// click are moving, nil until there is one or once the writer types on.
    case composing(FigureGridEdit, reference: FigureGridReference?)
}

public struct FigureGridModel {
    public private(set) var table: FigureTable
    /// Nil only while the table has no cells.
    public internal(set) var selection: FigureGridSelection?
    public internal(set) var edit: FigureGridEditState = .idle
    /// A cell's contents as the cell editor opens on them (its formula with
    /// `=`, or its value), supplied by the controller.
    private let editText: (CellKey) -> String

    /// Characters after which an arrow or click composes a reference.
    private static let referencePoints: Set<Character> = ["=", "(", ",", "+", "-", "*", "/", "^", "<", ">"]

    public init(table: FigureTable, editText: @escaping (CellKey) -> String) {
        self.table = table
        self.editText = editText
        selection = Self.firstCell(of: table).map { FigureGridSelection(anchor: $0, focus: $0) }
    }

    // MARK: Keys

    public mutating func reduce(_ key: FigureGridKey) -> [FigureGridEffect] {
        switch edit {
        case .idle: return reduceIdle(key)
        case let .editing(e): return reduceEditing(key, e, composing: false, reference: nil)
        case let .composing(e, ref): return reduceEditing(key, e, composing: true, reference: ref)
        }
    }

    private mutating func reduceIdle(_ key: FigureGridKey) -> [FigureGridEffect] {
        switch key {
        case .escape: return [.fold]
        case let .insert(direction): return insert(direction)
        default: break
        }
        guard let sel = selection, let active = position(sel.anchor), let far = position(sel.focus) else { return [] }
        switch key {
        case let .arrow(d, extend):
            return extend ? extendTo(step(far, d)) : moveTo(step(active, d))
        case let .tab(backward):
            return moveTo(tabStep(active, backward: backward))
        case let .returnKey(backward):
            return backward ? moveTo(step(active, .up)) : beginEdit(sel.anchor, text: editText(sel.anchor), inCell: true)
        case let .type(text):
            return text.isEmpty ? [] : beginEdit(sel.anchor, text: text, inCell: false)
        case .editInPlace:
            return beginEdit(sel.anchor, text: editText(sel.anchor), inCell: true)
        case .deleteBackward:
            return [.clear(sel.cells(in: table))]
        case .selectAll:
            guard let first = Self.firstCell(of: table), let last = lastCell else { return [] }
            return selectRectangle(first, last)
        case let .selectColumn(column):
            guard table.columnIndex(of: column) != nil, let top = table.rows.first, let bottom = table.rows.last
            else { return [] }
            return selectRectangle(CellKey(row: top, column: column), CellKey(row: bottom, column: column))
        case let .selectRow(row):
            guard table.rowIndex(of: row) != nil, let left = table.columns.first, let right = table.columns.last
            else { return [] }
            return selectRectangle(CellKey(row: row, column: left), CellKey(row: row, column: right))
        case let .click(cell, extend):
            guard let p = position(cell) else { return [] }
            return extend ? extendTo(p) : moveTo(p)
        case let .doubleClick(cell):
            guard let p = position(cell) else { return [] }
            return moveTo(p) + beginEdit(cell, text: editText(cell), inCell: true)
        case .editTextChanged, .escape, .insert:
            return []
        }
    }

    private mutating func reduceEditing(
        _ key: FigureGridKey, _ e: FigureGridEdit, composing: Bool, reference: FigureGridReference?
    ) -> [FigureGridEffect] {
        let canPoint = composing && (reference != nil || Self.endsAtReferencePoint(e.text))
        switch key {
        case let .arrow(d, extend):
            if e.inCell { return [.fieldEditorKeeps] }
            if canPoint { return pointByArrow(d, extend: extend, e, reference) }
            return commit(e) + reduceIdle(key)
        case let .returnKey(backward):
            // Return commits and moves down (⇧ up); only on a selected cell does it edit.
            let effects = commit(e)
            guard let p = position(e.cell) else { return effects }
            return effects + moveTo(step(p, backward ? .up : .down))
        case .tab, .insert, .selectColumn, .selectRow:
            return commit(e) + reduceIdle(key)
        case .type, .deleteBackward, .selectAll:
            return [.fieldEditorKeeps]
        case let .editTextChanged(text):
            var next = e
            next.text = text
            // Typing on past the reference fixes it: the next arrow starts another.
            let kept = reference.flatMap { ref -> FigureGridReference? in
                guard let address = FigureGridAddress.string(from: ref.anchor, to: ref.focus, in: table),
                      text == ref.prefix + address else { return nil }
                return ref
            }
            edit = text.hasPrefix("=") ? .composing(next, reference: kept) : .editing(next)
            return []
        case .editInPlace:
            var next = e
            next.inCell.toggle()
            edit = composing ? .composing(next, reference: reference) : .editing(next)
            return []
        case .escape:
            edit = .idle
            return [.cancelEdit]
        case let .click(cell, extend):
            guard position(cell) != nil else { return [] }
            if canPoint { return point(at: cell, extend: extend, e, reference) }
            return commit(e) + reduceIdle(key)
        case let .doubleClick(cell):
            guard position(cell) != nil else { return [] }
            if canPoint { return point(at: cell, extend: false, e, reference) }
            if cell == e.cell { return [.fieldEditorKeeps] }
            return commit(e) + reduceIdle(key)
        }
    }

    // MARK: Verbs the controller calls

    /// Select one cell (a row or column the host just inserted, say).
    public mutating func select(_ cell: CellKey) -> [FigureGridEffect] {
        guard let p = position(cell) else { return [] }
        return moveTo(p)
    }

    /// Fold the grid: an open edit is committed (Done, a click away, the text
    /// taking focus) or discarded (ruling R7c-8).
    public mutating func fold(commit shouldCommit: Bool) -> [FigureGridEffect] {
        switch edit {
        case .idle: return [.fold]
        case let .editing(e), let .composing(e, _):
            if shouldCommit { return commit(e) + [.fold] }
            edit = .idle
            return [.cancelEdit, .fold]
        }
    }

    /// The controller refused a commit (a formula that does not parse): the
    /// edit opens again on its cell, holding the text, arrows on the caret.
    public mutating func reopenEdit(cell: CellKey, text: String) -> [FigureGridEffect] {
        guard let p = position(cell) else { return [] }
        return moveTo(p) + beginEdit(cell, text: text, inCell: true)
    }

    /// The host's table changed (an edit here or elsewhere, a sort, an undo):
    /// each held id is checked against it. A deleted row or column gives way
    /// to the next live one by slot (the previous one at the end); an id the
    /// table never held gives way to the first. An edit whose cell is gone is
    /// cancelled; a reference whose cell is gone is dropped (its text stays).
    public mutating func tableChanged(_ newTable: FigureTable) -> [FigureGridEffect] {
        table = newTable
        var effects = [FigureGridEffect]()
        switch edit {
        case .idle: break
        case let .editing(e), let .composing(e, _):
            if position(e.cell) == nil {
                edit = .idle
                effects.append(.cancelEdit)
            } else if case let .composing(e, ref?) = edit, position(ref.anchor) == nil || position(ref.focus) == nil {
                edit = .composing(e, reference: nil)
            }
        }
        let old = selection
        if let old, let anchor = resolve(old.anchor), let focus = resolve(old.focus) {
            selection = FigureGridSelection(anchor: anchor, focus: focus)
        } else {
            selection = Self.firstCell(of: table).map { FigureGridSelection(anchor: $0, focus: $0) }
        }
        if let sel = selection, sel != old {
            effects.append(.moveSelection(to: sel.anchor))
            if sel.focus != sel.anchor { effects.append(.extendSelection(to: sel.focus)) }
        }
        return effects
    }

    // MARK: Steps

    private struct Position: Equatable { var row: Int; var column: Int }

    private func position(_ key: CellKey) -> Position? {
        guard let r = table.rowIndex(of: key.row), let c = table.columnIndex(of: key.column) else { return nil }
        return Position(row: r, column: c)
    }

    private func key(_ p: Position) -> CellKey { CellKey(row: table.rows[p.row], column: table.columns[p.column]) }

    private static func firstCell(of table: FigureTable) -> CellKey? {
        guard let r = table.rows.first, let c = table.columns.first else { return nil }
        return CellKey(row: r, column: c)
    }

    private var lastCell: CellKey? {
        guard let r = table.rows.last, let c = table.columns.last else { return nil }
        return CellKey(row: r, column: c)
    }

    /// One cell in `d`, held at the table's edge.
    private func step(_ p: Position, _ d: FigureGridDirection) -> Position {
        var q = p
        switch d {
        case .up: q.row = max(p.row - 1, 0)
        case .down: q.row = min(p.row + 1, table.rows.count - 1)
        case .left: q.column = max(p.column - 1, 0)
        case .right: q.column = min(p.column + 1, table.columns.count - 1)
        }
        return q
    }

    /// Tab: right, wrapping to the next row's first cell; ⇧Tab: left,
    /// wrapping to the previous row's last; held at the first and last cell.
    private func tabStep(_ p: Position, backward: Bool) -> Position {
        let width = table.columns.count
        let flat = p.row * width + p.column + (backward ? -1 : 1)
        guard flat >= 0, flat < table.rows.count * width else { return p }
        return Position(row: flat / width, column: flat % width)
    }

    private mutating func moveTo(_ p: Position) -> [FigureGridEffect] {
        let cell = key(p)
        let next = FigureGridSelection(anchor: cell, focus: cell)
        guard next != selection else { return [] }
        selection = next
        return [.moveSelection(to: cell), .scrollTo(cell)]
    }

    /// Select the rectangle `first`…`last`, `first` the active cell; nothing when it already is.
    private mutating func selectRectangle(_ first: CellKey, _ last: CellKey) -> [FigureGridEffect] {
        let next = FigureGridSelection(anchor: first, focus: last)
        guard next != selection else { return [] }
        selection = next
        return first == last ? [.moveSelection(to: first)] : [.moveSelection(to: first), .extendSelection(to: last)]
    }

    private mutating func extendTo(_ p: Position) -> [FigureGridEffect] {
        guard let sel = selection else { return [] }
        let cell = key(p)
        guard cell != sel.focus else { return [] }
        selection = FigureGridSelection(anchor: sel.anchor, focus: cell)
        return [.extendSelection(to: cell), .scrollTo(cell)]
    }

    // MARK: Edits

    private mutating func beginEdit(_ cell: CellKey, text: String, inCell: Bool) -> [FigureGridEffect] {
        let e = FigureGridEdit(cell: cell, text: text, inCell: inCell)
        edit = text.hasPrefix("=") ? .composing(e, reference: nil) : .editing(e)
        return [.beginEdit(cell: cell, text: text)]
    }

    private mutating func commit(_ e: FigureGridEdit) -> [FigureGridEffect] {
        edit = .idle
        return [.commitEdit(cell: e.cell, text: e.text)]
    }

    /// True when the formula text ends (spaces aside) where a reference may
    /// go: after `=`, an operator, an open bracket or a comma.
    private static func endsAtReferencePoint(_ text: String) -> Bool {
        guard let last = text.last(where: { $0 != " " }) else { return false }
        return referencePoints.contains(last)
    }

    /// An arrow while composing: the first moves from the cell being edited
    /// (⇧ makes a range from it); later ones move the reference's focus, a
    /// plain arrow collapsing it there. Nothing when the step goes nowhere.
    private mutating func pointByArrow(
        _ d: FigureGridDirection, extend: Bool, _ e: FigureGridEdit, _ reference: FigureGridReference?
    ) -> [FigureGridEffect] {
        let from = reference?.focus ?? e.cell
        guard let p = position(from) else { return [] }
        let target = step(p, d)
        guard target != p else { return [] }
        let cell = key(target)
        let anchor = extend ? (reference?.anchor ?? e.cell) : cell
        return writeReference(anchor: anchor, focus: cell, prefix: reference?.prefix ?? e.text, e)
    }

    /// A click while composing: references the clicked cell, or with ⇧ (a
    /// drag) stretches the current reference to it.
    private mutating func point(
        at cell: CellKey, extend: Bool, _ e: FigureGridEdit, _ reference: FigureGridReference?
    ) -> [FigureGridEffect] {
        let anchor = extend ? (reference?.anchor ?? cell) : cell
        if let reference, reference.anchor == anchor, reference.focus == cell { return [] }
        return writeReference(anchor: anchor, focus: cell, prefix: reference?.prefix ?? e.text, e)
    }

    private mutating func writeReference(
        anchor: CellKey, focus: CellKey, prefix: String, _ e: FigureGridEdit
    ) -> [FigureGridEffect] {
        guard let address = FigureGridAddress.string(from: anchor, to: focus, in: table) else { return [] }
        var next = e
        next.text = prefix + address
        edit = .composing(next, reference: FigureGridReference(anchor: anchor, focus: focus, prefix: prefix))
        return [.insertReference(address, editText: next.text), .scrollTo(focus)]
    }

    // MARK: Insert

    /// A row goes above or below the active cell's row, kept inside the body:
    /// never above the header row nor below the total row. A column goes left
    /// or right of the active cell's column. With no cells, at the body's
    /// start or end.
    private func insert(_ d: FigureGridDirection) -> [FigureGridEffect] {
        let active = selection.flatMap { position($0.anchor) }
        switch d {
        case .up, .down:
            let rows = table.rows
            let head = min(table.headerRows, rows.count)
            let tail = table.hasTotalRow && rows.count > head ? 1 : 0
            let wanted = active.map { d == .up ? $0.row : $0.row + 1 } ?? (d == .up ? head : rows.count - tail)
            let at = min(max(wanted, head), rows.count - tail)
            return [.insertRow(after: at == 0 ? nil : rows[at - 1])]
        case .left, .right:
            let columns = table.columns
            let at = active.map { d == .left ? $0.column : $0.column + 1 } ?? (d == .left ? 0 : columns.count)
            return [.insertColumn(after: at == 0 ? nil : columns[at - 1])]
        }
    }

    // MARK: Resolution

    private func resolve(_ cell: CellKey) -> CellKey? {
        guard let r = Self.resolve(cell.row, table.rowSlots, table.rows.first),
              let c = Self.resolve(cell.column, table.columnSlots, table.columns.first) else { return nil }
        return CellKey(row: r, column: c)
    }

    /// The id if live; else the next live id after its slot, else the one
    /// before; an id with no slot gives way to `first`.
    private static func resolve<ID: Hashable>(_ id: ID, _ slots: [FigureTable.Slot<ID>], _ first: ID?) -> ID? {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return first }
        if !slots[i].isDeleted { return id }
        if let after = slots[(i + 1)...].first(where: { !$0.isDeleted }) { return after.id }
        return slots[..<i].last(where: { !$0.isDeleted })?.id
    }
}
