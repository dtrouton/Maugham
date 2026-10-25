import Foundation

/// **What a Research table's CSV cannot hold** (spec §4.2, report plan 6b,
/// ruling P-4): which figure it is the working copy of, that figure's name and
/// caption, its header and total rows, its cell formats and its column widths.
/// One per Research table that has one, at
/// `.maugham/research-tables/<ResearchItem.id>.json` — keyed by the item's id,
/// so the typed mover's renames and moves of the CSV never stale it.
///
/// - `figureId` names the parked figure this file is the working copy of; it
///   is how *Use in document* recognises a copy coming back (Task 8). Nil for a
///   table that was never a figure.
/// - Formats and widths are by POSITION (0-based row and column, as in the
///   CSV): the file has no row or column ids.
///
/// **Tolerant** (ADR 0015): every field may be missing, and one that cannot be
/// read takes its default, so a sidecar written by a later build, or damaged,
/// still reads; keys it does not know are ignored. A Research file follows
/// Research rules — plain, last writer wins, unsigned (spec §4.2).
public struct ResearchTableSidecar: Codable, Equatable, Sendable {

    /// One cell's format and alignment, by position.
    public struct CellStyle: Codable, Equatable, Sendable {
        public var row: Int
        public var column: Int
        public var format: CellFormat
        public var alignment: CellAlignment

        public init(row: Int, column: Int, format: CellFormat = CellFormat(),
                    alignment: CellAlignment = .automatic) {
            self.row = row
            self.column = column
            self.format = format
            self.alignment = alignment
        }

        enum CodingKeys: String, CodingKey { case row, column, format, alignment }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            row = try c.decode(Int.self, forKey: .row)
            column = try c.decode(Int.self, forKey: .column)
            format = (try? c.decodeIfPresent(CellFormat.self, forKey: .format)) ?? CellFormat()
            alignment = (try? c.decodeIfPresent(CellAlignment.self, forKey: .alignment)) ?? .automatic
        }
    }

    public var figureId: String?
    public var name: String?
    public var caption: String?
    public var headerRows: Int
    public var totalRow: Bool
    public var formats: [CellStyle]
    /// Each column's width by position; nil is the automatic width.
    public var columnWidths: [Double?]

    public init(
        figureId: String? = nil, name: String? = nil, caption: String? = nil,
        headerRows: Int = 0, totalRow: Bool = false,
        formats: [CellStyle] = [], columnWidths: [Double?] = []
    ) {
        self.figureId = figureId
        self.name = name
        self.caption = caption
        self.headerRows = headerRows
        self.totalRow = totalRow
        self.formats = formats
        self.columnWidths = columnWidths
    }

    enum CodingKeys: String, CodingKey {
        case figureId = "figure_id"
        case name, caption
        case headerRows = "header_rows"
        case totalRow = "total_row"
        case formats
        case columnWidths = "column_widths"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        figureId = (try? c.decodeIfPresent(String.self, forKey: .figureId)) ?? nil
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        caption = (try? c.decodeIfPresent(String.self, forKey: .caption)) ?? nil
        headerRows = (try? c.decodeIfPresent(Int.self, forKey: .headerRows)) ?? 0
        totalRow = (try? c.decodeIfPresent(Bool.self, forKey: .totalRow)) ?? false
        // One unreadable style drops that style, never the rest.
        formats = ((try? c.decodeIfPresent([Lenient<CellStyle>].self, forKey: .formats)) ?? nil)?
            .compactMap(\.value) ?? []
        columnWidths = (try? c.decodeIfPresent([Double?].self, forKey: .columnWidths)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(figureId, forKey: .figureId)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(caption, forKey: .caption)
        try c.encode(headerRows, forKey: .headerRows)
        try c.encode(totalRow, forKey: .totalRow)
        try c.encode(formats, forKey: .formats)
        try c.encode(columnWidths, forKey: .columnWidths)
    }

    /// An element that decodes to nil instead of failing its array.
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    // MARK: - On disk

    /// The folder every Research table sidecar lives in, project-relative.
    /// Spelled here only (`MaughamSidecarPath` asks it).
    public static let folder = ".maugham/research-tables"

    /// **Where item `itemId`'s sidecar lives**: `<folder>/<itemId>.json`. The
    /// id comes from the synced manifest, so it must be a doc id that can name
    /// a file (`SafeRelativePath.requireDocId`: one plain file name with no
    /// dot, which every minted `res-…` id is), and the folder is checked on
    /// disk (`SafeRelativePath.resolveFile`, a change form — tripwire 58).
    public static func fileURL(forItem itemId: String, in projectURL: URL) throws -> URL {
        try SafeRelativePath.requireDocId(itemId)
        return try SafeRelativePath.resolveFile(named: "\(itemId).json", in: folder, under: projectURL)
    }

    /// Item `itemId`'s sidecar, or nil when it has none. Throws for an id that
    /// cannot name a file, or a file that is there but is not a JSON object.
    public static func read(forItem itemId: String, in projectURL: URL) throws -> ResearchTableSidecar? {
        let url = try fileURL(forItem: itemId, in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url) // adr-0018-ok: a Research table's sidecar JSON, not manuscript
        return try JSONDecoder().decode(ResearchTableSidecar.self, from: data)
    }

    /// Writes item `itemId`'s sidecar, replacing any there, atomically (an
    /// atomic write replaces a link at the path rather than following it).
    public static func write(_ sidecar: ResearchTableSidecar, forItem itemId: String,
                             in projectURL: URL) throws {
        let url = try fileURL(forItem: itemId, in: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: url, options: .atomic)
    }
}
