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
}
