import AppKit
import MaughamCore

/// **Where one of the margin's marks sits in the text** (shell p5 Task 2):
/// resolved from `MarginMarks` against the buffer when the marks arrive, and
/// shifted by each storage edit (`EditorCoordinator.marginNoteEdit`), so a
/// draw only reads it (tripwire 4).
struct MarginPlace: Equatable {
    enum Mark: Equatable {
        case dot(annotationId: String, name: String, colour: NSColor = MarginOverlayView.dotColor)
        case tick
    }
    let mark: Mark
    let paragraphId: String
    /// The UTF-16 location the mark sits beside: the note's first word, or
    /// the paragraph's start.
    var anchor: Int
    /// A dot's words, tinted; nil for a tick or a paragraph-level note.
    var tint: NSRange?

    /// A position after an edit that replaced `editedRange.length - delta`
    /// characters at `editedRange.location` with `editedRange.length`. A
    /// position inside the replaced text collapses to the edit's start.
    static func shifted(_ position: Int, editedRange: NSRange, delta: Int) -> Int {
        let replacedEnd = editedRange.location + editedRange.length - delta
        if position >= replacedEnd { return position + delta }
        if position > editedRange.location { return editedRange.location }
        return position
    }

    func shifted(editedRange: NSRange, delta: Int) -> MarginPlace {
        var next = self
        next.anchor = Self.shifted(anchor, editedRange: editedRange, delta: delta)
        if let tint {
            let start = Self.shifted(tint.location, editedRange: editedRange, delta: delta)
            // Text typed exactly at the end is after the note's words, not in
            // them (fix round 1, M3): the end moves only for an edit before it.
            let end = NSMaxRange(tint) <= editedRange.location
                ? NSMaxRange(tint)
                : Self.shifted(NSMaxRange(tint), editedRange: editedRange, delta: delta)
            next.tint = end > start ? NSRange(location: start, length: end - start) : nil
        }
        return next
    }
}

/// **The margin's geometry** (shell p5 Task 2): pure, beside the text
/// column's trailing edge, inside the trailing inset — so the leading
/// margin stays the screenplay gutter's and the figure captions'. The tick
/// is a short bar just past the column; the dot sits outside it, so a
/// paragraph may carry both. Neither changes the text's layout: the inset
/// exists whatever the setting.
enum MarginGeometry {
    static let dotDiameter: CGFloat = 6
    /// The dot's centre, past the column's trailing edge.
    static let dotOffset: CGFloat = 10
    static let tickWidth: CGFloat = 2
    /// The tick's leading edge, past the column's trailing edge.
    static let tickOffset: CGFloat = 2
    /// A click lands within this much of a mark.
    static let hitSlop: CGFloat = 4
    /// **The ticks' own lane** past the column's edge (closing round B,
    /// M4): a tick and its click area end inside it, and the review rail's
    /// cards begin after it (`ReviewMarginRailView`), so in read-through a
    /// tick never sits on a card nor takes its click.
    static let tickLane: CGFloat = tickOffset + tickWidth + hitSlop + 2

    static func dotRect(columnTrailingX x: CGFloat, line: NSRect) -> NSRect {
        let d = dotDiameter
        let height = min(line.height, 14)
        return NSRect(x: x + dotOffset - d / 2, y: line.minY + (height - d) / 2, width: d, height: d)
    }

    static func tickRect(columnTrailingX x: CGFloat, line: NSRect) -> NSRect {
        let height = max(4, min(line.height, 14) - 4)
        return NSRect(x: x + tickOffset, y: line.minY + 2, width: tickWidth, height: height)
    }

    /// A mark's click area: its rect with a little slop, never reaching
    /// into the text column (fix round 1, M2) — a click at a line's end is
    /// the text's.
    static func hitRect(_ mark: NSRect, columnTrailingX x: CGFloat) -> NSRect {
        var hit = mark.insetBy(dx: -hitSlop, dy: -hitSlop)
        if hit.minX < x {
            hit.size.width -= x - hit.minX
            hit.origin.x = x
        }
        return hit
    }
}

/// **View ▸ Margin's overlay** (shell p5 Task 2): a dot beside a person's
/// note and a faint tint on its words; a grey tick beside a paragraph a
/// check or a round flagged. Installed on the text view as the translation
/// badges and the review rail are (`syncMarginOverlay`), covering it,
/// drawing the visible range only from the coordinator's `marginPlaces`.
///
/// **It draws no words** (ADR 0027 §1 as amended): no text-drawing call, no
/// tooltip, no accessibility value or help, and only the two fixed labels
/// (`MarginOverlayCensusTests`). **A click on a mark moves nothing in the
/// editor**: the overlay takes it, so the text view never sees it, and it
/// posts the one window event that shows the paragraph in To resolve.
/// Everywhere else the overlay lets clicks through. Hit testing reads the
/// rects the last draw cached — no layout query on a mouse move (M10).
final class MarginOverlayView: NSView {

    weak var coordinator: EditorCoordinator?
    weak var associatedTextView: NSTextView?

    override var isFlipped: Bool { true }

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
        let nc = NotificationCenter.default
        nc.removeObserver(self)
        guard let tv = associatedTextView, let scrollView = tv.enclosingScrollView else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        nc.addObserver(self, selector: #selector(handleScroll(_:)),
                       name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func handleScroll(_ note: Notification) { needsDisplay = true }

    // MARK: - What is where (visible range only)

    /// One mark as drawn: a tick, or every dot beside one line (M8).
    struct Drawn: Equatable {
        let places: [MarginPlace]
        /// The mark's rect, in this view's (the text view's) coordinates.
        let rect: NSRect
        /// Where a click takes it: never inside the text column (M2).
        let hitRect: NSRect
        /// The tints' rects, the dots' only.
        let tintRects: [NSRect]

        var paragraphId: String { places[0].paragraphId }
        var isTick: Bool { places[0].mark == .tick }
        /// Stable across draws while the marks stand: VoiceOver's element key.
        var id: String {
            isTick ? "tick:\(paragraphId)"
                : "dots:" + places.map { place -> String in
                    if case .dot(let id, _, _) = place.mark { return id }
                    return ""
                }.joined(separator: ",")
        }
        /// The note a one-note dot stands for (its click shows that note);
        /// nil for a tick or a dot of several notes.
        var soleNoteId: String? {
            guard places.count == 1, case .dot(let id, _, _) = places[0].mark else { return nil }
            return id
        }
        /// The dots' writers, for their one fixed label.
        var names: [String] {
            places.compactMap { place in
                if case .dot(_, let name, _) = place.mark { return name }
                return nil
            }
        }
        /// The dot's fill: its person's colour, or the quiet grey where one
        /// mark stands for several people.
        var colour: NSColor {
            let colours = places.compactMap { place -> NSColor? in
                if case .dot(_, _, let colour) = place.mark { return colour }
                return nil
            }
            guard let first = colours.first, colours.allSatisfy({ $0 == first }) else {
                return MarginOverlayView.dotColor
            }
            return first
        }
    }

    /// What the last draw (or the first accessibility query) found, and the
    /// coordinator's `marginGeneration` it was found for.
    private(set) var lastDrawn: [Drawn] = []
    private var drawnGeneration: Int?
    /// How often the layout was read — a hit test never reads it (M10).
    private(set) var layoutReadCount = 0
    /// VoiceOver's elements, kept per mark while the mark stands (M4).
    private var elements: [String: MarginMarkElement] = [:]

    /// The marks on screen and their rects. Bound to the visible glyph range
    /// by a binary search over the sorted places (`ElementGutterView`'s
    /// precedent); nothing is resolved from the document.
    func visibleMarks() -> [Drawn] {
        layoutReadCount += 1
        guard let textView = associatedTextView, let coordinator,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return [] }
        let places = coordinator.marginPlaces
        let length = textView.textStorage?.length ?? 0
        guard !places.isEmpty, length > 0 else { return [] }
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visible = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let origin = textView.textContainerOrigin
        let columnTrailingX = origin.x + container.size.width

        // First place at or after the visible start; a few before it may
        // still tint into view.
        var low = 0, high = places.count
        while low < high {
            let mid = (low + high) / 2
            if places[mid].anchor < visible.location { low = mid + 1 } else { high = mid }
        }
        var start = low
        while start > 0, low - start < 8 { start -= 1 }

        var drawn: [Drawn] = []
        for place in places[start...] {
            if place.anchor > NSMaxRange(visible) { break }
            let anchor = min(place.anchor, length - 1)
            let glyph = layoutManager.glyphIndexForCharacter(at: anchor)
            var line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            line.origin.y += origin.y
            let rect: NSRect
            switch place.mark {
            case .dot: rect = MarginGeometry.dotRect(columnTrailingX: columnTrailingX, line: line)
            case .tick: rect = MarginGeometry.tickRect(columnTrailingX: columnTrailingX, line: line)
            }
            var tints: [NSRect] = []
            if let tint = place.tint, NSIntersectionRange(tint, visible).length > 0 {
                let clamped = NSIntersectionRange(tint, NSRange(location: 0, length: length))
                let glyphs = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
                layoutManager.enumerateEnclosingRects(
                    forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: container) { r, _ in
                        tints.append(r.offsetBy(dx: origin.x, dy: origin.y))
                    }
            }
            if place.anchor < visible.location && tints.isEmpty { continue }
            // Dots beside one line are one mark (M8): same rect, one element.
            if place.mark != .tick,
               let index = drawn.lastIndex(where: { !$0.isTick && $0.rect == rect }) {
                let held = drawn[index]
                drawn[index] = Drawn(places: held.places + [place], rect: rect, hitRect: held.hitRect,
                                     tintRects: held.tintRects + tints)
                continue
            }
            drawn.append(Drawn(places: [place], rect: rect,
                               hitRect: MarginGeometry.hitRect(rect, columnTrailingX: columnTrailingX),
                               tintRects: tints))
        }
        return drawn
    }

    /// The cached marks, read again only when the coordinator's marks moved
    /// since they were found.
    private func currentMarks() -> [Drawn] {
        if drawnGeneration != coordinator?.marginGeneration { refreshCache() }
        return lastDrawn
    }

    private func refreshCache() {
        lastDrawn = visibleMarks()
        drawnGeneration = coordinator?.marginGeneration
    }

    // MARK: - Drawing: positions, never words

    /// Quiet in light and dark: the system's secondary and tertiary label
    /// greys, and the accent at a whisper for the tint. A dot takes its
    /// person's pencil (`Drawn.colour`; the grey where a mark is several
    /// people's); a tick is never anyone's.
    static let dotColor = NSColor.secondaryLabelColor
    static let tickColor = NSColor.tertiaryLabelColor
    static let tintColor = NSColor.controlAccentColor.withAlphaComponent(0.10)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        refreshCache()
        for mark in lastDrawn {
            Self.tintColor.setFill()
            for r in mark.tintRects { NSBezierPath(rect: r).fill() }
            if mark.isTick {
                Self.tickColor.setFill()
                NSBezierPath(roundedRect: mark.rect, xRadius: 1, yRadius: 1).fill()
            } else {
                mark.colour.setFill()
                NSBezierPath(ovalIn: mark.rect).fill()
            }
        }
    }

    // MARK: - The click

    /// A mark under the point takes the click; anywhere else the text view
    /// does. Reads the last draw's rects only (M10); marks that moved since
    /// take no click until they are drawn again.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        return mark(at: local) == nil ? nil : self
    }

    func mark(at point: NSPoint) -> Drawn? {
        guard drawnGeneration == coordinator?.marginGeneration else { return nil }
        return lastDrawn.first { $0.hitRect.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let drawn = mark(at: point) else { return }
        coordinator?.marginMarkPressed(paragraphId: drawn.paragraphId, annotationId: drawn.soleNoteId)
    }

    // MARK: - VoiceOver

    override func isAccessibilityElement() -> Bool { false }

    /// One button per visible mark: what it marks, and the click. The same
    /// element answers every query while its mark stands (M4).
    override func accessibilityChildren() -> [Any]? {
        guard let textView = associatedTextView else { return [] }
        let marks = currentMarks()
        var kept: [String: MarginMarkElement] = [:]
        let children: [MarginMarkElement] = marks.map { drawn in
            let element = elements[drawn.id]
                ?? MarginMarkElement(paragraphId: drawn.paragraphId, soleNoteId: drawn.soleNoteId,
                                     isTick: drawn.isTick,
                                     names: drawn.names, coordinator: coordinator)
            element.setAccessibilityParent(self)
            let screen = textView.window?.convertToScreen(textView.convert(drawn.rect, to: nil)) ?? drawn.rect
            element.setAccessibilityFrame(screen)
            kept[drawn.id] = element
            return element
        }
        elements = kept
        return children
    }
}

/// A mark as VoiceOver reaches it: a button whose label is one of the two
/// fixed labels (a person's name at most) and whose press is the click.
final class MarginMarkElement: NSAccessibilityElement {
    let paragraphId: String
    /// The note a one-note dot stands for (`Drawn.soleNoteId`).
    let soleNoteId: String?
    weak var coordinator: EditorCoordinator?

    init(paragraphId: String, soleNoteId: String? = nil, isTick: Bool, names: [String],
         coordinator: EditorCoordinator?) {
        self.paragraphId = paragraphId
        self.soleNoteId = soleNoteId
        self.coordinator = coordinator
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(isTick ? MarginMarks.tickAccessibilityLabel
                                     : MarginMarks.accessibilityLabel(ofDots: names))
    }

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            coordinator?.marginMarkPressed(paragraphId: paragraphId, annotationId: soleNoteId)
            return coordinator != nil
        }
    }
}

// MARK: - The coordinator's side

extension EditorCoordinator {

    /// The margin's marks arrived (`applyControl`). Self-guarded (D2): a
    /// rebuild that changed nothing the marks depend on re-places nothing.
    func setMargin(_ marks: MarginMarks) {
        guard marks != margin else { return }
        margin = marks
        recomputeMarginPlaces()
    }

    /// Resolve the marks against the buffer: every paragraph's range from
    /// ONE pass over the document (`marginParagraphRangesProvider`, fix
    /// round 1, I3), a dot's words through its grapheme span. Once per
    /// arrival, attach or whole-buffer replace — never per draw. Nothing over
    /// a translation (its anchors are the source's).
    func recomputeMarginPlaces() {
        marginPlacesRecomputeCount += 1
        var places: [MarginPlace] = []
        if !bufferHoldsTranslation, !margin.isEmpty, let ranges = marginParagraphRangesProvider?() {
            for paragraphId in margin.ticks {
                guard let paragraph = ranges[paragraphId] else { continue }
                places.append(MarginPlace(mark: .tick, paragraphId: paragraphId,
                                          anchor: paragraph.location, tint: nil))
            }
            for dot in margin.dots {
                guard let paragraph = ranges[dot.paragraphId] else { continue }
                var anchor = paragraph.location
                var tint: NSRange?
                if let span = dot.span, let text = reviewParagraphTextProvider?(dot.paragraphId),
                   let utf16 = ReviewSpanCapture.graphemeRangeToUTF16(span, in: text), utf16.length > 0 {
                    tint = NSRange(location: paragraph.location + utf16.location, length: utf16.length)
                    anchor = tint!.location
                }
                places.append(MarginPlace(mark: .dot(annotationId: dot.annotationId, name: dot.name,
                                                     colour: dot.colour),
                                          paragraphId: dot.paragraphId, anchor: anchor, tint: tint))
            }
        }
        marginPlaces = places.sorted { a, b in
            if a.anchor != b.anchor { return a.anchor < b.anchor }
            return a.mark == .tick && b.mark != .tick
        }
        marginGeneration &+= 1
        syncMarginOverlay()
    }

    /// A storage edit moved the text: every place shifts with it (O(marks),
    /// no document read). An edit that swallowed a mark's place — a delete
    /// or a replace across paragraphs — may have taken its paragraph away:
    /// the places are read again from the document on the next turn, once
    /// the document holds the edit, and a mark whose paragraph is gone is
    /// dropped (fix round 2).
    func marginNoteEdit(editedRange: NSRange, changeInLength delta: Int) {
        guard !marginPlaces.isEmpty else { return }
        let replacedEnd = editedRange.location + editedRange.length - delta
        let swallowed = marginPlaces.contains { $0.anchor > editedRange.location && $0.anchor < replacedEnd }
        marginPlaces = marginPlaces.map { $0.shifted(editedRange: editedRange, delta: delta) }
        marginGeneration &+= 1
        marginOverlay?.needsDisplay = true
        if swallowed, !marginReplaceScheduled {
            marginReplaceScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDetached else { return }
                self.marginReplaceScheduled = false
                self.recomputeMarginPlaces()
            }
        }
    }

    /// Install the overlay when there is something to mark, and show or
    /// hide it. Idempotent; never left on a text view SwiftUI replaced.
    func syncMarginOverlay() {
        guard let textView else { return }
        if let stale = marginOverlay, stale.superview !== textView {
            stale.removeFromSuperview()
            marginOverlay = nil
        }
        if marginOverlay == nil, !marginPlaces.isEmpty {
            let overlay = MarginOverlayView(frame: textView.bounds)
            overlay.coordinator = self
            overlay.associatedTextView = textView
            overlay.autoresizingMask = [.width, .height]
            textView.addSubview(overlay)
            marginOverlay = overlay
        }
        marginOverlay?.isHidden = marginPlaces.isEmpty
        layoutMarginOverlay(in: textView)
        marginOverlay?.needsDisplay = true
    }

    /// The overlay covers the text view; re-framed on resize from
    /// `MaughamTextView.updateColumnInset`.
    func layoutMarginOverlay(in textView: NSTextView) {
        marginOverlay?.frame = textView.bounds
        marginGeneration &+= 1
    }

    /// **A mark was clicked or pressed**: To resolve shows that paragraph's
    /// group. The editor's caret and scroll are not touched.
    /// `annotationId`: the note, when the mark is one note's dot.
    func marginMarkPressed(paragraphId: String, annotationId: String? = nil) {
        guard let documentId else { return }
        MaughamEvent.postShowParagraphInResolve(docId: documentId, paragraphId: paragraphId,
                                                annotationId: annotationId)
    }
}
