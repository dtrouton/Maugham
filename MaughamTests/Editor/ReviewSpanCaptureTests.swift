// MaughamTests/Editor/ReviewSpanCaptureTests.swift
import XCTest
import MaughamCore
@testable import Maugham

/// Task 3c: the pure paragraph-relative span-capture arithmetic.
final class ReviewSpanCaptureTests: XCTestCase {

    // MARK: paragraphRelativeRange

    func test_relative_selectionInsideParagraph() {
        // paragraph occupies [10, 30); selection [15, 20) in display coords.
        let r = ReviewSpanCapture.paragraphRelativeRange(
            absolute: 15..<20, paragraph: 10..<30)
        XCTAssertEqual(r, 5..<10)
    }

    func test_relative_selectionAtParagraphStart() {
        let r = ReviewSpanCapture.paragraphRelativeRange(
            absolute: 10..<14, paragraph: 10..<30)
        XCTAssertEqual(r, 0..<4)
    }

    func test_relative_selectionStraddlesEnd_clampsToParagraph() {
        // Selection runs from inside the paragraph past its end into the
        // separator / next paragraph — clamp to the paragraph end.
        let r = ReviewSpanCapture.paragraphRelativeRange(
            absolute: 25..<40, paragraph: 10..<30)
        XCTAssertEqual(r, 15..<20)
    }

    func test_relative_emptySelection_returnsNil() {
        XCTAssertNil(ReviewSpanCapture.paragraphRelativeRange(
            absolute: 12..<12, paragraph: 10..<30))
    }

    func test_relative_noOverlap_returnsNil() {
        XCTAssertNil(ReviewSpanCapture.paragraphRelativeRange(
            absolute: 35..<40, paragraph: 10..<30))
    }

    func test_relative_selectionBeforeParagraph_returnsNil() {
        XCTAssertNil(ReviewSpanCapture.paragraphRelativeRange(
            absolute: 0..<5, paragraph: 10..<30))
    }

    // MARK: captureSpan (UTF-16 → grapheme → SpanAnchor)

    func test_capture_asciiWord() {
        let para = "She was angry and shaking with fury."
        // "angry" is at grapheme/UTF-16 offset 8..<13 (all ASCII).
        let span = ReviewSpanCapture.captureSpan(in: para, relativeUTF16: 8..<13)
        XCTAssertEqual(span?.quote, "angry")
    }

    func test_capture_afterEmojiOffsetsBySurrogatePair() {
        // 🎉 is 1 grapheme but 2 UTF-16 code units. After it, "go" starts at
        // UTF-16 offset 3 but grapheme offset 2.
        let para = "🎉 go now"
        // UTF-16: 🎉(0,1) space(2) g(3) o(4) ...
        let span = ReviewSpanCapture.captureSpan(in: para, relativeUTF16: 3..<5)
        XCTAssertEqual(span?.quote, "go")
    }

    func test_capture_emptyRange_returnsNil() {
        XCTAssertNil(ReviewSpanCapture.captureSpan(
            in: "hello", relativeUTF16: 2..<2))
    }

    func test_capture_outOfBounds_returnsNil() {
        XCTAssertNil(ReviewSpanCapture.captureSpan(
            in: "hi", relativeUTF16: 1..<99))
    }

    func test_capture_resolvesBackToSameRange() {
        // Round-trip: capture then resolve should land on the same text.
        let para = "The quick brown fox jumps."
        let span = ReviewSpanCapture.captureSpan(in: para, relativeUTF16: 4..<9)!
        XCTAssertEqual(span.quote, "quick")
        let resolved = SpanAnchorResolver.resolve(anchor: span, in: para)
        XCTAssertNotNil(resolved)
        let arr = Array(para)
        XCTAssertEqual(String(arr[resolved!]), "quick")
    }
}
