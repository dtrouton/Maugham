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

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              !isApplyingExternalUpdate else { return }
        // Capture the post-edit cursor position. retokenizeAndStyle mutates
        // storage attributes which can jostle NSTextView's selection (most
        // visibly after paste of a multi-char string). We restore the
        // captured range both synchronously (in case the move is in
        // retokenizeAndStyle) and on the next runloop tick (in case it's an
        // async layout-pass effect from storage.endEditing).
        let postEditSelection = textView.selectedRange()
        binding.wrappedValue = textView.string
        retokenizeAndStyle()
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
        if typewriterScroll {
            scrollSelectionToVerticalCenter(in: textView)
        }
        applyFocusDim(in: textView)
        onCursorChanged?(textView.selectedRange().location)
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
