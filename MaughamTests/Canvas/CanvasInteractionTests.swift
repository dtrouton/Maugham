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
        i.begin(at: CGPoint(x: 110, y: 110), in: scene)
        i.update(to: CGPoint(x: 160, y: 130), in: &scene)
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.origin, CGPoint(x: 150, y: 120))
    }

    func test_dragOnEmptySpaceMovesNothing() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 900, y: 900), in: scene)
        XCTAssertFalse(i.isActive)
        i.update(to: CGPoint(x: 950, y: 950), in: &scene)
        XCTAssertEqual(scene.node(CanvasNodeID("s1"))?.origin, CGPoint(x: 100, y: 100))
    }

    func test_dragPreservesWidthAndDoesNotReMeasure() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: scene)
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
        XCTAssertNil(n?.cachedHeight, "a rewrapped scrap must be re-measured before it is hit-tested")
    }

    func test_resizeIsClampedToAWorkableMinimum() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.beginResize(CanvasNodeID("s1"), at: CGPoint(x: 340, y: 140), in: scene)
        i.update(to: CGPoint(x: 0, y: 140), in: &scene)
        XCTAssertGreaterThanOrEqual(scene.node(CanvasNodeID("s1"))!.width,
                                    CanvasInteraction.minimumScrapWidth)
    }

    /// The corner target the state machine hit-tests takes its size from the
    /// same constant the renderer draws the mark from.
    func test_grabbingTheBottomRightCornerResizesRatherThanMoves() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        // Card is (100,100) 240x80, so the corner square starts at
        // (340 - 14, 180 - 14) = (326, 166).
        i.begin(at: CGPoint(x: 334, y: 174), in: scene)
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
        i.begin(at: CGPoint(x: 329, y: 169), in: scene)
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
        byOnePointInX.begin(at: CGPoint(x: 325, y: 174), in: scene)
        XCTAssertTrue(byOnePointInX.isActive)
        XCTAssertFalse(byOnePointInX.isResizing,
                       "the corner target reaches a point further left than the "
                       + "mark it is drawn from")

        var byOnePointInY = CanvasInteraction()
        byOnePointInY.begin(at: CGPoint(x: 334, y: 165), in: scene)
        XCTAssertTrue(byOnePointInY.isActive)
        XCTAssertFalse(byOnePointInY.isResizing,
                       "the corner test is an OR — a press anywhere along the "
                       + "card's right edge would rewrap instead of moving it")

        // And the far corner of the square itself still resizes, so the pair
        // above brackets the boundary rather than sitting on one side of it.
        var atTheCorner = CanvasInteraction()
        atTheCorner.begin(at: CGPoint(x: 326, y: 166), in: scene)
        XCTAssertTrue(atTheCorner.isResizing)
    }

    func test_newScrapLandsAtTheClickAndOnTop() {
        var scene = sceneWithOneScrap()
        let id = CanvasInteraction.createScrap(at: CGPoint(x: 500, y: 400), in: &scene)
        let n = scene.node(id)
        XCTAssertEqual(n?.origin, CGPoint(x: 500, y: 400))
        XCTAssertGreaterThan(n!.z, scene.node(CanvasNodeID("s1"))!.z)
        XCTAssertNil(n?.cachedHeight, "a new scrap is measured by the view, not guessed here")
    }

    func test_createdScrapIDsAreUnique() {
        var scene = CanvasScene()
        let ids = (0..<200).map { _ in CanvasInteraction.createScrap(at: .zero, in: &scene) }
        XCTAssertEqual(Set(ids).count, 200)
        XCTAssertEqual(scene.count, 200)
    }

    // MARK: - Velocity, for §7.3's momentum

    func test_endReturnsTheFinalDragDeltaAsVelocity() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: scene)
        i.update(to: CGPoint(x: 130, y: 110), in: &scene)
        i.update(to: CGPoint(x: 160, y: 118), in: &scene)   // last frame: +30, +8
        let flick = i.end()
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
        i.begin(at: CGPoint(x: 110, y: 110), in: scene)
        i.update(to: CGPoint(x: 160, y: 130), in: &scene)
        XCTAssertEqual(i.end()?.velocity, .zero,
                       "one sample is a placement, not a throw")
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
        i.begin(at: CGPoint(x: 110, y: 110), in: scene)
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
        i.begin(at: CGPoint(x: 110, y: 110), in: scene)
        i.update(to: CGPoint(x: 111, y: 110), in: &scene)
        XCTAssertTrue(i.hasMoved)
        i.end()
        XCTAssertTrue(i.hasMoved)

        // ...and the next press starts clean.
        i.begin(at: CGPoint(x: 111, y: 110), in: scene)
        XCTAssertFalse(i.hasMoved)
    }

    func test_aResizeThatNeverMovedIsNotAResize() {
        var scene = sceneWithOneScrap()
        var i = CanvasInteraction()
        i.beginResize(CanvasNodeID("s1"), at: CGPoint(x: 340, y: 140), in: scene)
        XCTAssertFalse(i.hasMoved)
        i.update(to: CGPoint(x: 341, y: 140), in: &scene)
        XCTAssertTrue(i.hasMoved, "a rewrap of one point is still a rewrap — the "
                      + "card has to be re-measured or it hit-tests against its "
                      + "old shape")
    }
}
