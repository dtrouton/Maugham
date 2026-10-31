import Foundation

/// Display helpers for a suggested change's before/after, shared by the Mac
/// `AnnotationsPane` and the phone `AnnotationDetailView` so both read the same
/// (cross-surface contract).
///
/// The op stores the BARE replacement as `suggestedText` (the "after"); the
/// "before" must match its grain. For a SUB-PARAGRAPH span suggestion the
/// "before" is the span's original text (`span.quote`) — so the diff reads
/// `very angry → furious`, not `<whole paragraph> → furious` (which mis-reads as
/// "the whole paragraph will be replaced"). For a paragraph-level suggestion
/// (no span) the "before" is the whole prior paragraph.
public enum SuggestionDisplay {

    /// The "before" text to pair with `annotation.suggestedText` in a before/after
    /// diff. Returns nil for a non-suggestion. The span's `quote` is the original
    /// span text captured at creation; falls back to the whole prior paragraph.
    public static func before(for annotation: Annotation) -> String? {
        guard annotation.kind == .suggestedChange else { return nil }
        if let span = annotation.span, !span.quote.isEmpty {
            // Mirror SuggestionSplice.apply's grain decision so the previewed
            // diff is exactly what accept will do. Resolve against priorText —
            // the paragraph as it was when the suggestion was authored.
            if let prior = annotation.priorText,
               let bare = annotation.suggestedText,
               let range = SpanAnchorResolver.resolve(anchor: span, in: prior) {
                let chars = Array(prior)
                if SuggestionSplice.isWholeParagraphGrain(
                    bare: bare,
                    prefix: String(chars[..<range.lowerBound]),
                    suffix: String(chars[range.upperBound...])) {
                    return prior
                }
            }
            return span.quote
        }
        return annotation.priorText
    }
}

// MARK: - A note on a table figure (report plan 9c-1)

extension SuggestionDisplay {

    /// **A figure suggestion's before and after, as cell text** — what the
    /// Mac's queue row and the phone's detail draw for a suggested change to
    /// one cell (Mac and phone read it here, tripwire 19).
    public struct FigureCells: Equatable, Sendable {
        /// The anchored cell as the table holds it NOW — what Accept would
        /// replace. Nil when the anchor is orphaned (its row or column is
        /// gone, so there is no cell); "" for an empty cell.
        public let before: String?
        /// The cell the suggestion proposes; "" when it proposes clearing it.
        public let after: String

        public init(before: String?, after: String) {
            self.before = before
            self.after = after
        }
    }

    /// The before/after for a suggested change on a table figure, or nil for
    /// any other note (a comment, a paragraph's suggestion, a whole-figure
    /// note). `table` is the figure's current table (the one its anchor
    /// resolves against); `names` renders a formula's references to other
    /// figures and Research; `locale` is the book's.
    ///
    /// A value reads as the grid's card shows it (`CellDisplay`, under the
    /// cell's own format); a formula as the formula bar shows it, `=` and its
    /// A1 text by current positions.
    public static func figureCells(
        for annotation: Annotation, table: FigureTable,
        names: FormulaNames = .empty, locale: TableLocale
    ) -> FigureCells? {
        guard annotation.kind == .suggestedChange, let anchor = annotation.figureAnchor else { return nil }
        let key = CellKey(row: anchor.row, column: anchor.column)
        let live = table.rowIndex(of: key.row) != nil && table.columnIndex(of: key.column) != nil
        return FigureCells(
            before: live ? cellText(table[key], table: table, names: names, locale: locale) : nil,
            after: cellText(annotation.suggestedCell, table: table, names: names, locale: locale))
    }

    /// One cell as text: "" for none, a formula as `=` plus its A1 text, a
    /// value as `CellDisplay` shows it under the cell's format.
    public static func cellText(
        _ cell: Cell?, table: FigureTable, names: FormulaNames, locale: TableLocale
    ) -> String {
        guard let cell else { return "" }
        switch cell.content {
        case .formula(let formula):
            return "=" + FormulaParser.render(formula, in: table, names: names)
        case .value(let value):
            return CellDisplay.string(for: value, format: cell.format, locale: locale)
        }
    }

    /// **Where a figure note points, in words**: "C3 · Table: Sales" for a
    /// live cell or range, "cells deleted · Table: Sales" when its row or
    /// column is gone, and the figure's title alone for a note on the whole
    /// figure. `figureTitle` is the registry's `FigureRecord.listTitle`.
    public static func figureAnchorLine(for annotation: Annotation, figureTitle: String) -> String {
        if annotation.figureOrphaned { return "\(Self.cellsDeleted) \u{00B7} \(figureTitle)" }
        if let address = annotation.figureAddress { return "\(address) \u{00B7} \(figureTitle)" }
        return figureTitle
    }

    /// What an orphaned anchor says in place of its address.
    public static let cellsDeleted = "cells deleted"
}

/// **The assistant-note colour**, as sRGB components: the terracotta the
/// Mac's review render reserves for the assistant (`ReviewPalette`) and the
/// dot both surfaces put on a cell with an open note. Stated once, here
/// (tripwire 19); each surface builds its own colour type from it.
public enum AssistantNoteColour {
    public static let red = 0.78
    public static let green = 0.42
    public static let blue = 0.32
}
