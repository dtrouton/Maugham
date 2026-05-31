import XCTest
@testable import MaughamPhone
import MaughamCore

/// Regression for the annotation detail's manuscript-text display.
///
/// The "Current"/"Suggested"/"Paragraph" context blocks render raw manuscript
/// paragraph bodies from the op log, which carry inline `<!--t-XXXXXX-->` task
/// anchors mid-line. Without a display strip they leak the anchor verbatim — the
/// same class of bug as the screenplay reader (anchors reaching the surface).
/// `AnnotationDetailView.displayText` strips them via the shared filter.
final class AnnotationDetailDisplayTests: XCTestCase {

    func test_displayText_stripsInlineTaskAnchor() {
        let raw = "She paused. [[todo: revisit]]<!--t-ab12cd--> Then left."
        let shown = AnnotationDetailView.displayText(raw)
        XCTAssertFalse(shown.contains("<!--t-"), "task anchor leaked: \(shown)")
        XCTAssertTrue(shown.contains("She paused."))
        XCTAssertTrue(shown.contains("Then left."))
    }

    func test_displayText_leavesCleanTextUntouched() {
        let raw = "A perfectly ordinary paragraph with no anchors."
        XCTAssertEqual(AnnotationDetailView.displayText(raw), raw)
    }
}
