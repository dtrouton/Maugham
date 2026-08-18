import XCTest
import AppKit
import SwiftUI
@testable import Maugham

/// **`WindowFloorFreeLayout`'s four answers, one test each.**
///
/// The container exists to stop a pane's chrome setting the window's minimum
/// height, and every part of that is a proposal answer:
///
/// | proposal height | answer | why |
/// |---|---|---|
/// | zero | zero | the MINIMUM query — answering it with the content's demand is the whole defect |
/// | definite | that height | an offer, accepted; the content compresses into it |
/// | infinite | the content's ideal | "how big do you want to be", not an offer |
/// | unspecified | the content's ideal | the same question with no number attached |
///
/// Plus the width, which is passed straight through: only the height is freed,
/// because this column has a floor its toolbar is measured against
/// (`AnnotationsQueueToolbarWidthTests`). A container that zeroed the width
/// answer too would take that floor out with it, and nothing in the height
/// tests would notice.
///
/// Driven through `NSHostingController.sizeThatFits(in:)`, which is the one API
/// that lets a test ASK a definite proposal — every other instrument here
/// (`fittingSize`, `intrinsicContentSize`, `contentMinSize`) answers one fixed
/// question each.
@MainActor
final class WindowFloorFreeLayoutTests: XCTestCase {

    private let childWidth: CGFloat = 200
    private let childHeight: CGFloat = 120

    /// A child with a definite ideal size and a definite minimum width, so both
    /// the height answers and the width pass-through have something to be wrong
    /// about.
    private func hosted() -> NSHostingController<AnyView> {
        NSHostingController(rootView: AnyView(
            Color.clear
                .frame(width: childWidth, height: childHeight)
                .doesNotRaiseTheWindowFloor()))
    }

    // MARK: - The height answers

    /// **Zero in, zero out** — the minimum query, and the reason the type
    /// exists. A `frame(minHeight: 0)` cannot do this: it returns
    /// `max(0, childMinimum)`, which is the child's minimum.
    func test_aZeroHeightProposalIsAccepted() {
        let size = hosted().sizeThatFits(in: CGSize(width: 300, height: 0))
        XCTAssertEqual(
            size.height, 0, accuracy: 0.5,
            "the minimum-height query must be answered with zero — answering it "
            + "with the content's own demand is exactly the leak this container "
            + "is for, and it is what reaches `window.contentMinSize`")
    }

    /// A definite offer is accepted as given, including one SMALLER than the
    /// content wants: the content compresses (and clips) rather than the
    /// container insisting.
    func test_aDefiniteHeightProposalIsAcceptedAsGiven() {
        let squeezed = hosted().sizeThatFits(in: CGSize(width: 300, height: 50))
        XCTAssertEqual(
            squeezed.height, 50, accuracy: 0.5,
            "a definite proposal is an offer, and this container accepts what "
            + "it is offered — 50 is below the content's own \(childHeight) on "
            + "purpose")

        let roomy = hosted().sizeThatFits(in: CGSize(width: 300, height: 400))
        XCTAssertEqual(
            roomy.height, 400, accuracy: 0.5,
            "and it fills a definite offer larger than the content, so a pane "
            + "still occupies its whole column")
    }

    /// **Infinity is a question, not an offer**, and the honest answer is what
    /// the content wants. Returning infinity would hand a greedy nonsense up to
    /// whatever asked.
    func test_anInfiniteHeightProposalAnswersTheContentsIdeal() {
        let size = hosted().sizeThatFits(
            in: CGSize(width: 300, height: CGFloat.infinity))
        XCTAssertEqual(
            size.height, childHeight, accuracy: 0.5,
            "an infinite proposal asks how tall the content wants to be; the "
            + "answer is its ideal (\(childHeight)), never infinity")
    }

    /// The same question with no number attached. This is the one `fittingSize`
    /// asks — which is why `fittingSize` on a pane still rises when its content
    /// grows, fix or no fix, and why the 2026-08-18 note is careful to separate
    /// the ideal from the minimum.
    func test_anUnspecifiedHeightProposalAnswersTheContentsIdeal() {
        let hosting = NSHostingView(rootView: AnyView(
            Color.clear
                .frame(width: childWidth, height: childHeight)
                .doesNotRaiseTheWindowFloor()))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            hosting.intrinsicContentSize.height, childHeight, accuracy: 0.5,
            "with no height proposed, the answer is the content's ideal — the "
            + "container is invisible to anything asking what the pane wants")
    }

    // MARK: - The width

    /// **Only the height is freed.** The width answer is the content's own, so
    /// a zero-width proposal returns the child's minimum width rather than
    /// zero. Written as `proposal.width ?? ideal.width` this test is red, and
    /// the column's own floor would have gone quietly.
    func test_theWidthAnswerIsTheContentsOwnNotTheProposals() {
        let hosting = NSHostingController(rootView: AnyView(
            Color.clear
                .frame(minWidth: 250, minHeight: 40)
                .doesNotRaiseTheWindowFloor()))

        let size = hosting.sizeThatFits(in: CGSize(width: 0, height: 100))
        XCTAssertEqual(
            size.width, 250, accuracy: 0.5,
            "a zero-width proposal must still answer the content's own minimum "
            + "width (250) — this column has a floor its toolbar is measured "
            + "against, and freeing the width would take that out with it")
    }
}
