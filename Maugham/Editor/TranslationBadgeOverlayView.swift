import AppKit
import MaughamCore

/// Transparent overlay in the LEFT text-container inset that marks each
/// paragraph's translation freshness during translation review (Task 12):
/// an amber FILLED dot for a STALE translation (the source changed after it was
/// made) and a gray HOLLOW dot for a MISSING one (no translation — the source
/// text is showing through). FRESH paragraphs are unmarked. Installed on the
/// text view like `ElementGutterView` / the review overlays, shown only in
/// translation review, and bound to the visible glyph range (tripwire 4).
///
/// The dimming of missing paragraphs' body text is NOT drawn here — that is a
/// layout-manager temporary attribute the coordinator applies over the text
/// (`applyTranslationDimming`), cleared on exit. This view draws only the margin
/// dots, reading the coordinator's pre-resolved `resolvedTranslationBadges`
/// (computed once per push via `TranslationBadgeLayout`, never per draw).
///
/// Drawing is machine-unverifiable here (it needs a laid-out `NSTextView` in a
/// window with a real `NSLayoutManager`), so it is smoke-territory — mirroring
/// `AnnotationMarkRenderer`. The load-bearing arithmetic (¶ → UTF-16 range) is
/// the pure `TranslationBadgeLayout`, unit-tested in `TranslationBadgeMappingTests`.
final class TranslationBadgeOverlayView: NSView {

    weak var coordinator: EditorCoordinator?
    weak var associatedTextView: NSTextView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // never intercept clicks

    private let dotDiameter: CGFloat = 7

    /// Amber (stale) — a warm ochre legible against both light and dark columns.
    private static let staleColor = NSColor(
        calibratedRed: 0.85, green: 0.55, blue: 0.10, alpha: 1)

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
        guard let tv = associatedTextView else { return }
        nc.addObserver(
            self, selector: #selector(handleScroll(_:)),
            name: NSText.didChangeNotification, object: tv)
        if let scrollView = tv.enclosingScrollView {
            scrollView.contentView.postsBoundsChangedNotifications = true
            nc.addObserver(
                self, selector: #selector(handleScroll(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView)
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func handleScroll(_ note: Notification) { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let textView = associatedTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let coordinator,
              coordinator.isReadingTranslation else { return }

        let badges = coordinator.bufferBadges
        guard !badges.isEmpty else { return }

        let inset = textView.textContainerInset
        let visibleRect = textView.visibleRect
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: container)
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
        let storageLength = textView.textStorage?.length ?? 0

        for badge in badges {
            guard badge.status != .fresh else { continue }
            // Clamp defensively: a torn push can leave a range past the buffer
            // (the model and the swapped buffer briefly disagree).
            let loc = min(badge.range.location, storageLength)
            let len = min(badge.range.length, max(0, storageLength - loc))
            guard NSIntersectionRange(
                    NSRange(location: loc, length: max(len, 1)), visibleCharRange
            ).length > 0 else { continue }

            // Anchor the dot to the paragraph's FIRST line fragment.
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: loc, length: max(len, 1)),
                actualCharacterRange: nil)
            let firstLineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location, effectiveRange: nil)
            let centerY = firstLineRect.midY + inset.height
            // Right-aligned within the left inset, hugging the text column.
            let x = max(4, inset.width - dotDiameter - 6)
            let dotRect = NSRect(
                x: x, y: centerY - dotDiameter / 2,
                width: dotDiameter, height: dotDiameter)

            switch badge.status {
            case .stale:   drawFilledDot(in: dotRect, color: Self.staleColor)
            case .missing: drawHollowDot(in: dotRect, color: .tertiaryLabelColor)
            case .fresh:   break   // unreachable (guarded above)
            }
        }
    }

    // MARK: - VoiceOver (shell p4 Task 8 fix round (d))

    /// **What VoiceOver hears beside each paragraph that is not current**:
    /// the note ("Out of date: …" / "Not translated yet: …") and the
    /// paragraph's opening words, in order. Pure over the badges and the text.
    static func accessibilityLabels(_ badges: [TranslationBadgeLayout.BadgeRange],
                                    text: String) -> [String] {
        let ns = text as NSString
        return badges.compactMap { badge in
            guard let note = TranslationBadgeLayout.accessibilityNote(badge.status) else { return nil }
            let loc = min(badge.range.location, ns.length)
            let len = min(badge.range.length, ns.length - loc, 60)
            let opening = ns.substring(with: NSRange(location: loc, length: max(0, len)))
            return opening.isEmpty ? note : "\(note). \(opening)\(badge.range.length > 60 ? "\u{2026}" : "")"
        }
    }

    override func isAccessibilityElement() -> Bool { false }

    /// One static-text element per paragraph that is not current, framed on
    /// its first line, so VoiceOver reads "out of date" / "not translated
    /// yet" where it is, not only in the line over the text.
    override func accessibilityChildren() -> [Any]? {
        guard let textView = associatedTextView, let coordinator, coordinator.isReadingTranslation,
              let layoutManager = textView.layoutManager else { return [] }
        let badges = coordinator.bufferBadges.filter { $0.status != .fresh }
        let labels = Self.accessibilityLabels(badges, text: textView.string)
        let length = textView.textStorage?.length ?? 0
        return zip(badges, labels).compactMap { badge, label -> NSAccessibilityElement? in
            guard length > 0 else { return nil }
            let glyph = layoutManager.glyphIndexForCharacter(at: min(badge.range.location, length - 1))
            var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect.origin.y += textView.textContainerInset.height
            rect.origin.x += textView.textContainerInset.width
            let screen = textView.window?.convertToScreen(textView.convert(rect, to: nil)) ?? rect
            let element = NSAccessibilityElement.element(
                withRole: .staticText, frame: screen, label: label, parent: self) as? NSAccessibilityElement
            return element
        }
    }

    private func drawFilledDot(in rect: NSRect, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private func drawHollowDot(in rect: NSRect, color: NSColor) {
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        path.lineWidth = 1.25
        color.setStroke()
        path.stroke()
    }
}
