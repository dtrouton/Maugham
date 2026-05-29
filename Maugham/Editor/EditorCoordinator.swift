import Foundation
import MaughamCore
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

    /// Fired inside `textDidChange` just before the binding setter writes
    /// the new text. Delivers the post-edit caret position so that
    /// Document's V2 task-anchor alignment can see where the cursor ended
    /// up after the keystroke that produced this change. nil when not
    /// wired (legacy / test surfaces — alignment degrades to per-paragraph
    /// per spec §2.4.3).
    var onPostEditCursor: ((Int) -> Void)?

    /// Fired when the cursor's screenplay element changes. Delivers the gutter
    /// abbreviation ("CHAR", "SCENE", "DLG", etc.) or nil when no script is
    /// parsed (prose mode) or the cursor isn't on a classified line. Mirrors
    /// the same delivery points as onCursorChanged: selection change and after
    /// every retokenize (text edits can change the element under the cursor
    /// without moving the selection).
    var onElementChanged: ((String?) -> Void)?

    /// Optional resolver for wiki-link titles. When set, ProseMode underlines
    /// `[[Title]]` tokens whose title resolves to a manuscript document.
    var wikiLinkResolver: ((String) -> Bool)?

    /// Id-returning resolver used by mouseDown click routing. Returns
    /// the doc id if the title resolves, nil otherwise.
    var wikiLinkResolverForClick: ((String) -> String?)?

    /// Called when the text view receives a paste with image content on the
    /// pasteboard. The handler saves the image and returns the Markdown
    /// reference string to insert at the cursor, or nil if the paste should
    /// fall through to standard NSTextView behavior. Nil for non-research-note
    /// editing (manuscript documents, screenplays — standard paste applies).
    var imagePasteHandler: ((NSImage) -> String?)?

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

    /// Observer token for `maughamNavigateToScene` notifications.
    private var navigateObserver: NSObjectProtocol?

    /// Observer token for `maughamFindMatchSelected` notifications.
    private var findMatchObserver: NSObjectProtocol?

    /// Observer token for `maughamEffectiveAppearanceChanged` notifications.
    private var appearanceObserver: NSObjectProtocol?

    /// Observer token for `maughamNavigateToParagraph` notifications, used
    /// to scroll the textView to the paragraph an annotation is anchored
    /// to when the user clicks an annotation row.
    private var paragraphNavigateObserver: NSObjectProtocol?

    /// Closure that maps a paragraph_id to its NSRange in textView.string.
    /// Set by EditorSurface.updateNSView so the coordinator can resolve
    /// ranges against the live Document's `displayRange(forParagraphId:)`.
    var paragraphRangeProvider: ((String) -> NSRange?)?

    /// Resolves a doc-wide UTF-16 location to the containing paragraph_id
    /// and the offset (in the same UTF-16 space) within that paragraph's
    /// text. Wired by EditorHost from `Document.paragraphId(at:)` +
    /// `displayRange(forParagraphId:)`. Used by the checkbox click path.
    var paragraphLocator: ((Int) -> (paragraphId: String, offsetWithinParagraph: Int)?)?

    /// Closure invoked when the user clicks a checkbox glyph — either the
    /// 3-char markdown `- [ ]` / `- [x]` bracket or the 5-char Fountain
    /// `[[todo:]]` / `[[done:]]` prefix. Delivers the paragraph id, the
    /// UTF-16 offset within that paragraph's text, and the marker kind
    /// (so the host can dispatch to `flipBracket` for `.markdown` or
    /// `flipTodoDone` for `.fountain`). The host wires this to
    /// `Document.setParagraph(id:text:)`. Routing the flip through
    /// `setParagraph` keeps the mutation on the standard `.typingBurst`
    /// path and out of the cloud-conflict-only `applyExternalText` channel
    /// (see tripwire #7 / area #2).
    var checkboxToggleHandler: ((String, Int, MaughamCheckboxKind) -> Void)?

    /// Number of times applyExternalText has been called. Internal so
    /// @testable importers (EditorIntegrationHarness) can assert invariants
    /// about typing not triggering external-text replacement. Production
    /// never reads this.
    internal private(set) var applyExternalTextCallCount: Int = 0

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
        super.init()
        // NotificationCenter posts these on `.main` so we're on the main
        // thread when the closures fire, but the closure types aren't
        // @MainActor-annotated. `MainActor.assumeIsolated` bridges the gap
        // without an extra Task hop (and asserts in debug if we're wrong
        // about being on the main thread).
        navigateObserver = NotificationCenter.default.addObserver(
            forName: .maughamNavigateToScene,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let location = note.userInfo?["lineLocation"] as? Int,
                      let textView = self.textView else { return }
                self.navigateToLine(at: location, in: textView)
            }
        }
        findMatchObserver = NotificationCenter.default.addObserver(
            forName: .maughamFindMatchSelected,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let match = note.userInfo?["match"] as? SearchMatch,
                      let textView = self.textView else { return }

                // Defer to allow the document load to complete first.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    let range = match.charRangeInDocument
                    guard let storage = textView.textStorage,
                          range.location + range.length <= storage.length else { return }
                    textView.setSelectedRange(range)
                    textView.scrollRangeToVisible(range)
                }
            }
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .maughamEffectiveAppearanceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Re-run the full appearance pass so background/caret/syntax
                // highlight colors re-resolve against the new effective appearance.
                self.applyAppearance(theme: self.theme, typography: self.typography)
            }
        }
        paragraphNavigateObserver = NotificationCenter.default.addObserver(
            forName: .maughamNavigateToParagraph,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let pid = note.userInfo?["paragraph_id"] as? String,
                      let textView = self.textView,
                      let provider = self.paragraphRangeProvider,
                      let range = provider(pid) else { return }
                let length = (textView.string as NSString).length
                guard range.location >= 0,
                      range.location + range.length <= length else { return }
                // Position a cursor (length 0) at paragraph start rather
                // than selecting the whole paragraph. Selecting the entire
                // range was disorienting when navigating from the Tasks
                // pane — the writer's "jump to this task" became "select
                // the whole containing paragraph including unrelated
                // text." A future refinement could thread an
                // intra-paragraph offset through the notification to land
                // exactly on the task line; for now, paragraph start is
                // close enough and avoids the surprising selection.
                let cursor = NSRange(location: range.location, length: 0)
                textView.setSelectedRange(cursor)
                textView.scrollRangeToVisible(range)
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    deinit {
        if let token = navigateObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = findMatchObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = appearanceObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = paragraphNavigateObserver {
            NotificationCenter.default.removeObserver(token)
        }
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
        applyExternalTextCallCount += 1
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

    /// Returns the (paragraphId, offsetWithinParagraph, kind) for the
    /// bracket glyph at the given character index, or nil if the index
    /// is not on a checkbox bracket. Reads `MaughamCheckboxAttr` from the
    /// text storage so painted bracket regions are recognized without a
    /// fresh tokenization pass. The paragraph mapping uses
    /// `paragraphLocator` (wired by EditorHost via `Document`). The `kind`
    /// flags whether the click landed on a 3-char markdown `[ ]`/`[x]`
    /// glyph or a 5-char Fountain `todo:`/`done:` prefix so the host
    /// dispatches to the correct flipper.
    func checkboxHitTest(
        atCharacterIndex index: Int
    ) -> (paragraphId: String, offsetWithinParagraph: Int, kind: MaughamCheckboxKind)? {
        guard let textView,
              let storage = textView.textStorage,
              index >= 0, index < storage.length else { return nil }
        let raw = storage.attribute(MaughamCheckboxAttr, at: index,
                                    effectiveRange: nil)
        guard let marker = raw as? MaughamCheckboxMarker else { return nil }
        // Use the marker's authoritative bracket location (the stamp time)
        // rather than `index` so a click anywhere within the glyph resolves
        // to the bracket start.
        guard let mapping = paragraphLocator?(marker.bracketLocation) else {
            return nil
        }
        return (paragraphId: mapping.paragraphId,
                offsetWithinParagraph: mapping.offsetWithinParagraph,
                kind: marker.kind)
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
        // Notify subscribers (e.g., scene navigator) that the script changed.
        if let script = lastParsedScript {
            NotificationCenter.default.post(
                name: .maughamScriptDidUpdate,
                object: script)
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
        // Text changes require re-dim. The textDidChange path delegates here;
        // no separate dim call needed.
        applyFocusDim(in: textView)
        // Fire element callback: text edits can reclassify the line under the
        // cursor without moving the selection, so we must fire here too (not
        // only from textViewDidChangeSelection).
        onElementChanged?(currentElementAbbreviation(in: textView))
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
        // Skip the cursor-restore when a Tab cycle is in flight — the cycle
        // method sets the cursor explicitly AFTER didChangeText (e.g.,
        // inside the opening paren on Parenthetical wrap), and the restore
        // would clobber that intent. Capture the flag now since `defer` in
        // cycle() will reset it before the async block fires.
        let skipCursorRestore = isApplyingTabCycle
        let postEditSelection = textView.selectedRange()
        // Notify the host of the post-edit caret position so Document's
        // V2 task-anchor alignment can read it inside the immediately-
        // following setFullText call. Must fire BEFORE binding-set so the
        // host has a chance to stash the value on the Document.
        onPostEditCursor?(postEditSelection.location)
        binding.wrappedValue = textView.string
        retokenizeAndStyle()
        // Autocomplete trigger deferred — see milestone-3b notes.
        if !skipCursorRestore {
            // Sync restore covers paste-induced cursor jostle from
            // storage.endEditing() — that happens during retokenizeAndStyle
            // synchronously, so the cursor is at its final position by the
            // time we check here. Any earlier async restore was racy under
            // rapid typing: queued main.async blocks vs queued key events
            // don't have guaranteed order on the next runloop tick, so the
            // restore could fire BEFORE the next textDidChange and force
            // the cursor back into the middle of a word the user just typed
            // forward through. The sync check below is sufficient for the
            // jostle case and has no race because it runs on the same
            // dispatch as the keystroke that triggered it.
            if textView.selectedRange() != postEditSelection {
                textView.setSelectedRange(postEditSelection)
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
        if typewriterScroll {
            scrollSelectionToVerticalCenter(in: textView)
        }
        // Cursor-only selection changes (arrow keys, click) don't go through
        // retokenizeAndStyle. Re-dim here.
        applyFocusDim(in: textView)
        onCursorChanged?(textView.selectedRange().location)
        onElementChanged?(currentElementAbbreviation(in: textView))
    }

    // MARK: - Tab/Shift+Tab cycle

    private func cycleElementForward(in textView: NSTextView) {
        cycle(in: textView, direction: .forward)
    }

    private func cycleElementBackward(in textView: NSTextView) {
        cycle(in: textView, direction: .backward)
    }

    /// Returns the gutter abbreviation (e.g. "CHAR", "SCENE", "DLG") for
    /// the line containing the current cursor position, or nil when no
    /// screenplay is parsed (prose mode) or the cursor isn't on a classified
    /// line with a label.
    private func currentElementAbbreviation(in textView: NSTextView) -> String? {
        guard let script = lastParsedScript else { return nil }
        let cursor = textView.selectedRange().location
        guard let line = script.lines.first(where: { line in
            line.range.contains(cursor) ||
                cursor == NSMaxRange(line.range)
        }) else {
            return nil
        }
        return ElementGutterView.abbreviation(for: line.element)
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
            let targetCursor = NSRange(location: result.cursorOffset, length: 0)
            textView.setSelectedRange(targetCursor)
            // Defensive reapply on the next runloop in case something
            // (theme refresh, layout pass) moves the cursor.
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                if textView.selectedRange() != targetCursor {
                    textView.setSelectedRange(targetCursor)
                }
            }
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
        let targetCursor = NSRange(location: cursorLocation, length: 0)
        textView.setSelectedRange(targetCursor)
        // Defensive reapply on the next runloop.
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            if textView.selectedRange() != targetCursor {
                textView.setSelectedRange(targetCursor)
            }
        }

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
        // Bound-check the range against current storage — lastParsedScript
        // can be momentarily stale relative to textView.string (selection-
        // change fires before textDidChange + retokenizeAndStyle re-parses).
        let storageLength = (textView.string as NSString).length
        guard NSMaxRange(activeLine.range) <= storageLength else {
            autocompleter.dismiss()
            return
        }
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

    private func navigateToLine(at location: Int, in textView: NSTextView) {
        let storage = textView.textStorage
        let length = (storage?.string as NSString?)?.length ?? 0
        let clamped = max(0, min(location, length))
        let range = NSRange(location: clamped, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
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
        // Centering computes negative Y near the top of the document and
        // overshoots near the bottom; clamp to the legitimate document
        // range so NSScrollView doesn't round-trip through a clamped value
        // and produce a visible jump on each keystroke.
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maxY = max(0, documentHeight - visible.height)
        let rawTarget = lineRect.midY - visible.height / 2
        let clampedY = max(0, min(rawTarget, maxY))
        // Skip the call entirely if we're already within a pixel of the
        // target — avoids a no-op scroll that NSScrollView still treats
        // as a relayout event and which can perturb a typing-mid-paragraph
        // cursor's apparent position.
        if abs(clampedY - visible.origin.y) < 0.5 { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
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
