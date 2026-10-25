import Foundation

/// **Where one source a figure's pins read stands** (spec §4.3, report plan 6b
/// Task 9) — a Research table, or a figure parked in Research (R-D2). For
/// plans 7–9's markers and publish notes; no surface reads it yet.
/// - `current`: every pin on it was taken from the bytes it holds now.
/// - `sourceChanged`: its content hash is no longer the one a pin recorded —
///   for a parked figure read without a pin, the one its park recorded.
/// - `sourceMissing`: the Research item, or the parked figure's working copy,
///   is gone. The kept values stay; nothing is cleared.
/// - `unpinned`: a formula reads a Research table at a position no pin holds
///   (one that came in with *Use in document* or a return before it could be
///   pinned, or whose pin was never written), so that cell shows `#REF!`; a
///   refresh pins it from `new`, the table's content hash now. Reported only
///   where no pin is stale (`sourceChanged` says the same, and more).
public enum PinStatus: Equatable, Sendable {
    case current
    case sourceChanged(old: String, new: String)
    case sourceMissing
    case unpinned(new: String)
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
    /// Every table in the book, by figure id — read only for a range's SHAPE
    /// (SUMIF's criteria over a live figure sizes its sum block), never for a
    /// value: an unpinned Research cell is `#REF!`, not a live read.
    public var tables: [String: FigureTable]

    public init(research: [String: PinSourceRead] = [:], parked: [String: Parked] = [:],
                tables: [String: FigureTable] = [:]) {
        self.research = research
        self.parked = parked
        self.tables = tables
    }

    var parkedTables: [String: FigureTable] { parked.mapValues(\.table) }
    /// Each parked figure's current park cycle (`FigureParking.cycle`).
    public var parks: [String: String] { parked.mapValues(\.parking.cycle) }
}

extension FigureParking {
    /// **This park's cycle** — what a pin taken on it records
    /// (`FigureResearchPin.park`): the working copy's Research item id, which
    /// every send mints afresh, else the copy's content hash.
    public var cycle: String { itemId ?? hash }
}

/// **Which pin counts, and which wins** — the one rule, for the workbook's
/// index (`FigurePinIndex`) and for status, Compare, Refresh and entry
/// (`FigurePins`), so the value shown, the render and "old" never disagree.
public enum FigurePinChoice {
    /// A pin counts unless its source is a figure parked now under another
    /// park cycle: a pin from an earlier park is inert (no op clears it).
    public static func isLive(_ pin: FigureResearchPin, parks: [String: String]) -> Bool {
        guard let current = parks[pin.research] else { return true }
        return pin.park == current
    }

    /// Does `a` (on cell `aCell`) win over `b` (on `bCell`)? A total order:
    /// the later `at`, then the earlier cell key, then the greater source hash.
    public static func wins(_ a: FigureResearchPin, on aCell: CellKey,
                            over b: FigureResearchPin, on bCell: CellKey) -> Bool {
        if a.at != b.at { return a.at > b.at }
        let ak = (aCell.row.raw, aCell.column.raw), bk = (bCell.row.raw, bCell.column.raw)
        if ak != bk { return ak < bk }
        return a.sourceHash > b.sourceHash
    }

    /// The figure's winning live pin on each source cell, with a cell holding it.
    public static func winners(
        _ pins: [CellKey: [FigureResearchPin]], parks: [String: String]
    ) -> [PinRead: (pin: FigureResearchPin, cell: CellKey)] {
        var out: [PinRead: (pin: FigureResearchPin, cell: CellKey)] = [:]
        for (cell, list) in pins {
            for pin in list where isLive(pin, parks: parks) {
                let r = PinRead(source: pin.research, row: pin.row, column: pin.column)
                if let held = out[r], !wins(pin, on: cell, over: held.pin, on: held.cell) { continue }
                out[r] = (pin, cell)
            }
        }
        return out
    }
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
/// sources (`PinSources`) and appends what this answers. A pin from an
/// earlier park of a figure is inert throughout (`FigurePinChoice`).
public enum FigurePins {

    // MARK: What is read

    /// What each formula cell of `table` reads through a pin: positions in
    /// Research tables, and in figures parked in Research (`parked`, by id —
    /// a ref's id anchors become positions in that parked table). `tables`
    /// (the book's) gives only a live figure's range shape.
    public static func reads(
        of table: FigureTable, parked: [String: FigureTable], tables: [String: FigureTable] = [:]
    ) -> [CellKey: Set<PinRead>] {
        var out: [CellKey: Set<PinRead>] = [:]
        for (key, cell) in table.cells {
            guard case .formula(let f) = cell.content else { continue }
            let reads = reads(of: f, in: table, parked: parked, tables: tables)
            if !reads.isEmpty { out[key] = reads }
        }
        return out
    }

    /// What one formula written in `table` reads through a pin: each single
    /// ref, every cell of a range, and SUMIF's resized sum block.
    public static func reads(
        of formula: Formula, in table: FigureTable, parked: [String: FigureTable], tables: [String: FigureTable] = [:]
    ) -> Set<PinRead> {
        var out = Set<PinRead>()
        Collector(home: table, parked: parked, tables: tables).collect(formula.expr, into: &out)
        return out
    }

    private static func reads(of state: FigureState, _ sources: PinSources) -> [CellKey: Set<PinRead>] {
        reads(of: state.table, parked: sources.parkedTables, tables: sources.tables)
    }

    // MARK: Where each source stands

    /// Each source `state`'s formulas read through a pin, and where it stands.
    /// A pin on a source no formula reads any more counts for nothing.
    public static func status(of state: FigureState, sources: PinSources) -> [String: PinStatus] {
        let reads = reads(of: state, sources)
        let read = Set(reads.values.flatMap { $0 })
        let parks = sources.parks
        let pinned = FigurePinChoice.winners(state.pins, parks: parks)
        let live = state.pins.values.flatMap { $0 }.filter { FigurePinChoice.isLive($0, parks: parks) }
        var out: [String: PinStatus] = [:]
        for source in Set(read.map(\.source)) {
            let pins = live.filter { $0.research == source }
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
                } else if read.contains(where: { $0.source == source && pinned[$0] == nil }) {
                    // Never read live (spec §4.3): an unpinned position is
                    // `#REF!` until a refresh, as the parked branch says.
                    out[source] = .unpinned(new: now.hash)
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
        let reads = reads(of: state, sources)
        let pinned = FigurePinChoice.winners(state.pins, parks: sources.parks)
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
    /// read through a pin, and every live pin it holds on a source they read,
    /// re-read from the source as it is now and pinned on the cell — only
    /// where the pin would differ (its value, the hash it was read from, or
    /// its park cycle). A source that is gone is left, its kept values
    /// standing. A parked figure whose copy is unchanged (`current`) needs no
    /// pin: its readers read its parked state. Ordered by cell, then position.
    public static func refresh(state: FigureState, sources: PinSources, at now: Date) -> [PinWrite] {
        let status = status(of: state, sources: sources)
        let parks = sources.parks
        var wanted = reads(of: state, sources)
        for (cell, list) in state.pins {
            for pin in list where status[pin.research] != nil && FigurePinChoice.isLive(pin, parks: parks) {
                wanted[cell, default: []].insert(read(pin))
            }
        }
        var out: [PinWrite] = []
        for (cell, set) in wanted {
            for r in set {
                let source: PinSourceRead?
                var park: String?
                if let parked = sources.parked[r.source] {
                    guard status[r.source] != .current else { continue }
                    source = parked.copy
                    park = parked.parking.cycle
                } else {
                    source = sources.research[r.source]
                }
                guard let source else { continue }
                if let write = write(r, on: cell, of: state, from: source, park: park, at: now) { out.append(write) }
            }
        }
        return out.sorted { a, b in
            a.cell != b.cell ? before(a.cell, b.cell) : order(read(a.pin), read(b.pin))
        }
    }

    /// **The pins entering `formula` in `cell` takes** (spec §4.3): each
    /// Research position it reads (a SUMIF block sized by its criteria, from
    /// `sources.tables`) that `cell` holds no pin for — the figure's own live
    /// pin on it where another cell holds one, so the figure reads one value
    /// per source cell, else the value read now. A source that is gone takes
    /// none (the ref shows `#REF!` until a refresh). Refs into a parked figure
    /// take none: they read its parked state.
    public static func entry(
        of formula: Formula, in cell: CellKey, state: FigureState, sources: PinSources, at now: Date
    ) -> [PinWrite] {
        let reads = reads(of: formula, in: state.table, parked: sources.parkedTables, tables: sources.tables)
            .filter { sources.parked[$0.source] == nil }
        let pinned = FigurePinChoice.winners(state.pins, parks: sources.parks)
        var out: [PinWrite] = []
        for r in reads {
            if state.pins[cell]?.contains(where: { read($0) == r }) == true { continue }
            if let held = pinned[r] {
                out.append(PinWrite(cell: cell, pin: held.pin, prior: nil))
            } else if let source = sources.research[r.source] {
                let value = source.value(row: r.row, column: r.column) ?? .error(.ref)
                out.append(PinWrite(cell: cell, pin: pin(r, value, source.hash, nil, now), prior: nil))
            }
        }
        return out.sorted { order(read($0.pin), read($1.pin)) }
    }

    /// **The entry pins every formula cell of `state` takes** (report plan 6b
    /// final review I-1) — what a figure made by *Use in document*, or the
    /// cells a return brings back, take, as `setCell` takes one cell's: each
    /// cell's `entry`, in cell order, each laid onto the state before the
    /// next is asked, so two cells reading one source cell read one value.
    /// `cells` limits it to those cells; nil asks every formula cell.
    public static func entry(
        state: FigureState, cells: Set<CellKey>? = nil, sources: PinSources, at now: Date
    ) -> [PinWrite] {
        var working = state
        var out: [PinWrite] = []
        let keys = working.table.cells.keys
            .filter { cells?.contains($0) ?? true }
            .sorted(by: before)
        for key in keys {
            guard case .formula(let f)? = working.table[key]?.content, readsResearch(f) else { continue }
            for w in entry(of: f, in: key, state: working, sources: sources, at: now) {
                working.pins[w.cell, default: []].append(w.pin)
                out.append(w)
            }
        }
        return out
    }

    /// **Can `formula` read a Research table at all?** — whether it names
    /// one anywhere (a ref, a range, SUMIF's sum block). A syntactic test,
    /// no book needed: the cheap gate before a host gathers `PinSources`.
    /// A ref into a parked figure takes no entry pin, so it does not count.
    public static func readsResearch(_ formula: Formula) -> Bool {
        func walk(_ e: FormulaExpr) -> Bool {
            switch e {
            case .number, .text, .bool, .missing, .error: return false
            case .ref(let r): return isResearch(r.target)
            case .range(let g): return isResearch(g.start.target) || isResearch(g.end.target)
            case .unary(_, let x): return walk(x)
            case .binary(_, let l, let r): return walk(l) || walk(r)
            case .call(_, let arguments): return arguments.contains(where: walk)
            }
        }
        func isResearch(_ t: RefTarget) -> Bool {
            if case .research = t { return true }
            return false
        }
        return walk(formula.expr)
    }

    // MARK: - Helpers

    private static func write(
        _ r: PinRead, on cell: CellKey, of state: FigureState, from source: PinSourceRead, park: String?, at now: Date
    ) -> PinWrite? {
        let value = source.value(row: r.row, column: r.column) ?? .error(.ref)
        let prior = state.pins[cell]?.first { read($0) == r }
        if let prior, prior.value == value, prior.sourceHash == source.hash, prior.park == park { return nil }
        return PinWrite(cell: cell, pin: pin(r, value, source.hash, park, now), prior: prior)
    }

    /// A new pin, its time to the whole second: the op log keeps milliseconds,
    /// so a pin read back from it equals the one written (a ⌘Z's drift guard
    /// compares them).
    private static func pin(_ r: PinRead, _ value: CellValue, _ hash: String, _ park: String?, _ at: Date) -> FigureResearchPin {
        FigureResearchPin(research: r.source, row: r.row, column: r.column, value: value, sourceHash: hash,
                          at: Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.down)), park: park)
    }

    private static func read(_ pin: FigureResearchPin) -> PinRead {
        PinRead(source: pin.research, row: pin.row, column: pin.column)
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
    /// The book's tables: a live figure's range SHAPE only.
    let tables: [String: FigureTable]

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
            case .research: return positions(g).map { ($0.1.count, $0.2.count) }
            case .figure(let id):
                if parked[id] != nil { return positions(g).map { ($0.1.count, $0.2.count) } }
                return tables[id].flatMap { Self.live(g, in: $0) }.map { ($0.0.count, $0.1.count) }
            }
        default: return nil
        }
    }
}
