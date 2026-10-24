import XCTest
@testable import MaughamCore

/// Microsoft's documented examples for each function, at the precision Microsoft shows;
/// each assertion holds to half a unit of the last digit shown. Every iterative result
/// also asserts its defining property, which is exact.
final class FinanceFunctionsTests: XCTestCase {
    private func value(_ r: Result<Double, FormulaError>, file: StaticString = #filePath, line: UInt = #line) -> Double {
        switch r {
        case .success(let x): return x
        case .failure(let err): XCTFail("unexpected \(err.rawValue)", file: file, line: line); return .nan
        }
    }

    /// `expected` shown to `decimals` places: within half a unit of the last.
    private func assertShown(_ r: Result<Double, FormulaError>, _ expected: Double, decimals: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        let x = value(r, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(x - expected), 0.5 * pow(10, -Double(decimals)),
                                 "\(x) is not \(expected) to \(decimals) places", file: file, line: line)
    }

    private func assertError(_ r: Result<Double, FormulaError>, _ err: FormulaError,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r, .failure(err), file: file, line: line)
    }

    /// IRR's defining property: the flows' NPV at the rate, the first undiscounted, is zero.
    private func assertIsIRR(_ r: Double, of flows: [Double], file: StaticString = #filePath, line: UInt = #line) {
        let npv = flows.enumerated().reduce(0.0) { $0 + $1.element / pow(1 + r, Double($1.offset)) }
        let largest = flows.map(abs).max() ?? 1
        XCTAssertLessThan(abs(npv), 1e-6 * largest, "NPV at \(r) is \(npv)", file: file, line: line)
    }

    // MARK: NPV

    func test_npv() {
        assertShown(Finance.npv(rate: 0.1, [-10000, 3000, 4200, 6800]), 1188.44, decimals: 2)
        let flows: [Double] = [8000, 9200, 10000, 12000, 14500]
        assertShown(Finance.npv(rate: 0.08, flows).map { $0 + -40000 }, 1922.06, decimals: 2)
        assertShown(Finance.npv(rate: 0.08, flows + [-9000]).map { $0 + -40000 }, -3749.47, decimals: 2)
        assertError(Finance.npv(rate: -1, [1]), .divideByZero)
    }

    // MARK: IRR

    func test_irr() {
        let four: [Double] = [-70000, 12000, 15000, 18000, 21000]
        let five = four + [26000]
        let two: [Double] = [-70000, 12000, 15000]
        let a = value(Finance.irr(four)), b = value(Finance.irr(five)), c = value(Finance.irr(two, guess: -0.1))
        assertShown(.success(a), -0.021245, decimals: 6)
        assertShown(.success(b), 0.086631, decimals: 6)
        assertShown(.success(c), -0.443507, decimals: 6)
        assertIsIRR(a, of: four)
        assertIsIRR(b, of: five)
        assertIsIRR(c, of: two)
    }

    func test_irr_withoutASignChange_isNum() {
        assertError(Finance.irr([100, 200]), .num)
        assertError(Finance.irr([-100, -200]), .num)
    }

    /// Ruling: where Newton fails from the guess (Excel's 20 iterations give up, #NUM!),
    /// bisection on (−0.999999, 10) may still find the root.
    func test_irr_whereNewtonFails_bisectionStillAnswers() {
        let flows: [Double] = [-70000, 12000, 15000, 18000, 21000, 26000]
        let r = value(Finance.irr(flows, guess: 9.5))
        assertIsIRR(r, of: flows)
    }

    // MARK: MIRR

    func test_mirr() {
        let flows: [Double] = [-120000, 39000, 30000, 21000, 37000, 46000]
        assertShown(Finance.mirr(flows, financeRate: 0.1, reinvestRate: 0.12), 0.12609, decimals: 5)
        // Microsoft's "after three years" row, MIRR(A2:A5, …): the first four flows.
        assertShown(Finance.mirr(Array(flows.prefix(4)), financeRate: 0.1, reinvestRate: 0.12), -0.04804, decimals: 5)
        assertShown(Finance.mirr(flows, financeRate: 0.1, reinvestRate: 0.14), 0.13476, decimals: 5)
        assertError(Finance.mirr([100, 200], financeRate: 0.1, reinvestRate: 0.1), .divideByZero)
        assertError(Finance.mirr([-100, -200], financeRate: 0.1, reinvestRate: 0.1), .divideByZero)
    }

    // MARK: the annuity family

    func test_pmt() {
        assertShown(Finance.pmt(rate: 0.08 / 12, periods: 10, present: 10000), -1037.03, decimals: 2)
        assertShown(Finance.pmt(rate: 0.08 / 12, periods: 10, present: 10000, atStart: true), -1030.16, decimals: 2)
    }

    func test_pv_fv() {
        assertShown(Finance.pv(rate: 0.08 / 12, periods: 240, payment: 500), -59777.15, decimals: 2)
        assertShown(Finance.fv(rate: 0.06 / 12, periods: 10, payment: -200, present: -500, atStart: true), 2581.40, decimals: 2)
    }

    func test_nper() {
        assertShown(Finance.nper(rate: 0.12 / 12, payment: -100, present: -1000, future: 10000, atStart: true), 59.6738657, decimals: 7)
        assertShown(Finance.nper(rate: 0.12 / 12, payment: -100, present: -1000, future: 10000), 60.0821229, decimals: 7)
        assertShown(Finance.nper(rate: 0.01, payment: -100, present: -1000), -9.57859404, decimals: 8)
        assertError(Finance.nper(rate: 0.01, payment: 100, present: -100_000), .num)   // a non-positive log argument
    }

    func test_rate() {
        let r = value(Finance.rate(periods: 48, payment: -200, present: 8000))
        assertShown(.success(r), 0.0077, decimals: 4)
        assertShown(.success(r * 12), 0.0924, decimals: 4)
        let back = value(Finance.pv(rate: r, periods: 48, payment: -200))
        XCTAssertLessThan(abs(back - 8000), 1e-6)
    }

    func test_zeroRateBranches() {
        XCTAssertEqual(Finance.pmt(rate: 0, periods: 10, present: 1000), .success(-100))
        XCTAssertEqual(Finance.pv(rate: 0, periods: 10, payment: -100), .success(1000))
        XCTAssertEqual(Finance.nper(rate: 0, payment: -100, present: 1000), .success(10))
        XCTAssertEqual(Finance.fv(rate: 0, periods: 10, payment: -100), .success(1000))
    }

    // MARK: CAGR

    func test_cagr() {
        assertShown(Finance.cagr(start: 100, end: 150, years: 3), 0.144714, decimals: 6)
        assertError(Finance.cagr(start: 0, end: 1, years: 1), .divideByZero)
        assertError(Finance.cagr(start: 100, end: 150, years: 0), .divideByZero)
        assertError(Finance.cagr(start: 100, end: -150, years: 3), .num)
    }

    // MARK: formula level

    func test_formula_npvOverARange_ignoresTextAndEmpties() {
        let grid = FormulaTestGrid([
            "B1": .number(0.1), "C1": .number(-10000), "D1": .text("note"), "E1": .number(3000), "F1": .empty,
            "G1": .number(4200), "H1": .bool(true), "I1": .date(45000), "J1": .number(6800),
        ])
        guard case .number(let x) = grid.eval("NPV(B1, C1:J1)") else { return XCTFail("not a number") }
        assertShown(.success(x), 1188.44, decimals: 2)
        guard case .number(let y) = grid.eval("NPV(B1, C1:F1)") else { return XCTFail("not a number") }
        assertShown(.success(y), value(Finance.npv(rate: 0.1, [-10000, 3000])), decimals: 9)
    }

    func test_formula_npvDirectArguments_countBooleansAndNumericText() {
        let none = FormulaTestGrid()
        XCTAssertEqual(none.eval("NPV(0, TRUE, \"2\", 3)"), .number(6))
        XCTAssertEqual(none.eval("NPV(0, \"x\")"), .error(.value))
        XCTAssertEqual(none.eval("NPV(-1, 1)"), .error(.divideByZero))
        XCTAssertEqual(FormulaTestGrid(["A1": .error(.ref)]).eval("NPV(0.1, A1:A2)"), .error(.ref))
    }

    func test_formula_missingArgumentsTakeTheirDefaults() {
        let none = FormulaTestGrid()
        guard case .number(let pv) = none.eval("PV(1%, 12, , 1000)") else { return XCTFail("not a number") }
        assertShown(.success(pv), -887.449, decimals: 3)
        guard case .number(let pmt) = none.eval("PMT(8%/12, 10, 10000, , TRUE)") else { return XCTFail("not a number") }
        assertShown(.success(pmt), -1030.16, decimals: 2)
    }

    func test_formula_irrAndMirrReadOneRange() {
        let grid = FormulaTestGrid(column: "A", [.number(-70000), .number(12000), .text("x"), .number(15000),
                                                 .number(18000), .number(21000), .number(26000)])
        guard case .number(let r) = grid.eval("IRR(A1:A7)") else { return XCTFail("not a number") }
        assertShown(.success(r), 0.086631, decimals: 6)
        guard case .number(let c) = grid.eval("IRR(A1:A4, -10%)") else { return XCTFail("not a number") }
        assertShown(.success(c), -0.443507, decimals: 6)
        XCTAssertEqual(FormulaTestGrid(column: "A", [.number(100), .number(200)]).eval("IRR(A1:A2)"), .error(.num))
        let m = FormulaTestGrid(column: "A", [.number(-120000), .number(39000), .number(30000), .number(21000),
                                              .number(37000), .number(46000)])
        guard case .number(let x) = m.eval("MIRR(A1:A6, 10%, 12%)") else { return XCTFail("not a number") }
        assertShown(.success(x), 0.12609, decimals: 5)
    }

    func test_formula_rateNperFvCagr() {
        let none = FormulaTestGrid()
        guard case .number(let r) = none.eval("RATE(48, -200, 8000)") else { return XCTFail("not a number") }
        assertShown(.success(r), 0.0077, decimals: 4)
        guard case .number(let n) = none.eval("NPER(12%/12, -100, -1000, 10000, 1)") else { return XCTFail("not a number") }
        assertShown(.success(n), 59.6738657, decimals: 7)
        guard case .number(let f) = none.eval("FV(6%/12, 10, -200, -500, 1)") else { return XCTFail("not a number") }
        assertShown(.success(f), 2581.40, decimals: 2)
        guard case .number(let g) = none.eval("CAGR(100, 150, 3)") else { return XCTFail("not a number") }
        assertShown(.success(g), 0.144714, decimals: 6)
        XCTAssertEqual(none.eval("CAGR(0, 1, 1)"), .error(.divideByZero))
        XCTAssertEqual(none.eval("PMT(1%, 10)"), .error(.value))   // too few arguments
    }
}
