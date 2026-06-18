import AppKit
import MaughamCore

/// One annotation resolved to absolute UTF-16 coordinates against the text
/// view's display string, ready to draw. Computed by the coordinator on
/// annotation-change / text-change (NOT per draw — tripwire 4) and consumed by
/// both `AnnotationMarkRenderer` (inline marks) and `ReviewMarginRailView`
/// (margin cards + leaders).
///
/// `absoluteRange` is nil when the annotation is paragraph-level or its span
/// went stale (resolvedSpanRange == nil): no inline mark is drawn, but the rail
/// still lists it anchored at the paragraph's start.
struct ResolvedReviewMark {
    let id: String
    let kind: AnnotationKind
    let color: NSColor
    /// Absolute UTF-16 range of the span in the text view's display string,
    /// or nil for paragraph-level / stale-span annotations (rail-only).
    let absoluteRange: NSRange?
    /// Absolute UTF-16 location used to vertically place the rail card — the
    /// span start when resolved, else the paragraph start.
    let railAnchorLocation: Int
    let authorName: String
    let body: String
    /// Replacement text for `.suggestedChange`; nil otherwise.
    let suggestedText: String?
}

/// Wire `target.handleScroll(_:)` to the text view's enclosing scroll view's
/// bounds-change (so the overlay repaints as the document scrolls) and to text
/// change. Mirrors `ElementGutterView`'s observation. `target` must implement an
/// `@objc func handleScroll(_:)`.
private func observeScroll(of textView: NSView?, target: NSView) {
    let nc = NotificationCenter.default
    nc.removeObserver(target)
    guard let textView = textView as? NSTextView else { return }
    nc.addObserver(
        target, selector: Selector(("handleScroll:")),
        name: NSText.didChangeNotification, object: textView)
    if let scrollView = textView.enclosingScrollView {
        scrollView.contentView.postsBoundsChangedNotifications = true
        nc.addObserver(
            target, selector: Selector(("handleScroll:")),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
    }
}

// MARK: - Inline marks

/// Transparent overlay drawn directly over the text view's glyphs (installed as
/// a subview of the text view, mirroring `ElementGutterView`). Paints the
/// per-annotation "pencil" marks — underline / strike+caret / query marker — in
/// the author's colour, bounded to the visible glyph range.
final class AnnotationMarkRenderer: NSView {

    weak var coordinator: EditorCoordinator?
    weak var associatedTextView: NSTextView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // never intercept clicks

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScroll(of: associatedTextView, target: self)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func handleScroll(_ note: Notification) { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let textView = associatedTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let coordinator,
              coordinator.isReviewMode else { return }

        let marks = coordinator.resolvedReviewMarks
        guard !marks.isEmpty else { return }

        let inset = textView.textContainerInset
        let visibleRect = textView.visibleRect
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: container)
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        for mark in marks {
            guard let range = mark.absoluteRange,
                  NSIntersectionRange(range, visibleCharRange).length > 0 else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let drawRect = NSRect(
                x: rect.origin.x + inset.width,
                y: rect.origin.y + inset.height,
                width: rect.size.width,
                height: rect.size.height)
            draw(mark: mark, in: drawRect)
        }
    }

    private func draw(mark: ResolvedReviewMark, in rect: NSRect) {
        let color = mark.color
        switch mark.kind {
        case .comment:
            drawUnderline(in: rect, color: color)
        case .query:
            drawUnderline(in: rect, color: color)
            drawEndMarker("?", at: rect, color: color)
        case .suggestedChange:
            drawStrikethrough(in: rect, color: color)
            drawEndMarker("\u{2038}", at: rect, color: color)  // ‸ caret
        case .craftNote:
            drawUnderline(in: rect, color: color)
        }
    }

    private func drawUnderline(in rect: NSRect, color: NSColor) {
        let path = NSBezierPath()
        let y = rect.maxY - 1.5
        path.move(to: NSPoint(x: rect.minX, y: y))
        path.line(to: NSPoint(x: rect.maxX, y: y))
        path.lineWidth = 1.5
        color.setStroke()
        path.stroke()
    }

    private func drawStrikethrough(in rect: NSRect, color: NSColor) {
        let path = NSBezierPath()
        let y = rect.midY
        path.move(to: NSPoint(x: rect.minX, y: y))
        path.line(to: NSPoint(x: rect.maxX, y: y))
        path.lineWidth = 1.0
        color.setStroke()
        path.stroke()
    }

    private func drawEndMarker(_ glyph: String, at rect: NSRect, color: NSColor) {
        let baseSize = associatedTextView?.font?.pointSize ?? 13
        let font = NSFont.monospacedSystemFont(ofSize: baseSize * 0.8, weight: .semibold)
        let attributed = NSAttributedString(
            string: glyph, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        // Place just past the span's end, vertically centred on the line.
        let p = NSPoint(x: rect.maxX + 1, y: rect.midY - size.height / 2)
        attributed.draw(at: p)
    }
}

// MARK: - Margin rail

/// Right-margin comment rail. For each review annotation with an anchor in (or
/// near) the visible range, draws a slip card — author colour left border,
/// small-caps author name, body (+ replacement for suggestions) — vertically
/// near its line, joined to the span by a thin leader line. Installed as a
/// subview of the text view at the right inset, mirroring the gutter.
final class ReviewMarginRailView: NSView {

    weak var coordinator: EditorCoordinator?
    weak var associatedTextView: NSTextView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScroll(of: associatedTextView, target: self)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func handleScroll(_ note: Notification) { needsDisplay = true }

    private let cardWidth: CGFloat = 180
    private let cardPadding: CGFloat = 8
    private let cardGap: CGFloat = 8
    private let leaderGap: CGFloat = 6

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        layer?.backgroundColor = NSColor.clear.cgColor
        guard let textView = associatedTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let coordinator,
              coordinator.isReviewMode else { return }

        let marks = coordinator.resolvedReviewMarks
        guard !marks.isEmpty else { return }

        let inset = textView.textContainerInset
        let visibleRect = textView.visibleRect
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: container)
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        // Resolve each visible mark's anchor Y (in this view's coordinate space,
        // which shares the text view's flipped Y origin). The rail is framed at
        // x = textView.bounds.width - railWidth in updateColumnInset, so the
        // text view's container Y maps directly to our Y after the inset offset.
        struct Placed {
            let mark: ResolvedReviewMark
            let anchorY: CGFloat       // line top in our coords
            let anchorRightX: CGFloat  // span right edge in text-view coords
            var cardY: CGFloat         // assigned after stacking
            let height: CGFloat
        }

        var placed: [Placed] = []
        for mark in marks {
            let anchorLoc = mark.railAnchorLocation
            let anchorRange = mark.absoluteRange ?? NSRange(location: anchorLoc, length: 0)
            guard NSLocationInRange(anchorLoc, visibleCharRange)
                    || NSIntersectionRange(anchorRange, visibleCharRange).length > 0
            else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: anchorLoc, length: max(anchorRange.length, 1)),
                actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let anchorY = rect.origin.y + inset.height
            let anchorRightX = rect.maxX + inset.width
            let height = cardHeight(for: mark)
            placed.append(Placed(
                mark: mark, anchorY: anchorY,
                anchorRightX: anchorRightX, cardY: anchorY, height: height))
        }

        // Simple downward-nudge stacking so cards don't overlap (v1).
        placed.sort { $0.anchorY < $1.anchorY }
        var cursorY: CGFloat = -.greatestFiniteMagnitude
        for i in placed.indices {
            let y = max(placed[i].anchorY, cursorY)
            placed[i].cardY = y
            cursorY = y + placed[i].height + cardGap
        }

        let railX = bounds.minX + 4
        for p in placed {
            let cardRect = NSRect(
                x: railX, y: p.cardY, width: cardWidth, height: p.height)
            drawCard(p.mark, in: cardRect)
            // Leader: from the span's right edge (in text-view coords, which is
            // to the LEFT of this view's origin → negative x here) to the card.
            drawLeader(
                fromX: p.anchorRightX - frame.minX, fromY: p.anchorY,
                toX: cardRect.minX, toY: cardRect.minY + 10,
                color: p.mark.color)
        }
    }

    private func cardHeight(for mark: ResolvedReviewMark) -> CGFloat {
        let bodyText = railBodyText(mark)
        let textWidth = cardWidth - 2 * cardPadding - 4  // 4 = border
        let bodyHeight = boundingHeight(bodyText, font: bodyFont, width: textWidth)
        return cardPadding + authorLineHeight + 2 + bodyHeight + cardPadding
    }

    private let authorLineHeight: CGFloat = 13
    private var bodyFont: NSFont { NSFont.systemFont(ofSize: 11) }
    private var authorFont: NSFont {
        NSFont.systemFont(ofSize: 9, weight: .semibold)
    }

    private func railBodyText(_ mark: ResolvedReviewMark) -> String {
        if mark.kind == .suggestedChange, let s = mark.suggestedText, !s.isEmpty {
            let body = mark.body.isEmpty ? "" : mark.body + "\n"
            return body + "→ " + s
        }
        return mark.body
    }

    private func boundingHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let bounds = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(14, ceil(bounds.height))
    }

    private func drawCard(_ mark: ResolvedReviewMark, in rect: NSRect) {
        // Card background.
        let bg = NSColor.textBackgroundColor.withAlphaComponent(0.96)
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        bg.setFill()
        bgPath.fill()
        // Subtle border.
        NSColor.separatorColor.setStroke()
        bgPath.lineWidth = 0.5
        bgPath.stroke()
        // Author-colour left border.
        let border = NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height)
        mark.color.setFill()
        NSBezierPath(rect: border).fill()

        // Author name (small-caps-ish via uppercase + tracking).
        let authorAttr = NSAttributedString(
            string: mark.authorName.uppercased(),
            attributes: [
                .font: authorFont,
                .foregroundColor: mark.color,
                .kern: 0.5])
        authorAttr.draw(at: NSPoint(x: rect.minX + cardPadding, y: rect.minY + cardPadding))

        // Body (+ replacement).
        let bodyAttr = NSAttributedString(
            string: railBodyText(mark),
            attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor])
        let bodyRect = NSRect(
            x: rect.minX + cardPadding,
            y: rect.minY + cardPadding + authorLineHeight + 2,
            width: cardWidth - 2 * cardPadding - 4,
            height: rect.height - cardPadding * 2 - authorLineHeight - 2)
        bodyAttr.draw(with: bodyRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private func drawLeader(
        fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat, color: NSColor
    ) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: fromX, y: fromY))
        path.line(to: NSPoint(x: toX - leaderGap, y: toY))
        path.lineWidth = 0.75
        color.withAlphaComponent(0.6).setStroke()
        path.stroke()
    }
}
