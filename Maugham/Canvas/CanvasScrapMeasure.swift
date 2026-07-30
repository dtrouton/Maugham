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
/// **An ITEM node is measured too, as of 1C-d, and the two measurements do not
/// meet.** A scrap's height comes from its text through `ScrapLayout`; an item
/// node has no text of its own, and its height is its picture's aspect ratio plus
/// one line of label (`CanvasCardMetrics.itemCardHeight(forCardWidth:pictureAspect:)`
/// below). What they share is the RULE — width is authoritative and height is
/// derived (spec §7A.3) — and the inset, which is `CanvasCardMetrics`' and is
/// spelled once.
///
/// **`itemLabelOnlyHeight` is the FLOOR and not a fallback.** A node whose facts
/// or whose picture have not arrived yet still has to have *a* height: a node with
/// no `cachedHeight` has no `frame`, which means `CanvasScene.nodes(intersecting:)`
/// and `topmostNode(at:)` both drop it — **not drawn, not clickable**, and
/// persisted that way. That is the 1C-c3 whole-branch Critical: `CanvasScene.setWidth`
/// clears `cachedHeight` by design, nothing on the item path refilled it, and one
/// corner drag took the photographed page off the canvas for good. The heal in
/// `CanvasView.rebuildLayouts` is what closes the route a producer cannot — a
/// hand-edited sidecar, and a picture that is still decoding.
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

/// An item card's geometry — the picture, the glyph and the title, and the
/// height that follows from them.
///
/// **These live in `CanvasCardMetrics` for the same reason the inset does**: the
/// draw pass and the measurement pass have to agree to the point, and a second
/// spelling of either is spec §7A.2's failure arriving on the card that carries a
/// photograph. They are geometry rather than *look*, which is why they are here
/// and not in `CanvasMaterial` — that file is the numbers the writer tunes by eye
/// against the running app, and `inset`, `minimumTextWidth` and `itemLabelFontSize`
/// were already settled on these terms.
///
/// This extension lives in `CanvasScrapMeasure.swift` rather than beside the rest
/// of `CanvasCardMetrics`, because measuring a line of text needs `NSFont` and the
/// model types in `Maugham/Canvas/` are deliberately Foundation-only.
extension CanvasCardMetrics {

    /// One line of an item card's label, measured rather than assumed — the
    /// system font's line height is a fact about the font and not about the point
    /// size.
    public static let itemLabelLineHeight: CGFloat = ceil(
        NSAttributedString(
            string: "Hg",
            attributes: [.font: NSFont.systemFont(ofSize: itemLabelFontSize)]
        ).size().height)

    /// Between the kind glyph and the title, on the label line.
    public static let itemGlyphGap: CGFloat = 4

    /// Between the picture and the label line under it. Smaller than `inset`
    /// deliberately: the label is a caption for the picture above it, and a gap as
    /// wide as the card's own margin would read as two unrelated things stacked.
    public static let itemPictureGap: CGFloat = 6

    /// How tall a picture may be, as a multiple of the card's content width.
    ///
    /// **A bound, not a look.** Aspect ratio is unbounded — a stitched panorama or
    /// a scanned receipt is 1:20 — and a card whose height is `width / aspect` is
    /// a card thousands of points tall, drawn every frame and impossible to get
    /// past. Beyond this ratio the picture is drawn to FIT the clamped box rather
    /// than filling it, so it is letterboxed and never distorted: the one thing an
    /// image on this surface may not do is stop being a faithful reproduction
    /// (spec §8A.2).
    public static let itemPictureMaximumHeightRatio: CGFloat = 3

    /// The height of an item card with no picture on it — one line of label inside
    /// the inset twice, which is the same arithmetic `cardHeight(forTextHeight:)`
    /// does for a scrap.
    ///
    /// **This is the FLOOR `CanvasView.rebuildLayouts` heals to**, and the heal is
    /// not bookkeeping: a node with no `cachedHeight` has no `frame`, and a node
    /// with no frame is dropped by `CanvasScene.topmostNode(at:)` and
    /// `nodes(intersecting:)` alike — neither drawn nor clickable, and persisted
    /// that way. It is also the honest height for a card whose picture has not
    /// decoded yet, because a label is exactly what such a card is showing.
    ///
    /// It was called `itemPlaceholderHeight` until 1C-d, when the placeholder it
    /// was named for stopped existing.
    public static let itemLabelOnlyHeight: CGFloat =
        cardHeight(forTextHeight: itemLabelLineHeight)

    /// **The one answer to "how tall is this item card".** `CanvasView` measures
    /// with it and `CanvasRenderer` lays the card out against the rects below,
    /// which are derived from the same terms.
    ///
    /// A genuine function of the WIDTH, which is what makes Task 6's resize safe:
    /// `CanvasScene.setWidth` clears the cached height by design, and the next
    /// measurement puts back a height that follows the new width, exactly as it
    /// does for a scrap.
    ///
    /// A non-positive or absent aspect ratio is the label-only card — there is no
    /// picture, or there is not one *yet*.
    public static func itemCardHeight(forCardWidth width: CGFloat,
                                      pictureAspect: CGFloat?) -> CGFloat {
        guard let aspect = pictureAspect, aspect > 0 else { return itemLabelOnlyHeight }
        return itemLabelOnlyHeight
            + itemPictureHeight(forCardWidth: width, aspect: aspect)
            + itemPictureGap
    }

    /// The height the picture's BOX takes on a card of this width — the content
    /// width over the aspect ratio, clamped by `itemPictureMaximumHeightRatio`.
    public static func itemPictureHeight(forCardWidth width: CGFloat,
                                         aspect: CGFloat) -> CGFloat {
        let content = textWidth(forCardWidth: width)
        return min(content / aspect, content * itemPictureMaximumHeightRatio)
    }

    /// Where the picture is drawn: the content width at the top of the card,
    /// **aspect-fitted** inside the box `itemPictureHeight` reserved for it.
    ///
    /// For every ratio inside the clamp the fit IS the box, to the point. Past it
    /// the picture is centred and letterboxed rather than cropped or stretched —
    /// a crop hides part of the page the writer is checking a reproduction
    /// against, and a stretch makes the card lie about the page's shape.
    public static func itemPictureRect(inCard frame: CGRect, aspect: CGFloat) -> CGRect {
        let box = CGRect(x: frame.minX + inset, y: frame.minY + inset,
                         width: textWidth(forCardWidth: frame.width),
                         height: itemPictureHeight(forCardWidth: frame.width, aspect: aspect))
        guard aspect > 0 else { return box }
        return fit(CGSize(width: aspect, height: 1), in: box)
    }

    /// The kind glyph's square, at the **bottom** of the card.
    ///
    /// Bottom-anchored, and that is load-bearing rather than a layout taste: the
    /// height a card is currently drawn at can be the floor while its picture is
    /// still decoding, and a label positioned from the top would then sit under
    /// the picture the next frame draws. Anchoring the label to the bottom edge
    /// keeps it on the card in both states.
    public static func itemGlyphBox(inCard frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + inset,
               y: frame.maxY - inset - itemLabelLineHeight,
               width: itemLabelLineHeight, height: itemLabelLineHeight)
    }

    /// Where the title starts — the glyph's square, plus the gap.
    public static func itemTitleOrigin(inCard frame: CGRect) -> CGPoint {
        let glyph = itemGlyphBox(inCard: frame)
        return CGPoint(x: glyph.maxX + itemGlyphGap, y: glyph.minY)
    }

    /// `size` scaled to fit inside `box`, centred — for the kind glyph, whose
    /// natural size is the SF Symbol's and is not square.
    ///
    /// Drawing a symbol into a square box directly is the obvious spelling and it
    /// stretches every glyph that is not square: `doc.text` is taller than it is
    /// wide and `waveform` is wider than it is tall, so the two would disagree
    /// about what a kind glyph looks like.
    public static func fit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}
