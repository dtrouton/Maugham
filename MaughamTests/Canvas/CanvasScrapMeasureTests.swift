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

    /// The floor's height, derived from the label the renderer draws rather than
    /// chosen by eye.
    ///
    /// `CanvasRenderer.drawItemContent` draws one line of title at
    /// `.system(size: CanvasCardMetrics.itemLabelFontSize)`, anchored `.topLeading`
    /// at `itemTitleOrigin(inCard:)`, inside a box inset `CanvasCardMetrics.inset`
    /// on every side. So a card with no picture on it must hold that line plus the
    /// inset twice. Measured here through `NSAttributedString` over a real title,
    /// which is a different mechanism from the one the production value uses, so
    /// the two agreeing means something.
    func test_anItemCardWithNoPictureIsTallEnoughForItsOwnLabel() {
        let line = NSAttributedString(
            string: "Notebook page 3",
            attributes: [.font: NSFont.systemFont(ofSize: CanvasCardMetrics.itemLabelFontSize)]
        ).size().height

        XCTAssertGreaterThanOrEqual(
            CanvasCardMetrics.itemLabelOnlyHeight,
            CanvasCardMetrics.inset * 2 + line,
            "an item node's card must leave room for the label the renderer draws "
            + "in it, or the card clips its own only content")
        XCTAssertLessThanOrEqual(
            CanvasCardMetrics.itemLabelOnlyHeight,
            CanvasCardMetrics.inset * 2 + line * 2,
            "a card with no picture holds ONE line of label — a height far above "
            + "that is a number picked by eye rather than derived from what is drawn")
    }

    // MARK: - An item card is measured (1C-d)

    /// **The floor and the no-picture measurement are the same number, and they
    /// have to be.** The floor is what `CanvasView.rebuildLayouts` heals a card to
    /// while its photograph is still decoding; the measurement is what the card
    /// gets when there is no photograph at all. If they ever differ, a card jumps
    /// height the instant a decode fails.
    func test_anItemCardWithNoPictureMeasuresToTheFloor() {
        for width in [CanvasInteraction.minimumCardWidth, 240, 600] as [CGFloat] {
            XCTAssertEqual(
                CanvasCardMetrics.itemCardHeight(forCardWidth: width, pictureAspect: nil),
                CanvasCardMetrics.itemLabelOnlyHeight,
                "a card with no picture must measure to the floor at every width — "
                + "the label does not wrap and does not care how wide the card is")
        }
    }

    /// **The height is a genuine function of the WIDTH**, which is spec §7A.3's
    /// rule and is what makes an item node safe to resize (Task 6):
    /// `CanvasScene.setWidth` clears the cached height by design, and a
    /// measurement that ignored the width would put back the same number for
    /// every size the writer chose.
    ///
    /// Asserted as a RATIO rather than against two literals: what the card
    /// promises is that the picture keeps its shape, and a pair of pinned numbers
    /// says nothing about that while breaking on any change to the label line.
    func test_anItemCardWithAPictureGrowsWithItsWidthAndKeepsTheAspect() {
        let aspect: CGFloat = 3.0 / 2.0          // an ordinary landscape photograph
        let narrow = CanvasCardMetrics.itemCardHeight(forCardWidth: 240, pictureAspect: aspect)
        let wide = CanvasCardMetrics.itemCardHeight(forCardWidth: 480, pictureAspect: aspect)

        XCTAssertGreaterThan(narrow, CanvasCardMetrics.itemLabelOnlyHeight,
                             "a picture added nothing to the card's height, so the "
                             + "photograph is drawn over its own label or not at all")
        XCTAssertGreaterThan(wide, narrow,
                             "the height does not follow the width — an item node's "
                             + "resize would distort every photograph on the canvas")

        // The picture's own box, which is the part that has to scale exactly.
        let narrowPicture = narrow - CanvasCardMetrics.itemLabelOnlyHeight
            - CanvasCardMetrics.itemPictureGap
        let widePicture = wide - CanvasCardMetrics.itemLabelOnlyHeight
            - CanvasCardMetrics.itemPictureGap
        XCTAssertEqual(
            CanvasCardMetrics.textWidth(forCardWidth: 240) / narrowPicture, aspect, accuracy: 0.001,
            "the picture's box is not the photograph's shape")
        XCTAssertEqual(
            CanvasCardMetrics.textWidth(forCardWidth: 480) / widePicture, aspect, accuracy: 0.001)
    }

    /// A portrait photograph is TALLER than the card is wide, and a landscape one
    /// is not. Without this the aspect could be applied upside down and every
    /// assertion above would still pass — both directions produce "a picture with
    /// a height that follows the width".
    func test_aPortraitPictureMakesATallerCardThanALandscapeOne() {
        let portrait = CanvasCardMetrics.itemCardHeight(forCardWidth: 240,
                                                        pictureAspect: 2.0 / 3.0)
        let landscape = CanvasCardMetrics.itemCardHeight(forCardWidth: 240,
                                                         pictureAspect: 3.0 / 2.0)
        XCTAssertGreaterThan(portrait, landscape,
                             "a portrait photograph is drawn as a landscape one — the "
                             + "aspect ratio is being applied the wrong way up")
        XCTAssertGreaterThan(portrait, 240,
                             "a 2:3 photograph on a 240 pt card is taller than it is "
                             + "wide, and this card is not")
    }

    /// **A pathological aspect ratio is CLAMPED, and the picture is letterboxed
    /// rather than cropped or stretched.** A stitched panorama or a scanned
    /// receipt is 1:20, and `width / aspect` on one is a card thousands of points
    /// tall, drawn every frame and impossible to get past.
    ///
    /// The second assertion is the one that matters: past the clamp the card's box
    /// is no longer the photograph's shape, so the *drawn rect* has to be, or the
    /// clamp buys a bounded card by making it lie about the page — which is the
    /// one thing spec §8A.2's reproduction corollary cannot afford.
    func test_anExtremeAspectIsClampedAndTheDrawnPictureIsStillTheRightShape() throws {
        let extreme: CGFloat = 1.0 / 20.0
        let content = CanvasCardMetrics.textWidth(forCardWidth: 240)
        let height = CanvasCardMetrics.itemCardHeight(forCardWidth: 240, pictureAspect: extreme)

        XCTAssertEqual(height,
                       CanvasCardMetrics.itemLabelOnlyHeight + CanvasCardMetrics.itemPictureGap
                           + content * CanvasCardMetrics.itemPictureMaximumHeightRatio,
                       accuracy: 0.001,
                       "a 1:20 photograph produced an unclamped card")
        // Control: the clamp is only meaningful because the unclamped number is
        // far larger. Without this the assertion above passes for a formula that
        // ignores the aspect ratio altogether.
        XCTAssertGreaterThan(content / extreme,
                             content * CanvasCardMetrics.itemPictureMaximumHeightRatio * 4)

        let card = CGRect(x: 0, y: 0, width: 240, height: height)
        let drawn = CanvasCardMetrics.itemPictureRect(inCard: card, aspect: extreme)
        XCTAssertEqual(drawn.width / drawn.height, extreme, accuracy: 0.001,
                       "the clamped picture is stretched to fill its box — the card is "
                       + "lying about the shape of the page it reproduces")
        XCTAssertLessThanOrEqual(drawn.maxY, CanvasCardMetrics.itemGlyphBox(inCard: card).minY,
                                 "the clamped picture is drawn over its own label")
    }

    /// **The drawn picture and the measured card are two readings of one
    /// arithmetic.** This is the §7A.2 discipline applied to the other content
    /// type: `CanvasCardMetrics` owns the rects, `CanvasView.rebuildLayouts`
    /// measures with them, and the renderer draws with them — so a card is never
    /// the wrong height for what is on it.
    func test_theMeasuredCardIsExactlyTallEnoughForThePictureAndTheLabel() throws {
        let aspect: CGFloat = 4.0 / 3.0
        let height = CanvasCardMetrics.itemCardHeight(forCardWidth: 240, pictureAspect: aspect)
        let card = CGRect(x: 12, y: 34, width: 240, height: height)

        let picture = CanvasCardMetrics.itemPictureRect(inCard: card, aspect: aspect)
        let glyph = CanvasCardMetrics.itemGlyphBox(inCard: card)

        XCTAssertEqual(picture.minY, card.minY + CanvasCardMetrics.inset, accuracy: 0.001,
                       "the picture does not start at the card's own inset")
        XCTAssertEqual(glyph.maxY, card.maxY - CanvasCardMetrics.inset, accuracy: 0.001,
                       "the label does not end at the card's own inset")
        XCTAssertEqual(glyph.minY - picture.maxY, CanvasCardMetrics.itemPictureGap, accuracy: 0.001,
                       "the gap between the picture and its caption is not the one the "
                       + "measurement reserved — the card is either padded or clipped")
        XCTAssertGreaterThan(CanvasCardMetrics.itemTitleOrigin(inCard: card).x, glyph.maxX,
                             "the title is drawn over the kind glyph")
    }

    /// An SF Symbol is not square, and drawing one into a square box stretches
    /// every glyph that is not — `doc.text` is taller than it is wide and
    /// `waveform` is wider than it is tall, so the two would disagree about what a
    /// kind glyph looks like.
    func test_aGlyphIsFittedInsideItsBoxRatherThanStretchedToIt() {
        let box = CGRect(x: 10, y: 10, width: 20, height: 20)
        let wide = CanvasCardMetrics.fit(CGSize(width: 40, height: 10), in: box)
        let tall = CanvasCardMetrics.fit(CGSize(width: 10, height: 40), in: box)

        XCTAssertEqual(wide.width / wide.height, 4, accuracy: 0.001)
        XCTAssertEqual(tall.width / tall.height, 0.25, accuracy: 0.001)
        XCTAssertTrue(box.insetBy(dx: -0.001, dy: -0.001).contains(wide),
                      "a fitted glyph left its box")
        XCTAssertTrue(box.insetBy(dx: -0.001, dy: -0.001).contains(tall))
        XCTAssertEqual(wide.midX, box.midX, accuracy: 0.001, "a fitted glyph is centred")
        XCTAssertEqual(tall.midY, box.midY, accuracy: 0.001)
    }
}
