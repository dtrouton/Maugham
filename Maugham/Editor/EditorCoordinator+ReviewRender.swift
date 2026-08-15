import Foundation
import MaughamCore
import AppKit
import SwiftUI

// EditorCoordinator — crafted review render + interactive margin cards +
// annotation authoring. Extracted from EditorCoordinator.swift (mechanical
// split); stored properties and the NSTextViewDelegate core stay in the base.
extension EditorCoordinator {
    // MARK: - Crafted review render, margin cards, annotation authoring

    /// Apply the open-annotation set for the crafted review render. Called
    /// ONE-WAY from `applyControl` (ADR 0017) when `control.reviewAnnotations`
    /// changes. Recomputes resolved marks (and redraws the overlays) only when the
    /// set actually changed — `applyControl` runs on every model observation, so
    /// this is guarded against no-op churn the same way `setReviewMode` is.
    func setReviewAnnotations(_ annotations: [Annotation]) {
        guard annotations != reviewAnnotations else { return }
        // A stet's annotationsVersion bump can drive this push DURING the stet
        // dwell. Defer it so the held STET card isn't recomputed away early; the
        // dwell completion (`stetReviewCardWithFlourish`) re-pulls the fresh set.
        if stetReviewCardId != nil { return }
        reviewAnnotations = annotations
        recomputeReviewMarks()
        refreshReviewOverlays()
    }

    /// Re-pull the current open-annotation set from `reviewAnnotationsProvider`
    /// and recompute marks. Reuses the same pull path as `setReviewMode`'s
    /// entry case so a just-created annotation renders IMMEDIATELY without the
    /// reviewer toggling review off/on (the SwiftUI observation→push chain off
    /// `annotationsVersion` is unreliable for the local-create case). Invoked
    /// from `commitAnnotation` AFTER the create's op-log append has been awaited.
    /// Only acts in review mode with a provider wired, and is no-op-guarded the
    /// same way as the push, so a subsequent `setReviewAnnotations` with the same
    /// set won't double-recompute. The provider is called on entry + after an
    /// explicit create only — never per keystroke.
    func refreshReviewMarksFromProvider() {
        guard isReviewMode, let provider = reviewAnnotationsProvider else { return }
        let pulled = provider()
        guard pulled != reviewAnnotations else { return }
        reviewAnnotations = pulled
        recomputeReviewMarks()
        refreshReviewOverlays()
    }

    /// Resolve every review annotation to absolute UTF-16 coordinates against the
    /// current display string. Span-anchored marks get an `absoluteRange`;
    /// paragraph-level / stale-span ones are rail-only (`absoluteRange == nil`)
    /// but still anchored at the paragraph start. Cached in `resolvedReviewMarks`;
    /// the overlay draws read the cache, never recompute (tripwire 4).
    func recomputeReviewMarks() {
        let localName = reviewLocalAuthorName?() ?? ""
        var marks: [ResolvedReviewMark] = []
        for ann in reviewAnnotations {
            let color = reviewPalette.color(for: ann.author)
            let authorName = ann.author?.displayName.isEmpty == false
                ? ann.author!.displayName
                : (ann.author?.sourceKind == .claude ? "Claude" : "Reviewer")

            var absolute: NSRange?
            var railAnchor = 0

            if let pid = ann.paragraphId,
               let paraRange = reviewParagraphRangeProvider?(pid) {
                railAnchor = paraRange.location
                if let grapheme = ann.resolvedSpanRange,
                   let paraText = reviewParagraphTextProvider?(pid),
                   let utf16 = ReviewSpanCapture.graphemeRangeToUTF16(grapheme, in: paraText),
                   utf16.length > 0 {
                    let abs = NSRange(
                        location: paraRange.location + utf16.location,
                        length: utf16.length)
                    absolute = abs
                    railAnchor = abs.location
                }
            }

            marks.append(ResolvedReviewMark(
                id: ann.id,
                kind: ann.kind,
                color: color,
                absoluteRange: absolute,
                railAnchorLocation: railAnchor,
                authorName: authorName,
                body: ann.body,
                suggestedText: ann.suggestedText,
                isOwn: AnnotationOwnership.isOwn(ann, localName: localName)))
        }
        resolvedReviewMarks = marks
        // A recompute can drop the currently-selected card (e.g. it was
        // withdrawn / accepted out of the open set). Clear the selection so the
        // actions row doesn't dangle over nothing.
        if let selected = selectedReviewCardId,
           !marks.contains(where: { $0.id == selected }) {
            clearReviewCardSelection()
        }
    }

    /// Install the overlays if missing and reconcile their visibility with the
    /// review posture. Idempotent.
    func syncReviewOverlays() {
        guard let textView else { return }
        if isReviewMode {
            installReviewOverlaysIfNeeded(in: textView)
        }
        markRenderer?.isHidden = !isReviewMode
        marginRail?.isHidden = !isReviewMode
        layoutReviewOverlays(in: textView)
        refreshReviewOverlays()
    }

    private func installReviewOverlaysIfNeeded(in textView: NSTextView) {
        if markRenderer == nil {
            let r = AnnotationMarkRenderer(frame: textView.bounds)
            r.coordinator = self
            r.associatedTextView = textView
            r.autoresizingMask = [.width, .height]
            textView.addSubview(r)
            markRenderer = r
        }
        if marginRail == nil {
            let rail = ReviewMarginRailView(frame: .zero)
            rail.coordinator = self
            rail.associatedTextView = textView
            rail.autoresizingMask = [.height]
            textView.addSubview(rail)
            marginRail = rail
        }
    }

    /// Frame the overlays: the mark renderer covers the whole text view (it draws
    /// over glyphs); the rail occupies the right inset gutter.
    func layoutReviewOverlays(in textView: NSTextView) {
        markRenderer?.frame = textView.bounds
        if let rail = marginRail {
            let inset = textView.textContainerInset.width
            // Right gutter spans from the column's right edge to the view edge.
            let railWidth = max(0, inset)
            rail.frame = NSRect(
                x: textView.bounds.width - railWidth,
                y: 0,
                width: railWidth,
                height: max(textView.bounds.height, textView.frame.height))
        }
    }

    /// Mark both overlays dirty (cheap — they bound their own work to the visible
    /// range). Called on annotation-change, text-change, scroll, and resize.
    func refreshReviewOverlays() {
        markRenderer?.needsDisplay = true
        marginRail?.needsDisplay = true
    }

    /// Toggle / set the selected margin card. Selecting also navigates to the
    /// annotation's span (span-precise) and shows the inline actions row;
    /// re-clicking the same card (or `nil`) clears the selection.
    func selectReviewCard(id: String?) {
        if selectedReviewCardId == id {
            clearReviewCardSelection()
            return
        }
        selectedReviewCardId = id
        if let id, let textView {
            // Span-precise select on card click (same path as the pane).
            let pid = resolvedReviewMarks.first(where: { $0.id == id })
                .flatMap { _ in reviewAnnotationParagraphId(id) }
            navigateToAnnotation(id: id, fallbackParagraphId: pid, in: textView)
        }
        marginRail?.reloadCardSelection()
        refreshReviewOverlays()
    }

    func clearReviewCardSelection() {
        guard selectedReviewCardId != nil else { return }
        selectedReviewCardId = nil
        marginRail?.reloadCardSelection()
        refreshReviewOverlays()
    }

    /// The paragraph id for a resolved mark, used as the navigation fallback when
    /// a card is clicked. Pulled from the live annotation set (the resolved mark
    /// doesn't carry the pid). Best-effort; nil is a harmless no-fallback.
    private func reviewAnnotationParagraphId(_ id: String) -> String? {
        reviewAnnotations.first(where: { $0.id == id })?.paragraphId
    }

    /// Perform a margin-card action against the annotation. Dispatches to the
    /// host-threaded handler; Edit / Reply open the inline composer; Delete
    /// confirms via NSAlert first. After a disposition / edit lands, the marks
    /// are refreshed from the provider (same path as the pane's notification),
    /// so the card list updates without a review toggle.
    func performReviewCardAction(_ action: ReviewCardAction, annotationId id: String) {
        guard let mark = resolvedReviewMarks.first(where: { $0.id == id }) else { return }
        switch action {
        case .accept:
            runReviewAction { [weak self] in await self?.reviewAcceptHandler?(id) }
        case .reject:
            runReviewAction { [weak self] in await self?.reviewRejectHandler?(id) }
        case .stet:
            stetReviewCardWithFlourish(id: id)
        case .archive:
            runReviewAction { [weak self] in await self?.reviewArchiveHandler?(id) }
        case .reply:
            beginCardComposer(
                placeholder: "Reply\u{2026}", initialText: "", for: id
            ) { [weak self] value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self?.runReviewAction {
                    await self?.reviewReplyHandler?(id, trimmed)
                }
            }
        case .edit:
            let isSuggest = (mark.kind == .suggestedChange)
            let initial = isSuggest ? (mark.suggestedText ?? "") : mark.body
            beginCardComposer(
                placeholder: isSuggest ? "Replacement\u{2026}" : "Edit\u{2026}",
                initialText: initial, for: id
            ) { [weak self] value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                // For a suggestion the field edits the replacement, keeping the
                // existing body; for others it edits the body, no replacement.
                if isSuggest {
                    self?.runReviewAction {
                        await self?.reviewEditHandler?(id, mark.body, trimmed)
                    }
                } else {
                    self?.runReviewAction {
                        await self?.reviewEditHandler?(id, trimmed, nil)
                    }
                }
            }
        case .delete:
            confirmDeleteCard(id: id, authorName: mark.authorName)
        }
    }

    /// Stet from the margin card with the proofreader's own acknowledgement.
    /// Records the stet immediately (never blocked), dismisses the actions row,
    /// then holds the card on-screen with a STET treatment for ~2s before
    /// refreshing the marks (which drops the now-stetted annotation out of the
    /// open set). Mirrors the AnnotationsPane dwell so the gesture reads here too.
    ///
    /// M3 P2 moved the flourish here from reject, where it had been since the
    /// margin card shipped: "stet" means *let it stand*, and a rejected note is
    /// precisely the one that did not.
    private func stetReviewCardWithFlourish(id: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reviewStetHandler?(id)
            // Keep the card present (don't refresh it away yet) and paint STET.
            self.stetReviewCardId = id
            self.clearReviewCardSelection()  // hides the actions row + redraws; card stays
            self.refreshReviewOverlays()     // repaint rail (STET) + inline (strike off)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.stetReviewCardId = nil
            self.refreshReviewMarksFromProvider()
        }
    }

    /// Run a disposition handler, then refresh marks from the provider so the
    /// card list reconciles (the resolved annotation drops out of the open set).
    private func runReviewAction(_ work: @escaping () async -> Void) {
        Task { @MainActor [weak self] in
            await work()
            self?.clearReviewCardSelection()
            self?.refreshReviewMarksFromProvider()
        }
    }

    /// Show the inline `ReviewAnnotationComposerView` near the selected card for
    /// Edit / Reply (re-uses the authoring composer — plain NSView, no popover).
    /// Positioned at the rail's selected-card rect in the scroll-view overlay
    /// parent, mirroring `beginAuthoringAnnotation`.
    private func beginCardComposer(
        placeholder: String, initialText: String, for id: String,
        onCommit: @escaping (String) -> Void
    ) {
        guard let parent = selectionToolbar?.superview else { return }
        annotationComposer?.dismiss()
        let composer = ReviewAnnotationComposerView(
            placeholder: placeholder,
            initialText: initialText,
            onCommit: { [weak self] value in
                self?.annotationComposer?.dismiss()
                self?.annotationComposer = nil
                onCommit(value)
            },
            onCancel: { [weak self] in
                self?.annotationComposer?.dismiss()
                self?.annotationComposer = nil
            })
        parent.addSubview(composer)
        annotationComposer = composer
        // Position next to the selected card. The rail reports the card's rect in
        // its own coords; convert to the overlay parent.
        if let rail = marginRail,
           let cardRect = rail.cardRect(forAnnotationId: id) {
            let inParent = rail.convert(cardRect, to: parent)
            composer.setFrameOrigin(NSPoint(
                x: inParent.minX,
                y: inParent.minY - composer.frame.height - 4))
        } else if let toolbar = selectionToolbar {
            composer.setFrameOrigin(toolbar.frame.origin)
        }
        composer.focus()
    }

    /// Confirm-then-withdraw for the reviewer's own annotation. NSAlert is fine
    /// here — the rail is an AppKit NSView in a real window; the alert sheets off
    /// it. (Reported in the task as a possible friction point; in practice the
    /// alert presents cleanly from the text view's window.)
    private func confirmDeleteCard(id: String, authorName: String) {
        guard let window = textView?.window else {
            // No window (test / detached) — withdraw without a prompt.
            runReviewAction { [weak self] in await self?.reviewWithdrawHandler?(id) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete your annotation"
        alert.informativeText =
            "This removes your annotation. The history is preserved, but the annotation will no longer appear here or in the editor."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runReviewAction { await self?.reviewWithdrawHandler?(id) }
        }
    }

    /// Map a `SelectionToolbarView.Kind` to the annotation flow. All three open
    /// the inline composer; Suggest pre-fills it with the selected text so the
    /// reviewer edits it into the replacement.
    func handleToolbarAction(_ kind: SelectionToolbarView.Kind) {
        switch kind {
        case .comment: beginAuthoringAnnotation(kind: .comment)
        case .query:   beginAuthoringAnnotation(kind: .query)
        case .suggest: beginAuthoringAnnotation(kind: .suggestedChange)
        }
    }

    /// Capture the paragraph id + sub-paragraph span for the current selection,
    /// then present a minimal inline composer. Comment/Query collect a body and
    /// start empty; Suggest pre-fills with the selected text and the reviewer
    /// edits it into the replacement (→ a `.suggestedChange` annotation with
    /// `original` = selected text, `suggestedText` = replacement). No-op if the
    /// selection can't be mapped to a paragraph-relative span.
    private func beginAuthoringAnnotation(kind: AnnotationKind) {
        guard let textView,
              let parent = selectionToolbar?.superview,
              let captured = capturedSpanForSelection(in: textView)
        else { return }

        // Tear down any prior composer before showing a new one.
        annotationComposer?.dismiss()

        let isSuggest = (kind == .suggestedChange)
        let placeholder: String
        switch kind {
        case .comment:         placeholder = "Comment…"
        case .query:           placeholder = "Query…"
        case .suggestedChange: placeholder = "Replacement…"
        default:               placeholder = "Note…"
        }

        let composer = ReviewAnnotationComposerView(
            placeholder: placeholder,
            initialText: isSuggest ? captured.selectedText : "",
            onCommit: { [weak self] value in
                self?.commitAnnotation(
                    kind: kind,
                    paragraphId: captured.paragraphId,
                    span: captured.span,
                    originalText: captured.selectedText,
                    composerValue: value)
            },
            onCancel: { [weak self] in
                self?.annotationComposer?.dismiss()
                self?.annotationComposer = nil
            })
        parent.addSubview(composer)
        annotationComposer = composer

        // Position the composer where the toolbar is (just above the selection),
        // then hide the toolbar so they don't overlap.
        if let toolbar = selectionToolbar {
            composer.setFrameOrigin(toolbar.frame.origin)
            toolbar.isHidden = true
        }
        composer.focus()
    }

    /// Compute (paragraphId, SpanAnchor, selectedText) for the current non-empty
    /// selection, clamped to the paragraph at the selection's start. Returns nil
    /// if the selection is empty, can't be located, or yields no usable span.
    /// `selectedText` is the clamped (within-paragraph) display text — the same
    /// substring the span anchors — used to pre-fill Suggest and as the diff's
    /// original.
    private func capturedSpanForSelection(
        in textView: NSTextView
    ) -> (paragraphId: String, span: SpanAnchor, selectedText: String)? {
        let sel = textView.selectedRange()
        guard sel.length > 0,
              let provider = paragraphRangeAtLocation,
              let located = provider(sel.location) else { return nil }
        let paraStart = located.range.location
        let paraEnd = located.range.location + located.range.length
        guard let relative = ReviewSpanCapture.paragraphRelativeRange(
                absolute: sel.location..<(sel.location + sel.length),
                paragraph: paraStart..<paraEnd) else { return nil }
        // Slice the paragraph's display text out of the textView (the stripped
        // display form — the same form `paragraphRange(at:)` measured).
        let ns = textView.string as NSString
        guard located.range.location >= 0,
              located.range.location + located.range.length <= ns.length
        else { return nil }
        let paragraphText = ns.substring(with: located.range)
        guard let span = ReviewSpanCapture.captureSpan(
                in: paragraphText, relativeUTF16: relative) else { return nil }
        // The selected text is the clamped relative range against the paragraph
        // display text (UTF-16, the same unit `relative` is in).
        let paraNS = paragraphText as NSString
        let selectedText = paraNS.substring(
            with: NSRange(location: relative.lowerBound,
                          length: relative.upperBound - relative.lowerBound))
        return (located.id, span, selectedText)
    }

    /// Commit a composed annotation. Comment/Query use `composerValue` as the
    /// body (empty → cancel). Suggest diffs the composer value against the
    /// original selected text via `SuggestedEditDiff`; an unchanged/empty edit
    /// creates nothing (just dismisses).
    private func commitAnnotation(
        kind: AnnotationKind, paragraphId: String,
        span: SpanAnchor, originalText: String, composerValue: String
    ) {
        annotationComposer?.dismiss()
        annotationComposer = nil

        let body: String
        let suggestedText: String?
        if kind == .suggestedChange {
            guard let diff = SuggestedEditDiff.make(
                    original: originalText, edited: composerValue) else {
                // Unchanged / empty → nothing to suggest.
                restoreToolbarAfterDismiss()
                return
            }
            body = diff.body
            suggestedText = diff.suggestedText
        } else {
            let trimmed = composerValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {  // empty body → cancel
                restoreToolbarAfterDismiss()
                return
            }
            body = trimmed
            suggestedText = nil
        }

        // Await the op-log append, THEN re-pull the annotation set so the new
        // annotation's inline mark + rail card render immediately (no review
        // toggle). The lagged SwiftUI push off `annotationsVersion` stays the
        // reconciler for annotations created elsewhere; this is the deterministic
        // local-create path. The toolbar dismiss is synchronous (UI), independent
        // of the persist.
        if let handler = createAnnotationHandler {
            Task { @MainActor [weak self] in
                await handler(kind, paragraphId, span, body, suggestedText)
                self?.refreshReviewMarksFromProvider()
            }
        }
        restoreToolbarAfterDismiss()
    }

    /// Collapse the selection so the toolbar hides on the next selection pass.
    private func restoreToolbarAfterDismiss() {
        textView?.setSelectedRange(
            NSRange(location: textView?.selectedRange().location ?? 0, length: 0))
        if let textView { updateSelectionToolbar(in: textView) }
    }
}
