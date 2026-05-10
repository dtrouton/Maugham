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
        let resolved = theme.resolved(systemAppearanceIsDark: Self.systemIsDark())
        let palette = resolved.palette
        let baseFont = baseFont(for: typography)
        let charWidth = Self.charWidth(font: baseFont)
        let bodyAttrs = bodyAttributes(palette: palette, baseFont: baseFont,
                                       typography: typography)

        storage.beginEditing()
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.setAttributes(bodyAttrs, range: fullRange)

        // First pass — per-line element styling driven by tokens.
        for token in tokens {
            guard NSMaxRange(token.range) <= storage.length else { continue }
            guard case let .fountainElement(element, _) = token.kind else { continue }
            let attrs = self.attributes(
                for: element,
                palette: palette,
                baseFont: baseFont,
                charWidth: charWidth,
                typography: typography)
            storage.addAttributes(attrs, range: token.range)
        }

        // Second pass — inline note spans within otherwise-non-note lines.
        // Re-parse to access inlineSpans (cheap; ~1ms on a feature script).
        let script = parser.parse(storage.string)
        let italic = NSFont(
            descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
            size: baseFont.pointSize) ?? baseFont
        let dimColor = dim(palette.syntaxPunctuation, alpha: 0.4)
        for line in script.lines where !line.inlineSpans.isEmpty {
            // Skip lines that are entirely .note — they're already styled.
            if line.element == .note { continue }
            for span in line.inlineSpans {
                guard NSMaxRange(span.range) <= storage.length else { continue }
                if span.kind == .note {
                    storage.addAttributes(
                        [.font: italic, .foregroundColor: dimColor],
                        range: span.range)
                }
            }
        }

        // Third pass — fade forced-syntax markers (@, ., >, ~, #, =, parens,
        // [[ ]], /* */). The body text retains its element styling; only the
        // syntactic marker characters get the dimmed syntaxPunctuation color.
        // Mirrors prose mode's quiet-syntax treatment of ** asterisks.
        for line in script.lines {
            for markerRange in markerRanges(in: line, storage: storage) {
                guard NSMaxRange(markerRange) <= storage.length else { continue }
                storage.addAttribute(
                    .foregroundColor,
                    value: palette.syntaxPunctuation,
                    range: markerRange)
            }
        }

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
        paragraph.alignment = .left
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

    private static func charWidth(font: NSFont) -> CGFloat {
        let sample = "the quick brown fox jumps over the lazy dog"
        let width = (sample as NSString).size(withAttributes: [.font: font]).width
        return width / CGFloat(sample.count)
    }

    private func attributes(
        for element: ScreenplayElement,
        palette: ThemePalette,
        baseFont: NSFont,
        charWidth: CGFloat,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        switch element {
        case .action:
            return [:]
        case .sceneHeading:
            let font = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                size: baseFont.pointSize) ?? baseFont
            return [.font: font]
        case .character:
            return [.paragraphStyle: paragraphStyle(
                head: charWidth * 22, tail: charWidth * 60,
                alignment: .left, typography: typography, baseFont: baseFont)]
        case .dialogue:
            return [.paragraphStyle: paragraphStyle(
                head: charWidth * 10, tail: charWidth * 45,
                alignment: .left, typography: typography, baseFont: baseFont)]
        case .parenthetical:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            return [
                .paragraphStyle: paragraphStyle(
                    head: charWidth * 15, tail: charWidth * 35,
                    alignment: .left, typography: typography, baseFont: baseFont),
                .font: italic]
        case .transition:
            let bold = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                size: baseFont.pointSize) ?? baseFont
            return [
                .paragraphStyle: paragraphStyle(
                    head: 0, tail: charWidth * 60,
                    alignment: .right, typography: typography, baseFont: baseFont),
                .font: bold]
        case .centered:
            let bold = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                size: baseFont.pointSize) ?? baseFont
            return [
                .paragraphStyle: paragraphStyle(
                    head: 0, tail: charWidth * 60,
                    alignment: .center, typography: typography, baseFont: baseFont),
                .font: bold]
        case .lyric:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            return [.font: italic]
        case .section:
            let bold = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                size: baseFont.pointSize) ?? baseFont
            return [
                .font: bold,
                .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .synopsis:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            return [
                .font: italic,
                .foregroundColor: dim(palette.syntaxPunctuation, alpha: 0.6)]
        case .boneyard, .note:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            return [
                .font: italic,
                .foregroundColor: dim(palette.syntaxPunctuation, alpha: 0.4)]
        case .pageBreak:
            return [
                .paragraphStyle: paragraphStyle(
                    head: 0, tail: charWidth * 60,
                    alignment: .center, typography: typography, baseFont: baseFont),
                .foregroundColor: dim(palette.syntaxPunctuation, alpha: 0.4)]
        case .titlePage:
            return [
                .foregroundColor: dim(palette.syntaxPunctuation, alpha: 0.4)]
        }
    }

    private func dim(_ color: NSColor, alpha: CGFloat) -> NSColor {
        color.withAlphaComponent(alpha)
    }

    private func paragraphStyle(
        head: CGFloat,
        tail: CGFloat,
        alignment: NSTextAlignment,
        typography: TypographySettings,
        baseFont: NSFont
    ) -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = head
        para.headIndent = head
        para.tailIndent = tail
        para.alignment = alignment
        para.lineSpacing = max(0,
            baseFont.pointSize * CGFloat(typography.lineHeightMultiplier - 1.0))
        para.paragraphSpacing =
            baseFont.pointSize * CGFloat(typography.paragraphSpacingMultiplier)
        return para
    }

    /// Returns the NSRanges of forced-syntax marker characters in a parsed
    /// FountainLine. Used by applyTypography's marker-fade pass.
    private func markerRanges(
        in line: FountainLine,
        storage: NSTextStorage
    ) -> [NSRange] {
        let lineStart = line.range.location
        let lineLength = line.range.length
        guard lineLength > 0,
              lineStart + lineLength <= storage.length else { return [] }
        let lineText = (storage.string as NSString)
            .substring(with: line.range)
        // Strip trailing newline for prefix/suffix checks.
        let trimmed = lineText.hasSuffix("\n")
            ? String(lineText.dropLast())
            : lineText
        let trimmedLength = (trimmed as NSString).length

        var ranges: [NSRange] = []

        // Single-char leading markers: @, !, ., >, ~
        if line.isForced {
            switch line.element {
            case .character:
                if trimmed.hasPrefix("@") {
                    ranges.append(NSRange(location: lineStart, length: 1))
                }
            case .action:
                if trimmed.hasPrefix("!") {
                    ranges.append(NSRange(location: lineStart, length: 1))
                }
            case .sceneHeading:
                if trimmed.hasPrefix(".") && !trimmed.hasPrefix("..") {
                    ranges.append(NSRange(location: lineStart, length: 1))
                }
            case .transition:
                if trimmed.hasPrefix(">") {
                    // > or "> ". Fade the > and the optional following space.
                    let withSpace = trimmed.hasPrefix("> ")
                    ranges.append(NSRange(
                        location: lineStart,
                        length: withSpace ? 2 : 1))
                }
            case .lyric:
                if trimmed.hasPrefix("~") {
                    ranges.append(NSRange(location: lineStart, length: 1))
                }
            default:
                break
            }
        }

        // Section: 1-6 leading # followed by a space.
        if case .section = line.element {
            var hashCount = 0
            for ch in trimmed {
                if ch == "#" { hashCount += 1 } else { break }
            }
            if hashCount >= 1 && hashCount <= 6
                && trimmed.count > hashCount
                && trimmed[trimmed.index(trimmed.startIndex, offsetBy: hashCount)] == " " {
                ranges.append(NSRange(
                    location: lineStart,
                    length: hashCount + 1))
            }
        }

        // Synopsis: leading "= ".
        if line.element == .synopsis && trimmed.hasPrefix("= ") {
            ranges.append(NSRange(location: lineStart, length: 2))
        }

        // Parenthetical: leading ( and trailing ).
        if line.element == .parenthetical
            && trimmed.hasPrefix("(") && trimmed.hasSuffix(")")
            && trimmedLength >= 2 {
            ranges.append(NSRange(location: lineStart, length: 1))
            ranges.append(NSRange(
                location: lineStart + trimmedLength - 1, length: 1))
        }

        // Centered: leading > and trailing <.
        if line.element == .centered
            && trimmed.hasPrefix(">") && trimmed.hasSuffix("<")
            && trimmedLength >= 2 {
            ranges.append(NSRange(location: lineStart, length: 1))
            ranges.append(NSRange(
                location: lineStart + trimmedLength - 1, length: 1))
        }

        // Boneyard: line containing /* and/or */.
        if line.element == .boneyard {
            let ns = trimmed as NSString
            let openRange = ns.range(of: "/*")
            if openRange.location != NSNotFound {
                ranges.append(NSRange(
                    location: lineStart + openRange.location, length: 2))
            }
            let closeRange = ns.range(of: "*/")
            if closeRange.location != NSNotFound {
                ranges.append(NSRange(
                    location: lineStart + closeRange.location, length: 2))
            }
        }

        // Note (block): line containing [[ and/or ]].
        if line.element == .note {
            let ns = trimmed as NSString
            let openRange = ns.range(of: "[[")
            if openRange.location != NSNotFound {
                ranges.append(NSRange(
                    location: lineStart + openRange.location, length: 2))
            }
            let closeRange = ns.range(of: "]]")
            if closeRange.location != NSNotFound {
                ranges.append(NSRange(
                    location: lineStart + closeRange.location, length: 2))
            }
        }

        return ranges
    }
}
