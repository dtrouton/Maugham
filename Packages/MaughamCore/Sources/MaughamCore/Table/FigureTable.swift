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

    public private(set) var rowSlots: [Slot<RowID>] { didSet { rowAxis = AxisIndex(rowSlots) } }
    public private(set) var columnSlots: [Slot<ColumnID>] { didSet { columnAxis = AxisIndex(columnSlots) } }
    public private(set) var cells: [CellKey: Cell]
    public var headerRows: Int { didSet { headerRows = min(max(headerRows, 0), 1) } }
    public var hasTotalRow: Bool
    public var columnWidths: [ColumnID: Double]

    /// Id → slot index and id → live position for each axis, so every id lookup is a
    /// dictionary read. Derived from the slots: never encoded, rebuilt on decode, and
    /// rebuilt by the slots' `didSet` on every insert, delete and move (each already O(n)).
    private var rowAxis: AxisIndex<RowID>
    private var columnAxis: AxisIndex<ColumnID>

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
        rowAxis = AxisIndex(r); columnAxis = AxisIndex(c)
    }

    private enum CodingKeys: String, CodingKey {
        case rowSlots, columnSlots, cells, headerRows, hasTotalRow, columnWidths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rowSlots = try c.decode([Slot<RowID>].self, forKey: .rowSlots)
        columnSlots = try c.decode([Slot<ColumnID>].self, forKey: .columnSlots)
        cells = try c.decode([CellKey: Cell].self, forKey: .cells)
        headerRows = try c.decode(Int.self, forKey: .headerRows)
        hasTotalRow = try c.decode(Bool.self, forKey: .hasTotalRow)
        columnWidths = try c.decode([ColumnID: Double].self, forKey: .columnWidths)
        rowAxis = AxisIndex(rowSlots); columnAxis = AxisIndex(columnSlots)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rowSlots, forKey: .rowSlots)
        try c.encode(columnSlots, forKey: .columnSlots)
        try c.encode(cells, forKey: .cells)
        try c.encode(headerRows, forKey: .headerRows)
        try c.encode(hasTotalRow, forKey: .hasTotalRow)
        try c.encode(columnWidths, forKey: .columnWidths)
    }

    /// Equality ignores the derived indexes.
    public static func == (a: FigureTable, b: FigureTable) -> Bool {
        a.rowSlots == b.rowSlots && a.columnSlots == b.columnSlots && a.cells == b.cells
            && a.headerRows == b.headerRows && a.hasTotalRow == b.hasTotalRow && a.columnWidths == b.columnWidths
    }

    public var rows: [RowID] { rowAxis.live }
    public var columns: [ColumnID] { columnAxis.live }

    public func rowIndex(of id: RowID) -> Int? { rowAxis.position[id] }
    public func columnIndex(of id: ColumnID) -> Int? { columnAxis.position[id] }
    public func rowSlotIndex(of id: RowID) -> Int? { rowAxis.slot[id] }
    public func columnSlotIndex(of id: ColumnID) -> Int? { columnAxis.slot[id] }

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

/// One axis's derived lookups: each id's first slot index, each live id's first live
/// position, and the live ids in order (the answers the old scans gave).
private struct AxisIndex<ID: Hashable & Codable & Sendable>: Sendable {
    let slot: [ID: Int]
    let position: [ID: Int]
    let live: [ID]

    init(_ slots: [FigureTable.Slot<ID>]) {
        var slot = [ID: Int](minimumCapacity: slots.count), position = [ID: Int](minimumCapacity: slots.count)
        var live = [ID]()
        live.reserveCapacity(slots.count)
        for (i, s) in slots.enumerated() {
            if slot[s.id] == nil { slot[s.id] = i }
            guard !s.isDeleted else { continue }
            if position[s.id] == nil { position[s.id] = live.count }
            live.append(s.id)
        }
        self.slot = slot; self.position = position; self.live = live
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
