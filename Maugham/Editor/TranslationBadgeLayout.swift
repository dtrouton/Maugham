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
/// `ranges(entries:renderedText:)` reconstructs each paragraph's UTF-16 range in
/// the rendered surface by walking the blocks the join produced. It is a pure
/// function of its inputs — no AppKit — so it is unit-testable in isolation
/// (`TranslationBadgeMappingTests`), which is the whole point of extracting it
/// from the overlay's `draw`.
enum TranslationBadgeLayout {

    /// One paragraph's ordered position + freshness in the translated surface.
    /// Deliberately carries no text: the block texts live in `renderedText` and
    /// are walked in this same order, keeping the control-plane push minimal
    /// (EditorControl D1 — as little text-derived state as possible).
    struct Entry: Equatable {
        let paragraphId: String
        let status: TranslationStatus
        init(paragraphId: String, status: TranslationStatus) {
            self.paragraphId = paragraphId
            self.status = status
        }
    }

    /// Resolve each entry to its UTF-16 `NSRange` in `renderedText`.
    ///
    /// `renderedText` MUST be the `entries`-order blocks joined with `"\n\n"`
    /// (the invariant EditorHost upholds by construction). We split it back on
    /// that exact separator and pair blocks with entries by position,
    /// accumulating UTF-16 offsets: `NSString` length per block, plus two code
    /// units for each `"\n\n"` separator. Pairing stops at the shorter of the
    /// two counts, so a torn push (entries and text momentarily disagreeing)
    /// yields fewer badges rather than a mis-placed one.
    ///
    /// KNOWN LIMITATION (documented; the common case is machine-checked): a
    /// single translated paragraph that itself contains a blank line ("\n\n")
    /// over-splits and shifts every later badge. Paragraph blocks are the units
    /// BETWEEN blank lines, so this never arises for source text; only a
    /// translation that introduces an internal blank line is unhandled. Fixing
    /// it would require threading per-block texts through the control plane,
    /// which EditorControl D1 discourages.
    static func ranges(
        entries: [Entry], renderedText: String
    ) -> [(paragraphId: String, range: NSRange, status: TranslationStatus)] {
        guard !entries.isEmpty else { return [] }
        let blocks = renderedText.components(separatedBy: "\n\n")
        let separatorLength = 2   // "\n\n" is two UTF-16 code units
        var result: [(paragraphId: String, range: NSRange, status: TranslationStatus)] = []
        var cursor = 0
        for (index, block) in blocks.enumerated() {
            let length = (block as NSString).length
            if index < entries.count {
                let entry = entries[index]
                result.append((
                    paragraphId: entry.paragraphId,
                    range: NSRange(location: cursor, length: length),
                    status: entry.status))
            }
            cursor += length + separatorLength
        }
        return result
    }
}
