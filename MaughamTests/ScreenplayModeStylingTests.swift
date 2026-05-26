import XCTest
import AppKit
@testable import Maugham

final class ScreenplayModeStylingTests: XCTestCase {
    private let mode = ScreenplayMode()

    private func style(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let tokens = mode.tokenize(text)
        mode.applyTypography(in: storage, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens)
        return storage
    }

    private func paragraphStyle(at location: Int, in storage: NSTextStorage) -> NSParagraphStyle? {
        let attrs = storage.attributes(at: location, effectiveRange: nil)
        return attrs[.paragraphStyle] as? NSParagraphStyle
    }

    func test_action_isLeftAligned() {
        let storage = style("Larry sits at the bar.")
        XCTAssertEqual(paragraphStyle(at: 0, in: storage)?.alignment, .left)
        XCTAssertEqual(paragraphStyle(at: 0, in: storage)?.firstLineHeadIndent ?? 0, 0,
                       accuracy: 0.5)
    }

    func test_sceneHeading_isLeftAligned_andBold() {
        let storage = style("INT. KITCHEN - DAY")
        XCTAssertEqual(paragraphStyle(at: 0, in: storage)?.alignment ?? .natural, .left)
        let font = storage.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func test_character_isIndentedAt22Chars() {
        let storage = style("BARRY\nHello.")
        let charWidth = ScreenplayModeStylingTests.charWidth(typography: .screenplayDefaults)
        let style = paragraphStyle(at: 0, in: storage)
        XCTAssertEqual(style?.firstLineHeadIndent ?? 0, charWidth * 22, accuracy: 1.0)
        XCTAssertEqual(style?.headIndent ?? 0, charWidth * 22, accuracy: 1.0)
    }

    func test_dialogue_isIndentedAt10_with35WidthBlock() {
        let storage = style("BARRY\nHello there.")
        let charWidth = ScreenplayModeStylingTests.charWidth(typography: .screenplayDefaults)
        // Dialogue is on line 2 — find its location.
        let dialogueLoc = ("BARRY\n" as NSString).length
        let style = paragraphStyle(at: dialogueLoc, in: storage)
        XCTAssertEqual(style?.firstLineHeadIndent ?? 0, charWidth * 10, accuracy: 1.0)
        XCTAssertEqual(style?.headIndent ?? 0, charWidth * 10, accuracy: 1.0)
        XCTAssertEqual(style?.tailIndent ?? 0, charWidth * 45, accuracy: 1.0)
    }

    func test_parenthetical_isIndentedAt15_with35TailIndent() {
        let storage = style("BARRY\n(quietly)\nHello.")
        let charWidth = ScreenplayModeStylingTests.charWidth(typography: .screenplayDefaults)
        let parenLoc = ("BARRY\n" as NSString).length
        let style = paragraphStyle(at: parenLoc, in: storage)
        XCTAssertEqual(style?.firstLineHeadIndent ?? 0, charWidth * 15, accuracy: 1.0)
        XCTAssertEqual(style?.tailIndent ?? 0, charWidth * 35, accuracy: 1.0)
    }

    func test_transition_isRightAligned_andBold() {
        let storage = style("Action.\n\nSMASH CUT TO:")
        let loc = ("Action.\n\n" as NSString).length
        let style = paragraphStyle(at: loc, in: storage)
        XCTAssertEqual(style?.alignment, .right)
        let font = storage.attributes(at: loc, effectiveRange: nil)[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func test_centered_isCenterAligned() {
        let storage = style(">THE END<")
        XCTAssertEqual(paragraphStyle(at: 0, in: storage)?.alignment, .center)
    }

    func test_lyric_isItalic() {
        let storage = style("~la la la")
        let font = storage.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
    }

    func test_section_isBoldAndUnderlined() {
        let storage = style("# ACT ONE")
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertNotNil(attrs[.underlineStyle])
    }

    func test_synopsis_isItalicAndDim() {
        let storage = style("= beat description")
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        XCTAssertNotNil(attrs[.foregroundColor])
        // Synopsis color must differ from body text color.
        let resolved = Theme.light.resolved(systemAppearanceIsDark: false)
        let bodyColor = resolved.palette.bodyText
        let attrColor = attrs[.foregroundColor] as? NSColor
        XCTAssertNotEqual(attrColor, bodyColor)
    }

    func test_boneyard_isItalicAndDim() {
        let storage = style("/* cut */")
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
    }

    func test_inlineNote_subRangeRendersDim() {
        // Inline note within an action line. The "[[ note ]]" range must
        // get a foreground color distinct from the body.
        let text = "Action with [[ note ]] in it."
        let storage = NSTextStorage(string: text)
        let tokens = mode.tokenize(text)
        mode.applyTypography(in: storage, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens)
        let noteStart = ("Action with " as NSString).length
        let bodyAttrs = storage.attributes(at: 0, effectiveRange: nil)
        let noteAttrs = storage.attributes(at: noteStart, effectiveRange: nil)
        let bodyColor = bodyAttrs[.foregroundColor] as? NSColor
        let noteColor = noteAttrs[.foregroundColor] as? NSColor
        XCTAssertNotNil(bodyColor)
        XCTAssertNotNil(noteColor)
        XCTAssertNotEqual(bodyColor, noteColor)
    }

    func test_dualSecondCharacter_trailingCaretFadedToSyntaxPunctuation() {
        let storage = style("BRICK\nHi.\n\nSTEVE ^\nHi.")
        // Locate the ^ inside the storage. The string contains "STEVE ^" —
        // the ^ is the LAST character of that line.
        let full = storage.string as NSString
        let stevLineStart = full.range(of: "STEVE ^").location
        XCTAssertNotEqual(stevLineStart, NSNotFound)
        let caretLocation = stevLineStart + ("STEVE " as NSString).length
        // Sanity check: the character at caretLocation is "^".
        XCTAssertEqual(full.substring(with: NSRange(location: caretLocation, length: 1)), "^")

        // syntaxPunctuation comes from Theme.light's resolved palette.
        let expectedFade = Theme.light.resolved(systemAppearanceIsDark: false)
            .palette.syntaxPunctuation
        let actual = storage.attributes(at: caretLocation, effectiveRange: nil)[.foregroundColor] as? NSColor
        XCTAssertEqual(actual, expectedFade,
                       "trailing ^ on dual-second cue should fade to syntaxPunctuation color")
    }

    /// Compute monospace character width for a typography setting,
    /// matching the math in ScreenplayMode.charWidth.
    static func charWidth(typography: TypographySettings) -> CGFloat {
        let font = NSFont(name: typography.fontFamily,
                          size: CGFloat(typography.fontSize))
            ?? NSFont.monospacedSystemFont(
                ofSize: CGFloat(typography.fontSize), weight: .regular)
        let sample = "the quick brown fox jumps over the lazy dog"
        let width = (sample as NSString).size(withAttributes: [.font: font]).width
        return width / CGFloat(sample.count)
    }
}
