import XCTest
@testable import MaughamCore

/// The encoded form of the table model is the op log's payload (rule 11: no migrations), so
/// these goldens pin it byte for byte. A failing golden means a persisted figure would no
/// longer decode: change the code back, never the fixture.
final class TableWireFormatTests: XCTestCase {
    private func json<T: Encodable>(_ value: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    private func assertGolden<T: Codable & Equatable>(_ value: T, _ golden: String,
                                                      file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try json(value), golden, file: file, line: line)
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: Data(golden.utf8)), value, "the golden decodes", file: file, line: line)
    }

    private let r1 = RowID("rrrr0001"), r2 = RowID("rrrr0002"), r3 = RowID("rrrr0003")
    private let c1 = ColumnID("cccc0001"), c2 = ColumnID("cccc0002")

    // MARK: ids (ruling R-P5-18)

    func test_ids_areBareStrings() throws {
        try assertGolden(r1, #""rrrr0001""#)
        try assertGolden(c1, #""cccc0001""#)
        try assertGolden(CellKey(row: r1, column: c1), #"{"column":"cccc0001","row":"rrrr0001"}"#)
    }

    // MARK: Formula

    func test_formula_binaryOverAnAbsoluteRefAndANumber() throws {
        let ref = FormulaRef(target: .this, anchor: .id(row: r1, column: c2), rowAbsolute: true)
        try assertGolden(Formula(.binary(.notEqual, .ref(ref), .number(2.5))),
            #"{"expr":{"binary":{"_0":"notEqual","_1":{"ref":{"_0":{"anchor":{"id":{"column":"cccc0002","row":"rrrr0001"}},"columnAbsolute":false,"rowAbsolute":true,"target":{"this":{}}}}},"_2":{"number":{"_0":2.5}}}}}"#)
    }

    // Refs to a figure and a research item carry its id, never its name (R-D1). Changed on
    // purpose by report plan 6b Task 3, before schema 10 shipped (ProjectManifest's history).
    func test_formula_callOverAFigureRangeAndAMissingArgument() throws {
        let g = FormulaRange(start: FormulaRef(target: .figure(id: "fig-cash0001"), anchor: .id(row: r1, column: c1)),
                             end: FormulaRef(target: .figure(id: "fig-cash0001"), anchor: .id(row: r3, column: c2), columnAbsolute: true))
        try assertGolden(Formula(.call(name: "PV", arguments: [.range(g), .missing])),
            #"{"expr":{"call":{"arguments":[{"range":{"_0":{"end":{"anchor":{"id":{"column":"cccc0002","row":"rrrr0003"}},"columnAbsolute":true,"rowAbsolute":false,"target":{"figure":{"id":"fig-cash0001"}}},"start":{"anchor":{"id":{"column":"cccc0001","row":"rrrr0001"}},"columnAbsolute":false,"rowAbsolute":false,"target":{"figure":{"id":"fig-cash0001"}}}}}},{"missing":{}}],"name":"PV"}}}"#)
    }

    func test_formula_unaryTextBoolErrorAndAResearchPosition() throws {
        let research = FormulaRef(target: .research(id: "res-mv0001"), anchor: .position(row: 8, column: 1))
        try assertGolden(Formula(.call(name: "IF", arguments: [.bool(true), .unary(.percent, .text("x")), .error(.ref), .ref(research)])),
            ##"{"expr":{"call":{"arguments":[{"bool":{"_0":true}},{"unary":{"_0":"percent","_1":{"text":{"_0":"x"}}}},{"error":{"_0":"#REF!"}},{"ref":{"_0":{"anchor":{"position":{"column":1,"row":8}},"columnAbsolute":false,"rowAbsolute":false,"target":{"research":{"id":"res-mv0001"}}}}}],"name":"IF"}}}"##)
    }

    func test_formula_everyOperatorNameIsPinned() throws {
        XCTAssertEqual(UnaryOperator.allNames, ["negate", "plus", "percent"])
        XCTAssertEqual(BinaryOperator.allNames, ["add", "subtract", "multiply", "divide", "power", "equal", "notEqual",
                                                 "less", "greater", "lessOrEqual", "greaterOrEqual"])
        XCTAssertEqual(FormulaError.allCases.map(\.rawValue), ["#DIV/0!", "#REF!", "#NAME?", "#VALUE!", "#NUM!", "#CIRC!"])
    }

    // MARK: Cell and CellFormat

    func test_cellFormat_eachNumberFormat() throws {
        try assertGolden(CellFormat(), #"{"negatives":"minus","number":{"general":{}},"zeroAsDash":false}"#)
        try assertGolden(CellFormat(number: .number(decimals: 2, grouping: true), negatives: .parentheses, zeroAsDash: true),
                         #"{"negatives":"parentheses","number":{"number":{"decimals":2,"grouping":true}},"zeroAsDash":true}"#)
        try assertGolden(NumberFormat.percent(decimals: 1), #"{"percent":{"decimals":1}}"#)
        try assertGolden(NumberFormat.currency(symbol: nil, decimals: 2), #"{"currency":{"decimals":2}}"#)
        try assertGolden(NumberFormat.currency(symbol: "€", decimals: 0), #"{"currency":{"decimals":0,"symbol":"€"}}"#)
        try assertGolden(NumberFormat.compact(decimals: 1), #"{"compact":{"decimals":1}}"#)
        try assertGolden(NumberFormat.date(.quarter), #"{"date":{"_0":"quarter"}}"#)
    }

    func test_cell_valueAndFormula() throws {
        try assertGolden(Cell(content: .value(.date(46319)), format: CellFormat(number: .date(.iso)), alignment: .right),
            #"{"alignment":"right","content":{"value":{"_0":{"date":{"_0":46319}}}},"format":{"negatives":"minus","number":{"date":{"_0":"iso"}},"zeroAsDash":false}}"#)
        try assertGolden(Cell(content: .value(.empty)),
            #"{"alignment":"automatic","content":{"value":{"_0":{"empty":{}}}},"format":{"negatives":"minus","number":{"general":{}},"zeroAsDash":false}}"#)
        try assertGolden(Cell(content: .formula(Formula(.unary(.negate, .number(1))))),
            #"{"alignment":"automatic","content":{"formula":{"_0":{"expr":{"unary":{"_0":"negate","_1":{"number":{"_0":1}}}}}}},"format":{"negatives":"minus","number":{"general":{}},"zeroAsDash":false}}"#)
    }

    // MARK: FigureTable

    func test_figureTable_withTombstones() throws {
        var t = FigureTable(rows: 0, columns: 0)
        t.insertRow(r1, after: nil)
        t.insertRow(r2, after: r1)
        t.insertRow(r3, after: r2)
        t.insertColumn(c1, after: nil)
        t.insertColumn(c2, after: c1)
        t.deleteRow(r2)
        t.deleteColumn(c2)
        t.setCell(Cell(content: .value(.number(1))), at: CellKey(row: r1, column: c1))
        t.headerRows = 1
        t.hasTotalRow = true
        t.columnWidths[c1] = 120
        try assertGolden(t,
            #"{"cells":[{"column":"cccc0001","row":"rrrr0001"},{"alignment":"automatic","content":{"value":{"_0":{"number":{"_0":1}}}},"format":{"negatives":"minus","number":{"general":{}},"zeroAsDash":false}}],"# +
            #""columnSlots":[{"id":"cccc0001","isDeleted":false},{"id":"cccc0002","isDeleted":true}],"columnWidths":["cccc0001",120],"hasTotalRow":true,"headerRows":1,"# +
            #""rowSlots":[{"id":"rrrr0001","isDeleted":false},{"id":"rrrr0002","isDeleted":true},{"id":"rrrr0003","isDeleted":false}]}"#)
    }

    func test_figureTable_headerRowsClampOnDecode() throws {
        func decoded(headerRows: Int) throws -> Int {
            let golden = #"{"cells":[],"columnSlots":[],"columnWidths":[],"hasTotalRow":false,"headerRows":\#(headerRows),"rowSlots":[]}"#
            return try JSONDecoder().decode(FigureTable.self, from: Data(golden.utf8)).headerRows
        }
        XCTAssertEqual(try decoded(headerRows: 5), 1)
        XCTAssertEqual(try decoded(headerRows: -2), 0)
        XCTAssertEqual(try decoded(headerRows: 1), 1)
    }

    // MARK: decode depth (ruling R-P5-19)

    /// Calls nested around a figure range, `depth` nodes deep: the costliest shape to decode.
    private func nestedCalls(depth: Int) -> Formula {
        var e = FormulaExpr.range(FormulaRange(start: FormulaRef(target: .figure(id: "fig-cash0001"), anchor: .id(row: r1, column: c1)),
                                               end: FormulaRef(target: .figure(id: "fig-cash0001"), anchor: .id(row: r3, column: c2))))
        for _ in 1..<depth { e = .call(name: "SUM", arguments: [e]) }
        return Formula(e)
    }

    /// Runs `body` on a thread with a 512 KB stack: Swift concurrency's and a secondary thread's size.
    private func onSmallStack(_ body: @escaping @Sendable () -> Void) {
        let done = expectation(description: "512 KB thread")
        let thread = Thread { body(); done.fulfill() }
        thread.stackSize = 512 * 1024
        thread.start()
        wait(for: [done], timeout: 60)
    }

    func test_decode_refusesPastTheDepthBound_onA512KBThread_withoutCrashing() throws {
        let n = FormulaParser.maxDepth
        // Encoded here, on the test's own large stack: a peer's op log could carry these bytes.
        let atBound = try JSONEncoder().encode(nestedCalls(depth: n))
        let justPast = try JSONEncoder().encode(nestedCalls(depth: n + 1))
        let deep = try JSONEncoder().encode(nestedCalls(depth: 120))
        let inCell = try JSONEncoder().encode(Cell(content: .formula(nestedCalls(depth: 120))))
        let expected = nestedCalls(depth: n)
        onSmallStack {
            func decodeError<T: Decodable>(_ type: T.Type, _ data: Data) -> Error? {
                do { _ = try JSONDecoder().decode(type, from: data); return nil } catch { return error }
            }
            let back = try? JSONDecoder().decode(Formula.self, from: atBound)
            XCTAssertEqual(back, expected, "depth \(n) decodes")
            for (label, data) in [("depth \(n + 1)", justPast), ("depth 120", deep)] {
                guard let error = decodeError(Formula.self, data) else { XCTFail("\(label) decoded"); continue }
                guard case DecodingError.dataCorrupted = error else { XCTFail("\(label): \(error)"); continue }
            }
            XCTAssertNotNil(decodeError(Cell.self, inCell), "inside a cell too")
        }
    }

    func test_decode_refusesANodeWithTwoCaseKeys() {
        let golden = #"{"expr":{"number":{"_0":1},"text":{"_0":"x"}}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Formula.self, from: Data(golden.utf8)))
    }
}

private extension UnaryOperator {
    static let allNames = [UnaryOperator.negate, .plus, .percent].map(\.rawValue)
}

private extension BinaryOperator {
    static let allNames = [BinaryOperator.add, .subtract, .multiply, .divide, .power, .equal, .notEqual,
                           .less, .greater, .lessOrEqual, .greaterOrEqual].map(\.rawValue)
}
