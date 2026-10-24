import XCTest
@testable import MaughamCore

final class FormulaFunctionsTests: XCTestCase {
    private let none = FormulaTestGrid()
    private let mixed = FormulaTestGrid(column: "A", [.number(1), .text("x"), .bool(true), .number(2)])
    private let oneToFour = FormulaTestGrid(column: "A", [.number(1), .number(2), .number(3), .number(4)])

    // MARK: totals

    func test_rangeArguments_countNumbersAndDatesOnly() {
        XCTAssertEqual(mixed.eval("SUM(A1:A4)"), .number(3))
        XCTAssertEqual(mixed.eval("COUNT(A1:A4)"), .number(2))
        XCTAssertEqual(mixed.eval("AVERAGE(A1:A4)"), .number(1.5))
        XCTAssertEqual(mixed.eval("MIN(A1:A4)"), .number(1))
        XCTAssertEqual(mixed.eval("MAX(A1:A4)"), .number(2))
        XCTAssertEqual(mixed.eval("MEDIAN(A1:A4)"), .number(1.5))
        let dated = FormulaTestGrid(column: "A", [.date(10), .number(5), .empty])
        XCTAssertEqual(dated.eval("SUM(A1:A3)"), .number(15))
        XCTAssertEqual(dated.eval("COUNT(A1:A3)"), .number(2))
    }

    func test_aReferencedCell_readsLikeARange() {
        let g = FormulaTestGrid(["A1": .text("x"), "A2": .bool(true)])
        XCTAssertEqual(g.eval("SUM(A1,A2,3)"), .number(3))
        XCTAssertEqual(g.eval("COUNT(A1,A2)"), .number(0))
    }

    func test_rangeErrors_propagateFirstInRowMajorOrder() {
        let g = FormulaTestGrid(["A1": .number(1), "B1": .error(.num), "A2": .error(.ref)])
        XCTAssertEqual(g.eval("SUM(A1:B2)"), .error(.num))
        XCTAssertEqual(g.eval("AVERAGE(A1:B2)"), .error(.num))
        XCTAssertEqual(g.eval("MIN(A1:B2)"), .error(.num))
        XCTAssertEqual(g.eval("MAX(A1:B2)"), .error(.num))
        XCTAssertEqual(g.eval("MEDIAN(A1:B2)"), .error(.num))
        XCTAssertEqual(g.eval("SUM(A2:B2)"), .error(.ref))
    }

    func test_count_ignoresErrors() {
        // Excel's COUNT counts numbers and skips error values, in a range or given directly.
        let g = FormulaTestGrid(["A1": .number(1), "A2": .error(.num)])
        XCTAssertEqual(g.eval("COUNT(A1:A2)"), .number(1))
        XCTAssertEqual(g.eval("COUNT(1/0,2)"), .number(1))
    }

    func test_directArguments_coerceNumbersBooleansAndNumericText() {
        XCTAssertEqual(none.eval("SUM(1,TRUE,\"2\")"), .number(4))
        XCTAssertEqual(none.eval("SUM(1,\"x\")"), .error(.value))
        XCTAssertEqual(none.eval("AVERAGE(\"x\")"), .error(.value))
        XCTAssertEqual(none.eval("MAX(1,\"x\")"), .error(.value))
        XCTAssertEqual(none.eval("COUNT(1,TRUE,\"2\",\"x\")"), .number(3))
        XCTAssertEqual(none.eval("SUM(1/0,1)"), .error(.divideByZero))
        XCTAssertEqual(none.eval("MAX(-5,FALSE)"), .number(0))
    }

    func test_totalsOfNothing() {
        let blanks = FormulaTestGrid(column: "A", [.empty, .text("x")])
        XCTAssertEqual(blanks.eval("AVERAGE(A1:A2)"), .error(.divideByZero))
        XCTAssertEqual(blanks.eval("MIN(A1:A2)"), .number(0))
        XCTAssertEqual(blanks.eval("MAX(A1:A2)"), .number(0))
        XCTAssertEqual(blanks.eval("MEDIAN(A1:A2)"), .error(.num))
        XCTAssertEqual(blanks.eval("SUM(A1:A2)"), .number(0))
        XCTAssertEqual(blanks.eval("COUNT(A1:A2)"), .number(0))
    }

    func test_median() {
        XCTAssertEqual(oneToFour.eval("MEDIAN(A1:A4)"), .number(2.5))
        XCTAssertEqual(oneToFour.eval("MEDIAN(A1:A3)"), .number(2))
        XCTAssertEqual(none.eval("MEDIAN(5,1,3)"), .number(3))
    }

    // MARK: rounding

    func test_round_onTheDecimalForm() {
        XCTAssertEqual(none.eval("ROUND(2.675,2)"), .number(2.68))
        XCTAssertEqual(none.eval("ROUND(-2.5,0)"), .number(-3))
        XCTAssertEqual(none.eval("ROUND(1234.5,-2)"), .number(1200))
        XCTAssertEqual(none.eval("ROUND(2.5,0)"), .number(3))
        XCTAssertEqual(none.eval("ROUND(1.005,2)"), .number(1.01))
        XCTAssertEqual(none.eval("ROUND(2.675,2.9)"), .number(2.68))              // digits truncate
        XCTAssertEqual(none.eval("ROUND(\"x\",2)"), .error(.value))
    }

    func test_roundUpAndDown() {
        XCTAssertEqual(none.eval("ROUNDUP(3.141,2)"), .number(3.15))
        XCTAssertEqual(none.eval("ROUNDUP(-3.141,2)"), .number(-3.15))
        XCTAssertEqual(none.eval("ROUNDDOWN(-3.149,2)"), .number(-3.14))
        XCTAssertEqual(none.eval("ROUNDDOWN(3.149,2)"), .number(3.14))
        XCTAssertEqual(none.eval("ROUNDUP(1234.1,-2)"), .number(1300))
    }

    func test_excelRounding_edges() {
        XCTAssertEqual(ExcelRounding.round(0, digits: 2), 0)
        XCTAssertEqual(ExcelRounding.round(-0.4, digits: 0), 0)
        XCTAssertEqual(ExcelRounding.round(1e300, digits: 2), 1e300)
        XCTAssertEqual(ExcelRounding.round(123.456, digits: 400), 123.456)
        XCTAssertTrue(ExcelRounding.round(.nan, digits: 2).isNaN)
    }

    func test_abs() {
        XCTAssertEqual(none.eval("ABS(-3.5)"), .number(3.5))
        XCTAssertEqual(none.eval("ABS(\"-2\")"), .number(2))
        XCTAssertEqual(none.eval("ABS(\"x\")"), .error(.value))
    }

    // MARK: logic

    func test_if() {
        XCTAssertEqual(FormulaTestGrid(["A1": .number(150)]).eval("IF(A1>100,\"Over\",\"Under\")"), .text("Over"))
        XCTAssertEqual(FormulaTestGrid(["A1": .number(50)]).eval("IF(A1>100,\"Over\",\"Under\")"), .text("Under"))
        XCTAssertEqual(none.eval("IF(2,\"y\",\"n\")"), .text("y"))
        XCTAssertEqual(none.eval("IF(0,\"y\",\"n\")"), .text("n"))
        XCTAssertEqual(none.eval("IF(A1,\"y\",\"n\")"), .text("n"))                  // empty is false
        XCTAssertEqual(none.eval("IF(\"x\",1,2)"), .error(.value))
        XCTAssertEqual(none.eval("IF(\"TRUE\",1,2)"), .number(1))                  // R-P5-6
        XCTAssertEqual(none.eval("IF(\"true\",1,2)"), .number(1))
        XCTAssertEqual(none.eval("IF(\"False\",1,2)"), .number(2))
        XCTAssertEqual(FormulaTestGrid(["A1": .text("TRUE")]).eval("IF(A1,1,2)"), .number(1))
        XCTAssertEqual(FormulaTestGrid(["A1": .text("false")]).eval("IF(A1,1,2)"), .number(2))
        XCTAssertEqual(FormulaTestGrid(["A1": .text("yes")]).eval("IF(A1,1,2)"), .error(.value))
        XCTAssertEqual(none.eval("IF(1/0,1,2)"), .error(.divideByZero))
        XCTAssertEqual(none.eval("IF(FALSE,1)"), .bool(false))                       // missing b
        XCTAssertEqual(none.eval("IF(TRUE,,1)"), .number(0))                         // missing a
        XCTAssertEqual(none.eval("IF(FALSE,1,)"), .number(0))
        XCTAssertEqual(none.eval("IF(TRUE,1,1/0)"), .number(1))
    }

    func test_iferror() {
        XCTAssertEqual(none.eval("IFERROR(1/0,\"—\")"), .text("—"))
        XCTAssertEqual(none.eval("IFERROR(NOSUCH(1),0)"), .number(0))
        XCTAssertEqual(none.eval("IFERROR(5,\"—\")"), .number(5))
        XCTAssertEqual(FormulaTestGrid(["A1": .error(.ref)]).eval("IFERROR(A1,-1)"), .number(-1))
    }

    // MARK: conditional totals

    func test_numericCriteria() {
        XCTAssertEqual(oneToFour.eval("SUMIF(A1:A4,\">2\")"), .number(7))
        XCTAssertEqual(oneToFour.eval("SUMIF(A1:A4,3)"), .number(3))
        XCTAssertEqual(oneToFour.eval("COUNTIF(A1:A4,\"<=2\")"), .number(2))
        XCTAssertEqual(oneToFour.eval("COUNTIF(A1:A4,\">=2\")"), .number(3))
        XCTAssertEqual(oneToFour.eval("COUNTIF(A1:A4,\"<2\")"), .number(1))
        XCTAssertEqual(oneToFour.eval("COUNTIF(A1:A4,\"=4\")"), .number(1))
        XCTAssertEqual(oneToFour.eval("AVERAGEIF(A1:A4,\">1\")"), .number(3))
        // R-P5-8: a numeric `=` matches numbers, dates and number-like text; ordering
        // comparisons match only numbers and dates; `<>` matches what `=` would not.
        let g = FormulaTestGrid(column: "A", [.text("5"), .number(5), .date(5), .bool(true)])
        XCTAssertEqual(g.eval("COUNTIF(A1:A4,5)"), .number(3))
        XCTAssertEqual(g.eval("COUNTIF(A1:A4,\"=5\")"), .number(3))
        XCTAssertEqual(g.eval("COUNTIF(A1:A4,\"<>5\")"), .number(1))
        XCTAssertEqual(g.eval("COUNTIF(A1:A4,\">0\")"), .number(2))
        XCTAssertEqual(g.eval("COUNTIF(A1:A4,\">=5\")"), .number(2))
        XCTAssertEqual(g.eval("SUMIF(A1:A4,5)"), .number(10))                   // the text "5" matches but sums nothing
    }

    func test_notEqual_matchesEveryOtherCell_blanksIncluded() {
        let g = FormulaTestGrid(column: "A", [.number(5), .number(6), .empty, .text("x")])
        XCTAssertEqual(g.eval("COUNTIF(A1:A4,\"<>5\")"), .number(3))
        XCTAssertEqual(g.eval("COUNTIF(A1:A4,\"<>x\")"), .number(3))
    }

    func test_textCriteria_wildcardsAndCase() {
        let regions = FormulaTestGrid(column: "A", [.text("North"), .text("south"), .text("NE"), .text("Norway")])
        XCTAssertEqual(regions.eval("COUNTIF(A1:A4,\"n*\")"), .number(3))
        XCTAssertEqual(regions.eval("COUNTIF(A1:A4,\"?orth\")"), .number(1))
        XCTAssertEqual(regions.eval("COUNTIF(A1:A4,\"SOUTH\")"), .number(1))
        XCTAssertEqual(regions.eval("COUNTIF(A1:A4,\"<>n*\")"), .number(1))
        XCTAssertEqual(regions.eval("COUNTIF(A1:A4,\">n\")"), .number(4))          // text compare, no wildcards
        let stars = FormulaTestGrid(column: "A", [.text("*"), .text("a"), .text("**")])
        XCTAssertEqual(stars.eval("COUNTIF(A1:A3,\"~*\")"), .number(1))
        XCTAssertEqual(stars.eval("COUNTIF(A1:A3,\"*\")"), .number(3))
        XCTAssertEqual(FormulaTestGrid(column: "A", [.text("a?"), .text("ab")]).eval("COUNTIF(A1:A2,\"a~?\")"), .number(1))
        // A text pattern never matches a number cell.
        XCTAssertEqual(FormulaTestGrid(column: "A", [.number(10), .text("10x")]).eval("COUNTIF(A1:A2,\"1*\")"), .number(1))
    }

    func test_wildcardMatcher() {
        XCTAssertTrue(FormulaWildcard.matches("abcabd", pattern: "a*d"))
        XCTAssertTrue(FormulaWildcard.matches("abc", pattern: "*"))
        XCTAssertTrue(FormulaWildcard.matches("", pattern: "*"))
        XCTAssertFalse(FormulaWildcard.matches("abc", pattern: "a?"))
        XCTAssertTrue(FormulaWildcard.matches("a~b", pattern: "a~~b"))
        XCTAssertFalse(FormulaWildcard.matches("axb", pattern: "a~*b"))
    }

    func test_emptyAndNonEmptyCriteria() {
        let g = FormulaTestGrid(column: "A", [.number(1), .empty, .text("x"), .empty])
        XCTAssertEqual(g.eval("COUNTIF(A1:A4,\"\")"), .number(2))
        XCTAssertEqual(g.eval("COUNTIF(A1:A4,\"<>\")"), .number(2))
        XCTAssertEqual(g.eval("COUNTIF(A1:A4,\"=\")"), .number(2))
    }

    func test_booleanCriteria() {
        let g = FormulaTestGrid(column: "A", [.bool(true), .bool(false), .text("TRUE"), .number(1)])
        XCTAssertEqual(g.eval("COUNTIF(A1:A4,TRUE)"), .number(1))
        XCTAssertEqual(g.eval("COUNTIF(A1:A4,\"false\")"), .number(1))
    }

    func test_sumRange_takesTheCriteriaShapeFromItsTopLeft() {
        var g = FormulaTestGrid(column: "A", [.text("North"), .text("West"), .text("NORTH")])
        g.cells.merge(FormulaTestGrid(column: "B", [.number(10), .number(20), .number(30)]).cells) { a, _ in a }
        XCTAssertEqual(g.eval("SUMIF(A1:A3,\"north\",B1:B3)"), .number(40))
        // R-P5-7: the sum range is resized to the criteria range's shape from its top-left.
        XCTAssertEqual(g.eval("SUMIF(A1:A3,\"north\",B1)"), .number(40))
        XCTAssertEqual(g.eval("SUMIF(A1:A3,\"north\",B1:B2)"), .number(40))
        XCTAssertEqual(g.eval("SUMIF(A1:A3,\"north\",B3:B1)"), .number(40))
        XCTAssertEqual(g.eval("AVERAGEIF(A1:A3,\"north\",B1)"), .number(20))
        g.cells["C2"] = .number(100)
        XCTAssertEqual(g.eval("SUMIF(A1:A3,\"west\",B1:C3)"), .number(20))       // a wider sum range narrows
        XCTAssertEqual(g.eval("AVERAGEIF(A1:A3,\"north\",B1:B3)"), .number(20))
        XCTAssertEqual(g.eval("AVERAGEIF(A1:A3,\"south\",B1:B3)"), .error(.divideByZero))
        XCTAssertEqual(g.eval("SUMIF(A1:A3,\"south\",B1:B3)"), .number(0))
    }

    func test_sumRangeResize_asksTheEnvironment() {
        let base = FormulaTestGrid(column: "A", [.number(1), .number(1)]).environment
        let asked = FormulaResultBox<[Int]>([])
        let env = FormulaEnvironment(cell: base.cell, range: base.range, resized: { _, rows, columns in
            asked.set([rows, columns])
            return [[.number(7)], [.number(8)]]
        })
        let f = try! FormulaParser.parsePositional("SUMIF(A1:A2,1,Z9)").get()
        XCTAssertEqual(FormulaEvaluator.evaluate(f, in: env), .number(15))
        XCTAssertEqual(asked.get(), [2, 1])
        let refused = FormulaEnvironment(cell: base.cell, range: base.range, resized: { _, _, _ in nil })
        XCTAssertEqual(FormulaEvaluator.evaluate(f, in: refused), .error(.ref))
    }

    func test_conditionalTotals_errors() {
        let g = FormulaTestGrid(["A1": .number(1), "A2": .error(.num), "B1": .error(.ref), "B2": .number(2)])
        XCTAssertEqual(g.eval("COUNTIF(A1:A2,1)"), .number(1))                     // a criteria-range error just fails
        XCTAssertEqual(g.eval("SUMIF(A1:A2,1)"), .number(1))
        XCTAssertEqual(g.eval("SUMIF(A1:A2,1,B1:B2)"), .error(.ref))               // a matched summed error propagates
        XCTAssertEqual(g.eval("SUMIF(A1:A2,\">5\",B1:B2)"), .number(0))
        XCTAssertEqual(none.eval("COUNTIF(1,1)"), .error(.value))                   // the range must be a range
        XCTAssertEqual(none.eval("AVERAGEIF(A1:A2,\">0\")"), .error(.divideByZero))
    }
}
