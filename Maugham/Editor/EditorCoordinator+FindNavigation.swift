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
        forceFoldFigureGrid(.navigation)   // the jump wins over an expanded grid
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
              let range = paragraphRangeNow(pid),
              range.location >= 0, range.location + range.length <= length
        else { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }

    /// **A project-find match selected** (`.maughamFindMatchSelected`, after
    /// its load delay): the match selected and shown; an expanded grid folds
    /// first, as any navigation does. The find list keeps the keys.
    func selectFindMatch(_ range: NSRange, in textView: NSTextView) {
        guard let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        forceFoldFigureGrid(.navigation)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    @discardableResult
    func navigateToLine(at sourceLocation: Int, in textView: NSTextView) -> NSRange {
        forceFoldFigureGrid(.navigation)   // the jump wins over an expanded grid
        // A line's location is the SOURCE's (the Scenes rows, a `.line`
        // place): over a translation it lands where the surface shows that
        // paragraph (fix I2).
        let location = surfaceLocation(forSource: sourceLocation)
        let storage = textView.textStorage
        let length = (storage?.string as NSString?)?.length ?? 0
        let clamped = max(0, min(location, length))
        let range = NSRange(location: clamped, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
        return range
    }

    /// **Going to a paragraph** (`.maughamNavigateToParagraph`, and a pending
    /// place landing): a caret (length 0) at the paragraph's start, the
    /// paragraph scrolled into view, the text focused. Returns the range
    /// scrolled to, or nil — and nothing moves — when this document has no
    /// such paragraph.
    ///
    /// A caret rather than the whole paragraph selected: selecting it was
    /// disorienting from the Tasks pane — "jump to this task" became "select
    /// the whole containing paragraph including unrelated text."
    ///
    /// An offset (`MaughamEvent.paragraphOffsetKey`: a figure's Used-in link
    /// naming a line inside a paragraph of several) moves the caret that far
    /// into the paragraph, never past its end.
    @discardableResult
    func landOnParagraph(_ paragraphId: String, offset: Int?, in textView: NSTextView) -> NSRange? {
        // Where the paragraph stands in the text the view HOLDS (fix 2, N6):
        // its translation's range over a translation, its source's otherwise.
        guard let range = paragraphRangeNow(paragraphId) else { return nil }
        let length = (textView.string as NSString).length
        guard range.location >= 0,
              range.location + range.length <= length else { return nil }
        let into = offset.map { max(0, min($0, range.length)) } ?? 0
        let cursor = NSRange(location: range.location + into, length: 0)
        forceFoldFigureGrid(.navigation)   // the jump wins over an expanded grid
        textView.setSelectedRange(cursor)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
        return range
    }

    /// **A document has just loaded into this editor** (`EditorSurface
    /// .makeNSView`, which runs once per document because the surface is
    /// keyed `.id(path)`): the window learns which document its manuscript
    /// editor has (`EditorControl.mountedDocumentId`), and a place it was
    /// asked to go to before the editor had it lands (`landPendingPlace`).
    /// A second editor in the window (a statement pane) and any surface with
    /// no document id do neither; they have their own `EditorControl`
    /// besides.
    func documentDidMount(control: EditorControl) {
        guard respondsToWindowCommands, let documentId else { return }
        control.editorDidMount(self, documentId: documentId)
        landPendingPlace(from: control)
    }

    /// **The window's pending place, taken** (`EditorControl.pendingPlace`,
    /// shell p1 Task 4b). Every manuscript load takes the slot, whatever it
    /// names: it lands exactly as the synchronous navigation does when it
    /// names THIS document and a place in it, and is dropped otherwise (a
    /// paragraph that is not here, a line past the end) — it never lands on
    /// a different document.
    ///
    /// At mount the text view is not yet in a window, so the scroll and the
    /// focus are repeated on the next main-queue turn, as `attach(to:)` does
    /// for a restored caret (and after it, so the place wins). The range is
    /// clamped to the text as it is then, which a translation surface may
    /// have replaced.
    private func landPendingPlace(from control: EditorControl) {
        guard let documentId, let place = control.pendingPlace else { return }
        control.pendingPlace = nil
        guard place.docId == documentId, let textView else { return }
        let landed: NSRange?
        switch place.target {
        case .paragraph(let id, let offset):
            landed = landOnParagraph(id, offset: offset, in: textView)
        case .line(let location):
            // A source location: past the end only of the source, which a
            // translated surface cannot say (`navigateToLine` maps and clamps).
            guard location >= 0,
                  isReadingTranslation || location <= (textView.string as NSString).length else { return }
            landed = navigateToLine(at: location, in: textView)
        }
        guard let landed, textView.window == nil else { return }
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            let length = (textView.string as NSString).length
            let start = min(landed.location, length)
            textView.scrollRangeToVisible(
                NSRange(location: start, length: min(landed.length, length - start)))
            textView.window?.makeFirstResponder(textView)
        }
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
        // Over a translation only what is true there (fix I3): a Comment,
        // Suggest or Query anchors to a SOURCE span the selection is not.
        toolbar.show(SelectionToolbarView.kinds(isReadingTranslation: isReadingTranslation))
        // Convert the selection rect from text-view coords into the overlay
        // parent's coords. `convert(_:to:)` walks the view tree and accounts
        // for the scroll view's clip/scroll offset automatically, so as the
        // document scrolls the toolbar tracks the on-screen selection.
        // The toolbar is pure-frame (no Auto Layout): it sized itself to its
        // content at construction, so read its actual frame size rather than
        // `fittingSize` (which is .zero for an unconstrained NSView).
        toolbar.setFrameOrigin(Self.originAbove(rectInTextView, size: toolbar.frame.size,
                                                in: parent, from: textView))
        toolbar.isHidden = false
    }

    /// **Where an overlay sized `size` sits just above a selection** — the
    /// floating toolbar's place, and the composer's when Edit ▸ Comment… or
    /// the right-click opens it with no toolbar showing (shell p5 Task 7).
    static func originAbove(_ rectInTextView: NSRect, size: NSSize, in parent: NSView,
                            from textView: NSTextView) -> NSPoint {
        let rectInParent = textView.convert(rectInTextView, to: parent)
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
        return NSPoint(x: originX, y: originY)
    }
}
