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

        let baseSize = textView.font?.pointSize ?? 13
        let font = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            .scaled(by: 0.7)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: palette.syntaxPunctuation,
        ]

        // For each parsed line, find its bounding glyph rect in the text view
        // and draw the abbreviation aligned to that line's baseline within
        // the gutter's frame.
        for line in script.lines {
            guard let label = Self.abbreviation(for: line.element) else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: line.range, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange, in: container)

            // Convert from container-coordinates (text view's coordinate space)
            // to gutter-coordinates. Text view is centered via textContainerInset;
            // gutter sits in the left inset area at x=0..gutterWidth.
            let yOffset = textView.textContainerInset.height
            let drawY = lineRect.origin.y + yOffset

            let labelSize = (label as NSString).size(withAttributes: attrs)
            // Right-aligned within the gutter (so labels read into the column).
            let drawX = bounds.width - labelSize.width - 6
            let point = NSPoint(x: drawX, y: drawY)
            (label as NSString).draw(at: point, withAttributes: attrs)
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

private extension NSFont {
    func scaled(by factor: CGFloat) -> NSFont {
        NSFont(descriptor: fontDescriptor, size: pointSize * factor) ?? self
    }
}
