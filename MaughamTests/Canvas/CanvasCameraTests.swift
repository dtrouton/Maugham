import XCTest
@testable import Maugham

final class CanvasCameraTests: XCTestCase {

    func test_identityCamera_mapsPointsUnchanged() {
        let c = CanvasCamera()
        XCTAssertEqual(c.contentPoint(fromView: CGPoint(x: 10, y: 20)), CGPoint(x: 10, y: 20))
        XCTAssertEqual(c.viewPoint(fromContent: CGPoint(x: 10, y: 20)), CGPoint(x: 10, y: 20))
    }

    func test_viewAndContentTransforms_areInverses() {
        var c = CanvasCamera()
        c.zoom = 2.5
        c.pan = CGPoint(x: -300, y: 120)
        let p = CGPoint(x: 173.25, y: -44.5)
        let round = c.contentPoint(fromView: c.viewPoint(fromContent: p))
        XCTAssertEqual(round.x, p.x, accuracy: 0.0001)
        XCTAssertEqual(round.y, p.y, accuracy: 0.0001)
    }

    /// Zoom-to-cursor. The point under the pointer must not move — the runner-up
    /// architecture got this free from setMagnification(_:centeredAt:) and we
    /// owe it by hand.
    func test_zoomAnchoring_holdsThePointUnderTheCursor() {
        var c = CanvasCamera()
        let anchorView = CGPoint(x: 400, y: 250)
        let contentBefore = c.contentPoint(fromView: anchorView)
        c.zoom(to: 2.75, anchoringViewPoint: anchorView)
        let contentAfter = c.contentPoint(fromView: anchorView)
        XCTAssertEqual(contentAfter.x, contentBefore.x, accuracy: 0.0001)
        XCTAssertEqual(contentAfter.y, contentBefore.y, accuracy: 0.0001)
        XCTAssertEqual(c.zoom, 2.75, accuracy: 0.0001)
    }

    func test_zoomIsClampedToItsRange() {
        var c = CanvasCamera()
        c.zoom(to: 99, anchoringViewPoint: .zero)
        XCTAssertEqual(c.zoom, CanvasCamera.zoomRange.upperBound)
        c.zoom(to: 0.0001, anchoringViewPoint: .zero)
        XCTAssertEqual(c.zoom, CanvasCamera.zoomRange.lowerBound)
    }

    func test_clampedZoom_stillAnchors() {
        var c = CanvasCamera()
        let anchor = CGPoint(x: 120, y: 90)
        let before = c.contentPoint(fromView: anchor)
        c.zoom(to: 999, anchoringViewPoint: anchor)
        let after = c.contentPoint(fromView: anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 0.0001,
                       "anchoring must use the CLAMPED zoom, not the requested one")
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001)
    }

    func test_visibleContentRect_shrinksAsZoomGrows() {
        var c = CanvasCamera()
        let size = CGSize(width: 800, height: 600)
        let at1 = c.visibleContentRect(viewSize: size)
        c.zoom = 2
        let at2 = c.visibleContentRect(viewSize: size)
        XCTAssertEqual(at1.width, 800, accuracy: 0.0001)
        XCTAssertEqual(at2.width, 400, accuracy: 0.0001)
    }

    /// `panBy` translates the CONTENT by the delta it is given. Direction is the
    /// caller's business — `CanvasEventNSView` decides what a scroll wheel means;
    /// the camera only applies it. (The old name for this test claimed the
    /// opposite of what the assertion checks.)
    func test_panBy_translatesContentByTheDelta() {
        var c = CanvasCamera()
        c.panBy(CGSize(width: 50, height: 30))
        XCTAssertEqual(c.viewPoint(fromContent: .zero), CGPoint(x: 50, y: 30))
    }

    func test_panBy_accumulates() {
        var c = CanvasCamera()
        c.panBy(CGSize(width: 50, height: 30))
        c.panBy(CGSize(width: -20, height: 5))
        XCTAssertEqual(c.pan, CGPoint(x: 30, y: 35))
    }

    // MARK: - Reveal (1C-c3)

    /// `bring` is `viewPoint(fromContent:)` solved for `pan`, so the check is the
    /// round trip rather than the arithmetic: after it, the content point really
    /// does map to the view point that was asked for.
    ///
    /// Driven at a zoom that is not 1 and from a pan that is not zero, because
    /// with either at its identity the wrong formula passes too.
    func test_bringPutsTheContentPointAtTheViewPointAsked() {
        var c = CanvasCamera()
        c.zoom = 2.5
        c.pan = CGPoint(x: -700, y: 480)
        let content = CGPoint(x: 1_840.5, y: 96.25)
        let target = CGPoint(x: 120, y: 120)

        c.bring(content, toViewPoint: target)

        let landed = c.viewPoint(fromContent: content)
        XCTAssertEqual(landed.x, target.x, accuracy: 0.0001)
        XCTAssertEqual(landed.y, target.y, accuracy: 0.0001)
    }

    /// **Zoom is not touched.** A reveal that also zoomed would change how much of
    /// their own work the writer can see in order to show them somebody else's,
    /// and "fit this rect" needs a viewport size `CanvasView` does not have
    /// outside its draw closure.
    func test_bringLeavesZoomAlone() {
        var c = CanvasCamera()
        c.zoom = 0.75
        c.bring(CGPoint(x: 4_000, y: 2_000), toViewPoint: CanvasCamera.revealViewPoint)
        XCTAssertEqual(c.zoom, 0.75, accuracy: 0.0001)
    }

    /// The inset is off the window's own corner: a region's chrome bar and label
    /// flush against it read as clipped rather than as arrived.
    func test_theRevealInsetIsClearOfTheCorner() {
        XCTAssertGreaterThan(CanvasCamera.revealViewPoint.x, 0)
        XCTAssertGreaterThan(CanvasCamera.revealViewPoint.y, 0)
    }

    /// Revealing the same point twice is the same camera — a reveal is a jump to a
    /// place, not a relative nudge, so it cannot accumulate the way `panBy` does.
    func test_bringIsAbsoluteRatherThanRelative() {
        var c = CanvasCamera()
        c.bring(CGPoint(x: 900, y: 300), toViewPoint: CanvasCamera.revealViewPoint)
        let once = c
        c.bring(CGPoint(x: 900, y: 300), toViewPoint: CanvasCamera.revealViewPoint)
        XCTAssertEqual(c, once)
    }
}
