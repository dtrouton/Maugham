import Foundation

/// What a figure is: a table of cells, or an image. Fixed at `figureCreate`
/// and recorded again in the manifest's figure registry.
///
/// **Lossless for a later build's word** (ADR 0015, ruling R-6a-3). A kind
/// is identity-bearing and sits in the manifest, so a word this build has
/// never seen decodes as `.unknown(raw)` and re-encodes as that same string:
/// the manifest still opens, and an older Mac that re-saves it relabels
/// nothing. Nothing creates `.unknown`, and `FigureOpPayload.validate` refuses
/// it for `figureCreate`. Not a `String`-raw enum, because the associated
/// value cannot ride on `rawValue`; the coding is hand-written.
public enum FigureKind: Codable, Equatable, Hashable, Sendable {
    case table
    case image
    /// A kind word from a later build, kept verbatim.
    case unknown(String)

    /// The kinds this build knows — what a surface may offer.
    public static let known: [FigureKind] = [.table, .image]

    /// The wire word.
    public var rawValue: String {
        switch self {
        case .table: return "table"
        case .image: return "image"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "table": self = .table
        case "image": self = .image
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// **A figure op's content** — `Op.figure`, JSON key `"figure"` (ruling D-a).
/// A figure op keeps the shared envelope (`changes: []`, `sequence: nil`), so
/// the chain, seal, trust, partition, backup signature and integrity checks
/// treat it as any other op line; everything the op says about the table
/// rides here and never in `changes`.
///
/// Every field is optional; which ones a kind needs is `validate(kind:payload:)`:
/// - `figureCreate` — a `kind` this build knows (never `.unknown`). A figure
///   made from a Research item by *Use in document* also carries `source`.
/// - `figureParked` — `parkedPath` and `parkedHash` (where the stream's figure
///   went in Research, and that file's content hash); `parkedItemId`, the
///   Research item holding that file, when known (report plan 6b Task 7);
///   `parkedFrontier`, what the parker had read (Task 8).
/// - `figureResumed` — nothing.
/// - `figureCellSet` — `cell`; `next` is the new cell (nil = cleared) and
///   `prior` the cell it replaced (nil = was empty).
/// - `figureStructure` — `structure`. A delete may carry `removed`, what it
///   took (ruling P-2); a revive must carry the slice it puts back.
/// - `figureSettings` — `settings`.
/// - `figureImageSet` — `image`; `priorImage` is the one it replaced.
/// - `figurePinSet` — `cell` and `pin`; `priorPin` is the pin from the same
///   source cell it replaced (nil = the cell held none), so its undo is
///   payload-only (ruling P-8).
/// - `figurePinClear` — `cell` (`pin`, when present, names the one cleared).
///
/// The wire shape is append-only history: a field renamed here is a field
/// every existing op log silently loses. A new case of either change enum
/// below is a new wire word, and so needs `OpKind`'s schema bump.
public struct FigureOpPayload: Codable, Equatable, Sendable {
    public var kind: FigureKind?
    public var cell: CellKey?
    public var next: Cell?
    public var prior: Cell?
    public var structure: FigureStructureChange?
    public var settings: FigureSettingsChange?
    public var image: FigureImageRef?
    public var priorImage: FigureImageRef?
    public var pin: FigureResearchPin?
    /// **The pin a `figurePinSet` replaced** (ruling P-8, report plan 6b
    /// Task 9): the cell's pin from the same source cell before the set, nil
    /// when it held none. Optional on the wire; `validate` does not ask for it.
    public var priorPin: FigureResearchPin?
    public var parkedPath: String?
    public var parkedHash: String?
    /// **The Research item a park wrote its working copy as** (spec §4.2,
    /// report plan 6b Task 7): its `ResearchItem.id`, which survives the typed
    /// mover's renames and moves where `parkedPath` does not. Optional on the
    /// wire; `validate` does not ask for it.
    public var parkedItemId: String?
    /// **What the parker had read when it parked** (report plan 6b Task 8):
    /// for each device stream, by its `Op.device`, the last op id the parking
    /// host had folded. The return folds the stream limited to it to find the
    /// state the working copy was written from, so an edit that sorts before
    /// the park but that the parker never saw (a skewed clock) survives a
    /// changed copy coming back (`FigureReturnDiff.base(of:streams:frontier:)`).
    /// Optional on the wire; `validate` does not ask for it.
    public var parkedFrontier: [String: String]?
    /// **What a row or column delete took, or what a revive puts back**
    /// (ruling P-2). The host fills it at delete time so `FigureInverse`
    /// stays payload-only. Nil on a delete that did not record it — a delete
    /// with nothing to put back offers no undo; an empty slice is a row or
    /// column that held nothing (an insert's undo).
    public var removed: FigureRemovedSlice?
    /// **The Research item a figure was made from** (spec §4.1, report plan
    /// 6b Task 6), on its `figureCreate`: nil for a figure made in the book.
    public var source: FigureSource?
    /// **The resume a return's content op belongs to** (report plan 6b final
    /// review M-2): the op id of the `figureResumed` it follows. A return
    /// whose resume the stream drops (a second Mac brought the same figure
    /// back at once) folds none of its content ops (`FigureDeriver`). Optional
    /// on the wire; `validate` does not ask for it.
    public var returnOf: String?

    enum CodingKeys: String, CodingKey {
        case kind, cell, next, prior, structure, settings, image
        case priorImage = "prior_image"
        case pin
        case priorPin = "prior_pin"
        case parkedPath = "parked_path"
        case parkedHash = "parked_hash"
        case parkedItemId = "parked_item_id"
        case parkedFrontier = "parked_frontier"
        case removed
        case source
        case returnOf = "return_of"
    }

    public init(
        kind: FigureKind? = nil, cell: CellKey? = nil,
        next: Cell? = nil, prior: Cell? = nil,
        structure: FigureStructureChange? = nil,
        settings: FigureSettingsChange? = nil,
        image: FigureImageRef? = nil, priorImage: FigureImageRef? = nil,
        pin: FigureResearchPin? = nil, priorPin: FigureResearchPin? = nil,
        parkedPath: String? = nil, parkedHash: String? = nil,
        parkedItemId: String? = nil,
        parkedFrontier: [String: String]? = nil,
        removed: FigureRemovedSlice? = nil,
        source: FigureSource? = nil,
        returnOf: String? = nil
    ) {
        self.kind = kind
        self.cell = cell
        self.next = next
        self.prior = prior
        self.structure = structure
        self.settings = settings
        self.image = image
        self.priorImage = priorImage
        self.pin = pin
        self.priorPin = priorPin
        self.parkedPath = parkedPath
        self.parkedHash = parkedHash
        self.parkedItemId = parkedItemId
        self.parkedFrontier = parkedFrontier
        self.removed = removed
        self.source = source
        self.returnOf = returnOf
    }

    /// The nine figure op kinds, in the order `OpKind` declares them.
    public static let kinds: [OpKind] = [
        .figureCreate, .figureParked, .figureResumed, .figureCellSet,
        .figureStructure, .figureSettings, .figureImageSet,
        .figurePinSet, .figurePinClear,
    ]

    /// **Does this payload carry what `kind` needs?** The table is the type's
    /// doc comment. A kind that is not a figure kind never carries a payload,
    /// so it answers false.
    public static func validate(kind: OpKind, payload: FigureOpPayload) -> Bool {
        // A picture's file name is joined onto `figures/`: one that could
        // leave the folder makes the whole op invalid, whatever its kind.
        for image in [payload.image, payload.priorImage].compactMap({ $0 })
        where !image.isAPlainFileName { return false }
        switch kind {
        case .figureCreate:
            // A later build's kind is kept when read, never created here.
            switch payload.kind {
            case .table?, .image?: return true
            case .unknown?, nil: return false
            }
        case .figureParked: return payload.parkedPath != nil && payload.parkedHash != nil
        case .figureResumed: return true
        case .figureCellSet: return payload.cell != nil
        case .figureStructure:
            // A revive puts back a slice, so it carries one (an empty one
            // for a row or column that held nothing).
            switch payload.structure {
            case .reviveRow?, .reviveColumn?: return payload.removed != nil
            case nil: return false
            default: return true
            }
        case .figureSettings: return payload.settings != nil
        case .figureImageSet: return payload.image != nil
        case .figurePinSet: return payload.cell != nil && payload.pin != nil
        case .figurePinClear: return payload.cell != nil
        default: return false
        }
    }
}

/// A change to a table's rows or columns. Ids, never positions: `after` is the
/// slot the row or column lands after (nil = first), and a move's `priorAfter`
/// is where it stood, so its inverse is a move back.
///
/// On the wire: `{"change": "insert_row", "row": "…", "after": "…"}` — a word
/// and flat ids, so a later reader needs no knowledge of Swift's enum coding.
///
/// **A revive** (`revive_row` / `revive_column`, ruling P-1, schema 10) clears
/// a deleted row's or column's tombstone in place — its own slot, so its own
/// position — and puts back the payload's `removed` slice. An insert of a
/// tombstoned id stays refused: only a revive brings one back.
public enum FigureStructureChange: Equatable, Sendable {
    case insertRow(RowID, after: RowID?)
    case insertColumn(ColumnID, after: ColumnID?)
    case deleteRow(RowID)
    case deleteColumn(ColumnID)
    case moveRow(RowID, after: RowID?, priorAfter: RowID?)
    case moveColumn(ColumnID, after: ColumnID?, priorAfter: ColumnID?)
    case reviveRow(RowID)
    case reviveColumn(ColumnID)
}

extension FigureStructureChange: Codable {
    private enum CodingKeys: String, CodingKey {
        case change, row, column, after
        case priorAfter = "prior_after"
    }

    private enum Word: String, Codable {
        case insertRow = "insert_row"
        case insertColumn = "insert_column"
        case deleteRow = "delete_row"
        case deleteColumn = "delete_column"
        case moveRow = "move_row"
        case moveColumn = "move_column"
        case reviveRow = "revive_row"
        case reviveColumn = "revive_column"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Word.self, forKey: .change) {
        case .insertRow:
            self = .insertRow(try c.decode(RowID.self, forKey: .row),
                              after: try c.decodeIfPresent(RowID.self, forKey: .after))
        case .insertColumn:
            self = .insertColumn(try c.decode(ColumnID.self, forKey: .column),
                                 after: try c.decodeIfPresent(ColumnID.self, forKey: .after))
        case .deleteRow:
            self = .deleteRow(try c.decode(RowID.self, forKey: .row))
        case .deleteColumn:
            self = .deleteColumn(try c.decode(ColumnID.self, forKey: .column))
        case .moveRow:
            self = .moveRow(try c.decode(RowID.self, forKey: .row),
                            after: try c.decodeIfPresent(RowID.self, forKey: .after),
                            priorAfter: try c.decodeIfPresent(RowID.self, forKey: .priorAfter))
        case .moveColumn:
            self = .moveColumn(try c.decode(ColumnID.self, forKey: .column),
                               after: try c.decodeIfPresent(ColumnID.self, forKey: .after),
                               priorAfter: try c.decodeIfPresent(ColumnID.self, forKey: .priorAfter))
        case .reviveRow:
            self = .reviveRow(try c.decode(RowID.self, forKey: .row))
        case .reviveColumn:
            self = .reviveColumn(try c.decode(ColumnID.self, forKey: .column))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .insertRow(row, after):
            try c.encode(Word.insertRow, forKey: .change)
            try c.encode(row, forKey: .row)
            try c.encodeIfPresent(after, forKey: .after)
        case let .insertColumn(column, after):
            try c.encode(Word.insertColumn, forKey: .change)
            try c.encode(column, forKey: .column)
            try c.encodeIfPresent(after, forKey: .after)
        case let .deleteRow(row):
            try c.encode(Word.deleteRow, forKey: .change)
            try c.encode(row, forKey: .row)
        case let .deleteColumn(column):
            try c.encode(Word.deleteColumn, forKey: .change)
            try c.encode(column, forKey: .column)
        case let .moveRow(row, after, priorAfter):
            try c.encode(Word.moveRow, forKey: .change)
            try c.encode(row, forKey: .row)
            try c.encodeIfPresent(after, forKey: .after)
            try c.encodeIfPresent(priorAfter, forKey: .priorAfter)
        case let .moveColumn(column, after, priorAfter):
            try c.encode(Word.moveColumn, forKey: .change)
            try c.encode(column, forKey: .column)
            try c.encodeIfPresent(after, forKey: .after)
            try c.encodeIfPresent(priorAfter, forKey: .priorAfter)
        case let .reviveRow(row):
            try c.encode(Word.reviveRow, forKey: .change)
            try c.encode(row, forKey: .row)
        case let .reviveColumn(column):
            try c.encode(Word.reviveColumn, forKey: .change)
            try c.encode(column, forKey: .column)
        }
    }
}

/// **What a row or column delete took** (ruling P-2): the row's (or column's)
/// cells and research pins, each keyed by the OTHER axis's id (a row's by
/// column id, a column's by row id), and for a column its width. Entries are
/// sorted by that id and an empty position has none, so two slices of the
/// same content are equal whatever order the table holds its other axis in.
///
/// On the wire: `{"cells": [{"at": "<id>", "cell": {…}, "pins": […]}], "width": 80}`.
public struct FigureRemovedSlice: Codable, Equatable, Sendable {
    /// One position along the other axis that held a cell, pins or both.
    public struct Entry: Codable, Equatable, Sendable {
        /// The other axis's id: a column id in a row's slice, a row id in a column's.
        public var at: String
        public var cell: Cell?
        public var pins: [FigureResearchPin]?

        public init(at: String, cell: Cell? = nil, pins: [FigureResearchPin]? = nil) {
            self.at = at
            self.cell = cell
            self.pins = pins
        }
    }

    public var cells: [Entry]
    /// A column's width; nil for a row, or for a column at the automatic width.
    public var width: Double?

    public init(cells: [Entry] = [], width: Double? = nil) {
        self.cells = cells.sorted { $0.at < $1.at }
        self.width = width
    }

    /// Nothing to put back: what an insert's undo deletes, and what a redone
    /// insert revives.
    public var isEmpty: Bool { cells.isEmpty && width == nil }
}

/// A change to a table's settings, carrying the value it replaced so its
/// inverse is a swap. A column width of nil is the automatic width.
///
/// On the wire: `{"setting": "header_rows", "rows": 1, "prior_rows": 0}`,
/// `{"setting": "total_row", "total": true, "prior_total": false}`,
/// `{"setting": "column_width", "column": "…", "width": 80, "prior_width": …}`.
public enum FigureSettingsChange: Equatable, Sendable {
    case headerRows(Int, prior: Int)
    case totalRow(Bool, prior: Bool)
    case columnWidth(ColumnID, Double?, prior: Double?)
}

extension FigureSettingsChange: Codable {
    private enum CodingKeys: String, CodingKey {
        case setting, rows
        case priorRows = "prior_rows"
        case total
        case priorTotal = "prior_total"
        case column, width
        case priorWidth = "prior_width"
    }

    private enum Word: String, Codable {
        case headerRows = "header_rows"
        case totalRow = "total_row"
        case columnWidth = "column_width"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Word.self, forKey: .setting) {
        case .headerRows:
            self = .headerRows(try c.decode(Int.self, forKey: .rows),
                               prior: try c.decode(Int.self, forKey: .priorRows))
        case .totalRow:
            self = .totalRow(try c.decode(Bool.self, forKey: .total),
                             prior: try c.decode(Bool.self, forKey: .priorTotal))
        case .columnWidth:
            self = .columnWidth(try c.decode(ColumnID.self, forKey: .column),
                                try c.decodeIfPresent(Double.self, forKey: .width),
                                prior: try c.decodeIfPresent(Double.self, forKey: .priorWidth))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .headerRows(rows, prior):
            try c.encode(Word.headerRows, forKey: .setting)
            try c.encode(rows, forKey: .rows)
            try c.encode(prior, forKey: .priorRows)
        case let .totalRow(total, prior):
            try c.encode(Word.totalRow, forKey: .setting)
            try c.encode(total, forKey: .total)
            try c.encode(prior, forKey: .priorTotal)
        case let .columnWidth(column, width, prior):
            try c.encode(Word.columnWidth, forKey: .setting)
            try c.encode(column, forKey: .column)
            try c.encodeIfPresent(width, forKey: .width)
            try c.encodeIfPresent(prior, forKey: .priorWidth)
        }
    }
}

/// **Where a figure made by *Use in document* came from** (spec §4.1, report
/// plan 6b Task 6, schema 10): the Research item's id, its project-relative
/// path, and the content hash (`ContentHash.ofFile`) of its file at the moment
/// it was copied. A snapshot's record, so a later surface can say when the
/// source has changed (§4.3).
///
/// `path` arrives from other devices: it is never joined onto a folder to
/// write. A reader resolves it through `SafeRelativePath` (tripwire 58).
///
/// On the wire: `{"research_item_id": "res-…", "path": "research/x.csv",
/// "content_hash": "0123456789abcdef"}`.
public struct FigureSource: Codable, Equatable, Hashable, Sendable {
    public var researchItemId: String
    public var path: String
    public var contentHash: String

    enum CodingKeys: String, CodingKey {
        case researchItemId = "research_item_id"
        case path
        case contentHash = "content_hash"
    }

    public init(researchItemId: String, path: String, contentHash: String) {
        self.researchItemId = researchItemId
        self.path = path
        self.contentHash = contentHash
    }
}

/// An image figure's picture: its file under `figures/` and that file's
/// content hash.
public struct FigureImageRef: Codable, Equatable, Hashable, Sendable {
    public var filename: String
    public var contentHash: String

    enum CodingKeys: String, CodingKey {
        case filename
        case contentHash = "content_hash"
    }

    public init(filename: String, contentHash: String) {
        self.filename = filename
        self.contentHash = contentHash
    }

    /// **Is `filename` one plain file name** (`SafeRelativePath.isPlainFileName`,
    /// the one rule)? The name arrives in ops from other devices and is
    /// joined onto `figures/` to write the picture, so a name that could
    /// climb out of the folder is refused when read
    /// (`FigureOpPayload.validate`), never written to.
    public var isAPlainFileName: Bool { SafeRelativePath.isPlainFileName(filename) }
}

/// **A research pin** — the value a formula last read from a Research table
/// (spec §4.3): which research item, the zero-based row and column it read,
/// the value, the source file's content hash and when it was read. A ref to
/// a figure parked in Research pins the same way, `research` holding that
/// figure's id and the position its parked table's cell had (R-D2). Taken
/// when a formula is entered and refreshed by `FigureDocument.refreshPins`.
public struct FigureResearchPin: Codable, Equatable, Sendable {
    /// The research item's id.
    public var research: String
    public var row: Int
    public var column: Int
    public var value: CellValue
    public var sourceHash: String
    public var at: Date
    /// **The park cycle a pin on a parked figure was taken in** (report plan
    /// 6b Task 9 review, schema 10): that park's `FigureParking.cycle` — its
    /// working copy's item id, else its hash. A pin from an earlier park of
    /// the same figure is inert (`FigurePinChoice.isLive`): the reader keeps
    /// the new parked state, and no op clears it. Nil on a Research pin.
    public var park: String?

    enum CodingKeys: String, CodingKey {
        case research, row, column, value
        case sourceHash = "source_hash"
        case at, park
    }

    public init(research: String, row: Int, column: Int, value: CellValue, sourceHash: String, at: Date,
                park: String? = nil) {
        self.research = research
        self.row = row
        self.column = column
        self.value = value
        self.sourceHash = sourceHash
        self.at = at
        self.park = park
    }
}
