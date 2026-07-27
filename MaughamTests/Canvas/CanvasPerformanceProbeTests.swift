import XCTest
@testable import Maugham

final class CanvasPerformanceProbeTests: XCTestCase {

    /// The bound spec §10 asked for. Far above any real canvas (a Playlist-scale
    /// collection is tens of nodes) and below where tldraw (4,000) and
    /// Excalidraw (~5,000) degrade.
    static let supportedNodeCount = 2_000

    /// A FIXED 20-column grid, so the grid's extent in both axes is independent
    /// of the node count. Cards are 240x100 on a 300x200 pitch, so a 1200x800
    /// viewport at zoom 1 covers content rect (0,0,1200,800) — but
    /// `CanvasRenderer.visibleNodes` insets that by `cullingBleed` (12pt) on
    /// every side before intersecting, so the QUERY rect is actually
    /// (-12,-12,1224,824). That extra bleed is enough to catch the edge-contact
    /// column at x=1200 ([1200,1440), now overlapping up to x=1212) and the
    /// edge-contact row at y=800 ([800,900), now overlapping up to y=812) — so
    /// the true admitted set is columns x=0,300,600,900,1200 and rows
    /// y=0,200,400,600,800, i.e. **5 x 5 = 25 nodes**, not the 4 x 4 = 16 an
    /// earlier draft computed against the bare camera viewport without the
    /// renderer's own bleed. `test_theFixtureCoversTheViewportAtEveryScaleUnderTest`
    /// caught the discrepancy (asserted 16, measured 25) — fixed here rather
    /// than in the renderer, which is behaving exactly as `cullingBleed`'s own
    /// doc comment says it should. Holds for ANY node count of 100 or more (5
    /// rows × 20 columns). If the columns were derived from the count, a bigger
    /// scene would be a taller grid and the culling assertion below would
    /// compare two different geometries.
    private static let columns = 20

    private func bigScene(_ count: Int) -> CanvasScene {
        var s = CanvasScene()
        for i in 0..<count {
            var n = CanvasNode(id: CanvasNodeID("n\(i)"), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i % Self.columns) * 300,
                                               y: CGFloat(i / Self.columns) * 200),
                               width: 240)
            n.cachedHeight = 100
            s.insert(n)
        }
        return s
    }

    private let viewSize = CGSize(width: 1200, height: 800)

    /// Guard the fixture itself. If this fails, the culling assertion below is
    /// comparing two different pictures and its result means nothing.
    func test_theFixtureCoversTheViewportAtEveryScaleUnderTest() {
        for count in [200, Self.supportedNodeCount] {
            XCTAssertEqual(
                CanvasRenderer.visibleNodes(in: bigScene(count), camera: CanvasCamera(),
                                            viewSize: viewSize).count,
                25, "the \(count)-node fixture does not fill the viewport as computed")
        }
    }

    /// The property §7A.1 depends on: the drawn set is proportional to the
    /// VIEWPORT, not to the scene.
    ///
    /// **This is an OUTPUT-INVARIANCE assertion, not a complexity one**, and an
    /// earlier draft of this comment claimed otherwise. It compares only the
    /// output COUNT at two scene sizes, so what it honestly pins is that culling
    /// happens at all and that its result does not grow with the scene — a
    /// "return everything" or a count-grows-with-scene regression is caught, and
    /// 200 vs 2,000 is unmistakably far enough apart for that.
    ///
    /// What it CANNOT see: `CanvasScene.nodes(intersecting:)` filters
    /// `byID.values` before it sorts, so an O(scene) linear scan happens on
    /// every call and is unavoidable — there is no spatial index. This test is
    /// blind to that cost by construction. Algorithmic complexity is not pinned
    /// here or anywhere; see `AREA.md` beside `supportedNodeCount` for what the
    /// timing probes below do and do not defend.
    ///
    /// It is deliberately not a wall-clock assertion — a millisecond budget on
    /// CI hardware is a flaky test that gets disabled and then protects nothing
    /// (TypingLatencyProbeTests is the house precedent).
    func test_culledSetDependsOnViewportNotSceneSize() {
        let small = CanvasRenderer.visibleNodes(in: bigScene(200), camera: CanvasCamera(),
                                                viewSize: viewSize).count
        let large = CanvasRenderer.visibleNodes(in: bigScene(Self.supportedNodeCount),
                                                camera: CanvasCamera(),
                                                viewSize: viewSize).count
        XCTAssertEqual(small, large,
                       "a 10x larger scene must not draw more nodes at the same "
                       + "camera — culling is the whole of virtualisation")
    }

    func test_aFullSceneStillCullsToAHandful() {
        let visible = CanvasRenderer.visibleNodes(in: bigScene(Self.supportedNodeCount),
                                                  camera: CanvasCamera(),
                                                  viewSize: viewSize)
        XCTAssertLessThan(visible.count, 60)
    }

    /// A fixture-gated probe: measured, reported, and only failed on an
    /// order-of-magnitude regression.
    func test_cullingAtTheSupportedBoundIsNotPathological() {
        let scene = bigScene(Self.supportedNodeCount)
        let camera = CanvasCamera()

        let start = Date()
        for _ in 0..<60 {
            _ = CanvasRenderer.visibleNodes(in: scene, camera: camera, viewSize: viewSize)
        }
        let perFrame = Date().timeIntervalSince(start) / 60 * 1000
        print("[probe] cull of \(Self.supportedNodeCount) nodes: \(String(format: "%.3f", perFrame)) ms/frame")

        // 8ms is half a 60Hz frame spent purely culling — an absurd budget that
        // only an algorithmic regression (an accidental O(n²)) could exceed.
        XCTAssertLessThan(perFrame, 8.0,
                          "culling got dramatically slower — suspect an O(n²) in "
                          + "CanvasScene.nodes or a lost early-out")
    }

    func test_zoomingOutFarStillTerminatesQuickly() {
        let scene = bigScene(Self.supportedNodeCount)
        var camera = CanvasCamera()
        camera.zoom = CanvasCamera.zoomRange.lowerBound
        let start = Date()
        let visible = CanvasRenderer.visibleNodes(in: scene, camera: camera, viewSize: viewSize)
        print("[probe] zoomed-out cull returned \(visible.count) nodes in "
              + "\(String(format: "%.3f", Date().timeIntervalSince(start) * 1000)) ms")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    /// Hit testing walks the same sorted list in reverse and runs on every
    /// click. A regression here is felt directly.
    func test_hitTestingAtTheSupportedBoundIsNotPathological() {
        let scene = bigScene(Self.supportedNodeCount)
        let start = Date()
        for _ in 0..<60 { _ = scene.topmostNode(at: CGPoint(x: 610, y: 410)) }
        let perClick = Date().timeIntervalSince(start) / 60 * 1000
        print("[probe] hit test over \(Self.supportedNodeCount) nodes: \(String(format: "%.3f", perClick)) ms")
        XCTAssertLessThan(perClick, 8.0)
    }
}
