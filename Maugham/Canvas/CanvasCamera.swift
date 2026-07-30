import Foundation

/// Pan and zoom for the canvas.
///
/// Applied with `cx.translateBy` / `cx.scaleBy` inside the `Canvas` draw so
/// glyphs rasterise under the final CTM and stay crisp at every zoom. NOT
/// `.scaleEffect`, which scales rendered output, reports unscaled geometry
/// through `GeometryProxy`, and breaks `NSCursor` tracking (spec §7A.1).
///
/// NOT `NSScrollView.magnification` either: the 2026-07-25 spike confirmed on
/// macOS 26.5.2 that SwiftUI content hosted in a magnified `NSScrollView` is
/// completely unaware of the magnification — it reports the same `.global`
/// frame at every zoom, and above ~2x the mistranslated point falls outside the
/// view and clicks stop registering entirely.
struct CanvasCamera: Equatable {

    /// Where content origin sits in view coordinates.
    var pan: CGPoint = .zero
    var zoom: CGFloat = 1

    /// tldraw ships a comparable range. Below 0.1 nothing is legible; above 6
    /// a scrap fills the window and the writer wants the editor, not the canvas.
    static let zoomRange: ClosedRange<CGFloat> = 0.1...6.0

    func viewPoint(fromContent p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + pan.x, y: p.y * zoom + pan.y)
    }

    /// The inverse transform. This IS the hit test (spec §7A.1) — convert the
    /// click into content space, then walk the model in reverse z-order. It
    /// never touches SwiftUI's event machinery.
    func contentPoint(fromView p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.x) / zoom, y: (p.y - pan.y) / zoom)
    }

    /// What the viewport can see, in content coordinates. The draw loop culls
    /// against this: `guard rect.intersects(viewport) else { continue }`.
    func visibleContentRect(viewSize: CGSize) -> CGRect {
        CGRect(origin: contentPoint(fromView: .zero),
               size: CGSize(width: viewSize.width / zoom, height: viewSize.height / zoom))
    }

    /// Where a revealed point is put, in view coordinates.
    ///
    /// Not the origin: a region's chrome bar and label flush against the window's
    /// top-left corner reads as clipped rather than as arrived. Not centred
    /// either — centring needs the viewport size, and this view deliberately has
    /// no `GeometryReader` (the size exists only inside the `Canvas` closure), so
    /// a fixed inset is the whole of what can be honoured without inventing one.
    static let revealViewPoint = CGPoint(x: 120, y: 120)

    /// Pan so that `content` sits at `view` — `viewPoint(fromContent:)` solved
    /// for `pan`, which is what makes the round trip a test rather than an
    /// argument.
    ///
    /// **Zoom is untouched, deliberately.** A reveal that also zoomed would
    /// change what the writer can see of their own work in order to show them
    /// somebody else's, and "fit this rect" needs the viewport size this view
    /// does not have outside its draw closure.
    mutating func bring(_ content: CGPoint, toViewPoint view: CGPoint) {
        pan = CGPoint(x: view.x - content.x * zoom, y: view.y - content.y * zoom)
    }

    /// Translate the content by `delta`, in VIEW points. Sign is the caller's
    /// decision; this only applies it.
    mutating func panBy(_ delta: CGSize) {
        pan.x += delta.width
        pan.y += delta.height
    }

    /// Zoom while holding one view point still — zoom-to-cursor.
    ///
    /// The clamp is applied BEFORE the anchoring maths. Anchoring against the
    /// requested zoom and then clamping drifts the anchor precisely when the
    /// writer is pinned at a limit and pushing further, which is exactly when
    /// they are watching it.
    mutating func zoom(to newZoom: CGFloat, anchoringViewPoint anchor: CGPoint) {
        let clamped = min(max(newZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let contentUnderAnchor = contentPoint(fromView: anchor)
        zoom = clamped
        pan = CGPoint(x: anchor.x - contentUnderAnchor.x * clamped,
                      y: anchor.y - contentUnderAnchor.y * clamped)
    }
}
