import SwiftUI
import XCTest
@testable import Maugham

final class DetailPaneToggleTasksTests: XCTestCase {
    func test_detailSegment_includesTasksCase() {
        XCTAssertEqual(DetailSegment.tasks.rawValue, "tasks")
    }

    func test_badgeOffsetIsDerivedNotPositional() {
        // Replaces the former allCases-ordering assertions. The badge offset
        // used to depend on inbox being third-to-last in DetailSegment.allCases;
        // it is now computed from the persona's own pane list, so enum ordering
        // is free to change. See DetailPaneTogglePersonaTests.
        XCTAssertEqual(DetailPaneToggle<AnyView>.badgeOffsetSegments(persona: .plan), 1)
    }
}
