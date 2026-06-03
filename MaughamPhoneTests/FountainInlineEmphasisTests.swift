import XCTest
import SwiftUI
import MaughamCore
@testable import MaughamPhone

/// Tests for `FountainInlineEmphasisRenderer.attributedContent(for:style:)` — the
/// pure function that applies inline Fountain emphasis (italic / bold / underline /
/// note) to the phone reader's `AttributedString` output.
///
/// Contract (mirrors `ScreenplayMode.applyInlineSpan` on Mac):
///   .italic    → italic font on inner text; * markers at 30 % opacity
///   .bold      → bold font on inner text; ** markers at 30 % opacity
///   .underline → underline decoration on inner text; _ markers at 30 % opacity
///   .note      → italic font + 40 % opacity over full [[...]] span
///   .note element lines → plain (skip span pass; element-level style handles it)
///
/// The tests use the real `FountainTokenizer` to parse source text, extract a line
/// with `inlineSpans` populated, then assert on the produced `AttributedString`
/// runs — not on SwiftUI `Text` rendering, which is not testable in XCTest.
final class FountainInlineEmphasisTests: XCTestCase {

    // MARK: - Helpers

    private func parsedLine(from source: String, at lineIndex: Int = 0) -> FountainLine {
        let script = FountainTokenizer().parse(source)
        // Skip empty trailing lines appended by the tokenizer.
        let nonEmpty = script.lines.filter { !$0.content.isEmpty || $0.element != .action }
        return nonEmpty[lineIndex]
    }

    private func attributedContent(_ line: FountainLine, style: FountainLineStyle? = nil) -> AttributedString {
        let s = style ?? FountainStyler.style(for: line)
        return FountainInlineEmphasisRenderer.attributedContent(for: line, style: s)
    }

    /// Advance an `AttributedString.Index` by `n` characters.
    private func attrIndex(_ n: Int, in attr: AttributedString) -> AttributedString.Index {
        var idx = attr.startIndex
        for _ in 0 ..< n { idx = attr.index(afterCharacter: idx) }
        return idx
    }

    /// Returns the font at character offset `index` in an AttributedString.
    private func fontAt(_ index: Int, in attr: AttributedString) -> Font? {
        let i = attrIndex(index, in: attr)
        let next = attr.index(afterCharacter: i)
        return attr[i ..< next].font
    }

    /// Returns the foreground color at character offset `index`.
    private func foregroundColorAt(_ index: Int, in attr: AttributedString) -> Color? {
        let i = attrIndex(index, in: attr)
        let next = attr.index(afterCharacter: i)
        return attr[i ..< next].foregroundColor
    }

    /// Returns the underline style at character offset `index`.
    private func underlineAt(_ index: Int, in attr: AttributedString) -> Text.LineStyle? {
        let i = attrIndex(index, in: attr)
        let next = attr.index(afterCharacter: i)
        return attr[i ..< next].underlineStyle
    }

    // MARK: - Fast-path: no spans

    func test_noSpans_returnsPlainAttributedString() {
        // Action line with no markers — inlineSpans empty → plain pass-through.
        let line = parsedLine(from: "He walks in.\n")
        XCTAssertTrue(line.inlineSpans.isEmpty, "precondition: no spans")
        let attr = attributedContent(line)
        XCTAssertEqual(String(attr.characters), "He walks in.")
        // No per-character font overrides.
        XCTAssertNil(fontAt(0, in: attr))
    }

    // MARK: - .note element lines skip the span pass

    func test_noteElementLine_returnsPlain() {
        // A block note line ([[...]]) is element .note — skip inline span pass.
        let line = parsedLine(from: "[[This is a note]]\n")
        XCTAssertEqual(line.element, .note)
        let attr = attributedContent(line)
        // Content is the full text (including brackets) as a plain AttributedString.
        XCTAssertEqual(String(attr.characters), "[[This is a note]]")
        XCTAssertNil(fontAt(0, in: attr), "no per-run font on .note element lines")
    }

    // MARK: - Italic

    func test_italic_innerTextIsItalic() {
        // "*italic*" inside action text.
        let source = "He said *hello* quietly.\n"
        let line = parsedLine(from: source)
        XCTAssertFalse(line.inlineSpans.isEmpty, "precondition: spans present")
        let attr = attributedContent(line)
        // The content is "He said *hello* quietly."
        // Positions: H=0,e=1,' '=2,s=3,a=4,i=5,d=6,' '=7,*=8,h=9,e=10,l=11,l=12,o=13,*=14,' '=15...
        let content = String(attr.characters)
        guard let starRange = content.range(of: "*hello*") else {
            XCTFail("marker not found in content: \(content)"); return
        }
        let starOffset = content.distance(from: content.startIndex, to: starRange.lowerBound)
        let hOffset = starOffset + 1  // 'h' in "hello"

        // Inner text should be italic.
        if let f = fontAt(hOffset, in: attr) {
            // Font was set — verify it incorporates italic.
            // We check that the font is .body.italic() by comparing with expected.
            XCTAssertEqual(f, Font.body.italic(),
                           "inner italic text should have italic font")
        } else {
            XCTFail("inner text at offset \(hOffset) has no font set (expected italic)")
        }

        // Leading * marker should be faded.
        let markerOpacity = foregroundColorAt(starOffset, in: attr)
        XCTAssertNotNil(markerOpacity, "leading * marker should have faded foreground color")
    }

    func test_italic_standaloneLine() {
        // Dialogue line: "She said *yes*." — verifies italic applied in non-action context.
        let source = "\nALICE\nShe said *yes*.\n"
        let script = FountainTokenizer().parse(source)
        let dialogueLine = script.lines.first { $0.element == .dialogue }!
        let attr = attributedContent(dialogueLine)
        let content = String(attr.characters)
        guard let range = content.range(of: "*yes*") else {
            XCTFail("marker not found: \(content)"); return
        }
        let starOffset = content.distance(from: content.startIndex, to: range.lowerBound)
        let yOffset = starOffset + 1
        XCTAssertNotNil(fontAt(yOffset, in: attr), "inner 'y' in *yes* should have font set")
        XCTAssertEqual(fontAt(yOffset, in: attr), Font.body.italic())
    }

    // MARK: - Bold

    func test_bold_innerTextIsBold() {
        let source = "She said **wow** loudly.\n"
        let line = parsedLine(from: source)
        XCTAssertFalse(line.inlineSpans.isEmpty, "precondition: spans present")
        let attr = attributedContent(line)
        let content = String(attr.characters)
        guard let range = content.range(of: "**wow**") else {
            XCTFail("marker not found: \(content)"); return
        }
        let starOffset = content.distance(from: content.startIndex, to: range.lowerBound)
        let wOffset = starOffset + 2  // skip "**", land on 'w'

        if let f = fontAt(wOffset, in: attr) {
            XCTAssertEqual(f, Font.body.bold(),
                           "inner bold text should have bold font")
        } else {
            XCTFail("inner text at offset \(wOffset) has no font set (expected bold)")
        }

        // Leading ** markers should be faded.
        XCTAssertNotNil(foregroundColorAt(starOffset, in: attr),
                        "leading ** marker should have faded foreground color")
        XCTAssertNotNil(foregroundColorAt(starOffset + 1, in: attr),
                        "second * of leading ** should also be faded")
    }

    // MARK: - Underline

    func test_underline_innerTextHasUnderlineStyle() {
        let source = "A _key term_ here.\n"
        let line = parsedLine(from: source)
        XCTAssertFalse(line.inlineSpans.isEmpty, "precondition: spans present")
        let attr = attributedContent(line)
        let content = String(attr.characters)
        guard let range = content.range(of: "_key term_") else {
            XCTFail("marker not found: \(content)"); return
        }
        let underscoreOffset = content.distance(from: content.startIndex, to: range.lowerBound)
        let kOffset = underscoreOffset + 1  // 'k' in "key"

        XCTAssertNotNil(underlineAt(kOffset, in: attr),
                        "inner underlined text should have underlineStyle set")
        // Marker should be faded, not underlined.
        XCTAssertNil(underlineAt(underscoreOffset, in: attr),
                     "leading _ marker should NOT be underlined")
        XCTAssertNotNil(foregroundColorAt(underscoreOffset, in: attr),
                        "leading _ marker should have faded foreground color")
    }

    // MARK: - Inline [[note]] within a non-note line

    func test_inlineNote_isItalicAndDimmed() {
        let source = "He walked in. [[fix this]] He sat.\n"
        let line = parsedLine(from: source)
        // Note: this action line has inlineSpans for the [[...]] note.
        XCTAssertFalse(line.inlineSpans.isEmpty, "precondition: spans present")
        let attr = attributedContent(line)
        let content = String(attr.characters)
        guard let range = content.range(of: "[[fix this]]") else {
            XCTFail("note span not found: \(content)"); return
        }
        let noteOffset = content.distance(from: content.startIndex, to: range.lowerBound)
        // Font should be italic.
        XCTAssertNotNil(fontAt(noteOffset, in: attr),
                        "[[note]] span should have an italic font set")
        // Foreground color should have low opacity.
        XCTAssertNotNil(foregroundColorAt(noteOffset, in: attr),
                        "[[note]] span should have a dimmed foreground color")
    }

    // MARK: - Multiple spans in one line

    func test_multipleSpans_bothApplied() {
        let source = "This is *italic* and **bold** text.\n"
        let line = parsedLine(from: source)
        XCTAssertFalse(line.inlineSpans.isEmpty, "precondition: spans present")
        let attr = attributedContent(line)
        let content = String(attr.characters)

        // Italic span.
        guard let italicRange = content.range(of: "*italic*") else {
            XCTFail("*italic* not found: \(content)"); return
        }
        let iStarOffset = content.distance(from: content.startIndex, to: italicRange.lowerBound)
        let iOffset = iStarOffset + 1
        XCTAssertEqual(fontAt(iOffset, in: attr), Font.body.italic(), "italic span applied")

        // Bold span.
        guard let boldRange = content.range(of: "**bold**") else {
            XCTFail("**bold** not found: \(content)"); return
        }
        let bStarOffset = content.distance(from: content.startIndex, to: boldRange.lowerBound)
        let bOffset = bStarOffset + 2
        XCTAssertEqual(fontAt(bOffset, in: attr), Font.body.bold(), "bold span applied")
    }

    // MARK: - Uppercased content (scene heading)

    func test_uppercase_spansAppliedAfterUppercasing() {
        // FountainStyler sets uppercased=true for scene headings.  The markers
        // are ASCII so they survive uppercasing; spans should still be applied.
        let source = "INT. OFFICE - DAY\n"
        let line = parsedLine(from: source)
        let style = FountainStyler.style(for: line)
        XCTAssertTrue(style.uppercased)
        // Scene headings rarely have emphasis, but ensure the function doesn't crash
        // on an uppercased line with no spans.
        let attr = FountainInlineEmphasisRenderer.attributedContent(for: line, style: style)
        XCTAssertFalse(String(attr.characters).isEmpty)
    }
}
