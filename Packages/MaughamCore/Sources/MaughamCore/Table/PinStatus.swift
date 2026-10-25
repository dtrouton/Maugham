import Foundation

/// **Where one source a figure's pins read stands** (spec §4.3, report plan 6b
/// Task 9) — a Research table, or a figure parked in Research (R-D2). For
/// plans 7–9's markers and publish notes; no surface reads it yet.
/// - `current`: every pin on it was taken from the bytes it holds now.
/// - `sourceChanged`: its content hash is no longer the one a pin recorded —
///   for a parked figure read without a pin, the one its park recorded.
/// - `sourceMissing`: the Research item, or the parked figure's working copy,
///   is gone. The kept values stay; nothing is cleared.
public enum PinStatus: Equatable, Sendable {
    case current
    case sourceChanged(old: String, new: String)
    case sourceMissing
}

/// One source cell a formula reads: a Research item's, or a parked figure's,
/// by id and 0-based live position — the key a `FigureResearchPin` is taken on.
public struct PinRead: Hashable, Sendable {
    public let source: String
    public let row: Int
    public let column: Int
    public init(source: String, row: Int, column: Int) {
        self.source = source
        self.row = row
        self.column = column
    }
}

/// **A source as it reads now**: its content hash and its computed values by
/// live position.
public struct PinSourceRead: Equatable, Sendable {
    public let hash: String
    private let values: [[CellValue]]

    public init(hash: String, values: [[CellValue]]) {
        self.hash = hash
        self.values = values
    }

    /// `table`'s values as `book` computes them with it set under `id` — a
    /// formula in a Research CSV reads the book's figures as a figure's would.
    public init(hash: String, table: FigureTable, book: Workbook, as id: String) {
        var book = book
        book.setTable(table, id: id)
        self.hash = hash
        self.values = table.rows.map { r in
            table.columns.map { c in book.value(at: CellAddress(table: id, key: CellKey(row: r, column: c))) }
        }
    }

    /// The value at a 0-based position, or nil off the grid.
    public func value(row: Int, column: Int) -> CellValue? {
        guard values.indices.contains(row), values[row].indices.contains(column) else { return nil }
        return values[row][column]
    }
}

/// **Every source one figure reads through pins, as it stands now** — what
/// the host gathers before asking `FigurePins`.
public struct PinSources: Sendable {
    /// A figure parked in Research: its park, its parked table (a ref's id
    /// anchors become positions in it), its parked values, and its working
    /// copy as it reads now (nil when the copy is gone).
    public struct Parked: Sendable {
        public let parking: FigureParking
        public let table: FigureTable
        public let parkedValues: PinSourceRead
        public let copy: PinSourceRead?
        public init(parking: FigureParking, table: FigureTable, parkedValues: PinSourceRead, copy: PinSourceRead?) {
            self.parking = parking
            self.table = table
            self.parkedValues = parkedValues
            self.copy = copy
        }
    }

    /// Research tables by item id; an id the figure reads that is absent here
    /// is gone (`sourceMissing`).
    public var research: [String: PinSourceRead]
    /// Parked figures by figure id. A ref to a figure absent here is live.
    public var parked: [String: Parked]

    public init(research: [String: PinSourceRead] = [:], parked: [String: Parked] = [:]) {
        self.research = research
        self.parked = parked
    }

    var parkedTables: [String: FigureTable] { parked.mapValues(\.table) }
}

/// One pinned position whose value would change on a refresh: the reading
/// figure's `cell` (the first one reading or holding it), what it shows now
/// (`old`) and what the source holds (`new`, nil when the source is gone).
public struct PinComparison: Equatable, Sendable {
    public let cell: CellKey
    public let read: PinRead
    public let old: CellValue
    public let new: CellValue?
    public init(cell: CellKey, read: PinRead, old: CellValue, new: CellValue?) {
        self.cell = cell
        self.read = read
        self.old = old
        self.new = new
    }
}

/// A pin to write on `cell`, and the one from the same source cell it
/// replaces there (`figurePinSet`'s `priorPin`, ruling P-8).
public struct PinWrite: Equatable, Sendable {
    public let cell: CellKey
    public let pin: FigureResearchPin
    public let prior: FigureResearchPin?
}

/// **Research pins: what a figure reads, where each source stands, what a
/// refresh writes** (spec §4.3; R-D2). Pure; the Mac's host gathers the
/// sources (`PinSources`) and appends what this answers.
public enum FigurePins {

    // MARK: What is read

    /// What each formula cell of `table` reads through a pin: positions in
    /// Research tables, and in figures parked in Research (`parked`, by id —
    /// a ref's id anchors become positions in that parked table).
    public static func reads(of table: FigureTable, parked: [String: FigureTable]) -> [CellKey: Set<PinRead>] {
        var out: [CellKey: Set<PinRead>] = [:]
        for (key, cell) in table.cells {
            guard case .formula(let f) = cell.content else { continue }
            let reads = reads(of: f, in: table, parked: parked)
            if !reads.isEmpty { out[key] = reads }
        }
        return out
    }

    /// What one formula written in `table` reads through a pin: each single
    /// ref, every cell of a range, and SUMIF's resized sum block.
    public static func reads(of formula: Formula, in table: FigureTable, parked: [String: FigureTable]) -> Set<PinRead> {
        var out = Set<PinRead>()
        Collector(home: table, parked: parked).collect(formula.expr, into: &out)
        return out
    }

    // MARK: Where each source stands

    /// Each source `state`'s formulas read through a pin, and where it stands.
    /// A pin on a source no formula reads any more counts for nothing.
    public static func status(of state: FigureState, sources: PinSources) -> [String: PinStatus] {
        let reads = reads(of: state.table, parked: sources.parkedTables)
        let read = Set(reads.values.flatMap { $0 })
        let pinned = homePins(state)
        var out: [String: PinStatus] = [:]
        for source in Set(read.map(\.source)) {
            let pins = state.pins.values.flatMap { $0 }.filter { $0.research == source }
            if let parked = sources.parked[source] {
                guard let copy = parked.copy else { out[source] = .sourceMissing; continue }
                if let stale = pins.first(where: { $0.sourceHash != copy.hash }) {
                    out[source] = .sourceChanged(old: stale.sourceHash, new: copy.hash)
                } else if parked.parking.hash != copy.hash,
                          read.contains(where: { $0.source == source && pinned[$0] == nil }) {
                    out[source] = .sourceChanged(old: parked.parking.hash, new: copy.hash)
                } else {
                    out[source] = .current
                }
            } else {
                guard let now = sources.research[source] else { out[source] = .sourceMissing; continue }
                if let stale = pins.first(where: { $0.sourceHash != now.hash }) {
                    out[source] = .sourceChanged(old: stale.sourceHash, new: now.hash)
                } else {
                    out[source] = .current
                }
            }
        }
        return out
    }

    // MARK: Compare and refresh

    /// **Old and new, side by side**: every position `state` reads through a
    /// pin whose value a refresh would change — what it shows now (its pin,
    /// else the parked value, else `#REF!`) and what its source holds now (nil
    /// when the source is gone). Ordered by cell, then source position.
    public static func compare(state: FigureState, sources: PinSources) -> [PinComparison] {
        let reads = reads(of: state.table, parked: sources.parkedTables)
        let pinned = homePins(state)
        var firstCell: [PinRead: CellKey] = [:]
        for (cell, set) in reads {
            for r in set where firstCell[r].map({ before(cell, $0) }) ?? true { firstCell[r] = cell }
        }
        let readSources = Set(reads.values.flatMap { $0.map(\.source) })
        for (r, pin) in pinned where firstCell[r] == nil && readSources.contains(r.source) {
            firstCell[r] = pin.cell
        }
        var out: [PinComparison] = []
        for (r, cell) in firstCell {
            let old: CellValue
            if let pin = pinned[r] {
                old = pin.pin.value
            } else if let parked = sources.parked[r.source] {
                old = parked.parkedValues.value(row: r.row, column: r.column) ?? .error(.ref)
            } else {
                old = .error(.ref)
            }
            let new: CellValue?
            if let parked = sources.parked[r.source] {
                new = parked.copy.map { $0.value(row: r.row, column: r.column) ?? .error(.ref) }
            } else {
                new = sources.research[r.source].map { $0.value(row: r.row, column: r.column) ?? .error(.ref) }
            }
            if new != old { out.append(PinComparison(cell: cell, read: r, old: old, new: new)) }
        }
        return out.sorted { a, b in
            a.cell != b.cell ? before(a.cell, b.cell) : order(a.read, b.read)
        }
    }

    /// **What a refresh writes** (spec §4.3): every position `state`'s formulas
    /// read through a pin, and every pin it holds on a source they read,
    /// re-read from the source as it is now and pinned on the cell — only
    /// where the pin would differ (its value or the hash it was read from).
    /// A source that is gone is left, its kept values standing. A parked
    /// figure whose copy is unchanged (`current`) needs no pin: its readers
    /// read its parked state. Ordered by cell, then source position.
    public static func refresh(state: FigureState, sources: PinSources, at now: Date) -> [PinWrite] {
        let status = status(of: state, sources: sources)
        var wanted = reads(of: state.table, parked: sources.parkedTables)
        for (cell, list) in state.pins {
            for pin in list where status[pin.research] != nil {
                wanted[cell, default: []].insert(PinRead(source: pin.research, row: pin.row, column: pin.column))
            }
        }
        var out: [PinWrite] = []
        for (cell, set) in wanted {
            for r in set {
                let read: PinSourceRead?
                if let parked = sources.parked[r.source] {
                    guard status[r.source] != .current else { continue }
                    read = parked.copy
                } else {
                    read = sources.research[r.source]
                }
                guard let read else { continue }
                if let write = write(r, on: cell, of: state, from: read, at: now) { out.append(write) }
            }
        }
        return out.sorted { a, b in
            a.cell != b.cell ? before(a.cell, b.cell) : order(read(a.pin), read(b.pin))
        }
    }

    /// **The pins entering `formula` in `cell` takes** (spec §4.3): each
    /// Research position it reads that `cell` holds no pin for — the figure's
    /// own pin on it where another cell holds one, so the figure reads one
    /// value per source cell, else the value read now. A source that is gone
    /// takes none (the ref shows `#REF!` until a refresh). Refs into a parked
    /// figure take none: they read its parked state.
    public static func entry(
        of formula: Formula, in cell: CellKey, state: FigureState, research: [String: PinSourceRead], at now: Date
    ) -> [PinWrite] {
        let reads = reads(of: formula, in: state.table, parked: [:])
        let pinned = homePins(state)
        var out: [PinWrite] = []
        for r in reads {
            if state.pins[cell]?.contains(where: { read($0) == r }) == true { continue }
            if let held = pinned[r] {
                out.append(PinWrite(cell: cell, pin: held.pin, prior: nil))
            } else if let source = research[r.source] {
                let value = source.value(row: r.row, column: r.column) ?? .error(.ref)
                out.append(PinWrite(cell: cell, pin: pin(r, value, source.hash, now), prior: nil))
            }
        }
        return out.sorted { order(read($0.pin), read($1.pin)) }
    }

    // MARK: - Helpers

    private static func write(
        _ r: PinRead, on cell: CellKey, of state: FigureState, from source: PinSourceRead, at now: Date
    ) -> PinWrite? {
        let value = source.value(row: r.row, column: r.column) ?? .error(.ref)
        let prior = state.pins[cell]?.first { read($0) == r }
        if let prior, prior.value == value, prior.sourceHash == source.hash { return nil }
        return PinWrite(cell: cell, pin: pin(r, value, source.hash, now), prior: prior)
    }

    /// A new pin, its time to the whole second: the op log keeps milliseconds,
    /// so a pin read back from it equals the one written (a ⌘Z's drift guard
    /// compares them).
    private static func pin(_ r: PinRead, _ value: CellValue, _ hash: String, _ at: Date) -> FigureResearchPin {
        FigureResearchPin(research: r.source, row: r.row, column: r.column, value: value, sourceHash: hash,
                          at: Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.down)))
    }

    private static func read(_ pin: FigureResearchPin) -> PinRead {
        PinRead(source: pin.research, row: pin.row, column: pin.column)
    }

    /// The figure's pin on each source cell, as `FigurePinIndex` reads it (the
    /// later-taken where two cells hold one), with a cell holding it.
    private static func homePins(_ state: FigureState) -> [PinRead: (pin: FigureResearchPin, cell: CellKey)] {
        var out: [PinRead: (pin: FigureResearchPin, cell: CellKey)] = [:]
        for (cell, list) in state.pins {
            for pin in list {
                let r = read(pin)
                if let held = out[r], held.pin.at > pin.at || (held.pin.at == pin.at && !before(cell, held.cell)) { continue }
                out[r] = (pin, cell)
            }
        }
        return out
    }

    private static func before(_ a: CellKey, _ b: CellKey) -> Bool {
        (a.row.raw, a.column.raw) < (b.row.raw, b.column.raw)
    }

    private static func order(_ a: PinRead, _ b: PinRead) -> Bool {
        (a.source, a.row, a.column) < (b.source, b.row, b.column)
    }
}

/// Walks a formula for what it reads through a pin, as `Workbook` resolves it.
private struct Collector {
    let home: FigureTable
    let parked: [String: FigureTable]

    func collect(_ e: FormulaExpr, into out: inout Set<PinRead>) {
        switch e {
        case .number, .text, .bool, .missing, .error: return
        case .ref(let r): add(FormulaRange(start: r, end: r), into: &out)
        case .range(let g): add(g, into: &out)
        case .unary(_, let x): collect(x, into: &out)
        case .binary(_, let l, let r): collect(l, into: &out); collect(r, into: &out)
        case .call(let name, let arguments):
            for a in arguments { collect(a, into: &out) }
            guard FormulaFunctions.all[name]?.resizesThirdToFirst == true, arguments.count == 3,
                  let shape = shape(arguments[0]), let block = asRange(arguments[2]),
                  let (source, rows, columns) = positions(block), let topRow = rows.first, let topColumn = columns.first
            else { return }
            for r in topRow..<(topRow + shape.rows) {
                for c in topColumn..<(topColumn + shape.columns) { out.insert(PinRead(source: source, row: r, column: c)) }
            }
        }
    }

    private func add(_ g: FormulaRange, into out: inout Set<PinRead>) {
        guard let (source, rows, columns) = positions(g) else { return }
        for r in rows { for c in columns { out.insert(PinRead(source: source, row: r, column: c)) } }
    }

    /// A range's source and the live positions it covers in it, when it reads
    /// a Research table or a parked figure; nil otherwise.
    private func positions(_ g: FormulaRange) -> (String, [Int], [Int])? {
        switch g.start.target {
        case .this: return nil
        case .research(let id):
            guard case .position(let r0, let c0) = g.start.anchor, case .position(let r1, let c1) = g.end.anchor,
                  min(r0, r1) >= 0, min(c0, c1) >= 0 else { return nil }
            return (id, Array(min(r0, r1)...max(r0, r1)), Array(min(c0, c1)...max(c0, c1)))
        case .figure(let id):
            guard let table = parked[id], let (rows, columns) = Self.live(g, in: table) else { return nil }
            return (id, rows, columns)
        }
    }

    /// A range's live positions in `table` (id anchors by slot, as `Workbook`).
    private static func live(_ g: FormulaRange, in table: FigureTable) -> ([Int], [Int])? {
        switch (g.start.anchor, g.end.anchor) {
        case let (.id(r0, c0), .id(r1, c1)):
            guard let rs0 = table.rowSlotIndex(of: r0), let rs1 = table.rowSlotIndex(of: r1),
                  let cs0 = table.columnSlotIndex(of: c0), let cs1 = table.columnSlotIndex(of: c1) else { return nil }
            let rows = table.liveRows(betweenSlots: rs0, rs1).compactMap { table.rowIndex(of: $0) }
            let columns = table.liveColumns(betweenSlots: cs0, cs1).compactMap { table.columnIndex(of: $0) }
            return rows.isEmpty || columns.isEmpty ? nil : (rows, columns)
        case let (.position(r0, c0), .position(r1, c1)):
            let rows = (min(r0, r1)...max(r0, r1)).filter { $0 >= 0 && $0 < table.rows.count }
            let columns = (min(c0, c1)...max(c0, c1)).filter { $0 >= 0 && $0 < table.columns.count }
            return rows.isEmpty || columns.isEmpty ? nil : (rows, columns)
        default:
            return nil
        }
    }

    private func asRange(_ e: FormulaExpr) -> FormulaRange? {
        switch e {
        case .ref(let r): return FormulaRange(start: r, end: r)
        case .range(let g): return g
        default: return nil
        }
    }

    /// The criteria range's shape, as the evaluator sees it.
    private func shape(_ e: FormulaExpr) -> (rows: Int, columns: Int)? {
        switch e {
        case .ref: return (1, 1)
        case .range(let g):
            switch g.start.target {
            case .this: return Self.live(g, in: home).map { ($0.0.count, $0.1.count) }
            case .research, .figure: return positions(g).map { ($0.1.count, $0.2.count) }
            }
        default: return nil
        }
    }
}
