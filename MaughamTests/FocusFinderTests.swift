import XCTest
@testable import Maugham

final class FocusFinderTests: XCTestCase {

    // MARK: - Sentences

    func test_sentenceRange_inSingleSentence_returnsWholeText() {
        let text = "Just a sentence."
        let range = FocusFinder.sentenceRange(in: text, cursor: 5)
        XCTAssertEqual(text.trimmedRange(range), "Just a sentence.")
    }

    func test_sentenceRange_picksContainingSentence() {
        let text = "First sentence. Second sentence. Third."
        // Cursor inside "Second sentence."
        let range = FocusFinder.sentenceRange(in: text, cursor: 18)
        XCTAssertEqual(text.trimmedRange(range), "Second sentence.")
    }

    func test_sentenceRange_atSentenceBoundary_picksFollowingSentence() {
        let text = "First. Second."
        // Cursor right after the period of "First."
        let range = FocusFinder.sentenceRange(in: text, cursor: 7)
        XCTAssertEqual(text.trimmedRange(range), "Second.")
    }

    func test_sentenceRange_emptyText_returnsZeroRange() {
        let range = FocusFinder.sentenceRange(in: "", cursor: 0)
        XCTAssertEqual(range, NSRange(location: 0, length: 0))
    }

    func test_sentenceRange_cursorBeyondText_clampsToLastSentence() {
        let text = "Only one."
        let range = FocusFinder.sentenceRange(in: text, cursor: 999)
        XCTAssertEqual(text.trimmedRange(range), "Only one.")
    }

    // MARK: - Paragraphs

    func test_paragraphRange_inSingleParagraph_returnsWholeText() {
        let text = "A single paragraph with several sentences. Like this."
        let range = FocusFinder.paragraphRange(in: text, cursor: 10)
        XCTAssertEqual(text.trimmedRange(range), text)
    }

    func test_paragraphRange_picksContainingParagraph() {
        let text = "First para.\n\nSecond para has\ntwo lines.\n\nThird."
        // Cursor inside "Second para has\ntwo lines."
        let range = FocusFinder.paragraphRange(in: text, cursor: 18)
        XCTAssertEqual(
            text.trimmedRange(range),
            "Second para has\ntwo lines."
        )
    }

    func test_paragraphRange_emptyText_returnsZeroRange() {
        let range = FocusFinder.paragraphRange(in: "", cursor: 0)
        XCTAssertEqual(range, NSRange(location: 0, length: 0))
    }

    func test_paragraphRange_caretAtEndOfParagraph_staysInThatParagraph() {
        // "First para." is 11 chars (indices 0...10); the caret position when
        // typing at the end of it is 11 (== NSMaxRange of the block, sitting
        // just before the blank-line separator). Regression: this used to
        // fall through to "nearest block at/after cursor" and highlight the
        // FOLLOWING paragraph.
        let text = "First para.\n\nSecond para."
        let range = FocusFinder.paragraphRange(in: text, cursor: 11)
        XCTAssertEqual(text.trimmedRange(range), "First para.")
    }

    func test_paragraphRange_caretAtEndOfMiddleParagraph_staysInThatParagraph() {
        let text = "One.\n\nTwo.\n\nThree."
        // End of "Two." — "One.\n\n" is 6 chars, "Two." adds 4 → caret at 10.
        let range = FocusFinder.paragraphRange(in: text, cursor: 10)
        XCTAssertEqual(text.trimmedRange(range), "Two.")
    }
}

private extension String {
    func trimmedRange(_ range: NSRange) -> String {
        let nsText = self as NSString
        guard NSMaxRange(range) <= nsText.length else { return "" }
        return nsText
            .substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
