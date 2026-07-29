import AppKit

/// How tall a card is — the ONE answer, reachable without a view.
///
/// `CanvasCardMetrics` owns the card's geometry and `ScrapLayout` owns its text
/// layout. A scrap card's height is the two of them paired — lay the text out at
/// the card's text width, then add the inset twice — and until now that pairing
/// existed only inside `CanvasView`. So nothing outside a SwiftUI view could
/// answer "how tall will this card be", which is exactly what a caller placing
/// cards without overlapping them has to know *before* any of them is drawn.
///
/// **A second spelling of this calculation is spec §7A.2's "text jumps on focus"
/// arriving by the back door**, past every structural defence in `ScrapLayout`:
/// drawn glyphs and edited glyphs on different rects, with no test of geometry
/// equality able to see it (`Maugham/Canvas/AREA.md`, "Card metrics live in
/// `CanvasCardMetrics`, and nowhere else"). Hence `height(of:)`, which is the
/// only place `cardHeight(forTextHeight:)` meets `measuredHeight` in this
/// directory, and `height(text:cardWidth:)`, which builds a throwaway layout and
/// then asks it.
///
/// **This does not replace `CanvasView.layouts`, and must not.** The mounted
/// `NSTextView` and the draw pass share one TextKit stack per scrap (tripwire 26,
/// [ADR 0026](../../docs/adr/0026-planning-canvas-rendering.md) §2) — that
/// sharing is the mitigation for §7A.2's biggest risk. `CanvasView` keeps
/// building and caching its `ScrapLayout` objects and asks `height(of:)` for the
/// number; `height(text:cardWidth:)` is for callers that have no card on screen
/// yet, and its layout is discarded on the way out.
///
/// **The scoped gap, stated so 1C-d meets a decision rather than a bug.**
/// `CanvasView.rebuildLayouts` measures `.scrap` nodes only, so an ITEM node
/// authored by anything that does not set a height gets none — and a node with no
/// `cachedHeight` has no `frame`, which means `CanvasScene.nodes(intersecting:)`
/// and `topmostNode(at:)` both drop it: **not drawn, not clickable.** That is
/// sufficient for 1C-c3, whose planner is the only producer of item nodes and
/// sets `CanvasCardMetrics.itemPlaceholderHeight` at creation; a hand-edited
/// sidecar can still hand us an item node with no height and it will be silently
/// absent. Widening `rebuildLayouts` to measure item nodes belongs to **1C-d**,
/// where an item's thumbnail makes its height depend on its image rather than on
/// one line of label, so the measurement it needs is not this one.
enum CanvasScrapMeasure {

    /// The canvas scrap font. Lifted off `CanvasView` so a caller with no view
    /// can measure with the same face the card is drawn in — a measurement taken
    /// at the system font would be a different number for the same words.
    static let scrapFont: NSFont = NSFont(name: "Iowan Old Style", size: 13)
        ?? .systemFont(ofSize: 13)

    /// The card height for text that has no layout yet.
    ///
    /// Builds a `ScrapLayout`, reads it, throws it away. That is deliberate: the
    /// layout that ends up on screen is `CanvasView`'s, keyed by node id and
    /// shared with the mounted editor, and handing a caller one from here would
    /// give the canvas a second stack for the same scrap.
    static func height(text: String, cardWidth: CGFloat) -> CGFloat {
        height(of: ScrapLayout(text: text,
                               width: CanvasCardMetrics.textWidth(forCardWidth: cardWidth),
                               font: scrapFont,
                               textColor: CanvasRenderer.cardInk))
    }

    /// The card height for a layout the caller already holds — `CanvasView`'s
    /// path, on every rebuild, resize and keystroke.
    ///
    /// **This is the one place the two halves of the calculation meet.** Anything
    /// else writing `cardHeight(forTextHeight: layout.measuredHeight)` is the
    /// second spelling the class doc is about.
    static func height(of layout: ScrapLayout) -> CGFloat {
        CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight)
    }
}

extension CanvasCardMetrics {

    /// The card height of an item node's dashed placeholder.
    ///
    /// **Derived from the label the renderer draws, not chosen by eye.**
    /// `CanvasRenderer.drawCard`'s `.item` arm draws one line of
    /// `CanvasRenderer.placeholderLabel(forReference:)` at `itemLabelFontSize`,
    /// anchored `.topLeading` at `textOrigin(inCard:)` — so the card is that line
    /// plus `inset` at the top and `inset` at the bottom, which is the same
    /// arithmetic `cardHeight(forTextHeight:)` does for a scrap. The line is
    /// measured rather than assumed, because the system font's line height is a
    /// fact about the font and not about the point size.
    ///
    /// It is a fixed height because the label is a single unwrapped line at a
    /// fixed size. **1C-d changes that** — a thumbnail makes an item's height
    /// depend on its image — and this constant is the thing it replaces.
    ///
    /// It lives in `CanvasScrapMeasure.swift` rather than beside the rest of
    /// `CanvasCardMetrics`, because measuring a line needs `NSFont` and the model
    /// types in `Maugham/Canvas/` are deliberately Foundation-only.
    public static let itemPlaceholderHeight: CGFloat = cardHeight(
        forTextHeight: ceil(
            NSAttributedString(
                string: "Hg",
                attributes: [.font: NSFont.systemFont(ofSize: itemLabelFontSize)]
            ).size().height))
}
