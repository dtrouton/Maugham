import Foundation
import CoreGraphics

/// **What the editor's card under a table figure's line shows** (report plan 7a): the
/// first rows of the computed table as display strings, and the height they reserve.
/// Pure values; the Mac draws them and passes its own metrics to `FigureCardLayout`.
public struct FigureCardModel: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case table, image, removed, ambiguous, parked }

    /// The most rows a card shows, header and total rows included.
    public static let maxShownRows = 12

    public var kind: Kind
    public var headerRows: [[String]]
    public var bodyRows: [[String]]
    /// Rows past the shown ones ("+ N more rows").
    public var moreRows: Int
    /// The last of `bodyRows` is the total row (it is kept when the rest is cut short).
    public var hasTotalRow: Bool
    /// One per column, never `.automatic`: a column's first filled cell, else numbers and dates right, text left.
    public var columnAlignments: [CellAlignment]
    /// The figure holds at least one research pin (`state.pins` is non-empty).
    public var readsResearch: Bool
    /// A source a pin read has changed since the pin was taken.
    public var pinChanged: Bool
    /// The figure was made from a Research item (*Use in document*).
    public var fromResearchSource: Bool

    public init(
        kind: Kind, headerRows: [[String]] = [], bodyRows: [[String]] = [], moreRows: Int = 0,
        hasTotalRow: Bool = false, columnAlignments: [CellAlignment] = [],
        readsResearch: Bool = false, pinChanged: Bool = false, fromResearchSource: Bool = false
    ) {
        self.kind = kind; self.headerRows = headerRows; self.bodyRows = bodyRows; self.moreRows = moreRows
        self.hasTotalRow = hasTotalRow; self.columnAlignments = columnAlignments
        self.readsResearch = readsResearch; self.pinChanged = pinChanged; self.fromResearchSource = fromResearchSource
    }

    /// A card with no table: removed, ambiguous, parked or image (drawn labelled at the placeholder height).
    public static func placeholder(_ kind: Kind) -> FigureCardModel { FigureCardModel(kind: kind) }

    public var shownRowCount: Int { headerRows.count + bodyRows.count }

    /// - `values`: the computed value at a cell of this figure (bind `Workbook.value(at:)` to its id).
    /// - `labelLookup`: `(figureId, row, column, language)`'s stored translation of a text cell, or nil;
    ///   consulted only for text cells and only when non-nil. Always nil until plan 9 stores translations.
    /// - `pinChanged`: the caller's answer from `PinStatus` (any `.sourceChanged`).
    public static func build(
        figureId: String,
        state: FigureState,
        values: (CellKey) -> CellValue,
        locale: TableLocale,
        language: String?,
        labelLookup: ((String, RowID, ColumnID, String?) -> String?)? = nil,
        pinChanged: Bool = false
    ) -> FigureCardModel {
        if state.parked != nil { return placeholder(.parked) }
        if state.kind == .image { return placeholder(.image) }
        let table = state.table
        let rows = table.rows, columns = table.columns
        let headerCount = min(table.headerRows, rows.count)
        let totalIndex = table.hasTotalRow && rows.count > headerCount ? rows.count - 1 : nil

        func text(_ row: RowID, _ column: ColumnID) -> String {
            let key = CellKey(row: row, column: column)
            let value = values(key)
            if case .text = value, let label = labelLookup?(figureId, row, column, language) { return label }
            return CellDisplay.string(for: value, format: table[key]?.format ?? CellFormat(), locale: locale)
        }
        func line(_ i: Int) -> [String] { columns.map { text(rows[i], $0) } }

        let budget = max(maxShownRows - headerCount, 0)
        var bodyIndexes = Array(headerCount..<rows.count)
        if bodyIndexes.count > budget {
            if let totalIndex, budget > 0 {
                bodyIndexes = Array(bodyIndexes.prefix(budget - 1)) + [totalIndex]
            } else {
                bodyIndexes = Array(bodyIndexes.prefix(budget))
            }
        }
        let shown = headerCount + bodyIndexes.count

        let alignments: [CellAlignment] = columns.map { column in
            for i in bodyIndexes {
                let key = CellKey(row: rows[i], column: column)
                let v = values(key)
                if v == .empty { continue }
                if let a = table[key]?.alignment, a != .automatic { return a }
                switch v { case .number, .date: return .right; default: return .left }
            }
            return .left
        }

        return FigureCardModel(
            kind: .table,
            headerRows: (0..<headerCount).map(line),
            bodyRows: bodyIndexes.map(line),
            moreRows: rows.count - shown,
            hasTotalRow: totalIndex != nil && bodyIndexes.last == totalIndex,
            columnAlignments: alignments,
            readsResearch: !state.pins.isEmpty,
            pinChanged: pinChanged,
            fromResearchSource: state.source != nil
        )
    }
}

/// **The height a card reserves under its figure line**: a pure function of the model and
/// plain metrics, so Core stays platform-free. The Mac passes its font's row height and
/// `FigureThumbnailLayout.reservedHeight` as `placeholderHeight`.
public enum FigureCardLayout {
    /// Rows are one line each (long cells truncate), so `columnWidth` does not change the height today.
    /// The "+ N more rows" line and the pin-changed banner each take one `moreLineHeight` line of
    /// their own, so neither covers a row.
    public static func height(
        for model: FigureCardModel, columnWidth: CGFloat,
        rowHeight: CGFloat, moreLineHeight: CGFloat, verticalPadding: CGFloat,
        placeholderHeight: CGFloat
    ) -> CGFloat {
        guard model.kind == .table, model.shownRowCount > 0 else { return placeholderHeight }
        let more = model.moreRows > 0 ? moreLineHeight : 0
        let banner = model.pinChanged ? moreLineHeight : 0
        return CGFloat(model.shownRowCount) * rowHeight + more + banner + 2 * verticalPadding
    }
}
