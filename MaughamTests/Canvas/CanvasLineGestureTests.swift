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
}
