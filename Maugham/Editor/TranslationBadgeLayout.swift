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

    /// One paragraph's ordered position, freshness, rendered TEXT and — when
    /// the writer reads the source under each paragraph (shell p4 Task 8) —
    /// the SOURCE drawn under it. The block the surface shows is `text`, then
    /// `sourceSeparator`, then `source` (`block`). Carrying the block's own
    /// text is what lets `ranges` accumulate offsets directly instead of
    /// re-splitting the joined string: the same bytes as the surface, just
    /// chunked per paragraph, so this is not new text-derived control state
    /// (EditorControl D1 still holds).
    struct Entry: Equatable {
        let paragraphId: String
        /// What the paragraph reads in the language (its source where it has
        /// no translation).
        let text: String
        /// The source drawn under `text`, or nil: source-under is off, the
        /// paragraph has no translation (its source is already `text` — shown
        /// once, never twice), or repeating it would add nothing.
        let source: String?
        let status: TranslationStatus
        /// Between `text` and `source`: one newline in prose; a blank line in
        /// a screenplay, so each half parses as its own Fountain block.
        let sourceSeparator: String
        init(paragraphId: String, text: String, source: String? = nil,
             status: TranslationStatus, sourceSeparator: String = TranslationBadgeLayout.proseSourceSeparator) {
            self.paragraphId = paragraphId
            self.text = text
            self.source = source
            self.status = status
            self.sourceSeparator = sourceSeparator
        }

        /// The paragraph's whole block in the surface.
        var block: String {
            guard let source else { return text }
            return text + sourceSeparator + source
        }
    }

    /// The prose separator between a translation and its source.
    static let proseSourceSeparator = "\n"
    /// A screenplay's: a blank line, so the translated block keeps its own
    /// structure and the source parses as the source does.
    static let screenplaySourceSeparator = "\n\n"
    /// Between paragraphs' blocks, as ever.
    static let blockSeparator = "\n\n"

    /// One paragraph's resolved UTF-16 ranges + freshness in the rendered
    /// translated surface. `range` covers the TRANSLATION only, so the badges
    /// and the caret's paragraph keep meaning "this paragraph"; `sourceRange`
    /// covers the source line under it (drawn in secondary ink), nil where
    /// none is drawn. Named (rather than an anonymous tuple) so both `ranges`
    /// and `EditorCoordinator.resolvedTranslationBadges` share one type.
    struct BadgeRange: Equatable {
        let paragraphId: String
        let range: NSRange
        let sourceRange: NSRange?
        let status: TranslationStatus
        init(paragraphId: String, range: NSRange, sourceRange: NSRange? = nil,
             status: TranslationStatus) {
            self.paragraphId = paragraphId
            self.range = range
            self.sourceRange = sourceRange
            self.status = status
        }

        /// The whole block: the translation and the source under it.
        var blockRange: NSRange {
            guard let sourceRange else { return range }
            return NSRange(location: range.location,
                           length: NSMaxRange(sourceRange) - range.location)
        }
    }

    /// The surface the entries join into — the one string EditorHost swaps in.
    static func surface(entries: [Entry]) -> String {
        entries.map(\.block).joined(separator: blockSeparator)
    }

    /// Resolve each entry to its UTF-16 ranges in the surface the entries'
    /// blocks join into (`surface(entries:)`).
    ///
    /// Accumulates directly over each entry's block — `(text as NSString)
    /// .length`, the separator, the source's length — plus two UTF-16 code
    /// units for the `"\n\n"` after every block but the last, rather than
    /// splitting a joined string back on `"\n\n"`. This makes the mapping
    /// immune BY CONSTRUCTION to a translated paragraph that itself contains
    /// an internal blank line (or a screenplay's blank line before its
    /// source): that paragraph is still exactly one entry with measured
    /// lengths, so it can never desync a later paragraph's offset.
    static func ranges(entries: [Entry]) -> [BadgeRange] {
        guard !entries.isEmpty else { return [] }
        let separatorLength = (blockSeparator as NSString).length
        var result: [BadgeRange] = []
        result.reserveCapacity(entries.count)
        var cursor = 0
        for entry in entries {
            let length = (entry.text as NSString).length
            var sourceRange: NSRange?
            var blockLength = length
            if let source = entry.source {
                let gap = (entry.sourceSeparator as NSString).length
                sourceRange = NSRange(location: cursor + length + gap,
                                      length: (source as NSString).length)
                blockLength = length + gap + (source as NSString).length
            }
            result.append(BadgeRange(
                paragraphId: entry.paragraphId,
                range: NSRange(location: cursor, length: length),
                sourceRange: sourceRange,
                status: entry.status))
            cursor += blockLength + separatorLength
        }
        return result
    }

    /// **The paragraph a surface location belongs to** — the last block that
    /// starts at or before it, so a caret in a source line, at a block's end
    /// or in the separator after it belongs to that paragraph; a negative
    /// location clamps to the first, one past the end to the last.
    /// `Document.paragraphId(at:)`'s walk, over the translated surface.
    static func index(at location: Int, in ranges: [BadgeRange]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        var low = 0, high = ranges.count - 1, found = 0
        while low <= high {
            let mid = (low + high) / 2
            if ranges[mid].range.location <= location { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    /// **A caret in the translated surface, as a caret in the source** — the
    /// paragraph it sits in, and its offset there clamped into the source
    /// paragraph (`sourceRangeOf` is the source's display range of a
    /// paragraph). This is what the surface tells `Document.cursorLocation`, so
    /// every reader of the source caret (To resolve's caret group, the
    /// Translator's note, the footer) finds the paragraph the writer clicked
    /// in, a source line included. Nil where the surface names no paragraph
    /// the source still has.
    static func sourceLocation(forSurfaceLocation location: Int, ranges: [BadgeRange],
                               sourceRangeOf: (String) -> NSRange?) -> Int? {
        guard let i = index(at: location, in: ranges),
              let source = sourceRangeOf(ranges[i].paragraphId) else { return nil }
        let badge = ranges[i]
        // In the source line: its own offset; in the translation: the same
        // distance in, which is as near as a caret in another language gets.
        let into: Int
        if let sourceRange = badge.sourceRange, location >= sourceRange.location {
            into = location - sourceRange.location
        } else {
            into = location - badge.range.location
        }
        return source.location + max(0, min(into, source.length))
    }

    /// **A source caret, as a caret in the translated surface** — the
    /// inverse of `sourceLocation`: the same distance into the paragraph's
    /// translation, clamped to it. Nil where the surface does not hold the
    /// paragraph. A chapter opened already read in a language restores its
    /// remembered caret through this, so the caret lands in its own paragraph
    /// and the source's remembered place is not rewritten by a stray one.
    static func surfaceLocation(forSourceLocation location: Int, paragraphId: String,
                                sourceRange: NSRange, ranges: [BadgeRange]) -> Int? {
        guard let badge = ranges.first(where: { $0.paragraphId == paragraphId }) else { return nil }
        let into = max(0, min(location - sourceRange.location, badge.range.length))
        return badge.range.location + into
    }

    /// **What the coordinator inks, clamped to the buffer**: each missing
    /// paragraph's text (the source showing through), each source line under
    /// a translation, and each STALE translation (fix round (d): out-of-date
    /// text is never drawn as if current). Clamped because a torn push can
    /// leave a range past the buffer for a moment. Pure, so which characters
    /// go quiet is assertable without a layout manager.
    struct Ink: Equatable {
        enum Kind: Equatable { case missing, source, stale }
        let range: NSRange
        let kind: Kind
        var isSource: Bool { kind == .source }
    }

    static func inks(_ badges: [BadgeRange], length: Int) -> [Ink] {
        func clamped(_ r: NSRange) -> NSRange? {
            let loc = min(r.location, length)
            let len = min(r.length, max(0, length - loc))
            return len > 0 ? NSRange(location: loc, length: len) : nil
        }
        var out: [Ink] = []
        for badge in badges {
            switch badge.status {
            case .missing:
                if let r = clamped(badge.range) { out.append(Ink(range: r, kind: .missing)) }
            case .stale:
                if let r = clamped(badge.range) { out.append(Ink(range: r, kind: .stale)) }
            case .fresh:
                break
            }
            if let source = badge.sourceRange, let r = clamped(source) {
                out.append(Ink(range: r, kind: .source))
            }
        }
        return out
    }

    /// **What VoiceOver says of a paragraph that is not current** (fix round
    /// (d)) — nil for a current one.
    static func accessibilityNote(_ status: TranslationStatus) -> String? {
        switch status {
        case .fresh: return nil
        case .stale: return "Out of date: the source changed after this paragraph was translated"
        case .missing: return "Not translated yet: the source is shown"
        }
    }

    // MARK: - The translation alone

    /// Each source line with the separator before it — what the translation
    /// alone is without. Sorted, as the ranges are.
    static func sourceSpans(_ ranges: [BadgeRange]) -> [NSRange] {
        ranges.compactMap { badge in
            badge.sourceRange.map {
                NSRange(location: NSMaxRange(badge.range), length: NSMaxRange($0) - NSMaxRange(badge.range))
            }
        }
    }

    /// `text` within `selection`, less every source span — clamped to the
    /// text, so a torn push copies what is there.
    private static func removingSourceSpans(_ text: NSString, _ selection: NSRange,
                                            _ ranges: [BadgeRange]) -> String {
        let length = text.length
        let start = min(max(0, selection.location), length)
        let end = min(NSMaxRange(selection), length)
        var out = ""
        var cursor = start
        for span in sourceSpans(ranges) where NSMaxRange(span) > cursor && span.location < end {
            if span.location > cursor {
                out += text.substring(with: NSRange(location: cursor, length: span.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(span))
        }
        if end > cursor { out += text.substring(with: NSRange(location: cursor, length: end - cursor)) }
        return out
    }

    /// **What copy puts on the pasteboard from a translated surface** (shell
    /// p4 Task 8, fix round (a)): the translation, never the grey source
    /// lines under it — except a selection made wholly inside one source line,
    /// where the writer asked for the source.
    static func copyable(_ text: String, selection: NSRange, ranges: [BadgeRange]) -> String {
        let ns = text as NSString
        if selection.length > 0, ranges.contains(where: { badge in
            badge.sourceRange.map { NSIntersectionRange($0, selection) == selection } ?? false
        }) {
            return ns.substring(with: selection)
        }
        return removingSourceSpans(ns, selection, ranges)
    }

    /// The whole surface's translation alone — what a reading window counts.
    static func translationOnly(_ text: String, ranges: [BadgeRange]) -> String {
        let ns = text as NSString
        return removingSourceSpans(ns, NSRange(location: 0, length: ns.length), ranges)
    }
}
