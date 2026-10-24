import Foundation

/// A figure table: rows and columns are ordered id slots (deleted ones stay as
/// tombstones so ranges and replayed inserts keep a position), cells are keyed
/// by id pair. Named `FigureTable`, never `Table` (SwiftUI's `Table` collides).
public struct FigureTable: Equatable, Codable, Sendable {
    public struct Slot<ID: Hashable & Codable & Sendable>: Equatable, Codable, Sendable {
        public let id: ID
        public var isDeleted: Bool
        public init(id: ID, isDeleted: Bool = false) { self.id = id; self.isDeleted = isDeleted }
    }

    public private(set) var rowSlots: [Slot<RowID>]
    public private(set) var columnSlots: [Slot<ColumnID>]
    public private(set) var cells: [CellKey: Cell]
    public var headerRows: Int { didSet { headerRows = min(max(headerRows, 0), 1) } }
    public var hasTotalRow: Bool
    public var columnWidths: [ColumnID: Double]

    public init(rows: Int, columns: Int) {
        var used = Set<String>()
        var r = [Slot<RowID>](), c = [Slot<ColumnID>]()
        for _ in 0..<max(rows, 0) {
            let id = TableID.mint(excluding: used); used.insert(id); r.append(Slot(id: RowID(id)))
        }
        for _ in 0..<max(columns, 0) {
            let id = TableID.mint(excluding: used); used.insert(id); c.append(Slot(id: ColumnID(id)))
        }
        rowSlots = r; columnSlots = c; cells = [:]
        headerRows = 0; hasTotalRow = false; columnWidths = [:]
    }

    public var rows: [RowID] { rowSlots.filter { !$0.isDeleted }.map(\.id) }
    public var columns: [ColumnID] { columnSlots.filter { !$0.isDeleted }.map(\.id) }

    public func rowIndex(of id: RowID) -> Int? {
        var n = 0
        for s in rowSlots where !s.isDeleted { if s.id == id { return n }; n += 1 }
        return nil
    }
    public func columnIndex(of id: ColumnID) -> Int? {
        var n = 0
        for s in columnSlots where !s.isDeleted { if s.id == id { return n }; n += 1 }
        return nil
    }
    public func rowSlotIndex(of id: RowID) -> Int? { rowSlots.firstIndex { $0.id == id } }
    public func columnSlotIndex(of id: ColumnID) -> Int? { columnSlots.firstIndex { $0.id == id } }

    public subscript(key: CellKey) -> Cell? { cells[key] }

    public mutating func setCell(_ cell: Cell?, at key: CellKey) {
        guard rowIndex(of: key.row) != nil, columnIndex(of: key.column) != nil else { return }
        cells[key] = cell
    }

    private var usedIDs: Set<String> {
        Set(rowSlots.map(\.id.raw)).union(columnSlots.map(\.id.raw))
    }

    @discardableResult
    public mutating func insertRow(after: RowID?) -> RowID {
        let id = RowID(TableID.mint(excluding: usedIDs))
        insertRow(id, after: after)
        return id
    }

    public mutating func insertRow(_ id: RowID, after: RowID?) {
        guard rowSlotIndex(of: id) == nil else { return }
        rowSlots.insert(Slot(id: id), at: Self.insertionIndex(after: after, in: rowSlots))
    }

    @discardableResult
    public mutating func insertColumn(after: ColumnID?) -> ColumnID {
        let id = ColumnID(TableID.mint(excluding: usedIDs))
        insertColumn(id, after: after)
        return id
    }

    public mutating func insertColumn(_ id: ColumnID, after: ColumnID?) {
        guard columnSlotIndex(of: id) == nil else { return }
        columnSlots.insert(Slot(id: id), at: Self.insertionIndex(after: after, in: columnSlots))
    }

    public mutating func deleteRow(_ id: RowID) {
        guard let i = rowSlotIndex(of: id) else { return }
        rowSlots[i].isDeleted = true
        cells = cells.filter { $0.key.row != id }
    }

    public mutating func deleteColumn(_ id: ColumnID) {
        guard let i = columnSlotIndex(of: id) else { return }
        columnSlots[i].isDeleted = true
        cells = cells.filter { $0.key.column != id }
        columnWidths[id] = nil
    }

    public mutating func moveRow(_ id: RowID, after: RowID?) {
        guard rowIndex(of: id) != nil, after != id, let from = rowSlotIndex(of: id) else { return }
        let slot = rowSlots.remove(at: from)
        rowSlots.insert(slot, at: Self.insertionIndex(after: after, in: rowSlots))
    }

    public mutating func moveColumn(_ id: ColumnID, after: ColumnID?) {
        guard columnIndex(of: id) != nil, after != id, let from = columnSlotIndex(of: id) else { return }
        let slot = columnSlots.remove(at: from)
        columnSlots.insert(slot, at: Self.insertionIndex(after: after, in: columnSlots))
    }

    /// nil = top; a known slot (live or tombstoned) = just after it; unknown = the end.
    private static func insertionIndex<ID>(after: ID?, in slots: [Slot<ID>]) -> Int {
        guard let after else { return 0 }
        if let i = slots.firstIndex(where: { $0.id == after }) { return i + 1 }
        return slots.count
    }
}

extension FigureTable {
    /// The live rows whose slots lie between slot indices `a` and `b` inclusive (either
    /// order), top to bottom. The one definition of a range's rows: rendering shows its
    /// first and last (an edge on a tombstone shrinks inward), evaluation reads them all,
    /// and an empty result is `#REF!`.
    func liveRows(betweenSlots a: Int, _ b: Int) -> [RowID] {
        Self.live(rowSlots, a, b)
    }

    /// The live columns between slot indices `a` and `b` inclusive; see `liveRows`.
    func liveColumns(betweenSlots a: Int, _ b: Int) -> [ColumnID] {
        Self.live(columnSlots, a, b)
    }

    private static func live<ID>(_ slots: [Slot<ID>], _ a: Int, _ b: Int) -> [ID] {
        let lo = max(min(a, b), 0), hi = min(max(a, b), slots.count - 1)
        guard lo <= hi else { return [] }
        return slots[lo...hi].filter { !$0.isDeleted }.map(\.id)
    }
}
