import Foundation
import MaughamCore

/// Pure geometry for the translation-review staleness badges (Task 12).
///
/// The translation-review surface shows the DERIVED translated text: each
/// paragraph rendered as `translatedText ?? sourceText` and joined in `sequence`
/// order with the pinned `"\n\n"` separator — the exact join EditorHost builds
/// for the read-only buffer (and that `ProjectStoreASTSource` uses for publish).
/// A badge's paragraph range must therefore be measured against THAT rendered
/// surface, not the source manuscript's `displayRange(forParagraphId:)`.
///
/// `ranges(entries:)` reconstructs each paragraph's UTF-16 range in the
/// rendered surface by ACCUMULATING each entry's own text length — it never
/// re-splits a joined string, so it is a pure function of its inputs — no
/// AppKit — and is unit-testable in isolation (`TranslationBadgeMappingTests`),
/// which is the whole point of extracting it from the overlay's `draw`.
enum TranslationBadgeLayout {

    /// One paragraph's ordered position, freshness, and rendered TEXT in the
    /// translated surface. Carrying the block's own text (`translatedText ??
    /// sourceText` — the same string EditorHost already holds when it builds
    /// the rendered surface) is what lets `ranges` accumulate offsets directly
    /// instead of re-splitting the joined string on `"\n\n"`: the same total
    /// bytes as the old renderedText-only design, just chunked per paragraph
    /// rather than pushed as one flat string, so this is not new text-derived
    /// control state (EditorControl D1 still holds).
    struct Entry: Equatable {
        let paragraphId: String
        let text: String
        let status: TranslationStatus
        init(paragraphId: String, text: String, status: TranslationStatus) {
            self.paragraphId = paragraphId
            self.text = text
            self.status = status
        }
    }

    /// One paragraph's resolved UTF-16 range + freshness in the rendered
    /// translated surface. Named (rather than an anonymous tuple) so both
    /// `ranges` and `EditorCoordinator.resolvedTranslationBadges` share one type.
    struct BadgeRange: Equatable {
        let paragraphId: String
        let range: NSRange
        let status: TranslationStatus
    }

    /// Resolve each entry to its UTF-16 `NSRange` in the surface the entries'
    /// own texts join into (entries-order blocks joined with `"\n\n"` — the
    /// invariant EditorHost upholds when it builds the rendered surface).
    ///
    /// Accumulates directly over each entry's TEXT — `(entry.text as
    /// NSString).length`, plus two UTF-16 code units for the `"\n\n"`
    /// separator after every entry but the last — rather than splitting a
    /// joined string back on `"\n\n"`. This makes the mapping immune BY
    /// CONSTRUCTION to a translated paragraph that itself contains an
    /// internal blank line: that paragraph is still exactly one entry with
    /// one measured length, however many blank-line runs live inside its
    /// text, so it can never desync a later paragraph's offset the way
    /// re-splitting the rendered string would.
    static func ranges(entries: [Entry]) -> [BadgeRange] {
        guard !entries.isEmpty else { return [] }
        let separatorLength = 2   // "\n\n" is two UTF-16 code units
        var result: [BadgeRange] = []
        result.reserveCapacity(entries.count)
        var cursor = 0
        for entry in entries {
            let length = (entry.text as NSString).length
            result.append(BadgeRange(
                paragraphId: entry.paragraphId,
                range: NSRange(location: cursor, length: length),
                status: entry.status))
            cursor += length + separatorLength
        }
        return result
    }
}
