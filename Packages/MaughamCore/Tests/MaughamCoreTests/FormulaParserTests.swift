import XCTest
@testable import MaughamCore

final class FormulaParserTests: XCTestCase {
    private var table = FigureTable(rows: 4, columns: 3)
    private var revenue = FigureTable(rows: 2, columns: 2)
    private var figures: [String: FigureTable] { ["revenue": revenue] }

    private func n(_ x: Double) -> FormulaExpr { .number(x) }

    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Formula? {
        switch FormulaParser.parse(text, in: table, figures: figures) {
        case .success(let f): return f
        case .failure(let e): XCTFail("\(text): \(e.message) at \(e.offset)", file: file, line: line); return nil
        }
    }

    private func parseError(_ text: String) -> FormulaParseError? {
        if case .failure(let e) = FormulaParser.parse(text, in: table, figures: figures) { return e }
        return nil
    }

    private func render(_ f: Formula?) -> String? {
        f.map { FormulaParser.render($0, in: table, figures: figures) }
    }

    private func this(_ r: Int, _ c: Int, rowAbs: Bool = false, colAbs: Bool = false) -> FormulaRef {
        FormulaRef(target: .this, anchor: .id(row: table.rows[r], column: table.columns[c]), rowAbsolute: rowAbs, columnAbsolute: colAbs)
    }

    // MARK: precedence

    func test_precedence_negationBeforePower() {
        XCTAssertEqual(parse("-2^2")?.expr, .binary(.power, .unary(.negate, n(2)), n(2)))
        XCTAssertEqual(parse("2^-1")?.expr, .binary(.power, n(2), .unary(.negate, n(1))))
    }

    func test_power_isLeftAssociative() {
        XCTAssertEqual(parse("2^3^2")?.expr, .binary(.power, .binary(.power, n(2), n(3)), n(2)))
    }

    func test_percentPostfix() {
        XCTAssertEqual(parse("10%*50")?.expr, .binary(.multiply, .unary(.percent, n(10)), n(50)))
        XCTAssertEqual(parse("-2%")?.expr, .unary(.percent, .unary(.negate, n(2))))
    }

    func test_comparison_isLoosest() {
        XCTAssertEqual(parse("1+1=2")?.expr, .binary(.equal, .binary(.add, n(1), n(1)), n(2)))
        XCTAssertEqual(parse("1<>2*3")?.expr, .binary(.notEqual, n(1), .binary(.multiply, n(2), n(3))))
    }

    func test_multiplicationBeforeAddition_andParentheses() {
        XCTAssertEqual(parse("1+2*3")?.expr, .binary(.add, n(1), .binary(.multiply, n(2), n(3))))
        XCTAssertEqual(parse("(1+2)*3")?.expr, .binary(.multiply, .binary(.add, n(1), n(2)), n(3)))
        XCTAssertEqual(parse("8-3-2")?.expr, .binary(.subtract, .binary(.subtract, n(8), n(3)), n(2)))
    }

    func test_whitespaceBetweenTokens() {
        XCTAssertEqual(parse("  sum ( a1 ,  2 ) * 3 ")?.expr,
                       .binary(.multiply, .call(name: "SUM", arguments: [.ref(this(0, 0)), n(2)]), n(3)))
    }

    func test_literals_textBoolAndErrors() {
        XCTAssertEqual(parse("\"say \"\"hi\"\"\"")?.expr, .text("say \"hi\""))
        XCTAssertEqual(parse("true")?.expr, .bool(true))
        XCTAssertEqual(parse("FALSE")?.expr, .bool(false))
        XCTAssertEqual(parse("#REF!+1")?.expr, .binary(.add, .error(.ref), n(1)))
        XCTAssertEqual(parse("1.5e3")?.expr, n(1500))
        XCTAssertEqual(parse(".5")?.expr, n(0.5))
    }

    // MARK: refs

    func test_rangeAndAbsolute() {
        XCTAssertEqual(parse("SUM($A$1:B3)")?.expr,
                       .call(name: "SUM", arguments: [.range(FormulaRange(start: this(0, 0, rowAbs: true, colAbs: true), end: this(2, 1)))]))
    }

    func test_range_isNormalisedTopLeftFirst() {
        XCTAssertEqual(parse("B3:$A1")?.expr, .range(FormulaRange(start: this(0, 0, colAbs: true), end: this(2, 1))))
    }

    func test_unknownFunction_parses() {
        XCTAssertEqual(parse("VLOOKUP(A1)")?.expr, .call(name: "VLOOKUP", arguments: [.ref(this(0, 0))]))
        XCTAssertEqual(parse("log10(2)")?.expr, .call(name: "LOG10", arguments: [n(2)]))
    }

    func test_emptyArgument_isMissing() {
        XCTAssertEqual(parse("PV(1,2,,0)")?.expr, .call(name: "PV", arguments: [n(1), n(2), .missing, n(0)]))
        XCTAssertEqual(parse("F()")?.expr, .call(name: "F", arguments: []))
        XCTAssertEqual(parse("F(,)")?.expr, .call(name: "F", arguments: [.missing, .missing]))
    }

    func test_outsideTable_fails_withMessage() {
        XCTAssertEqual(parseError("D9")?.message, "D9 is outside this table")
        XCTAssertEqual(parseError("1+SUM(A1:B12)")?.message, "B12 is outside this table")
        XCTAssertEqual(parseError("1+SUM(A1:B12)")?.offset, 9)
    }

    func test_unknownFigure_fails() {
        XCTAssertEqual(parseError("nope!A1")?.message, "There is no table named nope")
        XCTAssertEqual(parseError("revenue!C1")?.message, "C1 is outside the table named revenue")
    }

    func test_figureRef_resolvesAgainstThatFigure() {
        XCTAssertEqual(parse("revenue!B2")?.expr,
                       .ref(FormulaRef(target: .figure(name: "revenue"), anchor: .id(row: revenue.rows[1], column: revenue.columns[1]))))
    }

    func test_researchRef_isPositional_quotedName() {
        XCTAssertEqual(parse("research:'model v3'!B2")?.expr,
                       .ref(FormulaRef(target: .research(name: "model v3"), anchor: .position(row: 1, column: 1))))
        XCTAssertEqual(parse("research:model-v3!Z99")?.expr,
                       .ref(FormulaRef(target: .research(name: "model-v3"), anchor: .position(row: 98, column: 25))),
                       "a research ref is never bounds-checked")
    }

    func test_parsePositional_needsNoTable() throws {
        let f = try FormulaParser.parsePositional("A1+fig!$B2").get()
        XCTAssertEqual(f.expr, .binary(.add,
            .ref(FormulaRef(target: .this, anchor: .position(row: 0, column: 0))),
            .ref(FormulaRef(target: .figure(name: "fig"), anchor: .position(row: 1, column: 1), columnAbsolute: true))))
    }

    func test_malformed_failsWithWriterFacingMessages() {
        let cases: [(String, String)] = [
            ("", "The formula is empty"),
            ("1+", "The formula ends before its last value"),
            ("(1+2", "A “(” is missing its “)”"),
            ("1+2)", "There is a “)” without its “(”"),
            ("\"abc", "Text is missing its closing quote"),
            ("SUM(1,2", "“SUM(” is missing its “)”"),
            ("foo", "“foo” isn't a cell, a function or a value"),
            ("2B", "Didn't expect “B” here"),
            ("A1:", "Expected a cell after “:”"),
            ("#BOGUS", "“#BOGUS” isn't an error value"),
        ]
        for (text, message) in cases {
            XCTAssertEqual(parseError(text)?.message, message, text)
        }
    }

    func test_parse_isTotal_onArbitraryInput() {
        var generator = SplitMix(seed: 42)
        let alphabet = Array("AB$1:2!(),\"'#%^*/+-=<> .eE_research REF?é\n")
        for _ in 0..<5_000 {
            let length = Int(generator.next() % 24)
            let text = String((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
            if case .success(let f) = FormulaParser.parse(text, in: table, figures: figures) {
                _ = FormulaParser.render(f, in: table, figures: figures)
            }
            _ = FormulaParser.parsePositional(text)
        }
        XCTAssertNotNil(parseError(String(repeating: "(", count: 50_000) + "1"))
        XCTAssertNotNil(parseError(String(repeating: "-", count: 50_000) + "1"))
        XCTAssertNotNil(parseError(String(repeating: "F(", count: 50_000)))
    }

    // MARK: render

    func test_render_roundTrips() {
        let cases: [(String, String)] = [
            ("1+2*3", "1+2*3"),
            ("(1+2)*3", "(1+2)*3"),
            ("-2^2", "-2^2"),
            ("2^-1", "2^-1"),
            ("10%*50", "10%*50"),
            ("1+1=2", "1+1=2"),
            ("sum($a$1:b3)", "SUM($A$1:B3)"),
            ("if(a1>=2,\"yes\",\"say \"\"no\"\"\")", "IF(A1>=2,\"yes\",\"say \"\"no\"\"\")"),
            ("pv(0.05,10,,0)", "PV(0.05,10,,0)"),
            ("a$1-$b2/c3", "A$1-$B2/C3"),
            ("revenue!b2+research:'model v3'!c9*research:model-v3!a1", "revenue!B2+research:'model v3'!C9*research:model-v3!A1"),
            ("2^(3^2)+(1+2)%-average(a1:c4)/(1-0.25)", "2^(3^2)+(1+2)%-AVERAGE(A1:C4)/(1-0.25)"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(render(parse(input)), expected, input)
        }
    }

    func test_render_numberLiterals() {
        let cases: [(Double, String)] = [
            (3, "3"), (0.1 + 0.2, "0.3"), (1234567.5, "1234567.5"), (1e14, "100000000000000"),
            (0.000001, "0.000001"), (1e15, "1E+15"), (2.675, "2.675"), (1.0 / 3.0, "0.333333333333333"),
        ]
        for (x, s) in cases {
            XCTAssertEqual(FormulaParser.render(Formula(n(x)), in: table), s)
        }
    }

    func test_render_afterDeletingRangeEdge_shrinks() {
        let f = parse("SUM(A1:A4)")
        table.deleteRow(table.rows[3])
        XCTAssertEqual(render(f), "SUM(A1:A3)")
        table.deleteRow(table.rows[0])
        XCTAssertEqual(render(f), "SUM(A1:A2)", "the old A2:A3 now at A1:A2")
    }

    func test_render_afterDeletingColumnEdge_shrinks() {
        let f = parse("SUM(A1:C1)")
        table.deleteColumn(table.columns[2])
        XCTAssertEqual(render(f), "SUM(A1:B1)")
    }

    func test_render_afterDeletingSingleRef_isREF() {
        let f = parse("A2+1")
        table.deleteRow(table.rows[1])
        XCTAssertEqual(render(f), "#REF!+1")
    }

    func test_render_rangeWhollyDeleted_isREF() {
        let f = parse("SUM(A2:A3)")
        let doomed = [table.rows[1], table.rows[2]]
        doomed.forEach { table.deleteRow($0) }
        XCTAssertEqual(render(f), "SUM(#REF!)")
    }

    func test_render_followsInsertsAndMoves() {
        let f = parse("B2")
        table.insertRow(after: nil)
        XCTAssertEqual(render(f), "B3")
    }

    func test_render_missingFigure_isNamedREF() throws {
        let f = try XCTUnwrap(parse("revenue!A1+SUM(revenue!A1:B2)"))
        XCTAssertEqual(FormulaParser.render(f, in: table), "revenue!#REF!+SUM(revenue!#REF!)")
    }

    func test_liveSlotsBetween_isTheSharedRangeDefinition() {
        let r = table.rows
        table.deleteRow(r[1])
        XCTAssertEqual(table.liveRows(betweenSlots: 3, 0), [r[0], r[2], r[3]])
        XCTAssertEqual(table.liveRows(betweenSlots: 1, 1), [])
    }

    // MARK: translate

    private func key(_ r: Int, _ c: Int) -> CellKey { CellKey(row: table.rows[r], column: table.columns[c]) }

    private func translated(_ text: String, from: CellKey, to: CellKey) -> String? {
        parse(text).map {
            FormulaParser.render(FormulaParser.translate($0, from: from, to: to, in: table, figures: figures), in: table, figures: figures)
        }
    }

    func test_translate_fillDown() {
        XCTAssertEqual(translated("A1+$B$1", from: key(0, 2), to: key(1, 2)), "A2+$B$1")
        XCTAssertEqual(translated("SUM(A$1:A1)*$A2", from: key(0, 1), to: key(2, 2)), "SUM(B$1:B3)*$A4")
    }

    func test_translate_offGrid_isREF() throws {
        XCTAssertEqual(translated("A4+1", from: key(0, 2), to: key(1, 2)), "#REF!+1")
        XCTAssertEqual(translated("A1", from: key(1, 2), to: key(0, 2)), "#REF!")
        XCTAssertEqual(translated("SUM(A3:A4)", from: key(0, 2), to: key(1, 2)), "SUM(#REF!)")
        let f = try XCTUnwrap(parse("A4+1"))
        XCTAssertEqual(FormulaParser.translate(f, from: key(0, 2), to: key(1, 2), in: table).expr,
                       .binary(.add, .error(.ref), n(1)))
    }

    func test_translate_figureAndResearchRefs() {
        XCTAssertEqual(translated("revenue!A1+research:m!B2", from: key(0, 0), to: key(1, 0)), "revenue!A2+research:m!B3")
        XCTAssertEqual(translated("revenue!A2", from: key(0, 0), to: key(1, 0)), "#REF!", "off the figure's grid")
        XCTAssertEqual(translated("research:m!B1", from: key(1, 0), to: key(0, 0)), "#REF!", "above row 1")
        XCTAssertEqual(translated("research:m!B1", from: key(0, 0), to: key(3, 0)), "research:m!B4", "never bounds-checked below")
    }

    func test_translate_shiftsAShrunkRange() {
        let f = parse("SUM(A1:A3)")!
        table.deleteRow(table.rows[2])     // A1:A3 now shows A1:A2
        let t = FormulaParser.translate(f, from: key(0, 1), to: key(1, 1), in: table)
        XCTAssertEqual(FormulaParser.render(t, in: table), "SUM(A2:A3)")
    }

    // MARK: codable

    func test_formulaCodableRoundTrip() throws {
        let f = try XCTUnwrap(parse("IF(SUM($A$1:B3)>=revenue!B2,research:'m v'!C1%,PV(-1,,\"x\",TRUE))+#DIV/0!"))
        let back = try JSONDecoder().decode(Formula.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
    }
}

/// A seeded generator so the totality sweep is the same every run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
