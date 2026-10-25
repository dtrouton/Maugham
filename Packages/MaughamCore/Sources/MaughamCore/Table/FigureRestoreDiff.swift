import Foundation

/// **A figure wound back to a checkpoint** (report plan 6c Task 1, ruling
/// Q-1): the ops that turn the figure as its stream now says into the figure
/// as it stood at the checkpoint's op pointer. Pure, no I/O, shared by the Mac
/// and the phone (tripwire 19). Ordinary figure ops — no new kind; the host
/// stamps each with the checkpoint (`Op.Provenance.sourceCheckpoint`).
///
/// **By id**, never by matching: both states come from the same stream, so a
/// row or column is the same row or column in each (unlike a return from
/// Research, whose CSV has no ids — `FigureReturnDiff.changes`).
/// - Live at the checkpoint, deleted now → `revive_row` / `revive_column` in
///   its own slot, carrying the checkpoint's slice. Columns revive before
///   rows, and each revive carries only the cells whose other axis is live
///   by then, so nothing it carries is dropped; a cell crossing a revived row
///   and a revived column rides the row's revive.
/// - Live now and deleted at the checkpoint, or inserted since (unknown to
///   it) → deleted, carrying `removedSlice` so the delete keeps what it took.
/// - Live at the checkpoint and unknown now (a stream that lost ops) → inserted.
/// - Order → moves (`FigureReturnDiff.place`, shared); cells (content, format,
///   alignment) → cell sets with `prior`; header rows, total row, widths →
///   settings; pins → pin set / clear; a different picture → one image change
///   (whether its bytes still exist is the caller's question). A picture set
///   since a checkpoint that had none stays: no op takes a picture away.
/// - **A pin live now is never replaced by one inert now** (ruling, plan 6c
///   Task 1 review): where the checkpoint's pin on a cell reads a figure
///   parked now under another park cycle (`FigurePinChoice.isLive` against
///   `parks`) and the cell's pin from that same source counts now, the
///   current pin is left as it is — restoring it would only unpin the cell.
///
/// Every change is made against the state the ones before it left, through
/// `FigureReturnDiff.Simulation`, so `FigureReturnDiff.everyChangeApplies`
/// accepts them onto `current`. A parked target or current is the caller's
/// concern: the diff reads both as tables.
public enum FigureRestoreDiff {

    /// **The figure at the checkpoint**: the fold of the stream's ops whose
    /// id is at or below `pointer` — the approximation the text's partial
    /// restore uses (a checkpoint keeps one op id per stream, not a frontier).
    public static func target(of ops: [Op], through pointer: String) -> FigureState {
        FigureDeriver.derive(ops.filter { $0.opId <= pointer })
    }

    /// The ops, in order, that bring `current` to `target`'s content; empty
    /// when they already agree. `parks` is the book's park cycle of each
    /// figure parked now (figure id → `FigureParking.cycle`), what
    /// `FigurePinChoice.isLive` reads; empty, every pin counts.
    public static func changes(
        from current: FigureState, to target: FigureState, parks: [String: String] = [:]
    ) -> [FigureReturnDiff.Change] {
        var sim = FigureReturnDiff.Simulation(state: current)
        let goal = target.table

        // MARK: Structure — deletes, revives (columns first), then each axis in order
        for id in sim.state.table.columns where goal.columnIndex(of: id) == nil {
            sim.emit(.figureStructure, FigureOpPayload(
                structure: .deleteColumn(id), removed: sim.state.removedSlice(column: id)))
        }
        for id in sim.state.table.rows where goal.rowIndex(of: id) == nil {
            sim.emit(.figureStructure, FigureOpPayload(
                structure: .deleteRow(id), removed: sim.state.removedSlice(row: id)))
        }
        for id in goal.columns where sim.state.table.columnSlotIndex(of: id) != nil && !sim.isLive(id) {
            let slice = target.removedSlice(column: id)
            sim.emit(.figureStructure, FigureOpPayload(
                structure: .reviveColumn(id),
                removed: FigureRemovedSlice(
                    cells: slice.cells.filter { sim.isLive(RowID($0.at)) }, width: slice.width)))
        }
        for id in goal.rows where sim.state.table.rowSlotIndex(of: id) != nil && !sim.isLive(id) {
            let slice = target.removedSlice(row: id)
            sim.emit(.figureStructure, FigureOpPayload(
                structure: .reviveRow(id),
                removed: FigureRemovedSlice(cells: slice.cells.filter { sim.isLive(ColumnID($0.at)) })))
        }
        FigureReturnDiff.place(
            goal.columns, fresh: Set(goal.columns.filter { sim.state.table.columnSlotIndex(of: $0) == nil }), in: &sim)
        FigureReturnDiff.place(
            goal.rows, fresh: Set(goal.rows.filter { sim.state.table.rowSlotIndex(of: $0) == nil }), in: &sim)

        // MARK: Cells — every cell the two now disagree on, in a stable order
        for key in sortedKeys(Set(sim.state.table.cells.keys).union(goal.cells.keys)) {
            let now = sim.state.table[key], wanted = goal[key]
            guard now != wanted else { continue }
            sim.emit(.figureCellSet, FigureOpPayload(cell: key, next: wanted, prior: now))
        }

        // MARK: Settings
        if sim.state.table.headerRows != goal.headerRows {
            sim.emit(.figureSettings, FigureOpPayload(
                settings: .headerRows(goal.headerRows, prior: sim.state.table.headerRows)))
        }
        if sim.state.table.hasTotalRow != goal.hasTotalRow {
            sim.emit(.figureSettings, FigureOpPayload(
                settings: .totalRow(goal.hasTotalRow, prior: sim.state.table.hasTotalRow)))
        }
        for column in goal.columns {
            let now = sim.state.table.columnWidths[column], wanted = goal.columnWidths[column]
            guard now != wanted else { continue }
            sim.emit(.figureSettings, FigureOpPayload(settings: .columnWidth(column, wanted, prior: now)))
        }

        // MARK: Pins
        for key in sortedKeys(Set(sim.state.pins.keys).union(target.pins.keys)) {
            restorePins(at: key, to: target.pins[key] ?? [], parks: parks, in: &sim)
        }

        // MARK: Picture
        if let picture = target.image, sim.state.image != picture {
            sim.emit(.figureImageSet, FigureOpPayload(image: picture, priorImage: sim.state.image))
        }

        return sim.ops
    }

    /// Brings one cell's pin list to `wanted`, in its order. A pin set
    /// replaces the pin from its source cell in place and appends a new
    /// source, so the pins that stay are kept when they already stand in
    /// `wanted`'s order; otherwise the cell is cleared and set afresh. A
    /// wanted pin inert under `parks` whose source's current pin counts
    /// gives way to that current pin.
    private static func restorePins(
        at key: CellKey, to target: [FigureResearchPin], parks: [String: String],
        in sim: inout FigureReturnDiff.Simulation
    ) {
        let now = sim.state.pins[key] ?? []
        func source(_ p: FigureResearchPin) -> PinRead { PinRead(source: p.research, row: p.row, column: p.column) }
        let wanted = target.map { pin -> FigureResearchPin in
            guard !FigurePinChoice.isLive(pin, parks: parks),
                  let live = now.first(where: { source($0) == source(pin) && FigurePinChoice.isLive($0, parks: parks) })
            else { return pin }
            return live
        }
        guard now != wanted else { return }
        let wantedSources = wanted.map(source)
        let kept = now.filter { wantedSources.contains(source($0)) }
        if wanted.isEmpty || !wantedSources.starts(with: kept.map(source)) {
            sim.emit(.figurePinClear, FigureOpPayload(cell: key))
        } else {
            for pin in now where !wantedSources.contains(source(pin)) {
                sim.emit(.figurePinClear, FigureOpPayload(cell: key, pin: pin))
            }
        }
        for pin in wanted {
            let held = (sim.state.pins[key] ?? []).first { source($0) == source(pin) }
            guard held != pin else { continue }
            sim.emit(.figurePinSet, FigureOpPayload(cell: key, pin: pin, priorPin: held))
        }
    }

    private static func sortedKeys(_ keys: Set<CellKey>) -> [CellKey] {
        keys.sorted { ($0.row.raw, $0.column.raw) < ($1.row.raw, $1.column.raw) }
    }
}
