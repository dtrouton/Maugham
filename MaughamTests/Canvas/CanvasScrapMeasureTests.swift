import XCTest
import AppKit
@testable import Maugham

/// "How tall is this card" asked from outside a view.
///
/// The assertions here are all comparisons against something else that already
/// answers the question — `ScrapLayout` for a scrap, the label the renderer
/// actually draws for an item placeholder. A test that pinned either to a
/// literal would go green over exactly the drift this type exists to prevent:
/// spec §7A.2's "text jumps on focus", which is what a second spelling of the
/// card's height produces (`Maugham/Canvas/AREA.md`, "Card metrics live in
/// `CanvasCardMetrics`, and nowhere else").
final class CanvasScrapMeasureTests: XCTestCase {

    private let cardWidth: CGFloat = 240

    /// The anti-drift assertion. `CanvasView` builds a `ScrapLayout`, keeps it
    /// (the mounted `NSTextView` and the draw pass share one TextKit stack per
    /// scrap — tripwire 26) and takes the card height from this type; a caller
    /// with no view builds nothing and takes the same number. The two must be the
    /// same arithmetic over the same layout, or the planner places cards on one
    /// geometry and the canvas draws them on another.
    func test_theMeasureAgreesWithTheViewsOwnLayout() {
        let text = "The fog came in off the water and stayed there for three days, "
            + "which is longer than anyone remembered it staying before."
        let layout = ScrapLayout(
            text: text,
            width: CanvasCardMetrics.textWidth(forCardWidth: cardWidth),
            font: CanvasScrapMeasure.scrapFont,
            textColor: CanvasRenderer.cardInk)

        XCTAssertEqual(CanvasScrapMeasure.height(text: text, cardWidth: cardWidth),
                       CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight),
                       accuracy: 0.0001,
                       "the measure and the view's own layout must be one calculation — "
                       + "a second spelling of the card height is §7A.2's text-jump "
                       + "arriving by the back door")
    }

    /// Guards against a constant. A measurement that ignores its text is exactly
    /// what a planner would fail to notice: every card would be placed at the
    /// same height and the drawn ones would overlap.
    func test_tallerTextMeasuresTaller() {
        let word = CanvasScrapMeasure.height(text: "Fog", cardWidth: cardWidth)
        let paragraph = CanvasScrapMeasure.height(
            text: String(repeating: "The fog came in off the water and stayed. ", count: 6),
            cardWidth: cardWidth)

        XCTAssertGreaterThan(paragraph, word,
                             "a paragraph must measure taller than a word at the same "
                             + "width, or the measurement is not reading the text")
    }

    /// `ScrapLayout.measuredHeight` floors at one line (`emptyLineHeight`, 18)
    /// precisely so a freshly created scrap has a frame at all — `CanvasNode.frame`
    /// is nil without a height and both `nodes(intersecting:)` and
    /// `topmostNode(at:)` drop a node with no frame, so a zero-height card is
    /// neither drawn nor clickable. The card height must carry that floor through.
    func test_anEmptyScrapStillGetsALinesHeight() {
        let empty = CanvasScrapMeasure.height(text: "", cardWidth: cardWidth)

        XCTAssertGreaterThanOrEqual(empty, CanvasCardMetrics.cardHeight(forTextHeight: 18),
                                    "an empty scrap must still get a line's worth of card, "
                                    + "or a card created empty is invisible and "
                                    + "un-clickable — ScrapLayout's own floor exists for "
                                    + "that reason and must not be lost on the way out")
    }

    /// The item placeholder's height, derived from the label the renderer draws
    /// rather than chosen by eye.
    ///
    /// `CanvasRenderer.drawCard`'s `.item` arm resolves
    /// `Text(CanvasRenderer.placeholderLabel(for:))` at
    /// `.system(size: CanvasCardMetrics.itemLabelFontSize)` and draws it
    /// `.topLeading` at `CanvasCardMetrics.textOrigin(inCard:)` — one line, inside
    /// a box inset `CanvasCardMetrics.inset` on every side. So the card must hold
    /// that line plus the inset twice. Measured here through `NSAttributedString`
    /// over the real label string, which is a different mechanism from the one the
    /// production value uses, so the two agreeing means something.
    func test_anItemPlaceholderIsTallEnoughForItsOwnLabel() {
        let label = CanvasRenderer.placeholderLabel(for: .project(id: "res-2026-07-30-abcd"))
        let line = NSAttributedString(
            string: label,
            attributes: [.font: NSFont.systemFont(ofSize: CanvasCardMetrics.itemLabelFontSize)]
        ).size().height

        XCTAssertGreaterThanOrEqual(
            CanvasCardMetrics.itemPlaceholderHeight,
            CanvasCardMetrics.inset * 2 + line,
            "an item node's card must leave room for the label the renderer draws "
            + "in it, or the placeholder clips its own only content")
        XCTAssertLessThanOrEqual(
            CanvasCardMetrics.itemPlaceholderHeight,
            CanvasCardMetrics.inset * 2 + line * 2,
            "the placeholder holds ONE line of label — a height far above that is a "
            + "number picked by eye rather than derived from what is drawn")
    }
}
