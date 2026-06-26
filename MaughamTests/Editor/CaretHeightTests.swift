import XCTest
import AppKit
@testable import Maugham

/// The insertion point on an empty line otherwise renders at the full line-
/// fragment height (glyph + the body paragraph style's ~12pt `lineSpacing`),
/// standing taller than the text and visibly "shrinking" the moment a glyph is
/// typed. `MaughamTextView` clamps the caret to the glyph line height.
@MainActor
final class CaretHeightTests: XCTestCase {

    func test_clampShrinksTallEmptyLineCaretToLineHeight() {
        let tall = NSRect(x: 5, y: 10, width: 1, height: 34)
        let clamped = MaughamTextView.clampedCaretRect(tall, toLineHeight: 22)
        XCTAssertEqual(clamped.height, 22, accuracy: 0.01,
            "tall empty-line caret must clamp to the glyph line height")
        // Top-aligned: origin (where the glyph sits) is preserved.
        XCTAssertEqual(clamped.origin.y, 10, accuracy: 0.01)
        XCTAssertEqual(clamped.origin.x, 5, accuracy: 0.01)
    }

    func test_clampLeavesGlyphHeightCaretUntouched() {
        // A populated-line caret is already at glyph height — must not change.
        let normal = NSRect(x: 5, y: 10, width: 1, height: 22)
        XCTAssertEqual(
            MaughamTextView.clampedCaretRect(normal, toLineHeight: 22), normal)
    }

    func test_clampIsShrinkOnlyNeverGrows() {
        // A caret shorter than the line height stays as-is (no growth → no
        // invalidation artifacts).
        let short = NSRect(x: 0, y: 0, width: 1, height: 10)
        XCTAssertEqual(
            MaughamTextView.clampedCaretRect(short, toLineHeight: 22), short)
    }

    func test_lineHeightIsGlyphSizedNotInflated() {
        let font = NSFont(name: "Iowan Old Style", size: 17)
            ?? NSFont.systemFont(ofSize: 17)
        let h = MaughamTextView.caretLineHeight(for: font)
        // On the order of the font size, NOT the ~34pt inflated empty-line box.
        XCTAssertGreaterThan(h, CGFloat(17))
        XCTAssertLessThan(h, CGFloat(30))
    }
}
