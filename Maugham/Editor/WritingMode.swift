import Foundation
import MaughamCore
import AppKit

/// Metrics computed by a writing mode for a given manuscript text.
public struct EditorMetrics: Equatable, Sendable {
    public var wordCount: Int
    public var characterCount: Int
    public var readingMinutes: Int
    public var pageCount: Double?

    public init(
        wordCount: Int,
        characterCount: Int,
        readingMinutes: Int,
        pageCount: Double? = nil
    ) {
        self.wordCount = wordCount
        self.characterCount = characterCount
        self.readingMinutes = readingMinutes
        self.pageCount = pageCount
    }
}

/// Pluggable mode that classifies text and applies typography for an
/// `EditorSurface`. ProseMode (Markdown) is the milestone-1b implementation.
public protocol WritingMode: Sendable {
    /// Classify the given text into syntax-highlighting tokens.
    func tokenize(_ text: String) -> [Token]

    /// Apply theme + typography attributes to a text storage based on tokens.
    /// `parsedScript` lets a Fountain-aware mode reuse a script the caller
    /// already parsed (the `EditorCoordinator` hot path parses once and threads
    /// it through both `tokenize` and here); modes that don't parse Fountain
    /// ignore it. Defaults to `nil` so existing callers are unaffected.
    ///
    /// `restyleWindow`, when non-nil, restricts the *structural* attribute
    /// writes (the whole-storage body reset + per-token element/inline/marker
    /// passes) to that character range — the keystroke fast path, where only
    /// the classification-changed window needs re-application because
    /// NSTextStorage shifts attributes with the text automatically. Passes that
    /// stamp location-encoding attributes (checkbox markers) still run
    /// document-wide so those stamps stay current outside the window. nil
    /// (the default) applies attributes to the whole document — the contract
    /// every non-typing caller relies on. See `TokenRestyleWindow` and the
    /// Editor AREA guide.
    func applyTypography(
        in storage: NSTextStorage,
        theme: Theme,
        typography: TypographySettings,
        tokens: [Token],
        parsedScript: FountainScript?,
        restyleWindow: NSRange?
    )

    /// Attributes to use for the NSTextView's `typingAttributes` so the caret
    /// on empty lines uses the right font, color, and paragraph style.
    func bodyTypingAttributes(
        theme: Theme,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any]

    /// If the user's typed replacement should auto-transform (em dash, etc.),
    /// return a `TransformResult` carrying both the substitute glyph and the
    /// full replacement range; otherwise nil.
    func smartTypographyTransform(
        currentText: String,
        replacementRange: NSRange,
        replacement: String,
        settings: TypographySettings
    ) -> SmartTypography.TransformResult?

    /// Compute metrics for the manuscript.
    func metrics(_ text: String) -> EditorMetrics

    /// Body text column width in points, given the configured page width.
    func textColumnWidth(typography: TypographySettings) -> CGFloat

    /// Whether the per-keystroke structural restyle is DEFERRED to the trailing
    /// edge of the typing burst (`true`) or painted LIVE & windowed on every
    /// keystroke (`false`).
    ///
    /// Prose defers (the 2026-06-26 flicker fix): editing the end of an inline
    /// emphasis run produces a transient invalid CommonMark state (`*italic *`
    /// un-italicizes, markers un-fade) that would flash on each keystroke; the
    /// deferral means that state never gets painted. Screenplay paints live:
    /// nearly every line is a *different element* (slug / character / dialogue /
    /// action / transition), so a ~300ms classification lag reads as pervasive
    /// sluggishness, and its inline emphasis is comparatively rare. See the
    /// Editor AREA guide (tripwire 9). Defaults to `true` (defer) — the safe,
    /// flicker-free posture for any new prose-like mode.
    var defersRestyleWhileTyping: Bool { get }
}

public extension WritingMode {
    /// Default: defer the restyle to the typing-burst settle (flicker-free).
    /// Modes whose styling is element-classification heavy (screenplay)
    /// override this to `false` so the restyle stays live. See the protocol
    /// requirement's doc comment and the Editor AREA guide (tripwire 9).
    var defersRestyleWhileTyping: Bool { true }

    /// Word count alone, WITHOUT the full `metrics(_:)` computation. Both
    /// modes' `metrics` derive `wordCount` from this exact trimmed
    /// whitespace-split — but `ScreenplayMode.metrics` ADDITIONALLY runs a
    /// whole-document Fountain parse purely for `pageCount`. Callers that
    /// only need the word count (the per-keystroke session/word bookkeeping
    /// in `DocumentStore.recordEditorTextWrite`, project word-count rebuilds)
    /// MUST use this instead: the 2026-06-10 live profile showed the
    /// per-keystroke `metrics` call burning a full Fountain parse per
    /// keystroke for a value it discarded.
    func wordCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? 0
            : trimmed.split(whereSeparator: \.isWhitespace).count
    }

    /// Back-compat overload: whole-document attribute application (no window).
    /// Existing callers and tests that don't thread a restyle window route
    /// through here. Defaults `restyleWindow` to nil so behavior is identical
    /// to the pre-windowing contract.
    func applyTypography(
        in storage: NSTextStorage,
        theme: Theme,
        typography: TypographySettings,
        tokens: [Token],
        parsedScript: FountainScript? = nil
    ) {
        applyTypography(
            in: storage, theme: theme, typography: typography,
            tokens: tokens, parsedScript: parsedScript, restyleWindow: nil)
    }
}
