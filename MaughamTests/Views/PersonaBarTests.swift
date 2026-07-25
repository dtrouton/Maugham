import XCTest
@testable import Maugham

final class PersonaBarTests: XCTestCase {
    func test_isHidden_inNoChromeFocusMode() {
        // Must #2, get out of the way: the bar is permanent chrome and has to
        // disappear with the titlebar under ⌘\. Nothing in this codebase hides
        // automatically — every SwiftUI view that vanishes in focus mode
        // checks isNoChromeOn explicitly.
        XCTAssertFalse(PersonaBar.isVisible(isNoChromeOn: true))
    }

    func test_isVisible_normally() {
        XCTAssertTrue(PersonaBar.isVisible(isNoChromeOn: false))
    }

    func test_accessibilityLabel_namesThePersonaAndItsKey() {
        XCTAssertEqual(PersonaBar.accessibilityLabel(for: .plan), "Plan mode, Command 1")
        XCTAssertEqual(PersonaBar.accessibilityLabel(for: .publish), "Publish mode, Command 4")
    }
}
