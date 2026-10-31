import XCTest
import MaughamCore
@testable import Maugham

/// **The PDF draws a table figure's cells** (report plan 9a Task 5, spec §9):
/// a line whose figure lays out (`PublishResolution.tableFigures`) is a
/// `MaughamTable` like a pipe table — or `MaughamTableNoHead` with no header
/// row — of its formatted, escaped cells, the total row ruled above. A line
/// with no layout keeps the literal float.
final class LaTeXTableFigureTests: XCTestCase {

    private let cashID = "fig-0a1b2c3d"

    // MARK: - fixtures

    /// `rows` as text or numbers (a `=` string is a formula), header and total
    /// rows as asked.
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

    private func emit(_ text: String, _ figures: PublishFigures, isFirstBody: Bool = true) throws -> String {
        let context = PublishContext(
            library: CitationLibrary(items: []), profile: .report,
            switches: (numberSections: false, listOfFigures: false, listOfTables: true),
            projectURL: URL(fileURLWithPath: "/nonexistent/report-9a-latex"),
            piecePaths: ["a": "manuscript/a.md"], figures: figures)
        let source = SinglePieceSource(pieceID: "a", title: "A", mode: .prose, text: text, context: context)
        let ast = try ProjectASTBuilder.build(from: source)
        let resolution = try PublishResolution.forCompile(
            source: source, bodyTag: nil, imageAllowed: ["png"],
            tableLocale: TableLocale(languageTag: "en-US"))
        return LaTeXBodyEmitter.emit(ast, resolution: resolution, isFirstBody: isFirstBody)
    }

    private let cashLine = "![Cash flows](../figures/cash.csv){#tbl:cash}\n\nSee @tbl:cash."

    /// The text from `\begin{env}` to `\end{env}`, inclusive.
    private func environment(_ name: String, in body: String) throws -> String {
        let start = try XCTUnwrap(body.range(of: "\\begin{\(name)}"), body)
        let end = try XCTUnwrap(body.range(of: "\\end{\(name)}", range: start.upperBound..<body.endIndex), body)
        return String(body[start.lowerBound..<end.upperBound])
    }

    // MARK: - tests

    /// A figures-only book defines `MaughamTable` and draws the figure in it:
    /// its header (the environment's fourth argument, which its `\endhead`
    /// repeats), its computed body cells and its
    /// total, `\hline` immediately before the total row.
    func test_aHeadedTableFigureWithATotal_drawsAMaughamTable() throws {
        let t = try table([["Item", "Amount"], ["Rent", "100"], ["Fees", "=B2*2"], ["Total", "=SUM(B2:B3)"]],
                          header: true, total: true)
        let body = try emit(cashLine, figures(t))
        XCTAssertTrue(body.contains("\\newenvironment{MaughamTable}[4]"), "a figures-only book defines it: \(body)")
        XCTAssertTrue(body.contains("""
            \\setcounter{table}{0}
            \\hypertarget{lbl-tbl-cash}{}
            \\begin{MaughamTable}{lr}{Cash flows}{Cash flows}{Item & Amount}
            Rent & 100 \\\\
            Fees & 200 \\\\
            \\hline
            Total & 300 \\\\
            \\end{MaughamTable}
            """), body)
        XCTAssertFalse(body.contains("MaughamTableNoHead"), "a headed figure needs no headless form: \(body)")
        XCTAssertFalse(body.contains("../figures/cash.csv"), "no literal source with a layout: \(body)")
        XCTAssertTrue(body.contains("\\MaughamCrossLink{lbl-tbl-cash}{Table 1}"), body)
    }

    /// No header row: `MaughamTableNoHead`, guarded and branched, and nothing
    /// in the table repeats a head.
    func test_aTableFigureWithoutAHeader_hasNoEndhead() throws {
        let t = try table([["1234.5"], ["=A1*2"]], header: false, total: false)
        let body = try emit(cashLine, figures(t))
        XCTAssertTrue(body.contains("""
            \\ifdefined\\MaughamTableNoHead\\else\\ifdefined\\longtable
            \\newenvironment{MaughamTableNoHead}[3]{\\begin{longtable}{#1}\\caption[{#2}]{#3}\\\\}{\\end{longtable}}
            \\else
            \\newenvironment{MaughamTableNoHead}[3]{\\begin{table}[htbp]\\centering\\caption[{#2}]{#3}\\begin{tabular}{#1}}{\\end{tabular}\\end{table}}
            \\fi\\fi
            """), body)
        let drawn = try environment("MaughamTableNoHead", in: body)
        XCTAssertEqual(drawn, """
            \\begin{MaughamTableNoHead}{r}{Cash flows}{Cash flows}
            1234.5 \\\\
            2469 \\\\
            \\end{MaughamTableNoHead}
            """)
        XCTAssertFalse(drawn.contains("\\endhead") || drawn.contains("\\endfirsthead"), drawn)
        XCTAssertFalse(body.contains("\\begin{MaughamTable}"), body)
    }

    /// A table whose only row is its total: ruled, headless, still valid.
    func test_aTableFigureWhoseOnlyRowIsItsTotal() throws {
        let t = try table([["42"]], header: false, total: true)
        let body = try emit("![](../figures/cash.csv)", figures(t))
        XCTAssertEqual(try environment("MaughamTableNoHead", in: body), """
            \\begin{MaughamTableNoHead}{r}{\\relax}{}
            \\hline
            42 \\\\
            \\end{MaughamTableNoHead}
            """)
    }

    /// A one-row table that is its header: the header and no rows.
    func test_aOneRowHeaderOnlyTableFigure() throws {
        let t = try table([["Only"]], header: true, total: true)
        let drawn = try environment("MaughamTable", in: try emit(cashLine, figures(t)))
        XCTAssertEqual(drawn, "\\begin{MaughamTable}{l}{Cash flows}{Cash flows}{Only}\n\\end{MaughamTable}")
    }

    /// Review Focus 1: a text cell's TeX specials print literally, and a row
    /// (header, body or total) opening with `[` or `*` starts with `\relax`.
    func test_specialsInCellsAreEscapedAndRowsAreGuarded() throws {
        let t = try table([["[Item]", "Note"],
                           ["[draft] <5% & #1_x", "{a}\\b$ ~^"],
                           ["*star", "plain"],
                           ["[sum]", "end"]], header: true, total: true)
        let drawn = try environment("MaughamTable", in: try emit(cashLine, figures(t)))
        XCTAssertEqual(drawn, """
            \\begin{MaughamTable}{ll}{Cash flows}{Cash flows}{\\relax [Item] & Note}
            \\relax [draft] <5\\% \\& \\#1\\_x & \\{a\\}\\textbackslash{}b\\$ \\textasciitilde{}\\textasciicircum{} \\\\
            \\relax *star & plain \\\\
            \\hline
            \\relax [sum] & end \\\\
            \\end{MaughamTable}
            """)
    }

    /// A text cell's line break never reaches TeX: a blank line in a row
    /// would end the paragraph mid-table.
    func test_aCellsLineBreaksBecomeSpaces() throws {
        let t = try table([["one\n\ntwo"]], header: false, total: false)
        let drawn = try environment("MaughamTableNoHead", in: try emit(cashLine, figures(t)))
        XCTAssertTrue(drawn.contains("\none two \\\\\n"), drawn)
    }

    /// A later body keeps the table out of the list, as a pipe table does.
    func test_aLaterBodysTableFigureIsUnlisted() throws {
        let t = try table([["Item"], ["Rent"]], header: true, total: false)
        let body = try emit(cashLine, figures(t), isFirstBody: false)
        XCTAssertTrue(body.contains("""
            \\begingroup\\renewcommand{\\addcontentsline}[3]{}
            \\setcounter{table}{0}
            """), body)
        XCTAssertTrue(body.contains("\\end{MaughamTable}\n\\endgroup"), body)
    }

    /// A line whose figure is parked has no layout: the literal float stays,
    /// anchor kept, and no headless form is defined.
    func test_aParkedFiguresLineKeepsItsLiteralFloat() throws {
        let t = try table([["1"]], header: false, total: false)
        let body = try emit(cashLine, figures(t, parked: true))
        XCTAssertTrue(body.contains("""
            \\begin{table}[htbp]
            \\centering
            \\hypertarget{lbl-tbl-cash}{}
            \\caption[{Cash flows}]{Cash flows}
            """), body)
        XCTAssertFalse(body.contains("MaughamTableNoHead"), body)
        XCTAssertFalse(body.contains("\\begin{MaughamTable}"), body)
    }

    /// A pipe table's body is untouched: no headless form beside it.
    func test_aPipeTableBodyGainsNoHeadlessForm() throws {
        let body = try emit("| a |\n|---|\n| 1 |\nTable: Sales {#tbl:sales}", .none)
        XCTAssertTrue(body.contains("\\begin{MaughamTable}{l}{Sales}{Sales}{a}\n1 \\\\\n\\end{MaughamTable}"), body)
        XCTAssertFalse(body.contains("MaughamTableNoHead"), body)
    }
}
