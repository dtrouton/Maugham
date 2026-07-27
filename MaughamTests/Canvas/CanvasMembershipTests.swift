import XCTest
@testable import Maugham

final class CanvasMembershipTests: XCTestCase {

    private let r1 = CanvasRegionID("r1")
    private let r2 = CanvasRegionID("r2")
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for (i, id) in [a, b].enumerated() {
            s.insert(CanvasNode(id: id, kind: .scrap,
                                origin: CGPoint(x: CGFloat(i) * 50, y: 0),
                                width: 240, cachedHeight: 80))
        }
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        s.insertRegion(CanvasRegion(id: r2, label: "Falls",
                                    frame: CGRect(x: 800, y: 0, width: 600, height: 400)))
        return s
    }

    // MARK: - The geometry firewall

    /// §4.2: coordinates never ADD a member.
    func test_movingANodeIntoARegionsRectDoesNotJoinIt() {
        var s = scene()
        XCTAssertFalse(s.region(r1)!.livesHere(b),
                       "precondition: 'b' already sits geometrically inside r1 and "
                       + "was never joined — so the assertion below is about the "
                       + "MOVE and not about the starting state")
        s.move(b, to: CGPoint(x: 100, y: 100))
        XCTAssertFalse(s.region(r1)!.livesHere(b), "geometry must never add a member")
    }

    /// §4.2: coordinates never REMOVE one. This is the tether's whole reason.
    func test_movingAMemberOutsideItsRegionDoesNotRemoveIt() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.move(a, to: CGPoint(x: 5_000, y: 5_000))
        XCTAssertTrue(s.region(r1)!.livesHere(a))
    }

    /// tldraw #6017, which ships this bug *despite* storing membership.
    func test_resizingARegionNeverEjectsMembers() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.setRegionFrame(CGRect(x: 0, y: 0, width: CanvasRegionMetrics.minimumSide,
                                height: CanvasRegionMetrics.minimumSide), for: r1)
        XCTAssertTrue(s.region(r1)!.livesHere(a))
    }

    func test_movingARegionAwayFromItsMembersKeepsThem() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.setRegionFrame(CGRect(x: 9_000, y: 9_000, width: 600, height: 400), for: r1)
        XCTAssertTrue(s.region(r1)!.livesHere(a))
    }

    // MARK: - One home, many appearances

    func test_joiningASecondRegionMovesTheHomeRatherThanAddingOne() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.join(a, home: r2, in: &s)
        XCTAssertFalse(s.region(r1)!.livesHere(a))
        XCTAssertTrue(s.region(r2)!.livesHere(a))
        XCTAssertEqual(CanvasMembership.homeRegion(of: a, in: s), r2)
    }

    func test_aNodeMayAppearInAnyNumberOfRegions() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.addAppearance(a, to: r2, in: &s)
        XCTAssertEqual(CanvasMembership.homeRegion(of: a, in: s), r1)
        XCTAssertEqual(CanvasMembership.appearanceRegions(of: a, in: s), [r2])
    }

    /// A node cannot be both resident and visitor in ONE region — the renderer
    /// would draw it as a card and as a chip at once, and §4.3 says an
    /// appearance must not render identically to the thing itself.
    func test_aNodeIsNeverBothAResidentAndAVisitorInTheSameRegion() {
        var s = scene()
        CanvasMembership.addAppearance(a, to: r1, in: &s)
        CanvasMembership.join(a, home: r1, in: &s)
        XCTAssertTrue(s.region(r1)!.livesHere(a))
        XCTAssertFalse(s.region(r1)!.appearsHere(a))

        CanvasMembership.addAppearance(a, to: r1, in: &s)
        XCTAssertTrue(s.region(r1)!.livesHere(a),
                      "citing the region a node already lives in is a no-op, not a demotion")
        XCTAssertFalse(s.region(r1)!.appearsHere(a))
    }

    func test_leavingClearsBothKindsOfMembershipInThatRegionOnly() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.addAppearance(a, to: r2, in: &s)
        CanvasMembership.leave(a, from: r1, in: &s)
        XCTAssertNil(CanvasMembership.homeRegion(of: a, in: s))
        XCTAssertEqual(CanvasMembership.appearanceRegions(of: a, in: s), [r2],
                       "leaving one region must not touch another")
    }

    // MARK: - What travels

    func test_onlyResidentsTravelWithTheirRegion() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        XCTAssertEqual(CanvasMembership.residents(of: r1, in: s), [a],
                       "a visitor is not luggage (§4.3)")
    }

    func test_aResidentWhoseNodeIsGoneDoesNotTravel() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.updateRegion(r1) { $0.addHome(CanvasNodeID("ghost")) }
        XCTAssertEqual(CanvasMembership.residents(of: r1, in: s), [a],
                       "residents() answers about NODES, so a stale id cannot make "
                       + "the drag loop reach for a node that is not there")
    }

    // MARK: - Deleting a node

    func test_removingANodeScrubsItFromEveryRegion() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.addAppearance(a, to: r2, in: &s)
        s.remove(a)
        XCTAssertFalse(s.region(r1)!.livesHere(a))
        XCTAssertFalse(s.region(r2)!.appearsHere(a),
                       "a ghost member would resurface in the inspector's list and "
                       + "in RegionBinding.references(forPiece:)")
    }

    func test_removingARegionLeavesItsCardsOnTheCanvas() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.removeRegion(r1)
        XCTAssertNotNil(s.node(a), "deleting a region never deletes cards")
        XCTAssertNil(CanvasMembership.homeRegion(of: a, in: s))
    }

    // MARK: - Collapse hides residents, in the scene

    func test_aResidentOfACollapsedRegionIsNotHitTestable() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        let inside = CGPoint(x: 10, y: 10)
        XCTAssertEqual(s.topmostNode(at: inside)?.id, a, "precondition: it is hit-testable now")
        s.updateRegion(r1) { $0.isCollapsed = true }
        XCTAssertNil(s.topmostNode(at: inside))
        XCTAssertTrue(s.isHidden(a))
    }

    func test_aVisitorToACollapsedRegionIsStillOnTheCanvas() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        s.updateRegion(r1) { $0.isCollapsed = true }
        XCTAssertFalse(s.isHidden(b),
                       "a visitor's card lives somewhere else — collapsing the "
                       + "region that cites it must not make the real thing vanish")
    }

    func test_aHiddenResidentIsNotDrawnAndIsStillMeasured() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.updateRegion(r1) { $0.isCollapsed = true }
        let everywhere = CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000)
        XCTAssertFalse(s.nodes(intersecting: everywhere).contains { $0.id == a })
        XCTAssertTrue(s.unorderedNodes.contains { $0.id == a },
                      "rebuildLayouts() walks unorderedNodes — stop measuring a "
                      + "hidden scrap and expanding the region shows unmeasured, "
                      + "unclickable cards")
    }

    func test_expandingARegionBringsItsResidentsBack() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.updateRegion(r1) { $0.isCollapsed = true }
        s.updateRegion(r1) { $0.isCollapsed = false }
        XCTAssertFalse(s.isHidden(a))
        XCTAssertEqual(s.topmostNode(at: CGPoint(x: 10, y: 10))?.id, a)
    }
}
