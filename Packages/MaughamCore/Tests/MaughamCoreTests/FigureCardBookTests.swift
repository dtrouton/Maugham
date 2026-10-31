import XCTest
@testable import MaughamCore

/// Report plan 9b Task 2: the one card loop the Mac cache and the phone share.
final class FigureCardBookTests: XCTestCase {
    private let en = TableLocale(languageTag: "en-GB", fallbackRegion: "GB")

    private func record(_ id: String, _ name: String, _ kind: FigureKind, path: String? = nil) -> FigureRecord {
        FigureRecord(id: id, name: name, kind: kind, piece: nil,
                     path: path ?? "figures/\(name).\(kind == .table ? "csv" : "png")")
    }

    private func tableState(parked: Bool = false, formula: String? = nil) throws -> FigureState {
        var state = FigureState(kind: .table, table: FigureTable(rows: 2, columns: 2))
        if parked { state.parked = FigureParking(path: "research/p.csv", hash: "h") }
        if let formula {
            let names = FormulaNames(figures: [], research: [("res-model01", "model")])
            guard case .success(let f) = FormulaParser.parse(formula, in: state.table, names: names)
            else { throw TestSetupError(message: "the test formula did not parse") }
            let key = CellKey(row: state.table.rows[0], column: state.table.columns[0])
            state.table.setCell(Cell(content: .formula(f)), at: key)
        }
        return state
    }

    private func book() throws -> FigureCardBook {
        let records = [record("t1", "plain", .table), record("i1", "pic", .image),
                       record("p1", "shelved", .table), record("r1", "reader", .table),
                       record("t1", "dup", .image)]
        var states = ["t1": try tableState(), "i1": FigureState(kind: .image),
                      "p1": try tableState(parked: true), "r1": try tableState(formula: "research:model!A1")]
        states["ghost"] = try tableState()
        return FigureCardBook.build(records: records, states: states, workbook: nil, locale: en,
                                    pinChanged: ["t1"], sourceChanged: [], openCellNotes: [:])
    }

    func test_oneCardPerRegisteredFigureWithAState_firstRecordWins() throws {
        let b = try book()
        XCTAssertEqual(Set(b.models.keys), ["t1", "i1", "p1", "r1"])
        XCTAssertEqual(b.models["t1"]?.kind, .table, "the first record of an id wins; the later image one is ignored")
        XCTAssertEqual(b.models["i1"]?.kind, .image)
        XCTAssertEqual(b.models["p1"]?.kind, .parked)
        XCTAssertEqual(b.models["t1"]?.pinChanged, true)
        XCTAssertEqual(b.models["r1"]?.pinChanged, false)
    }

    func test_readersAreTheUnparkedFiguresThatReadResearch_andParkedLabelsNameTheParked() throws {
        let b = try book()
        XCTAssertEqual(b.researchReaders, ["r1"])
        XCTAssertEqual(b.parkedLabels, [ManuscriptLabel(reference: "tbl:shelved")!])
    }

    func test_aRecordWithNoStateGetsNoCard() {
        let b = FigureCardBook.build(records: [record("t1", "plain", .table)], states: [:], workbook: nil,
                                     locale: en, pinChanged: [], sourceChanged: [], openCellNotes: [:])
        XCTAssertTrue(b.models.isEmpty)
    }

    func test_theLineRule() throws {
        let b = try book()
        let twin = [record("a", "x", .table, path: "figures/x.csv"), record("b", "y", .table, path: "figures/x.csv")]
        let index = FigureLineResolution.Index([record("t1", "plain", .table)] + twin)
        let doc = "draft.md"
        XCTAssertEqual(b.model(forLinePath: "figures/plain.csv", documentPath: doc, index: index)?.kind, .table)
        XCTAssertEqual(b.model(forLinePath: "figures/gone.csv", documentPath: doc, index: index)?.kind, .removed)
        XCTAssertEqual(b.model(forLinePath: "figures/x.csv", documentPath: doc, index: index)?.kind, .ambiguous)
        XCTAssertEqual(b.model(forLinePath: "research/pic.png", documentPath: doc, index: index)?.kind, .image)
        XCTAssertEqual(b.model(forLinePath: "https://example.com/a.png", documentPath: doc, index: index)?.kind, .image)
        let noCard = FigureCardBook(models: [:])
        XCTAssertNil(noCard.model(forLinePath: "figures/plain.csv", documentPath: doc, index: index),
                     "a registered figure with no card answers nil, as the cache always did")
    }
}

private struct TestSetupError: Error { let message: String }
