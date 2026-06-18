import Foundation
import MaughamCore

/// Pure helpers for turning an editor selection (an absolute UTF-16 range into
/// the full display text) into a paragraph-relative `SpanAnchor`.
///
/// The editor toolbar acts on `textView.selectedRange()` — an `NSRange` (UTF-16
/// offsets) into `textView.string`, which is the *stripped display* form of the
/// manuscript (paragraphs joined by "\n\n"). `Document.paragraphRange(at:)`
/// gives the containing paragraph's id plus its UTF-16 range in that same
/// display string. From there we clamp the selection into the paragraph,
/// translate UTF-16 offsets to grapheme offsets on the paragraph's display
/// text, and hand the grapheme range to `SpanAnchorResolver.capture`.
///
/// Spans live within one paragraph (spec). A selection straddling a paragraph
/// boundary is clamped to the *first* paragraph (the one `paragraphRange(at:)`
/// reports for the selection's start). A selection with no overlap returns nil.
enum ReviewSpanCapture {

    /// Intersect an absolute selection with a paragraph's range and express the
    /// result relative to the paragraph's start. All four bounds are in the
    /// same unit (UTF-16 code units against the display text).
    ///
    /// Returns nil if the selection is empty or does not overlap the paragraph.
    /// A selection that runs past the paragraph's end is clamped to the
    /// paragraph end (spans stay within one paragraph).
    static func paragraphRelativeRange(
        absolute: Range<Int>, paragraph: Range<Int>
    ) -> Range<Int>? {
        guard !absolute.isEmpty else { return nil }
        let lo = max(absolute.lowerBound, paragraph.lowerBound)
        let hi = min(absolute.upperBound, paragraph.upperBound)
        guard lo < hi else { return nil }
        return (lo - paragraph.lowerBound)..<(hi - paragraph.lowerBound)
    }

    /// Convert a paragraph-relative UTF-16 range into a grapheme `Range<Int>`
    /// against `paragraphText`, then capture a `SpanAnchor`.
    ///
    /// Returns nil if the UTF-16 bounds don't land on grapheme boundaries that
    /// can be mapped (e.g. mid-surrogate), or if the resulting grapheme range
    /// is empty.
    static func captureSpan(
        in paragraphText: String, relativeUTF16 range: Range<Int>
    ) -> SpanAnchor? {
        let ns = paragraphText as NSString
        guard range.lowerBound >= 0,
              range.upperBound <= ns.length,
              range.lowerBound < range.upperBound else { return nil }
        // Map UTF-16 offsets → String.Index → grapheme distance.
        let utf16 = paragraphText.utf16
        guard let loU16 = utf16.index(
                utf16.startIndex, offsetBy: range.lowerBound,
                limitedBy: utf16.endIndex),
              let hiU16 = utf16.index(
                utf16.startIndex, offsetBy: range.upperBound,
                limitedBy: utf16.endIndex),
              let lo = loU16.samePosition(in: paragraphText),
              let hi = hiU16.samePosition(in: paragraphText)
        else { return nil }
        let loGrapheme = paragraphText.distance(
            from: paragraphText.startIndex, to: lo)
        let hiGrapheme = paragraphText.distance(
            from: paragraphText.startIndex, to: hi)
        guard loGrapheme < hiGrapheme else { return nil }
        return SpanAnchorResolver.capture(
            in: paragraphText, range: loGrapheme..<hiGrapheme)
    }
}
