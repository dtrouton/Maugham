import AppKit
import MaughamCore

// MARK: - The placement maths (pure)

/// **Where a resolved label goes** (report foundations plan 3b Task 6,
/// R-3b-1): small and faint in the line-spacing gap directly beneath the end
/// of its raw marker, when the gap holds it; otherwise only while the caret is
/// in the marker or the pointer is over it, as a small tag above the line.
/// Nothing here changes layout: the label is drawn, never reserved.
enum ReferenceLabelLayout {
    /// The label's size against the body's (R-3b-1: "about 0.65×").
    static let sizeRatio: CGFloat = 0.65
    /// No label is drawn smaller than this, whatever the body size.
    static let minimumPointSize: CGFloat = 9
    /// The tag's inner padding, horizontal and vertical.
    static let tagPadding = CGSize(width: 4, height: 1)

    static func labelPointSize(forBody body: CGFloat) -> CGFloat {
        max(minimumPointSize, (body * sizeRatio).rounded(.toNearestOrEven))
    }

    /// The label's ink: its cap height down to its descender (`descender` is
    /// negative, as `NSFont` gives it). Digits, capitals, parentheses and a
    /// "g" all sit inside it.
    static func inkHeight(capHeight: CGFloat, descender: CGFloat) -> CGFloat {
        (capHeight - descender).rounded(.up)
    }

    /// **The fit rule**: the label fits beneath its line when its ink is no
    /// taller than the gap the paragraph's line spacing leaves under the line
    /// (`NSParagraphStyle.lineSpacing`, `ProseMode`'s
    /// `pointSize × (lineHeightMultiplier − 1)`). Paragraph spacing is never
    /// counted: a marker's line is rarely its paragraph's last, and a figure
    /// line's spacing holds its thumbnail.
    static func fits(inkHeight: CGFloat, lineSpacing: CGFloat) -> Bool {
        inkHeight > 0 && inkHeight <= lineSpacing
    }

    /// The point to draw a label at (`NSString.draw(at:)` in a flipped view:
    /// its top-left, the baseline an ascender below), beneath a marker: its
    /// ink centred in the gap under the line, its right edge on the marker's,
    /// kept inside the column.
    ///
    /// - Parameters:
    ///   - markerMaxX: the right edge of the marker's last glyph.
    ///   - gapTop: where the line's own glyphs end: its baseline plus the
    ///     body font's descent and leading.
    static func beneathOrigin(markerMaxX: CGFloat, gapTop: CGFloat, lineSpacing: CGFloat,
                              labelWidth: CGFloat, ascender: CGFloat, capHeight: CGFloat,
                              inkHeight: CGFloat, column: ClosedRange<CGFloat>) -> CGPoint {
        let inkTop = gapTop + max(0, (lineSpacing - inkHeight) / 2)
        let baseline = inkTop + capHeight
        return CGPoint(x: clampedX(rightEdge: markerMaxX, width: labelWidth, column: column),
                       y: baseline - ascender)
    }

    /// The tag drawn above the line when the label doesn't fit beneath:
    /// padded around the label, its bottom just above the line's top, its
    /// right edge on the marker's, kept inside the column.
    static func tagFrame(markerMaxX: CGFloat, lineTop: CGFloat, labelSize: CGSize,
                         column: ClosedRange<CGFloat>) -> CGRect {
        let size = CGSize(width: labelSize.width + 2 * tagPadding.width,
                          height: labelSize.height + 2 * tagPadding.height)
        return CGRect(x: clampedX(rightEdge: markerMaxX, width: size.width, column: column),
                      y: lineTop - 1 - size.height, width: size.width, height: size.height)
    }

    /// Right-aligned on `rightEdge`, then pushed inside `column` (the left
    /// edge wins when the label is wider than the column).
    static func clampedX(rightEdge: CGFloat, width: CGFloat, column: ClosedRange<CGFloat>) -> CGFloat {
        let x = min(rightEdge, column.upperBound) - width
        return max(column.lowerBound, x)
    }
}

// MARK: - The overlay

/// Transparent, click-through overlay over the text view that draws each
/// visible citation's, cross-reference's and footnote reference's resolved
/// label (R-3b-1, R-3b-2). Modelled on `FigureThumbnailOverlay`: it draws only
/// the visible range, from the coordinator's cached markers and the cached
/// index (tripwire 4); repaints on a text change, a storage edit (the focus
/// dim), scroll, a caret move and a new index version, never by restyling.
/// Installed above the thumbnails and below the completion list, which lives
/// in the scroll view.
final class ReferenceLabelOverlay: NSView {
    weak var coordinator: EditorCoordinator?
    weak var associatedTextView: NSTextView?

    /// The last draw's readings (the mounted tests'): labels drawn beneath
    /// their markers, and tags drawn above their lines.
    private(set) var lastBeneathCount = 0
    private(set) var lastTagCount = 0
    /// Markers in view whose label didn't fit, and where each sits: what the
    /// pointer can hover, and what a caret move repaints for.
    private(set) var hoverTargets: [(rect: CGRect, range: NSRange)] = []
    /// The marker the pointer is over, if its label waits for a hover.
    private(set) var hoveredMarker: NSRange?
    /// How many observed changes asked for a repaint.
    private(set) var repaintRequests = 0

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
        observe()
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func observe() {
        let nc = NotificationCenter.default
        nc.removeObserver(self)
        guard let textView = associatedTextView else { return }
        nc.addObserver(self, selector: #selector(repaint(_:)),
                       name: NSText.didChangeNotification, object: textView)
        nc.addObserver(self, selector: #selector(caretMoved(_:)),
                       name: NSTextView.didChangeSelectionNotification, object: textView)
        if let storage = textView.textStorage {
            nc.addObserver(self, selector: #selector(repaint(_:)),
                           name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            nc.addObserver(self, selector: #selector(repaint(_:)),
                           name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    /// Skipped when the document holds no marker now and none was drawn: a
    /// marker-free manuscript never repaints its labels.
    @objc private func repaint(_ note: Notification) {
        guard lastBeneathCount + lastTagCount > 0 || !hoverTargets.isEmpty
                || coordinator?.referenceMarkerTokens.isEmpty == false else { return }
        repaintRequests += 1
        needsDisplay = true
    }

    /// A caret move matters only to a label that waits for the caret.
    @objc private func caretMoved(_ note: Notification) {
        guard lastTagCount > 0 || !hoverTargets.isEmpty else { return }
        repaintRequests += 1
        needsDisplay = true
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hover(at: nil)
    }

    /// The pointer is at `point` (this view's coordinates), or gone: a
    /// linear look over the few markers in view whose label waits, and a
    /// repaint only when the hovered one changes.
    func hover(at point: CGPoint?) {
        let found = point.flatMap { p in hoverTargets.first { $0.rect.contains(p) }?.range }
        guard found != hoveredMarker else { return }
        hoveredMarker = found
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        lastBeneathCount = 0
        lastTagCount = 0
        hoverTargets = []
        guard let textView = associatedTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage,
              let coordinator, coordinator.showsReferenceMarks,
              !coordinator.referenceMarkerTokens.isEmpty,
              let index = coordinator.referenceIndex?() else { return }
        let length = storage.length

        // A label hangs below its line: look a line higher than the view's top.
        let origin = textView.textContainerOrigin
        var probe = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        probe.origin.y -= 40
        probe.size.height += 80
        let glyphs = layoutManager.glyphRange(forBoundingRect: probe, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let groups = coordinator.referenceGroups(intersecting: chars)
        guard !groups.isEmpty else { return }

        let padding = container.lineFragmentPadding
        let column = (origin.x + padding)...(origin.x + max(padding, container.size.width - padding))
        let caret = textView.selectedRange()
        let background = textView.backgroundColor
        var drawnOnLine: (top: CGFloat, frames: [CGRect]) = (.nan, [])

        for group in groups {
            guard group.range.length > 0, NSMaxRange(group.range) <= length,
                  let text = ManuscriptChecks.labelText(
                    for: group, index: index, footnoteNumbers: coordinator.footnoteNumbers)
            else { continue }
            let last = NSMaxRange(group.range) - 1
            let glyph = layoutManager.glyphIndexForCharacter(at: last)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let markerGlyphs = layoutManager.glyphRange(forCharacterRange: group.range,
                                                        actualCharacterRange: nil)
            var markerRect = layoutManager.boundingRect(forGlyphRange: markerGlyphs, in: container)
            markerRect = markerRect.offsetBy(dx: origin.x, dy: origin.y)
            let lastRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let markerMaxX = lastRect.maxX + origin.x
            let baseline = lineRect.minY + layoutManager.location(forGlyphAt: glyph).y + origin.y
            let lineTop = lineRect.minY + origin.y

            let attributes = storage.attributes(at: last, effectiveRange: nil)
            let body = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
            let lineSpacing = (attributes[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing ?? 0
            // The marker's own colour, faint; its alpha carries the focus dim.
            let ink = (attributes[.foregroundColor] as? NSColor) ?? NSColor.textColor
            let font = NSFont.systemFont(ofSize: ReferenceLabelLayout.labelPointSize(forBody: body.pointSize))
            let label = text as NSString
            let style: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: ink.withAlphaComponent(ink.alphaComponent * 0.55),
            ]
            let size = label.size(withAttributes: style)
            let inkHeight = ReferenceLabelLayout.inkHeight(capHeight: font.capHeight,
                                                           descender: font.descender)

            if ReferenceLabelLayout.fits(inkHeight: inkHeight, lineSpacing: lineSpacing) {
                let point = ReferenceLabelLayout.beneathOrigin(
                    markerMaxX: markerMaxX,
                    gapTop: baseline - body.descender + body.leading,
                    lineSpacing: lineSpacing, labelWidth: size.width,
                    ascender: font.ascender, capHeight: font.capHeight,
                    inkHeight: inkHeight, column: column)
                let frame = CGRect(origin: point, size: size)
                // Two markers close on one line: the later label gives way.
                if drawnOnLine.top != lineTop { drawnOnLine = (lineTop, []) }
                guard !drawnOnLine.frames.contains(where: { $0.intersects(frame) }) else { continue }
                drawnOnLine.frames.append(frame)
                lastBeneathCount += 1
                if frame.intersects(dirtyRect) { label.draw(at: point, withAttributes: style) }
            } else {
                hoverTargets.append((markerRect, group.range))
                let caretIn = caret.location >= group.range.location
                    && caret.location <= NSMaxRange(group.range)
                guard caretIn || hoveredMarker == group.range else { continue }
                let frame = ReferenceLabelLayout.tagFrame(
                    markerMaxX: markerMaxX, lineTop: lineTop, labelSize: size, column: column)
                lastTagCount += 1
                guard frame.intersects(dirtyRect) else { continue }
                let box = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
                background.withAlphaComponent(0.95).setFill()
                box.fill()
                ink.withAlphaComponent(0.25 * ink.alphaComponent).setStroke()
                box.lineWidth = 0.5
                box.stroke()
                var tagStyle = style
                tagStyle[.foregroundColor] = ink.withAlphaComponent(ink.alphaComponent * 0.8)
                label.draw(at: CGPoint(x: frame.minX + ReferenceLabelLayout.tagPadding.width,
                                       y: frame.minY + ReferenceLabelLayout.tagPadding.height),
                           withAttributes: tagStyle)
            }
        }
    }
}

// MARK: - The coordinator's side

extension EditorCoordinator {
    /// Whether this surface draws labels and problem marks: a manuscript's
    /// prose editor with the window's index (only `EditorHost` builds one and
    /// sets `answersInsertCommands`). A research note, a statement and a
    /// screenplay get neither.
    var showsReferenceMarks: Bool {
        answersInsertCommands && referenceIndex != nil && mode is ProseMode && !isDetached
    }

    /// Install the label overlay on a surface that shows labels. Idempotent;
    /// called from `attach` after the thumbnails, so it sits above them.
    func syncReferenceLabelOverlay() {
        guard let textView, showsReferenceMarks, referenceLabelOverlay == nil else { return }
        let overlay = ReferenceLabelOverlay(frame: textView.bounds)
        overlay.coordinator = self
        overlay.associatedTextView = textView
        overlay.autoresizingMask = [.width, .height]
        textView.addSubview(overlay)
        referenceLabelOverlay = overlay
    }

    /// Re-framed on resize from `MaughamTextView.updateColumnInset`, with the
    /// problem tooltips when the column's width changed.
    func layoutReferenceLabelOverlay(in textView: NSTextView) {
        if let overlay = referenceLabelOverlay {
            overlay.frame = textView.bounds
            overlay.needsDisplay = true
        }
        if let width = textView.textContainer?.size.width,
           let tooltips = problemTooltips, tooltips.width != width {
            rebuildProblemTooltips()
        }
    }

    /// The marker groups holding a marker token inside `chars`: the visible
    /// range's markers, each block read once and remembered by its text, so a
    /// repaint re-reads only a paragraph that changed (tripwire 4).
    func referenceGroups(intersecting chars: NSRange) -> [ManuscriptChecks.Group] {
        guard let textView else { return [] }
        let text = textView.string as NSString
        let markers = referenceMarkerTokens
        // The first marker that could reach `chars`: binary search on location.
        var lo = 0, hi = markers.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(markers[mid]) < chars.location { lo = mid + 1 } else { hi = mid }
        }
        var out: [ManuscriptChecks.Group] = []
        var i = lo
        while i < markers.count, markers[i].location <= NSMaxRange(chars) {
            let block = ManuscriptChecks.enclosingBlock(of: markers[i].location, in: text)
            var inBlock: [NSRange] = []
            while i < markers.count, markers[i].location < NSMaxRange(block) {
                inBlock.append(markers[i])
                i += 1
            }
            let blockText = text.substring(with: block)
            let groups: [ManuscriptChecks.Group]
            if let held = referenceGroupCache[blockText] {
                groups = held
            } else {
                groups = ManuscriptChecks.groups(inBlockText: blockText)
                if referenceGroupCache.count >= 256 { referenceGroupCache.removeAll() }
                referenceGroupCache[blockText] = groups
            }
            for group in groups {
                let placed = group.shifted(by: block.location)
                guard NSIntersectionRange(placed.range, chars).length > 0,
                      inBlock.contains(where: { NSIntersectionRange($0, placed.range).length > 0 })
                else { continue }
                out.append(placed)
            }
        }
        return out
    }
}
