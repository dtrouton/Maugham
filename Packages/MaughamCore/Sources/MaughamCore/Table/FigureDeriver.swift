import Foundation

/// Where a parked figure went: its file in Research, that file's content
/// hash and, when the park recorded it, the Research item holding it
/// (`figureParked`'s `parkedPath` / `parkedHash` / `parkedItemId`), and what
/// the parker had read (`parkedFrontier`).
public struct FigureParking: Equatable, Sendable {
    public var path: String
    public var hash: String
    public var itemId: String?
    /// Per device stream, the last op id the parking host had folded; nil
    /// for a park that did not record it.
    public var frontier: [String: String]?
    public init(path: String, hash: String, itemId: String? = nil, frontier: [String: String]? = nil) {
        self.path = path
        self.hash = hash
        self.itemId = itemId
        self.frontier = frontier
    }
}

/// **A figure as its op stream says it is** — content and lifecycle (ruling
/// D-e). Name, piece and path are the manifest registry's (`FigureRecord`),
/// never this.
public struct FigureState: Equatable, Sendable {
    /// The first `figureCreate`'s kind; nil before any create.
    public var kind: FigureKind?
    public var table: FigureTable
    public var image: FigureImageRef?
    /// Each cell's research pins, in the order first set; a cell with none has no key.
    public var pins: [CellKey: [FigureResearchPin]]
    /// Set while the figure is parked in Research; nil once resumed.
    public var parked: FigureParking?
    /// The device of the first `figureCreate`.
    public var createdBy: String?
    /// The Research item the first `figureCreate` was made from, when it was
    /// (*Use in document*, spec §4.1).
    public var source: FigureSource?
    /// One line per op that could not apply, naming its op id. The op stays in
    /// the log; only the view drops it.
    public var diagnostics: [String]
    /// **Ops waiting for an id this stream has not shown yet** (ruling R-6a-4),
    /// in fold order: a cell set, pin, width, delete or move naming a row or
    /// column no insert has folded. Merged order is ULID order, so under clock
    /// skew an edit can sort before the insert it depends on; it is held here
    /// and replays, in its original order, the moment that insert folds. Kept
    /// on the state so `FigureDeriver.fold` carries it across calls; `derive`
    /// diagnoses whatever is still held when the stream ends.
    public internal(set) var held: [Op]
    /// **Returns this stream drops whole** (report plan 6b final review M-2):
    /// the op ids of `figureResumed` ops that came while the figure was not
    /// parked — a second Mac bringing the same figure back at once. Every
    /// content op naming one of them (`FigureOpPayload.returnOf`) is dropped
    /// and diagnosed, so the second return's rows are not added twice.
    public internal(set) var abandonedReturns: Set<String> = []

    public init(
        kind: FigureKind? = nil, table: FigureTable = FigureTable(rows: 0, columns: 0),
        image: FigureImageRef? = nil, pins: [CellKey: [FigureResearchPin]] = [:],
        parked: FigureParking? = nil, createdBy: String? = nil, diagnostics: [String] = [],
        source: FigureSource? = nil
    ) {
        self.held = []
        self.kind = kind
        self.table = table
        self.image = image
        self.pins = pins
        self.parked = parked
        self.createdBy = createdBy
        self.diagnostics = diagnostics
        self.source = source
    }
}

/// **Folds a figure's op stream onto a `FigureTable`.** Pure, no I/O, shared by
/// the Mac and the phone (tripwire 19). Fold in the order `OpLogStore`'s
/// `loadDiagnosed` / `loadSyncMerged` return — that merged order is the whole
/// conflict rule:
/// - **Per-cell last writer wins** in fold order.
/// - **Delete beats edit** (spec §11.5): a cell set, pin or column width on a
///   deleted row or column is dropped from the view and diagnosed; a delete
///   takes the cells, pins and width it held.
/// - **A revive puts a deleted row or column back in its own slot** (ruling
///   P-1) with the slice its payload carries (ruling P-2): cells and pins only
///   where the other axis is still live — one whose column (or row) was
///   deleted meanwhile stays gone, diagnosed — and a column's width. Reviving
///   a live row or column is dropped; one never seen waits like any other op.
/// - **A not-yet-seen id waits** (ruling R-6a-4): an op naming a row or column
///   no insert has folded is held (`FigureState.held`) and replays in its
///   original fold order when that insert folds; one still held at the end of
///   `derive` is diagnosed. Only a tombstoned id drops.
/// - **Concurrent inserts both survive**: an insert replays through
///   `FigureTable.insertRow(_:after:)` by id, so two inserts after one row both
///   land after it, the later-folded first.
/// - The first `figureCreate` sets the kind; a later one is diagnosed and ignored.
/// - **Parked folds nothing** (ruling P-5): `figureParked` sets `parked` and
///   `figureResumed` clears it; a content op ordered between them — a cell,
///   structure, settings, image or pin op — is dropped from the view and
///   diagnosed, and stays in the log (like a delete beating an edit). A second
///   park while parked is dropped the same way: the first one's working copy
///   is the one the stream points at. A resume while not parked is dropped,
///   and so is every content op of that return (its `returnOf`): two Macs
///   bringing one figure back at once add its rows once.
///
/// This is not the manuscript deriver, and never asks `Deriver.appliesToManuscript`
/// (tripwire 44+1): a figure op is never manuscript text.
public enum FigureDeriver {

    public static func derive(_ ops: [Op]) -> FigureState {
        var state = FigureState()
        for op in ops { fold(op, into: &state) }
        for op in state.held {
            state.diagnostics.append("\(op.opId): names a row or column no insert ever created, never applied")
        }
        return state
    }

    /// Folds one op onto `state` — what `derive` does per op, for a host that
    /// applies its own appends without re-deriving.
    public static func fold(_ op: Op, into state: inout FigureState) {
        guard FigureOpPayload.kinds.contains(op.kind) else {
            return state.diagnostics.append("\(op.opId): \(op.kind.rawValue) is not a figure op")
        }
        guard let p = op.figure, FigureOpPayload.validate(kind: op.kind, payload: p) else {
            return state.diagnostics.append("\(op.opId): \(op.kind.rawValue) is missing what it needs")
        }
        func drop(_ why: String) { state.diagnostics.append("\(op.opId): \(why)") }

        // Parked folds nothing (ruling P-5) — asked before the wait for an
        // unseen id, so an op ordered while parked never waits to replay.
        if state.parked != nil, isContent(op.kind) {
            return drop("\(op.kind.rawValue) while the figure is parked in Research, not applied")
        }
        if let resume = p.returnOf, state.abandonedReturns.contains(resume) {
            return drop("\(op.kind.rawValue) of a return whose resume was dropped, not applied")
        }

        if namesAnUnseenID(op.kind, p, in: state.table) {
            state.held.append(op)
            return
        }

        switch op.kind {
        case .figureCreate:
            guard state.kind == nil else {
                return drop("a second figure_create, ignored")
            }
            state.kind = p.kind
            state.createdBy = op.device
            state.source = p.source

        case .figureParked:
            guard state.parked == nil else {
                return drop("a second figure_parked while parked, ignored")
            }
            if let path = p.parkedPath, let hash = p.parkedHash {
                state.parked = FigureParking(
                    path: path, hash: hash, itemId: p.parkedItemId, frontier: p.parkedFrontier)
            }

        case .figureResumed:
            guard state.parked != nil else {
                state.abandonedReturns.insert(op.opId)
                return drop("figure_resumed while not parked, ignored")
            }
            state.parked = nil

        case .figureCellSet:
            guard let key = p.cell else { return }
            guard isLive(key, in: state.table) else {
                return drop("cell set on a deleted row or column (\(key.row.raw), \(key.column.raw))")
            }
            state.table.setCell(p.next, at: key)

        case .figureStructure:
            guard let change = p.structure else { return }
            if let why = applyStructure(change, to: &state) { return drop(why) }
            switch change {
            case .insertRow, .insertColumn:
                // A new id: whatever waited on it replays now, in fold order.
                // Everything held is re-folded; an op still missing another id
                // is held again, keeping its place.
                let waiting = state.held
                state.held = []
                for held in waiting { fold(held, into: &state) }
            case let .reviveRow(id):
                for entry in p.removed?.cells ?? [] {
                    let key = CellKey(row: id, column: ColumnID(entry.at))
                    guard isLive(key, in: state.table) else {
                        drop("revive of row \(id.raw): its cell in deleted column \(entry.at) stays gone")
                        continue
                    }
                    restore(entry, at: key, into: &state)
                }
            case let .reviveColumn(id):
                for entry in p.removed?.cells ?? [] {
                    let key = CellKey(row: RowID(entry.at), column: id)
                    guard isLive(key, in: state.table) else {
                        drop("revive of column \(id.raw): its cell in deleted row \(entry.at) stays gone")
                        continue
                    }
                    restore(entry, at: key, into: &state)
                }
                state.table.columnWidths[id] = p.removed?.width
            default:
                break
            }

        case .figureSettings:
            guard let change = p.settings else { return }
            switch change {
            case .headerRows(let rows, _):
                state.table.headerRows = rows
            case .totalRow(let total, _):
                state.table.hasTotalRow = total
            case .columnWidth(let column, let width, _):
                guard state.table.columnIndex(of: column) != nil else {
                    return drop("column width on a deleted column \(column.raw)")
                }
                state.table.columnWidths[column] = width
            }

        case .figureImageSet:
            state.image = p.image

        case .figurePinSet:
            guard let key = p.cell, let pin = p.pin else { return }
            guard isLive(key, in: state.table) else {
                return drop("pin on a deleted row or column (\(key.row.raw), \(key.column.raw))")
            }
            var list = state.pins[key] ?? []
            if let i = list.firstIndex(where: { sameSource($0, pin) }) {
                list[i] = pin
            } else {
                list.append(pin)
            }
            state.pins[key] = list

        case .figurePinClear:
            guard let key = p.cell else { return }
            if let pin = p.pin {
                let list = (state.pins[key] ?? []).filter { !sameSource($0, pin) }
                state.pins[key] = list.isEmpty ? nil : list
            } else {
                state.pins[key] = nil
            }

        default:
            return   // unreachable: the kinds guard above
        }
    }

    /// Applies `change`, or answers why it could not.
    private static func applyStructure(_ change: FigureStructureChange, to state: inout FigureState) -> String? {
        switch change {
        case let .insertRow(id, after):
            guard state.table.rowSlotIndex(of: id) == nil else {
                return "insert of row \(id.raw), which already exists"
            }
            state.table.insertRow(id, after: after)
            return nil
        case let .insertColumn(id, after):
            guard state.table.columnSlotIndex(of: id) == nil else {
                return "insert of column \(id.raw), which already exists"
            }
            state.table.insertColumn(id, after: after)
            return nil
        case let .deleteRow(id):
            guard state.table.rowIndex(of: id) != nil else {
                return "delete of a deleted row \(id.raw)"
            }
            state.table.deleteRow(id)
            state.pins = state.pins.filter { $0.key.row != id }
            return nil
        case let .deleteColumn(id):
            guard state.table.columnIndex(of: id) != nil else {
                return "delete of a deleted column \(id.raw)"
            }
            state.table.deleteColumn(id)
            state.pins = state.pins.filter { $0.key.column != id }
            return nil
        case let .reviveRow(id):
            guard state.table.reviveRow(id) else {
                return "revive of row \(id.raw), which is not deleted"
            }
            return nil
        case let .reviveColumn(id):
            guard state.table.reviveColumn(id) else {
                return "revive of column \(id.raw), which is not deleted"
            }
            return nil
        case let .moveRow(id, after, _):
            guard state.table.rowIndex(of: id) != nil, after != id else {
                return "move of a deleted row \(id.raw)"
            }
            state.table.moveRow(id, after: after)
            return nil
        case let .moveColumn(id, after, _):
            guard state.table.columnIndex(of: id) != nil, after != id else {
                return "move of a deleted column \(id.raw)"
            }
            state.table.moveColumn(id, after: after)
            return nil
        }
    }

    /// Does this op name a row or column that has no slot at all — never
    /// inserted, as opposed to deleted? A move's `after:` anchor is not asked:
    /// an unknown anchor places at the end, as an insert's does.
    private static func namesAnUnseenID(_ kind: OpKind, _ p: FigureOpPayload, in table: FigureTable) -> Bool {
        func unseen(_ r: RowID) -> Bool { table.rowSlotIndex(of: r) == nil }
        func unseen(_ c: ColumnID) -> Bool { table.columnSlotIndex(of: c) == nil }
        switch kind {
        case .figureCellSet, .figurePinSet, .figurePinClear:
            guard let key = p.cell else { return false }
            return unseen(key.row) || unseen(key.column)
        case .figureSettings:
            if case let .columnWidth(column, _, _)? = p.settings { return unseen(column) }
            return false
        case .figureStructure:
            switch p.structure {
            case let .deleteRow(r)?, let .moveRow(r, _, _)?, let .reviveRow(r)?: return unseen(r)
            case let .deleteColumn(c)?, let .moveColumn(c, _, _)?, let .reviveColumn(c)?: return unseen(c)
            default: return false
            }
        default:
            return false
        }
    }

    /// The kinds that change a figure's content — everything but its
    /// lifecycle (create, park, resume). What a park stops folding.
    private static func isContent(_ kind: OpKind) -> Bool {
        switch kind {
        case .figureCellSet, .figureStructure, .figureSettings, .figureImageSet,
             .figurePinSet, .figurePinClear:
            return true
        default:
            return false
        }
    }

    /// One slice entry back onto its (live) cell.
    private static func restore(_ entry: FigureRemovedSlice.Entry, at key: CellKey, into state: inout FigureState) {
        if let cell = entry.cell { state.table.setCell(cell, at: key) }
        if let pins = entry.pins, !pins.isEmpty { state.pins[key] = pins }
    }

    private static func isLive(_ key: CellKey, in table: FigureTable) -> Bool {
        table.rowIndex(of: key.row) != nil && table.columnIndex(of: key.column) != nil
    }

    /// Two pins read the same source cell: one research item, one row and column.
    private static func sameSource(_ a: FigureResearchPin, _ b: FigureResearchPin) -> Bool {
        a.research == b.research && a.row == b.row && a.column == b.column
    }
}

extension FigureState {
    /// **What deleting row `id` would take** (ruling P-2): its cells and pins
    /// keyed by column id, for the delete's payload, so its undo can put them
    /// back. Empty for a row that holds nothing, or that is not live.
    public func removedSlice(row id: RowID) -> FigureRemovedSlice {
        var at: [String: FigureRemovedSlice.Entry] = [:]
        for (key, cell) in table.cells where key.row == id {
            at[key.column.raw, default: .init(at: key.column.raw)].cell = cell
        }
        for (key, list) in pins where key.row == id && !list.isEmpty {
            at[key.column.raw, default: .init(at: key.column.raw)].pins = list
        }
        return FigureRemovedSlice(cells: Array(at.values))
    }

    /// The column's twin of `removedSlice(row:)`: keyed by row id, with its width.
    public func removedSlice(column id: ColumnID) -> FigureRemovedSlice {
        var at: [String: FigureRemovedSlice.Entry] = [:]
        for (key, cell) in table.cells where key.column == id {
            at[key.row.raw, default: .init(at: key.row.raw)].cell = cell
        }
        for (key, list) in pins where key.column == id && !list.isEmpty {
            at[key.row.raw, default: .init(at: key.row.raw)].pins = list
        }
        return FigureRemovedSlice(cells: Array(at.values), width: table.columnWidths[id])
    }
}
