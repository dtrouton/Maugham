import SwiftUI

/// §4's third row: **a document with nothing bound** — and, since stage 3b, the
/// same shape one subject over: **a research item whose card is not on this
/// canvas**. The board dims, and the canvas says what to do next.
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

    /// What the chrome says: the state the writer is looking at, then the gesture
    /// that changes it.
    ///
    /// **A value rather than two loose strings, since stage 3b**, because there
    /// are now two of these and the pair is the unit: a headline from one state
    /// over an instruction from the other names a gesture that will not do what
    /// the sentence above it promises, and nothing about two `String` constants
    /// makes that unspellable. `Equatable` so a test can assert *which* message
    /// the decision returned — with two of them, "chrome appeared" has stopped
    /// being the same claim as "the right chrome appeared".
    struct Message: Equatable {
        let headline: String
        let instruction: String
    }

    /// §4's third row: a manuscript document with nothing on this canvas bound to
    /// it. The instruction is the next move in the writer's own verb — the guide
    /// calls the gesture *"drag on empty canvas to draw one"*, and the binding is
    /// what §4.1's invariant adds to it while the board is dimmed.
    static let nothingBound = Message(
        headline: "Nothing on this canvas is bound to this document yet.",
        instruction: "Drag out a region and it binds to it.")

    /// §4's *"its card highlighted on the board"* with no card to highlight
    /// (stage 3b). The board still dims — that is Task 1's ruling and the reason
    /// this message has to exist: undimming would make the click on a research
    /// row indistinguishable from a click on the project row, and dimming
    /// silently leaves the writer a dark board with nothing lit and nothing said.
    ///
    /// **It names the TREE and never the sweep.** A research subject's sweep
    /// draws a plain region and binds nothing (§4.1's group precedent — the
    /// canvas never guesses a piece the writer never named), so *"drag out a
    /// region"* here would promise something the gesture does not do. The gesture
    /// that answers this state is the one that puts the card on the board:
    /// dragging the row out of the binder (spec §8A.1).
    static let cardNotHere = Message(
        headline: "This item isn't on this canvas yet.",
        instruction: "Drag its row from the tree to place it.")

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
    /// So the subject's own case is the second signal and it is asked FIRST — and
    /// since stage 3b it is asked as a `switch`, because it now chooses BETWEEN
    /// two messages rather than gating one. Both arms read the same `litNothing`:
    /// a chapter with a lit region and an item with its card on the board are the
    /// same state, *the board is answering you*, and chrome over either would be
    /// contradicting what the writer is looking at.
    ///
    /// **ONE decision function, deliberately** — the returned `Message?` is both
    /// "is there chrome" and "which", so no second predicate can disagree with
    /// this one about whether the middle of the board is occupied.
    static func message(subject: CanvasSubject, highlight: CanvasHighlight) -> Message? {
        switch subject {
        case .piece:
            return highlight.litNothing ? nothingBound : nil
        case .research:
            return highlight.litNothing ? cardNotHere : nil
        case .group, .wholeProject:
            return nil
        }
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

    /// Which of the two states the board is in — decided by
    /// `CanvasBindingOffer.message(subject:highlight:)` and never re-derived
    /// here. This view knows how the sentences look and nothing about when they
    /// appear.
    let message: CanvasBindingOffer.Message

    var body: some View {
        VStack(spacing: 4) {
            Text(message.headline)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(message.instruction)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}
