import XCTest
@testable import Maugham

final class ConflictStateTests: XCTestCase {

    func test_equality_byAllFields() {
        let date = Date()
        let a = ConflictState(
            path: "manuscript/01-chapter-1.md",
            localText: "local",
            externalText: "external",
            externalModifiedAt: date)
        let b = ConflictState(
            path: "manuscript/01-chapter-1.md",
            localText: "local",
            externalText: "external",
            externalModifiedAt: date)
        XCTAssertEqual(a, b)
    }

    func test_phrasing_localAhead() {
        let s = ConflictState(
            path: "x.md",
            localText: "one two three four five",   // 5 words
            externalText: "one two",                  // 2 words
            externalModifiedAt: Date())
        XCTAssertEqual(s.localAheadByWords, 3)
        XCTAssertEqual(s.phrasing,
            "Your version (3 words ahead) and the cloud version are different.")
    }

    func test_phrasing_externalAhead() {
        let s = ConflictState(
            path: "x.md",
            localText: "one",
            externalText: "one two three four",
            externalModifiedAt: Date())
        XCTAssertEqual(s.localAheadByWords, -3)
        XCTAssertEqual(s.phrasing,
            "The cloud version (3 words ahead) and your version are different.")
    }

    func test_phrasing_equalCounts() {
        let s = ConflictState(
            path: "x.md",
            localText: "one two",
            externalText: "tea coffee",
            externalModifiedAt: Date())
        XCTAssertEqual(s.localAheadByWords, 0)
        XCTAssertEqual(s.phrasing,
            "Your version and the cloud version are different.")
    }
}
