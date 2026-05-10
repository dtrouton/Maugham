import XCTest
import AppKit
@testable import Maugham

final class InlineEmphasisStylingTests: XCTestCase {
    private let mode = ScreenplayMode()

    private func style(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let tokens = mode.tokenize(text)
        mode.applyTypography(in: storage, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens)
        return storage
    }

    func test_italicSpan_innerContentIsItalic() {
        let storage = style("Action with *italic* text.")
        let innerStart = ("Action with *" as NSString).length
        let attrs = storage.attributes(at: innerStart, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func test_boldSpan_innerContentIsBold() {
        let storage = style("Action with **bold** text.")
        let innerStart = ("Action with **" as NSString).length
        let attrs = storage.attributes(at: innerStart, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func test_underlineSpan_innerContentHasUnderline() {
        let storage = style("Action with _underline_ text.")
        let innerStart = ("Action with _" as NSString).length
        let attrs = storage.attributes(at: innerStart, effectiveRange: nil)
        XCTAssertNotNil(attrs[.underlineStyle])
    }

    func test_emphasisMarkersAreFaded() {
        let storage = style("Action with *italic* text.")
        let markerStart = ("Action with " as NSString).length
        let attrs = storage.attributes(at: markerStart, effectiveRange: nil)
        let palette = Theme.light.resolved(systemAppearanceIsDark: false).palette
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, palette.syntaxPunctuation)
    }

    func test_compositionBoldItalic_innerOverlapIsBoldItalic() {
        let storage = style("*foo **bar** baz*")
        // Inner "bar" (after "*foo **") is at offset 7. Should be bold-italic.
        let barStart = ("*foo **" as NSString).length
        let attrs = storage.attributes(at: barStart, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.italic))
    }
}
