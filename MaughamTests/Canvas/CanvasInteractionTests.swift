import XCTest
@testable import Maugham

final class CanvasInteractionTests: XCTestCase {

    private func sceneWithOneScrap() -> CanvasScene {
        var s = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("s1"), kind: .scrap,
                           origin: CGPoint(x: 100, y: 100), width: 240)
        n.cachedHeight = 80
        s.insert(n)
        return s
    }

    func test_dragMovesTheNodeByTheDragDelta() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: scene, connecting: false)
        i.update(to: CGPoint(x: 160, y: 130), in: &scene)
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.origin, CGPoint(x: 150, y: 120))
    }

    /// A drag on empty space DRAWS A REGION — it does not touch the cards.
    ///
    /// 1C-a documented this gesture as a deliberate no-op and this test asserted
    /// `isActive == false` to say so; 1C-b Task 5 gave the gesture a job, which
    /// is the one thing that could ever have changed the assertion. What the
    /// test is really about is unchanged and is the second line: a drag that
    /// begins on bare canvas must not pick up, move or resize a card.
    func test_dragOnEmptySpaceMovesNothing() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 900, y: 900), in: scene, connecting: false)
        XCTAssertEqual(i.kind, .drawingRegion)
        XCTAssertNil(i.activeNodeID)
        i.update(to: CGPoint(x: 950, y: 950), in: &scene)
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.origin, CGPoint(x: 100, y: 100))
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.width, 240)
    }

    func test_dragPreservesWidthAndDoesNotReMeasure() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: scene, connecting: false)
        i.update(to: CGPoint(x: 400, y: 400), in: &scene)
        let n = scene.node(CanvasNodeID("s1"))
        XCTAssertEqual(n?.width, 240)
        XCTAssertEqual(n?.cachedHeight, 80, "moving a scrap must not re-measure it")
    }

    /// §7A.3: width is authoritative; resizing rewraps and the height is derived.
    func test_resizeChangesWidthAndClearsTheCachedHeight() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.beginResize(CanvasNodeID("s1"), at: CGPoint(x: 340, y: 140), in: scene)
        i.update(to: CGPoint(x: 400, y: 140), in: &scene)
        let n = scene.node(CanvasNodeID("s1"))
        XCTAssertEqual(n?.width, 300)
        XCTAssertNil(try XCTUnwrap(n).cachedHeight,
                     "a rewrapped scrap must be re-measured before it is hit-tested")
    }

    func test_resizeIsClampedToAWorkableMinimum() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.beginResize(CanvasNodeID("s1"), at: CGPoint(x: 340, y: 140), in: scene)
        i.update(to: CGPoint(x: 0, y: 140), in: &scene)
        XCTAssertGreaterThanOrEqual(scene.node(CanvasNodeID("s1"))!.width,
                                    CanvasInteraction.minimumCardWidth)
    }

    /// The corner target the state machine hit-tests takes its size from the
    /// same constant the renderer draws the mark from.
    func test_grabbingTheBottomRightCornerResizesRatherThanMoves() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        // Card is (100,100) 240x80, so the corner square starts at
        // (340 - 14, 180 - 14) = (326, 166).
        i.begin(at: CGPoint(x: 334, y: 174), in: scene, connecting: false)
        XCTAssertTrue(i.isResizing)
        i.update(to: CGPoint(x: 384, y: 174), in: &scene)
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.width, 290)
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.origin, CGPoint(x: 100, y: 100),
                       "a resize must not also move the card")
    }

    /// The TARGET is the whole 14x14 corner square; the MARK `resizeHandle`
    /// draws is the triangle below its hypotenuse. The upper-left half is
    /// therefore live but uninked, deliberately — a target slightly larger than
    /// its mark forgives a near miss. (326,166) is the square's top-left corner;
    /// (329,169) is inside the square and above the triangle — the hypotenuse
    /// runs x + y = 506 and 329 + 169 = 498, so the ink is not under this point.
    func test_theUnmarkedHalfOfTheCornerSquareStillResizes() {
        let scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 329, y: 169), in: scene, connecting: false)
        XCTAssertTrue(i.isResizing,
                      "shrinking the target down to the ink would make the corner "
                      + "feel like it misses")
    }

    /// ...and a point outside the square still moves the card, so the target has
    /// not silently grown either.
    ///
    /// **Both points are exactly ONE point outside, on exactly ONE axis.** The
    /// plan's version of this test pressed at (320,160) — six points clear on
    /// both axes, which no plausible drift in this geometry could reach, and
    /// which a `||` in place of the `&&` would pass just as happily. The corner
    /// square is (326,166)–(340,180), so (325,174) misses it on x alone and
    /// (334,165) on y alone.
    func test_justOutsideTheCornerSquareMovesRatherThanResizes() {
        let scene = sceneWithOneScrap()
        var byOnePointInX = CanvasInteraction()
        byOnePointInX.begin(at: CGPoint(x: 325, y: 174), in: scene, connecting: false)
        XCTAssertTrue(byOnePointInX.isActive)
        XCTAssertFalse(byOnePointInX.isResizing,
                       "the corner target reaches a point further left than the "
                       + "mark it is drawn from")

        var byOnePointInY = CanvasInteraction()
        byOnePointInY.begin(at: CGPoint(x: 334, y: 165), in: scene, connecting: false)
        XCTAssertTrue(byOnePointInY.isActive)
        XCTAssertFalse(byOnePointInY.isResizing,
                       "the corner test is an OR — a press anywhere along the "
                       + "card's right edge would rewrap instead of moving it")

        // And the far corner of the square itself still resizes, so the pair
        // above brackets the boundary rather than sitting on one side of it.
        var atTheCorner = CanvasInteraction()
        atTheCorner.begin(at: CGPoint(x: 326, y: 166), in: scene, connecting: false)
        XCTAssertTrue(atTheCorner.isResizing)
    }

    /// The same corner square, on an ITEM node, opens a RESIZE — the uniform rule
    /// this surface had before 1C-c3, restored now that every card kind is
    /// measured (1C-d Task 6).
    ///
    /// **This test is the inversion of `test_theCornerOfAnItemNodeMovesItRatherThanResizingIt`
    /// and not its deletion**, and what it asserts is the same thing the old one
    /// protected, from the other side. The kind test existed because
    /// `CanvasScene.setWidth` clears `cachedHeight` by design and **nothing
    /// re-measured an item node**: a node with no height has no `frame`, and a
    /// node with no frame is dropped by `CanvasScene.nodes(intersecting:)` and
    /// `topmostNode(at:)` alike — not drawn, not clickable, and persisted that
    /// way through a save. Task 5 supplied the measurement
    /// (`CanvasCardMetrics.itemCardHeight(forCardWidth:pictureAspect:)`, floored
    /// at `itemLabelOnlyHeight`) and this task added the per-frame re-derive in
    /// `CanvasView.remeasure`, so a cleared height is refilled exactly as a
    /// scrap's is.
    ///
    /// **The safety property is asserted through the real delivery path** by
    /// `CanvasViewMountingTests.test_aCornerDragOnClaudesSourcePageResizesItAndStaysOnTheCanvas`,
    /// mid-drag. This is the state-machine half: the decision, with no view.
    ///
    /// The condition was REMOVED rather than widened to `.item`. Every kind
    /// measures now, so the honest end state is one unconditional rule and not a
    /// second condition — which is also what lets `CanvasRenderer.drawCard` go
    /// back to inking the triangle on every card.
    func test_theCornerOfAnItemNodeResizesItLikeAnyOtherCard() {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: CanvasNodeID.item("res-p3"),
                                kind: .item(.project(id: "res-p3")),
                                origin: CGPoint(x: 100, y: 100), width: 240,
                                cachedHeight: 33, author: .claude))
        // Card is (100,100) 240x33, so the corner square is (326,119)–(340,133).
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 334, y: 127), in: scene, connecting: false)
        XCTAssertTrue(i.isResizing,
                      "the corner of a page card still moves it: the mark "
                      + "CanvasRenderer.drawCard draws there now invites a gesture "
                      + "the state machine does not offer")
        i.update(to: CGPoint(x: 394, y: 127), in: &scene)
        XCTAssertEqual(scene.node(CanvasNodeID.item("res-p3"))?.width, 300,
                       "the drag reached the resize arm but the width did not follow "
                       + "the pointer")
        // Control: the card was RESIZED and not dragged. A `.moving` arm would
        // have moved the origin by the same 60 pt and left the width alone.
        XCTAssertEqual(scene.node(CanvasNodeID.item("res-p3"))?.origin,
                       CGPoint(x: 100, y: 100),
                       "a resize must not also move the card")
    }

    /// An item node's width is clamped by the SAME rule a scrap's is, and the
    /// clamp is one line in `CanvasInteraction.update` that never had a kind test
    /// on it — so this asserts that no second rule was invented for the kind that
    /// just gained the gesture.
    ///
    /// The floor is a scrap's wrapping in origin (`minimumCardWidth`'s doc), and
    /// an item card inherits it rather than getting a number of its own: a page
    /// card at 40 pt would be a photograph the writer cannot see either.
    func test_anItemNodeIsClampedToTheSameMinimumWidthAsAScrap() {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: CanvasNodeID.item("res-p3"),
                                kind: .item(.project(id: "res-p3")),
                                origin: CGPoint(x: 100, y: 100), width: 240,
                                cachedHeight: 33, author: .claude))
        var i = CanvasInteraction()
        i.beginResize(CanvasNodeID.item("res-p3"), at: CGPoint(x: 334, y: 127), in: scene)
        i.update(to: CGPoint(x: 0, y: 127), in: &scene)
        XCTAssertEqual(scene.node(CanvasNodeID.item("res-p3"))?.width,
                       CanvasInteraction.minimumCardWidth,
                       "an item node was dragged below the minimum card width — the "
                       + "clamp in CanvasInteraction.update is one rule for every kind")
    }

    func test_newScrapLandsAtTheClickAndOnTop() {
        var scene = sceneWithOneScrap()
        let id = CanvasInteraction.createScrap(at: CGPoint(x: 500, y: 400), in: &scene)
        let n = scene.node(id)
        XCTAssertEqual(n?.origin, CGPoint(x: 500, y: 400))
        XCTAssertGreaterThan(n!.z, scene.node(CanvasNodeID("s1"))!.z)
        XCTAssertNil(try XCTUnwrap(n).cachedHeight,
                     "a new scrap is measured by the view, not guessed here")
        // The width is the one thing about a new card the writer sees before
        // typing a word, and nothing else in the suite reads
        // `defaultScrapWidth` — `createScrap` could hand `insert` the MINIMUM,
        // or any literal, and every card the canvas ever makes would come out
        // the wrong size with the suite still green.
        XCTAssertEqual(n?.width, CanvasInteraction.defaultScrapWidth)
        XCTAssertGreaterThan(CanvasInteraction.defaultScrapWidth,
                             CanvasInteraction.minimumCardWidth,
                             "a default equal to the minimum opens every new scrap "
                             + "at the narrowest width the surface allows, which is "
                             + "also the one width the writer cannot narrow")
    }

    func test_createdScrapIDsAreUnique() {
        var scene = CanvasScene()
        let ids = (0..<200).map { _ in CanvasInteraction.createScrap(at: .zero, in: &scene) }
        XCTAssertEqual(Set(ids).count, 200)
        XCTAssertEqual(scene.count, 200)
    }

    // MARK: - Velocity, for §7.3's momentum

    /// Time is INJECTED here, not sampled. `update` and `end` both default `now`
    /// to `CACurrentMediaTime()`, so left to the defaults this test would measure
    /// how long the machine took between two synchronous calls and compare it
    /// against `maximumFlickAge` — green on a quiet machine, red under load, and
    /// wrong either way. The stamps below say "one frame apart, released half a
    /// frame later", which is what the assertion is actually about.
    func test_endReturnsTheFinalDragDeltaAsVelocity() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        let t = 100.0
        i.begin(at: CGPoint(x: 110, y: 110), in: scene, connecting: false)
        i.update(to: CGPoint(x: 130, y: 110), in: &scene, now: t)
        // last frame: +30, +8
        i.update(to: CGPoint(x: 160, y: 118), in: &scene, now: t + 1.0 / 60)
        let flick = i.end(now: t + 1.0 / 60 + 1.0 / 120)
        XCTAssertEqual(flick?.id, CanvasNodeID("s1"))
        XCTAssertEqual(flick?.velocity, CGSize(width: 30, height: 8))
        XCTAssertFalse(i.isActive)
    }

    func test_aResizeYieldsNoFlick() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.beginResize(CanvasNodeID("s1"), at: CGPoint(x: 340, y: 140), in: scene)
        i.update(to: CGPoint(x: 400, y: 140), in: &scene)
        XCTAssertNil(i.end(), "a rewrap must not send the card skating")
    }

    func test_aDragWithOnlyOneSampleYieldsZeroVelocity() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: scene, connecting: false)
        i.update(to: CGPoint(x: 160, y: 130), in: &scene)
        XCTAssertEqual(i.end()?.velocity, .zero,
                       "one sample is a placement, not a throw")
    }

    /// **A drag the writer PAUSED before letting go is a placement, not a
    /// throw.** `mouseDragged:` is delivered on MOTION, not on a clock, so a
    /// parked pointer produces no samples at all: without the stamp the two
    /// retained samples are still the fast ones from before the pause, and the
    /// card the writer had already put down goes skating.
    ///
    /// Both halves are here on purpose. The staleness guard has a failure mode
    /// of its own — set too tight it kills every flick, which passes the first
    /// assertion and destroys §7.3.
    func test_aDragPausedBeforeReleaseDoesNotFlick() {
        let fast = CGPoint(x: 130, y: 110)
        let faster = CGPoint(x: 160, y: 118)   // +30, +8 in one frame

        // A scene each: the drags below move the card, and a second press at the
        // same point would land on bare canvas.
        var pausedScene = sceneWithOneScrap()
        var paused = CanvasInteraction()
        paused.begin(at: CGPoint(x: 110, y: 110), in: pausedScene, connecting: false)
        paused.update(to: fast, in: &pausedScene, now: 100)
        paused.update(to: faster, in: &pausedScene, now: 100 + 1.0 / 60)
        XCTAssertEqual(paused.end(now: 100 + 1.0 / 60 + 0.2)?.velocity, .zero,
                       "the writer moved the card fast, held it still for a fifth "
                       + "of a second and let go — a card that slides away from "
                       + "where it was parked is the first thing momentum gets "
                       + "blamed for")

        var releasedScene = sceneWithOneScrap()
        var released = CanvasInteraction()
        released.begin(at: CGPoint(x: 110, y: 110), in: releasedScene, connecting: false)
        released.update(to: fast, in: &releasedScene, now: 100)
        released.update(to: faster, in: &releasedScene, now: 100 + 1.0 / 60)
        XCTAssertEqual(released.end(now: 100 + 1.0 / 60 + 1.0 / 120)?.velocity,
                       CGSize(width: 30, height: 8),
                       "a release that follows its last motion inside a frame is an "
                       + "ordinary fast flick and MUST still flick")
    }

    /// The boundary itself, from both sides — a guard whose threshold could halve
    /// or double without a test noticing is not a threshold.
    ///
    /// The two comparisons below are deliberately written against the constant,
    /// so they pin that the guard fires where it claims to rather than a frame
    /// either side of it. That leaves the constant's own VALUE unpinned, which is
    /// what the band at the top asserts: the number may be tuned, but only inside
    /// the window where both of §7.3's failure modes are still excluded.
    ///
    /// They straddle the boundary by a millisecond rather than landing on it. A
    /// sample aged EXACTLY `maximumFlickAge` is not a behaviour worth pinning —
    /// whether the comparison is `<=` or `<` makes no difference to any writer —
    /// and asserting it would only measure floating point: `51 + 0.1 - 51` is
    /// `0.10000000000000142`, so the on-the-boundary release is already outside
    /// its own boundary. A millisecond each way pins the threshold's position to
    /// within 2 ms, which is two orders finer than any mis-tuning could be.
    func test_theFlickStalenessBoundaryIsWhereItSaysItIs() {
        let age = CanvasInteraction.maximumFlickAge

        XCTAssertGreaterThan(age, 2.0 / 60,
                             "a threshold inside a couple of frames disarms ORDINARY "
                             + "flicks: every drag sample on this surface mutates the "
                             + "scene and recomputes `body`, so the mouseUp of a "
                             + "genuine throw routinely lands a hitched frame or two "
                             + "after the last mouseDragged")
        XCTAssertLessThan(age, 0.15,
                          "the shortest stop a hand can make on purpose before letting "
                          + "go is around 150-200ms; at or above it the guard starts "
                          + "believing pauses and the parked card is thrown anyway")

        var onTimeScene = sceneWithOneScrap()
        var justInTime = CanvasInteraction()
        justInTime.begin(at: CGPoint(x: 110, y: 110), in: onTimeScene, connecting: false)
        justInTime.update(to: CGPoint(x: 120, y: 110), in: &onTimeScene, now: 50)
        justInTime.update(to: CGPoint(x: 140, y: 110), in: &onTimeScene, now: 51)
        XCTAssertEqual(justInTime.end(now: 51 + age - 0.001)?.velocity,
                       CGSize(width: 20, height: 0),
                       "a release a millisecond inside the threshold is a flick")

        var lateScene = sceneWithOneScrap()
        var tooLate = CanvasInteraction()
        tooLate.begin(at: CGPoint(x: 110, y: 110), in: lateScene, connecting: false)
        tooLate.update(to: CGPoint(x: 120, y: 110), in: &lateScene, now: 50)
        tooLate.update(to: CGPoint(x: 140, y: 110), in: &lateScene, now: 51)
        XCTAssertEqual(tooLate.end(now: 51 + age + 0.001)?.velocity, .zero,
                       "a release a millisecond outside it is a placement")
    }

    // MARK: - Did it move at all?

    /// AppKit opens a drag session on EVERY mouse-down, including the first
    /// mouse-down of a double-click (`CanvasEventNSView.applyMouseDown` pins the
    /// ordering). So entering a scrap always runs a `begin`/`end` pair with no
    /// `.changed` in between, and the canvas needs to be able to tell that from a
    /// drag — otherwise every double-click writes the sidecar, rebuilds the
    /// accessibility tree, and (from Task 15) leaves a "Move Scrap" undo step
    /// that undoes nothing.
    ///
    /// `hasMoved` survives `end()` deliberately: the caller reads it either side
    /// of the call, and it is cleared by the next `begin`.
    func test_aPressThatNeverMovedIsNotADrag() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: scene, connecting: false)
        XCTAssertTrue(i.isActive)
        XCTAssertFalse(i.hasMoved)

        i.update(to: CGPoint(x: 110, y: 110), in: &scene)
        XCTAssertFalse(i.hasMoved, "a sample at the press point is not movement")

        i.end()
        XCTAssertFalse(i.hasMoved, "`hasMoved` describes the gesture that just "
                       + "ended — a caller reading it after `end()` must not be "
                       + "told the card moved")
    }

    func test_aDragOfASinglePointHasMoved() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: scene, connecting: false)
        i.update(to: CGPoint(x: 111, y: 110), in: &scene)
        XCTAssertTrue(i.hasMoved)
        i.end()
        XCTAssertTrue(i.hasMoved)

        // ...and the next press starts clean.
        i.begin(at: CGPoint(x: 111, y: 110), in: scene, connecting: false)
        XCTAssertFalse(i.hasMoved)
    }

    /// Renamed from `test_aResizeThatNeverMovedIsNotAResize`, which described one
    /// line of itself: the one-point case is what it actually measures, and the
    /// case its old name claimed is now
    /// `test_aResizeSampleAtThePressPointStillClearsTheCachedHeight` below —
    /// which turns out to have the OPPOSITE answer.
    func test_aResizeOfOnePointIsAResize() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.beginResize(CanvasNodeID("s1"), at: CGPoint(x: 340, y: 140), in: scene)
        XCTAssertFalse(i.hasMoved)
        i.update(to: CGPoint(x: 341, y: 140), in: &scene)
        XCTAssertTrue(i.hasMoved, "a rewrap of one point is still a rewrap — the "
                      + "card has to be re-measured or it hit-tests against its "
                      + "old shape")
    }

    /// **`hasMoved` and "does this node still have a height" are DIFFERENT
    /// questions, and a resize is where they part company.**
    ///
    /// `test_aPressThatNeverMovedIsNotADrag` covers the update-at-the-press-point
    /// case for a MOVE, where it is harmless: `scene.move(to:)` puts the node back
    /// exactly where it was. The resizing arm is not harmless —
    /// `CanvasScene.setWidth` clears `cachedHeight` unconditionally, identical
    /// width or not, so this one sample leaves the node with no `frame` at all:
    /// invisible to `topmostNode(at:)`, to `nodes(intersecting:)` and to the
    /// renderer.
    ///
    /// That is a state the model is entitled to be in — the width IS
    /// authoritative and the height IS derived — but it means the view's
    /// re-measure may not be gated on `hasMoved`. It is not; the live proof is
    /// `CanvasViewMountingTests.test_aCornerPressThatNeverMovedLeavesTheCardOnTheCanvas`.
    func test_aResizeSampleAtThePressPointStillClearsTheCachedHeight() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        let press = CGPoint(x: 340, y: 140)
        i.beginResize(CanvasNodeID("s1"), at: press, in: scene)
        i.update(to: press, in: &scene)

        XCTAssertFalse(i.hasMoved, "the pointer never left the press point")
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.width, 240,
                       "precondition: the width is unchanged, so nothing about "
                       + "this card actually needs rewrapping")
        XCTAssertNil(try XCTUnwrap(scene.node(CanvasNodeID("s1"))).cachedHeight,
                     "the height went anyway — so a caller that re-measures only "
                     + "when `hasMoved` leaves this card with no frame, and a card "
                     + "with no frame is not on the canvas at all")
        XCTAssertNil(try XCTUnwrap(scene.node(CanvasNodeID("s1"))).frame)
    }
}
