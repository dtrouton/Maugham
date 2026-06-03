import XCTest
import SwiftUI
import MaughamCore
@testable import MaughamPhone

/// Tests for `FountainInlineEmphasisRenderer.attributedContent(for:style:)` — the
/// pure function that applies the SHARED tokenizer's `FountainInlineSpan` values
/// (italic / bold / underline / note) to the phone reader's `AttributedString`.
///
/// CONTRACT (mirrors `ScreenplayMode.applyInlineSpan` on Mac):
///   .italic    → italic font on inner text; * markers at 30 % opacity
///   .bold      → bold font on inner text; ** markers at 30 % opacity
///   .underline → underline decoration on inner; _ markers at 30 % opacity
///   .note      → italic font + 40 % opacity over full [[...]] span (markers incl.)
///   .note element lines → plain (skip span pass; element-level style handles it)
///
/// Every test parses REAL Fountain source through `DocumentReaderView.parseFountain`
/// — the exact production parse path — so the parser-produced `inlineSpans` are
/// exercised, not hand-built spans. A hand-built-span test could pass while the
/// real parser→renderer wiring is broken; parsing real text closes that gap.
final class FountainInlineEmphasisTests: XCTestCase {

    // MARK: - Helpers

    /// Parse real Fountain through the production path and return the first line
    /// matching `element` (default: the first body line with non-empty content).
    private func parsedLine(
        from source: String,
        element: ScreenplayElement? = nil
    ) -> FountainLine {
        let script = DocumentReaderView.parseFountain(source)
        if let element {
            return script.lines.first { $0.element == element }!
        }
        return script.lines.first { !$0.content.isEmpty }!
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

    private func fontAt(_ index: Int, in attr: AttributedString) -> Font? {
        let i = attrIndex(index, in: attr)
        let next = attr.index(afterCharacter: i)
        return attr[i ..< next].font
    }

    private func foregroundColorAt(_ index: Int, in attr: AttributedString) -> Color? {
        let i = attrIndex(index, in: attr)
        let next = attr.index(afterCharacter: i)
        return attr[i ..< next].foregroundColor
    }

    private func underlineAt(_ index: Int, in attr: AttributedString) -> Text.LineStyle? {
        let i = attrIndex(index, in: attr)
        let next = attr.index(afterCharacter: i)
        return attr[i ..< next].underlineStyle
    }

    /// Character offset of `substring`'s first occurrence in the AttributedString.
    private func offset(of substring: String, in attr: AttributedString) -> Int? {
        let content = String(attr.characters)
        guard let range = content.range(of: substring) else { return nil }
        return content.distance(from: content.startIndex, to: range.lowerBound)
    }

    // MARK: - Fast path: no spans

    func test_noSpans_returnsPlainAttributedString() {
        let line = parsedLine(from: "He walks in.\n")
        XCTAssertTrue(line.inlineSpans.isEmpty, "precondition: parser produced no spans")
        let attr = attributedContent(line)
        XCTAssertEqual(String(attr.characters), "He walks in.")
        XCTAssertNil(fontAt(0, in: attr))
    }

    // MARK: - .note element lines skip the span pass

    func test_noteElementLine_returnsPlain() {
        let line = parsedLine(from: "[[This is a note]]\n", element: .note)
        XCTAssertEqual(line.element, .note)
        let attr = attributedContent(line)
        XCTAssertEqual(String(attr.characters), "[[This is a note]]")
        XCTAssertNil(fontAt(0, in: attr), "no per-run font on .note element lines")
    }

    // MARK: - Italic

    func test_italic_innerTextIsItalic_markersFaded() {
        let line = parsedLine(from: "He said *hello* quietly.\n")
        XCTAssertTrue(line.inlineSpans.contains { $0.kind == .italic },
                      "precondition: parser produced an italic span")
        let attr = attributedContent(line)
        guard let star = offset(of: "*hello*", in: attr) else {
            XCTFail("marker not found"); return
        }
        // Inner 'h' (star + 1) should be italic; the * marker should be faded.
        XCTAssertEqual(fontAt(star + 1, in: attr), Font.body.italic(),
                       "inner italic text should have italic font")
        XCTAssertNotNil(foregroundColorAt(star, in: attr),
                        "leading * marker should be faded")
        // Closing * is at star + 6 ("*hello*" = 7 chars, last index 6).
        XCTAssertNotNil(foregroundColorAt(star + 6, in: attr),
                        "trailing * marker should be faded")
    }

    func test_italic_inDialogueContext() {
        let line = parsedLine(from: "\nALICE\nShe said *yes*.\n", element: .dialogue)
        let attr = attributedContent(line)
        guard let star = offset(of: "*yes*", in: attr) else {
            XCTFail("marker not found"); return
        }
        XCTAssertEqual(fontAt(star + 1, in: attr), Font.body.italic())
    }

    // MARK: - Bold

    func test_bold_innerTextIsBold_markersFaded() {
        let line = parsedLine(from: "She said **wow** loudly.\n")
        XCTAssertTrue(line.inlineSpans.contains { $0.kind == .bold },
                      "precondition: parser produced a bold span")
        let attr = attributedContent(line)
        guard let stars = offset(of: "**wow**", in: attr) else {
            XCTFail("marker not found"); return
        }
        // Inner 'w' (stars + 2, skipping **) should be bold.
        XCTAssertEqual(fontAt(stars + 2, in: attr), Font.body.bold(),
                       "inner bold text should have bold font")
        // Both leading ** chars faded.
        XCTAssertNotNil(foregroundColorAt(stars, in: attr))
        XCTAssertNotNil(foregroundColorAt(stars + 1, in: attr))
    }

    // MARK: - Underline

    func test_underline_innerHasUnderline_markersFaded() {
        let line = parsedLine(from: "A _key term_ here.\n")
        XCTAssertTrue(line.inlineSpans.contains { $0.kind == .underline },
                      "precondition: parser produced an underline span")
        let attr = attributedContent(line)
        guard let underscore = offset(of: "_key term_", in: attr) else {
            XCTFail("marker not found"); return
        }
        XCTAssertNotNil(underlineAt(underscore + 1, in: attr),
                        "inner underlined text should have underlineStyle set")
        XCTAssertNil(underlineAt(underscore, in: attr),
                     "leading _ marker should NOT be underlined")
        XCTAssertNotNil(foregroundColorAt(underscore, in: attr),
                        "leading _ marker should be faded")
    }

    // MARK: - Inline [[note]] within a non-note line

    func test_inlineNote_isItalicAndDimmed_overWholeSpan() {
        let line = parsedLine(from: "He walked in. [[fix this]] He sat.\n")
        XCTAssertTrue(line.inlineSpans.contains { $0.kind == .note },
                      "precondition: parser produced a note span")
        let attr = attributedContent(line)
        guard let note = offset(of: "[[fix this]]", in: attr) else {
            XCTFail("note span not found"); return
        }
        // Whole span (including brackets) is italic + dimmed — check the bracket
        // and an inner char.
        XCTAssertEqual(fontAt(note, in: attr), Font.body.italic(),
                       "[[ bracket should be italic (whole-span treatment)")
        XCTAssertNotNil(foregroundColorAt(note, in: attr),
                        "note span should be dimmed")
        XCTAssertEqual(fontAt(note + 2, in: attr), Font.body.italic(),
                       "inner note text should be italic")
    }

    // MARK: - Multiple spans in one line

    func test_multipleSpans_bothApplied() {
        let line = parsedLine(from: "This is *italic* and **bold** text.\n")
        let kinds = Set(line.inlineSpans.map(\.kind))
        XCTAssertTrue(kinds.contains(.italic) && kinds.contains(.bold),
                      "precondition: parser produced both italic and bold spans")
        let attr = attributedContent(line)

        guard let i = offset(of: "*italic*", in: attr) else {
            XCTFail("*italic* not found"); return
        }
        XCTAssertEqual(fontAt(i + 1, in: attr), Font.body.italic(), "italic applied")

        guard let b = offset(of: "**bold**", in: attr) else {
            XCTFail("**bold** not found"); return
        }
        XCTAssertEqual(fontAt(b + 2, in: attr), Font.body.bold(), "bold applied")
    }

    // MARK: - Uppercased content

    func test_uppercase_spansMapCorrectlyAfterUppercasing() {
        // Parse a real line carrying an italic span, then force the uppercased
        // style flag. Markers are ASCII so uppercasing does not shift offsets;
        // the parser-produced span must still map to the right (uppercased) chars.
        let line = parsedLine(from: "She *whispers* the secret.\n")
        var style = FountainStyler.style(for: line)
        style.uppercased = true
        let attr = FountainInlineEmphasisRenderer.attributedContent(for: line, style: style)
        let content = String(attr.characters)
        XCTAssertEqual(content, "SHE *WHISPERS* THE SECRET.",
                       "content uppercased; ASCII markers preserved")
        guard let star = offset(of: "*WHISPERS*", in: attr) else {
            XCTFail("uppercased marker not found in: \(content)"); return
        }
        XCTAssertEqual(fontAt(star + 1, in: attr), Font.body.italic(),
                       "italic span still maps correctly after uppercasing")
    }
}
