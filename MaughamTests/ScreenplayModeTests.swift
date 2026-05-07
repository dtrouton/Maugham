import XCTest
import AppKit
@testable import Maugham

final class ScreenplayModeTests: XCTestCase {
    private let mode = ScreenplayMode()

    func test_tokenize_emptyText_returnsEmpty() {
        XCTAssertEqual(mode.tokenize(""), [])
    }

    func test_tokenize_returnsSinglePlainToken() {
        let text = "FADE IN:\n\nINT. ROOM - DAY\n\nLarry sits."
        let tokens = mode.tokenize(text)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .plain)
        XCTAssertEqual(tokens[0].range.length, (text as NSString).length)
    }

    func test_smartTypographyTransform_alwaysReturnsNil() {
        XCTAssertNil(mode.smartTypographyTransform(
            currentText: "ah-",
            replacementRange: NSRange(location: 3, length: 0),
            replacement: "-",
            settings: .defaults))
    }

    func test_metrics_countsWordsLikeProse() {
        let metrics = mode.metrics("hello world this is text")
        XCTAssertEqual(metrics.wordCount, 5)
        XCTAssertEqual(metrics.characterCount, 24)
    }

    func test_applyTypography_setsMonospaceFont() {
        let storage = NSTextStorage(string: "FADE IN:")
        let tokens = [Token(range: NSRange(location: 0, length: 8), kind: .plain)]
        mode.applyTypography(in: storage, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens)
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(attrs[.font])
        XCTAssertNotNil(attrs[.foregroundColor])
    }
}
