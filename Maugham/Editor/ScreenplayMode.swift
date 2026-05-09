import Foundation
import AppKit

/// Fountain mode for `.fountain` documents. Tokenizes via FountainTokenizer,
/// applies per-element paragraph styling, and computes Final-Draft-heuristic
/// page count. Phase 3a — single-file screenplays only.
public struct ScreenplayMode: WritingMode {
    private static let wordsPerMinute = 200
    private static let canonicalPageWidthChars = 60

    private let parser: FountainTokenizer

    public init(parser: FountainTokenizer = FountainTokenizer()) {
        self.parser = parser
    }

    public func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        let script = parser.parse(text)
        return script.lines.map { line in
            Token(
                range: line.range,
                kind: .fountainElement(line.element, isForced: line.isForced))
        }
    }

    public func smartTypographyTransform(
        currentText: String,
        replacementRange: NSRange,
        replacement: String,
        settings: TypographySettings
    ) -> String? {
        nil
    }

    public func metrics(_ text: String) -> EditorMetrics {
        let script = parser.parse(text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.isEmpty
            ? 0
            : trimmed.split(whereSeparator: \.isWhitespace).count
        let chars = (text as NSString).length
        let mins = words / Self.wordsPerMinute
        return EditorMetrics(
            wordCount: words,
            characterCount: chars,
            readingMinutes: mins,
            pageCount: script.estimatedPageCount)
    }

    public func applyTypography(
        in storage: NSTextStorage,
        theme: Theme,
        typography: TypographySettings,
        tokens: [Token]
    ) {
        // Real per-element styling lands in Tasks 9 and 10. For now, set
        // a uniform monospace body so the editor renders without crashing
        // and existing smoke tests of the screenplay project type still
        // open `.fountain` files.
        let resolved = theme.resolved(systemAppearanceIsDark: Self.systemIsDark())
        let palette = resolved.palette
        let baseFont = baseFont(for: typography)
        let attrs = bodyAttributes(palette: palette, baseFont: baseFont,
                                   typography: typography)
        storage.beginEditing()
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.setAttributes(attrs, range: fullRange)
        storage.endEditing()
    }

    public func bodyTypingAttributes(
        theme: Theme,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        let resolved = theme.resolved(systemAppearanceIsDark: Self.systemIsDark())
        return bodyAttributes(palette: resolved.palette,
                              baseFont: baseFont(for: typography),
                              typography: typography)
    }

    /// Screenplay always renders at canonical 60-character width regardless of
    /// the user's prose-oriented `pageWidthCharacters` setting.
    public func textColumnWidth(typography: TypographySettings) -> CGFloat {
        let font = baseFont(for: typography)
        let sample = "the quick brown fox jumps over the lazy dog"
        let sampleWidth = (sample as NSString)
            .size(withAttributes: [.font: font]).width
        let avgCharWidth = sampleWidth / CGFloat(sample.count)
        return avgCharWidth * CGFloat(Self.canonicalPageWidthChars)
    }

    // MARK: - Helpers

    private static func systemIsDark() -> Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func baseFont(for typography: TypographySettings) -> NSFont {
        if let font = NSFont(name: typography.fontFamily,
                             size: CGFloat(typography.fontSize)) {
            return font
        }
        return NSFont.monospacedSystemFont(
            ofSize: CGFloat(typography.fontSize), weight: .regular)
    }

    private func bodyAttributes(
        palette: ThemePalette,
        baseFont: NSFont,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing =
            max(0, baseFont.pointSize * CGFloat(typography.lineHeightMultiplier - 1.0))
        paragraph.paragraphSpacing =
            baseFont.pointSize * CGFloat(typography.paragraphSpacingMultiplier)
        return [
            .font: baseFont,
            .foregroundColor: palette.bodyText,
            .paragraphStyle: paragraph,
        ]
    }
}
