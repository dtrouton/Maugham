import AppKit
import MaughamCore

/// Custom NSView drawn in the left text-container inset of MaughamTextView.
/// Shows a small uppercase abbreviation per line indicating the parsed
/// screenplay element (CHAR, DLG, PAR, TRANS, etc.). Action lines get no label.
final class ElementGutterView: NSView {

    weak var coordinator: EditorCoordinator?
    weak var associatedTextView: NSTextView?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    /// Per-view cache of attributed labels. The label glyphs don't depend on
    /// the line, only on (element, pointSize, color), so we build each one once
    /// and reuse the immutable `NSAttributedString` (which also caches its own
    /// rendered size). Created lazily; `pointSize` and `color` vary with the
    /// font and the resolved theme/appearance palette respectively, so both are
    /// part of the key — a theme or light/dark switch produces a different
    /// `color` and therefore a fresh entry, never a stale color (no explicit
    /// flush needed; old entries are simply never looked up again).
    private let labelCache = LabelCache()

    /// Static abbreviation lookup. Exposed for unit testing via `@testable`.
    static func abbreviation(for element: ScreenplayElement) -> String? {
        switch element {
        case .action:               return nil
        case .sceneHeading:         return "SCENE"
        case .character:            return "CHAR"
        case .dialogue:             return "DLG"
        case .parenthetical:        return "PAR"
        case .transition:           return "TRANS"
        case .centered:             return "CTR"
        case .lyric:                return "LYR"
        case .section(let level):   return "§\(level)"
        case .synopsis:             return "SYN"
        case .pageBreak:            return "PAGE"
        case .boneyard:             return "CUT"
        case .note:                 return "NOTE"
        case .titlePage:            return nil   // title page lines have no gutter label
        }
    }

    /// Indices of lines that carry a gutter label AND intersect `window`.
    ///
    /// `FountainScript.lines` are document-ordered and contiguous by
    /// construction (each line's `range` covers its text including the trailing
    /// newline, so consecutive ranges abut), which makes `range.location`
    /// monotonically non-decreasing. We binary-search the first line whose
    /// range could reach into `window`, then walk forward only while a line can
    /// still start before the window's end, filtering to labeled elements.
    /// O(log n + visible) instead of the previous O(all lines) full-document
    /// walk per redraw (tripwire 4; 2026-06-10 live profile: 8,302 labeled
    /// lines at 250 pp, scanned on every keystroke + scroll).
    ///
    /// An empty `window` (length 0) selects nothing — intersection length must
    /// be strictly positive to count as visible.
    static func labeledLineIndices(
        in script: FountainScript, intersecting window: NSRange
    ) -> [Int] {
        let lines = script.lines
        guard window.length > 0, !lines.isEmpty else { return [] }
        let windowEnd = NSMaxRange(window)

        // lowerBound: first index whose line could intersect the window. A line
        // intersects only if its end (NSMaxRange) is strictly greater than the
        // window's start, so we find the first line with NSMaxRange > location.
        var lo = 0
        var hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(lines[mid].range) <= window.location {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        var result: [Int] = []
        var i = lo
        while i < lines.count {
            let range = lines[i].range
            // Lines are ordered by start; once a line starts at or beyond the
            // window's end, no later line can intersect.
            if range.location >= windowEnd { break }
            if abbreviation(for: lines[i].element) != nil,
               NSIntersectionRange(range, window).length > 0 {
                result.append(i)
            }
            i += 1
        }
        return result
    }

    /// Cached attributed labels keyed by (element abbreviation, pointSize,
    /// color). The label string + attributes are independent of which line they
    /// sit on, so each distinct (element, size, color) is built once and the
    /// immutable `NSAttributedString` reused across every line that needs it in
    /// a draw and across draws. `color` is part of the key precisely so a theme
    /// or light/dark switch — which changes the resolved palette's
    /// `syntaxPunctuation` — yields a fresh entry rather than a stale-colored
    /// cached one. Entries from a prior color are simply never looked up again
    /// (the dictionary is unbounded but bounded in practice by the small set of
    /// element abbreviations × the one-or-two live (size, color) combinations).
    final class LabelCache {
        private struct Key: Hashable {
            let label: String
            let pointSize: CGFloat
            // NSColor isn't reliably Hashable across appearance contexts; its
            // RGBA in the device space is a stable, identity-bearing stamp.
            let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
        }
        private var store: [Key: NSAttributedString] = [:]

        /// Returns the cached label for `element` at `pointSize`/`color`, or
        /// `nil` if the element carries no gutter label. Building the same
        /// (element, size, color) twice returns the identical instance.
        func attributedLabel(
            for element: ScreenplayElement, pointSize: CGFloat, color: NSColor
        ) -> NSAttributedString? {
            guard let label = ElementGutterView.abbreviation(for: element) else {
                return nil
            }
            let rgba = color.usingColorSpace(.deviceRGB) ?? color
            let key = Key(
                label: label, pointSize: pointSize,
                r: rgba.redComponent, g: rgba.greenComponent,
                b: rgba.blueComponent, a: rgba.alphaComponent)
            if let cached = store[key] { return cached }
            let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
            let attributed = NSAttributedString(
                string: label,
                attributes: [.font: font, .foregroundColor: color])
            store[key] = attributed
            return attributed
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let tv = associatedTextView else { return }
        let nc = NotificationCenter.default
        nc.removeObserver(self)
        nc.addObserver(
            self,
            selector: #selector(handleTextDidChange(_:)),
            name: NSText.didChangeNotification,
            object: tv)
        if let scrollView = tv.enclosingScrollView {
            nc.addObserver(
                self,
                selector: #selector(handleBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView)
            scrollView.contentView.postsBoundsChangedNotifications = true
        }
        nc.addObserver(
            self,
            selector: #selector(handleAppearanceChange(_:)),
            name: NSWindow.didChangeBackingPropertiesNotification,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleTextDidChange(_ note: Notification) {
        needsDisplay = true
    }

    @objc private func handleBoundsDidChange(_ note: Notification) {
        needsDisplay = true
    }

    @objc private func handleAppearanceChange(_ note: Notification) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Update the layer's background color to match the current theme.
        // wantsLayer = true (set in init) ensures the layer auto-clears
        // between draws, so we don't need an explicit fill that could bleed.
        let palette = currentPalette()
        layer?.backgroundColor = palette.background.cgColor

        guard let textView = associatedTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let script = coordinator?.lastParsedScript else { return }

        // Effective label point size matches the prior `.scaled(by: 0.7)` of
        // the body font — keeps drawn glyphs pixel-identical.
        let baseSize = textView.font?.pointSize ?? 13
        let labelPointSize = baseSize * 0.7
        let labelColor = palette.syntaxPunctuation

        // Bound the work to the lines whose glyphs are currently on screen
        // (visible-range draw, tripwire 4). We map the text view's visibleRect
        // to a glyph range once, convert to a character range, then select only
        // the labeled lines that intersect it — instead of querying boundingRect
        // for every labeled line in the whole document on each redraw.
        //
        // visibleRect (not dirtyRect): scrolling delivers partial dirtyRects for
        // only the newly-exposed band, but the gutter redraws wholesale on bounds
        // change and the backing layer auto-clears each draw, so we must repaint
        // every currently-visible labeled line, not just the dirty sliver. The
        // visibleRect bounds the cost to on-screen lines while keeping the drawn
        // output identical to the old full-document scan for visible lines.
        let visibleRect = textView.visibleRect
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: container)
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        let yOffset = textView.textContainerInset.height

        for index in Self.labeledLineIndices(in: script, intersecting: visibleCharRange) {
            let line = script.lines[index]
            guard let attributed = labelCache.attributedLabel(
                for: line.element, pointSize: labelPointSize, color: labelColor)
            else { continue }

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: line.range, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange, in: container)

            // Convert from container-coordinates (text view's coordinate space)
            // to gutter-coordinates. Text view is centered via textContainerInset;
            // gutter sits in the left inset area at x=0..gutterWidth.
            let drawY = lineRect.origin.y + yOffset

            // Right-aligned within the gutter (so labels read into the column).
            let drawX = bounds.width - attributed.size().width - 6
            attributed.draw(at: NSPoint(x: drawX, y: drawY))
        }
    }

    private func currentPalette() -> ThemePalette {
        let appearance = NSApp?.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua])
        let theme = coordinator?.theme ?? .light
        let resolved = theme.resolved(systemAppearanceIsDark: appearance == .darkAqua)
        return resolved.palette
    }
}
