import XCTest
import MaughamCore
@testable import Maugham

/// **Resolution lays out each table-figure line** (report plan 9a Task 3,
/// spec §9): a line that resolves to an unparked table figure gets its
/// computed, formatted cells in the body's own language; its number, its
/// list-of-tables entry and its label are the same with or without a layout.
final class PublishResolutionTableFigureTests: XCTestCase {

    private let cashID = "fig-0a1b2c3d"
    private let spareID = "fig-4e5f6a7b"

    // MARK: - fixtures

    /// A one-column table: A1 = 1234.5, A2 = `A1*2`.
    private func cashTable() throws -> FigureTable {
        var table = FigureTable(rows: 2, columns: 1)
        let a1 = CellKey(row: table.rows[0], column: table.columns[0])
        let a2 = CellKey(row: table.rows[1], column: table.columns[0])
        table.setCell(Cell(content: .value(.number(1234.5))), at: a1)
        guard case .success(let f) = FormulaParser.parse("A1*2", in: table)
        else { throw FigureEditInvalid(reason: "the formula did not parse") }
        table.setCell(Cell(content: .formula(f)), at: a2)
        return table
    }

    private func figures(parked: Bool = false, spare: Bool = false) throws -> PublishFigures {
        let table = try cashTable()
        var records = [FigureRecord(id: cashID, name: "cash", kind: .table, piece: nil, path: "figures/cash.csv")]
        var states = [cashID: FigureState(
            kind: .table, table: table,
            parked: parked ? FigureParking(path: "research/cash.csv", hash: "h") : nil)]
        var book = Workbook(pins: FigurePinIndex())
        book.setTable(table, id: cashID)
        if spare {
            records.append(FigureRecord(id: spareID, name: "spare", kind: .table, piece: nil,
                                        path: "figures/spare.csv"))
            states[spareID] = FigureState(kind: .table, table: table)
            book.setTable(table, id: spareID)
        }
        return PublishFigures(records: records, states: states, workbook: book, pinStatus: [:],
                              sourceChanged: [], parked: parked ? [cashID] : [])
    }

    private func context(_ figures: PublishFigures) -> PublishContext {
        PublishContext(library: CitationLibrary(items: []), profile: .report,
                       switches: (numberSections: true, listOfFigures: true, listOfTables: true),
                       projectURL: URL(fileURLWithPath: "/nonexistent/report-9a"),
                       piecePaths: ["a": "manuscript/a.md"], figures: figures)
    }

    private func resolve(_ text: String, _ figures: PublishFigures,
                         locale: TableLocale = TableLocale(languageTag: "en-US")) throws -> PublishResolution {
        let source = SinglePieceSource(pieceID: "a", title: "A", mode: .prose, text: text,
                                       context: context(figures))
        return try PublishResolution.forCompile(source: source, bodyTag: nil, imageAllowed: ["png"],
                                                tableLocale: locale)
    }

    private let cashLine = "![Cash](../figures/cash.csv){#tbl:cash}\n\nSee @tbl:cash."

    // MARK: - tests

    func test_aTableFigureLineGetsItsLayout() throws {
        let r = try resolve(cashLine, try figures())
        let layout = try XCTUnwrap(r.tableFigures["a"]?[0])
        XCTAssertNil(layout.header)
        XCTAssertEqual(layout.body, [["1234.5"], ["2469"]], "a formula prints its computed value")
        XCTAssertEqual(layout.alignments, [.right])
        XCTAssertEqual(r.tableNumbers["a"], [0: 1])
        XCTAssertEqual(r.targets[ManuscriptLabel(reference: "tbl:cash")!]?.text, "Table 1")
    }

    func test_twoBodiesFormatInTheirOwnLanguages() throws {
        let en = try resolve(cashLine, try figures(), locale: TableLocale(languageTag: "en-US"))
        let es = try resolve(cashLine, try figures(), locale: TableLocale(languageTag: "es-ES"))
        let enCell = try XCTUnwrap(en.tableFigures["a"]?[0]?.body.first?.first)
        let esCell = try XCTUnwrap(es.tableFigures["a"]?[0]?.body.first?.first)
        XCTAssertEqual(enCell, "1234.5")
        XCTAssertTrue(esCell.hasSuffix(",5"), "Spanish prints a decimal comma, got \(esCell)")
        XCTAssertNotEqual(enCell, esCell)
    }

    /// The gate's per-body locale: the source body is the card's (a blank
    /// language as none, the Mac's region borrowed); a translated body is its
    /// own language with no borrowed region and the book's currency.
    func test_theGateFormatsABodyInItsConfigsLanguage() {
        func body(_ tag: String?, _ language: String) -> BodyPlan.Body {
            var config = PublishConfig()
            config.metadata.language = language
            return BodyPlan.Body(tag: tag, displayTag: tag ?? "en", source: SinglePieceSource(
                pieceID: "a", title: "A", mode: .prose, text: ""), config: config, sourceLanguage: "en-GB")
        }
        XCTAssertEqual(PublishProblemGate.tableLocale(for: body(nil, "  "), macRegion: "GB"),
                       TableLocale(languageTag: nil, fallbackRegion: "GB"))
        XCTAssertEqual(PublishProblemGate.tableLocale(for: body(nil, "en"), macRegion: "US"),
                       TableLocale(languageTag: "en", fallbackRegion: "US"))
        let es = PublishProblemGate.tableLocale(for: body("es", "es"), macRegion: "GB")
        XCTAssertEqual(es.locale.identifier, "es")
        XCTAssertEqual(es.currencySymbol, "£")
    }

    func test_anUnusedFigureIsNotPublished() throws {
        let r = try resolve(cashLine, try figures(spare: true))
        XCTAssertEqual(r.tableFigures.mapValues { Array($0.keys) }, ["a": [0]],
                       "only the figure a line names is laid out")
        XCTAssertEqual(r.tableNumbers, ["a": [0: 1]])
        XCTAssertEqual(r.listOfTables.count, 1)
    }

    func test_aPipeTableIsUntouched() throws {
        let text = "| a |\n|---|\n| 1 |\nTable: Sales {#tbl:sales}\n\nSee @tbl:sales."
        let with = try resolve(text, try figures())
        let without = try resolve(text, .none)
        XCTAssertEqual(with.tableFigures, [:])
        XCTAssertEqual(with.tableNumbers, ["a": [0: 1]])
        XCTAssertEqual(with.tableNumbers, without.tableNumbers)
        XCTAssertEqual(with.listOfTables.map(\.number), without.listOfTables.map(\.number))
        XCTAssertEqual(with.listOfTables.map(\.target), without.listOfTables.map(\.target))
        XCTAssertEqual(with.problems, without.problems)
    }

    func test_aLineToAParkedFigureGetsNoLayoutButKeepsItsNumber() throws {
        let r = try resolve(cashLine, try figures(parked: true))
        XCTAssertEqual(r.tableFigures, [:])
        XCTAssertEqual(r.tableNumbers, ["a": [0: 1]])
        XCTAssertEqual(r.listOfTables.map(\.number), [1])
        XCTAssertEqual(r.targets[ManuscriptLabel(reference: "tbl:cash")!]?.text, "Table 1",
                       "a reference still lands")
    }
}
