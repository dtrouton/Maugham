import XCTest
@testable import Maugham

final class DetailPaneToggleTasksTests: XCTestCase {
    func test_detailSegment_includesTasksCase() {
        XCTAssertEqual(DetailSegment.tasks.rawValue, "tasks")
    }
}
