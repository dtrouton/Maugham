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
    func applyTypography(
        in storage: NSTextStorage,
        theme: Theme,
        typography: TypographySettings,
        tokens: [Token]
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
}
