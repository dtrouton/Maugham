import XCTest
@testable import Maugham

/// Regression: when an annotation's `priorText`/`suggestedText` contains inline
/// task anchors (`<!--t-XXXXXX-->`), the Mac diff card MUST strip them before
/// display. Fixed by routing both strings through `AnnotationRow.displayText`,
/// which calls `MarkdownDisplayFilter.stripTaskAnchorsInline` — the shared
/// MaughamCore stripper (matches the phone's `AnnotationDetailView.displayText`).
final class AnnotationDiffCardStripTests: XCTestCase {

    func test_displayText_stripsTaskAnchorFromPriorText() {
        let raw = "She walked quickly<!--t-abc123--> to the door."
        let stripped = AnnotationRow.displayText(raw)
        XCTAssertFalse(stripped.contains("<!--t-"),
            "task anchor must be stripped from prior text; got: \(stripped)")
        XCTAssertEqual(stripped, "She walked quickly to the door.")
    }

    func test_displayText_stripsTaskAnchorFromSuggestedText() {
        let raw = "She walked slowly<!--t-xyz789--> through the room."
        let stripped = AnnotationRow.displayText(raw)
        XCTAssertFalse(stripped.contains("<!--t-"),
            "task anchor must be stripped from suggested text; got: \(stripped)")
        XCTAssertEqual(stripped, "She walked slowly through the room.")
    }

    func test_displayText_stripsInlineAnchorWithLeadingSpace() {
        // The regex includes an optional leading space so "foo <!--t-X-->" → "foo"
        // (not "foo ") — verify the canonical collapsing behavior.
        let raw = "End of line <!--t-aaaaaa-->."
        let stripped = AnnotationRow.displayText(raw)
        XCTAssertFalse(stripped.contains("<!--t-"),
            "task anchor with leading space must be stripped cleanly; got: \(stripped)")
        XCTAssertEqual(stripped, "End of line.")
    }

    func test_displayText_noAnchor_returnsUnchanged() {
        let raw = "Clean text with no anchors at all."
        let stripped = AnnotationRow.displayText(raw)
        XCTAssertEqual(stripped, raw,
            "text without anchors must pass through unchanged; got: \(stripped)")
    }

    func test_displayText_stripsMultipleAnchors() {
        let raw = "First<!--t-aaaaaa--> and second<!--t-bbbbbb--> items."
        let stripped = AnnotationRow.displayText(raw)
        XCTAssertFalse(stripped.contains("<!--t-"),
            "all task anchors must be stripped; got: \(stripped)")
        XCTAssertEqual(stripped, "First and second items.")
    }
}
