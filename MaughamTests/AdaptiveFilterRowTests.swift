import XCTest
@testable import Maugham

final class AdaptiveFilterRowTests: XCTestCase {

    func test_shouldShowIcons_returnsTrue_whenNaturalExceedsAvailable() {
        // Natural width 400 cannot fit in 200 → must show icons.
        XCTAssertTrue(AdaptiveFilterRowFit.shouldShowIcons(
            naturalLabelWidth: 400, availableWidth: 200))
    }

    func test_shouldShowIcons_returnsFalse_whenNaturalFitsAvailable() {
        // Natural width 180 fits in 200 → full labels.
        XCTAssertFalse(AdaptiveFilterRowFit.shouldShowIcons(
            naturalLabelWidth: 180, availableWidth: 200))
    }

    func test_shouldShowIcons_returnsFalse_atExactFit() {
        // Equal widths fit (no truncation, no hyphenation).
        XCTAssertFalse(AdaptiveFilterRowFit.shouldShowIcons(
            naturalLabelWidth: 200, availableWidth: 200))
    }

    func test_shouldShowIcons_returnsFalse_whenAvailableIsZero() {
        // Defensive: if SwiftUI hasn't measured yet (available == 0),
        // do not flip into icon mode. Default to labels until measured.
        XCTAssertFalse(AdaptiveFilterRowFit.shouldShowIcons(
            naturalLabelWidth: 200, availableWidth: 0))
    }
}
