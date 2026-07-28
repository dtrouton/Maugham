import XCTest
@testable import Maugham

final class CanvasRegionCodecTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-region-codec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func sidecarURL() -> URL {
        root.appendingPathComponent(CanvasStore.sidecarRelativePath)
    }

    private func writeSidecar(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: sidecarURL().deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: sidecarURL(), atomically: true, encoding: .utf8)
    }

    private func sceneWithOneOfEverything() -> CanvasScene {
        var s = CanvasScene()
        for id in ["a", "b"] {
            s.insert(CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                                origin: CGPoint(x: 10, y: 20), width: 240, cachedHeight: 80))
        }
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 10, y: 20, width: 300, height: 200),
                                    homeMembers: [CanvasNodeID("a")],
                                    appearances: [CanvasNodeID("b")],
                                    boundPieceID: "piece-3",
                                    isCollapsed: true))
        return s
    }

    func test_everyFieldOfARegionSurvivesADiskRoundTrip() {
        CanvasStore(projectRoot: root).save(scene: sceneWithOneOfEverything(), scraps: [:])
        let r = CanvasStore(projectRoot: root).load().scene.region(CanvasRegionID("r1"))
        XCTAssertEqual(r?.label, "Act II fog")
        XCTAssertEqual(r?.frame, CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(r?.homeMembers, [CanvasNodeID("a")])
        XCTAssertEqual(r?.appearances, [CanvasNodeID("b")])
        XCTAssertEqual(r?.boundPieceID, "piece-3")
        XCTAssertEqual(r?.isCollapsed, true)
    }

    func test_theSidecarIsByteIdenticalAcrossTwoSavesOfOneScene() throws {
        let scene = sceneWithOneOfEverything()
        CanvasStore(projectRoot: root).save(scene: scene, scraps: [:])
        let first = try Data(contentsOf: sidecarURL())
        CanvasStore(projectRoot: root).save(scene: scene, scraps: [:])
        XCTAssertEqual(first, try Data(contentsOf: sidecarURL()),
                       "membership is held in Sets, whose iteration order is not "
                       + "stable across runs — the encoder must sort")
    }

    /// The test above re-reads the SAME `CanvasScene` value both times, so the
    /// same `Set` buffer backs `homeMembers`/`appearances` on both saves — its
    /// iteration order is deterministic within one process regardless of
    /// whether the encoder sorts, so it cannot actually catch a missing
    /// `.sorted()` (confirmed empirically while building this task: removing
    /// `.sorted()` left it green). This test checks the sortedness directly,
    /// independent of Set-internal iteration order, by feeding in enough
    /// scrambled elements that an unsorted hash-bucket order matching
    /// alphabetical order by chance is negligible.
    func test_regionMembershipArraysAreWrittenSortedRegardlessOfSetIterationOrder() throws {
        var s = CanvasScene()
        s.insertRegion(CanvasRegion(
            id: CanvasRegionID("r1"), label: "X",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10),
            homeMembers: Set(["f", "a", "d", "b", "e", "c"].map(CanvasNodeID.init)),
            appearances: Set(["z", "w", "y", "v", "x", "u"].map(CanvasNodeID.init))))
        CanvasStore(projectRoot: root).save(scene: s, scraps: [:])
        let dto = try JSONDecoder().decode(
            CanvasSceneDTO.self, from: try Data(contentsOf: sidecarURL()))
        let region = dto.regions?.first { $0.id == "r1" }
        XCTAssertEqual(region?.homeMembers, ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(region?.appearances, ["u", "v", "w", "x", "y", "z"])
    }

    /// A sidecar written by 1C-a has no `regions` key at all.
    func test_aSchemaV1SidecarLoadsItsNodesAndNoRegions() throws {
        try writeSidecar("""
        {"schemaVersion":1,"nodes":[{"id":"a","kind":"scrap","x":5,"y":6,\
        "width":240,"cachedHeight":80,"z":1}]}
        """)
        let scene = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(scene.count, 1)
        XCTAssertEqual(scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 5, y: 6))
        XCTAssertEqual(scene.regionCount, 0)
    }

    /// The forward-compatibility promise the schema-3 bump makes to every
    /// canvas 1C-b wrote: a schema-2 file — no `lines` key at all — carrying
    /// REAL, populated regions (not `test_aSchemaV1SidecarLoadsItsNodesAndNoRegions`'s
    /// empty case) still decodes those regions intact, regardless of how many
    /// bumps `currentSchemaVersion` has taken since (now 4, 1C-c2's
    /// `promotedItemID`). The version literal itself is asserted once, in
    /// `CanvasLineCodecTests.test_theSchemaVersionIsFour` — this test's job is
    /// the region content surviving the bump, not the number.
    func test_aSchemaV2SidecarsPopulatedRegionsSurviveTheBumpToSchemaThree() throws {
        try writeSidecar("""
        {"schemaVersion":2,"nodes":[{"id":"a","kind":"scrap","x":0,"y":0,\
        "width":240,"cachedHeight":80,"z":1},{"id":"b","kind":"scrap","x":50,"y":60,\
        "width":240,"cachedHeight":80,"z":1}],"regions":[\
        {"id":"r1","label":"Act II fog","x":10,"y":20,"width":300,"height":200,\
        "homeMembers":["a"],"appearances":["b"],"boundPieceID":"piece-3",\
        "isCollapsed":true}]}
        """)
        let r = CanvasStore(projectRoot: root).load().scene.region(CanvasRegionID("r1"))
        XCTAssertEqual(r?.label, "Act II fog")
        XCTAssertEqual(r?.frame, CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(r?.homeMembers, [CanvasNodeID("a")])
        XCTAssertEqual(r?.appearances, [CanvasNodeID("b")])
        XCTAssertEqual(r?.boundPieceID, "piece-3")
        XCTAssertEqual(r?.isCollapsed, true)
    }

    /// The repair, not the crash. Both regions claim 'a' as home.
    func test_twoRegionsClaimingOneHomeAreRepairedRatherThanTrusted() throws {
        try writeSidecar("""
        {"schemaVersion":2,"nodes":[{"id":"a","kind":"scrap","x":0,"y":0,\
        "width":240,"cachedHeight":80,"z":1}],"regions":[\
        {"id":"r2","label":"B","x":0,"y":0,"width":100,"height":100,\
        "homeMembers":["a"],"appearances":[],"isCollapsed":false},\
        {"id":"r1","label":"A","x":0,"y":0,"width":100,"height":100,\
        "homeMembers":["a"],"appearances":[],"isCollapsed":false}]}
        """)
        let scene = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(CanvasMembership.homeRegion(of: CanvasNodeID("a"), in: scene),
                       CanvasRegionID("r1"),
                       "first in id order keeps the home — and note the file lists "
                       + "r2 first, so a loader that merely took the first ENTRY "
                       + "would pass this by accident")
        XCTAssertEqual(CanvasMembership.appearanceRegions(of: CanvasNodeID("a"), in: scene),
                       [CanvasRegionID("r2")],
                       "demoted, not dropped: that region really did cite the node")
    }

    func test_membershipNamingANodeThatIsNotThereIsDropped() throws {
        try writeSidecar("""
        {"schemaVersion":2,"nodes":[],"regions":[\
        {"id":"r1","label":"A","x":0,"y":0,"width":100,"height":100,\
        "homeMembers":["ghost"],"appearances":["spectre"],"isCollapsed":false}]}
        """)
        let r = CanvasStore(projectRoot: root).load().scene.region(CanvasRegionID("r1"))
        XCTAssertEqual(r?.homeMembers, [])
        XCTAssertEqual(r?.appearances, [])
    }

    /// 1C-a's rule, restated because this task rewrites the loader around it: a
    /// node of an unknown kind is dropped and the rest of the canvas opens.
    func test_aNodeFromTheFutureIsDroppedAndTheRegionStillLoads() throws {
        try writeSidecar("""
        {"schemaVersion":2,"nodes":[{"id":"x","kind":"hologram","x":0,"y":0,\
        "width":240,"z":1}],"regions":[\
        {"id":"r1","label":"A","x":0,"y":0,"width":100,"height":100,\
        "homeMembers":["x"],"appearances":[],"isCollapsed":false}]}
        """)
        let scene = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(scene.count, 0)
        XCTAssertEqual(scene.regionCount, 1)
        XCTAssertEqual(scene.region(CanvasRegionID("r1"))?.homeMembers, [],
                       "the scrub has to run AFTER the nodes are decoded, or a "
                       + "dropped node leaves a member behind")
    }

    /// The forward-compat failure, stated so it is a decision and not a surprise.
    func test_aSidecarFromTheFutureCostsTheLayoutAndNotTheWords() throws {
        try writeSidecar("""
        {"schemaVersion":99,"nodes":[{"id":"a","kind":"scrap","x":5,"y":6,\
        "width":240,"cachedHeight":80,"z":1}]}
        """)
        try "\(ScrapText.banner)\n\n## a\n\nthe falls at night\n"
            .write(to: root.appendingPathComponent(CanvasStore.scrapsRelativePath),
                   atomically: true, encoding: .utf8)
        let loaded = CanvasStore(projectRoot: root).load()
        XCTAssertEqual(loaded.scene.count, 0)
        XCTAssertEqual(loaded.scraps[CanvasNodeID("a")], "the falls at night")
    }
}
