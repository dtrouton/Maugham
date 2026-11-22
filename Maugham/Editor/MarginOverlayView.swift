import AppKit
import MaughamCore

/// **Where one of the margin's marks sits in the text** (shell p5 Task 2):
/// resolved from `MarginMarks` against the buffer when the marks arrive, and
/// shifted by each storage edit (`EditorCoordinator.marginNoteEdit`), so a
/// draw only reads it (tripwire 4).
struct MarginPlace: Equatable {
    enum Mark: Equatable {
        case dot(annotationId: String, name: String)
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
            let end = Self.shifted(NSMaxRange(tint), editedRange: editedRange, delta: delta)
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

    static func dotRect(columnTrailingX x: CGFloat, line: NSRect) -> NSRect {
        let d = dotDiameter
        let height = min(line.height, 14)
        return NSRect(x: x + dotOffset - d / 2, y: line.minY + (height - d) / 2, width: d, height: d)
    }

    static func tickRect(columnTrailingX x: CGFloat, line: NSRect) -> NSRect {
        let height = max(4, min(line.height, 14) - 4)
        return NSRect(x: x + tickOffset, y: line.minY + 2, width: tickWidth, height: height)
    }

    static func hitRect(_ mark: NSRect) -> NSRect {
        mark.insetBy(dx: -hitSlop, dy: -hitSlop)
    }
}

/// **View ▸ Margin's overlay** (shell p5 Task 2): a dot beside a person's
/// note and a faint tint on its words; a grey tick beside a paragraph a
/// check or a round flagged. Installed on the text view as the translation
/// badges and the review rail are (`syncMarginOverlay`), covering it,
/// drawing the visible range only from the coordinator's `marginPlaces`.
///
/// **It draws no words** (ADR 0027 §1 as amended): no text-drawing call in
/// this file (`MarginOverlayCensusTests`). **A click on a mark moves
/// nothing in the editor**: the overlay takes it, so the text view never
/// sees it, and it posts the one window event that shows the paragraph in
/// To resolve. Everywhere else the overlay lets clicks through.
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

    struct Drawn: Equatable {
        let place: MarginPlace
        /// The mark's rect, in this view's (the text view's) coordinates.
        let rect: NSRect
        /// The tint's rects, a dot's only.
        let tintRects: [NSRect]
    }

    /// The marks on screen and their rects. Bound to the visible glyph range
    /// by a binary search over the sorted places (`ElementGutterView`'s
    /// precedent); per draw nothing is resolved from the document.
    func visibleMarks() -> [Drawn] {
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
            drawn.append(Drawn(place: place, rect: rect, tintRects: tints))
        }
        return drawn
    }

    // MARK: - Drawing: positions, never words

    /// Quiet in light and dark: the system's secondary and tertiary label
    /// greys, and the accent at a whisper for the tint. One colour per
    /// mark, whoever wrote the note and whatever an item says.
    static let dotColor = NSColor.secondaryLabelColor
    static let tickColor = NSColor.tertiaryLabelColor
    static let tintColor = NSColor.controlAccentColor.withAlphaComponent(0.10)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for mark in visibleMarks() {
            Self.tintColor.setFill()
            for r in mark.tintRects { NSBezierPath(rect: r).fill() }
            switch mark.place.mark {
            case .dot:
                Self.dotColor.setFill()
                NSBezierPath(ovalIn: mark.rect).fill()
            case .tick:
                Self.tickColor.setFill()
                NSBezierPath(roundedRect: mark.rect, xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    // MARK: - The click

    /// A mark under the point takes the click; anywhere else the text view
    /// does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        return mark(at: local) == nil ? nil : self
    }

    func mark(at point: NSPoint) -> MarginPlace? {
        visibleMarks().first { MarginGeometry.hitRect($0.rect).contains(point) }?.place
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let place = mark(at: point) else { return }
        coordinator?.marginMarkPressed(place)
    }

    // MARK: - VoiceOver

    override func isAccessibilityElement() -> Bool { false }

    /// One button per visible mark: what it marks, and the click.
    override func accessibilityChildren() -> [Any]? {
        guard let textView = associatedTextView else { return [] }
        return visibleMarks().map { drawn in
            let element = MarginMarkElement(place: drawn.place, coordinator: coordinator)
            element.setAccessibilityParent(self)
            let screen = textView.window?.convertToScreen(textView.convert(drawn.rect, to: nil)) ?? drawn.rect
            element.setAccessibilityFrame(screen)
            return element
        }
    }
}

/// A mark as VoiceOver reaches it: a button whose label says what it marks
/// and whose press is the click.
final class MarginMarkElement: NSAccessibilityElement {
    let place: MarginPlace
    weak var coordinator: EditorCoordinator?

    init(place: MarginPlace, coordinator: EditorCoordinator?) {
        self.place = place
        self.coordinator = coordinator
        super.init()
        setAccessibilityRole(.button)
        switch place.mark {
        case .dot(_, let name): setAccessibilityLabel(MarginMarks.accessibilityLabel(ofDot: name))
        case .tick: setAccessibilityLabel(MarginMarks.tickAccessibilityLabel)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            coordinator?.marginMarkPressed(place)
            return coordinator != nil
        }
    }
}

// MARK: - The coordinator's side

extension EditorCoordinator {

    /// The margin's marks arrived (`applyControl`). Self-guarded (D2).
    func setMargin(_ marks: MarginMarks) {
        guard marks != margin else { return }
        margin = marks
        recomputeMarginPlaces()
    }

    /// Resolve the marks against the buffer: each paragraph's range from the
    /// document (`reviewParagraphRangeProvider`), a dot's words through its
    /// grapheme span. Once per arrival, attach or whole-buffer replace —
    /// never per draw. Nothing over a translation (its anchors are the
    /// source's).
    func recomputeMarginPlaces() {
        var places: [MarginPlace] = []
        if !bufferHoldsTranslation, let range = reviewParagraphRangeProvider {
            for paragraphId in margin.ticks {
                guard let paragraph = range(paragraphId) else { continue }
                places.append(MarginPlace(mark: .tick, paragraphId: paragraphId,
                                          anchor: paragraph.location, tint: nil))
            }
            for dot in margin.dots {
                guard let paragraph = range(dot.paragraphId) else { continue }
                var anchor = paragraph.location
                var tint: NSRange?
                if let span = dot.span, let text = reviewParagraphTextProvider?(dot.paragraphId),
                   let utf16 = ReviewSpanCapture.graphemeRangeToUTF16(span, in: text), utf16.length > 0 {
                    tint = NSRange(location: paragraph.location + utf16.location, length: utf16.length)
                    anchor = tint!.location
                }
                places.append(MarginPlace(mark: .dot(annotationId: dot.annotationId, name: dot.name),
                                          paragraphId: dot.paragraphId, anchor: anchor, tint: tint))
            }
        }
        marginPlaces = places.sorted { a, b in
            if a.anchor != b.anchor { return a.anchor < b.anchor }
            return a.mark == .tick && b.mark != .tick
        }
        syncMarginOverlay()
    }

    /// A storage edit moved the text: every place shifts with it (O(marks),
    /// no document read).
    func marginNoteEdit(editedRange: NSRange, changeInLength delta: Int) {
        guard !marginPlaces.isEmpty else { return }
        marginPlaces = marginPlaces.map { $0.shifted(editedRange: editedRange, delta: delta) }
        marginOverlay?.needsDisplay = true
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
    }

    /// **A mark was clicked or pressed**: To resolve shows that paragraph's
    /// group. The editor's caret and scroll are not touched.
    func marginMarkPressed(_ place: MarginPlace) {
        guard let documentId else { return }
        MaughamEvent.postShowParagraphInResolve(docId: documentId, paragraphId: place.paragraphId)
    }
}
