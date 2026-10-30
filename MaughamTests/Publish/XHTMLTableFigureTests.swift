import XCTest
import MaughamCore
@testable import Maugham

/// **The EPUB draws a table figure's cells** (report plan 9a Task 6, spec §9):
/// a line whose figure lays out (`PublishResolution.tableFigures`) is a
/// `<table>` shaped like a pipe table's — `<thead>` only with a header row,
/// the total as `<tr class="total">`, the caption carrying the `tbl-` id —
/// of escaped, already-formatted cells. A line with no layout keeps its
/// literal paragraph.
final class XHTMLTableFigureTests: XCTestCase {

    private let cashID = "fig-0a1b2c3d"

    private func table(_ rows: [[String]], header: Bool, total: Bool) throws -> FigureTable {
        var table = FigureTable(rows: rows.count, columns: rows.first?.count ?? 1)
        table.headerRows = header ? 1 : 0
        table.hasTotalRow = total
        for (r, row) in rows.enumerated() {
            for (c, text) in row.enumerated() {
                let key = CellKey(row: table.rows[r], column: table.columns[c])
                if text.hasPrefix("=") {
                    guard case .success(let f) = FormulaParser.parse(String(text.dropFirst()), in: table)
                    else { throw FigureEditInvalid(reason: "the formula did not parse") }
                    table.setCell(Cell(content: .formula(f)), at: key)
                } else if let n = Double(text) {
                    table.setCell(Cell(content: .value(.number(n))), at: key)
                } else {
                    table.setCell(Cell(content: .value(.text(text))), at: key)
                }
            }
        }
        return table
    }

    private func figures(_ table: FigureTable, parked: Bool = false) -> PublishFigures {
        var book = Workbook(pins: FigurePinIndex())
        book.setTable(table, id: cashID)
        return PublishFigures(
            records: [FigureRecord(id: cashID, name: "cash", kind: .table, piece: nil, path: "figures/cash.csv")],
            states: [cashID: FigureState(kind: .table, table: table,
                                         parked: parked ? FigureParking(path: "research/cash.csv", hash: "h") : nil)],
            workbook: book, pinStatus: [:], sourceChanged: [], parked: parked ? [cashID] : [])
    }

    private func emit(_ text: String, _ figures: PublishFigures) throws -> String {
        let context = PublishContext(
            library: CitationLibrary(items: []), profile: .report,
            switches: (numberSections: false, listOfFigures: false, listOfTables: true),
            projectURL: URL(fileURLWithPath: "/nonexistent/report-9a-xhtml"),
            piecePaths: ["a": "manuscript/a.md"], figures: figures)
        let source = SinglePieceSource(pieceID: "a", title: "A", mode: .prose, text: text, context: context)
        let ast = try ProjectASTBuilder.build(from: source)
        let resolution = try PublishResolution.forCompile(
            source: source, bodyTag: nil, imageAllowed: ["png"],
            tableLocale: TableLocale(languageTag: "en-US"))
        return XHTMLBodyEmitter.emit(ast, resolution: resolution)
    }

    private let cashLine = "![Cash flows](../figures/cash.csv){#tbl:cash}\n\nSee @tbl:cash."

    func test_aHeadedTableFigureWithATotal_drawsItsCells() throws {
        let t = try table([["Item", "Amount"], ["Rent", "100"], ["Fees", "=B2*2"], ["Total", "=SUM(B2:B3)"]],
                          header: true, total: true)
        let html = try emit(cashLine, figures(t))
        XCTAssertTrue(html.contains("<thead>\n<tr><th style=\"text-align:left\">Item</th><th style=\"text-align:right\">Amount</th></tr>\n</thead>"), html)
        XCTAssertTrue(html.contains("<tr><td style=\"text-align:left\">Rent</td><td style=\"text-align:right\">100</td></tr>"), html)
        XCTAssertTrue(html.contains("<tr><td style=\"text-align:left\">Fees</td><td style=\"text-align:right\">200</td></tr>"), html)
        XCTAssertTrue(html.contains("<tr class=\"total\"><td style=\"text-align:left\">Total</td><td style=\"text-align:right\">300</td></tr>"), html)
        XCTAssertEqual(html.components(separatedBy: "class=\"total\"").count, 2, "only the last row is the total: \(html)")
        XCTAssertFalse(html.contains("../figures/cash.csv"), "no literal source with a layout: \(html)")
        XCTAssertTrue(html.contains("<span class=\"caption-number\">Table 1.</span> Cash flows"), html)
    }

    func test_theCaptionCarriesTheAddressSoALinkLands() throws {
        let t = try table([["Item", "Amount"], ["Rent", "100"]], header: true, total: false)
        let html = try emit(cashLine, figures(t))
        let id = try XCTUnwrap(html.range(of: #"<caption id="([^"]+)">"#, options: .regularExpression), html)
        let captionID = html[id].dropFirst("<caption id=\"".count).dropLast(2)
        XCTAssertTrue(captionID.hasSuffix("tbl-cash"), String(captionID))
        XCTAssertFalse(html.contains("class=\"total\""), "no total row, no total class: \(html)")
    }

    func test_noHeaderRow_hasNoThead() throws {
        let t = try table([["1234.5"], ["=A1*2"]], header: false, total: false)
        let html = try emit(cashLine, figures(t))
        XCTAssertFalse(html.contains("<thead>"), html)
        XCTAssertFalse(html.contains("<th"), html)
        XCTAssertTrue(html.contains("<tbody>"), html)
        XCTAssertTrue(html.contains("<caption id="), html)
    }

    func test_cellsAreXMLEscaped() throws {
        let t = try table([["A & B", "x"], ["<i>1</i>", "\"q\""]], header: true, total: false)
        let html = try emit(cashLine, figures(t))
        XCTAssertTrue(html.contains("A &amp; B"), html)
        XCTAssertTrue(html.contains("&lt;i&gt;1&lt;/i&gt;"), html)
        XCTAssertFalse(html.contains("<i>1</i>"), html)
    }

    func test_aParkedFigure_keepsTheLiteralParagraph() throws {
        let t = try table([["Item", "Amount"], ["Rent", "100"]], header: true, total: false)
        let html = try emit(cashLine, figures(t, parked: true))
        XCTAssertFalse(html.contains("<table"), html)
        XCTAssertTrue(html.contains("../figures/cash.csv"), html)
        XCTAssertTrue(html.contains("<p class=\"caption\">"), html)
    }
}
