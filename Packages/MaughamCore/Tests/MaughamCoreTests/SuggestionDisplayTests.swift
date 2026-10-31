import XCTest
@testable import MaughamCore

final class SuggestionDisplayTests: XCTestCase {

    private func suggestion(span: SpanAnchor?, prior: String?, suggested: String?) -> Annotation {
        Annotation(
            id: "op1", kind: .suggestedChange, paragraphId: "p1",
            body: "", suggestedText: suggested, priorText: prior,
            createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false,
            span: span)
    }

    /// Span suggestion → the "before" is the span's original text, so the diff
    /// reads `very angry → furious`, not `<whole paragraph> → furious`.
    func test_before_spanSuggestion_isTheSpanText() {
        let ann = suggestion(
            span: SpanAnchor(quote: "very angry", prefix: "She was ", suffix: ".", posHint: 8),
            prior: "She was very angry.", suggested: "furious")
        XCTAssertEqual(SuggestionDisplay.before(for: ann), "very angry")
    }

    /// Paragraph-level suggestion (no span) → the "before" is the whole prior paragraph.
    func test_before_paragraphSuggestion_isThePriorParagraph() {
        let ann = suggestion(span: nil, prior: "She was angry.", suggested: "Her jaw clenched.")
        XCTAssertEqual(SuggestionDisplay.before(for: ann), "She was angry.")
    }

    /// Empty-quote span behaves as paragraph-level.
    func test_before_emptyQuoteSpan_fallsBackToParagraph() {
        let ann = suggestion(
            span: SpanAnchor(quote: "", prefix: "", suffix: "", posHint: 0),
            prior: "Whole paragraph.", suggested: "New.")
        XCTAssertEqual(SuggestionDisplay.before(for: ann), "Whole paragraph.")
    }

    /// Non-suggestions have no before/after.
    func test_before_nonSuggestion_isNil() {
        let comment = Annotation(
            id: "op2", kind: .comment, paragraphId: "p1",
            body: "nice", suggestedText: nil, priorText: "Para.",
            createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false)
        XCTAssertNil(SuggestionDisplay.before(for: comment))
    }

    // MARK: - A suggestion on a table figure (report plan 9c-1 Task 7)

    private let en = TableLocale(languageTag: "en-US", fallbackRegion: nil)
    private let es = TableLocale(languageTag: "es-ES", fallbackRegion: nil)

    private func figureNote(
        kind: AnnotationKind = .suggestedChange, anchor: FigureCellAnchor?,
        suggested: Cell?, address: String? = nil, orphaned: Bool = false
    ) -> Annotation {
        Annotation(
            id: "fig1", kind: kind, paragraphId: nil, body: "",
            suggestedText: nil, priorText: nil,
            createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil, isStale: orphaned,
            figureAnchor: anchor, suggestedCell: suggested,
            figureAddress: address, figureOrphaned: orphaned)
    }

    /// Before is the anchored cell as the table holds it now, after the
    /// proposal, each as the card shows a value.
    func test_figureCells_valueSuggestion_readsBothCellsInTheBooksLocale() {
        var table = FigureTable(rows: 3, columns: 3)
        let key = CellKey(row: table.rows[2], column: table.columns[2])
        table.setCell(Cell(content: .value(.number(11.5))), at: key)
        let ann = figureNote(anchor: FigureCellAnchor(row: key.row, column: key.column),
                             suggested: Cell(content: .value(.number(1234.5))), address: "C3")
        XCTAssertEqual(SuggestionDisplay.figureCells(for: ann, table: table, locale: en),
                       .init(before: "11.5", after: "1234.5"))
        // The book's decimal separator, not the machine form Claude wrote.
        XCTAssertEqual(SuggestionDisplay.figureCells(for: ann, table: table, locale: es)?.before, "11,5")
    }

    /// A formula reads as the formula bar shows it, by current positions; a
    /// suggestion to clear the cell reads "".
    func test_figureCells_formulaAndClear() throws {
        var table = FigureTable(rows: 3, columns: 3)
        let key = CellKey(row: table.rows[2], column: table.columns[2])
        let formula = try FormulaParser.parse("A1+B2", in: table).get()
        table.setCell(Cell(content: .formula(formula)), at: key)
        let anchor = FigureCellAnchor(row: key.row, column: key.column)
        let clear = figureNote(anchor: anchor, suggested: nil, address: "C3")
        XCTAssertEqual(SuggestionDisplay.figureCells(for: clear, table: table, locale: en),
                       .init(before: "=A1+B2", after: ""))
        // A row inserted above moves the references the formula shows.
        table.insertRow(after: nil)
        let proposed = figureNote(anchor: anchor, suggested: Cell(content: .formula(formula)), address: "C4")
        XCTAssertEqual(SuggestionDisplay.figureCells(for: proposed, table: table, locale: en)?.after, "=A2+B3")
    }

    /// An orphaned anchor has no cell to read: before is nil, after still shows.
    func test_figureCells_orphaned_hasNoBefore() {
        var table = FigureTable(rows: 3, columns: 3)
        let anchor = FigureCellAnchor(row: RowID("gone0000"), column: table.columns[0])
        table.setCell(Cell(content: .value(.number(1))), at: CellKey(row: table.rows[0], column: table.columns[0]))
        let ann = figureNote(anchor: anchor, suggested: Cell(content: .value(.text("x"))), orphaned: true)
        XCTAssertEqual(SuggestionDisplay.figureCells(for: ann, table: table, locale: en),
                       .init(before: nil, after: "x"))
    }

    /// Only a figure suggestion has cells: a figure comment, a paragraph
    /// suggestion and a whole-figure note answer nil.
    func test_figureCells_onlyForAFigureSuggestion() {
        let table = FigureTable(rows: 1, columns: 1)
        let anchor = FigureCellAnchor(row: table.rows[0], column: table.columns[0])
        XCTAssertNil(SuggestionDisplay.figureCells(
            for: figureNote(kind: .comment, anchor: anchor, suggested: nil, address: "A1"), table: table, locale: en))
        XCTAssertNil(SuggestionDisplay.figureCells(
            for: figureNote(anchor: nil, suggested: nil), table: table, locale: en))
        XCTAssertNil(SuggestionDisplay.figureCells(
            for: suggestion(span: nil, prior: "a", suggested: "b"), table: table, locale: en))
    }

    /// The anchor line: address, "cells deleted", or the figure alone.
    func test_figureAnchorLine() {
        let anchor = FigureCellAnchor(row: RowID("r0000000"), column: ColumnID("c0000000"))
        XCTAssertEqual(SuggestionDisplay.figureAnchorLine(
            for: figureNote(anchor: anchor, suggested: nil, address: "C3"), figureTitle: "Table: Sales"),
            "C3 \u{00B7} Table: Sales")
        XCTAssertEqual(SuggestionDisplay.figureAnchorLine(
            for: figureNote(anchor: anchor, suggested: nil, orphaned: true), figureTitle: "Table: Sales"),
            "cells deleted \u{00B7} Table: Sales")
        XCTAssertEqual(SuggestionDisplay.figureAnchorLine(
            for: figureNote(kind: .comment, anchor: nil, suggested: nil), figureTitle: "Table: Sales"),
            "Table: Sales")
    }
}
