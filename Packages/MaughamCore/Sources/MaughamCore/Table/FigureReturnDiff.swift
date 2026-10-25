import Foundation

/// **What a changed working copy brings back to its parked figure** (spec §4.2
/// "Coming back", report plan 6b Task 8): the ops that turn the parked figure
/// into what the copy now says, keeping every row and column id the copy still
/// holds. Pure, no I/O, shared by the Mac and the phone (tripwire 19).
///
/// **Three-way** (controller's ruling, Task 8): `base` is the figure as the
/// working copy was written from it, `current` the figure as its stream now
/// says (an edit that sorts before the park but that the parker never read is
/// in `current` and not in `base`). The changes are `base → copy`, applied onto
/// `current`; a cell the copy did not change keeps whatever `current` holds.
///
/// - **Columns** match by header text when `base` has a header row — a
///   longest common subsequence of the headers, then an equal header found out
///   of order (a moved column) — else by position.
/// - **Rows** match by their values over the matched columns: a longest common
///   subsequence, then an equal row found out of order (a moved row), then,
///   between two matched rows, a row whose cells are at least half the same (an
///   edited row). A formula is compared by its shape relative to its own cell,
///   so a row whose formulas Excel re-pointed when a row was inserted above it
///   still matches.
/// - A matched row or column keeps its id and moves if the copy moved it; an
///   unmatched old one is deleted, carrying what it held (ruling P-2; anchors
///   on it are orphaned, §11.5); a new one is inserted with a fresh id from
///   `mintRow`/`mintColumn` (never a tombstoned one, ruling P-1).
/// - **Cells**: a cell the copy changed is set; one it did not is left alone. A
///   copy's formula is compared with the old one by id, then by its text at the
///   copy's positions; a formula the copy could not read only because a figure
///   it names was renamed while parked (`TableCSV.read` kept it as `=…` text)
///   keeps the old formula.
/// - **Formats** come from the sidecar, whose positions are the parked CSV's
///   (pass it only when it was written for those bytes); without one, a matched
///   cell keeps its format and a new cell takes the one its text suggested.
///   Header and total rows and widths likewise.
/// - A cell the copy changed that `current` also changed after `base` — a late
///   edit — takes the copy's value and is listed in `overwritten`, as is a late
///   edit in a row or column the copy deleted.
public enum FigureReturnDiff {

    /// One op to append, in order.
    public struct Change: Equatable, Sendable {
        public let kind: OpKind
        public let payload: FigureOpPayload
    }

    /// What the return appends, and what it says.
    public struct Changes: Equatable, Sendable {
        public var ops: [Change]
        /// Cells a late edit had changed that the copy's change replaced.
        public var overwritten: [CellKey]
        /// The read's problems that still stand: a cell that kept its old
        /// formula is no problem.
        public var problems: [CSVReadProblem]

        /// Nothing to bring back but the resume: an unchanged copy.
        public static let none = Changes(ops: [], overwritten: [], problems: [])
    }

    /// **The state the working copy was written from**: the stream folded only
    /// as far as the parker had read (`FigureParking.frontier`) — for each
    /// device, its ops at or before the last id the parker had folded; a
    /// device the parker had not read contributes none. Never parked.
    public static func base(of ops: [Op], frontier: [String: String]) -> FigureState {
        var state = FigureDeriver.derive(ops.filter { op in
            guard FigureOpPayload.kinds.contains(op.kind), let last = frontier[op.device] else { return false }
            return op.opId <= last
        })
        state.parked = nil
        return state
    }

    /// The two-way return (the brief's shape): `parked` is both the base and
    /// the state the changes land on.
    public static func ops(
        from parked: FigureState, to copy: FigureTable, sidecar: ResearchTableSidecar?,
        mintRow: () -> RowID, mintColumn: () -> ColumnID
    ) -> [(OpKind, FigureOpPayload)] {
        changes(from: parked, onto: parked, to: copy, sidecar: sidecar,
                mintRow: mintRow, mintColumn: mintColumn).ops.map { ($0.kind, $0.payload) }
    }

    /// The three-way return. `copy` is `TableCSV.read`'s table (its own ids),
    /// `problems` that read's problems, and `names` the book's name directory
    /// the read used.
    public static func changes(
        from base: FigureState, onto current: FigureState, to copy: FigureTable,
        sidecar: ResearchTableSidecar?, names: FormulaNames = .empty, problems: [CSVReadProblem] = [],
        mintRow: () -> RowID, mintColumn: () -> ColumnID
    ) -> Changes {
        var base = base
        base.parked = nil
        var sim = Simulation(state: current)

        // MARK: Matching
        let columnPairs = matchColumns(base: base.table, copy: copy)
        let rowPairs = matchRows(base: base.table, copy: copy, columns: columnPairs)
        let copyRows = copy.rows, copyColumns = copy.columns
        var columnFor: [ColumnID: ColumnID] = [:]   // copy id → result id
        var rowFor: [RowID: RowID] = [:]
        for (b, c) in columnPairs { columnFor[copyColumns[c]] = base.table.columns[b] }
        for (b, c) in rowPairs { rowFor[copyRows[c]] = base.table.rows[b] }
        func freshRow() -> RowID {
            var id = mintRow()
            while sim.state.table.rowSlotIndex(of: id) != nil || base.table.rowSlotIndex(of: id) != nil { id = mintRow() }
            return id
        }
        func freshColumn() -> ColumnID {
            var id = mintColumn()
            while sim.state.table.columnSlotIndex(of: id) != nil || base.table.columnSlotIndex(of: id) != nil {
                id = mintColumn()
            }
            return id
        }
        for id in copyColumns where columnFor[id] == nil { columnFor[id] = freshColumn() }
        for id in copyRows where rowFor[id] == nil { rowFor[id] = freshRow() }
        let matchedBaseColumns = Set(columnPairs.map { base.table.columns[$0.0] })
        let matchedBaseRows = Set(rowPairs.map { base.table.rows[$0.0] })
        var overwritten: [CellKey] = []

        // MARK: Structure — deletes, then each axis placed in the copy's order
        for id in base.table.columns where !matchedBaseColumns.contains(id) && sim.isLive(id) {
            overwritten += sim.lateEdits(inColumn: id, base: base)
            sim.emit(.figureStructure, FigureOpPayload(
                structure: .deleteColumn(id), removed: sim.state.removedSlice(column: id)))
        }
        let pairedCopyColumns = Set(columnPairs.map { copyColumns[$0.1] })
        place(copyColumns.map { columnFor[$0]! },
              fresh: Set(copyColumns.filter { !pairedCopyColumns.contains($0) }.map { columnFor[$0]! }), in: &sim)
        for id in base.table.rows where !matchedBaseRows.contains(id) && sim.isLive(id) {
            overwritten += sim.lateEdits(inRow: id, base: base)
            sim.emit(.figureStructure, FigureOpPayload(
                structure: .deleteRow(id), removed: sim.state.removedSlice(row: id)))
        }
        let pairedCopyRows = Set(rowPairs.map { copyRows[$0.1] })
        place(copyRows.map { rowFor[$0]! },
              fresh: Set(copyRows.filter { !pairedCopyRows.contains($0) }.map { rowFor[$0]! }), in: &sim)

        // MARK: Cells
        let toResult = IDMap(rows: rowFor, columns: columnFor)
        var toCopy = IDMap(rows: [:], columns: [:])
        for (copyId, resultId) in rowFor { toCopy.rows[resultId] = copyId }
        for (copyId, resultId) in columnFor { toCopy.columns[resultId] = copyId }
        var styles: [Position: ResearchTableSidecar.CellStyle] = [:]
        for style in sidecar?.formats ?? [] { styles[Position(row: style.row, column: style.column)] = style }
        var kept: Set<Position> = []

        for (r, copyRow) in copyRows.enumerated() {
            let row = rowFor[copyRow]!
            guard sim.isLive(row) else { continue }   // deleted late: the delete stands
            for (c, copyColumn) in copyColumns.enumerated() {
                let column = columnFor[copyColumn]!
                guard sim.isLive(column) else { continue }
                let key = CellKey(row: row, column: column)
                let old = base.table[key]
                let ours = copy[CellKey(row: copyRow, column: copyColumn)]
                var target: Cell?
                if let ours {
                    var cell = ours
                    if let old, sameContent(ours.content, old.content, toResult: toResult, toCopy: toCopy,
                                            copy: copy, names: names) {
                        cell.content = old.content
                        if case .value(.text) = ours.content, case .formula = old.content {
                            kept.insert(Position(row: r, column: c))
                        }
                    } else {
                        cell.content = toResult.content(ours.content)
                    }
                    if let old {
                        if sidecar != nil, let br = base.table.rowIndex(of: row), let bc = base.table.columnIndex(of: column) {
                            let style = styles[Position(row: br, column: bc)]
                            cell.format = style?.format ?? CellFormat()
                            cell.alignment = style?.alignment ?? .automatic
                        } else {
                            cell.format = old.format
                            cell.alignment = old.alignment
                        }
                    }
                    target = cell
                }
                guard target != old else { continue }   // the copy left it alone
                let now = sim.state.table[key]
                guard target != now else { continue }
                if now != old { overwritten.append(key) }
                sim.emit(.figureCellSet, FigureOpPayload(cell: key, next: target, prior: now))
            }
        }

        // MARK: Settings
        if let sidecar {
            if sidecar.headerRows != base.table.headerRows, sim.state.table.headerRows != sidecar.headerRows {
                sim.emit(.figureSettings, FigureOpPayload(
                    settings: .headerRows(sidecar.headerRows, prior: sim.state.table.headerRows)))
            }
            if sidecar.totalRow != base.table.hasTotalRow, sim.state.table.hasTotalRow != sidecar.totalRow {
                sim.emit(.figureSettings, FigureOpPayload(
                    settings: .totalRow(sidecar.totalRow, prior: sim.state.table.hasTotalRow)))
            }
            for (p, column) in base.table.columns.enumerated() where matchedBaseColumns.contains(column) && sim.isLive(column) {
                let width = p < sidecar.columnWidths.count ? sidecar.columnWidths[p] : nil
                let now = sim.state.table.columnWidths[column]
                guard width != base.table.columnWidths[column], width != now else { continue }
                sim.emit(.figureSettings, FigureOpPayload(settings: .columnWidth(column, width, prior: now)))
            }
        }

        return Changes(
            ops: sim.ops, overwritten: overwritten,
            problems: problems.filter { !kept.contains(Position(row: $0.row, column: $0.column)) })
    }

    // MARK: - Placing an axis

    /// Puts `order` (result ids, the copy's order) in place on `sim`: a fresh
    /// id is inserted after the one before it; a kept id moves there unless it
    /// is among the longest run already in order. An id `sim` no longer holds
    /// live (deleted late) is passed over.
    private static func place<ID: AxisID>(_ order: [ID], fresh: Set<ID>, in sim: inout Simulation) {
        let kept = order.filter { !fresh.contains($0) && sim.isLive($0) }
        let stable = Set(longestIncreasing(kept.map { sim.slot(of: $0) ?? 0 }).map { kept[$0] })
        var previous: ID?
        for id in order {
            if fresh.contains(id) {
                sim.emit(.figureStructure, FigureOpPayload(structure: ID.insert(id, after: previous)))
            } else if sim.isLive(id) {
                if !stable.contains(id) {
                    let prior = sim.predecessor(of: id)
                    if prior != previous {
                        sim.emit(.figureStructure, FigureOpPayload(structure: ID.move(id, after: previous, priorAfter: prior)))
                    }
                }
            } else {
                continue
            }
            previous = id
        }
    }

    // MARK: - Matching

    /// (base live column index, copy live column index) pairs.
    static func matchColumns(base: FigureTable, copy: FigureTable) -> [(Int, Int)] {
        let b = base.columns, c = copy.columns
        guard base.headerRows == 1, let baseHeader = base.rows.first, let copyHeader = copy.rows.first else {
            return (0..<min(b.count, c.count)).map { ($0, $0) }
        }
        let bk = b.enumerated().map { i, id in matchKey(base[CellKey(row: baseHeader, column: id)], at: (0, i), in: base) }
        let ck = c.enumerated().map { i, id in matchKey(copy[CellKey(row: copyHeader, column: id)], at: (0, i), in: copy) }
        var pairs = lcs(bk, ck)
        pairs += movedPairs(bk, ck, already: pairs, blank: { $0.isEmpty })
        // No header in common (every one retitled): by position after all.
        guard !pairs.isEmpty else { return (0..<min(b.count, c.count)).map { ($0, $0) } }
        return pairs.sorted { $0.1 < $1.1 }
    }

    /// (base live row index, copy live row index) pairs, over the matched columns.
    static func matchRows(base: FigureTable, copy: FigureTable, columns: [(Int, Int)]) -> [(Int, Int)] {
        let bc = base.columns, cc = copy.columns
        func keys(_ t: FigureTable, _ cols: [ColumnID], copySide: Bool) -> [[String]] {
            t.rows.enumerated().map { r, row in
                columns.map { pair in
                    let i = copySide ? pair.1 : pair.0
                    return matchKey(t[CellKey(row: row, column: cols[i])], at: (r, i), in: t)
                }
            }
        }
        let bk = keys(base, bc, copySide: false), ck = keys(copy, cc, copySide: true)
        let anchors = lcs(bk, ck)
        var pairs = anchors + movedPairs(bk, ck, already: anchors, blank: { $0.allSatisfy(\.isEmpty) })
        // Between two anchors, an edited row: at least half its cells the same.
        var baseTaken = Set(pairs.map(\.0)), copyTaken = Set(pairs.map(\.1))
        let fences = [(-1, -1)] + anchors + [(bk.count, ck.count)]
        for k in 1..<fences.count {
            let (b0, c0) = fences[k - 1], (b1, c1) = fences[k]
            var next = b0 + 1
            for j in (c0 + 1)..<max(c1, c0 + 1) where !copyTaken.contains(j) {
                var i = next
                while i < b1 {
                    if !baseTaken.contains(i), similar(bk[i], ck[j]) { break }
                    i += 1
                }
                guard i < b1 else { continue }
                pairs.append((i, j))
                baseTaken.insert(i); copyTaken.insert(j)
                next = i + 1
            }
        }
        // Anywhere else, an edited row that also moved: more than half its
        // cells the same, or half with its first cell (its label) the same —
        // the most alike first, the nearest on a tie. Skipped when what is
        // left unmatched is too large to compare all against all.
        let leftover = (bk.count - baseTaken.count) * (ck.count - copyTaken.count)
        for j in 0..<ck.count where leftover <= 1_000_000 && !copyTaken.contains(j) {
            var best: (i: Int, score: Double)?
            for i in 0..<bk.count where !baseTaken.contains(i) {
                guard let score = likeness(bk[i], ck[j]) else { continue }
                if best == nil || score > best!.score || (score == best!.score && abs(i - j) < abs(best!.i - j)) {
                    best = (i, score)
                }
            }
            guard let best else { continue }
            pairs.append((best.i, j))
            baseTaken.insert(best.i); copyTaken.insert(j)
        }
        return pairs.sorted { $0.1 < $1.1 }
    }

    /// How alike two rows are, when alike enough to be one row edited and
    /// moved: the share of held cells that are the same, over half, or half
    /// exactly with the same non-empty first cell. Nil otherwise.
    private static func likeness(_ a: [String], _ b: [String]) -> Double? {
        var same = 0, held = 0
        for (x, y) in zip(a, b) where !x.isEmpty || !y.isEmpty {
            held += 1
            if x == y { same += 1 }
        }
        guard held > 0 else { return nil }
        if same * 2 > held { return Double(same) / Double(held) }
        if same * 2 == held, let x = a.first, !x.isEmpty, x == b.first { return 0.5 }
        return nil
    }

    /// At least half the cells either row holds are the same in both.
    private static func similar(_ a: [String], _ b: [String]) -> Bool {
        var same = 0, held = 0
        for (x, y) in zip(a, b) where !x.isEmpty || !y.isEmpty {
            held += 1
            if x == y { same += 1 }
        }
        return held == 0 || same * 2 >= held
    }

    /// Pairs of equal, non-empty keys left unpaired by `already`, each copy key
    /// taking the first such base key: a row or column the copy moved.
    private static func movedPairs<K: Hashable>(
        _ a: [K], _ b: [K], already: [(Int, Int)], blank: (K) -> Bool
    ) -> [(Int, Int)] {
        let takenA = Set(already.map(\.0)), takenB = Set(already.map(\.1))
        var waiting: [K: [Int]] = [:]
        for (i, key) in a.enumerated() where !takenA.contains(i) && !blank(key) {
            waiting[key, default: []].append(i)
        }
        var out: [(Int, Int)] = []
        for (j, key) in b.enumerated() where !takenB.contains(j) {
            guard var list = waiting[key], !list.isEmpty else { continue }
            out.append((list.removeFirst(), j))
            waiting[key] = list
        }
        return out
    }

    /// The pairs of a longest common subsequence of `a` and `b`, in order. Common
    /// ends are matched first; a middle too large for the table (over 4 million
    /// cells) is matched greedily in order instead.
    static func lcs<K: Hashable>(_ a: [K], _ b: [K]) -> [(Int, Int)] {
        var lo = 0
        while lo < a.count, lo < b.count, a[lo] == b[lo] { lo += 1 }
        var ha = a.count, hb = b.count
        while ha > lo, hb > lo, a[ha - 1] == b[hb - 1] { ha -= 1; hb -= 1 }
        var out = (0..<lo).map { ($0, $0) }
        let n = ha - lo, m = hb - lo
        if n > 0, m > 0 {
            if n * m <= 4_000_000 {
                // dp[i][j] = LCS length of a[lo+i..<ha] and b[lo+j..<hb].
                var dp = [Int32](repeating: 0, count: (n + 1) * (m + 1))
                func at(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        dp[at(i, j)] = a[lo + i] == b[lo + j]
                            ? dp[at(i + 1, j + 1)] + 1 : max(dp[at(i + 1, j)], dp[at(i, j + 1)])
                    }
                }
                var i = 0, j = 0
                while i < n, j < m {
                    if a[lo + i] == b[lo + j] { out.append((lo + i, lo + j)); i += 1; j += 1 }
                    else if dp[at(i + 1, j)] >= dp[at(i, j + 1)] { i += 1 }
                    else { j += 1 }
                }
            } else {
                var next: [K: [Int]] = [:]
                for i in lo..<ha { next[a[i], default: []].append(i) }
                var floor = lo
                for j in lo..<hb {
                    guard let i = next[b[j]]?.first(where: { $0 >= floor }) else { continue }
                    out.append((i, j))
                    floor = i + 1
                }
            }
        }
        out += (0..<(a.count - ha)).map { (ha + $0, hb + $0) }
        return out
    }

    /// Indices into `values` of one longest strictly increasing subsequence.
    static func longestIncreasing(_ values: [Int]) -> [Int] {
        var tails: [Int] = []          // index into values of the smallest tail per length
        var previous = [Int](repeating: -1, count: values.count)
        for (i, v) in values.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if values[tails[mid]] < v { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { previous[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var out: [Int] = []
        var k = tails.last ?? -1
        while k >= 0 { out.append(k); k = previous[k] }
        return out.reversed()
    }

    // MARK: - Comparing cells

    /// What a cell is for matching: its value, or its formula's shape relative
    /// to the cell (`(row, column)` its live position in `table`).
    static func matchKey(_ cell: Cell?, at position: (Int, Int), in table: FigureTable) -> String {
        guard let cell else { return "" }
        switch cell.content {
        case .value(let v): return valueKey(v)
        case .formula(let f): return "=" + shape(f.expr, at: position, in: table)
        }
    }

    private static func valueKey(_ v: CellValue) -> String {
        switch v {
        case .empty: return ""
        case .number(let x): return "n" + FormulaParser.numberText(x)
        case .date(let s): return "d\(s)"
        case .text(let s): return s.isEmpty ? "" : "t" + s
        case .bool(let b): return b ? "bT" : "bF"
        case .error(let e): return "e" + e.rawValue
        }
    }

    private static func shape(_ e: FormulaExpr, at here: (Int, Int), in table: FigureTable) -> String {
        func ref(_ r: FormulaRef) -> String {
            var out: String
            switch r.target {
            case .this: out = ""
            case .figure(let id): out = "f" + id
            case .research(let id): out = "r" + id
            }
            switch (r.target, r.anchor) {
            case let (.this, .id(row, column)):
                let rr = table.rowIndex(of: row).map { r.rowAbsolute ? "R\($0)" : "r\($0 - here.0)" } ?? "#"
                let cc = table.columnIndex(of: column).map { r.columnAbsolute ? "C\($0)" : "c\($0 - here.1)" } ?? "#"
                out += rr + cc
            case let (_, .id(row, column)):
                out += "@" + row.raw + "," + column.raw
            case let (_, .position(row, column)):
                out += "p\(row),\(column)"
            }
            return out
        }
        switch e {
        case .number(let x): return FormulaParser.numberText(x)
        case .text(let s): return "\"" + s + "\""
        case .bool(let b): return b ? "T" : "F"
        case .missing: return "_"
        case .error(let err): return err.rawValue
        case .ref(let r): return ref(r)
        case .range(let g): return ref(g.start) + ":" + ref(g.end)
        case .unary(let op, let x): return op.rawValue + "(" + shape(x, at: here, in: table) + ")"
        case .binary(let op, let l, let r):
            return op.rawValue + "(" + shape(l, at: here, in: table) + "," + shape(r, at: here, in: table) + ")"
        case .call(let name, let args):
            return name + "(" + args.map { shape($0, at: here, in: table) }.joined(separator: ",") + ")"
        }
    }

    /// Did the copy leave this content as the base had it? By value; a formula
    /// by id, then by its text at the copy's positions; a formula the copy
    /// read as `=…` text (`TableCSV.read`'s unreadable formula) equal to the
    /// base's text but for the names it cites is unchanged too — a figure
    /// renamed while this one was parked.
    private static func sameContent(
        _ ours: CellContent, _ old: CellContent, toResult: IDMap, toCopy: IDMap,
        copy: FigureTable, names: FormulaNames
    ) -> Bool {
        switch (ours, old) {
        case let (.value(a), .value(b)):
            return valueKey(a) == valueKey(b)
        case let (.formula(a), .formula(b)):
            if toResult.formula(a) == b { return true }
            return FormulaParser.render(a, in: copy, names: names)
                == FormulaParser.render(toCopy.formula(b), in: copy, names: names)
        case let (.value(.text(t)), .formula(b)):
            guard t.hasPrefix("=") else { return false }
            let theirs = "=" + FormulaParser.render(toCopy.formula(b), in: copy, names: names)
            return withoutNames(t) == withoutNames(theirs)
        default:
            return false
        }
    }

    private static let namePrefix = try! NSRegularExpression(
        pattern: #"(research:)?('(?:[^']|'')*'|[A-Za-z0-9_.\-]+)!"#)

    /// Formula text with every `name!` (figure or research, bare or quoted)
    /// replaced by one placeholder.
    private static func withoutNames(_ text: String) -> String {
        namePrefix.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1\u{1}!")
    }

    // MARK: - Ids

    private struct Position: Hashable { let row: Int; let column: Int }

    /// Maps the `.this` refs of a formula from one table's ids to another's; an
    /// id with no mapping is kept (it renders `#REF!` where it is not held).
    private struct IDMap {
        var rows: [RowID: RowID]
        var columns: [ColumnID: ColumnID]

        func content(_ c: CellContent) -> CellContent {
            if case .formula(let f) = c { return .formula(formula(f)) }
            return c
        }

        func formula(_ f: Formula) -> Formula { Formula(expr(f.expr)) }

        private func ref(_ r: FormulaRef) -> FormulaRef {
            guard case .this = r.target, case let .id(row, column) = r.anchor else { return r }
            var out = r
            out.anchor = .id(row: rows[row] ?? row, column: columns[column] ?? column)
            return out
        }

        private func expr(_ e: FormulaExpr) -> FormulaExpr {
            switch e {
            case .number, .text, .bool, .missing, .error: return e
            case .ref(let r): return .ref(ref(r))
            case .range(let g): return .range(FormulaRange(start: ref(g.start), end: ref(g.end)))
            case .unary(let op, let x): return .unary(op, expr(x))
            case .binary(let op, let l, let r): return .binary(op, expr(l), expr(r))
            case .call(let name, let args): return .call(name: name, arguments: args.map(expr))
            }
        }
    }
}

// MARK: - The simulated fold

/// The state the ops land on, folded op by op as they are made, so each op is
/// made against what the ones before it left (a move's `priorAfter`, a delete's
/// slice, a cell's `prior`).
private struct Simulation {
    var state: FigureState
    var ops: [FigureReturnDiff.Change] = []

    init(state: FigureState) {
        self.state = state
        self.state.parked = nil
    }

    mutating func emit(_ kind: OpKind, _ payload: FigureOpPayload) {
        ops.append(FigureReturnDiff.Change(kind: kind, payload: payload))
        let op = Op(opId: "return-\(ops.count)", docId: "", at: Date(timeIntervalSince1970: 0),
                    device: "", session: "", kind: kind, changes: [], figure: payload)
        FigureDeriver.fold(op, into: &state)
    }

    func isLive<ID: AxisID>(_ id: ID) -> Bool { id.isLive(in: state.table) }
    func slot<ID: AxisID>(of id: ID) -> Int? { id.slot(in: state.table) }
    func predecessor<ID: AxisID>(of id: ID) -> ID? { id.predecessor(in: state.table) }

    /// Cells of a row about to be deleted that differ from the base: late edits
    /// the copy's delete takes.
    func lateEdits(inRow id: RowID, base: FigureState) -> [CellKey] {
        state.table.columns.map { CellKey(row: id, column: $0) }.filter { state.table[$0] != base.table[$0] }
    }

    func lateEdits(inColumn id: ColumnID, base: FigureState) -> [CellKey] {
        state.table.rows.map { CellKey(row: $0, column: id) }.filter { state.table[$0] != base.table[$0] }
    }
}

/// A row or a column id, for the one placing walk both axes share.
private protocol AxisID: Hashable {
    static func insert(_ id: Self, after: Self?) -> FigureStructureChange
    static func move(_ id: Self, after: Self?, priorAfter: Self?) -> FigureStructureChange
    func isLive(in table: FigureTable) -> Bool
    func slot(in table: FigureTable) -> Int?
    /// The slot just before this one (tombstones too), nil when it is first.
    func predecessor(in table: FigureTable) -> Self?
}

extension RowID: AxisID {
    static func insert(_ id: RowID, after: RowID?) -> FigureStructureChange { .insertRow(id, after: after) }
    static func move(_ id: RowID, after: RowID?, priorAfter: RowID?) -> FigureStructureChange {
        .moveRow(id, after: after, priorAfter: priorAfter)
    }
    func isLive(in table: FigureTable) -> Bool { table.rowIndex(of: self) != nil }
    func slot(in table: FigureTable) -> Int? { table.rowSlotIndex(of: self) }
    func predecessor(in table: FigureTable) -> RowID? {
        guard let i = table.rowSlotIndex(of: self), i > 0 else { return nil }
        return table.rowSlots[i - 1].id
    }
}

extension ColumnID: AxisID {
    static func insert(_ id: ColumnID, after: ColumnID?) -> FigureStructureChange { .insertColumn(id, after: after) }
    static func move(_ id: ColumnID, after: ColumnID?, priorAfter: ColumnID?) -> FigureStructureChange {
        .moveColumn(id, after: after, priorAfter: priorAfter)
    }
    func isLive(in table: FigureTable) -> Bool { table.columnIndex(of: self) != nil }
    func slot(in table: FigureTable) -> Int? { table.columnSlotIndex(of: self) }
    func predecessor(in table: FigureTable) -> ColumnID? {
        guard let i = table.columnSlotIndex(of: self), i > 0 else { return nil }
        return table.columnSlots[i - 1].id
    }
}
