import Foundation

/// Computes the *attribute-application window* for a keystroke restyle.
///
/// `NSTextStorage` attaches attributes to characters and shifts them
/// automatically across edits, so after a keystroke only the region whose
/// *token classification* actually changed needs its attributes re-applied —
/// everything before the first divergence is unshifted-and-unchanged, and
/// everything after the last divergence shifted by the edit's length delta but
/// carried its (correct) attributes along.
///
/// Tokenization itself stays whole-document (it is cheap and Fountain is
/// context-sensitive); what this windows is the *attribute application* in
/// `WritingMode.applyTypography`. See `Maugham/Editor/AREA.md` and
/// `WindowedTypographyEquivalenceTests`.
///
/// Comparison is `(kind, length)` only — locations shift across edits so they
/// are deliberately excluded. `Token.Kind` is `Equatable` and its associated
/// payloads (heading level, emphasis traits, `ScreenplayElement`, checkbox
/// checked-state, …) participate in that equality, so a payload-only change
/// (e.g. a line reclassified CHARACTER→action, or a checkbox toggled) is
/// detected as a mismatch even when range length is unchanged.
enum TokenRestyleWindow {

    /// The result of diffing the old and new token streams for a keystroke.
    enum Decision: Equatable {
        /// Token streams are identical in `(kind, length)` start-to-end: the
        /// attributes already in storage are correct (they merely shifted with
        /// the text). Nothing needs re-application.
        case noChange
        /// Re-apply attributes to exactly this character range (already
        /// expanded to whole-token boundaries). Callers reset the body
        /// attributes over this range and re-run the per-token styling for any
        /// token intersecting it.
        case window(NSRange)
        /// The diff could not be trusted (nil/empty token history, wildly
        /// divergent counts, or a structural inconsistency). Fall back to the
        /// whole-document path.
        case fullDocument
    }

    /// Diff `oldTokens` against `newTokens` and return the restyle decision.
    ///
    /// - Parameters:
    ///   - oldTokens: tokens from BEFORE the edit (the coordinator's
    ///     `lastTokens`). Empty/nil history forces a full-document restyle.
    ///   - newTokens: tokens derived from the post-edit text.
    ///   - storageLength: the post-edit `NSTextStorage.length`. Used as the
    ///     window's hard upper bound and as a structural sanity check.
    static func decide(
        oldTokens: [Token],
        newTokens: [Token],
        storageLength: Int
    ) -> Decision {
        // No prior tokens to diff against (initial load, external apply) → full.
        guard !oldTokens.isEmpty else { return .fullDocument }
        // Edit emptied the document, or token derivation produced nothing for a
        // non-empty doc: cheap enough and avoids edge-case windows → full.
        guard !newTokens.isEmpty else { return .fullDocument }

        let oldCount = oldTokens.count
        let newCount = newTokens.count

        // Front walk: tokens that match in (kind, length) from the start are
        // unshifted and unchanged.
        var front = 0
        let frontLimit = min(oldCount, newCount)
        while front < frontLimit,
              tokensEquivalent(oldTokens[front], newTokens[front]) {
            front += 1
        }

        // Back walk: tokens that match in (kind, length) from the end shifted
        // by the length delta but carried their attributes with them.
        var back = 0
        let backLimit = frontLimit - front
        while back < backLimit,
              tokensEquivalent(
                oldTokens[oldCount - 1 - back],
                newTokens[newCount - 1 - back]) {
            back += 1
        }

        // Whole stream matched → nothing to restyle.
        if front == newCount && back == 0 && oldCount == newCount {
            return .noChange
        }

        // The changed window in NEW-token space is [front ... newCount-1-back].
        let firstChanged = front
        let lastChanged = newCount - 1 - back

        // Structural inconsistency (shouldn't happen given the walks above) →
        // be conservative and restyle the whole document.
        guard firstChanged <= lastChanged,
              firstChanged >= 0,
              lastChanged < newCount else {
            return .fullDocument
        }

        // Expand to whole-token boundaries on both sides: the window is the
        // union of the changed tokens' ranges. Tokens can overlap (e.g. a
        // line-element token plus an inline taskBody token inside it), so take
        // min-location / max-end across the changed span rather than assuming
        // monotonic ordering.
        var lower = newTokens[firstChanged].range.location
        var upper = NSMaxRange(newTokens[firstChanged].range)
        for i in firstChanged...lastChanged {
            let r = newTokens[i].range
            // A malformed range (negative location, or past storage) means we
            // can't trust the window math → full document.
            guard r.location >= 0, NSMaxRange(r) <= storageLength else {
                return .fullDocument
            }
            lower = min(lower, r.location)
            upper = max(upper, NSMaxRange(r))
        }

        guard lower >= 0, upper <= storageLength, lower <= upper else {
            return .fullDocument
        }
        return .window(NSRange(location: lower, length: upper - lower))
    }

    /// Equality on `(kind, length)` — deliberately ignores `location`.
    private static func tokensEquivalent(_ a: Token, _ b: Token) -> Bool {
        a.range.length == b.range.length && a.kind == b.kind
    }
}

/// The window the TYPING path paints (`performDeferredRestyle` and
/// `paintLiveWindowed`): a character diff, not a token diff (Editor AREA.md,
/// "Restyle, scroll and typewriter").
enum TypingRestyleWindow {
    /// Smallest BLOCK-aligned character range (in NEW-text coordinates)
    /// covering everything that changed between `old` and `new`, via a common-
    /// prefix / common-suffix scan (the divergence is localized near the edit,
    /// so this is cheap even on a long document). Returns nil when identical or
    /// the new text is empty. Token-free, so it works for plain prose.
    ///
    /// Expanded to whole blank-line blocks, not just lines, because a line's
    /// styling can depend on the other lines of its block: a table's header is
    /// bold only while the delimiter row below it is valid, a figure line is a
    /// figure only while it is alone in its paragraph, emphasis is
    /// paragraph-scoped, and a screenplay cue's trailing `^` makes the dialogue
    /// under it dual. A line-only window left those lines stale
    /// (`WindowedTypographyEquivalenceTests`' typing-path legs).
    static func changedBlockWindow(old: NSString, new: NSString) -> NSRange? {
        guard let lines = changedLineWindow(old: old, new: new) else { return nil }
        return widenToBlankLineBlocks(lines, in: new)
    }

    /// How far (UTF-16 units) the widening may grow on EACH side of the
    /// changed lines. Blocks are op-log paragraphs, normally a few hundred
    /// units; a table or a screenplay dialogue block fits with room to spare.
    /// The cap exists for a document with no blank lines at all (single
    /// newlines between paragraphs), whose one "block" is the whole text: an
    /// uncapped widening would repaint it whole on every settle and bring back
    /// the scroll snap. Past the cap, a context-dependent line further away
    /// than this stays stale until the next whole-document paint (theme,
    /// typography, attach).
    static let maxWideningPerSide = 6_000

    /// `range` grown backward and forward over every non-blank line next to
    /// it, so it starts and ends on a blank line (or the text's ends), but by
    /// no more than `maxWideningPerSide` (plus the line that crosses it) on
    /// each side.
    static func widenToBlankLineBlocks(_ range: NSRange, in text: NSString) -> NSRange {
        var lower = range.location
        while lower > 0, range.location - lower < maxWideningPerSide {
            let previous = text.lineRange(for: NSRange(location: lower - 1, length: 0))
            if isBlank(previous, in: text) { break }
            lower = previous.location
        }
        var upper = NSMaxRange(range)
        while upper < text.length, upper - NSMaxRange(range) < maxWideningPerSide {
            let next = text.lineRange(for: NSRange(location: upper, length: 0))
            if isBlank(next, in: text) || next.length == 0 { break }
            upper = NSMaxRange(next)
        }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func isBlank(_ line: NSRange, in text: NSString) -> Bool {
        for i in line.location..<NSMaxRange(line) {
            switch text.character(at: i) {
            case 0x20, 0x09, 0x0A, 0x0D: continue
            default: return false
            }
        }
        return true
    }

    /// The changed range expanded to whole lines (`paragraphRange`).
    private static func changedLineWindow(old: NSString, new: NSString) -> NSRange? {
        let oldLen = old.length, newLen = new.length
        if newLen == 0 { return nil }
        var prefix = 0
        let maxPrefix = min(oldLen, newLen)
        while prefix < maxPrefix,
              old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix == oldLen, prefix == newLen { return nil }  // identical
        var suffix = 0
        let maxSuffix = min(oldLen, newLen) - prefix
        while suffix < maxSuffix,
              old.character(at: oldLen - 1 - suffix)
                == new.character(at: newLen - 1 - suffix) { suffix += 1 }
        let loc = min(prefix, newLen - 1)
        let len = max(0, min(newLen - prefix - suffix, newLen - loc))
        return new.paragraphRange(for: NSRange(location: loc, length: len))
    }
}
