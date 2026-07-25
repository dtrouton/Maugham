import SwiftUI
import XCTest
@testable import Maugham

final class DetailPaneToggleTasksTests: XCTestCase {
    func test_detailSegment_includesTasksCase() {
        XCTAssertEqual(DetailSegment.tasks.rawValue, "tasks")
    }

    // The former allCases-ordering assertions (the badge offset used to depend
    // on inbox being third-to-last in DetailSegment.allCases) are replaced by
    // DetailPaneTogglePersonaTests.test_badgeLandsOnTheInboxInEveryPickerThatHasOne,
    // which asserts where the badge lands rather than what the arithmetic
    // returns. Deliberately not duplicated here.
}
