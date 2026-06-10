import Foundation
import MaughamCore
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
        return tokens(from: script, text: text)
    }

    /// Derive syntax tokens from an already-parsed `FountainScript` without
    /// re-parsing. `text` must be the same source `script` was parsed from —
    /// it's needed for the boneyard discriminator's NSString substring work.
    /// `retokenizeAndStyle` parses once and threads the script through both this
    /// and `applyTypography(parsedScript:)`, avoiding the redundant per-keystroke
    /// re-parses (see CLAUDE.md P1-editor / Editor AREA.md).
    func tokens(from script: FountainScript, text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        var tokens: [Token] = script.lines.map { line in
            Token(
                range: line.range,
                kind: .fountainElement(line.element,
                                       isForced: line.isForced,
                                       isDualSecond: line.isDualSecond))
        }
        // Inline `[[todo:]]` / `[[done:]]` boneyard discriminator. Each
        // occurrence emits a `.checkbox` token over the 5-char `todo:` /
        // `done:` prefix; the paint pass in `applyTypography` stamps
        // `MaughamCheckboxAttr` over that range so mouseDown's hit-test
        // can fire without re-scanning. The body and surrounding `[[ ]]`
        // continue to render under the existing `.note` line-element /
        // inline-note span path.
        let ns = text as NSString
        for line in script.lines {
            guard line.range.length > 0,
                  NSMaxRange(line.range) <= ns.length else { continue }
            let lineText = ns.substring(with: line.range)
            for hit in FountainBoneyardScanner.matchTodoAllFull(lineText) {
                // Shift ranges from lineText-local to doc-wide UTF-16 space.
                let docPrefix = NSRange(
                    location: line.range.location + hit.prefixRange.location,
                    length: hit.prefixRange.length)
                guard NSMaxRange(docPrefix) <= ns.length else { continue }
                tokens.append(Token(
                    range: docPrefix,
                    kind: .checkbox(checked: hit.done)))

                // taskBody: covers the body inside [[ ]] (after "todo:/done:")
                if hit.bodyRange.length > 0 {
                    let docBody = NSRange(
                        location: line.range.location + hit.bodyRange.location,
                        length: hit.bodyRange.length)
                    if NSMaxRange(docBody) <= ns.length {
                        tokens.append(Token(
                            range: docBody, kind: .taskBody(done: hit.done)))
                    }
                }

                // invisibleAnchor: the `<!--t-XXXXXX-->` span glued after `]]`
                if hit.anchorRange.location != NSNotFound {
                    let docAnchor = NSRange(
                        location: line.range.location + hit.anchorRange.location,
                        length: hit.anchorRange.length)
                    if NSMaxRange(docAnchor) <= ns.length {
                        tokens.append(Token(range: docAnchor, kind: .invisibleAnchor))
                    }
                }
            }
        }
        return tokens
    }

    public func smartTypographyTransform(
        currentText: String,
        replacementRange: NSRange,
        replacement: String,
        settings: TypographySettings
    ) -> SmartTypography.TransformResult? {
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
        tokens: [Token],
        parsedScript: FountainScript? = nil,
        restyleWindow: NSRange? = nil
    ) {
        let resolved = theme.resolved(systemAppearanceIsDark: Self.systemIsDark())
        let palette = resolved.palette
        let baseFont = baseFont(for: typography)
        let charWidth = Self.charWidth(font: baseFont)
        let bodyAttrs = bodyAttributes(palette: palette, baseFont: baseFont,
                                       typography: typography)

        // The character range whose *structural* attributes (body reset +
        // per-element/inline/marker styling) get re-applied. nil → whole doc.
        // Clamped to storage bounds so a stale window can't over-run.
        let fullStorage = NSRange(location: 0, length: storage.length)
        let window = restyleWindow.map {
            NSIntersectionRange($0, fullStorage)
        } ?? fullStorage
        // A token participates in the structural passes iff it intersects the
        // window. With a whole-doc window this is always true (the legacy path).
        func inWindow(_ range: NSRange) -> Bool {
            NSIntersectionRange(range, window).length > 0
                // Zero-length tokens (empty trailing line) intersect the window
                // when their location falls within it.
                || (range.length == 0
                    && range.location >= window.location
                    && range.location <= NSMaxRange(window))
        }

        storage.beginEditing()
        storage.setAttributes(bodyAttrs, range: window)

        // Use the caller's pre-parsed script when supplied (the hot
        // per-keystroke path threads ONE parse through tokenize + here); fall
        // back to parsing `storage.string` for resolver-less / test callers.
        // `storage.string == textView.string` at the production call site, so
        // the threaded script is identical to what this would parse.
        let script = parsedScript ?? parser.parse(storage.string)
        let hasTitlePage = (script.titlePage != nil)

        // First pass — per-line element styling driven by tokens.
        var isFirstBody = true

        for token in tokens {
            guard NSMaxRange(token.range) <= storage.length else { continue }
            guard case let .fountainElement(element, _, isDualSecond) = token.kind
            else { continue }

            // Skip titlePage elements (handled by applyTitlePageStyling).
            if case .titlePage = element { continue }

            // `isFirstBody` is POSITIONAL — it must advance for the first body
            // token in document order whether or not that token is inside the
            // restyle window, so a windowed pass that lands entirely below the
            // first body element still attributes the rest of the document
            // identically to the whole-doc path. Capture-then-advance is cheap
            // (no per-token script lookup), so it stays OUTSIDE the window guard.
            let tokenIsFirstBody = isFirstBody
            isFirstBody = false

            // Out-of-window tokens keep their (shifted-correct) attributes; skip
            // attribute synthesis + write. `isDualSecond` rides on the token
            // itself (part of token identity — see Token.Kind), so the old O(N)
            // per-token script search is gone on every path.
            guard inWindow(token.range) else { continue }

            var attrs = self.attributes(
                for: element,
                isDualSecond: isDualSecond,
                palette: palette,
                baseFont: baseFont,
                charWidth: charWidth,
                typography: typography)

            // Add paragraph spacing before the first body element when there's
            // a title page above.
            if hasTitlePage && tokenIsFirstBody {
                let mutable: NSMutableParagraphStyle
                if let existing = attrs[.paragraphStyle] as? NSParagraphStyle {
                    mutable = (existing.mutableCopy() as! NSMutableParagraphStyle)
                } else {
                    mutable = NSMutableParagraphStyle()
                }
                mutable.paragraphSpacingBefore = baseFont.pointSize * 2.0
                attrs[.paragraphStyle] = mutable
            }

            storage.addAttributes(attrs, range: token.range)
        }

        // Second pass — inline emphasis/note spans within otherwise-non-note lines.
        // We already have script from the early parse above; no need to re-parse.
        for line in script.lines where !line.inlineSpans.isEmpty {
            // Skip lines that are entirely .note — they're already styled.
            if line.element == .note { continue }
            for span in line.inlineSpans {
                guard NSMaxRange(span.range) <= storage.length else { continue }
                guard inWindow(span.range) else { continue }
                applyInlineSpan(span, in: storage, palette: palette,
                                baseFont: baseFont)
            }
        }

        // Third pass — fade forced-syntax markers (@, ., >, ~, #, =, parens,
        // [[ ]], /* */). The body text retains its element styling; only the
        // syntactic marker characters get the dimmed syntaxPunctuation color.
        // Mirrors prose mode's quiet-syntax treatment of ** asterisks.
        for line in script.lines {
            // Skip the substring/marker scan entirely for lines outside the
            // window — their markers already carry the (shifted-correct) fade.
            guard inWindow(line.range) else { continue }
            for markerRange in markerRanges(in: line, storage: storage) {
                guard NSMaxRange(markerRange) <= storage.length else { continue }
                guard inWindow(markerRange) else { continue }
                storage.addAttribute(
                    .foregroundColor,
                    value: palette.syntaxPunctuation,
                    range: markerRange)
            }
        }

        // Fourth pass — per-key title page styling. Runs after the per-element
        // pass so the new styling overrides T1's placeholder dim for .titlePage.
        applyTitlePageStyling(
            in: storage,
            script: script,
            palette: palette,
            baseFont: baseFont,
            typography: typography,
            inWindow: inWindow)

        // Fifth pass — paint `MaughamCheckboxAttr` over each `[[todo:]]` /
        // `[[done:]]` prefix found in tokens. CRITICAL: this must run AFTER
        // the full-storage `setAttributes` at the top (which clears all
        // attributes) so the marker survives the re-paint. `addAttributes`
        // here is purely additive — it does not disturb the per-element
        // foregroundColor / paragraphStyle already painted above. See
        // CLAUDE.md tripwire: ScreenplayMode.applyTypography uses full-
        // storage setAttributes and any range-specific attribute embedded
        // in that dictionary would be wiped on the next retokenize.
        for token in tokens {
            guard case .checkbox(let checked) = token.kind else { continue }
            guard NSMaxRange(token.range) <= storage.length else { continue }
            let marker = MaughamCheckboxMarker(
                bracketLocation: token.range.location,
                checked: checked,
                kind: .fountain)
            let attrs: [NSAttributedString.Key: Any] = [
                .cursor: NSCursor.pointingHand,
                MaughamCheckboxAttr: marker,
            ]
            storage.addAttributes(attrs, range: token.range)
        }

        // Sixth pass — task body and anchor styling. Applied post-setAttributes
        // (mirrors the checkbox pass above) so these attributes survive the
        // full-storage wipe. No race risk: addAttributes is purely additive.
        for token in tokens {
            guard NSMaxRange(token.range) <= storage.length else { continue }
            if case .taskBody(let done) = token.kind {
                var attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: palette.syntaxPunctuation,
                ]
                if done {
                    attrs[.strikethroughStyle] =
                        NSUnderlineStyle.single.rawValue
                    attrs[.strikethroughColor] = palette.syntaxPunctuation
                }
                storage.addAttributes(attrs, range: token.range)
            } else if case .invisibleAnchor = token.kind {
                storage.addAttributes(
                    [.foregroundColor: NSColor.clear],
                    range: token.range)
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

    /// Test seam for the cross-surface `ScreenplayEmphasis` contract: the
    /// bold/italic this editor applies to `element`, read off the resolved font
    /// traits. Layout (indents/alignment) and palette colour are intentionally
    /// out of the contract and not reflected here. See `ScreenplayEmphasis` and
    /// `ScreenplayEmphasisContractTests`.
    func contractEmphasis(for element: ScreenplayElement) -> ScreenplayEmphasis {
        let base = baseFont(for: .screenplayDefaults)
        let attrs = attributes(
            for: element, isDualSecond: false, palette: .light,
            baseFont: base, charWidth: Self.charWidth(font: base),
            typography: .screenplayDefaults)
        let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        let underline = (attrs[.underlineStyle] as? Int).map {
            $0 & NSUnderlineStyle.single.rawValue != 0
        } ?? false
        return ScreenplayEmphasis(
            bold: traits.contains(.bold), italic: traits.contains(.italic),
            underline: underline)
    }

    private func attributes(
        for element: ScreenplayElement,
        isDualSecond: Bool,
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
            let head: CGFloat = isDualSecond ? charWidth * 42 : charWidth * 22
            let tail: CGFloat = charWidth * 60
            return [.paragraphStyle: paragraphStyle(
                head: head, tail: tail,
                alignment: .left, typography: typography, baseFont: baseFont)]
        case .dialogue:
            let head: CGFloat = isDualSecond ? charWidth * 32 : charWidth * 10
            let tail: CGFloat = isDualSecond ? charWidth * 58 : charWidth * 45
            return [.paragraphStyle: paragraphStyle(
                head: head, tail: tail,
                alignment: .left, typography: typography, baseFont: baseFont)]
        case .parenthetical:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            let head: CGFloat = isDualSecond ? charWidth * 37 : charWidth * 15
            let tail: CGFloat = isDualSecond ? charWidth * 53 : charWidth * 35
            return [
                .paragraphStyle: paragraphStyle(
                    head: head, tail: tail,
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

    private func applyInlineSpan(
        _ span: FountainInlineSpan,
        in storage: NSTextStorage,
        palette: ThemePalette,
        baseFont: NSFont
    ) {
        switch span.kind {
        case .note:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            storage.addAttributes(
                [.font: italic, .foregroundColor: dim(palette.syntaxPunctuation, alpha: 0.4)],
                range: span.range)

        case .emphasis(let traits):
            // span.range is content (markers already excluded by the tokenizer).
            // applyTrait composes, so calling it twice yields bold+italic.
            if traits.contains(.bold) {
                applyTrait(.bold, in: storage, range: span.range, baseFont: baseFont)
            }
            if traits.contains(.italic) {
                applyTrait(.italic, in: storage, range: span.range, baseFont: baseFont)
            }

        case .emphasisMarker:
            fadeMarker(in: storage, location: span.range.location,
                       length: span.range.length, palette: palette)

        case .underline:
            let markerLen = 1
            let inner = NSRange(
                location: span.range.location + markerLen,
                length: span.range.length - markerLen * 2)
            storage.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: inner)
            fadeMarker(in: storage, location: span.range.location, length: 1,
                       palette: palette)
            fadeMarker(in: storage,
                       location: span.range.location + span.range.length - 1,
                       length: 1, palette: palette)
        }
    }

    private func applyTrait(
        _ trait: NSFontDescriptor.SymbolicTraits,
        in storage: NSTextStorage,
        range: NSRange,
        baseFont: NSFont
    ) {
        guard NSMaxRange(range) <= storage.length else { return }
        // Compose with any existing font traits at the range — read each
        // run's current font, INSERT the new trait, re-apply.
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let current = (value as? NSFont) ?? baseFont
            var traits = current.fontDescriptor.symbolicTraits
            traits.insert(trait)
            if let composed = NSFont(
                descriptor: current.fontDescriptor.withSymbolicTraits(traits),
                size: current.pointSize) {
                storage.addAttribute(.font, value: composed, range: subrange)
            }
        }
    }

    private func fadeMarker(
        in storage: NSTextStorage,
        location: Int,
        length: Int,
        palette: ThemePalette
    ) {
        let range = NSRange(location: location, length: length)
        guard NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.foregroundColor,
                             value: palette.syntaxPunctuation,
                             range: range)
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

        // Trailing ^ marker for dual-dialogue second cue. Fades the ^ and any
        // single space immediately before it. Applies to both forced (@steve ^)
        // and unforced (STEVE ^) cues.
        if line.element == .character && line.isDualSecond {
            // Search for the LAST ^ in the trimmed line text, then map back
            // to the line range in storage.
            if let caretIdx = trimmed.lastIndex(of: "^") {
                let caretOffset = trimmed.distance(from: trimmed.startIndex, to: caretIdx)
                let caretNSLocation = lineStart + caretOffset
                // Include a single trailing space before the ^ in the fade range.
                let includeSpace = caretOffset > 0
                    && trimmed[trimmed.index(before: caretIdx)] == " "
                let fadeStart = caretNSLocation - (includeSpace ? 1 : 0)
                let fadeLength = 1 + (includeSpace ? 1 : 0)
                ranges.append(NSRange(location: fadeStart, length: fadeLength))
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

    /// Apply per-key title page styling. Called from applyTypography after
    /// the per-element styling pass. Each field's line gets per-key paragraph
    /// and font attributes (applied to the full line so NSTextStorage paragraph-
    /// style coalescing works correctly); the key prefix then gets faded to
    /// palette.syntaxPunctuation color.
    private func applyTitlePageStyling(
        in storage: NSTextStorage,
        script: FountainScript,
        palette: ThemePalette,
        baseFont: NSFont,
        typography: TypographySettings,
        inWindow: (NSRange) -> Bool = { _ in true }
    ) {
        guard let titlePage = script.titlePage else { return }
        for field in titlePage {
            guard NSMaxRange(field.range) <= storage.length else { continue }
            guard inWindow(field.range) else { continue }
            let lineSource = (storage.string as NSString)
                .substring(with: field.range)

            // Find the colon position — the key is everything before, value is after.
            guard let colonIdx = lineSource.firstIndex(of: ":") else { continue }
            let keyLength = lineSource.distance(
                from: lineSource.startIndex, to: colonIdx) + 1  // include the ":"
            let keyRange = NSRange(
                location: field.range.location, length: keyLength)

            // Apply paragraph and font styling to the FULL line range so that
            // NSTextStorage's paragraph-level attribute coalescing works correctly.
            // (Paragraph style attributes applied to a sub-range of a paragraph
            // are silently discarded by NSTextStorage.)
            let lineAttrs = titlePageValueAttributes(
                key: field.key, palette: palette,
                baseFont: baseFont, typography: typography)
            storage.addAttributes(lineAttrs, range: field.range)

            // Fade the key in syntaxPunctuation color (overrides any foreground
            // color set by lineAttrs for the key portion).
            storage.addAttribute(
                .foregroundColor, value: palette.syntaxPunctuation,
                range: keyRange)
        }
    }

    /// The shared per-key treatment this surface uses for a title-page key.
    /// Sourced from the cross-surface contract; exposed (internal) so the
    /// contract test can assert the Mac consumes `TitlePageFieldStyle.style`.
    static func titlePageStyle(forKey key: String) -> TitlePageFieldStyle {
        TitlePageFieldStyle.style(forKey: key)
    }

    private func titlePageValueAttributes(
        key: String,
        palette: ThemePalette,
        baseFont: NSFont,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        let style = ScreenplayMode.titlePageStyle(forKey: key)

        let para = NSMutableParagraphStyle()
        para.lineSpacing = max(0,
            baseFont.pointSize * CGFloat(typography.lineHeightMultiplier - 1.0))
        para.alignment = (style.alignment == .center) ? .center : .left

        var traits = baseFont.fontDescriptor.symbolicTraits
        if style.bold { traits.insert(.bold) }
        if style.italic { traits.insert(.italic) }
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        let font = NSFont(
            descriptor: descriptor,
            size: baseFont.pointSize * CGFloat(style.scale)) ?? baseFont

        var attrs: [NSAttributedString.Key: Any] = [
            .paragraphStyle: para,
            .font: font,
        ]
        if style.dimmed {
            attrs[.foregroundColor] = palette.syntaxPunctuation
        }
        return attrs
    }
}
