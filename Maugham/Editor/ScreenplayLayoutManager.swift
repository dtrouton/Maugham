import AppKit

extension NSAttributedString.Key {
    /// Marker attribute applied by ScreenplayMode to ranges that should
    /// render visually uppercase via ScreenplayLayoutManager glyph
    /// substitution. The source text is unmodified.
    public static let maughamDisplayUppercase =
        NSAttributedString.Key("MaughamDisplayUppercase")
}

/// NSLayoutManager subclass that substitutes uppercase glyphs for ranges
/// marked with `.maughamDisplayUppercase`. Source text and selection
/// indices stay untouched. Used by ScreenplayMode for forced character /
/// scene heading / transition lines whose source case is mixed or lower.
///
/// Strategy: override `drawGlyphs(forGlyphRange:at:)` to record the active
/// glyph range as instance state for the duration of the draw call. AppKit
/// then calls `showCGGlyphs` one or more times within that draw, each call
/// covering a sub-run of the active range. We compute the character range
/// for each sub-run via `characterRange(forGlyphRange:actualGlyphRange:)`,
/// check the marker attribute, uppercase the string, and substitute glyphs.
public final class ScreenplayLayoutManager: NSLayoutManager {
    private var activeDrawRange: NSRange?
    private var glyphCursor: Int = 0

    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        activeDrawRange = glyphsToShow
        glyphCursor = glyphsToShow.location
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        activeDrawRange = nil
    }

    public override func showCGGlyphs(
        _ glyphs: UnsafePointer<CGGlyph>,
        positions: UnsafePointer<CGPoint>,
        count glyphCount: Int,
        font: NSFont,
        textMatrix: CGAffineTransform,
        attributes: [NSAttributedString.Key : Any] = [:],
        in CGContext: CGContext
    ) {
        let drawRange = NSRange(location: glyphCursor, length: glyphCount)
        glyphCursor += glyphCount

        guard let storage = textStorage,
              activeDrawRange != nil,
              let charRange = self.actualCharRange(forGlyphRange: drawRange) else {
            super.showCGGlyphs(
                glyphs, positions: positions, count: glyphCount,
                font: font, textMatrix: textMatrix,
                attributes: attributes, in: CGContext)
            return
        }

        let storageAttrs = storage.attributes(at: charRange.location,
                                              effectiveRange: nil)
        guard storageAttrs[.maughamDisplayUppercase] as? Bool == true else {
            super.showCGGlyphs(
                glyphs, positions: positions, count: glyphCount,
                font: font, textMatrix: textMatrix,
                attributes: attributes, in: CGContext)
            return
        }

        let original = (storage.string as NSString).substring(with: charRange)
        let upper = original.uppercased()
        guard upper != original else {
            super.showCGGlyphs(
                glyphs, positions: positions, count: glyphCount,
                font: font, textMatrix: textMatrix,
                attributes: attributes, in: CGContext)
            return
        }

        // Re-derive glyphs from the uppercased string. CTFontGetGlyphsForCharacters
        // takes UTF-16 code units; each typically maps 1:1 to a glyph for ASCII
        // scripts. If the count diverges (ligatures), fall back to the original
        // glyphs to avoid drawing garbage.
        let chars = Array(upper.utf16)
        var newGlyphs = [CGGlyph](repeating: 0, count: chars.count)
        let success = CTFontGetGlyphsForCharacters(
            font as CTFont, chars, &newGlyphs, chars.count)
        guard success, newGlyphs.count == glyphCount else {
            super.showCGGlyphs(
                glyphs, positions: positions, count: glyphCount,
                font: font, textMatrix: textMatrix,
                attributes: attributes, in: CGContext)
            return
        }

        newGlyphs.withUnsafeBufferPointer { buf in
            super.showCGGlyphs(
                buf.baseAddress!,
                positions: positions, count: glyphCount,
                font: font, textMatrix: textMatrix,
                attributes: attributes, in: CGContext)
        }
    }

    private func actualCharRange(forGlyphRange glyphRange: NSRange) -> NSRange? {
        var actual = NSRange(location: 0, length: 0)
        let charRange = self.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: &actual)
        guard actual.length > 0 else { return nil }
        return charRange
    }
}
