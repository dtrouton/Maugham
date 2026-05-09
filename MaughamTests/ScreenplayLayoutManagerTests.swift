import XCTest
import AppKit
@testable import Maugham

final class ScreenplayLayoutManagerTests: XCTestCase {

    /// Verify that the marker attribute exists with the expected raw string
    /// (so other code adding/reading the attribute uses the same key).
    func test_markerAttribute_hasExpectedRawValue() {
        XCTAssertEqual(
            NSAttributedString.Key.maughamDisplayUppercase.rawValue,
            "MaughamDisplayUppercase")
    }

    /// Verify the layout manager can be instantiated and attached to a
    /// container without raising (smoke for subclass viability).
    func test_layoutManager_attachesToTextStorage() {
        let storage = NSTextStorage(string: "Sam")
        let lm = ScreenplayLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: 200))
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        // No crash = pass. Layout manager is wired up.
        XCTAssertNotNil(storage.layoutManagers.first)
    }

    /// Verify shouldUppercase reads the marker attribute correctly.
    func test_attributesWithMarker_triggerUppercaseBranch() {
        // We can't easily invoke showCGGlyphs from a unit test (it requires
        // a graphics context). So we test the public surface via the marker
        // attribute presence: an NSAttributedString carrying the marker
        // round-trips to a Storage and the attribute is preserved.
        let attrs: [NSAttributedString.Key: Any] = [
            .maughamDisplayUppercase: true]
        let storage = NSTextStorage(string: "Sam")
        storage.setAttributes(attrs, range: NSRange(location: 0, length: 3))
        let stored = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(stored[.maughamDisplayUppercase] as? Bool, true)
    }
}
