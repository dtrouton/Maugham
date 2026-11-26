import XCTest
@testable import MaughamCore
@testable import Maugham

/// **A place on the translated surface → its paragraph** (moved from the
/// translation review pane's `selectedEntry` tests, shell p4 Task 9: the pane
/// is gone and its wrapper with it; the mapping it wrapped is what the
/// reading surface, its selection toolbar and To resolve's caret use —
/// `TranslationBadgeLayout.index(at:in:)` over `ranges(entries:)`). The
/// translated render's offsets, never the source `displayText`'s.
final class TranslationBadgeIndexTests: XCTestCase {

    private func entry(_ id: String, _ text: String,
                       _ status: TranslationStatus = .fresh) -> TranslationBadgeLayout.Entry {
        TranslationBadgeLayout.Entry(paragraphId: id, text: text, status: status)
    }

    private func paragraph(at location: Int, in entries: [TranslationBadgeLayout.Entry]) -> TranslationBadgeLayout.Entry? {
        let ranges = TranslationBadgeLayout.ranges(entries: entries)
        return TranslationBadgeLayout.index(at: location, in: ranges).map { entries[$0] }
    }

    func test_noEntriesIsNoParagraph() {
        XCTAssertNil(paragraph(at: 0, in: []))
    }

    func test_insideTheFirstAndSecondBlocks() {
        let entries = [entry("a", "Bonjour"), entry("b", "Le monde")]
        XCTAssertEqual(paragraph(at: 3, in: entries)?.paragraphId, "a")
        // "Bonjour"=7, "\n\n"=2, so "Le monde" starts at 9.
        XCTAssertEqual(paragraph(at: 11, in: entries)?.paragraphId, "b")
    }

    func test_aBlocksEndAndTheGapAfterItBelongToIt() {
        let entries = [entry("a", "Bonjour"), entry("b", "Le monde")]
        XCTAssertEqual(paragraph(at: 7, in: entries)?.paragraphId, "a", "the end boundary")
        XCTAssertEqual(paragraph(at: 8, in: entries)?.paragraphId, "a", "inside the separator")
    }

    func test_outOfRangeClamps() {
        let entries = [entry("a", "Bonjour"), entry("b", "Le monde")]
        XCTAssertEqual(paragraph(at: 9_999, in: entries)?.paragraphId, "b")
        XCTAssertEqual(paragraph(at: -5, in: entries)?.paragraphId, "a")
    }

    func test_theEntryCarriesItsStatus() {
        let entries = [entry("a", "Bonjour", .stale), entry("b", "Le monde", .missing)]
        XCTAssertEqual(paragraph(at: 11, in: entries)?.status, .missing)
    }

    /// A block with an internal blank line stays one entry; the next block's
    /// offset does not shift.
    func test_aMultiLineBlockDoesNotDesyncTheNext() {
        let entries = [entry("a", "Line one\n\nLine two"), entry("b", "Suivant")]
        XCTAssertEqual(paragraph(at: 22, in: entries)?.paragraphId, "b")
    }
}
