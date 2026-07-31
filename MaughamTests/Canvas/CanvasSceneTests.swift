import XCTest
@testable import Maugham

final class CanvasSceneTests: XCTestCase {

    private func scrap(_ id: String, x: CGFloat, y: CGFloat, z: Int = 0) -> CanvasNode {
        CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                   origin: CGPoint(x: x, y: y), width: 240, z: z)
    }

    func test_insertAndLookup_roundTrips() {
        var scene = CanvasScene()
        scene.insert(scrap("a", x: 10, y: 20))
        XCTAssertEqual(scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 10, y: 20))
        XCTAssertNil(scene.node(CanvasNodeID("nope")))
    }

    func test_move_changesOriginOnly() {
        var scene = CanvasScene()
        scene.insert(scrap("a", x: 0, y: 0))
        scene.move(CanvasNodeID("a"), to: CGPoint(x: 100, y: 50))
        let n = scene.node(CanvasNodeID("a"))
        XCTAssertEqual(n?.origin, CGPoint(x: 100, y: 50))
        XCTAssertEqual(n?.width, 240, "move must not disturb the authoritative width")
    }

    func test_setWidth_clearsTheDerivedHeight() {
        var scene = CanvasScene()
        scene.insert(scrap("a", x: 0, y: 0))
        scene.setCachedHeight(80, for: CanvasNodeID("a"))
        scene.setWidth(300, for: CanvasNodeID("a"))
        XCTAssertEqual(scene.node(CanvasNodeID("a"))?.width, 300)
        XCTAssertNil(try XCTUnwrap(scene.node(CanvasNodeID("a"))).cachedHeight,
                     "a rewrapped scrap must be re-measured before it is hit-tested")
    }

    func test_topmostNodeAt_prefersHigherZ() {
        var scene = CanvasScene()
        scene.insert(scrap("low", x: 0, y: 0, z: 1))
        scene.insert(scrap("high", x: 0, y: 0, z: 9))
        scene.setCachedHeight(80, for: CanvasNodeID("low"))
        scene.setCachedHeight(80, for: CanvasNodeID("high"))
        XCTAssertEqual(scene.topmostNode(at: CGPoint(x: 5, y: 5))?.id, CanvasNodeID("high"))
    }

    func test_topmostNodeAt_missesOutsideAnyNode() {
        var scene = CanvasScene()
        scene.insert(scrap("a", x: 0, y: 0))
        scene.setCachedHeight(80, for: CanvasNodeID("a"))
        XCTAssertNil(scene.topmostNode(at: CGPoint(x: 900, y: 900)))
    }

    func test_nodeWithoutCachedHeight_isNotHitTestable() {
        var scene = CanvasScene()
        scene.insert(scrap("a", x: 0, y: 0))
        XCTAssertNil(scene.topmostNode(at: CGPoint(x: 5, y: 5)),
                     "an unmeasured node has no height and must not swallow clicks")
    }

    func test_remove_dropsTheNode() {
        var scene = CanvasScene()
        scene.insert(scrap("a", x: 0, y: 0))
        scene.remove(CanvasNodeID("a"))
        XCTAssertNil(scene.node(CanvasNodeID("a")))
    }

    func test_topZ_isTheHighestZOrZeroOnAnEmptyScene() {
        var scene = CanvasScene()
        XCTAssertEqual(scene.topZ, 0)
        scene.insert(scrap("a", x: 0, y: 0, z: 4))
        scene.insert(scrap("b", x: 0, y: 0, z: 2))
        XCTAssertEqual(scene.topZ, 4)
    }

    /// `nodes` sorts on every access. `count` and `unorderedNodes` exist so that
    /// callers running inside `body` or a draw loop do not have to.
    func test_countAndUnorderedNodesDoNotDependOnTheSortedList() {
        var scene = CanvasScene()
        for i in 0..<20 { scene.insert(scrap("n\(i)", x: CGFloat(i), y: 0, z: 20 - i)) }
        XCTAssertEqual(scene.count, 20)
        XCTAssertEqual(Set(scene.unorderedNodes.map(\.id)),
                       Set(scene.nodes.map(\.id)),
                       "unorderedNodes must be the same SET, only unsorted")
    }

    /// Culling and hit testing filter first and order the survivors. That must
    /// not change the answer — the front-most card is still the front-most card.
    func test_filterFirstOrderingMatchesTheDrawOrder() {
        var scene = CanvasScene()
        for (i, z) in [7, 2, 9, 2, 5].enumerated() {
            scene.insert(scrap("n\(i)", x: 0, y: 0, z: z))
            scene.setCachedHeight(80, for: CanvasNodeID("n\(i)"))
        }
        let all = CGRect(x: -1000, y: -1000, width: 4000, height: 4000)
        XCTAssertEqual(scene.nodes(intersecting: all).map(\.id), scene.nodes.map(\.id),
                       "culling must return draw order, back to front")
        XCTAssertEqual(scene.topmostNode(at: CGPoint(x: 5, y: 5))?.id,
                       scene.nodes.last?.id,
                       "the hit test must agree with the draw order about which "
                       + "card is in front — including the id tiebreak at equal z")
    }

    // MARK: - The item id namespace
    //
    // 1C-a renders item nodes as placeholders and 1C-d completes them, but the
    // ID SPELLING is consumed by 1C-b and 1C-c and is pinned here.

    func test_itemNodeIDEncodesItsReference() {
        XCTAssertEqual(CanvasNodeID.item("r-9").raw, "item:r-9")
    }

    func test_itemAndScrapWithTheSameRawStringDoNotCollide() {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: .item("r-9"), kind: .item(.project(id: "r-9")),
                                origin: .zero, width: 180))
        scene.insert(CanvasNode(id: CanvasNodeID("r-9"), kind: .scrap,
                                origin: .zero, width: 240))
        XCTAssertEqual(scene.nodes.count, 2)
    }

    // MARK: - Card metrics

    func test_textWidthIsTheCardWidthLessBothInsets() {
        XCTAssertEqual(CanvasCardMetrics.textWidth(forCardWidth: 240),
                       240 - CanvasCardMetrics.inset * 2)
    }

    func test_textWidthNeverCollapsesBelowTheMinimum() {
        XCTAssertEqual(CanvasCardMetrics.textWidth(forCardWidth: 4),
                       CanvasCardMetrics.minimumTextWidth)
    }

    func test_cardHeightAndTextSizeAreInverses() {
        let cardHeight = CanvasCardMetrics.cardHeight(forTextHeight: 88)
        let frame = CGRect(x: 10, y: 20, width: 240, height: cardHeight)
        XCTAssertEqual(CanvasCardMetrics.textSize(inCard: frame).height, 88, accuracy: 0.0001)
        XCTAssertEqual(CanvasCardMetrics.textSize(inCard: frame).width,
                       CanvasCardMetrics.textWidth(forCardWidth: 240), accuracy: 0.0001)
    }

    func test_textOriginIsInsetFromTheCardOrigin() {
        let frame = CGRect(x: 10, y: 20, width: 240, height: 100)
        XCTAssertEqual(CanvasCardMetrics.textOrigin(inCard: frame),
                       CGPoint(x: 10 + CanvasCardMetrics.inset, y: 20 + CanvasCardMetrics.inset))
    }
}
