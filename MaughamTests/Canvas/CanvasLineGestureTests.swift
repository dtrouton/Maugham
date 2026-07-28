import XCTest
import AppKit
@testable import Maugham

/// Drawing a line: the two routes into it, and what the gesture does once it is
/// under way.
///
/// Fixture as `CanvasLineTests`: `a` at (0,0,240,80) → centre (120,40), `b` at
/// (400,0,240,80) → centre (520,40). A point inside `a` is (10,10) and inside
/// `b` is (410,10).
///
/// The two routes — ⇧-drag from any card, and a drag out of the connect mark on
/// the *selected* card — resolve to one `Bool` in `CanvasView` before
/// `CanvasInteraction` sees anything, so everything below the decision is tested
/// once. What is tested twice is the DECISION, which is the only place the fast
/// route and the discoverable one could come apart.
final class CanvasLineGestureTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")

    private func node(_ id: CanvasNodeID, x: CGFloat, y: CGFloat,
                      width: CGFloat = 240, height: CGFloat = 80,
                      z: Int = 0) -> CanvasNode {
        CanvasNode(id: id, kind: .scrap, origin: CGPoint(x: x, y: y),
                   width: width, cachedHeight: height, z: z)
    }

    private func twoCards() -> CanvasScene {
        var scene = CanvasScene()
        scene.insert(node(a, x: 0, y: 0))
        scene.insert(node(b, x: 400, y: 0))
        return scene
    }

    private let insideA = CGPoint(x: 10, y: 10)
    private let insideB = CGPoint(x: 410, y: 10)

    /// Inside `a`'s connect target: `connectHandleRect` for (0,0,240,80) is
    /// (226,33,14,14). Computed here rather than hard-coded so a change to
    /// `connectHandleSize` moves the test with the surface.
    private var insideAsConnectHandle: CGPoint {
        let rect = CanvasRenderer.connectHandleRect(inCard: CGRect(x: 0, y: 0, width: 240, height: 80))
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: - The gesture, on `CanvasInteraction`

    func test_aConnectingDragFromOneCardToAnotherCreatesALine() throws {
        var scene = twoCards()
        var i = CanvasInteraction()

        i.begin(at: insideA, in: scene, connecting: true)
        XCTAssertEqual(i.kind, .drawingLine,
                       "a connecting press on a card must open a line gesture, not a move")
        i.update(to: CGPoint(x: 200, y: 40), in: &scene)
        let id = i.endLine(at: insideB, in: &scene)

        XCTAssertNotNil(id, "the drag ended over a second card, which is a line")
        XCTAssertEqual(scene.lines.count, 1)
        let line = try XCTUnwrap(scene.lines.first)
        XCTAssertEqual(line.from, a)
        XCTAssertEqual(line.to, b)
        XCTAssertNil(line.label,
                     "a new line asserts nothing until the writer says so — spec §5's "
                     + "untyped edge, and a default label would be a vocabulary")
    }

    func test_aConnectingDragOnACardsResizeCornerDrawsALineRatherThanResizing() {
        var scene = twoCards()
        var i = CanvasInteraction()
        // Inside `a`'s bottom-right resize square: the card is (0,0)–(240,80) and
        // the target is the whole `resizeHandleSize` corner.
        let corner = CGPoint(x: 240 - 2, y: 80 - 2)

        var control = CanvasInteraction()
        control.begin(at: corner, in: scene, connecting: false)
        XCTAssertTrue(control.isResizing,
                      "precondition: that point really is the resize corner, so the "
                      + "assertion below is about the modifier and not about the point")

        i.begin(at: corner, in: scene, connecting: true)
        XCTAssertEqual(i.kind, .drawingLine)
        XCTAssertFalse(i.isResizing,
                       "the writer holding ⇧ has already said which gesture they mean; "
                       + "the corner must not win over it")
        i.update(to: CGPoint(x: 300, y: 40), in: &scene)
        XCTAssertEqual(scene.node(a)?.width, 240,
                       "a line drag off the corner must not have resized the card")
    }

    func test_anUnmodifiedDragOnACardStillMovesIt() {
        var scene = twoCards()
        var i = CanvasInteraction()

        i.begin(at: insideA, in: scene, connecting: false)
        XCTAssertEqual(i.kind, .movingNode)
        i.update(to: CGPoint(x: 60, y: 60), in: &scene)

        XCTAssertEqual(scene.node(a)?.origin, CGPoint(x: 50, y: 50),
                       "without this control, \"connecting draws a line\" is satisfied "
                       + "by a build where every drag draws one")
        XCTAssertTrue(scene.lines.isEmpty)
    }

    func test_aConnectingDragOnBareCanvasStillSweepsARegion() {
        var scene = twoCards()
        var i = CanvasInteraction()
        // Well clear of both cards.
        i.begin(at: CGPoint(x: 100, y: 400), in: scene, connecting: true)

        XCTAssertEqual(i.kind, .drawingRegion,
                       "there is no marquee select on this surface (§9), so ⇧ is not "
                       + "overloaded and a ⇧-drag on nothing is still a sweep")
        i.update(to: CGPoint(x: 400, y: 700), in: &scene)
        XCTAssertEqual(i.pendingRegionDraw, CGRect(x: 100, y: 400, width: 300, height: 300))
        XCTAssertNil(i.pendingLine)
    }

    func test_thePendingLineAnchorsAtTheSourceCentreAndFollowsThePointer() {
        var scene = twoCards()
        var i = CanvasInteraction()

        i.begin(at: insideA, in: scene, connecting: true)
        XCTAssertEqual(i.pendingLine?.from, CGPoint(x: 120, y: 40),
                       "the band must anchor at the source card's CENTRE and not at the "
                       + "press point, or the finished line jumps the instant it exists")
        XCTAssertEqual(i.pendingLine?.to, insideA)

        i.update(to: CGPoint(x: 300, y: 200), in: &scene)
        XCTAssertEqual(i.pendingLine?.from, CGPoint(x: 120, y: 40))
        XCTAssertEqual(i.pendingLine?.to, CGPoint(x: 300, y: 200),
                       "the free end follows the pointer")
    }

    func test_thePendingLineIsClearedWhenTheDragEnds() {
        var scene = twoCards()
        var i = CanvasInteraction()

        i.begin(at: insideA, in: scene, connecting: true)
        i.update(to: CGPoint(x: 300, y: 40), in: &scene)
        XCTAssertNotNil(i.pendingLine, "precondition: there was a band to clear")

        _ = i.endLine(at: insideB, in: &scene)
        XCTAssertNil(i.pendingLine,
                     "a band left behind draws a dashed line from the card to wherever "
                     + "the pointer last was, for the rest of the session")
        XCTAssertNil(i.kind)
    }

    func test_aDragEndingOnEmptyCanvasCreatesNothing() {
        var scene = twoCards()
        var i = CanvasInteraction()

        i.begin(at: insideA, in: scene, connecting: true)
        i.update(to: CGPoint(x: 300, y: 400), in: &scene)
        let id = i.endLine(at: CGPoint(x: 300, y: 400), in: &scene)

        XCTAssertNil(id, "a line needs two ends; a dangling one is not a thought")
        XCTAssertTrue(scene.lines.isEmpty)
        XCTAssertNil(i.pendingLine)
    }

    func test_aDragEndingOnTheSourceCardCreatesNothing() {
        var scene = twoCards()
        var i = CanvasInteraction()

        i.begin(at: insideA, in: scene, connecting: true)
        i.update(to: CGPoint(x: 300, y: 40), in: &scene)
        let id = i.endLine(at: CGPoint(x: 30, y: 30), in: &scene)

        XCTAssertNil(id, "a line from a card to itself has nothing to say and draws as a blob")
        XCTAssertTrue(scene.lines.isEmpty)
    }

    func test_endLineWithoutBeginningOneDoesNothing() {
        var scene = twoCards()
        var i = CanvasInteraction()

        XCTAssertNil(i.endLine(at: insideB, in: &scene))

        // And not merely because nothing was under the point: a live MOVE must
        // not be closed as a line either.
        i.begin(at: insideA, in: scene, connecting: false)
        i.update(to: CGPoint(x: 60, y: 60), in: &scene)
        XCTAssertNil(i.endLine(at: insideB, in: &scene),
                     "only a line gesture closes as a line")
        XCTAssertTrue(scene.lines.isEmpty)
    }

    /// **What this can see, and what it cannot.** It fails if `begin` opens a
    /// move instead of a line, and if any arm of `update` touches the scene for a
    /// line drag. It does NOT fail if the `.drawingLine` arm is emptied to a
    /// `break` — the card stays put either way, and the band silently stops
    /// following the pointer. That half is
    /// `test_thePendingLineAnchorsAtTheSourceCentreAndFollowsThePointer`, and the
    /// two are only a pair together.
    func test_aLineDragNeverMovesTheSourceCard() {
        var scene = twoCards()
        var i = CanvasInteraction()
        let before = scene.node(a)?.origin

        i.begin(at: insideA, in: scene, connecting: true)
        for x in stride(from: CGFloat(20), through: 400, by: 20) {
            i.update(to: CGPoint(x: x, y: 40), in: &scene)
        }
        _ = i.endLine(at: insideB, in: &scene)

        XCTAssertEqual(scene.node(a)?.origin, before,
                       "the source card stays where it is for the whole drag: a line "
                       + "drag reads its position and changes nothing about it")
        XCTAssertEqual(scene.node(b)?.origin, CGPoint(x: 400, y: 0))
    }

    /// A line drag reports no flick, so a card can never be thrown by one.
    func test_aLineDragThrowsNothing() {
        var scene = twoCards()
        var i = CanvasInteraction()

        i.begin(at: insideA, in: scene, connecting: true)
        i.update(to: CGPoint(x: 200, y: 40), in: &scene, now: 100)
        i.update(to: CGPoint(x: 380, y: 40), in: &scene, now: 100.01)
        XCTAssertNil(i.end(now: 100.02),
                     "`end`'s flick detection is `guard case .moving`, and that is what "
                     + "guarantees a line drag never sends the source card skating")
    }

    /// **This cannot exercise the uniqueness LOOP and does not claim to.** Eight
    /// hex characters over fifty draws collide with vanishing probability, and
    /// there is no seam to force one through. What it does catch is the mutation
    /// that matters in practice — an id that is constant, empty, or reused from
    /// something already in the scene — and it inserts each id it mints so the
    /// scene it asks about is really growing.
    func test_newLineIDsDoNotCollideWithExistingOnes() {
        var scene = twoCards()
        var minted: Set<String> = []
        for _ in 0..<50 {
            let id = CanvasInteraction.newLineID(in: scene)
            XCTAssertNil(scene.line(id), "a minted id must not already be in the scene")
            XCTAssertTrue(minted.insert(id.raw).inserted,
                          "and it must not repeat one this loop already inserted")
            scene.insertLine(CanvasLine(id: id, from: a, to: b))
        }
        XCTAssertEqual(scene.lines.count, 50)
    }

    // MARK: - The route decision, on `CanvasView`

    func test_aPressInsideTheSelectedCardsConnectHandleConnects() {
        let scene = twoCards()
        XCTAssertTrue(CanvasView.pressStartsALine(at: insideAsConnectHandle,
                                                  selection: .node(a),
                                                  in: scene, shiftHeld: false),
                      "the mark is drawn on the selected card, so a drag out of it is "
                      + "the discoverable route into a line")
    }

    func test_theSamePointOnAnUnselectedCardDoesNot() {
        let scene = twoCards()
        XCTAssertFalse(CanvasView.pressStartsALine(at: insideAsConnectHandle,
                                                   selection: .node(b),
                                                   in: scene, shiftHeld: false),
                       "no mark was drawn there, so the writer aimed at nothing — and "
                       + "`applyMouseDown` fires onClick before onDrag(.began), so the "
                       + "press that selects a card must not also start a line from it")
        XCTAssertFalse(CanvasView.pressStartsALine(at: insideAsConnectHandle,
                                                   selection: nil,
                                                   in: scene, shiftHeld: false))
    }

    func test_theSamePointOnTheSelectedCardWithARegionSelectedInsteadDoesNot() {
        var scene = twoCards()
        let region = CanvasRegionID("r1")
        scene.insertRegion(CanvasRegion(id: region, label: "Act II",
                                        frame: CGRect(x: -100, y: -100, width: 900, height: 400)))
        XCTAssertFalse(CanvasView.pressStartsALine(at: insideAsConnectHandle,
                                                   selection: .region(region),
                                                   in: scene, shiftHeld: false),
                       "a card with no mark on it has no connect target, whatever else "
                       + "on the canvas is selected")
    }

    func test_aPressOutsideTheHandleOnTheSelectedCardStillMovesIt() {
        let scene = twoCards()
        XCTAssertFalse(CanvasView.pressStartsALine(at: insideA, selection: .node(a),
                                                   in: scene, shiftHeld: false),
                       "the target is the mark, not the card — otherwise selecting a "
                       + "card would make it undraggable")
    }

    func test_shiftConnectsFromAnyCardSelectedOrNot() {
        let scene = twoCards()
        for selection: CanvasSelection? in [nil, .node(a), .node(b),
                                            .region(CanvasRegionID("nope"))] {
            XCTAssertTrue(CanvasView.pressStartsALine(at: insideA, selection: selection,
                                                      in: scene, shiftHeld: true),
                          "⇧ is the fast route and owes nothing to the selection; the "
                          + "two routes are independent and neither is a special case "
                          + "of the other")
        }
    }

    /// The handle is empty on a card too short to hold it above the resize corner
    /// — `connectHandleRect` returns `.null` there, and `CGRect.null.contains(_)`
    /// is false. Asserted rather than assumed: the hit test rests on it.
    func test_aCardTooShortForTheMarkHasNoConnectTarget() throws {
        var scene = CanvasScene()
        let short = CanvasNodeID("sh")
        scene.insert(node(short, x: 0, y: 0, height: 20))
        let frame = try XCTUnwrap(scene.node(short)?.frame)
        XCTAssertTrue(CanvasRenderer.connectHandleRect(inCard: frame).isNull,
                      "precondition: this card is too short for both marks, so the "
                      + "corner belongs to resize")

        let atTheRightEdge = CGPoint(x: 233, y: 10)
        XCTAssertNotNil(scene.topmostNode(at: atTheRightEdge),
                        "precondition: the point is on the card, so a false below is "
                        + "about the absent handle and not about missing the card")
        XCTAssertFalse(CanvasView.pressStartsALine(at: atTheRightEdge, selection: .node(short),
                                                   in: scene, shiftHeld: false))
        XCTAssertTrue(CanvasView.pressStartsALine(at: atTheRightEdge, selection: .node(short),
                                                  in: scene, shiftHeld: true),
                      "⇧ still works on a card with no mark — which is why the mark may "
                      + "be absent at all")
    }

    /// A card drawn IN FRONT of the selected card's mark takes the press. The
    /// mark is hidden under it, so the writer cannot have aimed at it — and
    /// `begin` resolves the source with `topmostNode(at:)`, so treating it as a
    /// connection would draw a line from a card the writer never pointed at.
    func test_aCardCoveringTheSelectedCardsMarkTakesThePress() {
        var scene = twoCards()
        let cover = CanvasNodeID("cv")
        scene.insert(node(cover, x: 200, y: 20, width: 120, height: 60, z: 5))
        XCTAssertEqual(scene.topmostNode(at: insideAsConnectHandle)?.id, cover,
                       "precondition: the covering card really is in front at that point")

        XCTAssertFalse(CanvasView.pressStartsALine(at: insideAsConnectHandle,
                                                   selection: .node(a),
                                                   in: scene, shiftHeld: false))
    }

    // MARK: - Selecting a line

    private let l1 = CanvasLineID("l1")

    /// The two fixture cards with a line between them: `a`'s centre (120,40) to
    /// `b`'s centre (520,40), so the segment runs along y = 40 between x = 120
    /// and x = 520. The gap between the cards is x ∈ (240, 400), which is the
    /// only stretch of it that is not under a card.
    private func linkedCards() -> CanvasScene {
        var scene = twoCards()
        scene.insertLine(CanvasLine(id: l1, from: a, to: b))
        return scene
    }

    /// On the line, in the gap between the two cards.
    private let onTheLineBetweenTheCards = CGPoint(x: 320, y: 40)

    func test_clickingALineSelectsIt() {
        XCTAssertEqual(linkedCards().selectionTarget(at: onTheLineBetweenTheCards),
                       .line(l1),
                       "a click on a line does not select it, so nothing the writer "
                       + "can see reaches ⌫ or the inspector")
    }

    /// The control the one above needs: bare canvas still selects nothing, so
    /// "the line is selected" is not satisfied by a build that answers `.line`
    /// for every point on the surface.
    ///
    /// Named for what it checks — the ROUTING function's answer on bare ground.
    /// The assignment that actually clears `model.selection` is covered through
    /// the real click path in
    /// `CanvasViewMountingTests.test_aSingleClickSelectsTheThingUnderIt`.
    func test_aClickOnBareCanvasResolvesToNothing() {
        let scene = linkedCards()
        // Same x, well clear of the 6 pt tolerance around y = 40.
        let bare = CGPoint(x: 320, y: 300)
        XCTAssertNil(scene.selectionTarget(at: bare),
                     "a click on bare ground away from every line still resolved to "
                     + "something — the accent stays on a thing the writer has "
                     + "clicked away from, and ⌫ is still pointed at it")
        XCTAssertEqual(scene.selectionTarget(at: onTheLineBetweenTheCards),
                       .line(l1),
                       "control: this scene does answer `.line` a few hundred points "
                       + "away, so the nil above is the bare ground and not a hit "
                       + "test that never finds anything")
    }

    /// **Drawing and hit testing take ONE rule about a collapsed region.**
    /// `CanvasScene.drawnLines` skips a line to a hidden node, so the line
    /// is not on screen — and a target the writer cannot see is a click they
    /// cannot explain.
    ///
    /// Expanding the region again is the control: without it "not clickable"
    /// is satisfied by a build where that line is never clickable at all.
    func test_aLineToAResidentOfACollapsedRegionIsNotClickable() {
        var scene = linkedCards()
        let region = CanvasRegionID("r1")
        scene.insertRegion(CanvasRegion(id: region, label: "Act II fog",
                                        frame: CGRect(x: 380, y: -40, width: 300, height: 200),
                                        homeMembers: [b], isCollapsed: true))
        XCTAssertTrue(scene.isHidden(b),
                      "precondition: `b` is a resident of a collapsed region, so it "
                      + "is not drawn and neither is the line to it")
        XCTAssertTrue(scene.drawnLines.isEmpty,
                      "precondition: the renderer is not drawing this line, so the "
                      + "assertion below is about hit testing agreeing with it")

        XCTAssertNil(scene.selectionTarget(at: onTheLineBetweenTheCards),
                     "a line running to a card inside a collapsed region is still "
                     + "clickable: the writer selects — and can then ⌫ — a line that "
                     + "is nowhere on the screen")

        scene.updateRegion(region) { $0.isCollapsed = false }
        XCTAssertEqual(scene.selectionTarget(at: onTheLineBetweenTheCards),
                       .line(l1),
                       "control: expanding the region must bring the line back under "
                       + "the pointer, or \"not clickable while collapsed\" is "
                       + "satisfied by a line that can never be clicked")
    }

    // MARK: - The click order is the draw order read backwards

    /// **A card beats a line running under it**, and it is first in the order
    /// for the same reason it is drawn last: the writer is pointing at the card.
    /// It also keeps the click and the DRAG agreeing — `CanvasInteraction.begin`
    /// resolves a press over a card as a move, so a click that resolved to the
    /// line would select one thing and drag another.
    func test_aClickOnACardBeatsALineRunningUnderIt() {
        var scene = twoCards()
        // A third card parked ON the segment, between the two it joins.
        let over = CanvasNodeID("ov")
        scene.insert(node(over, x: 280, y: 20, width: 80, height: 40, z: 5))
        scene.insertLine(CanvasLine(id: l1, from: a, to: b))
        let point = CGPoint(x: 320, y: 40)
        XCTAssertEqual(scene.topmostNode(at: point)?.id, over,
                       "precondition: the point is on the covering card")
        XCTAssertEqual(CanvasLineHit.line(at: point, in: scene), l1,
                       "precondition: and the line really does run under it, so the "
                       + "assertion below is a precedence and not an absent line")

        XCTAssertEqual(scene.selectionTarget(at: point), .node(over),
                       "the line under a card took the click: the writer aims at a "
                       + "card, gets a line, and the drag they start moves the card "
                       + "they thought they had selected")
    }

    /// **The reversal.** Task 3 draws lines above the WHOLE region pass, chrome
    /// bar included, so the line takes the click there. An earlier draft gave the
    /// bar priority — on the true ground that it is a region's only grab handle
    /// — which left the line drawn on top of the thing that was taking its
    /// clicks.
    func test_aClickOnALineCrossingARegionsChromeBarSelectsTheLine() {
        let scene = lineAcrossAChromeBar()
        XCTAssertEqual(CanvasInteraction.regionHit(at: onTheChromeBar, in: scene),
                       .chrome(chromeRegion),
                       "precondition: this point really is on the region's chrome bar")
        XCTAssertEqual(CanvasLineHit.line(at: onTheChromeBar, in: scene), l1,
                       "precondition: and the line really does cross it there")

        XCTAssertEqual(scene.selectionTarget(at: onTheChromeBar), .line(l1),
                       "the chrome bar took a click on a line drawn over it — hit "
                       + "testing disagreeing with what is visibly frontmost, which "
                       + "is the one thing the draw-order rule exists to prevent")
    }

    /// **The control the reversal needs.** Without it, "the line wins" is
    /// satisfied by a build where a region with a line anywhere near it can no
    /// longer be picked up at all — and the bar is the only handle a region has.
    func test_aClickOnTheSameChromeBarAwayFromTheLineStillSelectsTheRegion() {
        let scene = lineAcrossAChromeBar()
        // Same bar, far along it from the crossing.
        let along = CGPoint(x: onTheChromeBar.x + 200, y: onTheChromeBar.y)
        XCTAssertNil(CanvasLineHit.line(at: along, in: scene),
                     "precondition: this end of the bar is clear of the line")
        XCTAssertEqual(scene.selectionTarget(at: along), .region(chromeRegion),
                       "a region whose bar a line happens to cross can no longer be "
                       + "grabbed at all — the line costs the bar 12 pt of a width in "
                       + "the hundreds, not the whole of it")
    }

    /// **The drag agrees with the click, or the writer selects one thing and
    /// moves another.**
    ///
    /// `CanvasInteraction.begin` had no line branch, so a press where a line
    /// crosses a region's chrome bar opened `.movingRegion` while the click
    /// selected the line. A line is not draggable, so idle is the honest answer
    /// — the same one a press on a region's INTERIOR already gets.
    ///
    /// Three presses, one sequence, and each asserts a different mode: an
    /// implementation that was always idle fails the control, and one that never
    /// is fails the first two.
    func test_aPressOnALineDragsNothing() {
        let scene = lineAcrossAChromeBar()
        var i = CanvasInteraction()

        i.begin(at: onTheChromeBar, in: scene, connecting: false)
        XCTAssertFalse(i.isActive,
                       "a press where the line crosses the bar opened \(String(describing: i.kind)) "
                       + "— the click selects the line there, so this drag moves the "
                       + "region under a line the writer is holding")

        // ⇧ changes nothing: a connecting press on a line is still a press on a
        // line, and `begin` only opens a line gesture from a NODE.
        i.begin(at: onTheChromeBar, in: scene, connecting: true)
        XCTAssertFalse(i.isActive)

        // The control, on the same bar, clear of the line.
        i.begin(at: CGPoint(x: onTheChromeBar.x + 200, y: onTheChromeBar.y),
                in: scene, connecting: false)
        XCTAssertEqual(i.kind, .movingRegion,
                       "the bar is a region's only grab handle and it must still work "
                       + "everywhere the line is not")
    }

    /// **The two orders, asserted against each other rather than each against a
    /// literal.** Change one without the other and this goes red, which is what
    /// would have caught the earlier draft's shape.
    ///
    /// Neither order is written down here. The CLICK order is read out of
    /// `selectionTarget` by peeling: ask it, remove whatever won, ask again. The
    /// DRAW order is read out of `CanvasRenderer.draw` by rasterising: at a point
    /// all three layers cover, the topmost is the one whose render ALONE is
    /// byte-identical to the render of everything still standing — because each
    /// of the three is opaque at the sample. Peel it and go again.
    ///
    /// The endpoint cards sit far from the sample and stay in every scene, so
    /// removing "the card layer" cannot take the line away with it.
    ///
    /// **Measured 2026-07-28, both mutations:** move the line pass above the
    /// region pass in `CanvasRenderer.draw` and the peel goes red inside the
    /// draw reading (a translucent region over an opaque line leaves nothing
    /// accounting for the pixel, so there is no order to read); put the region
    /// hit above the line hit in `selectionTarget` and the two orders come back
    /// different. Either way the message names the layer, which is what a
    /// bisecting reader needs.
    @MainActor
    func test_theClickOrderIsTheDrawOrderReadBackwards() throws {
        let scene = allThreeLayers()
        let point = coincidentPoint

        // Every layer really is under the point — without this the two orders
        // could agree by both being short.
        XCTAssertEqual(scene.topmostNode(at: point)?.id, coveringCard)
        XCTAssertEqual(CanvasLineHit.line(at: point, in: scene), l1)
        XCTAssertEqual(CanvasInteraction.regionHit(at: point, in: scene), .chrome(chromeRegion))

        var clickOrder: [Layer] = []
        var remaining = Layer.allCases
        while !remaining.isEmpty {
            let answer = keeping(remaining).selectionTarget(at: point)
            let winner = try XCTUnwrap(
                Layer.allCases.first { $0.matches(answer) },
                "with \(remaining) still on the canvas, a click at \(point) resolved "
                + "to \(String(describing: answer)) — which is none of them")
            clickOrder.append(winner)
            remaining.removeAll { $0 == winner }
        }

        var drawOrder: [Layer] = []
        remaining = Layer.allCases
        while remaining.count > 1 {
            let all = try renderLayers(remaining).color(at: point)
            var top: [Layer] = []
            for layer in remaining {
                if try renderLayers([layer]).color(at: point) == all { top.append(layer) }
            }
            let topLayer = try XCTUnwrap(
                top.first,
                "with \(remaining) drawn, NONE of them accounts for the pixel at "
                + "\(point) on its own. The likeliest cause is the one this test "
                + "exists for: a translucent layer has moved ON TOP of an opaque "
                + "one, i.e. the draw order changed. (The other cause is a fixture "
                + "whose frontmost layer stopped being opaque at the sample.)")
            XCTAssertEqual(top.count, 1,
                           "with \(remaining) drawn, \(top) EACH account for the "
                           + "pixel at \(point) on their own — two layers cannot both "
                           + "be frontmost, so this fixture can no longer read a "
                           + "draw order")
            drawOrder.append(topLayer)
            remaining.removeAll { $0 == topLayer }
        }
        drawOrder.append(try XCTUnwrap(remaining.first))

        XCTAssertEqual(clickOrder, drawOrder,
                       "the click order is \(clickOrder) and the draw order is "
                       + "\(drawOrder), both front to back. They are one rule — the "
                       + "thing drawn on top takes the click — so a change to either "
                       + "is a change to both, and whoever re-opens this has to "
                       + "propose the package whole")
        // …and the rule is the interesting order rather than any order at all.
        XCTAssertEqual(clickOrder, [.card, .line, .region],
                       "both orders moved together, which is what the assertion above "
                       + "guarantees — but they moved AWAY from card-over-line-over-"
                       + "region, and this canvas has one stated front-to-back order")
    }

    // MARK: - The three-layer fixture

    /// The three drawn layers that can meet under one point. Front to back is
    /// the answer under test, so the case order here is deliberately alphabetical
    /// and says nothing.
    private enum Layer: String, CaseIterable, CustomStringConvertible {
        case card, line, region
        var description: String { rawValue }

        func matches(_ selection: CanvasSelection?) -> Bool {
            switch (self, selection) {
            case (.card, .node), (.line, .line), (.region, .region): return true
            default: return false
            }
        }
    }

    private let chromeRegion = CanvasRegionID("cr")
    private let coveringCard = CanvasNodeID("ov")

    /// A region at (200,0)–(700,300); its chrome bar is the top 24 pt.
    private var chromeFrame: CGRect { CGRect(x: 200, y: 0, width: 500, height: 300) }

    /// Where the line crosses the chrome bar.
    ///
    /// The y is DERIVED from `CanvasRegionMetrics` rather than written down: a
    /// shrunk `chromeHeight` has to move this sample rather than silently turn it
    /// into a sample of the wash, where there is nothing to lose a click to.
    private var onTheChromeBar: CGPoint {
        CGPoint(x: 400, y: CanvasRegionMetrics.chromeRect(in: chromeFrame).midY)
    }

    private var coincidentPoint: CGPoint { onTheChromeBar }

    /// A line CROSSING a region's chrome bar — the near-perpendicular crossing
    /// the rule is argued about. Its two cards sit well above and well below the
    /// region, so the segment is vertical at x = 400 and meets the bar at one
    /// place only. That is what lets a second sample further along the same bar
    /// be a real control rather than a second point on the line.
    private func lineAcrossAChromeBar() -> CanvasScene {
        var scene = CanvasScene()
        let x = onTheChromeBar.x
        scene.insert(node(a, x: x - 50, y: -220, width: 100, height: 40))
        scene.insert(node(b, x: x - 50, y: 380, width: 100, height: 40))
        scene.insertLine(CanvasLine(id: l1, from: a, to: b))
        scene.insertRegion(CanvasRegion(id: chromeRegion, label: "Act II fog", frame: chromeFrame))
        return scene
    }

    /// `lineAcrossAChromeBar` plus a card sitting over the crossing, so a card,
    /// a line and a region's chrome bar all cover `coincidentPoint`.
    ///
    /// The card is centred exactly on the sample, so the seeded tilt turns it
    /// about that point and cannot move it out from under either the hit test
    /// (which is on the unrotated rect) or the raster reader.
    private func allThreeLayers() -> CanvasScene {
        var scene = lineAcrossAChromeBar()
        scene.insert(node(coveringCard, x: coincidentPoint.x - 40, y: coincidentPoint.y - 6,
                          width: 80, height: 12, z: 5))
        return scene
    }

    /// The same scene with only `layers` left standing. The line's two endpoint
    /// cards are not part of the card LAYER — they are 300 pt away from the
    /// sample and stay put, or removing the card layer would take the line with
    /// them and the peel would read an order the surface does not have.
    private func keeping(_ layers: [Layer]) -> CanvasScene {
        var scene = allThreeLayers()
        if !layers.contains(.card) { scene.remove(coveringCard) }
        if !layers.contains(.line) { scene.removeLine(l1) }
        if !layers.contains(.region) { scene.removeRegion(chromeRegion) }
        return scene
    }

    /// Rasterise `keeping(layers)`.
    ///
    /// The line is rendered SELECTED because that stroke is fully opaque, which
    /// is what lets the peel above compare bytes: an opaque layer's own pixel is
    /// its own colour whatever is beneath it. The backing is deliberately NOT the
    /// card paper the harness defaults to — a card drawn on a page of its own
    /// colour is invisible, and the peel would read the card as absent.
    @MainActor
    private func renderLayers(_ layers: [Layer]) throws -> CanvasPage {
        try render(scene: keeping(layers), size: CGSize(width: 800, height: 400),
                   selection: .line(l1), backing: .black)
    }

    // MARK: - A stale line selection

    /// `CanvasModel.clearSelectionIfItNoLongerResolves`' `.line` arm, which
    /// nothing else can see: a snapshot carries the SCENE and not the selection,
    /// so an undo that takes back a line otherwise leaves the inspector and ⌫
    /// holding a dangling id.
    ///
    /// The control is the second half: an undo that cleared the selection
    /// unconditionally would satisfy the first and deselect the writer's line on
    /// every unrelated ⌘Z.
    func test_undoingBackPastALineClearsAStaleLineSelection() {
        let model = CanvasModel()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-line-select-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        model.attach(projectRoot: root)
        model.withScene { s in
            s.insert(self.node(self.a, x: 0, y: 0))
            s.insert(self.node(self.b, x: 400, y: 0))
        }

        model.mutate("Draw Line") { $0.insertLine(CanvasLine(id: self.l1, from: self.a, to: self.b)) }
        model.selection = .line(l1)
        XCTAssertNotNil(model.selectedLine, "precondition: it resolves")

        model.undo.undo()
        XCTAssertNil(model.scene.line(l1), "precondition: the undo took the line back")
        XCTAssertNil(model.selection,
                     "the selection still names a line that is no longer in the "
                     + "scene — `selectedLine` resolves to nil and both the inspector "
                     + "and ⌫ are left holding a dangling id")

        // The control: a line selection that STILL resolves survives an undo.
        model.mutate("Draw Line") { $0.insertLine(CanvasLine(id: self.l1, from: self.a, to: self.b)) }
        model.selection = .line(l1)
        model.mutate("Move Scrap") { $0.move(self.a, to: CGPoint(x: 10, y: 10)) }
        model.undo.undo()
        XCTAssertEqual(model.selection, .line(l1),
                       "an undo that had nothing to do with the selected line "
                       + "deselected it anyway")
    }
}
