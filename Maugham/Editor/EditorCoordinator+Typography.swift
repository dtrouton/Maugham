import Foundation
import MaughamCore
import AppKit
import SwiftUI

// EditorCoordinator — tokenization, styling, the deferred/live restyle
// pipeline, metrics delivery, focus dimming and typewriter centering.
// Extracted from EditorCoordinator.swift (mechanical split).
extension EditorCoordinator {
    // MARK: - Typography, restyle pipeline, metrics, focus dim

    /// Focus mode settings changed — update and re-dim immediately.
    func applyFocusPrefs(sentence: Bool, paragraph: Bool) {
        self.sentenceFocus = sentence
        self.paragraphFocus = paragraph
        guard let textView else { return }
        retokenizeAndStyle()
        applyFocusDim(in: textView)
    }

    /// The view's effective appearance changed (OS light/dark flip, or the app's
    /// appearance under Follow System). Called DIRECTLY by the owning
    /// `MaughamTextView.viewDidChangeEffectiveAppearance` — one delegate hop, no
    /// NotificationCenter broadcast — so only THIS view's coordinator restyles,
    /// never every live coordinator (including leaked ones). AppKit also fires the
    /// underlying callback on a view's first mount, so this no-ops when the
    /// effective appearance name is unchanged since the last handled change.
    func effectiveAppearanceDidChange() {
        guard !isDetached, let textView else { return }
        let name = textView.effectiveAppearance.name
        guard name != lastEffectiveAppearanceName else { return }
        lastEffectiveAppearanceName = name
        applyAppearance(theme: theme, typography: typography)
    }

    /// Theme/typography changed — re-style without re-text.
    func applyAppearance(theme: Theme, typography: TypographySettings) {
        self.theme = theme
        self.typography = typography
        guard !isDetached, let textView else { return }
        applyAppearanceCount += 1
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

    /// Re-tokenize the whole document and apply typography.
    ///
    /// `windowedTyping` is set to `true` ONLY from the `textDidChange` typing
    /// path. When true, the structural attribute application is restricted to
    /// the classification-changed window (diffed against `lastTokens` via
    /// `TokenRestyleWindow`) instead of the whole document — the keystroke
    /// fast path (see Editor AREA.md / `WindowedTypographyEquivalenceTests`).
    /// Every other caller (initial attach, `applyExternalText`, theme /
    /// typography / focus changes) leaves it `false` and gets the whole-doc
    /// application, which is the contract those paths rely on. Tokenization
    /// itself is always whole-document either way.
    func retokenizeAndStyle(windowedTyping: Bool = false,
                                    nativizedText: String? = nil) {
        guard let textView, let storage = textView.textStorage else { return }
        // Bridge the AppKit-backed string to NATIVE Swift storage before any
        // scanning. `textView.string` is NSString-backed ("foreign"): every
        // Character/Substring walk over it pays per-character objc_msgSend —
        // the 2026-06-10 live profile showed FountainTokenizer 5–20× slower
        // on foreign strings than the native ones our headless tests use.
        // One O(N) UTF-8 copy here makes the whole-doc tokenize run at
        // native speed.
        //
        // One nativization per keystroke: textDidChange nativizes once and
        // threads the SAME string here (it is byte-identical to
        // textView.string — assigned in the same MainActor slice with no
        // intervening edit). Other callers (attach, applyExternalText, theme)
        // pass nil and self-nativize. The windowed-diff storageLength guard
        // still falls back to whole-doc on any mismatch.
        var text: String
        if let nativizedText {
            text = nativizedText
        } else {
            text = textView.string
            text.makeContiguousUTF8()
        }
        // P1-editor: parse the Fountain script EXACTLY ONCE per keystroke and
        // thread it through token derivation + styling + the scene-navigator
        // notification, instead of parsing the whole document three times
        // (tokenize, lastParsedScript, applyTypography). O(N²)→O(N) when typing
        // a long screenplay. The prose path doesn't parse Fountain and is
        // unchanged. See Editor AREA.md and the hardening plan task 4.7.
        let tokens: [Token]
        if let screenplay = mode as? ScreenplayMode {
            // Always parse (even empty text → `.empty`) so `lastParsedScript`
            // and the scene-navigator notification keep their prior payload;
            // `tokens(from:text:)` returns `[]` for empty text on its own.
            let script = FountainTokenizer().parse(text)
            lastParsedScript = script
            tokens = screenplay.tokens(from: script, text: text)
        } else {
            tokens = mode.tokenize(text)
            lastParsedScript = nil
        }
        self.lastTokens = tokens
        // Notify subscribers (e.g., scene navigator) that the script changed.
        // On the typing fast path, coalesce to a trailing edge so the scene
        // navigator's per-keystroke deep-compare + per-row walks don't run on
        // every key. Whole-doc callers post immediately. See AREA tripwire 4
        // and `scriptUpdateNotifyTask`.
        if let script = lastParsedScript {
            postScriptDidUpdate(script, debounced: windowedTyping)
        }
        // Deliver precomputed metrics on the SAME timing as the script post:
        // coalesced to the trailing edge while typing, immediate for whole-doc
        // callers. The page count rides `lastParsedScript` (no extra parse); the
        // word count is one whitespace split of the already-nativized `text`.
        // This supersedes EditorHost's `metricsMirrorTask`. See spec §7.
        deliverMetrics(text: text, debounced: windowedTyping)
        // Sync typing attributes so the caret on empty lines matches the
        // body font/paragraph style instead of the system default. Cheap and
        // non-visual-churn, so it stays live on both paths.
        textView.typingAttributes = mode.bodyTypingAttributes(
            theme: theme, typography: typography)
        // The actual visual repaint (applyTypography + focus-dim). On the typing
        // fast path this is DEFERRED to the trailing edge of the burst so the
        // styling doesn't re-render on every keystroke — that's what stops the
        // transient-invalid-state flicker (e.g. `*italic *` while editing the
        // end of an emphasis run). All other callers paint synchronously.
        if windowedTyping {
            if mode.defersRestyleWhileTyping {
                // Prose: the burst baseline text was captured in shouldChangeTextIn
                // on the first edit; the settle paint windows the restyle to the
                // changed paragraphs at the trailing edge of the burst (no paint
                // on the keystroke, so a transient invalid emphasis state can't
                // flicker).
                scheduleDeferredRestyle()
            } else {
                // Screenplay: paint live (windowed) on the keystroke — its
                // element-classification styling would lag visibly behind a
                // settle delay. Windowed, so no whole-doc relayout / scroll snap.
                paintLiveWindowed(text: text, in: storage, tokens: tokens)
            }
        } else {
            // Whole-doc paint: every non-typing caller (attach, applyExternalText,
            // theme/typography/focus changes) repaints the entire document.
            burstBaselineText = nil
            applyModeTypography(in: storage, tokens: tokens, restyleWindow: nil)
            applyFocusDim(in: textView)
            // Re-baseline the live (screenplay) windowed path against the freshly
            // repainted whole-doc text so its next keystroke diffs correctly.
            liveRestyleBaseline = text
        }
        // Fire element callback: text edits can reclassify the line under the
        // cursor without moving the selection, so we must fire here too (not
        // only from textViewDidChangeSelection). Compute stays live on both
        // paths, so the status footer / gutter element stay responsive.
        onElementChanged?(currentElementAbbreviation(in: textView))
    }

    /// Applies the mode's structural typography to `storage`. ProseMode supports
    /// an optional wiki-link resolver for `[[Title]]` styling; other modes use
    /// the protocol's resolver-less call. `restyleWindow == nil` is whole-doc.
    /// Shared by the synchronous restyle path and the deferred settle paint.
    private func applyModeTypography(
        in storage: NSTextStorage,
        tokens: [Token],
        restyleWindow: NSRange?
    ) {
        if let prose = mode as? ProseMode {
            prose.applyTypography(
                in: storage, theme: theme, typography: typography,
                tokens: tokens, wikiLinkResolver: wikiLinkResolver,
                restyleWindow: restyleWindow)
        } else {
            mode.applyTypography(
                in: storage, theme: theme, typography: typography,
                tokens: tokens, parsedScript: lastParsedScript,
                restyleWindow: restyleWindow)
        }
    }

    /// Live (non-deferred) restyle for element-heavy modes (screenplay). Paints
    /// on every keystroke — but WINDOWED to the changed paragraph(s), diffed
    /// against `liveRestyleBaseline` (the text as of the last paint) — so a
    /// local `setAttributes` never invalidates whole-doc layout or snaps the
    /// scroll origin (Editor AREA tripwire 9). The first paint after attach has
    /// no baseline and paints whole-doc. Cursor restore is handled by the caller
    /// (`textDidChange`) after `retokenizeAndStyle` returns, so none is needed
    /// here. `liveRestyleBaseline` is advanced to the new text on the way out.
    private func paintLiveWindowed(
        text: String, in storage: NSTextStorage, tokens: [Token]
    ) {
        guard let textView else { return }
        defer { liveRestyleBaseline = text }
        let window: NSRange?
        if let baseline = liveRestyleBaseline {
            guard let changed = changedParagraphWindow(
                old: baseline as NSString, new: text as NSString) else {
                // Text unchanged (e.g. a no-op smart-typography transform) —
                // nothing structural to repaint; just refresh the focus dim.
                applyFocusDim(in: textView)
                return
            }
            window = changed
        } else {
            window = nil   // first paint since attach: whole-doc
        }
        applyModeTypography(in: storage, tokens: tokens, restyleWindow: window)
        applyFocusDim(in: textView)
    }

    /// Schedule the deferred (settle) repaint for the typing fast path. Cancel-
    /// and-reschedule on every keystroke so it fires once, ~`restyleSettleDelayMs`
    /// after the last key. The paint is whole-document (the burst's window-diff
    /// baseline is stale by settle time) and preserves the caret + scroll
    /// position itself, since a whole-doc `setAttributes` invalidates layout and
    /// would otherwise snap a long scrolled document toward the top (Editor AREA
    /// tripwire 9). During the burst no paint happens, so the existing emphasis
    /// attributes simply shift with the text (NSTextStorage) and nothing flips.
    private func scheduleDeferredRestyle() {
        deferredRestyleTask?.cancel()
        let delay = restyleSettleDelayMs
        deferredRestyleTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            self.deferredRestyleTask = nil
            self.performDeferredRestyle()
        }
    }

    /// The settle paint: restyle from the latest live tokens, scoped to the
    /// paragraph window the burst changed (character-diffed against
    /// `burstBaselineText`). A windowed `setAttributes` leaves the rest of the
    /// document's layout — and the scroll position AppKit settled on while
    /// following the caret — untouched, so no scroll handling is needed. Only
    /// the rare no-baseline fallback paints whole-doc, and only it captures /
    /// restores the scroll origin (the snap-to-top guard, Editor AREA tripwire 9).
    private func performDeferredRestyle() {
        guard let textView, let storage = textView.textStorage else { return }
        let baseline = burstBaselineText
        burstBaselineText = nil
        let selection = textView.selectedRange()

        if let baseline {
            guard let window = changedParagraphWindow(
                old: baseline as NSString, new: storage.string as NSString) else {
                // No textual change (e.g. a transform that produced identical
                // text) — just refresh the dim; scroll/attrs already correct.
                applyFocusDim(in: textView)
                onElementChanged?(currentElementAbbreviation(in: textView))
                return
            }
            applyModeTypography(in: storage, tokens: lastTokens, restyleWindow: window)
            applyFocusDim(in: textView)
            if textView.selectedRange() != selection {
                textView.setSelectedRange(selection)
            }
            if typewriterScroll {
                scrollSelectionToVerticalCenter(in: textView)
            }
            // Typewriter off: a local restyle doesn't move scroll — leave it.
        } else {
            // No baseline (defensive: shouldn't happen on the typing path).
            // Whole-doc relayout snaps the origin toward the top; capture before
            // and restore after (or re-center when typewriter is on).
            let scrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin
            applyModeTypography(in: storage, tokens: lastTokens, restyleWindow: nil)
            applyFocusDim(in: textView)
            if textView.selectedRange() != selection {
                textView.setSelectedRange(selection)
            }
            if typewriterScroll {
                scrollSelectionToVerticalCenter(in: textView)
            } else if let origin = scrollOrigin,
                      let scrollView = textView.enclosingScrollView,
                      scrollView.contentView.bounds.origin != origin {
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        onElementChanged?(currentElementAbbreviation(in: textView))
    }

    /// Smallest paragraph-aligned character range (in NEW-text coordinates)
    /// covering everything that changed between `old` and `new`, via a common-
    /// prefix / common-suffix scan (the divergence is localized near the edit,
    /// so this is cheap even on a long document). Expanded to whole paragraphs so
    /// paragraph-level attributes re-apply cleanly. Returns nil when identical or
    /// the new text is empty. Token-free, so it works for plain prose.
    private func changedParagraphWindow(old: NSString, new: NSString) -> NSRange? {
        let oldLen = old.length, newLen = new.length
        if newLen == 0 { return nil }
        var prefix = 0
        let maxPrefix = min(oldLen, newLen)
        while prefix < maxPrefix,
              old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix == oldLen, prefix == newLen { return nil }  // identical
        var suffix = 0
        let maxSuffix = min(oldLen, newLen) - prefix
        while suffix < maxSuffix,
              old.character(at: oldLen - 1 - suffix)
                == new.character(at: newLen - 1 - suffix) { suffix += 1 }
        let loc = min(prefix, newLen - 1)
        let len = max(0, min(newLen - prefix - suffix, newLen - loc))
        return new.paragraphRange(for: NSRange(location: loc, length: len))
    }

    /// Posts `.maughamScriptDidUpdate` carrying `script`. When `debounced`,
    /// coalesces to a ~350ms trailing edge (cancel-and-reschedule), so the
    /// scene navigator's deep-compare + per-row walks fire once per typing
    /// burst rather than once per keystroke. When not debounced (whole-doc
    /// callers), cancels any in-flight debounced post first — so a stale
    /// script post can't land AFTER an immediate whole-doc one — then posts
    /// synchronously. `deinit` and `applyExternalText`/`attach` cancel the
    /// pending task, so a doc switch mid-debounce never strands a stale
    /// script post on the new document's navigator.
    private func postScriptDidUpdate(_ script: FountainScript, debounced: Bool) {
        // Channel A scoping (ADR 0021): deliver only to windows on the
        // originating project. A receiver adopting a foreign project's script
        // would re-lay-out its editor and clobber its scene-navigator payload.
        // NOT a key-window guard — a background window's own MCP-driven
        // re-parse must still update its navigator. A nil origin
        // (non-manuscript surface) never reaches here (only ScreenplayMode
        // posts), and if it ever did, only the `MaughamEvent.post` is skipped —
        // the cancel/reschedule bookkeeping the doc comment above promises
        // stays UNCONDITIONAL, so a nil-origin call can't strand a stale
        // in-flight debounced post (tripwire 3/6/7 debounce-race class).
        let projectId = scriptOriginProjectId
        guard debounced else {
            scriptUpdateNotifyTask?.cancel()
            scriptUpdateNotifyTask = nil
            if let projectId {
                MaughamEvent.post(
                    .maughamScriptDidUpdate, to: .project(id: projectId), object: script)
            }
            return
        }
        scriptUpdateNotifyTask?.cancel()
        scriptUpdateNotifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.scriptUpdateNotifyTask = nil
            if let projectId {
                MaughamEvent.post(
                    .maughamScriptDidUpdate, to: .project(id: projectId), object: script)
            }
        }
    }

    /// Compute `EditorMetrics` for `text` WITHOUT a fresh whole-doc parse on
    /// the screenplay path: the page count reads the keystroke's own
    /// `lastParsedScript`, and the word/character counts come from the same
    /// trimmed whitespace split `WritingMode.metrics` uses (so the footer and
    /// the session/word bookkeeping in `DocumentStore.recordEditorTextWrite`
    /// can't drift apart — both go through `WritingMode.wordCount`). Prose mode
    /// is already parse-free, so it delegates to `mode.metrics` unchanged.
    private func computeMetrics(text: String) -> EditorMetrics {
        guard let script = lastParsedScript else {
            // Prose (and any non-Fountain mode): metrics is parse-free already.
            return mode.metrics(text)
        }
        let words = mode.wordCount(text)
        return EditorMetrics(
            wordCount: words,
            characterCount: (text as NSString).length,
            readingMinutes: words / ScreenplayMode.wordsPerMinute,
            pageCount: script.estimatedPageCount)
    }

    /// Delivers precomputed metrics through `onMetricsChanged`, on the same
    /// timing discipline as `postScriptDidUpdate`: coalesced to a ~350ms
    /// trailing edge while typing (so a burst pays one whitespace split), and
    /// immediate for whole-doc callers (attach / applyExternalText / theme).
    /// The metrics are computed at ARM time and captured into the task, so the
    /// trailing edge can't re-read a since-changed `textView.string`.
    private func deliverMetrics(text: String, debounced: Bool) {
        guard onMetricsChanged != nil else { return }
        guard debounced else {
            metricsNotifyTask?.cancel()
            metricsNotifyTask = nil
            onMetricsChanged?(computeMetrics(text: text))
            return
        }
        // Defer the COMPUTATION to the trailing edge too, not just delivery:
        // computeMetrics' word-count split is O(document), and computing at
        // arm time re-paid it on EVERY keystroke — a live-profile regression
        // (2026-06-10 sample 7: ~20 ms/keystroke at 553 KB) that the debounce
        // was supposed to prevent. Capturing the immutable `text` is free; at
        // fire time it is exactly the last arming keystroke's text
        // (cancel-and-rearm), and `lastParsedScript` matches it — every path
        // that changes the script out-of-band (attach, applyExternalText)
        // cancels this task before posting its own immediate delivery.
        metricsNotifyTask?.cancel()
        metricsNotifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.metricsNotifyTask = nil
            self.onMetricsChanged?(self.computeMetrics(text: text))
        }
    }

    func scrollSelectionToVerticalCenter(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: textView.selectedRange(),
            actualCharacterRange: nil)
        let lineRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: textContainer)
        guard let scrollView = textView.enclosingScrollView else { return }
        let visible = scrollView.contentView.documentVisibleRect
        // `lineRect` is in text-container coordinates; the text view offsets
        // the container by `textContainerInset.height`. The scroll origin /
        // frame / visible rect are all in view coordinates, so add the inset
        // to land the line's midpoint in the same space. With typewriter
        // scroll on, that inset is ~half a viewport (see refreshTypewriterInset),
        // which is exactly the headroom that lets the first and last lines
        // reach center.
        let lineMidY = lineRect.midY + textView.textContainerInset.height
        // Centering computes negative Y near the top of the document and
        // overshoots near the bottom; clamp to the legitimate document
        // range so NSScrollView doesn't round-trip through a clamped value
        // and produce a visible jump on each keystroke.
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maxY = max(0, documentHeight - visible.height)
        let rawTarget = lineMidY - visible.height / 2
        let clampedY = max(0, min(rawTarget, maxY))
        // Skip the call entirely if we're already within a pixel of the
        // target — avoids a no-op scroll that NSScrollView still treats
        // as a relayout event and which can perturb a typing-mid-paragraph
        // cursor's apparent position.
        if abs(clampedY - visible.origin.y) < 0.5 { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func applyFocusDim(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        // Review posture turns focus-dim off — the reviewer reads the whole
        // crafted draft, not a dimmed sentence/paragraph window.
        guard !isReviewMode else { return }
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
