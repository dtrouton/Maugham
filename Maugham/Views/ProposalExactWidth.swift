import SwiftUI

/// **A row that answers exactly the width it was offered when it fits.**
///
/// SwiftUI's stacks share space in floating point: the right column's
/// control at the floor splits 208pt among three flexible segments, and the
/// shares sum to 216.00000000000003 — a row 3e-14 wider than its proposal.
/// A `.frame(maxWidth: .infinity)` answers the larger of the two, so the
/// control reports 232.00000000000003; the column's `VStack` takes that as
/// its width and offers it to the pane below, and a wrapped `Text` there
/// rounds 208.00000000000003 UP to the next device pixel — half a point on a
/// Retina display, a whole point at 1x, enough to carry the pane (and the
/// brief editor in it) one point past the column on CI's display.
///
/// This absorbs ONLY that error: a child wider than the proposal by less
/// than `tolerance` answers the proposal. A child that really overflows
/// answers its own width, so a census measuring it still sees the overflow
/// — unlike a `.frame(minWidth: 0, …)`, which hides any overflow
/// (`RightColumnPaneWidthTests`).
struct ProposalExactWidth: Layout {
    /// Far below any device pixel; far above a floating-point sum's error.
    static let tolerance: CGFloat = 0.001

    /// The width this layout answers for a child of `child` width under a
    /// proposal of `proposed` (nil: unspecified). Pure.
    static func width(child: CGFloat, proposed: CGFloat?) -> CGFloat {
        guard let proposed, child > proposed, child - proposed < tolerance else { return child }
        return proposed
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(proposal)
        return CGSize(width: Self.width(child: size.width, proposed: proposal.width), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for child in subviews {
            child.place(at: bounds.origin, anchor: .topLeading,
                        proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}
