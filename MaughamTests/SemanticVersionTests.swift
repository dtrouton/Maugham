import XCTest
@testable import Maugham

final class SemanticVersionTests: XCTestCase {
    func test_parseStandardVersion() {
        XCTAssertEqual(SemanticVersion("0.1.0"), SemanticVersion(major: 0, minor: 1, patch: 0))
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("12.34.56"), SemanticVersion(major: 12, minor: 34, patch: 56))
    }

    func test_parseStripsVPrefix() {
        XCTAssertEqual(SemanticVersion("v0.1.0"), SemanticVersion(major: 0, minor: 1, patch: 0))
    }

    func test_parseRejectsMalformed() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("0.1"))
        XCTAssertNil(SemanticVersion("0.1.0.4"))
        XCTAssertNil(SemanticVersion("a.b.c"))
        XCTAssertNil(SemanticVersion("0.1.0-beta"))
    }

    func test_parseDevPlaceholder() {
        XCTAssertNil(SemanticVersion("0.0.0-dev"))
    }

    func test_orderingMajor() {
        XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("1.0.0")!)
    }

    func test_orderingMinor() {
        XCTAssertLessThan(SemanticVersion("0.1.9")!, SemanticVersion("0.2.0")!)
    }

    func test_orderingPatch() {
        XCTAssertLessThan(SemanticVersion("0.1.0")!, SemanticVersion("0.1.1")!)
    }

    func test_equalityIgnoresVPrefix() {
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion("1.2.3"))
    }

    func test_stringRoundTrip() {
        XCTAssertEqual(SemanticVersion("1.2.3")?.string, "1.2.3")
    }
}
