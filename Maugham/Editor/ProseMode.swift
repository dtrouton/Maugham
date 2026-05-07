import Foundation
import AppKit

/// Markdown-flavored prose mode. Used by EditorSurface for `.md` documents.
public struct ProseMode: WritingMode {
    private let tokenizer: MarkdownTokenizer
    private static let wordsPerMinute = 200

    public init(tokenizer: MarkdownTokenizer = MarkdownTokenizer()) {
        self.tokenizer = tokenizer
    }

    public func tokenize(_ text: String) -> [Token] {
        tokenizer.tokenize(text)
    }

    public func smartTypographyTransform(
        currentText: String,
        replacementRange: NSRange,
        replacement: String,
        settings: TypographySettings
    ) -> String? {
        SmartTypography.transform(
            currentText: currentText,
            replacementRange: replacementRange,
            replacement: replacement,
            settings: settings)
    }

    public func metrics(_ text: String) -> EditorMetrics {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.isEmpty
            ? 0
            : trimmed.split(whereSeparator: \.isWhitespace).count
        let chars = (text as NSString).length
        let mins = words / Self.wordsPerMinute
        return EditorMetrics(
            wordCount: words,
            characterCount: chars,
            readingMinutes: mins
        )
    }

    public func applyTypography(
        in storage: NSTextStorage,
        theme: Theme,
        typography: TypographySettings,
        tokens: [Token]
    ) {
        let resolved = theme.resolved(systemAppearanceIsDark: false)
        let palette = resolved.palette
        let baseFont = baseFont(for: typography)
        let bodyAttrs = bodyAttributes(palette: palette, baseFont: baseFont,
                                       typography: typography)

        storage.beginEditing()
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.setAttributes(bodyAttrs, range: fullRange)

        for token in tokens {
            guard NSMaxRange(token.range) <= storage.length else { continue }
            let attrs = attributes(
                for: token.kind, palette: palette, baseFont: baseFont)
            storage.addAttributes(attrs, range: token.range)
        }
        storage.endEditing()
    }

    public func bodyTypingAttributes(
        theme: Theme,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        let resolved = theme.resolved(systemAppearanceIsDark: false)
        return bodyAttributes(
            palette: resolved.palette,
            baseFont: baseFont(for: typography),
            typography: typography)
    }

    /// Width of the body text column, in points, given the configured page
    /// width (in characters) and current font. Uses an "M" glyph as the
    /// per-character width estimate.
    public func textColumnWidth(
        typography: TypographySettings
    ) -> CGFloat {
        let font = baseFont(for: typography)
        let em = ("M" as NSString)
            .size(withAttributes: [.font: font]).width
        return em * CGFloat(typography.pageWidthCharacters)
    }

    private func baseFont(for typography: TypographySettings) -> NSFont {
        NSFont(name: typography.fontFamily, size: CGFloat(typography.fontSize))
            ?? NSFont.systemFont(ofSize: CGFloat(typography.fontSize))
    }

    private func bodyAttributes(
        palette: ThemePalette,
        baseFont: NSFont,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        // Use lineSpacing rather than lineHeightMultiple so the NSTextView
        // insertion point (which tracks line-box height) stays at glyph height.
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

    private func attributes(
        for kind: Token.Kind,
        palette: ThemePalette,
        baseFont: NSFont
    ) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .heading(let level):
            let scale: CGFloat = level == 1 ? 1.6 : level == 2 ? 1.4 : level == 3 ? 1.25 : 1.1
            let font = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                size: baseFont.pointSize * scale
            ) ?? baseFont
            return [.font: font, .foregroundColor: palette.heading]

        case .emphasis(let strong):
            let traits: NSFontDescriptor.SymbolicTraits = strong ? .bold : .italic
            let font = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(traits),
                size: baseFont.pointSize
            ) ?? baseFont
            return [.font: font]

        case .code:
            let mono = NSFont.monospacedSystemFont(
                ofSize: baseFont.pointSize - 1, weight: .regular)
            return [.font: mono, .foregroundColor: palette.code]

        case .link:
            return [.foregroundColor: palette.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue]

        case .listMarker, .blockquote, .horizontalRule:
            return [.foregroundColor: palette.syntaxPunctuation]

        case .syntaxPunctuation:
            return [.foregroundColor: palette.syntaxPunctuation]

        case .plain:
            return [:]
        }
    }
}
