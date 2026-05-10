import XCTest
@testable import Maugham

final class InlineEmphasisTests: XCTestCase {
    private let parser = FountainTokenizer()

    func test_italicSpan_detected() {
        let script = parser.parse("Action with *italic* text.")
        let line = script.lines[0]
        let italic = line.inlineSpans.filter { $0.kind == .italic }
        XCTAssertEqual(italic.count, 1)
        XCTAssertEqual(italic[0].range.length, 8)
    }

    func test_boldSpan_detected() {
        let script = parser.parse("Action with **bold** text.")
        let line = script.lines[0]
        let bold = line.inlineSpans.filter { $0.kind == .bold }
        XCTAssertEqual(bold.count, 1)
        XCTAssertEqual(bold[0].range.length, 8)
    }

    func test_boldNotMistakenForItalic() {
        let script = parser.parse("**bold**")
        let line = script.lines[0]
        let bold = line.inlineSpans.filter { $0.kind == .bold }
        let italic = line.inlineSpans.filter { $0.kind == .italic }
        XCTAssertEqual(bold.count, 1)
        XCTAssertEqual(italic.count, 0)
    }

    func test_underlineSpan_detected() {
        let script = parser.parse("Action with _underline_ text.")
        let line = script.lines[0]
        let underline = line.inlineSpans.filter { $0.kind == .underline }
        XCTAssertEqual(underline.count, 1)
    }

    func test_compositionItalicWithBold_bothDetected() {
        let script = parser.parse("*foo **bar** baz*")
        let line = script.lines[0]
        let italic = line.inlineSpans.filter { $0.kind == .italic }
        let bold = line.inlineSpans.filter { $0.kind == .bold }
        XCTAssertEqual(italic.count, 1)
        XCTAssertEqual(bold.count, 1)
        XCTAssertEqual(italic[0].range.length, 17)
        XCTAssertEqual(bold[0].range.length, 7)
    }

    func test_unclosedItalic_noSpan() {
        let script = parser.parse("Action with *foo continuing")
        let line = script.lines[0]
        let italic = line.inlineSpans.filter { $0.kind == .italic }
        XCTAssertEqual(italic.count, 0)
    }

    func test_crossLineEmphasis_noSpan() {
        let script = parser.parse("Action *foo\nbar* continues.")
        let line0Italic = script.lines[0].inlineSpans.filter { $0.kind == .italic }
        XCTAssertEqual(line0Italic.count, 0)
    }

    func test_emptyEmphasis_noSpan() {
        let script = parser.parse("Action ** here")
        let line = script.lines[0]
        let bold = line.inlineSpans.filter { $0.kind == .bold }
        XCTAssertEqual(bold.count, 0)
    }
}
