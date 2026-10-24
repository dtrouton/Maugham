import XCTest
@testable import MaughamCore

final class DateFunctionsTests: XCTestCase {
    private func d(_ y: Int, _ m: Int, _ day: Int) -> CellValue { .date(DateSerial.serial(year: y, month: m, day: day)!) }

    private var microsoft: FormulaTestGrid {
        var g = FormulaTestGrid(column: "A", [.number(-10000), .number(2750), .number(4250), .number(3250), .number(2750)])
        let dates = [d(2008, 1, 1), d(2008, 3, 1), d(2008, 10, 30), d(2009, 2, 15), d(2009, 4, 1)]
        for (i, v) in dates.enumerated() { g.cells["B\(i + 1)"] = v }
        return g
    }

    func test_dateArithmetic() {
        let g = FormulaTestGrid(["A1": d(2026, 1, 1), "B1": d(2026, 10, 24)])
        XCTAssertEqual(g.eval("B1-A1"), .number(296))
        XCTAssertEqual(g.eval("A1+30"), d(2026, 1, 31))
    }

    func test_yearMonthEdate() {
        let g = FormulaTestGrid(["A1": d(2026, 10, 24), "B1": .number(46319), "C1": .text("x")])
        XCTAssertEqual(g.eval("YEAR(A1)"), .number(2026))
        XCTAssertEqual(g.eval("MONTH(A1)"), .number(10))
        XCTAssertEqual(g.eval("YEAR(B1)"), .number(2026))
        XCTAssertEqual(g.eval("EDATE(A1, 3)"), d(2027, 1, 24))
        XCTAssertEqual(g.eval("EDATE(A1, -1.9)"), d(2026, 9, 24))
        XCTAssertEqual(g.eval("MONTH(5)"), .error(.num))
        XCTAssertEqual(g.eval("YEAR(C1)"), .error(.value))
        XCTAssertEqual(FormulaTestGrid(["A1": d(2026, 1, 31)]).eval("EDATE(A1,1)"), d(2026, 2, 28))
    }

    func test_xnpvMicrosoftExample() {
        guard case .number(let x) = microsoft.eval("XNPV(0.09, A1:A5, B1:B5)") else { return XCTFail("not a number") }
        XCTAssertEqual(x, 2086.65, accuracy: 0.005)
    }

    func test_xirrMicrosoftExample() {
        guard case .number(let r) = microsoft.eval("XIRR(A1:A5, B1:B5)") else { return XCTFail("not a number") }
        XCTAssertEqual(r, 0.373362535, accuracy: 1e-6)
        var g = microsoft
        g.cells["C1"] = .number(r)
        guard case .number(let n) = g.eval("XNPV(C1, A1:A5, B1:B5)") else { return XCTFail("not a number") }
        XCTAssertEqual(n, 0, accuracy: 1e-4)
        guard case .number(let r2) = microsoft.eval("XIRR(A1:A5, B1:B5, 0.5)") else { return XCTFail("not a number") }
        XCTAssertEqual(r2, 0.373362535, accuracy: 1e-6)
    }

    func test_xnpvAndXirrErrors() {
        var g = microsoft
        XCTAssertEqual(g.eval("XNPV(0.09, A1:A5, B1:B4)"), .error(.num))
        XCTAssertEqual(g.eval("XIRR(A1:A5, B1:B4)"), .error(.num))
        XCTAssertEqual(g.eval("XNPV(-1, A1:A5, B1:B5)"), .error(.num))
        g.cells["B3"] = d(2007, 1, 1)
        XCTAssertEqual(g.eval("XNPV(0.09, A1:A5, B1:B5)"), .error(.num))
        let positive = FormulaTestGrid(["A1": .number(1), "A2": .number(2), "B1": d(2026, 1, 1), "B2": d(2027, 1, 1)])
        XCTAssertEqual(positive.eval("XIRR(A1:A2, B1:B2)"), .error(.num))
    }

    func test_hugeDatesAreNumNotACrash() {
        let big = CellValue.number(1e30)
        for (cell, label) in [("B1", "first"), ("B3", "later")] {
            var g = microsoft
            g.cells[cell] = big
            XCTAssertEqual(g.eval("XNPV(0.09, A1:A5, B1:B5)"), .error(.num), label)
            XCTAssertEqual(g.eval("XIRR(A1:A5, B1:B5)"), .error(.num), label)
            g.cells[cell] = .number(-1e30)
            XCTAssertEqual(g.eval("XNPV(0.09, A1:A5, B1:B5)"), .error(.num), label)
            XCTAssertEqual(g.eval("YEAR(\(cell))"), .error(.num), label)
        }
        XCTAssertEqual(FormulaTestGrid(["A1": big]).eval("EDATE(A1, 1)"), .error(.num))
        XCTAssertEqual(microsoft.eval("EDATE(A1, 1e30)"), .error(.num))
    }

    func test_pairsAlignByPosition_blanksAreValueErrors() {
        var g = microsoft
        g.cells["A6"] = .number(100); g.cells["B6"] = d(2009, 5, 1)
        g.cells["A3"] = nil              // blank in values at position 3
        XCTAssertEqual(g.eval("XNPV(0.09, A1:A6, B1:B6)"), .error(.value))
        g.cells["A3"] = .number(4250); g.cells["B5"] = nil   // blank in dates at a different position
        XCTAssertEqual(g.eval("XNPV(0.09, A1:A6, B1:B6)"), .error(.value))
        XCTAssertEqual(g.eval("XIRR(A1:A6, B1:B6)"), .error(.value))
        g.cells["A3"] = nil              // blanks at different positions in each list
        XCTAssertEqual(g.eval("XNPV(0.09, A1:A6, B1:B6)"), .error(.value))
        g.cells["A3"] = .text("x"); g.cells["B5"] = d(2009, 4, 1)
        XCTAssertEqual(g.eval("XNPV(0.09, A1:A6, B1:B6)"), .error(.value))
    }
}
