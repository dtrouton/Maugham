import Foundation
import AppKit

/// Metrics computed by a writing mode for a given manuscript text.
public struct EditorMetrics: Equatable, Sendable {
    public var wordCount: Int
    public var characterCount: Int
    public var readingMinutes: Int

    public init(wordCount: Int, characterCount: Int, readingMinutes: Int) {
        self.wordCount = wordCount
        self.characterCount = characterCount
        self.readingMinutes = readingMinutes
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
    /// return the substitution; otherwise nil.
    func smartTypographyTransform(
        currentText: String,
        replacementRange: NSRange,
        replacement: String,
        settings: TypographySettings
    ) -> String?

    /// Compute metrics for the manuscript.
    func metrics(_ text: String) -> EditorMetrics
}
