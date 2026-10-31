import XCTest
import MaughamCore
@testable import Maugham

/// **Word draws a table figure's cells** (report plan 9a Task 7, spec §9): a
/// line whose figure lays out (`PublishResolution.tableFigures`) is a native
/// `<w:tbl>` after its caption — `w:tblHeader` on the header row only, the
/// header bold, `w:jc` per alignment, the total's cells ruled above. A line
/// with no layout keeps its literal paragraph.
final class DOCXTableFigureTests: XCTestCase {

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

    private func emit(_ text: String, _ figures: PublishFigures) throws -> XMLDocument {
        let context = PublishContext(
            library: CitationLibrary(items: []), profile: .report,
            switches: (numberSections: false, listOfFigures: false, listOfTables: true),
            projectURL: URL(fileURLWithPath: "/nonexistent/report-9a-docx"),
            piecePaths: ["a": "manuscript/a.md"], figures: figures)
        let source = SinglePieceSource(pieceID: "a", title: "A", mode: .prose, text: text, context: context)
        let ast = try ProjectASTBuilder.build(from: source)
        let resolution = try PublishResolution.forCompile(
            source: source, bodyTag: nil, imageAllowed: ["png"],
            tableLocale: TableLocale(languageTag: "en-US"))
        let body = DOCXBodyEmitter.emit(
            bodies: [DOCXBodyEmitter.Body(ast: ast, resolution: resolution, bodyTag: nil, figureFiles: [:])],
            config: PublishConfig(), page: .letter)
        return try XMLDocument(xmlString: body.documentXML)
    }

    private func nodes(_ doc: XMLDocument, _ xpath: String) throws -> [XMLElement] {
        try doc.nodes(forXPath: xpath).compactMap { $0 as? XMLElement }
    }

    /// Every descendant element named `name`, walked by hand: NSXML's
    /// element-relative `.//` XPath reads past the context node.
    private func descendants(_ e: XMLElement, _ name: String) -> [XMLElement] {
        (e.children ?? []).compactMap { $0 as? XMLElement }.flatMap { child in
            (child.name == name ? [child] : []) + descendants(child, name)
        }
    }

    private func texts(_ e: XMLElement) throws -> String {
        descendants(e, "w:t").compactMap(\.stringValue).joined()
    }

    private func rows(_ doc: XMLDocument) throws -> [[String]] {
        try nodes(doc, "//*[name()='w:tr']").map { tr in
            try descendants(tr, "w:tc").map { try texts($0) }
        }
    }

    private let cashLine = "![Cash flows](../figures/cash.csv){#tbl:cash}\n\nSee @tbl:cash."

    func test_headerBodyAndTotal_drawANativeTable() throws {
        let t = try table([["Item", "Amount"], ["Rent", "100"], ["Fees", "=B2*2"], ["Total", "=SUM(B2:B3)"]],
                          header: true, total: true)
        let doc = try emit(cashLine, figures(t))
        XCTAssertEqual(try rows(doc), [["Item", "Amount"], ["Rent", "100"], ["Fees", "200"], ["Total", "300"]])
        XCTAssertEqual(try nodes(doc, "//*[name()='w:tblHeader']").count, 1)
        // The header row carries it, and its runs are bold.
        let first = try XCTUnwrap(try nodes(doc, "//*[name()='w:tr']").first)
        XCTAssertEqual(descendants(first, "w:tblHeader").count, 1)
        XCTAssertEqual(descendants(first, "w:b").count, 2)
        // The total row's cells (and only they) are ruled above.
        let trs = try nodes(doc, "//*[name()='w:tr']")
        for (i, tr) in trs.enumerated() {
            let tops = descendants(tr, "w:tcBorders").flatMap { descendants($0, "w:top") }
            if i == trs.count - 1 {
                XCTAssertEqual(tops.count, 2)
                XCTAssertTrue(tops.allSatisfy { $0.attribute(forName: "w:sz")?.stringValue == "8" })
            } else {
                XCTAssertEqual(tops.count, 0, "row \(i)")
            }
        }
        let jcs = descendants(trs[1], "w:jc").compactMap { $0.attribute(forName: "w:val")?.stringValue }
        XCTAssertEqual(jcs, ["left", "right"])
        let text = try nodes(doc, "//*[name()='w:p']").map { try texts($0) }
        // NSXML drops the whitespace-only run between number and caption.
        XCTAssertTrue(text.contains("Table 1.Cash flows"), "\(text)")
        XCTAssertFalse(text.contains { $0.contains("../figures/cash.csv") }, "no literal with a layout: \(text)")
    }

    func test_captionBookmarkIsUnchanged() throws {
        let t = try table([["Item", "Amount"], ["Rent", "100"]], header: true, total: false)
        let doc = try emit(cashLine, figures(t))
        let name = DOCXNames.labelBookmark(try XCTUnwrap(ManuscriptLabel(reference: "tbl:cash")))
        let starts = try nodes(doc, "//*[name()='w:bookmarkStart']").compactMap { $0.attribute(forName: "w:name")?.stringValue }
        XCTAssertTrue(starts.contains(name), "\(starts)")
        XCTAssertEqual(try nodes(doc, "//*[name()='w:tcBorders']").count, 0, "no total, no rule")
    }

    func test_noHeader_hasNoTblHeader() throws {
        let t = try table([["1234.5"], ["=A1*2"]], header: false, total: false)
        let doc = try emit(cashLine, figures(t))
        XCTAssertEqual(try nodes(doc, "//*[name()='w:tblHeader']").count, 0)
        XCTAssertEqual(try nodes(doc, "//*[name()='w:b']").count, 0)
        XCTAssertEqual(try rows(doc).count, 2)
    }

    func test_headerOnly() throws {
        let t = try table([["Item", "Amount"]], header: true, total: false)
        let doc = try emit(cashLine, figures(t))
        XCTAssertEqual(try rows(doc), [["Item", "Amount"]])
        XCTAssertEqual(try nodes(doc, "//*[name()='w:tblHeader']").count, 1)
    }

    func test_totalOnly() throws {
        let t = try table([["1"], ["=A1*3"]], header: false, total: true)
        let doc = try emit(cashLine, figures(t))
        XCTAssertEqual(try rows(doc), [["1"], ["3"]])
        XCTAssertEqual(try nodes(doc, "//*[name()='w:tblHeader']").count, 0)
        XCTAssertEqual(try nodes(doc, "//*[name()='w:tcBorders']").count, 1)
    }

    /// M4: a table with no rows (Use in Document from an empty CSV) still
    /// writes a table Word opens — one empty row under its caption, as the
    /// PDF and EPUB show an empty table — never a `<w:tbl>` with no `<w:tr>`.
    func test_aTableWithNoRows_drawsOneEmptyRow() throws {
        var t = FigureTable(rows: 0, columns: 2)
        t.headerRows = 1
        t.hasTotalRow = true
        let doc = try emit(cashLine, figures(t))
        let tables = try nodes(doc, "//*[name()='w:tbl']")
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(try rows(doc), [["", ""]], "one empty row, as wide as the table")
        XCTAssertEqual(try nodes(doc, "//*[name()='w:tblHeader']").count, 0)
    }

    func test_specialsAreEscaped_andReadBackVerbatim() throws {
        let t = try table([["A & B", "x"], ["<i>1</i>", "\"q\""], ["[not a link]", "y"]], header: true, total: false)
        let doc = try emit(cashLine, figures(t))
        XCTAssertEqual(try rows(doc), [["A & B", "x"], ["<i>1</i>", "\"q\""], ["[not a link]", "y"]])
    }

    func test_aParkedFigure_keepsTheLiteralParagraph() throws {
        let t = try table([["Item", "Amount"], ["Rent", "100"]], header: true, total: false)
        let doc = try emit(cashLine, figures(t, parked: true))
        XCTAssertEqual(try nodes(doc, "//*[name()='w:tbl']").count, 0)
        let text = try nodes(doc, "//*[name()='w:p']").map { try texts($0) }
        XCTAssertTrue(text.contains { $0.contains("../figures/cash.csv") }, "\(text)")
    }
}
