import AppKit
import MaughamCore

// EditorCoordinator — translation-review staleness badges + dimmed missing
// paragraphs (Task 12). The margin dots are drawn by `TranslationBadgeOverlayView`
// (installed like the review overlays / gutter); the missing-paragraph dimming is
// a layout-manager TEMPORARY attribute applied here and cleared on exit. Both are
// bound to the pushed model, resolved once per push via `TranslationBadgeLayout`
// (never per draw — tripwire 4).
extension EditorCoordinator {

    /// Receive the ordered per-paragraph translation freshness + the rendered
    /// translated surface, pushed ONE-WAY from EditorHost via `EditorControl`
    /// (same discipline as `translationLanguage` — explicit events only, never
    /// per keystroke; the surface is read-only in translation review). Resolves
    /// each paragraph to its UTF-16 range in the rendered surface
    /// (`TranslationBadgeLayout`), applies the missing-paragraph dimming, and
    /// installs/reconciles the margin-dot overlay. No-op-guarded on the model the
    /// same way `setReviewAnnotations` is (applyControl runs every observation
    /// pass). An `.empty` model (exit path) clears the dimming and hides the
    /// overlay.
    func setTranslationBadges(_ model: EditorControl.TranslationBadgeModel) {
        guard model != appliedTranslationBadgeModel else { return }
        appliedTranslationBadgeModel = model
        resolvedTranslationBadges = TranslationBadgeLayout.ranges(
            entries: model.entries, renderedText: model.renderedText)
        applyTranslationDimming()
        syncTranslationBadgeOverlay()
    }

    /// Dim MISSING paragraphs' body text to `.tertiaryLabelColor` — they show the
    /// SOURCE text through (no translation yet), so the dimming reads as "not yet
    /// translated" without hiding the text. Implemented as a LAYOUT-MANAGER
    /// temporary attribute: display-only, never touches the op log or the text
    /// storage's stored attributes (so a `retokenizeAndStyle` doesn't wipe it),
    /// and trivially cleared. Clears any prior dimming wholesale first — nothing
    /// else sets a temporary foreground color, so a full-range removal is exact —
    /// then re-applies over the current missing ranges. Outside translation
    /// review it only clears.
    func applyTranslationDimming() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let fullRange = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        guard isTranslationReview else { return }
        for badge in resolvedTranslationBadges where badge.status == .missing {
            let loc = min(badge.range.location, fullRange.length)
            let len = min(badge.range.length, max(0, fullRange.length - loc))
            guard len > 0 else { continue }
            layoutManager.addTemporaryAttribute(
                .foregroundColor, value: NSColor.tertiaryLabelColor,
                forCharacterRange: NSRange(location: loc, length: len))
        }
    }

    /// Install the overlay if missing and reconcile its visibility with the
    /// translation-review posture. Idempotent; mirrors `syncReviewOverlays`.
    func syncTranslationBadgeOverlay() {
        guard let textView else { return }
        if isTranslationReview {
            installTranslationBadgeOverlayIfNeeded(in: textView)
        }
        translationBadgeOverlay?.isHidden = !isTranslationReview
        layoutTranslationBadgeOverlay(in: textView)
        translationBadgeOverlay?.needsDisplay = true
    }

    private func installTranslationBadgeOverlayIfNeeded(in textView: NSTextView) {
        guard translationBadgeOverlay == nil else { return }
        let overlay = TranslationBadgeOverlayView(frame: textView.bounds)
        overlay.coordinator = self
        overlay.associatedTextView = textView
        overlay.autoresizingMask = [.width, .height]
        textView.addSubview(overlay)
        translationBadgeOverlay = overlay
    }

    /// The badge overlay covers the whole text view (it draws dots in the left
    /// inset). Re-framed on resize from `MaughamTextView.updateColumnInset`,
    /// mirroring the review overlays.
    func layoutTranslationBadgeOverlay(in textView: NSTextView) {
        translationBadgeOverlay?.frame = textView.bounds
    }
}
