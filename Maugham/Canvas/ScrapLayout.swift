import AppKit

/// One scrap's text, laid out ONCE through a TextKit 2 stack that is used for
/// BOTH the `Canvas` draw and the mounted `NSTextView`.
///
/// Spec §7A.2 names the drawn/edited seam the biggest risk in the design: if the
/// two layouts differ at all, text jumps every time the writer clicks in and
/// again when they click out. The mitigation is structural — there is only one
/// layout, and both consumers read it.
///
/// Three requirements, all verified by the 2026-07-25 rendering spike. Changing
/// any of them silently breaks the surface:
///
/// 1. `contentStorage.textStorage = NSTextStorage(...)`, NEVER
///    `contentStorage.attributedString = ...`. With `attributedString` the stack
///    lays out and draws perfectly, `textView.textContentStorage` is identity-equal
///    to ours, and yet `textView.textStorage` is nil, `textView.string` is empty,
///    and BOTH real keystrokes and `insertText` are silent no-ops. A scrap that
///    renders beautifully and refuses to accept a single character.
/// 2. `lineFragmentPadding = 0` (NSTextContainer defaults to 5),
///    `widthTracksTextView = false`, `textContainerInset = .zero`. Any one left
///    at its default shifts drawn against edited.
/// 3. Callers must draw at the window's true `backingScaleFactor` × camera zoom,
///    and must NEVER derive that scale by hand — deriving it from pixel width
///    bakes in AppKit's frame rounding and shifts glyphs by a subpixel, which is
///    the "text jumps" failure wearing a measurement-artifact disguise.
///    `CanvasRenderer` satisfies this by doing nothing: `GraphicsContext`'s
///    `withCGContext` already hands over a context at backing scale under the
///    camera CTM. Task 7 pins that no scale is derived anywhere in `Maugham/Canvas/`.
final class ScrapLayout {

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let container: NSTextContainer

    init(text: String, width: CGFloat, font: NSFont) {
        // REQUIREMENT 1 — see the class doc. Do not "simplify" this to
        // `contentStorage.attributedString = ...`.
        contentStorage.textStorage = NSTextStorage(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]))

        container = NSTextContainer(size: CGSize(width: width,
                                                 height: CGFloat.greatestFiniteMagnitude))
        // REQUIREMENT 2 — see the class doc.
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false

        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = container
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    var text: String { contentStorage.textStorage?.string ?? "" }

    var measuredHeight: CGFloat {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        // An empty scrap still needs a line's worth of height, or a freshly
        // created scrap has a zero-height frame and is not hit-testable — the
        // writer double-clicks, gets a caret, and can never click back into it.
        return max(ceil(layoutManager.usageBoundsForTextContainer.height),
                   Self.emptyLineHeight)
    }

    /// One line at the canvas font. Deliberately generous rather than measured:
    /// the exact value only matters until the first character is typed.
    private static let emptyLineHeight: CGFloat = 18

    func setWidth(_ width: CGFloat) {
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    /// Draw into a context whose CTM the caller has already set to the camera
    /// (translate + scale) and which is in top-left (flipped) text coordinates.
    /// The caller applies NO scale of its own — see requirement 3.
    func draw(into cgContext: CGContext, at origin: CGPoint) {
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let p = fragment.layoutFragmentFrame.origin
            fragment.draw(at: CGPoint(x: origin.x + p.x, y: origin.y + p.y), in: cgContext)
            return true
        }
    }

    /// Mount a real editor on THIS stack. The returned view shares the container,
    /// so what it edits is what we draw.
    func makeEditor(frame: CGRect) -> NSTextView {
        let tv = NSTextView(frame: frame, textContainer: container)
        tv.textContainerInset = .zero          // REQUIREMENT 2
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        // DELIBERATELY false. The canvas undo manager reaches this view through
        // the responder chain (`ScrapEditorContainer.undoManager`), so ⌘Z while
        // editing runs the CANVAS stack. If the view also registered its own
        // typing steps on that same manager, every keystroke would land twice:
        // the writer's ⌘Z would run the canvas snapshot (reverting the edit),
        // and the text view's queued step would still be sitting there pointed
        // at an `NSTextStorage` that `rebuildLayouts()` has since replaced — so
        // the second ⌘Z would appear to do nothing. Snapshots own scrap text;
        // Task 15 states the decision and its cost in full.
        tv.allowsUndo = false
        return tv
    }

    /// Place the caret from the click point (spec §7A.2, the rule borrowed from
    /// Miro) so clicking into a scrap lands where the writer aimed. `localPoint`
    /// is relative to the TEXT origin, not the card origin — callers convert
    /// through `CanvasCardMetrics.textOrigin(inCard:)`.
    func characterIndex(at localPoint: CGPoint) -> Int {
        var index = 0
        var best = CGFloat.greatestFiniteMagnitude
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            let base = contentStorage.offset(from: contentStorage.documentRange.location,
                                             to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let top = fragment.layoutFragmentFrame.origin.y + line.typographicBounds.minY
                let distance = abs(localPoint.y - (top + line.typographicBounds.height / 2))
                if distance < best {
                    best = distance
                    let inLine = line.characterIndex(
                        for: CGPoint(x: localPoint.x, y: line.typographicBounds.height / 2))
                    index = base + inLine
                }
            }
            return true
        }
        return index
    }

    // MARK: - Test seams

    /// The fragment and line geometry the focus/blur pin compares. Formatted to
    /// six decimal places so a subpixel drift cannot hide behind `==` on Doubles.
    var lineGeometrySignature: [String] {
        var out: [String] = []
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            let f = fragment.layoutFragmentFrame
            for line in fragment.textLineFragments {
                out.append(String(format: "%.6f/%.6f/%.6f/%.6f/%.6f/%.6f",
                                  f.origin.x, f.origin.y,
                                  line.typographicBounds.origin.y,
                                  line.typographicBounds.width,
                                  line.glyphOrigin.x, line.glyphOrigin.y))
            }
            return true
        }
        return out
    }

    var debugLineFragmentPadding: CGFloat { container.lineFragmentPadding }
    var debugWidthTracksTextView: Bool { container.widthTracksTextView }
}
