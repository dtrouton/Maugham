import SwiftUI

/// **A column pane may not set the WINDOW's minimum height.**
///
/// SwiftUI propagates a subtree's minimum height all the way out to
/// `NSHostingView`, and a window shorter than that minimum is not compressed —
/// it is **centred**. In a three-column `NavigationSplitView` that is not a
/// cosmetic difference: the whole split view is laid out shorter than the
/// window and pushed up, so the sidebar's scroll view acquires a NEGATIVE frame
/// origin and the top of the binder tree ends up above the window's top edge,
/// with its scroller never having moved (measured 2026-08-18,
/// `TreeScrollStabilityTests.test_control_aWindowShorterThanItsMinimumPutsTheTreeOutsideIt`).
///
/// **`NSHostingView` stamps `window.contentMinSize` once, at mount.** A pane
/// whose minimum height RISES afterwards therefore cannot push the window back
/// out: the writer's window stays at a size the window itself still considers
/// legal while the content has quietly decided it needs more, and every height
/// in the gap lays out short. That is exactly what Denver's Review smoke found
/// — swapping the review pass made `AnnotationsPane`'s advisory nudge appear,
/// the pane's minimum height rose with it, and at window heights inside the new
/// gap the tree was displaced upward out of the column.
///
/// So the rule this expresses: **a pane's content growing is a reason to
/// compress or scroll that pane, never a reason to move the window's floor.**
/// The floor is `ProjectWindow`'s own `.frame(minHeight:)` and nothing else's
/// business.
///
/// It is a `Layout` rather than a `frame`/`layoutPriority` because neither of
/// those can LOWER a reported minimum: `frame(minHeight: 0)` returns
/// `max(0, childMinimum)`, and layout priority only redistributes space a stack
/// already has. What is needed is a container that answers the minimum-height
/// question with the space it was offered — including zero — while still
/// drawing its content at the content's own ideal height when there is room.
struct WindowFloorFreeLayout: Layout {

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        // The ideal height is asked for at the width actually on offer — a
        // height measured at the content's unconstrained width is the wrong
        // number for every wrapping thing inside it.
        let ideal = subview.sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil))
        // **The width answer is the content's own, unchanged.** Only the height
        // is freed here: reporting `proposal.width` would hand back a zero
        // minimum width on the width query too, and this column has a floor its
        // toolbar is measured against (`AnnotationsQueueToolbarWidthTests`).
        let width = ideal.width
        // An unspecified or infinite height proposal is a question about what
        // the content WANTS, and the honest answer is its ideal. Every other
        // proposal — the minimum query included — is an offer, and this
        // container accepts whatever it is offered rather than insisting.
        guard let height = proposal.height, height != .infinity else {
            return CGSize(width: width, height: ideal.height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout Void
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension View {
    /// Wrap a column pane so nothing inside it can raise the window's minimum
    /// height. See ``WindowFloorFreeLayout``.
    ///
    /// The clip is part of the contract: below the height its chrome wants, the
    /// pane loses its own bottom rather than the window losing the top of
    /// another column.
    func doesNotRaiseTheWindowFloor() -> some View {
        WindowFloorFreeLayout { self }.clipped()
    }
}
