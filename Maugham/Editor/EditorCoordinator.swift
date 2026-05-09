import Foundation
import AppKit
import SwiftUI

/// NSTextViewDelegate that mediates between SwiftUI's @Binding and NSTextView.
/// Handles the isApplyingExternalUpdate guard so that external state changes
/// don't clobber the user's editing context.
@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate {
    private var binding: Binding<String>
    private let mode: any WritingMode
    private(set) var theme: Theme
    private(set) var typography: TypographySettings
    private(set) var typewriterScroll: Bool
    private(set) var sentenceFocus: Bool
    private(set) var paragraphFocus: Bool

    private var isApplyingExternalUpdate = false
    weak var textView: NSTextView?

    /// Cursor location to restore after the next attach. Set by EditorSurface
    /// when the user revisits a previously-open document.
    var initialCursorLocation: Int?

    /// Fired on every selection change with the new caret location, so the
    /// host can persist per-document cursor positions.
    var onCursorChanged: ((Int) -> Void)?

    /// Optional resolver for wiki-link titles. When set, ProseMode underlines
    /// `[[Title]]` tokens whose title resolves to a manuscript document.
    var wikiLinkResolver: ((String) -> Bool)?

    /// Id-returning resolver used by mouseDown click routing. Returns
    /// the doc id if the title resolves, nil otherwise.
    var wikiLinkResolverForClick: ((String) -> String?)?

    /// Most recent token list, captured each time we retokenize. Used by
    /// click routing to look up wiki-link ranges hit-tested by mouseDown.
    private(set) var lastTokens: [Token] = []

    /// Most recent FountainScript from ScreenplayMode parsing. nil for prose
    /// modes. Updated each time retokenizeAndStyle runs. Source for both
    /// the character autocompleter (3b) and the element gutter (3b).
    private(set) var lastParsedScript: FountainScript?

    /// Most recent cycle target on the current blank line. Cleared when:
    /// - cursor moves to a different line
    /// - any non-Tab edit triggers textDidChange
    /// - the active line gains content via the cycle's mutator
    /// Used so that subsequent Tab presses on the same blank line cycle
    /// from the prior target rather than re-computing startingElement.
    private var lastCycleTarget: ScreenplayElement?

    /// Active line's range at the moment lastCycleTarget was set; used to
    /// detect cursor moves to a different line.
    private var lastCycleTargetLineRange: NSRange?

    /// Set to true while cycle(in:direction:) is mutating storage so that
    /// textDidChange knows to leave lastCycleTarget alone.
    private var isApplyingTabCycle = false

    private let autocompleter = CharacterAutocompleter()

    init(text: Binding<String>,
         mode: any WritingMode,
         theme: Theme,
         typography: TypographySettings,
         typewriterScroll: Bool,
         sentenceFocus: Bool,
         paragraphFocus: Bool,
         wikiLinkResolver: ((String) -> Bool)? = nil) {
        self.binding = text
        self.mode = mode
        self.theme = theme
        self.typography = typography
        self.typewriterScroll = typewriterScroll
        self.sentenceFocus = sentenceFocus
        self.paragraphFocus = paragraphFocus
        self.wikiLinkResolver = wikiLinkResolver
    }

    /// Set the text view from outside (called by EditorSurface.makeNSView).
    func attach(to textView: NSTextView) {
        self.textView = textView
        applyAppearance(theme: theme, typography: typography)
        retokenizeAndStyle()
        if let location = initialCursorLocation {
            let length = (textView.string as NSString).length
            let clamped = max(0, min(location, length))
            let range = NSRange(location: clamped, length: 0)
            textView.setSelectedRange(range)
            // Defer scroll + first-responder acquisition until the textView
            // is actually in a window (it's not yet during attach).
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.scrollRangeToVisible(range)
                textView.window?.makeFirstResponder(textView)
            }
            initialCursorLocation = nil
        }
    }

    /// External (binding-side) update — replace text without disturbing user.
    func applyExternalText(_ text: String) {
        guard let textView, textView.string != text else { return }
        isApplyingExternalUpdate = true
        defer { isApplyingExternalUpdate = false }

        // Preserve cursor where possible
        let oldSelection = textView.selectedRange()
        textView.string = text
        let clamped = NSRange(
            location: min(oldSelection.location, text.utf16.count),
            length: 0
        )
        textView.setSelectedRange(clamped)
        retokenizeAndStyle()
    }

    /// Typewriter scroll setting changed — update and apply immediately.
    func applyTypewriterScroll(_ enabled: Bool) {
        self.typewriterScroll = enabled
        guard enabled, let textView else { return }
        scrollSelectionToVerticalCenter(in: textView)
    }

    /// Focus mode settings changed — update and re-dim immediately.
    func applyFocusPrefs(sentence: Bool, paragraph: Bool) {
        self.sentenceFocus = sentence
        self.paragraphFocus = paragraph
        guard let textView else { return }
        retokenizeAndStyle()
        applyFocusDim(in: textView)
    }

    /// Theme/typography changed — re-style without re-text.
    func applyAppearance(theme: Theme, typography: TypographySettings) {
        self.theme = theme
        self.typography = typography
        guard let textView else { return }
        textView.backgroundColor = theme.resolved(
            systemAppearanceIsDark: NSApp.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]) == .darkAqua
        ).palette.background
        textView.insertionPointColor = theme.resolved(
            systemAppearanceIsDark: NSApp.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]) == .darkAqua
        ).palette.caret
        retokenizeAndStyle()
    }

    /// Returns the wiki-link title at the given character index, or nil if
    /// the index is not inside a wiki-link range.
    func wikiLinkTitle(atCharacterIndex index: Int) -> String? {
        for token in lastTokens {
            if NSLocationInRange(index, token.range),
               case .wikiLink(let title) = token.kind {
                return title
            }
        }
        return nil
    }

    private func retokenizeAndStyle() {
        guard let textView, let storage = textView.textStorage else { return }
        let tokens = mode.tokenize(textView.string)
        self.lastTokens = tokens
        if mode is ScreenplayMode {
            lastParsedScript = FountainTokenizer().parse(textView.string)
        } else {
            lastParsedScript = nil
        }
        // ProseMode supports an optional wiki-link resolver for `[[Title]]`
        // styling. Other modes use the protocol's resolver-less call.
        if let prose = mode as? ProseMode {
            prose.applyTypography(
                in: storage,
                theme: theme,
                typography: typography,
                tokens: tokens,
                wikiLinkResolver: wikiLinkResolver)
        } else {
            mode.applyTypography(
                in: storage,
                theme: theme,
                typography: typography,
                tokens: tokens)
        }
        // Sync typing attributes so the caret on empty lines matches the
        // body font/paragraph style instead of the system default.
        textView.typingAttributes = mode.bodyTypingAttributes(
            theme: theme, typography: typography)
        applyFocusDim(in: textView)
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView,
                  shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        guard let replacementString,
              !isApplyingExternalUpdate else { return true }

        // Smart typography handling
        if let substitute = mode.smartTypographyTransform(
            currentText: textView.string,
            replacementRange: affectedCharRange,
            replacement: replacementString,
            settings: typography
        ) {
            // The transform returns just the substitute glyph; the coordinator
            // is responsible for consuming the preceding ASCII run that the
            // substitute replaces. Em dash eats one "-"; ellipsis eats two ".".
            var range = affectedCharRange
            if substitute == "—" && range.location > 0 {
                range = NSRange(location: range.location - 1,
                                length: range.length + 1)
            } else if substitute == "…" && range.location > 1 {
                range = NSRange(location: range.location - 2,
                                length: range.length + 2)
            }
            textView.insertText(substitute, replacementRange: range)
            return false
        }
        return true
    }

    func textView(_ textView: NSTextView,
                  doCommandBy commandSelector: Selector) -> Bool {
        guard mode is ScreenplayMode else { return false }

        if autocompleter.isVisible {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                autocompleter.moveSelectionUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                autocompleter.moveSelectionDown()
                return true
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertNewline(_:)):
                autocompleter.acceptSelection(in: textView)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                autocompleter.dismiss()
                return true
            default:
                return false
            }
        }

        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            cycleElementForward(in: textView)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            cycleElementBackward(in: textView)
            return true
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              !isApplyingExternalUpdate else { return }
        if !isApplyingTabCycle {
            lastCycleTarget = nil
            lastCycleTargetLineRange = nil
        }
        // Capture the post-edit cursor position. retokenizeAndStyle mutates
        // storage attributes which can jostle NSTextView's selection (most
        // visibly after paste of a multi-char string). We restore the
        // captured range both synchronously (in case the move is in
        // retokenizeAndStyle) and on the next runloop tick (in case it's an
        // async layout-pass effect from storage.endEditing).
        let postEditSelection = textView.selectedRange()
        binding.wrappedValue = textView.string
        retokenizeAndStyle()
        if mode is ScreenplayMode {
            updateAutocomplete(in: textView)
        }
        if textView.selectedRange() != postEditSelection {
            textView.setSelectedRange(postEditSelection)
            textView.scrollRangeToVisible(postEditSelection)
        }
        DispatchQueue.main.async { [weak textView, postEditSelection] in
            guard let textView else { return }
            if textView.selectedRange() != postEditSelection {
                textView.setSelectedRange(postEditSelection)
                // Also scroll back to the cursor: a large paste reflows the
                // layout and can drift the scroll to the top of the document.
                textView.scrollRangeToVisible(postEditSelection)
            }
        }
        if typewriterScroll {
            scrollSelectionToVerticalCenter(in: textView)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              !isApplyingExternalUpdate else { return }
        // Clear lastCycleTarget when cursor moves to a different line.
        if let lineRange = lastCycleTargetLineRange {
            let cursor = textView.selectedRange().location
            if cursor < lineRange.location || cursor > NSMaxRange(lineRange) {
                lastCycleTarget = nil
                lastCycleTargetLineRange = nil
            }
        }
        if mode is ScreenplayMode {
            updateAutocomplete(in: textView)
        }
        if typewriterScroll {
            scrollSelectionToVerticalCenter(in: textView)
        }
        applyFocusDim(in: textView)
        onCursorChanged?(textView.selectedRange().location)
    }

    // MARK: - Tab/Shift+Tab cycle

    private func cycleElementForward(in textView: NSTextView) {
        cycle(in: textView, direction: .forward)
    }

    private func cycleElementBackward(in textView: NSTextView) {
        cycle(in: textView, direction: .backward)
    }

    private enum CycleDirection { case forward, backward }

    private func cycle(in textView: NSTextView, direction: CycleDirection) {
        guard let storage = textView.textStorage,
              let script = lastParsedScript else { return }

        // Empty document: no lines in script. Treat as a single blank line
        // at position 0 with .action as the preceding context.
        if script.lines.isEmpty {
            let target: ScreenplayElement
            if let cached = lastCycleTarget {
                target = advance(from: cached, direction: direction)
            } else {
                target = ScreenplayCycle.startingElement(after: .action)
            }
            let neighborhood = LineNeighborhood(prevIsBlank: true, nextIsBlank: true)
            let result = ScreenplayLineMutator.mutate(line: "", to: target, neighborhood: neighborhood)
            let replaceRange = NSRange(location: 0, length: 0)
            guard textView.shouldChangeText(in: replaceRange, replacementString: result.text) else { return }
            isApplyingTabCycle = true
            defer { isApplyingTabCycle = false }
            storage.replaceCharacters(in: replaceRange, with: result.text)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: result.cursorOffset, length: 0))
            if result.text.isEmpty {
                lastCycleTarget = target
                lastCycleTargetLineRange = NSRange(location: 0, length: 0)
            } else {
                lastCycleTarget = nil
                lastCycleTargetLineRange = nil
            }
            return
        }

        let cursor = textView.selectedRange().location
        guard let activeLine = lineCovering(cursor: cursor, in: script) else { return }
        guard let lineIndex = script.lines.firstIndex(of: activeLine) else { return }

        let prevElement: ScreenplayElement = (lineIndex > 0)
            ? script.lines[lineIndex - 1].element
            : .action
        let isBlank = activeLine.content.isEmpty

        // Choose target.
        let target: ScreenplayElement = chooseTarget(
            activeLine: activeLine,
            prevElement: prevElement,
            isBlank: isBlank,
            direction: direction)

        // Compute neighborhood from script.
        let prevBlank = (lineIndex <= 0)
            || script.lines[lineIndex - 1].content.isEmpty
        let nextBlank = (lineIndex >= script.lines.count - 1)
            || script.lines[lineIndex + 1].content.isEmpty
        let neighborhood = LineNeighborhood(
            prevIsBlank: prevBlank,
            nextIsBlank: nextBlank)

        // Apply mutator. Note: activeLine.content has forced markers stripped,
        // but the mutator works on raw source content. We need the source text
        // of the line (without trailing newline) to pass to the mutator.
        let nsSource = textView.string as NSString
        let lineRangeLength = activeLine.range.length
        // Determine if the line's range includes a trailing newline.
        let hasTrailingNewline: Bool
        if activeLine.range.location + lineRangeLength <= nsSource.length {
            let lastCharRange = NSRange(
                location: activeLine.range.location + lineRangeLength - 1,
                length: 1)
            if lineRangeLength > 0 {
                let lastChar = nsSource.substring(with: lastCharRange)
                hasTrailingNewline = (lastChar == "\n")
            } else {
                hasTrailingNewline = false
            }
        } else {
            hasTrailingNewline = false
        }
        let sourceContentLength = hasTrailingNewline
            ? lineRangeLength - 1
            : lineRangeLength
        let sourceContent = nsSource.substring(
            with: NSRange(location: activeLine.range.location,
                          length: sourceContentLength))

        let result = ScreenplayLineMutator.mutate(
            line: sourceContent,
            to: target,
            neighborhood: neighborhood)

        // Replace only the line's content portion (not trailing newline).
        let replaceRange = NSRange(
            location: activeLine.range.location,
            length: sourceContentLength)

        // Swift undo + delegate notification dance.
        guard textView.shouldChangeText(in: replaceRange, replacementString: result.text) else { return }
        isApplyingTabCycle = true
        defer { isApplyingTabCycle = false }
        storage.replaceCharacters(in: replaceRange, with: result.text)
        textView.didChangeText()

        let cursorLocation = activeLine.range.location + result.cursorOffset
        textView.setSelectedRange(NSRange(location: cursorLocation, length: 0))

        // Update lastCycleTarget lifecycle.
        let newContentLength = (result.text as NSString).length
        let newLineRange = NSRange(
            location: activeLine.range.location,
            length: newContentLength)
        if isBlank && result.text.isEmpty {
            // Line stayed empty — preserve target for subsequent Tab.
            lastCycleTarget = target
            lastCycleTargetLineRange = newLineRange
        } else {
            lastCycleTarget = nil
            lastCycleTargetLineRange = nil
        }
    }

    private func chooseTarget(
        activeLine: FountainLine,
        prevElement: ScreenplayElement,
        isBlank: Bool,
        direction: CycleDirection
    ) -> ScreenplayElement {
        if isBlank, let cached = lastCycleTarget {
            return advance(from: cached, direction: direction)
        }
        if isBlank {
            return ScreenplayCycle.startingElement(after: prevElement)
        }
        return advance(from: activeLine.element, direction: direction)
    }

    private func advance(from element: ScreenplayElement,
                         direction: CycleDirection) -> ScreenplayElement {
        switch direction {
        case .forward:  return ScreenplayCycle.cycleForward(from: element)
        case .backward: return ScreenplayCycle.cycleBackward(from: element)
        }
    }

    private func lineCovering(cursor: Int, in script: FountainScript) -> FountainLine? {
        for line in script.lines {
            let end = line.range.location + line.range.length
            // Match if cursor strictly inside non-zero range, OR exactly at the
            // location of a zero-length line (trailing empty line).
            if line.range.length > 0 && line.range.location <= cursor && cursor < end {
                return line
            }
            if line.range.length == 0 && cursor == line.range.location {
                return line
            }
        }
        return script.lines.last
    }

    private func updateAutocomplete(in textView: NSTextView) {
        guard mode is ScreenplayMode,
              let script = lastParsedScript,
              !script.characterNames.isEmpty,
              textView.textStorage != nil else {
            autocompleter.dismiss()
            return
        }
        let cursor = textView.selectedRange().location
        guard let activeLine = lineCovering(cursor: cursor, in: script) else {
            autocompleter.dismiss()
            return
        }
        guard activeLine.element == .character else {
            autocompleter.dismiss()
            return
        }
        // Cursor must be at end of line content.
        // End of line in source: range covers content + trailing newline if
        // present. Subtract 1 if the line's source text ends with newline.
        let lineSource = (textView.string as NSString).substring(with: activeLine.range)
        let trailingNewlineLength = lineSource.hasSuffix("\n") ? 1 : 0
        let endOfLine = activeLine.range.location
            + activeLine.range.length
            - trailingNewlineLength
        guard cursor == endOfLine else {
            autocompleter.dismiss()
            return
        }
        guard !activeLine.content.isEmpty else {
            autocompleter.dismiss()
            return
        }
        // Strip @ prefix for prefix-matching.
        let prefix = activeLine.content.hasPrefix("@")
            ? String(activeLine.content.dropFirst())
            : activeLine.content
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: prefix, characterNames: script.characterNames)
        guard !suggestions.isEmpty else {
            autocompleter.dismiss()
            return
        }
        // Compute anchor rect from layout manager.
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            autocompleter.dismiss()
            return
        }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: cursor, length: 0),
            actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: container)
        rect = rect.offsetBy(dx: textView.textContainerInset.width,
                             dy: textView.textContainerInset.height)
        autocompleter.show(suggestions: suggestions,
                           anchorRect: rect,
                           relativeTo: textView)
    }

    private func scrollSelectionToVerticalCenter(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: textView.selectedRange(),
            actualCharacterRange: nil)
        let lineRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: textContainer)
        guard let scrollView = textView.enclosingScrollView else { return }
        let visible = scrollView.contentView.documentVisibleRect
        let targetY = lineRect.midY - visible.height / 2
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyFocusDim(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let useSentence = sentenceFocus
        let useParagraph = paragraphFocus && !sentenceFocus
        guard useSentence || useParagraph else { return }

        let cursor = textView.selectedRange().location
        let activeRange = useSentence
            ? FocusFinder.sentenceRange(in: textView.string, cursor: cursor)
            : FocusFinder.paragraphRange(in: textView.string, cursor: cursor)

        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }

        storage.beginEditing()
        if activeRange.location > 0 {
            dim(storage,
                in: NSRange(location: 0, length: activeRange.location))
        }
        let afterStart = NSMaxRange(activeRange)
        if afterStart < fullRange.length {
            dim(storage,
                in: NSRange(location: afterStart,
                            length: fullRange.length - afterStart))
        }
        storage.endEditing()
    }

    private func dim(_ storage: NSTextStorage, in range: NSRange) {
        storage.enumerateAttribute(
            .foregroundColor, in: range, options: []
        ) { value, subrange, _ in
            guard let color = value as? NSColor else { return }
            let dimmed = color.withAlphaComponent(0.4)
            storage.addAttribute(.foregroundColor,
                                  value: dimmed, range: subrange)
        }
    }
}
