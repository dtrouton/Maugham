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
/// - **Matching** (`FigureReturnMatch.swift`): columns by header text, then
///   a retitled column by its unchanged position; rows by their values —
///   equal, moved, or edited (`FigureReturnDiff.likeness`).
/// - A matched row or column keeps its id and moves if the copy moved it; an
///   unmatched old one is deleted, carrying what it held (ruling P-2; anchors
///   on it are orphaned, §11.5); a new one is inserted with a fresh id from
///   `mintRow`/`mintColumn` (never a tombstoned one, ruling P-1).
/// - **Cells**: a cell the copy changed is set; one it did not is left alone. A
///   copy's formula is compared with the old one by id, then by its text at the
///   copy's positions; a formula the copy could not read only because a figure
///   it names was renamed while parked (`TableCSV.read` kept it as `=…` text,
///   exactly the old formula under the park-time names) keeps the old formula.
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
        public init(kind: OpKind, payload: FigureOpPayload) {
            self.kind = kind
            self.payload = payload
        }
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

    /// **The state the working copy was written from**: for each device, the
    /// prefix of its own stream, in append order (`streams`, from
    /// `OpLogStore.loadDiagnosedStreams`), up to and including the last op the
    /// parker had folded from it (`FigureParking.frontier`). A device the
    /// parker had not read contributes none: its ops surface as late edits.
    /// **A recorded op this Mac cannot find in that device's stream** — held
    /// here by a permit partition the parker's Mac did not hold, or in a
    /// later segment that synced before an earlier one — falls back to that
    /// device's ops whose id is at or below the recorded one (final review
    /// M-1): append order is lost for that device, but the rows the parker
    /// read stay in the base, so the copy's copies of them match rather than
    /// come back a second time.
    /// Ops a return already appended (`broughtBackFromResearch` — a return
    /// that stopped part way and was parked again) count as written from: a
    /// retry brings back only what is left; a return the stream itself drops
    /// (its resume was a duplicate, `FigureState.abandonedReturns`) does not.
    /// Never parked: the lifecycle ops are left out of the fold.
    public static func base(
        of ops: [Op], streams: [String: [String]], frontier: [String: String]
    ) -> FigureState {
        var read: Set<String> = []
        for (device, last) in frontier {
            guard let stream = streams[device] else { continue }
            if let end = stream.firstIndex(of: last) {
                read.formUnion(stream[...end])
            } else {
                read.formUnion(stream.filter { $0 <= last })
            }
        }
        let abandoned = FigureDeriver.derive(ops.filter { FigureOpPayload.kinds.contains($0.kind) })
            .abandonedReturns
        var state = FigureDeriver.derive(ops.filter { op in
            guard FigureOpPayload.kinds.contains(op.kind),
                  op.kind != .figureParked, op.kind != .figureResumed else { return false }
            if let resume = op.figure?.returnOf, abandoned.contains(resume) { return false }
            return read.contains(op.opId) || op.provenance?.synthesisSource == .broughtBackFromResearch
        })
        state.parked = nil
        return state
    }

    /// **Does every change apply, in turn, onto `state` resumed?** Each payload
    /// carries what its kind needs, and none is dropped or left waiting — what
    /// a host checks before it appends the first op of a return.
    public static func everyChangeApplies(_ changes: [Change], onto state: FigureState) -> Bool {
        var sim = Simulation(state: state)
        for change in changes {
            // Against what each change found: an op already waiting (held
            // before the return began) is no fault of the return's.
            let diagnosed = sim.state.diagnostics.count, held = sim.state.held.count
            guard FigureOpPayload.validate(kind: change.kind, payload: change.payload) else { return false }
            sim.emit(change.kind, change.payload)
            guard sim.state.diagnostics.count == diagnosed, sim.state.held.count <= held else { return false }
        }
        return true
    }

    /// **`state` with `changes` folded in turn, or nil when one does not apply
    /// or misstates what it replaces** (report plan 7d Task 2). Each change's
    /// undo is built from what it says it replaced, so a host asks this before
    /// it appends a batch it will undo, and asks it of the inverses at ⌘Z and
    /// of the redo at ⇧⌘Z: their drift guard. Beyond `everyChangeApplies`:
    /// - a cell set's `prior` is the cell it lands on;
    /// - a delete's `removed` slice is what the row or column holds;
    /// - a move's `priorAfter` is the slot before it;
    /// - a setting's prior is the table's;
    /// - a pin set's `priorPin`, and a pin clear's pin, are held by the cell.
    public static func applied(_ changes: [Change], onto state: FigureState) -> FigureState? {
        var sim = Simulation(state: state)
        for change in changes {
            let diagnosed = sim.state.diagnostics.count, held = sim.state.held.count
            guard FigureOpPayload.validate(kind: change.kind, payload: change.payload),
                  describesWhatItReplaces(change, in: sim.state) else { return nil }
            sim.emit(change.kind, change.payload)
            guard sim.state.diagnostics.count == diagnosed, sim.state.held.count <= held else { return nil }
        }
        sim.state.parked = state.parked
        return sim.state
    }

    private static func describesWhatItReplaces(_ change: Change, in state: FigureState) -> Bool {
        let p = change.payload, table = state.table
        switch change.kind {
        case .figureCellSet:
            return p.cell.map { table[$0] == p.prior } ?? false
        case .figureStructure:
            switch p.structure {
            case let .deleteRow(id)?: return p.removed.map { $0 == state.removedSlice(row: id) } ?? true
            case let .deleteColumn(id)?: return p.removed.map { $0 == state.removedSlice(column: id) } ?? true
            case let .moveRow(id, _, priorAfter)?:
                return id.slot(in: table) != nil && id.predecessor(in: table) == priorAfter
            case let .moveColumn(id, _, priorAfter)?:
                return id.slot(in: table) != nil && id.predecessor(in: table) == priorAfter
            default: return true
            }
        case .figureSettings:
            switch p.settings {
            case let .headerRows(_, prior)?: return table.headerRows == prior
            case let .totalRow(_, prior)?: return table.hasTotalRow == prior
            case let .columnWidth(column, _, prior)?: return table.columnWidths[column] == prior
            case nil: return false
            }
        case .figurePinSet:
            guard let prior = p.priorPin, let key = p.cell else { return true }
            return state.pins[key]?.contains(prior) == true
        case .figurePinClear:
            guard let pin = p.pin, let key = p.cell else { return true }
            return state.pins[key]?.contains(pin) == true
        default:
            return true
        }
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
    /// `problems` that read's problems, `names` the book's name directory the
    /// read used, and `namesAtPark` the names the working copy was written
    /// with (the sidecar's `formulaNames` laid over `names`), when known.
    public static func changes(
        from base: FigureState, onto current: FigureState, to copy: FigureTable,
        sidecar: ResearchTableSidecar?, names: FormulaNames = .empty, namesAtPark: FormulaNames? = nil,
        problems: [CSVReadProblem] = [],
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
                                            copy: copy, names: names, namesAtPark: namesAtPark) {
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
    /// live (deleted late) is passed over. Shared with `FigureRestoreDiff`.
    static func place<ID: AxisID>(_ order: [ID], fresh: Set<ID>, in sim: inout Simulation) {
        let kept = order.filter { !fresh.contains($0) && sim.isLive($0) }
        let stable = Set(longestIncreasing(kept.map { sim.slot(of: $0) ?? 0 }).map { kept[$0] })
        var previous: ID?
        for id in order {
            if fresh.contains(id) {
                sim.emit(.figureStructure, FigureOpPayload(structure: ID.insert(id, after: previous)))
            } else if sim.isLive(id) {
                // Already just after `previous` among the live (a tombstone
                // between them is no reason to move): no op.
                if !stable.contains(id), sim.livePredecessor(of: id) != previous {
                    sim.emit(.figureStructure, FigureOpPayload(
                        structure: ID.move(id, after: previous, priorAfter: sim.predecessor(of: id))))
                }
            } else {
                continue
            }
            previous = id
        }
    }

    /// Did the copy leave this content as the base had it? By value; a formula
    /// by its text under the park-time names (`namesAtPark`: the copy's text
    /// as written), by id, then by its text at the copy's positions. A formula the copy
    /// read as `=…` text (`TableCSV.read`'s unreadable formula: a name it does
    /// not know) is unchanged when that text is exactly the base formula
    /// written with the names of park time (`namesAtPark`) — a figure renamed
    /// while this one was parked. Any other unknown name, a typo, is a change.
    private static func sameContent(
        _ ours: CellContent, _ old: CellContent, toResult: IDMap, toCopy: IDMap,
        copy: FigureTable, names: FormulaNames, namesAtPark: FormulaNames?
    ) -> Bool {
        switch (ours, old) {
        case let (.value(a), .value(b)):
            return valueKey(a) == valueKey(b)
        case let (.formula(a), .formula(b)):
            // The text the copy was written with first: a figure renamed while
            // parked whose old name another figure has since taken reads to
            // that other figure now, and must not be re-pointed to it.
            if let namesAtPark, FormulaParser.render(a, in: copy, names: names)
                == FormulaParser.render(toCopy.formula(b), in: copy, names: namesAtPark) { return true }
            if toResult.formula(a) == b { return true }
            return FormulaParser.render(a, in: copy, names: names)
                == FormulaParser.render(toCopy.formula(b), in: copy, names: names)
        case let (.value(.text(t)), .formula(b)):
            guard t.hasPrefix("="), let namesAtPark else { return false }
            return t == "=" + FormulaParser.render(toCopy.formula(b), in: copy, names: namesAtPark)
        default:
            return false
        }
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

extension FigureReturnDiff {
    /// The state the ops land on, folded op by op as they are made, so each op is
    /// made against what the ones before it left (a move's `priorAfter`, a delete's
    /// slice, a cell's `prior`). Shared with `FigureRestoreDiff`, whose changes
    /// fold here too: never appended.
    struct Simulation {
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
        func livePredecessor<ID: AxisID>(of id: ID) -> ID? { id.livePredecessor(in: state.table) }

        /// Cells of a row about to be deleted that differ from the base: late edits
        /// the copy's delete takes.
        func lateEdits(inRow id: RowID, base: FigureState) -> [CellKey] {
            state.table.columns.map { CellKey(row: id, column: $0) }.filter { state.table[$0] != base.table[$0] }
        }

        func lateEdits(inColumn id: ColumnID, base: FigureState) -> [CellKey] {
            state.table.rows.map { CellKey(row: $0, column: id) }.filter { state.table[$0] != base.table[$0] }
        }
    }
}

/// A row or a column id, for the one placing walk both axes share.
protocol AxisID: Hashable {
    static func insert(_ id: Self, after: Self?) -> FigureStructureChange
    static func move(_ id: Self, after: Self?, priorAfter: Self?) -> FigureStructureChange
    func isLive(in table: FigureTable) -> Bool
    func slot(in table: FigureTable) -> Int?
    /// The slot just before this one (tombstones too), nil when it is first.
    func predecessor(in table: FigureTable) -> Self?
    /// The live one just before this one, nil when it is first.
    func livePredecessor(in table: FigureTable) -> Self?
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
    func livePredecessor(in table: FigureTable) -> RowID? {
        guard let i = table.rowIndex(of: self), i > 0 else { return nil }
        return table.rows[i - 1]
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
    func livePredecessor(in table: FigureTable) -> ColumnID? {
        guard let i = table.columnIndex(of: self), i > 0 else { return nil }
        return table.columns[i - 1]
    }
}
