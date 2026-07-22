import XCTest
import MaughamCore
@testable import Maugham

/// Task 12: the pure `¶id → UTF-16 range` mapping over the DERIVED translated
/// surface. Each entry carries its own rendered TEXT and `ranges` accumulates
/// offsets directly over those texts (never re-splitting a joined string), so
/// these tests pin the offsets across multi-line paragraphs, missing
/// paragraphs (rendered as their source text), the "\n\n" joins, non-BMP
/// (emoji) UTF-16 arithmetic, and a translated block that itself contains an
/// internal blank line. AppKit is not involved: this is the layer the
/// overlay's `draw` delegates to.
final class TranslationBadgeMappingTests: XCTestCase {

    private func entry(
        _ id: String, _ text: String, _ status: TranslationStatus
    ) -> TranslationBadgeLayout.Entry {
        TranslationBadgeLayout.Entry(paragraphId: id, text: text, status: status)
    }

    /// The substring the range selects out of the rendered surface (UTF-16).
    private func slice(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    /// The full rendered surface `ranges` measures against: entries' own texts
    /// joined the same way EditorHost joins them for the buffer swap.
    private func rendered(_ entries: [TranslationBadgeLayout.Entry]) -> String {
        entries.map(\.text).joined(separator: "\n\n")
    }

    func test_singleParagraph_rangeCoversWholeBlock() {
        let entries = [entry("one", "Bonjour le monde", .stale)]
        let out = TranslationBadgeLayout.ranges(entries: entries)
        let text = rendered(entries)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].paragraphId, "one")
        XCTAssertEqual(out[0].status, .stale)
        XCTAssertEqual(
            out[0].range, NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(slice(text, out[0].range), "Bonjour le monde")
    }

    func test_threeParagraphs_offsetsAcrossJoins() {
        let entries = [
            entry("p-a", "Un", .fresh),
            entry("p-b", "Deux", .stale),
            entry("p-c", "Trois", .missing),
        ]
        let out = TranslationBadgeLayout.ranges(entries: entries)
        let text = rendered(entries)
        XCTAssertEqual(out.count, 3)
        for (i, e) in entries.enumerated() {
            XCTAssertEqual(slice(text, out[i].range), e.text, "block \(i)")
        }
        // Explicit offsets: "Un"=[0,2], sep 2, "Deux"=[4,4], sep 2, "Trois"=[10,5].
        XCTAssertEqual(out[0].range, NSRange(location: 0, length: 2))
        XCTAssertEqual(out[1].range, NSRange(location: 4, length: 4))
        XCTAssertEqual(out[2].range, NSRange(location: 10, length: 5))
        XCTAssertEqual(out.map { $0.status }, [.fresh, .stale, .missing])
    }

    func test_multiLineParagraph_internalNewlineStaysOneBlock() {
        // A single paragraph with a hard line break (a lone "\n") is ONE block;
        // its range must span both lines, not split at the internal newline.
        let entries = [
            entry("m-a", "Line one\nline two", .stale),
            entry("m-b", "Second para", .fresh),
        ]
        let out = TranslationBadgeLayout.ranges(entries: entries)
        let text = rendered(entries)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(slice(text, out[0].range), "Line one\nline two")
        XCTAssertEqual(slice(text, out[1].range), "Second para")
    }

    func test_missingParagraph_blockIsSourceText() {
        // EditorHost renders a MISSING paragraph as its SOURCE text; the badge
        // range must cover that source block and carry `.missing`.
        let entries = [
            entry("s-a", "Translated first", .fresh),
            entry("s-b", "Untranslated source second", .missing),
        ]
        let out = TranslationBadgeLayout.ranges(entries: entries)
        let text = rendered(entries)
        XCTAssertEqual(out[1].status, .missing)
        XCTAssertEqual(slice(text, out[1].range), "Untranslated source second")
    }

    func test_nonBMP_emoji_utf16OffsetsAreCorrect() {
        // "😀" is a non-BMP scalar → two UTF-16 code units. Offsets after it
        // must account for the surrogate pair, or the next badge mis-places.
        let first = "😀 accueil"
        let entries = [
            entry("e-a", first, .stale),
            entry("e-b", "après", .missing),
        ]
        let out = TranslationBadgeLayout.ranges(entries: entries)
        let text = rendered(entries)
        let firstLen = (first as NSString).length   // 2 (emoji) + 8 = 10
        XCTAssertEqual(out[0].range, NSRange(location: 0, length: firstLen))
        XCTAssertEqual(slice(text, out[0].range), first)
        // The second block starts after the first block + the 2-unit separator.
        XCTAssertEqual(out[1].range.location, firstLen + 2)
        XCTAssertEqual(slice(text, out[1].range), "après")
    }

    func test_emptyEntries_returnsEmpty() {
        XCTAssertTrue(TranslationBadgeLayout.ranges(entries: []).isEmpty)
    }

    /// The failure shape the old split-based `ranges` had (documented as a
    /// "known limitation" in the first cut): a translated paragraph whose text
    /// itself contains a blank line ("\n\n") — reachable via `write_translation`,
    /// which does not block it; construct-parity only warns. Because `ranges`
    /// now accumulates each entry's OWN text length rather than re-splitting a
    /// joined string, that internal blank line is invisible to the accumulator:
    /// the entry's range spans its WHOLE text (both halves + the internal
    /// separator), and every subsequent entry's range stays correctly placed.
    func test_internalBlankLineInTranslatedBlock_doesNotDesyncLaterEntries() {
        let entries = [
            entry("b-a", "Before", .fresh),
            entry("b-b", "First half\n\nSecond half", .stale),
            entry("b-c", "After", .missing),
        ]
        let out = TranslationBadgeLayout.ranges(entries: entries)
        let text = rendered(entries)
        XCTAssertEqual(out.count, 3)
        // The middle entry's range covers its entire text, blank line included.
        XCTAssertEqual(slice(text, out[1].range), "First half\n\nSecond half")
        XCTAssertEqual(out[1].status, .stale)
        // The following entry is unaffected — no desync from the internal split.
        XCTAssertEqual(out[2].paragraphId, "b-c")
        XCTAssertEqual(slice(text, out[2].range), "After")
        XCTAssertEqual(out[2].status, .missing)
    }
}
