import XCTest
import MaughamCore
@testable import Maugham

/// Where Claude's nodes go.
///
/// Every assertion here is about a *placement* rather than about a coordinate:
/// the planner is the canvas's answer to "where does this land", and Claude can
/// express no position at all (plan ruling 1), so the numbers are the canvas's
/// to change. Pinning them to literals would make a calibration pass red for no
/// reason. What must not change is that the region lands clear of the writer's
/// work, the cards do not sit on top of one another, the page sits above what
/// was read off it, and the same request twice places the same way.
///
/// `test_planningNeverMutatesTheScene` is `PromotionTests`' assertion by name,
/// for the same reason: `Promotion` never mutates and `PromotionPerformer` does,
/// and `Maugham/Canvas/AREA.md` calls the line between them load-bearing.
final class CanvasClaudePlacementTests: XCTestCase {

    // MARK: - Fixtures

    /// Three measured cards and a region, all of them the writer's — the scene
    /// Claude's region has to keep off.
    private func writersCanvas() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("aaaa1111"), kind: .scrap,
                            origin: CGPoint(x: 0, y: 0), width: 240, cachedHeight: 60))
        s.insert(CanvasNode(id: CanvasNodeID("bbbb2222"), kind: .scrap,
                            origin: CGPoint(x: 300, y: 120), width: 240, cachedHeight: 90))
        s.insert(CanvasNode(id: CanvasNodeID("cccc3333"), kind: .scrap,
                            origin: CGPoint(x: 120, y: 400), width: 240, cachedHeight: 40))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II",
                                    frame: CGRect(x: 80, y: 360, width: 400, height: 200)))
        return s
    }

    private let threeScraps = [
        "The fog came in off the water and stayed for three days.",
        "October's doctor arrives on the last train, which is the only train.",
        "The falls at night: sound first, then the cold off them, then nothing."
    ]

    private func everyExistingFrame(in scene: CanvasScene) -> [CGRect] {
        scene.unorderedNodes.compactMap(\.frame) + scene.regions.map(\.frame)
    }

    // MARK: - Purity

    /// The whole reason `plan` and `apply` are two functions. A planner that
    /// mutated as it decided could not be asked twice, could not be previewed,
    /// and could not be shared by Task 5's two persistence routes without each
    /// one getting a slightly different scene.
    func test_planningNeverMutatesTheScene() {
        let before = writersCanvas()
        let s = before

        _ = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: threeScraps), in: s)
        _ = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: threeScraps,
                                          sourceReferenceID: "res-notebook-p3",
                                          regionLabel: "Notebook p3",
                                          connections: [(0, 2)]), in: s)

        XCTAssertEqual(s, before,
                       "planning is a function of its inputs — `Promotion` never "
                       + "mutates and neither may this")
    }

    // MARK: - Placement

    /// Claude's region goes to the right of everything already on the canvas,
    /// and CLEAR of it rather than merely not on top of it.
    ///
    /// The one-point expansion is the load-bearing half. `CGRect.intersects` is
    /// false for rects that merely touch, so a region abutting the writer's
    /// rightmost card would satisfy a plain non-intersection assertion while
    /// reading, on screen, as a card wedged into a region's edge. Expanding by a
    /// single point — deliberately not by the gutter constant, which would make
    /// this a restatement of the implementation — asks for clearance instead.
    func test_theRegionLandsClearOfEverythingAlreadyOnTheCanvas() {
        let scene = writersCanvas()
        let plan = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: threeScraps,
                                          sourceReferenceID: "res-notebook-p3"), in: scene)

        for frame in everyExistingFrame(in: scene) {
            XCTAssertFalse(plan.regionFrame.intersects(frame),
                           "the planned region \(plan.regionFrame) sits on top of "
                           + "\(frame), which the writer put there")
            XCTAssertFalse(plan.regionFrame.insetBy(dx: -1, dy: -1).intersects(frame),
                           "the planned region \(plan.regionFrame) abuts \(frame) — "
                           + "touching is not clear, and this is the gutter's job")
        }
    }

    /// What Task 2's real heights buy. Estimated heights place a long scrap's
    /// neighbour inside it, and the failure is invisible until a writer reads a
    /// card whose bottom two lines are under the next one.
    func test_theCardsDoNotOverlapEachOther() {
        let long = String(repeating: "The fog came in off the water and stayed. ", count: 8)
        let plan = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: [long, "Fog.", long, "Rain."]),
            in: CanvasScene())

        let frames = plan.scraps.map { $0.node.frame }
        XCTAssertEqual(frames.compactMap { $0 }.count, 4,
                       "every planned card carries a real height — a node with no "
                       + "`cachedHeight` has no frame, and is neither drawn nor clickable")

        for (i, a) in frames.enumerated() {
            for (j, b) in frames.enumerated() where j > i {
                guard let a, let b else { continue }
                XCTAssertFalse(a.intersects(b), "card \(i) at \(a) overlaps card \(j) at \(b)")
            }
        }
    }

    /// Spec §8A.2's reproduction corollary in the only form a planner can serve
    /// it: reading order puts the page above what was read off it, so "what was
    /// read off this page" is answerable by looking rather than by clicking.
    func test_theSourcePageIsAboveWhatWasReadOffIt() {
        let plan = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: threeScraps,
                                          sourceReferenceID: "res-notebook-p3"),
            in: CanvasScene())

        guard let source = plan.source?.createdNode else {
            return XCTFail("a source that is not already on the canvas is created here")
        }
        XCTAssertEqual(plan.scraps.count, 3)
        for scrap in plan.scraps {
            XCTAssertLessThan(source.origin.y, scrap.node.origin.y,
                              "the page belongs above the scraps read off it")
        }
    }

    /// Both halves in one test so neither can be quietly dropped.
    ///
    /// The tint means *these words came off a machine*. The photograph is the
    /// writer's, so tinting its node would say Claude took the photograph — and
    /// it echoes the rule that an item node never carries a promoted stripe,
    /// because it already exists as itself.
    func test_theSourcePageCarriesNoAuthorAndTheScrapsDo() {
        let plan = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: threeScraps,
                                          sourceReferenceID: "res-notebook-p3",
                                          connections: [(0, 1)]),
            in: CanvasScene())

        for scrap in plan.scraps {
            XCTAssertEqual(scrap.node.author, .claude,
                           "a card whose words came off a machine says so")
        }
        for line in plan.lines {
            XCTAssertEqual(line.author, .claude,
                           "the arrows were read off the page too")
        }
        XCTAssertNil(plan.source?.createdNode?.author,
                     "the photograph is the writer's — tinting its node would say "
                     + "Claude took it")
    }

    /// One home, many appearances (§4.3), and the second add is the one that
    /// could have gone wrong: moving the writer's existing card into a new region
    /// would be a geometry-driven TRANSITION, which membership never is
    /// (tripwire 31).
    func test_addingTheSamePageTwiceMakesOneNode() {
        let reference = "res-notebook-p3"
        let itemID = CanvasNodeID.item(reference)
        var scene = CanvasScene()

        let first = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: threeScraps, sourceReferenceID: reference),
            in: scene)
        CanvasClaudePlacement.apply(first, to: &scene)
        let afterFirst = scene.count
        let pageOrigin = scene.node(itemID)?.origin

        XCTAssertEqual(afterFirst, 4, "three scraps and the page")

        let second = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: ["A fourth thing.", "A fifth."],
                                          sourceReferenceID: reference),
            in: scene)
        CanvasClaudePlacement.apply(second, to: &scene)

        XCTAssertEqual(scene.count, afterFirst + 2,
                       "the second add mints its scraps and reuses the page — "
                       + "`CanvasNodeID.item(_:)` derives the id from the reference "
                       + "precisely so two adds resolve to one node")
        XCTAssertEqual(scene.node(itemID)?.origin, pageOrigin,
                       "the page does not move; a new region cites it where it is")

        XCTAssertEqual(scene.region(first.regionID)?.livesHere(itemID), true,
                       "the first region still HOMES the page")
        XCTAssertEqual(scene.region(second.regionID)?.appearsHere(itemID), true,
                       "the second region CITES it")
        XCTAssertEqual(scene.region(second.regionID)?.livesHere(itemID), false,
                       "one home, many appearances — a second home would be the "
                       + "transition the whole membership design exists to refuse")

        for scrap in second.scraps {
            XCTAssertEqual(scene.region(second.regionID)?.livesHere(scrap.node.id), true,
                           "a scrap this call created lives in the region this call created")
        }
    }

    /// Determinism, ids excluded. Two identical calls against one scene must
    /// decide the same geometry, or a retry after a transport failure puts the
    /// same page in two different places.
    func test_theSameRequestPlacesIdenticallyTwice() {
        let scene = writersCanvas()
        func makeRequest() -> CanvasClaudePlacement.Request {
            CanvasClaudePlacement.Request(scraps: threeScraps,
                                          sourceReferenceID: "res-notebook-p3",
                                          regionLabel: "Notebook p3",
                                          connections: [(0, 2)])
        }

        let a = CanvasClaudePlacement.plan(makeRequest(), in: scene)
        let b = CanvasClaudePlacement.plan(makeRequest(), in: scene)

        XCTAssertEqual(a.regionFrame, b.regionFrame)
        XCTAssertEqual(a.regionLabel, b.regionLabel)
        XCTAssertEqual(a.source?.createdNode?.origin, b.source?.createdNode?.origin)
        XCTAssertEqual(a.scraps.map(\.text), b.scraps.map(\.text))
        XCTAssertEqual(a.scraps.map { $0.node.origin }, b.scraps.map { $0.node.origin })
        XCTAssertEqual(a.scraps.map { $0.node.cachedHeight }, b.scraps.map { $0.node.cachedHeight })
        XCTAssertEqual(a.lines.count, b.lines.count)
    }

    /// A region the writer could not have swept is a region the canvas should not
    /// mint either — so the floor is asserted against `CanvasInteraction`'s own
    /// refusal as well as against the constant.
    ///
    /// With today's padding and gap the natural size already clears the floor, so
    /// this pins the FLOOR rather than exercising the clamp: it is the assertion
    /// that goes red if a calibration pass ever tightens the padding far enough
    /// to mint a region the sweep gesture would have refused.
    func test_aRegionIsNeverSmallerThanOneTheWriterCouldSweep() {
        let plan = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: ["Fog."]), in: CanvasScene())

        XCTAssertGreaterThanOrEqual(plan.regionFrame.width, CanvasRegionMetrics.minimumSide)
        XCTAssertGreaterThanOrEqual(plan.regionFrame.height, CanvasRegionMetrics.minimumSide)

        var sweep = CanvasScene()
        XCTAssertNotNil(CanvasInteraction.createRegion(plan.regionFrame, in: &sweep),
                        "the sweep gesture would have accepted this rect; the canvas "
                        + "must not mint one it would have refused")
    }

    /// The plan is one value, and the words travel with the card that will hold
    /// them.
    ///
    /// The applier writes the sidecar and `canvas.md` from this; a text array
    /// handed alongside the plan would be a second chance for the nodes and the
    /// words to disagree about which scrap is which, and nothing downstream could
    /// tell which of the two was right.
    func test_thePlanCarriesEachCardsWordsWithTheCard() {
        let plan = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: threeScraps), in: CanvasScene())

        XCTAssertEqual(plan.scraps.map(\.text), threeScraps,
                       "the column is laid out in the request's own order")
        XCTAssertEqual(plan.scrapTexts.count, 3)
        for scrap in plan.scraps {
            XCTAssertEqual(plan.scrapTexts[scrap.node.id], scrap.text,
                           "the words the applier writes are keyed by the node that "
                           + "will hold them")
        }
    }

    /// `connect` indexes the call's OWN scraps, which is the structural half of
    /// plan ruling 1 — Claude can draw the arrows it read off a page and can
    /// reach nothing the writer made. Untested, the lines would be a built and
    /// unreachable half, which this area has shipped five of.
    func test_aConnectionBecomesALineBetweenTheTwoScrapsItNames() {
        var scene = CanvasScene()
        let plan = CanvasClaudePlacement.plan(
            CanvasClaudePlacement.Request(scraps: threeScraps, connections: [(0, 2)]),
            in: scene)

        XCTAssertEqual(plan.lines.count, 1)
        XCTAssertEqual(plan.lines.first?.from, plan.scraps.first?.node.id)
        XCTAssertEqual(plan.lines.first?.to, plan.scraps.last?.node.id)
        XCTAssertNil(plan.lines.first?.label,
                     "`connect` carries no label — a label from Claude on an edge is "
                     + "the nearest thing to the typed edge §5 rejects (plan ruling 2)")

        CanvasClaudePlacement.apply(plan, to: &scene)
        XCTAssertEqual(scene.lineCount, 1, "the line reaches the scene through `apply`")
    }
}
