import XCTest
@testable import Maugham

final class SceneNavigatorCompactFormatTests: XCTestCase {

    func test_compact_zero_isEmpty() {
        XCTAssertEqual(SceneNavigatorPane.formatPagesCompact(0), "")
    }

    func test_compact_tiny_belowQuarter() {
        XCTAssertEqual(SceneNavigatorPane.formatPagesCompact(0.05), "<¼")
    }

    func test_compact_quarter() {
        XCTAssertEqual(SceneNavigatorPane.formatPagesCompact(0.25), "¼")
    }

    func test_compact_half() {
        XCTAssertEqual(SceneNavigatorPane.formatPagesCompact(0.5), "½")
    }

    func test_compact_threeQuarters() {
        XCTAssertEqual(SceneNavigatorPane.formatPagesCompact(0.75), "¾")
    }

    func test_compact_one() {
        XCTAssertEqual(SceneNavigatorPane.formatPagesCompact(1.0), "1")
    }

    func test_compact_oneAndAHalf() {
        XCTAssertEqual(SceneNavigatorPane.formatPagesCompact(1.5), "1½")
    }

    func test_compact_two() {
        XCTAssertEqual(SceneNavigatorPane.formatPagesCompact(2.0), "2")
    }
}
