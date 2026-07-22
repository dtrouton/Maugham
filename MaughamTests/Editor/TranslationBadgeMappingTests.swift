import XCTest
import MaughamCore
@testable import Maugham

/// Task 12: the pure `¶id → UTF-16 range` mapping over the DERIVED translated
/// surface. The surface is the entries-order blocks joined with `"\n\n"`, so a
/// badge's range must be measured against that rendered text — these tests pin
/// the offsets across multi-line paragraphs, missing paragraphs (rendered as
/// their source text), the "\n\n" joins, and non-BMP (emoji) UTF-16 arithmetic.
/// AppKit is not involved: this is the layer the overlay's `draw` delegates to.
final class TranslationBadgeMappingTests: XCTestCase {

    private func entry(
        _ id: String, _ status: TranslationStatus
    ) -> TranslationBadgeLayout.Entry {
        TranslationBadgeLayout.Entry(paragraphId: id, status: status)
    }

    /// The substring the range selects out of the rendered surface (UTF-16).
    private func slice(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    func test_singleParagraph_rangeCoversWholeBlock() {
        let text = "Bonjour le monde"
        let out = TranslationBadgeLayout.ranges(
            entries: [entry("one", .stale)], renderedText: text)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].paragraphId, "one")
        XCTAssertEqual(out[0].status, .stale)
        XCTAssertEqual(
            out[0].range, NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(slice(text, out[0].range), "Bonjour le monde")
    }

    func test_threeParagraphs_offsetsAcrossJoins() {
        let blocks = ["Un", "Deux", "Trois"]
        let text = blocks.joined(separator: "\n\n")
        let out = TranslationBadgeLayout.ranges(
            entries: [entry("p-a", .fresh), entry("p-b", .stale), entry("p-c", .missing)],
            renderedText: text)
        XCTAssertEqual(out.count, 3)
        for (i, block) in blocks.enumerated() {
            XCTAssertEqual(slice(text, out[i].range), block, "block \(i)")
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
        let blocks = ["Line one\nline two", "Second para"]
        let text = blocks.joined(separator: "\n\n")
        let out = TranslationBadgeLayout.ranges(
            entries: [entry("m-a", .stale), entry("m-b", .fresh)], renderedText: text)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(slice(text, out[0].range), "Line one\nline two")
        XCTAssertEqual(slice(text, out[1].range), "Second para")
    }

    func test_missingParagraph_blockIsSourceText() {
        // EditorHost renders a MISSING paragraph as its SOURCE text; the badge
        // range must cover that source block and carry `.missing`.
        let blocks = ["Translated first", "Untranslated source second"]
        let text = blocks.joined(separator: "\n\n")
        let out = TranslationBadgeLayout.ranges(
            entries: [entry("s-a", .fresh), entry("s-b", .missing)], renderedText: text)
        XCTAssertEqual(out[1].status, .missing)
        XCTAssertEqual(slice(text, out[1].range), "Untranslated source second")
    }

    func test_nonBMP_emoji_utf16OffsetsAreCorrect() {
        // "😀" is a non-BMP scalar → two UTF-16 code units. Offsets after it
        // must account for the surrogate pair, or the next badge mis-places.
        let first = "😀 accueil"
        let blocks = [first, "après"]
        let text = blocks.joined(separator: "\n\n")
        let out = TranslationBadgeLayout.ranges(
            entries: [entry("e-a", .stale), entry("e-b", .missing)], renderedText: text)
        let firstLen = (first as NSString).length   // 2 (emoji) + 8 = 10
        XCTAssertEqual(out[0].range, NSRange(location: 0, length: firstLen))
        XCTAssertEqual(slice(text, out[0].range), first)
        // The second block starts after the first block + the 2-unit separator.
        XCTAssertEqual(out[1].range.location, firstLen + 2)
        XCTAssertEqual(slice(text, out[1].range), "après")
    }

    func test_emptyEntries_returnsEmpty() {
        XCTAssertTrue(
            TranslationBadgeLayout.ranges(entries: [], renderedText: "anything").isEmpty)
    }

    func test_fewerEntriesThanBlocks_pairsPrefixOnly() {
        // A torn push (more rendered blocks than status entries) emits badges
        // only for the entries it has — never a mis-indexed extra.
        let text = ["A", "B", "C"].joined(separator: "\n\n")
        let out = TranslationBadgeLayout.ranges(
            entries: [entry("t-a", .stale)], renderedText: text)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(slice(text, out[0].range), "A")
    }

    func test_fewerBlocksThanEntries_pairsPrefixOnly() {
        let text = "OnlyOne"
        let out = TranslationBadgeLayout.ranges(
            entries: [entry("u-a", .stale), entry("u-b", .missing)], renderedText: text)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].paragraphId, "u-a")
        XCTAssertEqual(slice(text, out[0].range), "OnlyOne")
    }
}
