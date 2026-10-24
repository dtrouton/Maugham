import XCTest
@testable import MaughamCore

/// A grid of A1 → value for evaluator tests; formulas are parsed positionally.
struct FormulaTestGrid {
    var cells: [String: CellValue] = [:]

    init(_ cells: [String: CellValue] = [:]) { self.cells = cells }

    /// Fills a column top-down from `row` 1.
    init(column: String, _ values: [CellValue]) {
        for (i, v) in values.enumerated() { cells["\(column)\(i + 1)"] = v }
    }

    var environment: FormulaEnvironment {
        let cells = self.cells
        @Sendable func at(_ row: Int, _ column: Int) -> CellValue {
            cells[A1.columnLetters(column) + String(row + 1)] ?? .empty
        }
        return FormulaEnvironment(
            cell: { ref in
                guard case .position(let r, let c) = ref.anchor else { return .error(.ref) }
                return at(r, c)
            },
            range: { g in
                guard case .position(let r0, let c0) = g.start.anchor,
                      case .position(let r1, let c1) = g.end.anchor else { return nil }
                return (min(r0, r1)...max(r0, r1)).map { r in (min(c0, c1)...max(c0, c1)).map { c in at(r, c) } }
            })
    }

    func eval(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> CellValue {
        guard case .success(let f) = FormulaParser.parsePositional(text) else {
            XCTFail("unparseable: \(text)", file: file, line: line); return .error(.value)
        }
        return FormulaEvaluator.evaluate(f, in: environment)
    }
}

final class FormulaEvaluatorTests: XCTestCase {
    private let none = FormulaTestGrid()

    private func number(_ v: CellValue, file: StaticString = #filePath, line: UInt = #line) -> Double {
        guard case .number(let x) = v else { XCTFail("not a number: \(v)", file: file, line: line); return .nan }
        return x
    }

    // MARK: binary floating point and precedence

    func test_pointOnePlusPointTwo_roundsToPointThreeAtFifteenDigits() {
        let x = number(none.eval("0.1+0.2"))
        XCTAssertEqual(ExcelRounding.round(x, digits: 15), 0.3)
        XCTAssertEqual(none.eval("0.1+0.2=0.3"), .bool(true))
    }

    func test_excelPrecedence() {
        XCTAssertEqual(none.eval("-2^2"), .number(4))
        XCTAssertEqual(none.eval("2^-1"), .number(0.5))
        XCTAssertEqual(none.eval("10%*50"), .number(5))
    }

    // MARK: arithmetic operands

    func test_operandCoercion() {
        XCTAssertEqual(none.eval("\"3\"+1"), .number(4))
        XCTAssertEqual(none.eval("\"a\"+1"), .error(.value))
        XCTAssertEqual(none.eval("\"-1.5\"*2"), .number(-3))
        XCTAssertEqual(none.eval("\"1e3\"+0"), .number(1000))
        XCTAssertEqual(none.eval("\"\"+1"), .error(.value))
        XCTAssertEqual(none.eval("TRUE+1"), .number(2))
        XCTAssertEqual(none.eval("FALSE*5"), .number(0))
        XCTAssertEqual(none.eval("A1+2"), .number(2))                       // empty is 0
        XCTAssertEqual(FormulaTestGrid(["A1": .date(46000)]).eval("A1*1"), .number(46000))
    }

    func test_errorsPropagate_leftOperandFirst() {
        let g = FormulaTestGrid(["A1": .error(.ref), "A2": .error(.num)])
        XCTAssertEqual(g.eval("A1+A2"), .error(.ref))
        XCTAssertEqual(g.eval("A2+A1"), .error(.num))
        XCTAssertEqual(g.eval("1/0+A2"), .error(.divideByZero))
        XCTAssertEqual(g.eval("A2=A1"), .error(.num))
        XCTAssertEqual(g.eval("\"a\"+1/0"), .error(.value))
    }

    // MARK: arithmetic results

    func test_dateArithmetic() {
        let g = FormulaTestGrid(["A1": .date(46000), "A2": .date(45990)])
        XCTAssertEqual(g.eval("A1+7"), .date(46007))
        XCTAssertEqual(g.eval("7+A1"), .date(46007))
        XCTAssertEqual(g.eval("A1-7"), .date(45993))
        XCTAssertEqual(g.eval("A1-A2"), .number(10))
        XCTAssertEqual(g.eval("A1*2"), .number(92000))
        XCTAssertEqual(g.eval("50000-A1"), .number(4000))
    }

    func test_arithmeticErrors() {
        XCTAssertEqual(none.eval("1/0"), .error(.divideByZero))
        XCTAssertEqual(none.eval("1/A1"), .error(.divideByZero))
        XCTAssertEqual(none.eval("0^0"), .error(.num))
        XCTAssertEqual(none.eval("(-8)^0.5"), .error(.num))
        XCTAssertEqual(none.eval("(-2)^3"), .number(-8))
        XCTAssertEqual(none.eval("10^400"), .error(.num))
        XCTAssertEqual(none.eval("1e300*1e300"), .error(.num))
    }

    // MARK: comparison

    func test_comparisonOrdersNumbersBeforeTextBeforeBooleans() {
        XCTAssertEqual(none.eval("1<\"a\""), .bool(true))
        XCTAssertEqual(none.eval("999999<\"0\""), .bool(true))
        XCTAssertEqual(none.eval("\"zzz\"<FALSE"), .bool(true))
        XCTAssertEqual(none.eval("FALSE<TRUE"), .bool(true))
        XCTAssertEqual(none.eval("\"abc\"=\"ABC\""), .bool(true))
        XCTAssertEqual(none.eval("\"a\"<\"B\""), .bool(true))
        XCTAssertEqual(none.eval("1=TRUE"), .bool(false))
        XCTAssertEqual(none.eval("2>=2"), .bool(true))
        XCTAssertEqual(none.eval("2<>2"), .bool(false))
        XCTAssertEqual(FormulaTestGrid(["A1": .date(46000)]).eval("A1=46000"), .bool(true))
    }

    func test_emptyEqualsZeroEmptyTextAndFalse() {
        XCTAssertEqual(none.eval("A1=0"), .bool(true))
        XCTAssertEqual(none.eval("A1=\"\""), .bool(true))
        XCTAssertEqual(none.eval("A1=FALSE"), .bool(true))
        XCTAssertEqual(none.eval("A1=B1"), .bool(true))
        XCTAssertEqual(none.eval("A1<1"), .bool(true))
        XCTAssertEqual(none.eval("A1<\"a\""), .bool(true))
        XCTAssertEqual(none.eval("A1<TRUE"), .bool(true))
    }

    // MARK: ranges and errors

    func test_rangeInAScalarPosition_isValueError() {
        let g = FormulaTestGrid(column: "A", [.number(1), .number(2)])
        XCTAssertEqual(g.eval("A1:A2+1"), .error(.value))
        XCTAssertEqual(g.eval("A1:A2"), .error(.value))
        XCTAssertEqual(g.eval("A1:A2=1"), .error(.value))
    }

    func test_aRefRange_isRefError() {
        let env = FormulaEnvironment(cell: { _ in .number(1) }, range: { _ in nil })
        let f = try! FormulaParser.parsePositional("SUM(A1:A3)").get()
        XCTAssertEqual(FormulaEvaluator.evaluate(f, in: env), .error(.ref))
    }

    func test_errorNodesAndMissingInScalarPosition() {
        XCTAssertEqual(FormulaEvaluator.evaluate(Formula(.error(.ref)), in: none.environment), .error(.ref))
        XCTAssertEqual(FormulaEvaluator.evaluate(Formula(.binary(.add, .missing, .number(2))), in: none.environment), .number(2))
    }

    func test_aBareEmptyCell_evaluatesToZero() {
        XCTAssertEqual(none.eval("A1"), .number(0))
        XCTAssertEqual(FormulaTestGrid(["A1": .text("x")]).eval("A1"), .text("x"))
        XCTAssertEqual(none.eval("+\"a\""), .text("a"))                    // unary plus is a no-op
    }

    func test_unknownFunction_isNameError() {
        XCTAssertEqual(none.eval("NOSUCH(1)"), .error(.name))
    }

    func test_wrongArgumentCount_isValueError() {
        XCTAssertEqual(none.eval("ROUND(1)"), .error(.value))
        XCTAssertEqual(none.eval("IFERROR(1)"), .error(.value))
        XCTAssertEqual(none.eval("COUNTIF(A1:A2,1,2)"), .error(.value))
    }

    func test_registeredGroupsHoldNoDuplicateNames() {
        let total = FormulaFunctions.groups.reduce(0) { $0 + $1.count }
        XCTAssertEqual(FormulaFunctions.all.count, total)
    }

    // MARK: depth

    func test_evaluationAtTheParserDepthBound_runsOnA512KBThread() {
        let n = FormulaParser.maxDepth
        let texts = [
            String(repeating: "SUM(", count: n - 1) + "A1:B2" + String(repeating: ")", count: n - 1),
            String(repeating: "IF(TRUE,", count: n - 1) + "1" + String(repeating: ")", count: n - 1),
            "1" + String(repeating: "+1", count: n - 1),
            String(repeating: "-", count: n - 1) + "1",
        ]
        let formulas = texts.map { try! FormulaParser.parsePositional($0).get() }
        let env = FormulaTestGrid(["A1": .number(1), "B2": .number(2)]).environment
        let done = expectation(description: "512 KB thread")
        let results = FormulaResultBox<[CellValue]>([])
        let thread = Thread {
            results.set(formulas.map { FormulaEvaluator.evaluate($0, in: env) })
            done.fulfill()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        wait(for: [done], timeout: 60)
        XCTAssertEqual(results.get(), [.number(3), .number(1), .number(Double(n)), .number(n % 2 == 0 ? -1 : 1)])
    }
}

final class FormulaResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
