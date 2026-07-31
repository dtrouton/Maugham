import XCTest
import SwiftUI
@testable import Maugham

/// Lines, drawn: the projection to node centres, the viewport cull, the label
/// pill, the connect mark on the selected card, and the pass order that binds
/// what is drawn on top to what will take the click.
///
/// The raster fixtures follow `CanvasRegionRenderTests`' idiom — render two
/// scenes differing in exactly ONE model fact and count the pixels that changed.
/// That is exact, needs no colour threshold, and a control rect asserting *zero*
/// is a real assertion rather than a rounding allowance.
final class CanvasLineRenderTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let l1 = CanvasLineID("l1")

    /// Two measured cards whose centres are (100, 20) and (540, 60) — so the
    /// segment's midpoint is (320, 40) and the segment is deliberately NOT
    /// axis-aligned. The horizontal case has its own fixture, because a
    /// horizontal fixture here would make every culling assertion depend on the
    /// hairline inset and there would be nothing left to control it against.
    private func twoCards() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 0, y: 0),
                            width: 200, cachedHeight: 40))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 440, y: 40),
                            width: 200, cachedHeight: 40))
        return s
    }

    private func linked(label: String? = nil) -> CanvasScene {
        var s = twoCards()
        s.insertLine(CanvasLine(id: l1, from: a, to: b, label: label))
        return s
    }

    private let viewport = CGSize(width: 800, height: 600)

    // MARK: - Projection

    func test_theDrawnLineResolvesToNodeCentresAndCarriesTheLabel() throws {
        let geometry = linked(label: "because").drawnLines
        XCTAssertEqual(geometry.count, 1)
        let line = try XCTUnwrap(geometry.first)
        XCTAssertEqual(line.id, l1)
        XCTAssertEqual(line.from, CGPoint(x: 100, y: 20),
                       "endpoints are node CENTRES — the same reading joinTarget "
                       + "takes for a drop, so the canvas has one answer to "
                       + "'where is this card'")
        XCTAssertEqual(line.to, CGPoint(x: 540, y: 60))
        XCTAssertEqual(line.label, "because",
                       "the label travels with the geometry; a projection that "
                       + "dropped it would draw every line unlabelled")
    }

    /// An unmeasured node has no frame at all, so drawing to a guessed position
    /// would twitch the instant the real measurement arrived.
    func test_linesToUnmeasuredNodesAreNotProjected() {
        let c = CanvasNodeID("c")
        var s = linked()
        s.insert(CanvasNode(id: c, kind: .scrap, origin: CGPoint(x: 900, y: 0),
                            width: 200, cachedHeight: nil))
        s.insertLine(CanvasLine(id: CanvasLineID("l2"), from: b, to: c))

        XCTAssertEqual(s.lines.count, 2,
                       "control: BOTH lines are genuinely in the scene, so the "
                       + "filter below is not measuring an insert that failed")
        XCTAssertNil(try XCTUnwrap(s.node(c)).frame, "control: c really is unmeasured")
        XCTAssertEqual(s.drawnLines.map(\.id), [l1])
    }

    /// **A resident of a collapsed region keeps its frame**, so `endpoints(of:)`
    /// answers happily for a card that is not drawn at all — and the line runs
    /// into bare ground. The two neighbouring per-frame passes in the renderer
    /// already guard exactly this (`tethers` skips a collapsed region's
    /// residents, `appearanceChips` filters `!scene.isHidden`), and lines shipped
    /// without it for one commit.
    ///
    /// It decides Task 5's hit test as well as the draw: a line the writer can
    /// click and cannot see is worse than one that is merely wrong.
    func test_aLineToACardInsideACollapsedRegionIsNotDrawn() {
        let hiding = CanvasRegionID("hiding")
        var s = linked()
        s.insertRegion(CanvasRegion(id: hiding, label: "Cut",
                                    frame: CGRect(x: 400, y: 0, width: 400, height: 200)))
        CanvasMembership.join(b, home: hiding, in: &s)

        XCTAssertEqual(s.drawnLines.map(\.id), [l1],
                       "control: while the region is expanded the line is projected, "
                       + "so the absence below is the collapse and not the membership")

        s.updateRegion(hiding) { $0.isCollapsed = true }
        XCTAssertTrue(s.isHidden(b), "precondition: b is hidden by the collapse")
        XCTAssertNotNil(s.node(b)?.frame,
                        "precondition — and the whole trap: a hidden node KEEPS its "
                        + "frame, so endpoints(of:) still answers and only an "
                        + "isHidden guard can catch this")
        XCTAssertTrue(s.drawnLines.isEmpty,
                      "a line to a card inside a collapsed region is still projected — "
                      + "it draws into bare ground, and Task 5 will hit-test a line "
                      + "the writer cannot see")
    }

    // MARK: - The label pill

    func test_theLabelBoxIsCentredOnTheSegmentMidpoint() throws {
        let line = try XCTUnwrap(linked(label: "because").drawnLines.first)
        let box = CanvasRenderer.lineLabelBox(for: line)
        XCTAssertEqual(box.midX, 320, accuracy: 0.001)
        XCTAssertEqual(box.midY, 40, accuracy: 0.001)
        XCTAssertGreaterThan(box.width, 0)
        XCTAssertGreaterThan(box.height, 0)
    }

    func test_theLabelBoxIsEmptyForAnUnlabelledLine() throws {
        let bare = try XCTUnwrap(linked().drawnLines.first)
        XCTAssertTrue(CanvasRenderer.lineLabelBox(for: bare).isEmpty,
                      "an unlabelled line reserves a pill of empty ground in the "
                      + "middle of the segment")

        let named = try XCTUnwrap(linked(label: "because").drawnLines.first)
        XCTAssertFalse(CanvasRenderer.lineLabelBox(for: named).isEmpty,
                       "control: the same geometry WITH a label does reserve one, "
                       + "so the emptiness above is not lineLabelBox returning "
                       + "nothing for everything")
    }

    /// Three readings of "whitespace is no name" and the renderer used to be the
    /// odd one out: `LineInspector.normalise` and
    /// `CanvasAccessibility.connectionPhrase` trim `.whitespacesAndNewlines`,
    /// while `lineLabelBox` trimmed `.whitespaces` — space and tab only — so a
    /// label of `"\n"` drew a pill with nothing in it and was announced as
    /// nothing at all.
    ///
    /// The route in is a hand-edited sidecar: `CanvasSceneCodec` does not
    /// normalise labels on load. It is NOT `add_canvas_scraps`, whose `connect`
    /// carries no label to write.
    ///
    /// Disable experiment, run 2026-07-30: restore `.whitespaces` and the `"\n"`
    /// case goes red on its own while `"\t"`, `" "` and the control stay green —
    /// so the assertion is about the widening and not about the helper.
    func test_aWhitespaceOnlyLabelDrawsNoPill() throws {
        for blank in ["\n", "\t", " ", " \n\t "] {
            let line = try XCTUnwrap(linked(label: blank).drawnLines.first)
            XCTAssertTrue(CanvasRenderer.lineLabelBox(for: line).isEmpty,
                          "a label of \(blank.debugDescription) is no name, so it "
                          + "reserves no pill — the renderer trims the same set "
                          + "LineInspector.normalise does")
        }
        let named = try XCTUnwrap(linked(label: "\nbecause\n").drawnLines.first)
        XCTAssertFalse(CanvasRenderer.lineLabelBox(for: named).isEmpty,
                       "control: a label that is only SURROUNDED by newlines still "
                       + "has a name in it, so widening the trim must not swallow "
                       + "the pill for everything containing one")
    }

    // MARK: - Culling

    /// Per-frame work on this surface is viewport-proportional by design, and
    /// lines are the one collection nothing bounds — a writer can draw one for
    /// every card, so "there are fewer lines than nodes" is not an argument.
    func test_aLineFarOutsideTheViewportIsCulled() {
        let far1 = CanvasNodeID("far1"), far2 = CanvasNodeID("far2")
        var s = linked()
        s.insert(CanvasNode(id: far1, kind: .scrap, origin: CGPoint(x: 90_000, y: 0),
                            width: 200, cachedHeight: 40))
        s.insert(CanvasNode(id: far2, kind: .scrap, origin: CGPoint(x: 90_600, y: 400),
                            width: 200, cachedHeight: 40))
        s.insertLine(CanvasLine(id: CanvasLineID("l2"), from: far1, to: far2))

        XCTAssertEqual(s.drawnLines.count, 2,
                       "control: the unculled projection still sees both, so the "
                       + "cull below is not hiding a projection failure")
        XCTAssertEqual(CanvasRenderer.visibleLines(in: s, camera: CanvasCamera(),
                                                   viewSize: viewport).map(\.id),
                       [l1])
    }

    /// **The control the negative test needs.** Every negative result in this
    /// area needs one that passed — a `visibleLines` that returned `[]` for
    /// everything satisfies the cull above.
    func test_aLineInsideTheViewportSurvivesCulling() {
        XCTAssertEqual(CanvasRenderer.visibleLines(in: linked(), camera: CanvasCamera(),
                                                   viewSize: viewport).map(\.id),
                       [l1])
    }

    /// **The hairline inset in `visibleLines` is not a rounding nicety** — but
    /// the reason this task was briefed with is wrong on this platform, and the
    /// assertion is shaped around what was actually measured rather than around
    /// what was expected.
    ///
    /// The brief's premise was "`CGRect.intersects` is FALSE for an empty rect".
    /// **Measured 2026-07-28 on macOS 26.5, it is not:** `intersects` is false
    /// only for a NULL rect, and a zero-height box lying across the viewport
    /// reports `true`. So an assertion on `visibleLines`' output alone stays
    /// GREEN with the inset deleted, which is precisely the unfalsifiable shape
    /// this area keeps finding.
    ///
    /// What is real is one spelling over: `intersection(viewport)` of that same
    /// degenerate box is not null and **is empty**, so a tidy-up to
    /// `!box.intersection(viewport).isEmpty` — which reads as a synonym — culls
    /// every axis-aligned line on the canvas, and two cards side by side is the
    /// ordinary case rather than the corner one. The inset removes the question
    /// by giving the box area, so the assertion that can go red is the one on
    /// `boundingBox` itself.
    func test_anAxisAlignedLineIsNotCulledByItsZeroHeightBox() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 0, y: 0),
                            width: 200, cachedHeight: 40))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 440, y: 0),
                            width: 200, cachedHeight: 40))
        s.insertLine(CanvasLine(id: l1, from: a, to: b))

        let line = try XCTUnwrap(s.drawnLines.first)
        XCTAssertEqual(line.from.y, line.to.y,
                       "precondition: this fixture is EXACTLY horizontal, which is "
                       + "what gives its bounding box zero height")

        // The platform's actual behaviour, pinned rather than assumed, because
        // it is what decides the shape of everything below. If a future macOS
        // changes either of these, this test says so before the canvas does.
        let page = CGRect(origin: .zero, size: viewport)
        let bareBox = CGRect(x: line.from.x, y: line.from.y,
                             width: line.to.x - line.from.x, height: 0)
        XCTAssertTrue(bareBox.isEmpty, "precondition: the raw segment box is degenerate")
        XCTAssertTrue(bareBox.intersects(page),
                      "measured: CGRect.intersects is false only for a NULL rect, "
                      + "so an empty box across the viewport reports true. If this "
                      + "flips, the output assertion below becomes the falsifiable "
                      + "one and this test can be simplified")
        XCTAssertTrue(bareBox.intersection(page).isEmpty,
                      "…and the trap one spelling over: the intersection of that "
                      + "same box IS empty, so a cull written as "
                      + "`!box.intersection(viewport).isEmpty` drops every "
                      + "axis-aligned line on the canvas")

        // The assertion that can actually go red: the inset is what gives the
        // culled-against box area, and so what makes the cull independent of
        // which emptiness rule it is spelled with.
        let culledAgainst = CanvasRenderer.boundingBox(of: line)
        XCTAssertFalse(culledAgainst.isEmpty,
                       "visibleLines culls an EMPTY rect for a horizontal line — the "
                       + "hairline inset has been removed, and the cull now depends "
                       + "on CGRect's empty-rect semantics being the forgiving ones")
        XCTAssertFalse(culledAgainst.intersection(page).isEmpty,
                       "…and its intersection with the viewport is empty too, so the "
                       + "line survives only by the spelling `intersects` happens to "
                       + "use")

        XCTAssertEqual(CanvasRenderer.visibleLines(in: s, camera: CanvasCamera(),
                                                   viewSize: viewport).map(\.id),
                       [l1],
                       "a horizontal line between two cards side by side was culled "
                       + "out of a viewport it runs straight across")
    }

    // MARK: - The connect mark's geometry

    func test_theConnectHandleSitsOnTheCardsRightEdgeAndInsideIt() {
        let card = CGRect(x: 100, y: 100, width: 240, height: 80)
        let handle = CanvasRenderer.connectHandleRect(inCard: card)
        XCTAssertEqual(handle.maxX, card.maxX, accuracy: 0.001, "on the right edge")
        XCTAssertEqual(handle.width, CanvasRenderer.connectHandleSize, accuracy: 0.001)
        XCTAssertEqual(handle.height, CanvasRenderer.connectHandleSize, accuracy: 0.001)
        XCTAssertEqual(handle.midY, card.midY, accuracy: 0.001, "vertically centred")
        XCTAssertTrue(card.contains(handle),
                      "and INSIDE the card: a target hanging over the edge takes "
                      + "clicks aimed at the ground beside it")
    }

    /// On a card too short for both, **the corner belongs to resize** — it is
    /// the permanent mark, and a target that moved depending on the card's
    /// height would be worse than one that is sometimes absent.
    func test_theConnectHandleNeverOverlapsTheResizeCorner() {
        for height in [CGFloat(28), 30, 40, 80, 200] {
            let card = CGRect(x: 100, y: 100, width: 240, height: height)
            let handle = CanvasRenderer.connectHandleRect(inCard: card)
            let resize = CGRect(x: card.maxX - CanvasRenderer.resizeHandleSize,
                                y: card.maxY - CanvasRenderer.resizeHandleSize,
                                width: CanvasRenderer.resizeHandleSize,
                                height: CanvasRenderer.resizeHandleSize)

            XCTAssertFalse(handle.isEmpty,
                           "a \(height) pt card has room for both marks and got no "
                           + "connect handle at all")
            XCTAssertFalse(handle.intersects(resize),
                           "at height \(height) the connect handle \(handle) overlaps "
                           + "the resize corner \(resize) — one gesture would take "
                           + "the other's clicks")
            XCTAssertTrue(card.contains(handle),
                          "at height \(height) the clamp pushed the handle outside "
                          + "the card")
        }

        let tooShort = CGRect(x: 100, y: 100, width: 240, height: 20)
        XCTAssertTrue(CanvasRenderer.connectHandleRect(inCard: tooShort).isEmpty,
                      "a card too short for both marks must YIELD the corner to "
                      + "resize rather than move the connect target somewhere the "
                      + "writer has to hunt for it")
    }

    /// **`connectHandleRect` reserves room for the resize triangle on EVERY card,
    /// and as of 1C-d Task 6 every card draws one** — so the subtraction is now
    /// correct rather than merely harmless.
    ///
    /// It was recorded as a cosmetic wrong in 1C-c3 and left alone by Task 5 on
    /// the strength of two measurements, which this re-does rather than quotes:
    /// the clamp only bites below a card height of `2 * (resizeHandleSize +
    /// connectHandleSize / 2)`, and a pictured item card is far above it. Fixing
    /// it then would have been a change this task undid.
    func test_theConnectDotsReservationIsForAMarkEveryCardNowDraws() throws {
        // Where the clamp begins to bite, as arithmetic: `y` is
        // `min(midY - connectHandleSize / 2, maxY - resizeHandleSize -
        // connectHandleSize)`, and the two are equal at this height.
        let clampBitesBelow = 2 * (CanvasRenderer.resizeHandleSize
                                   + CanvasRenderer.connectHandleSize / 2)
        XCTAssertEqual(clampBitesBelow, 42, "the calibrated figure in Maugham/Canvas/AREA.md")

        // A pictured item card — the ordinary one. A 4:3 photograph on a card at
        // the default width, measured through the same function the canvas uses.
        let pictured = CanvasCardMetrics.itemCardHeight(
            forCardWidth: CanvasInteraction.defaultScrapWidth, pictureAspect: 4.0 / 3.0)
        XCTAssertGreaterThan(pictured, clampBitesBelow,
                             "a pictured item card is short enough for the clamp to "
                             + "move its connect dot, which is not what AREA.md's "
                             + "measurement says (\(pictured) pt)")
        let picturedCard = CGRect(x: 0, y: 0, width: 240, height: pictured)
        XCTAssertEqual(CanvasRenderer.connectHandleRect(inCard: picturedCard).midY,
                       picturedCard.midY, accuracy: 0.001,
                       "the clamp bit on a pictured item card")

        // A label-only item card — the floor, and the one the clamp does move.
        // What has to hold there is not that the dot is centred but that it is on
        // the card and clear of the resize square the card now draws.
        let floorCard = CGRect(x: 0, y: 0, width: 240,
                               height: CanvasCardMetrics.itemLabelOnlyHeight)
        XCTAssertLessThan(floorCard.height, clampBitesBelow,
                          "control: the floor card is tall enough to escape the clamp, "
                          + "so the assertions below are not exercising it")
        let handle = CanvasRenderer.connectHandleRect(inCard: floorCard)
        XCTAssertFalse(handle.isEmpty,
                       "the floor-height item card lost its connect target entirely")
        XCTAssertTrue(floorCard.contains(handle),
                      "the clamp pushed the connect target off a floor-height item card")
        XCTAssertFalse(handle.intersects(CGRect(x: floorCard.maxX - CanvasRenderer.resizeHandleSize,
                                                y: floorCard.maxY - CanvasRenderer.resizeHandleSize,
                                                width: CanvasRenderer.resizeHandleSize,
                                                height: CanvasRenderer.resizeHandleSize)),
                       "the connect target overlaps the resize square on a floor-height "
                       + "item card — and that square is now a live target with a mark "
                       + "on it, so one gesture takes the other's clicks")
    }

    /// The target may be larger than the mark, and should be — the reason
    /// `CanvasInteractionTests.test_theUnmarkedHalfOfTheCornerSquareStillResizes`
    /// exists. A target slightly larger than its ink forgives a near miss, where
    /// the reverse swallows drags the writer aimed at the card.
    ///
    /// There are deliberately TWO constants, not one, and the split is the
    /// design: `CanvasMaterial.connectMarkDiameter` is a look number the writer
    /// tunes by eye, `CanvasRenderer.connectHandleSize` is target geometry. What
    /// has to hold between them is a containment, which is what this asserts —
    /// an earlier name here claimed they came from one constant, which was never
    /// true and would have been the wrong design if it were.
    func test_theConnectTargetContainsItsMarkAndIsLargerThanIt() {
        let card = CGRect(x: 100, y: 100, width: 240, height: 80)
        let target = CanvasRenderer.connectHandleRect(inCard: card)
        let mark = CanvasRenderer.connectMarkRect(inCard: card)

        XCTAssertTrue(target.contains(mark),
                      "the mark \(mark) is not inside its target \(target) — a "
                      + "target smaller than its own ink swallows drags the writer "
                      + "aimed at the card")
        XCTAssertLessThan(mark.width, target.width,
                          "…and STRICTLY inside, so a near miss is forgiven")
        XCTAssertEqual(mark.midX, target.midX, accuracy: 0.001)
        XCTAssertEqual(mark.midY, target.midY, accuracy: 0.001)
        XCTAssertEqual(mark.width, CanvasMaterial.connectMarkDiameter, accuracy: 0.001)
        XCTAssertTrue(CanvasRenderer.connectMarkRect(
            inCard: CGRect(x: 100, y: 100, width: 240, height: 20)).isEmpty,
                      "the mark must yield with its target, or a card too short for "
                      + "the gesture still advertises it")
    }

    // MARK: - Drawn output, rasterised

    /// The line, actually drawn. The two scenes differ only in whether the line
    /// is in the model; every pixel that changes is the line.
    @MainActor
    func test_aLineIsActuallyDrawnBetweenItsTwoCards() throws {
        let size = CGSize(width: 700, height: 250)
        let withLine = try render(scene: linked(), size: size)
        let without = try render(scene: twoCards(), size: size)

        // The segment runs (100, 20) → (540, 60); this window straddles its
        // midpoint and is clear of both cards.
        let midpointBand = CGRect(x: 310, y: 34, width: 20, height: 12)
        XCTAssertGreaterThan(withLine.differingPixels(from: without, in: midpointBand), 0,
                             "no ink appeared at the segment's own midpoint — the "
                             + "line is projected and never drawn")
        XCTAssertGreaterThan(withLine.differingPixels(from: without,
                                                      in: CGRect(origin: .zero, size: size)),
                             100,
                             "a handful of pixels changed over the whole page: that "
                             + "is a speck, not a line four hundred points long")
        XCTAssertEqual(withLine.differingPixels(from: without,
                                                in: CGRect(x: 300, y: 150,
                                                           width: 100, height: 40)),
                       0,
                       "control: pixels changed far from the segment, so the count "
                       + "above is not measuring the whole page shifting")
    }

    /// **Heavier and fully opaque rather than an accent colour.** The canvas
    /// already spends its colour budget on the region ring and the palette wash
    /// (§7.1), and a line is thin enough that weight reads faster than hue.
    @MainActor
    func test_aSelectedLineDrawsHeavierThanAnUnselectedOne() throws {
        let size = CGSize(width: 700, height: 250)
        let none = try render(scene: twoCards(), size: size)
        let plain = try render(scene: linked(), size: size)
        let picked = try render(scene: linked(), size: size, selection: .line(l1))

        // The card-free stretch between the two cards (a ends at x 200, b starts
        // at x 440), so every changed pixel here is line and nothing else.
        let run = CGRect(x: 210, y: 24, width: 220, height: 32)
        let plainInk = plain.differingPixels(from: none, in: run)
        let pickedInk = picked.differingPixels(from: none, in: run)

        XCTAssertGreaterThan(plainInk, 0,
                             "control: the UNSELECTED line is drawn at all — without "
                             + "this, a selected-only line satisfies the comparison "
                             + "below")
        XCTAssertGreaterThan(pickedInk, plainInk,
                             "the selected line inks \(pickedInk) pixels against the "
                             + "unselected line's \(plainInk) — selection is modelled "
                             + "and not drawn, so the writer cannot see which line "
                             + "⌫ is about to take")
    }

    /// **The pass-order assertion, and what binds the draw order to Task 5's
    /// click order.** The thing drawn on top takes the click, so "above the
    /// region" has to mean above the WHOLE region pass — its wash, its chrome
    /// bar and its resize triangle — and not merely above the wash.
    ///
    /// **A `differingPixels > 0` assertion cannot say this**, and that is why
    /// this test is shaped the way it is. Every part of a region is drawn
    /// TRANSLUCENT (the wash at alpha 0.07–0.09, the resize triangle in a 0.30
    /// stroke colour), so a line drawn UNDERNEATH still shows through and still
    /// changes the pixel: the obvious version of this test passes under the
    /// exact defect it names.
    ///
    /// So it asks the question exactly instead. The line is rendered SELECTED,
    /// which is fully opaque, and each sample sits on a pixel row the 3 pt
    /// stroke covers completely. An opaque line drawn above the region composites
    /// to its own colour whatever is beneath — so its pixel over the region must
    /// be BYTE-IDENTICAL to its pixel over bare ground. Drawn beneath, the
    /// region tints it and the two differ. No threshold, and it goes red the
    /// moment the line pass moves after the region loop.
    @MainActor
    func test_theLineDrawsBeneathTheCardsAndAboveEveryPartOfTheRegion() throws {
        let size = CGSize(width: 700, height: 500)
        let s = crossingScene()
        var noRegion = s
        noRegion.removeRegion(regionID)

        // **Every sample is DERIVED from the region's own metrics, not written
        // down.** Hardcoded, a shrunk `chromeHeight` would move the bar out from
        // under the "chrome bar" sample and turn it into a second wash sample —
        // and the test would keep passing under a quietly narrower claim, which
        // the `beside` control cannot see because the wash differs from bare
        // ground too. The preconditions below fail loudly instead, and say to
        // re-derive.
        let chrome = CanvasRegionMetrics.chromeRect(in: regionFrame)
        let corner = CanvasRegionMetrics.resizeHandleRect(in: regionFrame)

        let parts: [(CanvasLineID, CGPoint, CGPoint, String)] = [
            (chromeLine,
             CGPoint(x: regionFrame.midX + 0.5, y: chromeY + 0.5),
             CGPoint(x: regionFrame.midX + 0.5, y: (chrome.minY + chromeY) / 2 + 0.5),
             "chrome bar"),
            (washLine,
             CGPoint(x: regionFrame.minX + 100.5, y: washY + 0.5),
             CGPoint(x: regionFrame.minX + 100.5, y: washY + 10.5),
             "wash"),
            (cornerLine,
             CGPoint(x: corner.maxX - Self.markInset + 0.5, y: cornerY + 0.5),
             CGPoint(x: corner.maxX - Self.markInset + 0.5, y: cornerY - Self.markInset + 0.5),
             "resize triangle")
        ]

        for (line, onTheLine, beside, part) in parts {
            // Each sample must still be in the part it claims, and the control
            // must still be clear of the stroke. Both go stale together whenever
            // a metric moves.
            for point in [onTheLine, beside] {
                XCTAssertTrue(regionFrame.contains(point),
                              "the \(part) sample \(point) has left the region — "
                              + "re-derive it from CanvasRegionMetrics")
                // The `?.` here is inside the PREDICATE, not on the subject: what
                // is asserted nil is `first {}`, which is legitimately nil and is
                // the whole point. An unmeasured node cannot contain the point
                // either, so the chain's own nil is the right answer for it.
                // nil-chain-ok: the optional chain is in the predicate
                XCTAssertNil(s.unorderedNodes.first { $0.frame?.contains(point) == true },
                             "the \(part) sample \(point) has ended up under a card, "
                             + "which draws over the line and would satisfy the "
                             + "equality below for the wrong reason")
                switch part {
                case "chrome bar":
                    XCTAssertTrue(chrome.contains(point),
                                  "the chrome-bar sample \(point) is no longer in the "
                                  + "chrome rect \(chrome) — CanvasRegionMetrics."
                                  + "chromeHeight has moved and this has silently "
                                  + "become a second wash sample")
                case "resize triangle":
                    XCTAssertTrue(corner.contains(point) && point.x + point.y >= corner.minX + corner.maxY,
                                  "the resize sample \(point) is outside the INKED "
                                  + "half of the corner square \(corner) — below the "
                                  + "hypotenuse is where the triangle is, and above "
                                  + "it this is a wash sample wearing the wrong name")
                default:
                    XCTAssertFalse(chrome.contains(point) || corner.contains(point),
                                   "the wash sample \(point) has drifted into the "
                                   + "chrome bar or the resize corner")
                }
            }
            XCTAssertGreaterThan(abs(beside.y - onTheLine.y), CanvasMaterial.selectedLineWidth,
                                 "the \(part) control sits inside the line's own "
                                 + "stroke, so it is not a control at all")

            let over = try render(scene: s, size: size, selection: .line(line))
            let bare = try render(scene: noRegion, size: size, selection: .line(line))

            XCTAssertNotEqual(over.color(at: beside), bare.color(at: beside),
                              "control: the region's \(part) is not being drawn at "
                              + "\(beside) at all, so the equality below would hold "
                              + "over two identical pages")
            XCTAssertEqual(over.color(at: onTheLine), bare.color(at: onTheLine),
                           "the opaque line's own pixel over the region's \(part) is "
                           + "\(over.color(at: onTheLine)) but over bare ground is "
                           + "\(bare.color(at: onTheLine)) — the \(part) is painting "
                           + "over the line, i.e. lines are drawn UNDER part of the "
                           + "region pass. Above the WHOLE region pass is one rule, "
                           + "and Task 5 hit-tests in the same order")
        }

        // …and BENEATH the cards. A line's job is to connect cards, and a line
        // crossing over one reads as damage.
        var noLines = s
        noLines.removeLine(chromeLine)
        noLines.removeLine(washLine)
        noLines.removeLine(cornerLine)
        let withLines = try render(scene: s, size: size)
        let without = try render(scene: noLines, size: size)

        // The wash line runs at y = 250, straight through the middle card at
        // (310, 230)–(370, 270). Sampled well inside it, so the ~1° seeded tilt
        // cannot move an edge into the window.
        XCTAssertEqual(withLines.differingPixels(from: without,
                                                 in: CGRect(x: 322, y: 242,
                                                            width: 36, height: 16)),
                       0,
                       "the line changed pixels INSIDE a card it runs under — lines "
                       + "are drawn over the cards, and every card the writer draws "
                       + "through is cut in half by its own line")
        XCTAssertGreaterThan(withLines.differingPixels(from: without,
                                                       in: CGRect(x: 380, y: 244,
                                                                  width: 30, height: 12)),
                             0,
                             "control: the same line, just past that card's right "
                             + "edge, really does ink — so the zero above is a line "
                             + "passing under a card and not a line that was never "
                             + "drawn")
    }

    /// Dashed, so an in-progress line never reads as one that exists — the same
    /// signal `drawSweep` uses for the same reason.
    @MainActor
    func test_thePendingLineIsDashedAndTheFinishedOneIsNot() throws {
        let size = CGSize(width: 700, height: 400)
        var bare = CanvasScene()
        bare.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 0, y: 180),
                               width: 200, cachedHeight: 40))
        bare.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 440, y: 180),
                               width: 200, cachedHeight: 40))
        var finished = bare
        finished.insertLine(CanvasLine(id: l1, from: a, to: b))

        let blank = try render(scene: bare, size: size)
        let solid = try render(scene: finished, size: size)
        let pending = try render(scene: bare, size: size,
                                 pendingLine: (CGPoint(x: 100, y: 200),
                                               CGPoint(x: 540, y: 200)))

        // A one-pixel row along the segment, in the card-free stretch between the
        // two cards. A solid line inks every column of it; a dash pattern inks
        // some fraction.
        let run = CGRect(x: 210, y: 200, width: 220, height: 1)
        let solidInk = solid.differingPixels(from: blank, in: run)
        let pendingInk = pending.differingPixels(from: blank, in: run)

        XCTAssertGreaterThan(pendingInk, Int(run.width * 0.25),
                             "\(pendingInk) of \(Int(run.width)) columns under the "
                             + "pointer carry ink — that is not a line at all, and a "
                             + "drag that is drawing a line looks exactly like a drag "
                             + "doing nothing")
        XCTAssertGreaterThan(solidInk, Int(run.width * 0.9),
                             "control: the FINISHED line inks \(solidInk) of "
                             + "\(Int(run.width)) columns, so the comparison below is "
                             + "against a genuinely solid line")
        XCTAssertLessThan(pendingInk, Int(run.width * 0.9),
                          "\(pendingInk) of \(Int(run.width)) columns are inked, i.e. "
                          + "the pending line is SOLID — which is what a line looks "
                          + "like once it exists, so the writer is shown a line that "
                          + "is not there yet")
    }

    /// **The connect mark is drawn on the SELECTED card**, and that is the
    /// discoverable half of the gesture — ⇧-drag has no chrome and nobody
    /// explores by holding a modifier.
    ///
    /// The positive half is what catches the permanent-chrome defect, and it is
    /// worth saying which way round: a mark drawn on every card would be in BOTH
    /// renders, so selecting the card would change nothing in its own handle rect
    /// and the `> 0` below goes red. The `== 0` on the other card catches the
    /// remaining shape — selecting one card marking them all.
    ///
    /// The sampled window stops 6 pt short of the card's right edge, clear of the
    /// 2 pt selection stroke and of the ~1.8 pt the seeded tilt swings that edge
    /// by; otherwise the stroke alone would satisfy the assertion.
    @MainActor
    func test_theConnectMarkIsDrawnOnlyOnTheSelectedCard() throws {
        let size = CGSize(width: 700, height: 250)
        let s = twoCards()
        let unselected = try render(scene: s, size: size)
        let selected = try render(scene: s, size: size, selection: .node(a))

        let cardA = try XCTUnwrap(s.node(a)?.frame)
        let cardB = try XCTUnwrap(s.node(b)?.frame)
        let handleA = CanvasRenderer.connectHandleRect(inCard: cardA)
        let inkOnly = CGRect(x: handleA.minX, y: handleA.minY + 2,
                             width: handleA.width - 6, height: handleA.height - 4)

        XCTAssertGreaterThan(selected.differingPixels(from: unselected, in: inkOnly), 0,
                             "selecting a card draws no connect mark on it — either "
                             + "the mark is never drawn, or it is permanent chrome on "
                             + "every card and so was already there before the click")
        XCTAssertEqual(selected.differingPixels(from: unselected,
                                                in: CanvasRenderer.connectHandleRect(inCard: cardB)),
                       0,
                       "selecting one card put a connect mark on the other one too")
    }

    // MARK: - The crossing fixture

    private let regionID = CanvasRegionID("r1")
    private let chromeLine = CanvasLineID("chrome")
    private let washLine = CanvasLineID("wash")
    private let cornerLine = CanvasLineID("corner")

    private let regionFrame = CGRect(x: 100, y: 100, width: 400, height: 300)

    /// How far inside the corner square the resize sample sits. Small enough to
    /// stay below the hypotenuse — the triangle is the inked half — and the
    /// precondition in the test says so if this ever stops being true.
    private static let markInset: CGFloat = 4

    /// **The three line heights, DERIVED from the region's own metrics.** They
    /// have to move with `chromeHeight` and `resizeHandleSide`, or the samples
    /// taken at them stop being samples of the parts they are named for.
    private var chromeY: CGFloat { CanvasRegionMetrics.chromeRect(in: regionFrame).midY }
    private var washY: CGFloat { regionFrame.midY }
    private var cornerY: CGFloat {
        CanvasRegionMetrics.resizeHandleRect(in: regionFrame).maxY - Self.markInset
    }

    /// A region at (100, 100)–(500, 400) and three horizontal lines crossing it
    /// at the heights of its three drawn parts, each strung between a pair of
    /// cards parked outside the region on either side.
    ///
    /// Horizontal on purpose: a 3 pt stroke on an exact integer y covers whole
    /// pixel rows, which is what lets the assertions above compare bytes rather
    /// than tolerances. One more card sits astride the middle line, for the
    /// beneath-the-cards half.
    private func crossingScene() -> CanvasScene {
        var s = CanvasScene()
        s.insertRegion(CanvasRegion(id: regionID, label: "Act II fog", frame: regionFrame))

        func card(_ id: CanvasNodeID, centre: CGPoint) {
            s.insert(CanvasNode(id: id, kind: .scrap,
                                origin: CGPoint(x: centre.x - 30, y: centre.y - 20),
                                width: 60, cachedHeight: 40))
        }
        let ends: [(CanvasLineID, CGFloat)] = [(chromeLine, chromeY), (washLine, washY),
                                               (cornerLine, cornerY)]
        for (line, y) in ends {
            let left = CanvasNodeID("\(line.raw)L"), right = CanvasNodeID("\(line.raw)R")
            card(left, centre: CGPoint(x: 60, y: y))
            card(right, centre: CGPoint(x: 560, y: y))
            s.insertLine(CanvasLine(id: line, from: left, to: right))
        }
        card(CanvasNodeID("middle"), centre: CGPoint(x: 340, y: washY))
        return s
    }

    // The rasterisation harness — `CanvasPage` and `render(scene:size:…)`
    // — lives in `CanvasRasterPage.swift`, shared with the region fixtures.
}
