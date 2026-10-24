import XCTest
@testable import MaughamCore

final class CellAddressTests: XCTestCase {
    func test_columnLetters_andTheirInverses() {
        let pairs: [(Int, String)] = [(0, "A"), (25, "Z"), (26, "AA"), (701, "ZZ"), (702, "AAA")]
        for (index, letters) in pairs {
            XCTAssertEqual(A1.columnLetters(index), letters)
            XCTAssertEqual(A1.columnIndex(letters), index)
            XCTAssertEqual(A1.columnIndex(letters.lowercased()), index)
        }
        XCTAssertNil(A1.columnIndex(""))
        XCTAssertNil(A1.columnIndex("A1"))
    }

    func test_parse_absoluteAndCaseInsensitive() {
        let abs = A1.parse("$B$2")
        XCTAssertEqual(abs?.row, 1); XCTAssertEqual(abs?.column, 1)
        XCTAssertEqual(abs?.rowAbsolute, true); XCTAssertEqual(abs?.columnAbsolute, true)
        let rel = A1.parse("b2")
        XCTAssertEqual(rel?.row, 1); XCTAssertEqual(rel?.column, 1)
        XCTAssertEqual(rel?.rowAbsolute, false); XCTAssertEqual(rel?.columnAbsolute, false)
        let mixed = A1.parse("C$10")
        XCTAssertEqual(mixed?.row, 9); XCTAssertEqual(mixed?.column, 2)
        XCTAssertEqual(mixed?.rowAbsolute, true); XCTAssertEqual(mixed?.columnAbsolute, false)
    }

    func test_parse_rejectsNonAddresses() {
        XCTAssertNil(A1.parse("A0"))
        XCTAssertNil(A1.parse("2B"))
        XCTAssertNil(A1.parse("B"))
        XCTAssertNil(A1.parse("B2 "))
        XCTAssertNil(A1.parse(""))
    }
}
