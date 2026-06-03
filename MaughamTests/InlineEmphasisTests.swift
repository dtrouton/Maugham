import XCTest
import MaughamCore
@testable import Maugham

final class InlineEmphasisTests: XCTestCase {
    private let parser = FountainTokenizer()

    /// Substring of `source` covered by a span (document-relative range).
    private func sub(_ span: FountainInlineSpan, in source: String) -> String {
        (source as NSString).substring(with: span.range)
    }

    func test_italicSpan_detected() {
        let source = "Action with *italic* text."
        let line = parser.parse(source).lines[0]
        // Content span (markers excluded) carrying italic only.
        let emphasis = line.inlineSpans.filter {
            if case .emphasis(let t) = $0.kind { return t == [.italic] }
            return false
        }
        XCTAssertEqual(emphasis.count, 1)
        XCTAssertEqual(sub(emphasis[0], in: source), "italic")
        // Two single-asterisk markers.
        let markers = line.inlineSpans.filter { $0.kind == .emphasisMarker }
        XCTAssertEqual(markers.count, 2)
        XCTAssertTrue(markers.allSatisfy { sub($0, in: source) == "*" })
    }

    func test_boldSpan_detected() {
        let source = "Action with **bold** text."
        let line = parser.parse(source).lines[0]
        let emphasis = line.inlineSpans.filter {
            if case .emphasis(let t) = $0.kind { return t == [.bold] }
            return false
        }
        XCTAssertEqual(emphasis.count, 1)
        XCTAssertEqual(sub(emphasis[0], in: source), "bold")
        let markers = line.inlineSpans.filter { $0.kind == .emphasisMarker }
        XCTAssertEqual(markers.count, 2)
        XCTAssertTrue(markers.allSatisfy { sub($0, in: source) == "**" })
    }

    func test_boldNotMistakenForItalic() {
        let line = parser.parse("**bold**").lines[0]
        let bold = line.inlineSpans.filter {
            if case .emphasis(let t) = $0.kind { return t == [.bold] }
            return false
        }
        let italicOnly = line.inlineSpans.filter {
            if case .emphasis(let t) = $0.kind { return t == [.italic] }
            return false
        }
        XCTAssertEqual(bold.count, 1)
        XCTAssertEqual(italicOnly.count, 0)
    }

    func test_underlineSpan_detected() {
        let line = parser.parse("Action with _underline_ text.").lines[0]
        let underline = line.inlineSpans.filter { $0.kind == .underline }
        XCTAssertEqual(underline.count, 1)
    }

    func test_compositionItalicWithBold_bothDetected() {
        // `*foo **bar** baz*`: italic wraps the whole interior; `bar` is
        // additionally bold. The scanner flattens this into three italic
        // content runs, one of which (`bar`) also carries bold.
        let source = "*foo **bar** baz*"
        let line = parser.parse(source).lines[0]
        let both = line.inlineSpans.filter {
            if case .emphasis(let t) = $0.kind { return t == [.bold, .italic] }
            return false
        }
        XCTAssertEqual(both.count, 1)
        XCTAssertEqual(sub(both[0], in: source), "bar")
        // The surrounding text is italic-only.
        let italicOnly = line.inlineSpans.filter {
            if case .emphasis(let t) = $0.kind { return t == [.italic] }
            return false
        }
        XCTAssertEqual(italicOnly.map { sub($0, in: source) }, ["foo ", " baz"])
    }

    func test_unclosedItalic_noSpan() {
        let line = parser.parse("Action with *foo continuing").lines[0]
        let emphasis = line.inlineSpans.filter {
            if case .emphasis = $0.kind { return true }
            return false
        }
        XCTAssertEqual(emphasis.count, 0)
    }

    func test_crossLineEmphasis_noSpan() {
        let line0 = parser.parse("Action *foo\nbar* continues.").lines[0]
        let emphasis = line0.inlineSpans.filter {
            if case .emphasis = $0.kind { return true }
            return false
        }
        XCTAssertEqual(emphasis.count, 0)
    }

    func test_emptyEmphasis_noSpan() {
        let line = parser.parse("Action ** here").lines[0]
        let emphasis = line.inlineSpans.filter {
            if case .emphasis = $0.kind { return true }
            return false
        }
        XCTAssertEqual(emphasis.count, 0)
    }

    // MARK: - New: combinable + nested emphasis via the shared scanner.

    func test_tripleAsterisk_isBoldItalicContentSpan() {
        // `***word***` in an action line → exactly one bold+italic content span
        // whose substring is `word` (markers excluded).
        let source = "***word***"
        let line = parser.parse(source).lines[0]
        let both = line.inlineSpans.filter {
            if case .emphasis(let t) = $0.kind { return t == [.bold, .italic] }
            return false
        }
        XCTAssertEqual(both.count, 1)
        XCTAssertEqual(sub(both[0], in: source), "word")
    }

    func test_nestedBoldInsideItalic_innerSpanIsBoldItalic() {
        // `*a **b** a*`: the span covering `b` carries both italic and bold.
        let source = "*a **b** a*"
        let line = parser.parse(source).lines[0]
        let inner = line.inlineSpans.first { span in
            if case .emphasis = span.kind { return sub(span, in: source) == "b" }
            return false
        }
        XCTAssertNotNil(inner)
        if case .emphasis(let t)? = inner?.kind {
            XCTAssertEqual(t, [.italic, .bold])
        } else {
            XCTFail("expected an emphasis span over `b`")
        }
    }
}
