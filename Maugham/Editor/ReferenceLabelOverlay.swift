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

// MARK: - The caption bar (pure)

/// **A figure line as a caption bar** (report plan 7b Task 8, spec §3.2):
/// its syntax faded until the caret enters it (`ProseMode`'s paint and the
/// coordinator's un-fade), and "Table 2." / "Figure 3." drawn beside it by
/// the label overlay (R7b-1). The number is the book's: the index's
/// `NumbersBefore` for this document plus the line's ordinal in it, counted
/// as `ReferenceIndex.PieceSummary` counts — every pipe table and every
/// table figure line (a `.csv` line labelled `tbl:` or unlabelled, R7a-1)
/// in the Tables list, every other figure line in the Figures list.
enum FigureCaptionBar {
    /// One figure line of the live text.
    struct Line: Equatable {
        /// The line, without its terminator.
        let lineRange: NSRange
        /// Which list it numbers in: `.tbl` or `.fig`.
        let kind: ManuscriptLabel.Kind
        /// Its place in that list within this document, from 1.
        let ordinal: Int
        /// Its `![`, `](path)` and `{#…}` token ranges, in order.
        let syntax: [NSRange]

        /// The book's number for this line, after `before`.
        func number(after before: ReferenceIndex.NumbersBefore) -> Int {
            ordinal + (kind == .tbl ? before.tablesBefore : before.figuresBefore)
        }

        /// "Table 2." or "Figure 3.", in the book's words.
        func caption(after before: ReferenceIndex.NumbersBefore, words: ElementWords) -> String {
            "\(kind == .tbl ? words.table : words.figure) \(number(after: before))."
        }
    }

    /// The figure lines of `tokens` (the live text's), in document order, one
    /// pass over the tokens.
    static func lines(tokens: [Token], text: NSString) -> [Line] {
        var figures: [(line: NSRange, path: String)] = []
        var tables: [Int] = []
        var syntax: [Int: [NSRange]] = [:]   // by line start
        for token in tokens {
            switch token.kind {
            case .tableBlock:
                tables.append(token.range.location)
            case .figureSyntax, .attributeBlock:
                guard NSMaxRange(token.range) <= text.length else { continue }
                let start = text.lineRange(for: NSRange(location: token.range.location, length: 0)).location
                syntax[start, default: []].append(token.range)
                if let path = FigureThumbnailLayout.figurePath(closing: token, in: text) {
                    var lineStart = 0, end = 0, contentsEnd = 0
                    text.getLineStart(&lineStart, end: &end, contentsEnd: &contentsEnd,
                                      for: NSRange(location: token.range.location, length: 0))
                    figures.append((NSRange(location: lineStart, length: contentsEnd - lineStart), path))
                }
            default:
                continue
            }
        }
        guard !figures.isEmpty else { return [] }
        figures.sort { $0.line.location < $1.line.location }
        tables.sort()
        var out: [Line] = []
        var tableCount = 0, figureCount = 0, nextTable = 0
        for figure in figures {
            while nextTable < tables.count, tables[nextTable] < figure.line.location {
                tableCount += 1
                nextTable += 1
            }
            let content = text.substring(with: figure.line).trimmingCharacters(in: .whitespaces)
            let label = ManuscriptAttributes.split(content).label
            let kind = ManuscriptLabel.Kind.ofFigureLine(path: figure.path, label: label)
            let ordinal: Int
            if kind == .tbl { tableCount += 1; ordinal = tableCount } else { figureCount += 1; ordinal = figureCount }
            out.append(Line(lineRange: figure.line, kind: kind, ordinal: ordinal,
                            syntax: (syntax[figure.line.location] ?? []).sorted { $0.location < $1.location }))
        }
        return out
    }
}

extension ReferenceLabelLayout {
    /// The space between a caption number and the text column it sits beside.
    static let marginGap: CGFloat = 8

    /// **Where a caption number goes** (R7b-1): in the left margin, its right
    /// edge `marginGap` before the column, on the line's baseline (its
    /// top-left, for `NSString.draw(at:)` in a flipped view). Nil when the
    /// margin is too narrow to hold it inside the view (`viewMinX`): the
    /// overlay then falls back to its tag above the line.
    static func marginOrigin(columnMinX: CGFloat, viewMinX: CGFloat, labelWidth: CGFloat,
                             baseline: CGFloat, ascender: CGFloat) -> CGPoint? {
        let x = columnMinX - marginGap - labelWidth
        guard x >= viewMinX else { return nil }
        return CGPoint(x: x, y: baseline - ascender)
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
    /// Caption numbers drawn in the margin, and as tags above their lines
    /// (R7b-1), with the text of each, in order (the mounted tests').
    private(set) var lastMarginNumberCount = 0
    private(set) var lastCaptionTagCount = 0
    private(set) var lastCaptionTexts: [String] = []
    /// The ink each margin number was drawn in, in order.
    private(set) var lastMarginNumberInks: [NSColor] = []
    /// Markers in view whose label didn't fit, and where each sits: what the
    /// pointer can hover, and what a caret move repaints for.
    private(set) var hoverTargets: [(rect: CGRect, range: NSRange)] = []
    /// The marker the pointer is over, if its label waits for a hover.
    private(set) var hoveredMarker: NSRange?
    /// The waiting label (a `hoverTargets` range) the caret was in at the
    /// last draw or caret move: a caret move repaints only when it enters or
    /// leaves one (whole-branch review M2).
    private var caretTarget: NSRange?
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
                || lastMarginNumberCount + lastCaptionTagCount > 0
                || coordinator?.referenceMarkerTokens.isEmpty == false
                || coordinator?.hasFigureLines == true else { return }
        repaintRequests += 1
        needsDisplay = true
    }

    /// A caret move matters only to a label that waits for the caret, and
    /// only when the caret enters or leaves one: a move along a line, or
    /// across prose, repaints nothing.
    @objc private func caretMoved(_ note: Notification) {
        guard lastTagCount + lastCaptionTagCount > 0 || !hoverTargets.isEmpty,
              let textView = associatedTextView else { return }
        let now = target(atCaret: textView.selectedRange())
        guard now != caretTarget else { return }
        caretTarget = now
        repaintRequests += 1
        needsDisplay = true
    }

    /// The waiting label holding `caret` (its ends included, as the draw asks).
    private func target(atCaret caret: NSRange) -> NSRange? {
        hoverTargets.first {
            caret.location >= $0.range.location && caret.location <= NSMaxRange($0.range)
        }?.range
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
        lastMarginNumberCount = 0
        lastCaptionTagCount = 0
        lastCaptionTexts = []
        lastMarginNumberInks = []
        hoverTargets = []
        defer { caretTarget = associatedTextView.flatMap { target(atCaret: $0.selectedRange()) } }
        guard let textView = associatedTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage,
              let coordinator, coordinator.showsReferenceMarks,
              let index = coordinator.referenceIndex?() else { return }
        let hasMarkers = !coordinator.referenceMarkerTokens.isEmpty
        let captionLines = coordinator.hasFigureLines ? coordinator.figureCaptionLines : []
        guard hasMarkers || !captionLines.isEmpty else { return }
        let length = storage.length

        // A label hangs below its line: look a line higher than the view's top.
        let origin = textView.textContainerOrigin
        var probe = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        probe.origin.y -= 40
        probe.size.height += 80
        let glyphs = layoutManager.glyphRange(forBoundingRect: probe, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        let padding = container.lineFragmentPadding
        let column = (origin.x + padding)...(origin.x + max(padding, container.size.width - padding))
        let caret = textView.selectedRange()
        let background = textView.backgroundColor

        if !captionLines.isEmpty, let before = coordinator.figureNumbersBefore?() {
            drawCaptionNumbers(captionLines, in: chars, before: before, words: index.words,
                               column: column, caret: caret, background: background,
                               bodyInk: ProseMode.palette(for: coordinator.theme).bodyText,
                               dirtyRect: dirtyRect)
        }

        let groups = hasMarkers ? coordinator.referenceGroups(intersecting: chars) : []
        guard !groups.isEmpty else { return }
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

// MARK: - The caption numbers (R7b-1)

extension ReferenceLabelOverlay {
    /// Draws "Table 2." / "Figure 3." beside each figure line in `chars`: in
    /// the left margin, right-aligned to the column, in the line's own font
    /// and faint ink; when the margin cannot hold it, as the overlay's tag
    /// above the line, shown while the caret is on the line or the pointer
    /// over it. Nothing here changes layout, so card heights are unchanged.
    fileprivate func drawCaptionNumbers(
        _ lines: [FigureCaptionBar.Line], in chars: NSRange,
        before: ReferenceIndex.NumbersBefore, words: ElementWords,
        column: ClosedRange<CGFloat>, caret: NSRange, background: NSColor, bodyInk: NSColor,
        dirtyRect: NSRect
    ) {
        guard let textView = associatedTextView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let storage = textView.textStorage
        else { return }
        let origin = textView.textContainerOrigin
        // The first line that could reach `chars`: binary search on location.
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(lines[mid].lineRange) < chars.location { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < lines.count, lines[i].lineRange.location <= NSMaxRange(chars) {
            let line = lines[i]
            i += 1
            guard line.lineRange.length > 0, NSMaxRange(line.lineRange) <= storage.length else { continue }
            let text = line.caption(after: before, words: words) as NSString
            let first = line.lineRange.location
            let glyph = layoutManager.glyphIndexForCharacter(at: first)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = lineRect.minY + layoutManager.location(forGlyphAt: glyph).y + origin.y
            let lineTop = lineRect.minY + origin.y
            // The caption's own font and colour: the character after `![`. An
            // empty caption (`![](…)`, a converted uncaptioned table) has
            // none; its number takes the body's ink, with the line's focus
            // dim (the `]`'s alpha), never the faded `]`'s colour, which
            // would draw it fainter than a captioned line's (whole-branch M2).
            let captionStart = line.syntax.first.map(NSMaxRange) ?? first + 2
            let captioned = line.syntax.count >= 2 && line.syntax[1].location > captionStart
            let sample = min(captionStart, NSMaxRange(line.lineRange) - 1)
            let attributes = storage.attributes(at: sample, effectiveRange: nil)
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)
            let sampled = (attributes[.foregroundColor] as? NSColor) ?? NSColor.textColor
            let ink = captioned ? sampled : bodyInk.withAlphaComponent(sampled.alphaComponent)
            let style: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: ink.withAlphaComponent(ink.alphaComponent * 0.55),
            ]
            let size = text.size(withAttributes: style)

            if let point = ReferenceLabelLayout.marginOrigin(
                columnMinX: column.lowerBound, viewMinX: bounds.minX, labelWidth: size.width,
                baseline: baseline, ascender: font.ascender) {
                lastMarginNumberCount += 1
                lastCaptionTexts.append(text as String)
                lastMarginNumberInks.append(style[.foregroundColor] as? NSColor ?? ink)
                if CGRect(origin: point, size: size).intersects(dirtyRect) {
                    text.draw(at: point, withAttributes: style)
                }
                continue
            }
            // Too narrow a margin: the tag above the line, for the caret or the pointer.
            let lineGlyphs = layoutManager.glyphRange(forCharacterRange: line.lineRange,
                                                      actualCharacterRange: nil)
            let lineBox = layoutManager.boundingRect(forGlyphRange: lineGlyphs, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            hoverTargets.append((lineBox, line.lineRange))
            let caretIn = caret.location >= line.lineRange.location
                && caret.location <= NSMaxRange(line.lineRange)
            guard caretIn || hoveredMarker == line.lineRange else { continue }
            let small = NSFont.systemFont(ofSize: ReferenceLabelLayout.labelPointSize(forBody: font.pointSize))
            var tagStyle = style
            tagStyle[.font] = small
            tagStyle[.foregroundColor] = ink.withAlphaComponent(ink.alphaComponent * 0.8)
            let frame = ReferenceLabelLayout.tagFrame(
                markerMaxX: column.lowerBound, lineTop: lineTop,
                labelSize: text.size(withAttributes: tagStyle), column: column)
            lastCaptionTagCount += 1
            lastCaptionTexts.append(text as String)
            guard frame.intersects(dirtyRect) else { continue }
            let box = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
            background.withAlphaComponent(0.95).setFill()
            box.fill()
            ink.withAlphaComponent(0.25 * ink.alphaComponent).setStroke()
            box.lineWidth = 0.5
            box.stroke()
            text.draw(at: CGPoint(x: frame.minX + ReferenceLabelLayout.tagPadding.width,
                                  y: frame.minY + ReferenceLabelLayout.tagPadding.height),
                      withAttributes: tagStyle)
        }
    }
}

// MARK: - The coordinator's side

extension EditorCoordinator {
    /// The live text's figure lines as caption bars (`FigureCaptionBar`),
    /// derived from `lastTokens` once per retokenize, on first ask: what the
    /// un-fade and the caption numbers read on a caret move or a draw
    /// (tripwire 4). Empty off a manuscript.
    var figureCaptionLines: [FigureCaptionBar.Line] {
        if let cached = figureCaptionLinesCache { return cached }
        guard paintsFigureSyntaxFaded, hasFigureLines, let textView else { return [] }
        let lines = FigureCaptionBar.lines(tokens: lastTokens, text: textView.string as NSString)
        figureCaptionLinesCache = lines
        return lines
    }

    /// The figure line holding `location` (its ends included), by binary
    /// search over `figureCaptionLines`.
    func figureCaptionLine(at location: Int) -> FigureCaptionBar.Line? {
        let lines = figureCaptionLines
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(lines[mid].lineRange) < location { lo = mid + 1 } else { hi = mid }
        }
        guard lo < lines.count, lines[lo].lineRange.location <= location else { return nil }
        return lines[lo]
    }

    /// Install the label overlay on a surface that shows labels. Idempotent;
    /// called from `attach` after the thumbnails, so it sits above them.
    func syncReferenceLabelOverlay() {
        guard let textView, showsReferenceMarks else { return }
        if let stale = referenceLabelOverlay, stale.superview !== textView {
            stale.removeFromSuperview()   // never left on a replaced text view (`attach(to:)`)
            referenceLabelOverlay = nil
        }
        guard referenceLabelOverlay == nil else { return }
        let overlay = ReferenceLabelOverlay(frame: textView.bounds)
        overlay.coordinator = self
        overlay.associatedTextView = textView
        overlay.autoresizingMask = [.width, .height]
        textView.addSubview(overlay)
        referenceLabelOverlay = overlay
    }

    /// Re-framed on resize from `MaughamTextView.updateColumnInset`, with the
    /// problem tooltips when the column moved.
    func layoutReferenceLabelOverlay(in textView: NSTextView) {
        if let overlay = referenceLabelOverlay {
            overlay.frame = textView.bounds
            overlay.needsDisplay = true
        }
        rebuildProblemTooltipsIfTheColumnMoved(in: textView)
    }

    /// The tooltips' rects are laid out at one column width and container
    /// origin; when either moved (a resize re-wraps; an inset change —
    /// `refreshTypewriterInset`, which the typewriter and review toggles run —
    /// moves every line) they are rebuilt. A figure thumbnail landing moves
    /// nothing: its room is fixed by the text (`FigureThumbnailLayout
    /// .reservedHeight`), so it needs no rebuild.
    func rebuildProblemTooltipsIfTheColumnMoved(in textView: NSTextView) {
        if let width = textView.textContainer?.size.width,
           let tooltips = problemTooltips,
           tooltips.width != width || tooltips.origin != textView.textContainerOrigin {
            rebuildProblemTooltips()
        }
    }

    /// One block's marker groups, relative to it, remembered by the block's
    /// text: the label overlay's draw and the settle's checks share it, so
    /// neither re-scans a paragraph that did not change. Bounded by the text
    /// the keys hold (`referenceGroupCacheBudget`), not by a count: past it the
    /// cache starts over, and a block longer than the whole budget is scanned
    /// and not kept (whole-branch review M5).
    func cachedReferenceGroups(blockText: String) -> [ManuscriptChecks.Group] {
        if let held = referenceGroupCache[blockText] { return held }
        let groups = ManuscriptChecks.groups(inBlockText: blockText)
        let length = (blockText as NSString).length
        guard length <= Self.referenceGroupCacheBudget else { return groups }
        if referenceGroupCacheLength + length > Self.referenceGroupCacheBudget {
            referenceGroupCache.removeAll()
            referenceGroupCacheLength = 0
        }
        referenceGroupCache[blockText] = groups
        referenceGroupCacheLength += length
        return groups
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
            for group in cachedReferenceGroups(blockText: text.substring(with: block)) {
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
