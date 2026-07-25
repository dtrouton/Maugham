import XCTest
import AppKit
@testable import Maugham

final class CanvasEventViewTests: XCTestCase {

    private func view() -> CanvasEventNSView {
        let v = CanvasEventNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        v.camera = CanvasCamera()
        return v
    }

    func test_scrollPansTheCamera() {
        let v = view()
        v.applyScroll(deltaX: 20, deltaY: -15, precise: true)
        XCTAssertEqual(v.camera.pan, CGPoint(x: 20, y: -15))
        XCTAssertEqual(v.camera.zoom, 1, "scrolling must not zoom")
    }

    func test_coarseWheelTicksAreAmplifiedRelativeToTrackpad() {
        let precise = view(); precise.applyScroll(deltaX: 0, deltaY: 3, precise: true)
        let wheel = view(); wheel.applyScroll(deltaX: 0, deltaY: 3, precise: false)
        XCTAssertGreaterThan(wheel.camera.pan.y, precise.camera.pan.y)
    }

    func test_magnifyZoomsAndHoldsTheAnchor() {
        let v = view()
        let anchor = CGPoint(x: 300, y: 200)
        let before = v.camera.contentPoint(fromView: anchor)
        v.applyMagnify(magnification: 0.5, at: anchor)   // +50%
        XCTAssertEqual(v.camera.zoom, 1.5, accuracy: 0.0001)
        let after = v.camera.contentPoint(fromView: anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 0.0001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001)
    }

    func test_magnifyIsClamped() {
        let v = view()
        for _ in 0..<50 { v.applyMagnify(magnification: 1.0, at: .zero) }
        XCTAssertEqual(v.camera.zoom, CanvasCamera.zoomRange.upperBound)
        for _ in 0..<200 { v.applyMagnify(magnification: -0.5, at: .zero) }
        XCTAssertEqual(v.camera.zoom, CanvasCamera.zoomRange.lowerBound)
    }

    func test_repeatedMagnifyCompoundsRatherThanResets() {
        let v = view()
        v.applyMagnify(magnification: 0.1, at: .zero)
        let once = v.camera.zoom
        v.applyMagnify(magnification: 0.1, at: .zero)
        XCTAssertGreaterThan(v.camera.zoom, once)
    }

    func test_viewAcceptsFirstMouseSoOneClickReachesTheCanvas() {
        XCTAssertTrue(view().acceptsFirstMouse(for: nil),
                      "an inactive window must not eat the writer's first click")
    }

    // MARK: - The one drag vocabulary

    func test_aFullDragEmitsBeganChangedEndedInOrder() {
        let v = view()
        var phases: [CanvasDragPhase] = []
        var points: [CGPoint] = []
        v.onDrag = { p, phase in points.append(p); phases.append(phase) }

        v.applyMouseDown(at: CGPoint(x: 10, y: 10), clickCount: 1)
        v.applyMouseDragged(to: CGPoint(x: 40, y: 20))
        v.applyMouseDragged(to: CGPoint(x: 70, y: 30))
        v.applyMouseUp(at: CGPoint(x: 70, y: 30))

        XCTAssertEqual(phases, [.began, .changed, .changed, .ended])
        XCTAssertEqual(points.first, CGPoint(x: 10, y: 10))
        XCTAssertEqual(points.last, CGPoint(x: 70, y: 30))
    }

    func test_draggedWithoutAMouseDownEmitsNothing() {
        let v = view()
        var phases: [CanvasDragPhase] = []
        v.onDrag = { _, phase in phases.append(phase) }
        v.applyMouseDragged(to: CGPoint(x: 40, y: 20))
        v.applyMouseUp(at: CGPoint(x: 40, y: 20))
        XCTAssertTrue(phases.isEmpty, "a drag that never began must not end")
    }

    func test_clickReportsItsClickCountSoDoubleClickIsDistinguishable() {
        let v = view()
        var counts: [Int] = []
        v.onClick = { _, count in counts.append(count) }
        v.applyMouseDown(at: .zero, clickCount: 1)
        v.applyMouseUp(at: .zero)
        v.applyMouseDown(at: .zero, clickCount: 2)
        v.applyMouseUp(at: .zero)
        XCTAssertEqual(counts, [1, 2])
    }

    /// ⌘Z on the canvas reaches `CanvasUndo` through the responder chain:
    /// `NSWindow.undo(_:)` asks the first responder for its `undoManager`.
    func test_theViewVendsTheCanvasUndoManagerToTheResponderChain() {
        let v = view()
        let manager = UndoManager()
        v.canvasUndoManager = manager
        XCTAssertTrue(v.acceptsFirstResponder)
        XCTAssertTrue(v.undoManager === manager)
    }
}
