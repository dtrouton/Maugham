import Foundation

/// **What a Collection piece's promotion carries of the book's figures**
/// (report plan 6c Task 4, rulings Q-4 to Q-6; Denver 2026-10-25: promotion
/// re-creates figures and leaves their history in the Collection). Pure, no
/// I/O, shared by the Mac and the phone (tripwire 19).
///
/// - **Which figures** (Q-4): the piece's own (`FigureRecord.piece`) move;
///   every other figure its text names (a `{#tbl:…}`/`{#fig:…}` label or a
///   cross-reference, or a figure line's path) or a carried figure's formula
///   reads — transitively, whole-book or another piece's — is copied and
///   stays in the Collection too.
/// - **Re-created, not moved** (Denver's ruling): a figure's history is
///   signed by every device that wrote it, and a new book holds none of their
///   keys, so its lines would be strangers there. The new stream opens with
///   the figure as its stream says it is now, written by this Mac's author.
/// - **Ids kept** (Q-5): the figure id, every row and column id and the
///   Research item ids its formulas and pins name, so a formula by id, a
///   Research table's sidecar and a pin resolve in the new book unchanged.
/// - **A parked figure is re-created, then parked again** (Q-6), naming the
///   same working copy, so it stays in Research in the new book.
public enum FigureCarry {

    /// **What a piece's text names of the figures**: the label references
    /// (`tbl:cashflow`, `fig:sites`) it defines or cross-references, and the
    /// paths its figure lines (`![…](figures/x.png)`) point at.
    public struct TextReferences: Equatable, Sendable {
        public var labels: Set<String>
        public var paths: Set<String>
        public init(labels: Set<String> = [], paths: Set<String> = []) {
            self.labels = labels
            self.paths = paths
        }
    }

    /// **What `text` names of the figures** — `text` derived from the
    /// piece's op log, never its `.md` (tripwire 20). The blocks and
    /// markers are the index's (`ManuscriptBlocks`,
    /// `ManuscriptInlineScanner`); a fenced block names nothing.
    public static func references(inText text: String) -> TextReferences {
        var out = TextReferences()
        let source = text.components(separatedBy: "\n")
        for (block, lines) in ManuscriptBlocks.parse(text) {
            switch block {
            case .table(_, _, _, _, let label?):
                out.labels.insert(label.reference)
            case .figure(_, let path, let label):
                out.paths.insert(normalised(path))
                if let label { out.labels.insert(label.reference) }
            case .other(.fence):
                continue
            default:
                break
            }
            for (marker, _) in ManuscriptInlineScanner.scan(source[lines].joined(separator: "\n")) {
                if case .crossRef(let label) = marker { out.labels.insert(label.reference) }
            }
        }
        return out
    }

    /// A figure line's path as the registry spells it: percent-decoded,
    /// without a leading `./` (`./figures/x%20y.png` → `figures/x y.png`).
    static func normalised(_ path: String) -> String {
        var p = path.removingPercentEncoding ?? path
        while p.hasPrefix("./") { p.removeFirst(2) }
        return p
    }

    /// **Can this build re-create `record`?** Only a kind it knows — the
    /// state's (its `figureCreate`'s), else the record's — can be created
    /// (`FigureOpPayload.validate`).
    public static func canRecreate(_ record: FigureRecord, state: FigureState?) -> Bool {
        FigureKind.known.contains(state?.kind ?? record.kind)
    }

    /// The label a figure of `record`'s kind and name takes in the text:
    /// `tbl:` for a table, `fig:` for an image; none for a kind this build
    /// does not know.
    public static func label(of record: FigureRecord) -> String? {
        switch record.kind {
        case .table: return "tbl:\(record.name)"
        case .image: return "fig:\(record.name)"
        case .unknown: return nil
        }
    }

    /// **The figures piece `forPiece`'s promotion carries** (Q-4), each list
    /// in registry order: `moved`, the piece's own; `copied`, every other
    /// figure `referencedLabels` or `referencedPaths` names, then every
    /// figure a carried figure's formula reads, transitively. A formula
    /// naming a figure the registry does not hold adds nothing (it reads
    /// `#REF!` already). `states` is each figure's state by id; one missing
    /// reads no figure.
    public static func figures(
        forPiece pieceId: String, records: [FigureRecord],
        referencedLabels: Set<String>, referencedPaths: Set<String> = [],
        states: [String: FigureState]
    ) -> (moved: [FigureRecord], copied: [FigureRecord]) {
        var byId: [String: FigureRecord] = [:]
        for record in records where byId[record.id] == nil { byId[record.id] = record }
        var carried = Set(records.filter { $0.piece == pieceId }.map(\.id))
        for record in records where !carried.contains(record.id) {
            let named = label(of: record).map(referencedLabels.contains) ?? false
            if named || referencedPaths.contains(record.path) { carried.insert(record.id) }
        }
        var queue = Array(carried)
        while let id = queue.popLast() {
            for read in figuresRead(by: states[id]) where !carried.contains(read) && byId[read] != nil {
                carried.insert(read)
                queue.append(read)
            }
        }
        var seen = Set<String>()
        let inOrder = records.filter { carried.contains($0.id) && seen.insert($0.id).inserted }
        return (inOrder.filter { $0.piece == pieceId }, inOrder.filter { $0.piece != pieceId })
    }

    /// **The ops that re-create `state` on an empty stream** (Q-5, Q-6), in
    /// order: `figureCreate` (the state's kind and `source`); for a table one
    /// insert per row and column slot in the table's own order with its own
    /// id, then a delete for each slot deleted there (so a range edge on a
    /// tombstone shrinks as it did), a cell set per live cell, then its header
    /// rows, total row and column widths where they are not the defaults; its
    /// live pins (`FigurePinChoice.winners` under `parks`, each source cell's
    /// winner on the cell holding it); its picture; and `figureParked` last
    /// when the state is parked, naming the same path, hash and working copy.
    /// The park's `parkedFrontier` is left nil: it names op ids, which only
    /// minting gives (`minted(_:by:)` fills it).
    ///
    /// Empty for a kind this build does not know: it cannot be created
    /// (`FigureOpPayload.validate`), so the caller names it as left behind.
    public static func openingOps(
        for record: FigureRecord, state: FigureState, parks: [String: String] = [:]
    ) -> [(kind: OpKind, payload: FigureOpPayload)] {
        guard canRecreate(record, state: state) else { return [] }
        let kind = state.kind ?? record.kind
        var out: [(kind: OpKind, payload: FigureOpPayload)] = [
            (.figureCreate, FigureOpPayload(kind: kind, source: state.source)),
        ]
        if kind == .table { out += openingPayloads(of: state.table) }
        let pins = FigurePinChoice.winners(state.pins, parks: parks).values.sorted {
            ($0.cell.row.raw, $0.cell.column.raw, $0.pin.research, $0.pin.row, $0.pin.column)
                < ($1.cell.row.raw, $1.cell.column.raw, $1.pin.research, $1.pin.row, $1.pin.column)
        }
        for (pin, cell) in pins {
            out.append((.figurePinSet, FigureOpPayload(cell: cell, pin: pin)))
        }
        if let image = state.image {
            out.append((.figureImageSet, FigureOpPayload(image: image)))
        }
        if let parked = state.parked {
            out.append((.figureParked, FigureOpPayload(
                parkedPath: parked.path, parkedHash: parked.hash, parkedItemId: parked.itemId)))
        }
        return out
    }

    /// The ops that build `table` on an empty stream, after its
    /// `figureCreate`: an insert per row slot, then per column slot, each
    /// after the one before with the table's own id; a delete per slot
    /// deleted there; a cell set per cell, row by row; then its header rows,
    /// total row and column widths where they are not the defaults. What a
    /// new figure (`createFigure`, *Use in document*) opens with too.
    public static func openingPayloads(of table: FigureTable) -> [(kind: OpKind, payload: FigureOpPayload)] {
        var out: [(kind: OpKind, payload: FigureOpPayload)] = []
        var lastRow: RowID?
        for slot in table.rowSlots {
            out.append((.figureStructure, FigureOpPayload(structure: .insertRow(slot.id, after: lastRow))))
            lastRow = slot.id
        }
        var lastColumn: ColumnID?
        for slot in table.columnSlots {
            out.append((.figureStructure, FigureOpPayload(structure: .insertColumn(slot.id, after: lastColumn))))
            lastColumn = slot.id
        }
        // A deleted slot held nothing once deleted: its delete takes an
        // empty slice.
        for slot in table.rowSlots where slot.isDeleted {
            out.append((.figureStructure, FigureOpPayload(structure: .deleteRow(slot.id), removed: FigureRemovedSlice())))
        }
        for slot in table.columnSlots where slot.isDeleted {
            out.append((.figureStructure, FigureOpPayload(structure: .deleteColumn(slot.id), removed: FigureRemovedSlice())))
        }
        for row in table.rows {
            for column in table.columns {
                let key = CellKey(row: row, column: column)
                guard let cell = table[key] else { continue }
                out.append((.figureCellSet, FigureOpPayload(cell: key, next: cell, prior: nil)))
            }
        }
        if table.headerRows != 0 {
            out.append((.figureSettings, FigureOpPayload(settings: .headerRows(table.headerRows, prior: 0))))
        }
        if table.hasTotalRow {
            out.append((.figureSettings, FigureOpPayload(settings: .totalRow(true, prior: false))))
        }
        for column in table.columns {
            guard let width = table.columnWidths[column] else { continue }
            out.append((.figureSettings, FigureOpPayload(settings: .columnWidth(column, width, prior: nil))))
        }
        return out
    }

    /// **`opening` minted in order by `mint`**, a `figureParked` among them
    /// given what the parker had read — each device's last op id minted
    /// before it, 6b's frontier shape (`FigureReturnDiff.base`) — so a
    /// return in the new book diffs against the re-created table.
    public static func minted(
        _ opening: [(kind: OpKind, payload: FigureOpPayload)],
        by mint: (OpKind, FigureOpPayload) -> Op
    ) -> [Op] {
        var out: [Op] = []
        for (kind, payload) in opening {
            var payload = payload
            if kind == .figureParked {
                var frontier: [String: String] = [:]
                for op in out { frontier[op.device] = op.opId }
                payload.parkedFrontier = frontier
            }
            out.append(mint(kind, payload))
        }
        return out
    }

    /// **The current park cycle of each parked figure in `states`**
    /// (`FigureParking.cycle`), by figure id: what `openingOps` judges pins
    /// by (`FigurePinChoice.isLive`).
    public static func parks(of states: [String: FigureState]) -> [String: String] {
        states.compactMapValues { $0.parked?.cycle }
    }

    /// **What the carried figures read that stays in the Collection** (Q-5),
    /// sorted by figure, then cell, then source: each formula cell reading a
    /// Research item not in `carriedResearch` (it reads `#REF!` in the new
    /// book once its pin is refreshed away, and has no source to refresh
    /// from); each live pin whose source is neither a carried Research item
    /// nor a carried figure (it keeps its value, with no source behind it);
    /// and each parked figure whose working copy's Research item is not
    /// carried (it cannot be brought back there). `carried` is the moved and
    /// copied figures; `states` their states by id.
    public static func leftBehindReads(
        carried: [FigureRecord], states: [String: FigureState],
        carriedResearch: Set<String>, parks: [String: String] = [:]
    ) -> [FigureCarryProblem] {
        let figureIds = Set(carried.map(\.id))
        var out = Set<FigureCarryProblem>()
        for record in carried {
            guard let state = states[record.id] else { continue }
            for (key, cell) in state.table.cells {
                guard case .formula(let formula) = cell.content else { continue }
                for item in researchRead(by: formula) where !carriedResearch.contains(item) {
                    out.insert(FigureCarryProblem(figureId: record.id, cell: key, source: item, read: .formula))
                }
            }
            for (_, winner) in FigurePinChoice.winners(state.pins, parks: parks) {
                let source = winner.pin.research
                guard !carriedResearch.contains(source), !figureIds.contains(source) else { continue }
                out.insert(FigureCarryProblem(figureId: record.id, cell: winner.cell, source: source, read: .pin))
            }
            if let parked = state.parked, !(parked.itemId.map(carriedResearch.contains) ?? false) {
                out.insert(FigureCarryProblem(
                    figureId: record.id, cell: nil, source: parked.itemId ?? parked.path, read: .parkedCopy))
            }
        }
        return out.sorted {
            ($0.figureId, $0.cell?.row.raw ?? "", $0.cell?.column.raw ?? "", $0.source, $0.read.rawValue)
                < ($1.figureId, $1.cell?.row.raw ?? "", $1.cell?.column.raw ?? "", $1.source, $1.read.rawValue)
        }
    }

    // MARK: - Reading formulas

    /// The figure ids `state`'s formulas read.
    private static func figuresRead(by state: FigureState?) -> Set<String> {
        guard let state else { return [] }
        var out = Set<String>()
        for cell in state.table.cells.values {
            guard case .formula(let formula) = cell.content else { continue }
            visitTargets(formula.expr) { if case .figure(let id) = $0 { out.insert(id) } }
        }
        return out
    }

    /// The Research item ids `formula` reads.
    private static func researchRead(by formula: Formula) -> Set<String> {
        var out = Set<String>()
        visitTargets(formula.expr) { if case .research(let id) = $0 { out.insert(id) } }
        return out
    }

    private static func visitTargets(_ e: FormulaExpr, _ visit: (RefTarget) -> Void) {
        switch e {
        case .number, .text, .bool, .missing, .error: break
        case .ref(let r): visit(r.target)
        case .range(let g): visit(g.start.target); visit(g.end.target)
        case .unary(_, let x): visitTargets(x, visit)
        case .binary(_, let l, let r): visitTargets(l, visit); visitTargets(r, visit)
        case .call(_, let arguments): for a in arguments { visitTargets(a, visit) }
        }
    }
}

/// **A read a promoted figure makes of something left in the Collection**
/// (Q-5), or a figure the promotion could not carry whole: which figure,
/// which cell (nil for anything but a formula or a pin), the source (a
/// Research item's id, a parked copy's path when the park named no item, a
/// kind's word, a picture's file name or why a removal failed) and which
/// problem it is.
public struct FigureCarryProblem: Hashable, Sendable {
    public enum Read: String, Sendable {
        /// A formula names the Research item.
        case formula
        /// A live pin holds a value read from it.
        case pin
        /// The figure is parked, and this is its working copy.
        case parkedCopy
        /// A copied figure of a kind this build cannot create, left out
        /// (`source` is the kind's word): it stays in the Collection.
        case unknownKind
        /// The picture's file (`source`) is not in `figures/`: the new
        /// book's stream names a picture it does not have.
        case pictureMissing
        /// The picture's file (`source`) is not the bytes its stream names
        /// (a newer picture not yet synced): copied as it is, and listed.
        case pictureChanged
        /// The piece's own figure arrived in the new book, but the
        /// Collection could not take its record out (`source` is why): it
        /// stands in both until the writer removes it there.
        case notRemoved
    }

    public let figureId: String
    public let cell: CellKey?
    public let source: String
    public let read: Read

    public init(figureId: String, cell: CellKey?, source: String, read: Read) {
        self.figureId = figureId
        self.cell = cell
        self.source = source
        self.read = read
    }
}
