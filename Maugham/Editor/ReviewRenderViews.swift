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
    /// True iff authored by the local reviewer (gates Edit / Delete on the
    /// interactive margin card). Computed in `recomputeReviewMarks` from
    /// `AnnotationOwnership.isOwn` against the local collaborator name.
    let isOwn: Bool
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
            // A card mid-"stet" reinstates the text — drop its inline strike so
            // the manuscript reads as left-standing during the brief dwell.
            if coordinator.stetReviewCardId == mark.id { continue }
            guard let range = mark.absoluteRange,
                  NSIntersectionRange(range, visibleCharRange).length > 0 else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)

            // Draw the underline/strike PER LINE FRAGMENT, not from a single
            // union boundingRect (Bug C): a span that wraps onto a second visual
            // line yields a union rect whose single horizontal stroke lands
            // between the two lines (invisible) or mis-placed. enumerate one rect
            // per visual line the glyph range covers and stroke each. The end
            // marker (query/caret) goes after the LAST fragment.
            var fragmentRects: [NSRect] = []
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                fragmentRects.append(NSRect(
                    x: rect.origin.x + inset.width,
                    y: rect.origin.y + inset.height,
                    width: rect.size.width,
                    height: rect.size.height))
            }
            guard !fragmentRects.isEmpty else { continue }
            draw(mark: mark, inFragments: fragmentRects)
        }
    }

    private func draw(mark: ResolvedReviewMark, inFragments rects: [NSRect]) {
        let color = mark.color
        switch mark.kind {
        case .comment, .craftNote:
            for rect in rects { drawUnderline(in: rect, color: color) }
        case .query:
            for rect in rects { drawUnderline(in: rect, color: color) }
            drawQueryMarker(at: rects[rects.count - 1], color: color)
        case .suggestedChange:
            for rect in rects { drawStrikethrough(in: rect, color: color) }
            drawEndMarker("\u{2038}", at: rects[rects.count - 1], color: color)  // ‸ caret
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

    /// The proofreader's query mark (Bug D): a legible small-caps "Qy?" in the
    /// author colour, set on a subtle rounded chip so it reads as an editorial
    /// mark rather than a stray "?" floating after the span.
    private func drawQueryMarker(at rect: NSRect, color: NSColor) {
        let baseSize = associatedTextView?.font?.pointSize ?? 13
        let font = NSFont.systemFont(ofSize: baseSize * 0.72, weight: .bold)
        let attributed = NSAttributedString(
            string: "Qy?",
            attributes: [.font: font, .foregroundColor: color, .kern: 0.3])
        let textSize = attributed.size()

        let padX: CGFloat = 3
        let padY: CGFloat = 1
        let chipWidth = textSize.width + padX * 2
        let chipHeight = textSize.height + padY * 2
        let chipRect = NSRect(
            x: rect.maxX + 2,
            y: rect.midY - chipHeight / 2,
            width: chipWidth,
            height: chipHeight)

        let chip = NSBezierPath(roundedRect: chipRect, xRadius: 3, yRadius: 3)
        color.withAlphaComponent(0.12).setFill()
        chip.fill()
        color.withAlphaComponent(0.45).setStroke()
        chip.lineWidth = 0.75
        chip.stroke()

        attributed.draw(at: NSPoint(
            x: chipRect.minX + padX,
            y: chipRect.minY + padY))
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

    /// Hit-test only the card rects — clicks elsewhere in the rail (the empty
    /// gutter, leader lines) pass through to the text view so selection still
    /// works. The actions row is a real subview, so it hit-tests itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in our SUPERVIEW's coordinates; convert to our own once.
        let local = convert(point, from: superview)
        // Let the actions-row buttons (a subview) claim their own hits first.
        // NSView.hitTest takes a point in the receiver's SUPERVIEW (= self) coords,
        // so `local` is exactly right here.
        if let actions = actionsRow, !actions.isHidden {
            if let hit = actions.hitTest(local) { return hit }
        }
        if cardRects.contains(where: { $0.rect.contains(local) }) { return self }
        return nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Leader lines run from the annotated span (which sits to the LEFT of
        // the rail, i.e. at a negative local X) across to the slip card. With
        // the default masked layer those left-of-origin segments are clipped at
        // the rail's leading edge; opt out so the leader renders the full way.
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScroll(of: associatedTextView, target: self)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func handleScroll(_ note: Notification) {
        // Scrolling moves the cards — reposition (or hide) the actions row.
        needsDisplay = true
        repositionActionsRow()
    }

    private let cardWidth: CGFloat = 180
    private let cardPadding: CGFloat = 8
    private let cardGap: CGFloat = 8
    private let leaderGap: CGFloat = 6
    /// Vertical room reserved under the selected card for the inline actions row.
    private let actionsRowHeight: CGFloat = 26

    // MARK: - Interaction (Part 1)

    /// Per-card rects captured during the last `draw` (in this view's flipped
    /// coords), used for click hit-testing and to position the actions row.
    private var cardRects: [(id: String, rect: NSRect)] = []
    /// The inline actions row (a plain NSStackView of NSButtons) shown on the
    /// selected card. NOT an NSPopover (tripwire 7). Rebuilt when the selection
    /// changes; repositioned on scroll/redraw.
    private var actionsRow: NSStackView?

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let hit = cardRects.first(where: { $0.rect.contains(local) }) {
            coordinator?.selectReviewCard(id: hit.id)
        } else {
            coordinator?.clearReviewCardSelection()
        }
    }

    /// The selected card's rect in this view's coords, or nil if not laid out /
    /// off-screen. Used by the coordinator to place the Edit/Reply composer.
    func cardRect(forAnnotationId id: String) -> NSRect? {
        cardRects.first(where: { $0.id == id })?.rect
    }

    /// Rebuild the actions row for the current selection and redraw. Called by
    /// the coordinator when `selectedReviewCardId` changes.
    func reloadCardSelection() {
        rebuildActionsRow()
        needsDisplay = true
    }

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

        let selectedId = coordinator.selectedReviewCardId

        // Simple downward-nudge stacking so cards don't overlap (v1). The
        // selected card reserves extra room beneath it for the inline actions
        // row so the next card doesn't collide with it.
        placed.sort { $0.anchorY < $1.anchorY }
        var cursorY: CGFloat = -.greatestFiniteMagnitude
        for i in placed.indices {
            let y = max(placed[i].anchorY, cursorY)
            placed[i].cardY = y
            let extra = (placed[i].mark.id == selectedId) ? actionsRowHeight : 0
            cursorY = y + placed[i].height + extra + cardGap
        }

        let railX = bounds.minX + 4
        cardRects = []
        for p in placed {
            let cardRect = NSRect(
                x: railX, y: p.cardY, width: cardWidth, height: p.height)
            cardRects.append((id: p.mark.id, rect: cardRect))
            let isStet = (coordinator.stetReviewCardId == p.mark.id)
            drawCard(p.mark, in: cardRect, selected: p.mark.id == selectedId, stet: isStet)
            // Leader: from the span's right edge (in text-view coords, which is
            // to the LEFT of this view's origin → negative x here) to the card.
            drawLeader(
                fromX: p.anchorRightX - frame.minX, fromY: p.anchorY,
                toX: cardRect.minX, toY: cardRect.minY + 10,
                color: p.mark.color)
        }
        // Position the actions row after the card rects are known.
        repositionActionsRow()
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

    /// Editor's-ink colour for the STET acknowledgement — distinct from the
    /// author colour and the red/green diff so it reads as its own gesture.
    private let stetColor = NSColor(
        calibratedRed: 0.20, green: 0.45, blue: 0.78, alpha: 1)

    private func drawCard(
        _ mark: ResolvedReviewMark, in rect: NSRect, selected: Bool, stet: Bool = false
    ) {
        if stet { drawStetCard(mark, in: rect); return }
        // Selected cards get a subtle lift: a soft author-colour glow ring drawn
        // just outside the card edge so the emphasis reads without shifting layout.
        if selected {
            let glow = NSBezierPath(
                roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: 5, yRadius: 5)
            mark.color.withAlphaComponent(0.18).setFill()
            glow.fill()
        }
        // Card background.
        let bg = NSColor.textBackgroundColor.withAlphaComponent(0.96)
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        bg.setFill()
        bgPath.fill()
        // Border — author colour + heavier when selected, else subtle separator.
        if selected {
            mark.color.withAlphaComponent(0.8).setStroke()
            bgPath.lineWidth = 1.25
        } else {
            NSColor.separatorColor.setStroke()
            bgPath.lineWidth = 0.5
        }
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

    /// The "stet" acknowledgement painted briefly on a card whose suggested
    /// change was just rejected: a tinted card, a bold "STET" chip + "let it
    /// stand", and the suggestion's text reinstated with a dotted underline (the
    /// proofreader's "leave it as it was" mark). Held ~2s by the coordinator.
    private func drawStetCard(_ mark: ResolvedReviewMark, in rect: NSRect) {
        // Card background + tinted border in the stet ink.
        let bg = NSColor.textBackgroundColor.withAlphaComponent(0.96)
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        bg.setFill(); bgPath.fill()
        stetColor.withAlphaComponent(0.12).setFill(); bgPath.fill()
        stetColor.withAlphaComponent(0.55).setStroke()
        bgPath.lineWidth = 1.0
        bgPath.stroke()
        // Left border in stet ink.
        let border = NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height)
        stetColor.setFill()
        NSBezierPath(rect: border).fill()

        // "STET" chip.
        let chipFont = NSFont.systemFont(ofSize: 9, weight: .bold)
        let chipText = NSAttributedString(
            string: "STET",
            attributes: [.font: chipFont, .foregroundColor: NSColor.white, .kern: 0.5])
        let chipTextSize = chipText.size()
        let chipPadX: CGFloat = 4, chipPadY: CGFloat = 1
        let chipRect = NSRect(
            x: rect.minX + cardPadding,
            y: rect.minY + cardPadding,
            width: chipTextSize.width + chipPadX * 2,
            height: chipTextSize.height + chipPadY * 2)
        let chipPath = NSBezierPath(roundedRect: chipRect, xRadius: 3, yRadius: 3)
        stetColor.setFill(); chipPath.fill()
        chipText.draw(at: NSPoint(x: chipRect.minX + chipPadX, y: chipRect.minY + chipPadY))

        // "let it stand" beside the chip.
        let standFont = NSFont(
            descriptor: NSFont.systemFont(ofSize: 10).fontDescriptor
                .withSymbolicTraits(.italic),
            size: 10) ?? NSFont.systemFont(ofSize: 10)
        let stand = NSAttributedString(
            string: "let it stand",
            attributes: [.font: standFont, .foregroundColor: stetColor])
        stand.draw(at: NSPoint(
            x: chipRect.maxX + 5,
            y: rect.minY + cardPadding + (chipRect.height - stand.size().height) / 2))

        // Reinstated text (the suggestion text struck-no-more), dotted-underlined.
        let reinstated = railBodyText(mark)
        let para = NSMutableParagraphStyle()
        let bodyAttr = NSAttributedString(
            string: reinstated,
            attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor,
                .underlineStyle: (NSUnderlineStyle.single.rawValue
                    | NSUnderlineStyle.patternDot.rawValue),
                .underlineColor: stetColor,
                .paragraphStyle: para])
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

    // MARK: - Inline actions row

    /// Tear down + rebuild the actions row for the current selection. The row is
    /// a plain NSStackView of small NSButtons (NOT an NSPopover — tripwire 7),
    /// one per `ReviewCardActions.actions(for:isOwn:)`, gated by kind + ownership.
    private func rebuildActionsRow() {
        actionsRow?.removeFromSuperview()
        actionsRow = nil
        guard let coordinator,
              let selectedId = coordinator.selectedReviewCardId,
              let mark = coordinator.resolvedReviewMarks.first(where: { $0.id == selectedId })
        else { return }

        let actions = ReviewCardActions.actions(for: mark.kind, isOwn: mark.isOwn)
        guard !actions.isEmpty else { return }

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.detachesHiddenViews = true
        for action in actions {
            let label = action.label(for: mark.kind)
            let button = NSButton(
                title: "", target: self, action: #selector(actionButtonTapped(_:)))
            // Icon-only so nothing truncates in the narrow (180pt) card; the
            // label becomes the hover tooltip.
            button.image = NSImage(
                systemSymbolName: action.systemImageName, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.toolTip = label
            // Destructive tint for Delete.
            if action == .delete {
                button.contentTintColor = .systemRed
            }
            button.identifier = NSUserInterfaceItemIdentifier(actionTag(action))
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        actionsRow = stack
        repositionActionsRow()
    }

    /// Place the actions row just under the selected card (or hide it if the
    /// selected card scrolled out of the laid-out set).
    private func repositionActionsRow() {
        guard let stack = actionsRow,
              let coordinator,
              let selectedId = coordinator.selectedReviewCardId,
              let cardRect = cardRects.first(where: { $0.id == selectedId })?.rect
        else { actionsRow?.isHidden = true; return }
        stack.isHidden = false
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        stack.setFrameOrigin(NSPoint(
            x: cardRect.minX + 2,
            y: cardRect.maxY + 3))
        stack.setFrameSize(NSSize(
            width: min(size.width, cardWidth),
            height: max(size.height, 18)))
    }

    /// Stable id<->action mapping so the button target/action can recover which
    /// action + annotation was tapped without capturing closures per button.
    private func actionTag(_ action: ReviewCardAction) -> String {
        switch action {
        case .accept:  return "accept"
        case .reject:  return "reject"
        case .archive: return "archive"
        case .reply:   return "reply"
        case .edit:    return "edit"
        case .delete:  return "delete"
        }
    }

    private func action(fromTag tag: String?) -> ReviewCardAction? {
        switch tag {
        case "accept":  return .accept
        case "reject":  return .reject
        case "archive": return .archive
        case "reply":   return .reply
        case "edit":    return .edit
        case "delete":  return .delete
        default:        return nil
        }
    }

    @objc private func actionButtonTapped(_ sender: NSButton) {
        guard let coordinator,
              let selectedId = coordinator.selectedReviewCardId,
              let action = action(fromTag: sender.identifier?.rawValue)
        else { return }
        coordinator.performReviewCardAction(action, annotationId: selectedId)
    }
}
