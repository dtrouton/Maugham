import XCTest
import AppKit
@testable import Maugham

final class ProseModeTests: XCTestCase {
    private let mode = ProseMode()

    func test_tokenize_delegatesToMarkdownTokenizer() {
        let tokens = mode.tokenize("# Title")
        XCTAssertTrue(tokens.contains { $0.kind == .heading(level: 1) })
    }

    func test_metrics_countsWordsAndCharacters() {
        let metrics = mode.metrics("hello world this is text")
        XCTAssertEqual(metrics.wordCount, 5)
        XCTAssertEqual(metrics.characterCount, 24)
    }

    func test_metrics_emptyString() {
        let metrics = mode.metrics("")
        XCTAssertEqual(metrics.wordCount, 0)
        XCTAssertEqual(metrics.characterCount, 0)
        XCTAssertEqual(metrics.readingMinutes, 0)
    }

    func test_metrics_readingMinutes_at200WPM() {
        let words = Array(repeating: "word", count: 600).joined(separator: " ")
        let metrics = mode.metrics(words)
        // 600 / 200 wpm = 3 minutes
        XCTAssertEqual(metrics.readingMinutes, 3)
    }

    func test_smartTypographyTransform_delegatesToSmartTypography() {
        let result = mode.smartTypographyTransform(
            currentText: "ah-",
            replacementRange: NSRange(location: 3, length: 0),
            replacement: "-",
            settings: .defaults)
        XCTAssertEqual(result, "—")
    }

    func test_applyTypography_setsBackgroundAndAttributes() {
        let storage = NSTextStorage(string: "hello")
        let tokens = [Token(range: NSRange(location: 0, length: 5), kind: .plain)]
        mode.applyTypography(in: storage, theme: .light,
                             typography: .defaults, tokens: tokens)

        // After applyTypography, every char should have a font attribute.
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(attrs[.font])
        XCTAssertNotNil(attrs[.foregroundColor])
    }
}
