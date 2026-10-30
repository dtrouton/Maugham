import XCTest
import MaughamCore
@testable import Maugham

/// **The table-figure problems and notes** (report plan 9a Task 4, spec §9):
/// an error cell, a missing Research source and a figure in Research are red
/// in a Report and amber elsewhere; "reads Research", "Research changed" and
/// the `NPV` first-flow note are amber everywhere. Each figure's problem is
/// raised once per body resolution — not per cell, not per line.
final class PublishProblemTableFigureTests: XCTestCase {

    private let cashID = "fig-0a1b2c3d"
    private let otherID = "fig-4e5f6a7b"

    // MARK: - fixtures

    /// A one-column table, its cells written as formulas (`=…`) or numbers.
    private func table(_ cells: [String]) throws -> FigureTable {
        var table = FigureTable(rows: cells.count, columns: 1)
        for (i, text) in cells.enumerated() {
            let key = CellKey(row: table.rows[i], column: table.columns[0])
            if text.hasPrefix("=") {
                guard case .success(let f) = FormulaParser.parse(String(text.dropFirst()), in: table)
                else { throw FigureEditInvalid(reason: "the formula \(text) did not parse") }
                table.setCell(Cell(content: .formula(f)), at: key)
            } else {
                table.setCell(Cell(content: .value(.number(Double(text) ?? 0))), at: key)
            }
        }
        return table
    }

    private func figures(_ cells: [String] = ["1234.5", "=A1*2"], parked: Bool = false,
                         pins: [String: PinStatus] = [:], sourceChanged: Bool = false,
                         state: Bool = true, twin: Bool = false) throws -> PublishFigures {
        let table = try table(cells)
        var records = [FigureRecord(id: cashID, name: "cash", kind: .table, piece: nil, path: "figures/cash.csv")]
        if twin {
            records.append(FigureRecord(id: otherID, name: "cash2", kind: .table, piece: nil,
                                        path: "figures/cash.csv"))
        }
        let states = state ? [cashID: FigureState(
            kind: .table, table: table,
            parked: parked ? FigureParking(path: "research/cash.csv", hash: "h") : nil)] : [:]
        var book = Workbook(pins: FigurePinIndex())
        book.setTable(table, id: cashID)
        return PublishFigures(records: records, states: states, workbook: book,
                              pinStatus: pins.isEmpty ? [:] : [cashID: pins],
                              sourceChanged: sourceChanged ? [cashID] : [], parked: parked ? [cashID] : [])
    }

    private func context(_ figures: PublishFigures, profile: ProjectProfile? = .report) -> PublishContext {
        PublishContext(library: CitationLibrary(items: []), profile: profile,
                       switches: (numberSections: true, listOfFigures: true, listOfTables: true),
                       projectURL: URL(fileURLWithPath: "/nonexistent/report-9a-t4"),
                       piecePaths: ["a": "manuscript/a.md"], figures: figures)
    }

    private func source(_ text: String, _ figures: PublishFigures) -> SinglePieceSource {
        SinglePieceSource(pieceID: "a", title: "A", mode: .prose, text: text, context: context(figures))
    }

    private func resolve(_ text: String, _ figures: PublishFigures) throws -> PublishResolution {
        try PublishResolution.forCompile(source: source(text, figures), bodyTag: nil, imageAllowed: ["png"],
                                         tableLocale: TableLocale(languageTag: "en-US"))
    }

    /// The same figure on two lines, in two paragraphs, and referred to.
    private let twoLines = "![Cash](../figures/cash.csv){#tbl:cash}\n\nSee @tbl:cash.\n\n"
        + "![Again](../figures/cash.csv)"

    private func kinds(_ r: PublishResolution) -> [PublishProblem.Kind] { r.problems.map(\.kind) }

    private func assertSeverity(_ kind: PublishProblem.Kind, redInAReport: Bool,
                                file: StaticString = #filePath, line: UInt = #line) {
        let p = PublishProblem(kind: kind, pieceID: "a", paragraphID: nil, bodyTag: nil)
        XCTAssertEqual(p.isError(profile: .report), redInAReport, "\(kind)", file: file, line: line)
        XCTAssertFalse(p.isError(profile: nil), "nothing blocks outside a Report: \(kind)", file: file, line: line)
    }

    // MARK: - an error cell

    func test_anErrorCellIsRaisedOncePerFigure_namingTheFirstCellAndItsError() throws {
        let r = try resolve(twoLines, try figures(["=1/0", "=A1+1", "3"]))
        XCTAssertEqual(kinds(r), [.tableFigureErrorCell(name: "cash", cell: "A1", error: "#DIV/0!")],
                       "one problem for two error cells on two lines")
        XCTAssertEqual(r.problems.first?.message, "Table “cash” has an error in A1 (#DIV/0!). "
                       + "Fix the cell in the table to publish it.")
        assertSeverity(.tableFigureErrorCell(name: "cash", cell: "A1", error: "#DIV/0!"), redInAReport: true)
        XCTAssertNotNil(r.tableFigures["a"]?[0], "the table still prints, its error showing")
    }

    func test_theGateRefusesAReportWithAnErrorCell_butPassesANovelWithAWarning() throws {
        let figs = try figures(["=1/0"])
        let problems = try resolve(twoLines, figs).problems
        guard case .refused(let errors) = PublishProblemGate.judge(
            problems, context: context(figs, profile: .report), refusesOnErrors: true) else {
            return XCTFail("a Report with an error cell refuses")
        }
        XCTAssertEqual(errors.map(\.level), [.error])
        guard case .passed(let warnings) = PublishProblemGate.judge(
            problems, context: context(figs, profile: nil), refusesOnErrors: true) else {
            return XCTFail("a novel publishes with an error cell")
        }
        XCTAssertEqual(warnings.map(\.level), [.warning])
    }

    // MARK: - Research sources

    func test_aMissingResearchSourceIsRaisedOncePerFigure() throws {
        let r = try resolve(twoLines, try figures(pins: ["r-1": .sourceMissing, "r-2": .sourceMissing]))
        XCTAssertEqual(kinds(r), [.tableFigureSourceMissing(name: "cash"), .tableFigureReadsResearch(name: "cash")])
        assertSeverity(.tableFigureSourceMissing(name: "cash"), redInAReport: true)
    }

    func test_aTableReadingResearchIsNotedOnce_amberEverywhere() throws {
        let r = try resolve(twoLines, try figures(pins: ["r-1": .current, "r-2": .current]))
        XCTAssertEqual(kinds(r), [.tableFigureReadsResearch(name: "cash")])
        assertSeverity(.tableFigureReadsResearch(name: "cash"), redInAReport: false)
        let figs = try figures(pins: ["r-1": .current])
        guard case .passed = PublishProblemGate.judge(
            try resolve(twoLines, figs).problems, context: context(figs), refusesOnErrors: true) else {
            return XCTFail("a Report publishes a table that reads Research")
        }
    }

    func test_aChangedPinIsNotedOnce_amberEverywhere() throws {
        let r = try resolve(twoLines, try figures(pins: ["r-1": .sourceChanged(old: "a", new: "b"),
                                                        "r-2": .sourceChanged(old: "c", new: "d")]))
        XCTAssertEqual(kinds(r), [.tableFigureReadsResearch(name: "cash"),
                                  .tableFigureResearchChanged(name: "cash")])
        assertSeverity(.tableFigureResearchChanged(name: "cash"), redInAReport: false)
    }

    func test_aFigureWhoseOwnSourceChangedIsNotedOnce() throws {
        let r = try resolve(twoLines, try figures(sourceChanged: true))
        XCTAssertEqual(kinds(r), [.tableFigureResearchChanged(name: "cash")])
    }

    // MARK: - the NPV note

    func test_theNPVFirstFlowNoteIsRaisedOncePerFigure_amberEverywhere() throws {
        let r = try resolve(twoLines, try figures(["1", "=NPV(8%,-100,30)", "=NPV(8%,-100,30)"]))
        XCTAssertEqual(kinds(r), [.tableFigureNPVNote(name: "cash", cell: "A2")],
                       "one note for two noted cells, naming the first")
        assertSeverity(.tableFigureNPVNote(name: "cash", cell: "A2"), redInAReport: false)
        XCTAssertTrue(r.problems.first?.message.contains("A2") ?? false)
    }

    func test_aCleanFigureRaisesNothing() throws {
        XCTAssertEqual(kinds(try resolve(twoLines, try figures())), [])
    }

    // MARK: - figures in Research

    func test_aReferenceToAParkedTableSaysItIsInResearch() throws {
        let r = try resolve("See @tbl:cash.\n\nAnd again @tbl:cash.", try figures(parked: true))
        XCTAssertEqual(kinds(r), [.figureInResearch(name: "cash"), .figureInResearch(name: "cash")],
                       "each reference is named, as an unresolved one is")
        XCTAssertFalse(kinds(r).contains(.unresolvedCrossRef(ManuscriptLabel(reference: "tbl:cash")!)))
        assertSeverity(.figureInResearch(name: "cash"), redInAReport: true)
        XCTAssertEqual(kinds(try resolve("See @tbl:nothing.", try figures(parked: true))),
                       [.unresolvedCrossRef(ManuscriptLabel(reference: "tbl:nothing")!)],
                       "a name no parked figure has is still unresolved")
    }

    func test_aLineToAParkedTableIsInResearch_onceAndWithItsNumber() throws {
        let r = try resolve(twoLines, try figures(parked: true))
        XCTAssertEqual(kinds(r), [.figureInResearch(name: "cash")])
        XCTAssertEqual(r.tableFigures, [:])
        XCTAssertEqual(r.tableNumbers, ["a": [0: 1, 2: 2]])
    }

    func test_aLegacyResearchLineIsInResearch() throws {
        let r = try resolve("![Model](../research/model.csv)\n\nSee Table 1.", try figures())
        XCTAssertEqual(kinds(r), [.figureInResearch(name: "model")])
        XCTAssertEqual(r.tableFigures, [:], "no layout: its literal source prints")
        XCTAssertEqual(r.tableNumbers, ["a": [0: 1]], "its number is kept")
    }

    // MARK: - a line the registry can't print

    func test_aCsvLineWithNoFigureRefusesAReport() throws {
        let figs = try figures()
        let r = try resolve("![Gone](../figures/gone.csv){#tbl:gone}\n\nSee @tbl:gone.", figs)
        XCTAssertEqual(kinds(r), [.figureNotFound("../figures/gone.csv")])
        XCTAssertEqual(r.tableFigures, [:])
        XCTAssertEqual(r.tableNumbers, ["a": [0: 1]])
        XCTAssertEqual(r.targets[ManuscriptLabel(reference: "tbl:gone")!]?.text, "Table 1")
        assertSeverity(.figureNotFound("figures/gone.csv"), redInAReport: true)
        guard case .refused = PublishProblemGate.judge(r.problems, context: context(figs),
                                                       refusesOnErrors: true) else {
            return XCTFail("a Report refuses a .csv line naming no figure")
        }
    }

    func test_anAmbiguousLineKeepsItsNumber_amber() throws {
        let r = try resolve("![Cash](../figures/cash.csv)", try figures(twin: true))
        XCTAssertEqual(kinds(r), [.figureAmbiguous("../figures/cash.csv")])
        XCTAssertEqual(r.tableFigures, [:])
        XCTAssertEqual(r.tableNumbers, ["a": [0: 1]])
        assertSeverity(.figureAmbiguous("figures/cash.csv"), redInAReport: false)
    }

    func test_anUnreadableTableKeepsItsNumber_andRefusesAReport() throws {
        let r = try resolve(twoLines, try figures(state: false))
        XCTAssertEqual(kinds(r), [.tableFigureUnreadable(name: "cash")], "once for two lines")
        XCTAssertEqual(r.tableFigures, [:])
        XCTAssertEqual(r.tableNumbers, ["a": [0: 1, 2: 2]])
        assertSeverity(.tableFigureUnreadable(name: "cash"), redInAReport: true)
    }

    // MARK: - through the gate, body by body

    /// The gate's own resolution: each body formats its cells in its config's
    /// language, and raises its figure's problem once, under its own tag.
    func test_theGateResolvesEachBodyInItsLanguage_andRaisesOncePerBody() throws {
        let figs = try figures(["1234.5", "=1/0"])
        func body(_ tag: String?, _ display: String, language: String) -> BodyPlan.Body {
            var config = PublishConfig(metadata: .init(title: "T", author: "A"))
            config.metadata.language = language
            return BodyPlan.Body(tag: tag, displayTag: display, source: source(twoLines, figs), config: config)
        }
        let bodies = try PublishProblemGate.resolve(
            bodies: [body(nil, "en", language: "en-US"), body("es", "es", language: "es-ES")],
            imageAllowed: ["png"])
        XCTAssertEqual(bodies[0].resolution.tableFigures["a"]?[0]?.body.first, ["1234.5"])
        let es = try XCTUnwrap(bodies[1].resolution.tableFigures["a"]?[0]?.body.first?.first)
        XCTAssertTrue(es.hasSuffix(",5"), "the es body prints a decimal comma, got \(es)")
        for (resolved, tag) in zip(bodies, ["en", "es"]) {
            XCTAssertEqual(resolved.resolution.problems.map(\.kind),
                           [.tableFigureErrorCell(name: "cash", cell: "A2", error: "#DIV/0!")])
            XCTAssertEqual(resolved.resolution.problems.map(\.bodyTag), [tag])
        }
    }
}
