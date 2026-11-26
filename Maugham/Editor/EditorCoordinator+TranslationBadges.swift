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
    /// per keystroke; the surface is read-only while a translation is read). Resolves
    /// each paragraph to its UTF-16 range in the rendered surface
    /// (`TranslationBadgeLayout`), applies the missing-paragraph dimming, and
    /// installs/reconciles the margin-dot overlay. No-op-guarded on the model the
    /// same way `setReviewAnnotations` is (applyControl runs every observation
    /// pass). An `.empty` model (exit path) clears the dimming and hides the
    /// overlay.
    func setTranslationBadges(_ model: EditorControl.TranslationBadgeModel) {
        guard model != appliedTranslationBadgeModel else { return }
        appliedTranslationBadgeModel = model
        resolvedTranslationBadges = TranslationBadgeLayout.ranges(entries: model.entries)
        // A model whose surface IS the text held (statuses moved, the text did
        // not) describes the buffer now; any other waits for its swap.
        if bufferHoldsTranslation, let textView,
           textView.string == TranslationBadgeLayout.surface(entries: model.entries) {
            bufferBadges = resolvedTranslationBadges
        }
        applyTranslationDimming()
        syncTranslationBadgeOverlay()
        if bufferHoldsTranslation { deliverReadingMetrics() }
    }

    /// Dim MISSING paragraphs' body text to `.tertiaryLabelColor` — they show the
    /// SOURCE text through (no translation yet), so the dimming reads as "not yet
    /// translated" without hiding the text — and draw each SOURCE line under a
    /// translation (shell p4 Task 8) in `.secondaryLabelColor`, the quieter ink
    /// of a text you are not reading. Implemented as LAYOUT-MANAGER temporary
    /// attributes: display-only, never touching the op log or the text
    /// storage's stored attributes (so a `retokenizeAndStyle` doesn't wipe
    /// them), and trivially cleared. Clears any prior dimming wholesale first —
    /// in translation reading nothing else sets a temporary foreground color
    /// (the caption bar's caret-line un-fade, report plan 7b Task 8, is skipped
    /// there), so a full-range removal is exact — then re-applies over the
    /// current ranges (`TranslationBadgeLayout.inks`). Outside a translation it
    /// clears, and the caret's figure line takes its un-fade back.
    func applyTranslationDimming() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let fullRange = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        guard isReadingTranslation else {
            figureSyntaxUnfadeWasCleared()
            return
        }
        for ink in TranslationBadgeLayout.inks(bufferBadges, length: fullRange.length) {
            layoutManager.addTemporaryAttribute(
                .foregroundColor, value: Self.color(of: ink.kind), forCharacterRange: ink.range)
        }
    }

    /// The ink of each kind: the source under a translation in secondary,
    /// a missing paragraph's source showing through in tertiary, and a stale
    /// translation in the badge's amber blended toward the text — quiet, and
    /// not the colour of current text (fix round (d)).
    static func color(of kind: TranslationBadgeLayout.Ink.Kind) -> NSColor {
        switch kind {
        case .source: return .secondaryLabelColor
        case .missing: return .tertiaryLabelColor
        case .stale: return staleInk
        }
    }

    static let staleInk = NSColor(name: nil) { appearance in
        let amber = NSColor(calibratedRed: 0.85, green: 0.55, blue: 0.10, alpha: 1)
        let text = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.2, alpha: 1)
        return text.blended(withFraction: 0.45, of: amber) ?? amber
    }

    /// Install the overlay if missing and reconcile its visibility with the
    /// translation-review posture. Idempotent; mirrors `syncReviewOverlays`.
    func syncTranslationBadgeOverlay() {
        guard let textView else { return }
        if isReadingTranslation {
            installTranslationBadgeOverlayIfNeeded(in: textView)
        }
        translationBadgeOverlay?.isHidden = !isReadingTranslation
        layoutTranslationBadgeOverlay(in: textView)
        translationBadgeOverlay?.needsDisplay = true
    }

    private func installTranslationBadgeOverlayIfNeeded(in textView: NSTextView) {
        // Never left on a text view SwiftUI replaced (`attach(to:)` is the rule).
        if let stale = translationBadgeOverlay, stale.superview !== textView {
            stale.removeFromSuperview()
            translationBadgeOverlay = nil
        }
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

    // MARK: - Keeping the reader's place across a swap (fix round (c), I4)

    /// **Where the reader is** in the text the view holds: the paragraph they
    /// are LOOKING at — the caret's when it is on screen, else the first one
    /// visible — how far into it the caret (and selection) sit, and how far
    /// below the top of the view the paragraph's line is. Read before a swap
    /// that involves a translation, restored after it (`restore`).
    struct ReadingPlace: Equatable {
        let paragraphId: String
        /// The caret's offset in the paragraph's translation or source text,
        /// and the selection's length.
        let into: Int
        let length: Int
        /// The paragraph's location's line top, less the visible top.
        let fromTop: CGFloat
    }

    func readingPlace() -> ReadingPlace? {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let inset = textView.textContainerInset
        var visible = textView.visibleRect
        visible.origin.y -= inset.height
        let selection = textView.selectedRange()
        let firstVisible = layoutManager.characterIndexForGlyph(
            at: layoutManager.glyphIndex(for: NSPoint(x: 1, y: max(0, visible.minY)), in: container))
        let caretVisible = lineTop(selection.location).map {
            $0 >= visible.minY && $0 < visible.maxY } ?? false
        let location = caretVisible ? selection.location : firstVisible
        guard let (paragraphId, start) = paragraphStart(at: location) else { return nil }
        let into = caretVisible ? selection.location - start : 0
        let top = lineTop(start) ?? visible.minY
        return ReadingPlace(paragraphId: paragraphId, into: max(0, into),
                            length: caretVisible ? selection.length : 0,
                            fromTop: top - visible.minY)
    }

    /// The paragraph a location of the HELD text belongs to, and where it
    /// starts there.
    private func paragraphStart(at location: Int) -> (String, Int)? {
        if bufferHoldsTranslation {
            guard let i = TranslationBadgeLayout.index(at: location, in: bufferBadges) else { return nil }
            let badge = bufferBadges[i]
            if let source = badge.sourceRange, location >= source.location {
                // A caret in a source line is that paragraph's, at its start.
                return (badge.paragraphId, location)
            }
            return (badge.paragraphId, badge.range.location)
        }
        guard let found = paragraphLocator?(location) else { return nil }
        return (found.paragraphId, location - found.offsetWithinParagraph)
    }

    /// The top of the line holding `location`, in container coordinates.
    private func lineTop(_ location: Int) -> CGFloat? {
        guard let textView, let layoutManager = textView.layoutManager,
              (textView.string as NSString).length >= location else { return nil }
        let length = (textView.string as NSString).length
        guard length > 0 else { return 0 }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(location, length - 1))
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    /// **Put the reader back** in the same paragraph of the text the view
    /// holds now: the caret the same distance in (clamped to the paragraph),
    /// the selection's length kept within it, and the paragraph's line as far
    /// below the top of the view as it was. Nothing moves when the new text
    /// does not have the paragraph.
    func restore(_ place: ReadingPlace) {
        guard let textView, let range = paragraphRangeNow(place.paragraphId) else { return }
        let landing = Self.landing(place, in: range)
        textView.setSelectedRange(landing)
        guard textView.window != nil, let top = lineTop(range.location) else { return }
        let inset = textView.textContainerInset
        textView.scroll(NSPoint(x: 0, y: max(0, top - place.fromTop + inset.height)))
    }

    /// Where the caret lands in the paragraph's range: the same distance in,
    /// the selection's length, both within it.
    static func landing(_ place: ReadingPlace, in range: NSRange) -> NSRange {
        let into = min(place.into, range.length)
        let length = min(place.length, range.length - into)
        return NSRange(location: range.location + into, length: max(0, length))
    }

    /// The paragraph's range in the text the view holds now: from the
    /// buffer's own ranges over a translation (fix 2, N6), else the source's
    /// (`paragraphRangeProvider`, which answers the source only).
    func paragraphRangeNow(_ paragraphId: String) -> NSRange? {
        if bufferHoldsTranslation {
            return bufferBadges.first { $0.paragraphId == paragraphId }?.range
        }
        return paragraphRangeProvider?(paragraphId)
    }

    // MARK: - Source and surface coordinates (fix I2; fix 2, N6)

    /// **A SOURCE location in the text the view holds** — the one rule every
    /// source-coordinate navigation takes (a Scenes row, a `.line` place, the
    /// restored caret): itself over the source; over a translation the same
    /// paragraph's place in its translation, the same distance in (clamped),
    /// read against the buffer's own ranges; the start when the surface does
    /// not hold the paragraph.
    func surfaceLocation(forSource location: Int) -> Int {
        guard bufferHoldsTranslation else { return location }
        guard let found = paragraphLocator?(location),
              let badge = bufferBadges.first(where: { $0.paragraphId == found.paragraphId })
        else { return 0 }
        return badge.range.location + max(0, min(found.offsetWithinParagraph, badge.range.length))
    }

    /// **A location of the text held, as a SOURCE location** — what the host
    /// is told the caret is (`onCursorChanged`): itself over the source; over
    /// a translation the same paragraph's source place
    /// (`TranslationBadgeLayout.sourceLocation`), the last told one exactly
    /// when the surface caret is its own image (fix M1). Nil — tell nothing —
    /// when the surface names no paragraph the source has.
    func sourceLocation(forSurface location: Int) -> Int? {
        guard bufferHoldsTranslation else { return location }
        if let told = lastToldSourceCaret, surfaceLocation(forSource: told) == location { return told }
        return TranslationBadgeLayout.sourceLocation(
            forSurfaceLocation: location, ranges: bufferBadges,
            sourceRangeOf: { self.paragraphRangeProvider?($0) })
    }
}

/// **Edit ▸ Undo is barred while the buffer holds a translation, from every
/// responder** (shell p4 Task 8 fix 2, N3). The window's stack holds the
/// writer's typing against the SOURCE; popped against a non-editable view
/// showing a translation it applies nothing and is consumed — the writer's
/// history lost in silence. The primary editor does not answer `undo:` (the
/// walk reaches the window, `MaughamTextView.responds(to:)`), nor do the tree
/// or a button; so this responder sits between the window's content view and
/// the window, and every walk that would reach the window's stack meets it
/// first: Undo and Redo are disabled, titled with when they return. A responder with its
/// own manager — a statement's second editor, a text field's field editor —
/// answers before it, as ever. The stack is kept, and is reachable again the
/// moment the source is back. One guard per window, held while any of its
/// editors reads a translation.
final class ReadingUndoGuard: NSResponder, NSMenuItemValidation {
    private var owners: Set<ObjectIdentifier> = []

    /// Titled so the writer knows why it is off, and when it comes back
    /// (plan 4 closing round, writer's seat b).
    static let undoTitle = "Undo \u{2014} Returns in Source"
    static let redoTitle = "Redo \u{2014} Returns in Source"

    @objc func undo(_ sender: Any?) {}
    @objc func redo(_ sender: Any?) {}

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) { item.title = Self.undoTitle; return false }
        if item.action == #selector(redo(_:)) { item.title = Self.redoTitle; return false }
        return false
    }

    /// The guard over `window`, if one stands.
    static func standing(over window: NSWindow?) -> ReadingUndoGuard? {
        window?.contentView?.nextResponder as? ReadingUndoGuard
    }

    /// `nextResponder` does not retain: the window holds its guard.
    private static var heldKey: UInt8 = 0

    @MainActor
    static func install(over window: NSWindow?, for owner: AnyObject) {
        guard let window, let content = window.contentView else { return }
        if let existing = content.nextResponder as? ReadingUndoGuard {
            existing.owners.insert(ObjectIdentifier(owner))
            return
        }
        let guardian = ReadingUndoGuard()
        guardian.nextResponder = content.nextResponder
        guardian.owners = [ObjectIdentifier(owner)]
        objc_setAssociatedObject(window, &heldKey, guardian, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        content.nextResponder = guardian
    }

    @MainActor
    static func remove(from window: NSWindow?, for owner: AnyObject) {
        guard let window, let content = window.contentView,
              let guardian = content.nextResponder as? ReadingUndoGuard else { return }
        guardian.owners.remove(ObjectIdentifier(owner))
        guard guardian.owners.isEmpty else { return }
        content.nextResponder = guardian.nextResponder
        objc_setAssociatedObject(window, &heldKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
