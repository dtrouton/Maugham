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
/// - `figureCreate` — a `kind` this build knows (never `.unknown`).
/// - `figureParked` — `parkedPath` and `parkedHash` (where the stream's figure
///   went in Research, and that file's content hash).
/// - `figureResumed` — nothing.
/// - `figureCellSet` — `cell`; `next` is the new cell (nil = cleared) and
///   `prior` the cell it replaced (nil = was empty).
/// - `figureStructure` — `structure`.
/// - `figureSettings` — `settings`.
/// - `figureImageSet` — `image`; `priorImage` is the one it replaced.
/// - `figurePinSet` — `cell` and `pin`.
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
    public var parkedPath: String?
    public var parkedHash: String?

    enum CodingKeys: String, CodingKey {
        case kind, cell, next, prior, structure, settings, image
        case priorImage = "prior_image"
        case pin
        case parkedPath = "parked_path"
        case parkedHash = "parked_hash"
    }

    public init(
        kind: FigureKind? = nil, cell: CellKey? = nil,
        next: Cell? = nil, prior: Cell? = nil,
        structure: FigureStructureChange? = nil,
        settings: FigureSettingsChange? = nil,
        image: FigureImageRef? = nil, priorImage: FigureImageRef? = nil,
        pin: FigureResearchPin? = nil,
        parkedPath: String? = nil, parkedHash: String? = nil
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
        self.parkedPath = parkedPath
        self.parkedHash = parkedHash
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
        case .figureStructure: return payload.structure != nil
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
public enum FigureStructureChange: Equatable, Sendable {
    case insertRow(RowID, after: RowID?)
    case insertColumn(ColumnID, after: ColumnID?)
    case deleteRow(RowID)
    case deleteColumn(ColumnID)
    case moveRow(RowID, after: RowID?, priorAfter: RowID?)
    case moveColumn(ColumnID, after: ColumnID?, priorAfter: ColumnID?)
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
        }
    }
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

    /// **Is `filename` one plain file name** — non-empty, no `/`, `\` or
    /// NUL, and not dot-leading (so never `.` or `..`)? The name arrives in
    /// ops from other devices and is joined onto `figures/` to write the
    /// picture, so a name that could climb out of the folder is refused when
    /// read (`FigureOpPayload.validate`), never written to.
    public var isAPlainFileName: Bool {
        !filename.isEmpty && !filename.hasPrefix(".")
            && !filename.contains("/") && !filename.contains("\\") && !filename.contains("\0")
    }
}

/// **A research pin** — the value a formula last read from a Research table
/// (spec §4.3): which research item, the zero-based row and column it read,
/// the value, the source file's content hash and when it was read. Defined
/// here so the wire shape is fixed with the kinds; plan 6b sets and refreshes
/// pins.
public struct FigureResearchPin: Codable, Equatable, Sendable {
    /// The research item's id.
    public var research: String
    public var row: Int
    public var column: Int
    public var value: CellValue
    public var sourceHash: String
    public var at: Date

    enum CodingKeys: String, CodingKey {
        case research, row, column, value
        case sourceHash = "source_hash"
        case at
    }

    public init(research: String, row: Int, column: Int, value: CellValue, sourceHash: String, at: Date) {
        self.research = research
        self.row = row
        self.column = column
        self.value = value
        self.sourceHash = sourceHash
        self.at = at
    }
}
