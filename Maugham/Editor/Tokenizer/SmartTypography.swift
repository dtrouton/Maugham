import Foundation
import MaughamCore

/// Computes optional auto-replacements for typographic input:
/// `--` -> em dash, `...` -> ellipsis, `"` / `'` -> curly quotes.
public enum SmartTypography {

    /// The result of a smart-typography transform: the substitute glyph and
    /// the full NSRange that the coordinator should pass to `insertText(_:replacementRange:)`.
    /// Carrying the range here means the coordinator never has to back-compute how
    /// many preceding characters to consume — that split was the source of the
    /// selection-corruption bug (finding 1.1).
    public struct TransformResult: Equatable {
        public let substitute: String
        public let range: NSRange
        public init(substitute: String, range: NSRange) {
            self.substitute = substitute
            self.range = range
        }
    }

    /// Returns a `TransformResult` if the user's replacement should be auto-transformed;
    /// otherwise nil. The `range` in the result already accounts for any preceding
    /// ASCII run that the substitute replaces (e.g. the leading "-" for em-dash).
    ///
    /// **Em-dash and ellipsis are suppressed when `replacementRange.length > 0`.**
    /// A non-empty replacement range means the user is replacing a selection; the
    /// preceding dashes/dots are part of existing text and must not be consumed.
    /// Smart quotes fire on selections too (they just curl the replacement).
    public static func transform(
        currentText: String,
        replacementRange: NSRange,
        replacement: String,
        settings: TypographySettings
    ) -> TransformResult? {
        // Em dash: replacement "-" preceded by another "-".
        // Guard: only on a caret insert (no selection) — a selection being replaced
        // must never have its range expanded backward to eat the selection.
        if settings.emDashAutoReplace, replacement == "-",
           replacementRange.length == 0,
           replacementRange.location > 0 {
            let nsText = currentText as NSString
            let prevRange = NSRange(location: replacementRange.location - 1, length: 1)
            if nsText.substring(with: prevRange) == "-" {
                // This runs in `shouldChangeTextIn` — BEFORE the just-typed "-"
                // is in the storage — so the range covers ONLY the existing
                // preceding "-". The newly-typed "-" is suppressed (the
                // coordinator returns false); the "—" substitute stands in for
                // it. Consuming length 2 here would eat the character AFTER the
                // caret, which isn't the new dash (it isn't in the string yet).
                let fullRange = NSRange(
                    location: replacementRange.location - 1,
                    length: 1)
                return TransformResult(substitute: "—", range: fullRange)
            }
        }

        // Ellipsis: replacement "." preceded by "..".
        // Same caret-only guard as em-dash.
        if settings.ellipsisAutoReplace, replacement == ".",
           replacementRange.length == 0,
           replacementRange.location >= 2 {
            let nsText = currentText as NSString
            let prevRange = NSRange(location: replacementRange.location - 2, length: 2)
            if nsText.substring(with: prevRange) == ".." {
                // Don't transform "1.0.0" — only when not preceded by a digit.
                if replacementRange.location >= 3 {
                    let beforeDots = NSRange(
                        location: replacementRange.location - 3, length: 1)
                    let prefixChar = nsText.substring(with: beforeDots)
                    if let scalar = prefixChar.unicodeScalars.first,
                       CharacterSet.decimalDigits.contains(scalar) {
                        return nil
                    }
                }
                // Pre-insert: covers ONLY the two existing preceding dots. The
                // just-typed "." is suppressed (coordinator returns false) and
                // the "…" stands in for it. Length 3 would eat the character
                // after the caret (the new "." isn't in the string yet).
                let fullRange = NSRange(
                    location: replacementRange.location - 2,
                    length: 2)
                return TransformResult(substitute: "…", range: fullRange)
            }
        }

        // Smart double quote — fires on selections too (curls the replacement).
        if settings.smartQuotes, replacement == "\"" {
            let glyph = isOpeningContext(text: currentText, at: replacementRange.location)
                ? "\u{201C}" : "\u{201D}"
            return TransformResult(substitute: glyph, range: replacementRange)
        }

        // Smart single quote — fires on selections too.
        if settings.smartQuotes, replacement == "'" {
            let glyph = isOpeningContext(text: currentText, at: replacementRange.location)
                ? "\u{2018}" : "\u{2019}"
            return TransformResult(substitute: glyph, range: replacementRange)
        }

        return nil
    }

    /// True when the cursor is at the start of input or after whitespace —
    /// we should produce an opening curly quote. Otherwise, closing.
    private static func isOpeningContext(text: String, at location: Int) -> Bool {
        guard location > 0 else { return true }
        let nsText = text as NSString
        guard location <= nsText.length else { return true }
        let prev = nsText.substring(
            with: NSRange(location: location - 1, length: 1))
        if prev.isEmpty { return true }
        if let scalar = prev.unicodeScalars.first,
           CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return true
        }
        return false
    }
}
