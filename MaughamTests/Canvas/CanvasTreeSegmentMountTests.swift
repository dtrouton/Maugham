import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

/// The binder segment, in a box the harness can observe — the test drives this
/// exactly as the picker drives `ProjectWindow`'s `@State`. At file scope
/// because `@Observable` cannot expand inside a `private` nested type.
@Observable
final class CanvasTreeSegmentBox {
    var segment: BinderSegment = .canvas
    init(_ segment: BinderSegment) { self.segment = segment }
}

/// **Does flipping the binder between `.canvas` and `.tree` rebuild the canvas?**
///
/// The slice-2 plan asserted it would and marked the underlying SwiftUI
/// behaviour *unverified by test in this app*, so it is measured here rather
/// than cited. Everything the writer would lose is `@State` on `CanvasView` —
/// the camera, the per-scrap layouts, the thumbnail cache, the in-progress
/// scrap edit and the accessibility elements — and `CanvasModel`'s own doc
/// comment says so from the other side ("what deliberately does not live here:
/// camera, layouts…").
///
/// **The counterfactual is planted, not described.** `Shape.twoArms` is exactly
/// what the lazy fix looks like — a `case .tree:` clause of its own returning
/// its own `CanvasView` — and it is measured beside `Shape.hoisted`, which asks
/// the REAL `ProjectWindow.editorRoute` and mounts one canvas for whatever it
/// answers `.canvas` to. If `editorRoute` ever stops mapping `.tree` onto the
/// canvas branch, the hoisted half of every measurement below goes red.
///
/// Measured on macOS 26.5, 2026-08-02. The numbers are in each test.
@MainActor
final class CanvasTreeSegmentMountTests: XCTestCase {

    private var roots: [URL] = []
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.contentView = NSView(frame: .zero) }
        windows.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: - The harness

    /// Which centre-column shape is under measurement.
    private enum Shape {
        /// The counterfactual: an arm apiece. Two `case` clauses in a ViewBuilder
        /// `switch` are two `_ConditionalContent` branches.
        case twoArms
        /// What shipped: one branch, chosen by the production route function.
        case hoisted
    }

    private typealias SegmentBox = CanvasTreeSegmentBox

    private struct Harness: View {
        @Bindable var box: SegmentBox
        let shape: Shape
        let root: URL
        let model: CanvasModel
        /// Bumped by `CanvasView.load()`, which runs from `.onAppear` — so it
        /// counts MOUNTS on the production path rather than through an
        /// instrument invented for this test.
        let onLoad: () -> Void

        var body: some View {
            switch shape {
            case .twoArms:
                switch box.segment {
                case .canvas: canvas
                case .tree: canvas
                default: Color.clear
                }
            case .hoisted:
                // Plan, because this box only ever holds Plan's two canvas
                // segments — the whole subject of the measurement is a flip
                // between them.
                switch ProjectWindow.editorRoute(persona: .plan,
                                                 interimSegment: box.segment,
                                                 projectType: .novel,
                                                 selectedPieceIsReference: false) {
                case .canvas: canvas
                case .collectionReference, .segment: Color.clear
                }
            }
        }

        private var canvas: some View {
            CanvasView(model: model, projectRoot: root,
                       paletteSwatchHexes: { onLoad(); return [] })
        }
    }

    // MARK: - Fixtures

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: CanvasNodeID("n1"), kind: .scrap,
                                origin: CGPoint(x: 20, y: 20), width: 240, cachedHeight: 38))
        CanvasStore(projectRoot: root).save(scene: scene,
                                            scraps: [CanvasNodeID("n1"): "a card"])
        return root
    }

    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func host(_ view: some View) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        windows.append(window)
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        pump()
        return window
    }

    private func firstDescendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = firstDescendant(type, in: sub) { return hit }
        }
        return nil
    }

    private func eventView(in window: NSWindow) throws -> CanvasEventNSView {
        let root = try XCTUnwrap(window.contentView)
        return try XCTUnwrap(firstDescendant(CanvasEventNSView.self, in: root),
                             "the canvas never reached the hosted hierarchy, so "
                             + "nothing here is measuring what it claims to")
    }

    /// Pan and zoom away from the defaults, through the same seam a trackpad
    /// drives, and hand back what the camera became.
    @discardableResult
    private func moveTheCamera(in window: NSWindow) throws -> CanvasCamera {
        let events = try eventView(in: window)
        events.applyScroll(deltaX: -320, deltaY: -180, precise: true)
        events.applyMagnify(magnification: 0.5, at: CGPoint(x: 400, y: 300))
        pump()
        let moved = try eventView(in: window).camera
        XCTAssertNotEqual(moved, CanvasCamera(),
                          "the control: if the camera never left its default "
                          + "this measures nothing at all")
        // The exact value, so the numbers quoted in the doc comments above are
        // pinned by an assertion rather than written down and left to drift.
        XCTAssertEqual(moved.pan, CGPoint(x: -680, y: -420))
        XCTAssertEqual(moved.zoom, 1.5)
        return moved
    }

    // MARK: - The measurement

    /// **The plant.** An arm apiece destroys the canvas on every flip.
    ///
    /// Measured: pan (−680, −420) at zoom 1.5 before the flip, `pan .zero` /
    /// `zoom 1` after — the untouched default — and the `CanvasEventNSView` is a
    /// different object, so `makeNSView` ran a second time. `load()` ran twice.
    ///
    /// A plant that does not fire is the finding: if this ever goes green,
    /// SwiftUI has stopped tearing sibling `case` arms down and the hoist in
    /// `editorPane` can be simplified away.
    func test_anArmApieceRebuildsTheCanvasOnEveryFlip() throws {
        let root = try makeRoot()
        let box = SegmentBox(.canvas)
        var loads = 0
        let window = host(Harness(box: box, shape: .twoArms, root: root,
                                  model: CanvasModel(), onLoad: { loads += 1 }))

        let before = try moveTheCamera(in: window)
        let beforeID = ObjectIdentifier(try eventView(in: window))
        XCTAssertEqual(loads, 1, "the canvas mounted once to begin with")

        box.segment = .tree
        pump()

        let after = try eventView(in: window)
        XCTAssertNotEqual(ObjectIdentifier(after), beforeID,
                          "two ViewBuilder case arms are two branches, so the "
                          + "canvas is a NEW view and AppKit made a new event view")
        XCTAssertEqual(after.camera, CanvasCamera(),
                       "and the camera went back to the origin at zoom 1, "
                       + "losing \(before)")
        XCTAssertEqual(loads, 2,
                       "`.onAppear` ran again, so `canvas.md` and the sidecar "
                       + "were re-read and every layout re-measured")
    }

    /// **What shipped.** One branch, chosen by `ProjectWindow.editorRoute`.
    ///
    /// Measured on the same fixture and the same flip: the same
    /// `CanvasEventNSView` object, the same camera the writer left it at, and
    /// `load()` still having run exactly once.
    func test_theHoistedRouteKeepsTheCanvasMountedAcrossTheFlip() throws {
        let root = try makeRoot()
        let box = SegmentBox(.canvas)
        var loads = 0
        let window = host(Harness(box: box, shape: .hoisted, root: root,
                                  model: CanvasModel(), onLoad: { loads += 1 }))

        let before = try moveTheCamera(in: window)
        let beforeID = ObjectIdentifier(try eventView(in: window))
        XCTAssertEqual(loads, 1)

        box.segment = .tree
        pump()

        let after = try eventView(in: window)
        XCTAssertEqual(ObjectIdentifier(after), beforeID,
                       "one branch serves both segments, so this is the same "
                       + "view and the same AppKit event view")
        XCTAssertEqual(after.camera, before,
                       "the writer's pan and zoom survive the flip")
        XCTAssertEqual(loads, 1,
                       "`.onAppear` did not run again — no re-read of "
                       + "`canvas.md`, no re-measure of every layout")
    }

    /// And back again, because a flip is a round trip in the hand: the writer
    /// arranges structure, flips to the canvas, flips back.
    func test_theCanvasSurvivesTheRoundTripBothWays() throws {
        let root = try makeRoot()
        let box = SegmentBox(.tree)
        var loads = 0
        let window = host(Harness(box: box, shape: .hoisted, root: root,
                                  model: CanvasModel(), onLoad: { loads += 1 }))

        let before = try moveTheCamera(in: window)
        let beforeID = ObjectIdentifier(try eventView(in: window))

        box.segment = .canvas
        pump()
        box.segment = .tree
        pump()

        let after = try eventView(in: window)
        XCTAssertEqual(ObjectIdentifier(after), beforeID)
        XCTAssertEqual(after.camera, before)
        XCTAssertEqual(loads, 1)
    }

    /// **A segment that is NOT the canvas still takes the centre column away**,
    /// which is the control for the two above: if `editorRoute` answered
    /// `.canvas` for everything, they would pass over a route that had stopped
    /// deciding anything.
    func test_leavingTheCanvasEntirelyDoesTakeItDown() throws {
        let root = try makeRoot()
        let box = SegmentBox(.canvas)
        var loads = 0
        let window = host(Harness(box: box, shape: .hoisted, root: root,
                                  model: CanvasModel(), onLoad: { loads += 1 }))
        XCTAssertEqual(loads, 1)

        box.segment = .research
        pump()
        let root2 = try XCTUnwrap(window.contentView)
        XCTAssertNil(firstDescendant(CanvasEventNSView.self, in: root2),
                     "the research segment puts the note editor in the centre, "
                     + "so the canvas must be gone")

        box.segment = .tree
        pump()
        XCTAssertEqual(loads, 2, "and coming back is a real remount, as it must be")
    }

}
