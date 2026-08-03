import SwiftUI

/// §4's third row: **a document with nothing bound**. The board dims, and the
/// canvas says what to do next.
///
/// **Standing chrome, not a banner** (§4.1). It is state-derived and persists
/// for exactly as long as the state does, which is why a self-dismissing
/// notification is the wrong shape twice over — and why there is nothing here to
/// dismiss, no timer, and nothing that remembers having been shown. The writer
/// refuses it by ignoring it (constitution: nothing is pushed). The precedent is
/// the empty canvas's own standing instruction rather than the three
/// `.overlay(alignment: .top)` banners already sharing this window, two of which
/// draw over each other when they coincide.
///
/// **The predicate is a `static func` over its inputs** rather than a computed
/// property on the view, for this directory's stated reason: a decision one
/// level above a primitive is exactly where unreachable halves have shipped
/// here before. It is fully testable with nothing mounted, and what a mounted
/// test then has to prove is only that the view reads it.
enum CanvasBindingOffer {

    static let headline = "Nothing on this canvas is bound to this document yet."

    /// The next move, in the writer's own verb — the guide calls the gesture
    /// *"drag on empty canvas to draw one"*, and the binding is what §4.1's
    /// invariant adds to it while the board is dimmed.
    static let instruction = "Drag out a region and it binds to it."

    /// **TWO signals, and one of them is not enough.**
    ///
    /// `CanvasHighlight.litNothing` answers *"nothing on this canvas answers to
    /// the subject"* — and it is true for a **group** with nothing bound beneath
    /// it as well, where §4.1 rules the offer must never appear: a dimmed board
    /// under Part One says *"here is everything under Part One"*, not *"put
    /// something here"*, and a sweep there makes a plain region, so an offer
    /// would promise something the gesture does not do. It is also true of
    /// nothing at all on the project row, where the board is not dimmed.
    ///
    /// So the subject's own case is the second signal and it is asked FIRST: only
    /// a `.piece` — one manuscript document — can be bound to.
    static func isOffered(subject: CanvasSubject, highlight: CanvasHighlight) -> Bool {
        guard case .piece = subject else { return false }
        return highlight.litNothing
    }
}

/// The offer itself: two quiet lines in the middle of the board.
///
/// **It sits BENEATH `CanvasEventView` in the stack**, which is what keeps it out
/// of the pointer's way without an `.allowsHitTesting` of its own — the drawn
/// `Canvas` is already in that position and is plainly visible through the
/// transparent event view. That also keeps the mounted editor frontmost
/// (tripwire 27) with nothing between them.
///
/// It carries its own accessibility because it is a real view rather than
/// drawn content: the canvas's synthetic tree covers what is *on* the board,
/// and this is not on the board. Combined into one element so the offer is one
/// announcement rather than two fragments.
struct CanvasBindingOfferView: View {
    var body: some View {
        VStack(spacing: 4) {
            Text(CanvasBindingOffer.headline)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(CanvasBindingOffer.instruction)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}
