import XCTest
@testable import Maugham

final class DetailPaneToggleTasksTests: XCTestCase {
    func test_detailSegment_includesTasksCase() {
        XCTAssertEqual(DetailSegment.tasks.rawValue, "tasks")
    }

    /// The inbox unread badge is positioned by shifting a top-trailing overlay
    /// left by exactly one segment width (DetailPaneToggle.segmentPicker), which
    /// assumes inbox is the SECOND-to-last right-pane segment and palette is last.
    /// Adding a segment after palette silently moved the badge onto the wrong tab
    /// once already (palette was appended after inbox). If this fails, update the
    /// badge offset in DetailPaneToggle to match the new tab order.
    func test_inboxIsSecondToLastSegment_soUnreadBadgeLandsOnIt() {
        let order = DetailSegment.allCases
        XCTAssertEqual(order.last, .palette, "palette must remain the last right-pane segment")
        XCTAssertEqual(order[order.count - 2], .inbox, "inbox must remain second-to-last so the badge offset lands on it")
    }
}
