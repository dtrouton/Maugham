import XCTest
@testable import Maugham

final class SearchTypesTests: XCTestCase {
    func test_SearchMatch_isIdentifiable() {
        let m = SearchMatch(
            id: UUID(),
            documentPath: "manuscript/foo.md",
            documentTitle: "Foo",
            documentSource: .manuscript,
            lineNumber: 1,
            charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "foo bar",
            matchRangeInLine: NSRange(location: 0, length: 3))
        XCTAssertEqual(m.documentSource, .manuscript)
    }

    func test_SearchResults_countsMatchesAndDocuments() {
        let m1 = SearchMatch(
            id: UUID(), documentPath: "a.md", documentTitle: "A",
            documentSource: .manuscript, lineNumber: 1,
            charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "foo", matchRangeInLine: NSRange(location: 0, length: 3))
        let m2 = SearchMatch(
            id: UUID(), documentPath: "a.md", documentTitle: "A",
            documentSource: .manuscript, lineNumber: 2,
            charRangeInDocument: NSRange(location: 10, length: 3),
            linePreview: "foo", matchRangeInLine: NSRange(location: 0, length: 3))
        let m3 = SearchMatch(
            id: UUID(), documentPath: "b.md", documentTitle: "B",
            documentSource: .research, lineNumber: 1,
            charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "foo", matchRangeInLine: NSRange(location: 0, length: 3))
        let r = SearchResults(
            query: "foo", options: SearchOptions(), matches: [m1, m2, m3])
        XCTAssertEqual(r.matchCount, 3)
        XCTAssertEqual(r.documentCount, 2)
    }

    func test_SearchOptions_defaultsCaseInsensitiveNoWholeWord() {
        let o = SearchOptions()
        XCTAssertFalse(o.caseSensitive)
        XCTAssertFalse(o.wholeWord)
    }
}
