import Foundation
import MaughamCore
import AppKit
import SwiftUI

// EditorCoordinator — span/line/annotation navigation and the review
// selection toolbar positioning. Extracted from EditorCoordinator.swift
// (mechanical split).
extension EditorCoordinator {
    // MARK: - Span/line/annotation navigation + selection toolbar

    /// Select an annotation's exact span (and scroll it into view). Looks the id
    /// up in `resolvedReviewMarks`: a resolved `absoluteRange` is selected
    /// directly; a paragraph-level / stale-span annotation (or one not in the
    /// resolved set — e.g. review is off) falls back to scrolling to the
    /// paragraph (the legacy behaviour). Selecting a range in review mode is
    /// fine: the read-only membrane blocks EDITS, not selection.
    func navigateToAnnotation(
        id: String, fallbackParagraphId: String?, in textView: NSTextView
    ) {
        let length = (textView.string as NSString).length
        if let mark = resolvedReviewMarks.first(where: { $0.id == id }),
           let range = mark.absoluteRange,
           range.location >= 0, range.location + range.length <= length {
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
            return
        }
        // Fallback: paragraph start (length-0 cursor), mirroring the legacy
        // `.maughamNavigateToParagraph` handler.
        guard let pid = fallbackParagraphId,
              let provider = paragraphRangeProvider,
              let range = provider(pid),
              range.location >= 0, range.location + range.length <= length
        else { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }

    func navigateToLine(at location: Int, in textView: NSTextView) {
        let storage = textView.textStorage
        let length = (storage?.string as NSString?)?.length ?? 0
        let clamped = max(0, min(location, length))
        let range = NSRange(location: clamped, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }

    /// SPIKE (collab review): the selection's bounding rect in TEXT-VIEW
    /// coordinates (the same space as `textView.frame` / a subview's frame),
    /// or nil when the selection is empty.
    ///
    /// `boundingRect(forGlyphRange:in:)` returns container-space coordinates.
    /// The text view offsets its container by `textContainerInset` (the column
    /// is centered horizontally via `.width`, and `.height` is the top inset —
    /// 24pt normally, ~half a viewport under typewriter scroll). Adding the
    /// inset to the rect's origin lands it in view space. This mirrors
    /// `scrollSelectionToVerticalCenter`'s `lineRect.midY + inset.height`
    /// correction and `ElementGutterView`'s `lineRect.origin.y + yOffset`.
    func selectionViewRect(in textView: NSTextView) -> NSRect? {
        let selection = textView.selectedRange()
        guard selection.length > 0,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: selection, actualCharacterRange: nil)
        let containerRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: container)
        let inset = textView.textContainerInset
        return NSRect(
            x: containerRect.origin.x + inset.width,
            y: containerRect.origin.y + inset.height,
            width: containerRect.size.width,
            height: containerRect.size.height)
    }

    /// Drive the floating selection toolbar one-way from the AppKit selection
    /// callback. Show + position above a non-empty selection while review
    /// posture is on; hide otherwise. No SwiftUI state round-trip (tripwire 2):
    /// the toolbar is a plain NSView the coordinator owns by weak reference.
    func updateSelectionToolbar(in textView: NSTextView) {
        guard let toolbar = selectionToolbar,
              let parent = toolbar.superview else { return }
        // Only surface the toolbar in review posture; in normal authoring the
        // editor stays clean.
        guard isReviewMode, let rectInTextView = selectionViewRect(in: textView)
        else {
            toolbar.isHidden = true
            return
        }
        // Convert the selection rect from text-view coords into the overlay
        // parent's coords. `convert(_:to:)` walks the view tree and accounts
        // for the scroll view's clip/scroll offset automatically, so as the
        // document scrolls the toolbar tracks the on-screen selection.
        let rectInParent = textView.convert(rectInTextView, to: parent)
        // The toolbar is pure-frame (no Auto Layout): it sized itself to its
        // content at construction, so read its actual frame size rather than
        // `fittingSize` (which is .zero for an unconstrained NSView).
        let size = toolbar.frame.size
        let gap: CGFloat = 6
        // Position just ABOVE the selection. AppKit's default coordinate system
        // is y-up (flipped == false for the scroll view's superview), so
        // "above" means a HIGHER maxY. Place the toolbar's bottom edge `gap`
        // above the selection's top edge (rectInParent.maxY).
        var originX = rectInParent.midX - size.width / 2
        var originY = rectInParent.maxY + gap
        // Clamp within the parent's bounds so it never clips off-edge.
        originX = max(parent.bounds.minX,
                      min(originX, parent.bounds.maxX - size.width))
        originY = max(parent.bounds.minY,
                      min(originY, parent.bounds.maxY - size.height))
        toolbar.setFrameOrigin(NSPoint(x: originX, y: originY))
        toolbar.isHidden = false
    }
}
