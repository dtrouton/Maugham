import XCTest
@testable import Maugham

final class DetailPaneToggleTasksTests: XCTestCase {
    func test_detailSegment_includesTasksCase() {
        XCTAssertEqual(DetailSegment.tasks.rawValue, "tasks")
    }

    /// The inbox unread badge is positioned by shifting a top-trailing overlay
    /// left by exactly TWO segment widths (DetailPaneToggle.segmentPicker), which
    /// assumes inbox is the THIRD-to-last right-pane segment (palette, ⌘⌥7, and
    /// translation, ⌘⌥8, follow it). Adding a segment after palette silently
    /// moved the badge onto the wrong tab once already (palette was appended
    /// after inbox). If this fails, update the badge offset in DetailPaneToggle
    /// to match the new tab order.
    func test_inboxIsThirdToLastSegment_soUnreadBadgeLandsOnIt() {
        let order = DetailSegment.allCases
        XCTAssertEqual(order.last, .translation, "translation must remain the last right-pane segment")
        XCTAssertEqual(order[order.count - 2], .palette, "palette must remain second-to-last")
        XCTAssertEqual(order[order.count - 3], .inbox, "inbox must remain third-to-last so the badge offset lands on it")
    }
}
