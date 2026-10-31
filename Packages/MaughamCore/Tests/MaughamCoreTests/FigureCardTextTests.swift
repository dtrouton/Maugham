import XCTest
@testable import MaughamCore

final class FigureCardTextTests: XCTestCase {
    func test_wordsAreTheOnesTheMacDrew() {
        XCTAssertEqual(FigureCardText.removed, "Figure removed")
        XCTAssertEqual(FigureCardText.ambiguous, "Two figures share this path")
        XCTAssertEqual(FigureCardText.parked, "In Research")
        XCTAssertEqual(FigureCardText.empty, "Empty table")
        XCTAssertEqual(FigureCardText.pinChanged, "Research has changed")
    }

    /// A registered figure whose files have not reached this device yet: a
    /// neutral state, never "Figure removed" (report plan 9b Task 5).
    func test_notReadyIsNeitherRemovedNorData() {
        XCTAssertEqual(FigureCardText.notReady, "Not downloaded yet")
        XCTAssertNotEqual(FigureCardText.notReady, FigureCardText.removed)
    }

    func test_moreRows() {
        XCTAssertEqual(FigureCardText.more(1), "+ 1 more row")
        XCTAssertEqual(FigureCardText.more(2), "+ 2 more rows")
        XCTAssertEqual(FigureCardText.more(3), "+ 3 more rows")
    }
}
