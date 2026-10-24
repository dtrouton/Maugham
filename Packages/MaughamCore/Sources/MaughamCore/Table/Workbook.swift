import Foundation

/// Where research refs read: the value pinned for one research cell.
public protocol ResearchPinSource: Sendable {
    /// The pinned value of a research cell (0-based position), or nil when no pin exists (→ #REF!).
    func pinnedValue(research name: String, row: Int, column: Int) -> CellValue?
}

/// A note the editor shows beside a formula without changing its value.
public enum FormulaNote: Hashable, Sendable {
    /// Spec §5: an `NPV` whose first value is negative — Excel discounts it one period.
    case npvFirstFlowDiscounted(CellAddress)
}

/// A document's figure tables evaluated together: refs between tables are live, research
/// refs read pins, and an edit recalculates only the cells that read what changed, in
/// dependency order. A reference cycle is `#CIRC!` on every cell in it; a cell that reads
/// it sees that error as any other (IFERROR catches it). Dependencies are static (both branches of an `IF` count), as in Excel.
public struct Workbook: Sendable {
    public private(set) var tables: [String: FigureTable] = [:]
    /// Test seam: how many formula cells the last `setTable`/`pinsChanged` evaluated.
    public private(set) var lastEvaluationCount = 0

    private let pins: any ResearchPinSource
    private var formulas: [CellAddress: Formula] = [:]
    private var values: [CellAddress: CellValue] = [:]          // formula cells' results
    private var graph = DependencyGraph()
    private var tablesRead: [CellAddress: Set<String>] = [:]     // formula → table names it names
    private var tableReaders: [String: Set<CellAddress>] = [:]
    private var researchRead: [CellAddress: Set<String>] = [:]   // formula → research items it reads directly
    private var researchReadersIndex: [String: Set<CellAddress>] = [:]
    private var npvNoted: Set<CellAddress> = []

    public init(pins: ResearchPinSource) { self.pins = pins }

    public var notes: Set<FormulaNote> { Set(npvNoted.map { .npvFirstFlowDiscounted($0) }) }

    /// `.empty` for a missing cell or table.
    public func value(at address: CellAddress) -> CellValue {
        if let v = values[address] { return v }
        guard let cell = tables[address.table]?[address.key], case .value(let v) = cell.content else { return .empty }
        return v
    }

    /// Adds, replaces or (nil) removes a table, recalculating what changed. Returns every address whose VALUE changed.
    @discardableResult
    public mutating func setTable(_ table: FigureTable?, named name: String) -> Set<CellAddress> {
        let old = tables[name]
        let oldCells = old?.cells ?? [:], newCells = table?.cells ?? [:]
        var changed = [CellAddress]()
        for (k, c) in oldCells where newCells[k]?.content != c.content { changed.append(CellAddress(table: name, key: k)) }
        for k in newCells.keys where oldCells[k] == nil { changed.append(CellAddress(table: name, key: k)) }
        let structural = old?.rowSlots != table?.rowSlots || old?.columnSlots != table?.columnSlots

        var before = [CellAddress: CellValue]()
        for a in changed { before[a] = value(at: a) }

        tables[name] = table

        var resolve = Set<CellAddress>()
        for a in changed {
            if formulas[a] != nil { purge(a) }
            if case .formula(let f)? = newCells[a.key]?.content {
                formulas[a] = f
                resolve.insert(a)
            }
        }
        // Rows or columns moved, came or went: re-resolve everything that names this table.
        if structural { resolve.formUnion(tableReaders[name] ?? []) }
        for a in resolve { self.resolve(a) }

        return recalculate(seeds: Set(changed).union(resolve), before: &before)
    }

    /// After plan 6 refreshes pins: recalculates every cell that reads the named research item.
    @discardableResult
    public mutating func pinsChanged(research name: String) -> Set<CellAddress> {
        var before = [CellAddress: CellValue]()
        return recalculate(seeds: researchReadersIndex[name] ?? [], before: &before)
    }

    /// Which cells read which research items, directly or through another table (spec §4.3's markers).
    public func researchReaders() -> [CellAddress: Set<String>] {
        var out = [CellAddress: Set<String>]()
        for (name, direct) in researchReadersIndex {
            for a in graph.closure(from: direct) where formulas[a] != nil { out[a, default: []].insert(name) }
        }
        return out
    }

    /// Every table whose formulas read `name`, directly or through another table, never
    /// `name` itself: what must re-render when `name` changes. A table naming a figure not
    /// (yet) in the workbook counts, so it re-renders when that figure arrives.
    public func tablesReading(_ name: String) -> Set<String> {
        var found = Set<String>()
        var queue = [name]
        while let next = queue.popLast() {
            for reader in tableReaders[next] ?? [] where reader.table != name && !found.contains(reader.table) {
                found.insert(reader.table)
                queue.append(reader.table)
            }
        }
        return found
    }

    // MARK: - Recalculation

    private mutating func recalculate(seeds: Set<CellAddress>, before: inout [CellAddress: CellValue]) -> Set<CellAddress> {
        let dirty = graph.closure(from: seeds).filter { formulas[$0] != nil }
        for a in dirty where before[a] == nil { before[a] = value(at: a) }
        for component in graph.components(of: dirty) {
            if component.cyclic {
                for a in component.members { markCircular(a) }
                continue
            }
            // A cell reading a cycle sees #CIRC! as an ordinary error: it propagates through
            // arithmetic, IFERROR catches it and COUNT ignores it (R-P5-12).
            let a = component.members[0]
            let (v, noted) = evaluate(a)
            values[a] = v
            if noted { npvNoted.insert(a) } else { npvNoted.remove(a) }
        }
        lastEvaluationCount = dirty.count
        return Set(before.compactMap { value(at: $0.key) != $0.value ? $0.key : nil })
    }

    private mutating func markCircular(_ a: CellAddress) {
        values[a] = .error(.circular)
        npvNoted.remove(a)
    }

    /// Forgets a formula cell that no longer holds that formula.
    private mutating func purge(_ a: CellAddress) {
        graph.removePrecedents(of: a)
        for t in tablesRead.removeValue(forKey: a) ?? [] { Self.remove(a, from: t, in: &tableReaders) }
        for r in researchRead.removeValue(forKey: a) ?? [] { Self.remove(a, from: r, in: &researchReadersIndex) }
        formulas[a] = nil
        values[a] = nil
        npvNoted.remove(a)
    }

    private static func remove(_ a: CellAddress, from key: String, in index: inout [String: Set<CellAddress>]) {
        index[key]?.remove(a)
        if index[key]?.isEmpty == true { index[key] = nil }
    }

    /// Recomputes which cells, tables and research items a formula reads.
    private mutating func resolve(_ a: CellAddress) {
        guard let f = formulas[a] else { return }
        var reads = References()
        resolver(home: a.table).collect(f.expr, into: &reads)
        graph.setPrecedents(reads.cells, of: a)
        for t in tablesRead[a] ?? [] where !reads.tables.contains(t) { Self.remove(a, from: t, in: &tableReaders) }
        for t in reads.tables { tableReaders[t, default: []].insert(a) }
        tablesRead[a] = reads.tables.isEmpty ? nil : reads.tables
        for r in researchRead[a] ?? [] where !reads.research.contains(r) { Self.remove(a, from: r, in: &researchReadersIndex) }
        for r in reads.research { researchReadersIndex[r, default: []].insert(a) }
        researchRead[a] = reads.research.isEmpty ? nil : reads.research
    }

    private func resolver(home: String) -> WorkbookResolver {
        WorkbookResolver(tables: tables, home: home)
    }

    /// The formula's value and whether it carries the NPV first-flow note.
    private func evaluate(_ a: CellAddress) -> (CellValue, Bool) {
        guard let f = formulas[a] else { return (.empty, false) }
        let env = environment(home: a.table)
        return (FormulaEvaluator.evaluate(f, in: env), Self.hasNegativeFirstFlow(f.expr, env))
    }

    private func environment(home: String) -> FormulaEnvironment {
        let resolver = self.resolver(home: home)
        let values = self.values, tables = self.tables, pins = self.pins
        @Sendable func read(_ a: CellAddress) -> CellValue {
            if let v = values[a] { return v }
            guard let cell = tables[a.table]?[a.key], case .value(let v) = cell.content else { return .empty }
            return v
        }
        @Sendable func pinned(_ name: String, _ rows: ClosedRange<Int>, _ columns: ClosedRange<Int>) -> [[CellValue]]? {
            var out = [[CellValue]]()
            for r in rows {
                var line = [CellValue]()
                for c in columns {
                    guard let v = pins.pinnedValue(research: name, row: r, column: c) else { return nil }
                    line.append(v)
                }
                out.append(line)
            }
            return out
        }
        return FormulaEnvironment(
            cell: { ref in
                if case .research(let name) = ref.target {
                    guard case .position(let r, let c) = ref.anchor else { return .error(.ref) }
                    return pins.pinnedValue(research: name, row: r, column: c) ?? .error(.ref)
                }
                return resolver.address(ref).map(read) ?? .error(.ref)
            },
            range: { g in
                if case .research(let name) = g.start.target {
                    guard let (rows, columns) = WorkbookResolver.positions(g) else { return nil }
                    return pinned(name, rows, columns)
                }
                return resolver.cells(g)?.map { $0.map(read) }
            },
            resized: { g, rowCount, columnCount in
                if case .research(let name) = g.start.target {
                    guard rowCount > 0, columnCount > 0, let (rows, columns) = WorkbookResolver.positions(g) else { return nil }
                    return pinned(name, rows.lowerBound...(rows.lowerBound + rowCount - 1),
                                  columns.lowerBound...(columns.lowerBound + columnCount - 1))
                }
                return resolver.block(g, rows: rowCount, columns: columnCount)?.map { $0.map(read) }
            })
    }

    /// Spec §5's amber note: some `NPV` in the formula whose first value argument is a range
    /// starting (by its first counted number) negative, or a negative literal or reference.
    private static func hasNegativeFirstFlow(_ e: FormulaExpr, _ env: FormulaEnvironment) -> Bool {
        switch e {
        case .number, .text, .bool, .missing, .error, .ref, .range: return false
        case .unary(_, let x): return hasNegativeFirstFlow(x, env)
        case .binary(_, let l, let r): return hasNegativeFirstFlow(l, env) || hasNegativeFirstFlow(r, env)
        case .call(let name, let arguments):
            if name == "NPV", arguments.count >= 2, firstFlowIsNegative(arguments[1], env) { return true }
            return arguments.contains { hasNegativeFirstFlow($0, env) }
        }
    }

    private static func firstFlowIsNegative(_ e: FormulaExpr, _ env: FormulaEnvironment) -> Bool {
        switch e {
        case .range(let g):
            for row in env.range(g) ?? [] {
                for v in row {
                    switch v {
                    case .number(let x): return x < 0
                    case .date(let d): return d < 0
                    default: continue
                    }
                }
            }
            return false
        case .number, .ref, .unary(.negate, _), .unary(.plus, _):
            if case .number(let x) = FormulaEvaluator.scalar(e, env) { return x < 0 }
            return false
        default:
            return false
        }
    }
}

// MARK: - Resolution

/// What a formula reads: cells (for the dependency graph), table names (re-resolved on a
/// structural change or when the table comes or goes) and research items.
private struct References {
    var cells = Set<CellAddress>()
    var tables = Set<String>()
    var research = Set<String>()
}

/// Turns a formula's refs into workbook addresses, the same way for dependencies and for
/// evaluation, through the table's own O(1) id lookups. Id ranges go through `FigureTable.liveRows/liveColumns(betweenSlots:)`, the
/// one range definition rendering also uses, so a deleted edge shrinks the range.
private struct WorkbookResolver: Sendable {
    let tables: [String: FigureTable]
    let home: String

    func tableName(_ target: RefTarget) -> String? {
        switch target {
        case .this: return home
        case .figure(let name): return name
        case .research: return nil
        }
    }

    /// A single ref's cell; nil (`#REF!`) for a missing table, a tombstone or off-grid.
    func address(_ ref: FormulaRef) -> CellAddress? {
        guard let name = tableName(ref.target), let table = tables[name] else { return nil }
        switch ref.anchor {
        case .id(let row, let column):
            guard table.rowIndex(of: row) != nil, table.columnIndex(of: column) != nil else { return nil }
            return CellAddress(table: name, key: CellKey(row: row, column: column))
        case .position(let row, let column):
            let rows = table.rows, columns = table.columns
            guard rows.indices.contains(row), columns.indices.contains(column) else { return nil }
            return CellAddress(table: name, key: CellKey(row: rows[row], column: columns[column]))
        }
    }

    /// A range's live cells row by row; nil (`#REF!`) when nothing between its edges is live.
    func cells(_ g: FormulaRange) -> [[CellAddress]]? {
        guard let name = tableName(g.start.target), let table = tables[name] else { return nil }
        let rows: [RowID], columns: [ColumnID]
        switch (g.start.anchor, g.end.anchor) {
        case let (.id(r0, c0), .id(r1, c1)):
            guard let rs0 = table.rowSlotIndex(of: r0), let rs1 = table.rowSlotIndex(of: r1),
                  let cs0 = table.columnSlotIndex(of: c0), let cs1 = table.columnSlotIndex(of: c1) else { return nil }
            rows = table.liveRows(betweenSlots: rs0, rs1)
            columns = table.liveColumns(betweenSlots: cs0, cs1)
        case (.position, .position):
            let live = table.rows, liveColumns = table.columns
            guard let (rr, cr) = Self.positions(g),
                  rr.upperBound < live.count, cr.upperBound < liveColumns.count else { return nil }
            rows = Array(live[rr])
            columns = Array(liveColumns[cr])
        default:
            return nil
        }
        guard !rows.isEmpty, !columns.isEmpty else { return nil }
        return rows.map { r in columns.map { c in CellAddress(table: name, key: CellKey(row: r, column: c)) } }
    }

    /// The `rows`×`columns` block from the range's live top-left (SUMIF's sum range); nil off-grid.
    func block(_ g: FormulaRange, rows rowCount: Int, columns columnCount: Int) -> [[CellAddress]]? {
        guard rowCount > 0, columnCount > 0, let name = tableName(g.start.target), let table = tables[name],
              let topLeft = cells(g)?.first?.first,
              let r0 = table.rowIndex(of: topLeft.key.row), let c0 = table.columnIndex(of: topLeft.key.column) else { return nil }
        let rows = table.rows, columns = table.columns
        guard r0 + rowCount <= rows.count, c0 + columnCount <= columns.count else { return nil }
        return rows[r0..<(r0 + rowCount)].map { r in
            columns[c0..<(c0 + columnCount)].map { c in CellAddress(table: name, key: CellKey(row: r, column: c)) }
        }
    }

    /// A positional range's row and column spans, normalised; nil unless both edges are positional.
    static func positions(_ g: FormulaRange) -> (ClosedRange<Int>, ClosedRange<Int>)? {
        guard case .position(let r0, let c0) = g.start.anchor, case .position(let r1, let c1) = g.end.anchor,
              min(r0, r1) >= 0, min(c0, c1) >= 0 else { return nil }
        return (min(r0, r1)...max(r0, r1), min(c0, c1)...max(c0, c1))
    }

    /// Everything `e` reads, statically: both branches of an `IF`, every live cell of a
    /// range, and SUMIF's resized sum range. Recursion follows the tree (`maxDepth`-bounded).
    func collect(_ e: FormulaExpr, into reads: inout References) {
        switch e {
        case .number, .text, .bool, .missing, .error: return
        case .ref(let r): collect(FormulaRange(start: r, end: r), single: true, into: &reads)
        case .range(let g): collect(g, single: false, into: &reads)
        case .unary(_, let x): collect(x, into: &reads)
        case .binary(_, let l, let r): collect(l, into: &reads); collect(r, into: &reads)
        case .call(let name, let arguments):
            for a in arguments { collect(a, into: &reads) }
            guard FormulaFunctions.all[name]?.resizesThirdToFirst == true, arguments.count == 3,
                  let shape = shape(arguments[0]), let block = asRange(arguments[2]),
                  let blockTable = tableName(block.start.target) else { return }
            reads.tables.insert(blockTable)
            for row in self.block(block, rows: shape.rows, columns: shape.columns) ?? [] { reads.cells.formUnion(row) }
        }
    }

    private func collect(_ g: FormulaRange, single: Bool, into reads: inout References) {
        if case .research(let name) = g.start.target { reads.research.insert(name); return }
        guard let name = tableName(g.start.target) else { return }
        reads.tables.insert(name)
        if single {
            if let a = address(g.start) { reads.cells.insert(a) }
        } else {
            for row in cells(g) ?? [] { reads.cells.formUnion(row) }
        }
    }

    private func asRange(_ e: FormulaExpr) -> FormulaRange? {
        switch e {
        case .ref(let r): return FormulaRange(start: r, end: r)
        case .range(let g): return g
        default: return nil
        }
    }

    /// The criteria range's shape, as the evaluator will see it.
    private func shape(_ e: FormulaExpr) -> (rows: Int, columns: Int)? {
        switch e {
        case .ref: return (1, 1)
        case .range(let g):
            if case .research = g.start.target {
                guard let (r, c) = Self.positions(g) else { return nil }
                return (r.count, c.count)
            }
            guard let cells = cells(g) else { return nil }
            return (cells.count, cells[0].count)
        default: return nil
        }
    }
}
