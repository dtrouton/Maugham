import XCTest
@testable import Maugham

/// The promoted mark, across the disk boundary. Schema 4 (1C-c2's
/// `promotedItemID`) was additive-optional in BOTH directions, which is the
/// pattern every canvas bump has kept, schema 5 (1C-c2a's `boundPieceID`) and
/// schema 6 (1C-c2b's `contributedToItemID`) included: an older sidecar
/// decodes unchanged, and a newer one costs an older build the arrangement
/// and never the words (`CanvasStore.load`).
final class CanvasPromotionCodecTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let r1 = CanvasRegionID("r1")

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 10, y: 20),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [a]))
        return s
    }

    private func roundTrip(_ s: CanvasScene) throws -> CanvasScene {
        let data = try JSONEncoder().encode(CanvasSceneDTO(scene: s))
        return try JSONDecoder().decode(CanvasSceneDTO.self, from: data).scene
    }

    func test_theSchemaIsFourBecauseThisSliceAddedAField() {
        // 1C-c2's own field (`promotedItemID`) is schema 4; the literal moved
        // to 5 in 1C-c2a, which added `boundPieceID`, and to 6 in 1C-c2b,
        // which added `contributedToItemID` — see
        // `CanvasLineCodecTests.test_theSchemaVersionIsSix` for the other
        // assertion of the same literal.
        XCTAssertEqual(CanvasSceneDTO.currentSchemaVersion, 6)
    }

    func test_aPromotedScrapKeepsItsArtifactAcrossASaveAndLoad() throws {
        var s = scene()
        s.setPromotedItem("res-9", for: a)
        XCTAssertEqual(try roundTrip(s).node(a)?.promotedItemID, "res-9")
    }

    func test_aPromotedRegionKeepsItsArtifactAcrossASaveAndLoad() throws {
        var s = scene()
        s.updateRegion(r1) { $0.promotedItemID = "res-fog" }
        XCTAssertEqual(try roundTrip(s).region(r1)?.promotedItemID, "res-fog")
    }

    func test_theMarkCanBeTakenOffAgain() throws {
        var s = scene()
        s.setPromotedItem("res-9", for: a)
        s.setPromotedItem(nil, for: a)
        XCTAssertNil(try roundTrip(s).node(a)?.promotedItemID)
    }

    /// A schema-3 sidecar — every canvas 1C-c1 wrote — decodes unchanged rather
    /// than throwing on a missing key. The fixture is a LITERAL, not a re-encode
    /// of today's DTO: a test that writes its own input cannot see a key that
    /// stopped being optional.
    func test_aSchemaThreeSidecarDecodesWithNoMarksAndLosesNothingElse() throws {
        let json = """
        {"schemaVersion":3,
         "nodes":[{"id":"a","kind":"scrap","x":10,"y":20,"width":240,
                   "cachedHeight":80,"z":0}],
         "regions":[{"id":"r1","label":"Act II fog","x":0,"y":0,"width":600,
                     "height":400,"homeMembers":["a"],"appearances":[],
                     "isCollapsed":false}],
         "lines":[]}
        """
        let decoded = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8))
        let s = decoded.scene
        XCTAssertNil(s.node(a)?.promotedItemID)
        XCTAssertNil(s.region(r1)?.promotedItemID)
        XCTAssertEqual(s.node(a)?.width, 240, "the rest of the file must survive the bump")
        XCTAssertEqual(s.region(r1)?.homeMembers, [a])
    }

    /// An unpromoted canvas's sidecar must not gain a key. MEASURED rather than
    /// asserted from Codable's synthesis rules: if this ever starts writing
    /// `"promotedItemID":null` on every node, every writer's next save is a
    /// whole-file diff for a feature they have not used.
    func test_anUnpromotedCanvasWritesNoPromotedKeyAtAll() throws {
        let data = try JSONEncoder().encode(CanvasSceneDTO(scene: scene()))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("promotedItemID"), "found it in: \(text)")
    }

    /// The loader drops a node of an unknown kind (a canvas from a newer build).
    /// Its mark goes with it — there is nothing left for the mark to be about.
    func test_aMarkOnADroppedNodeGoesWithTheNode() throws {
        let json = """
        {"schemaVersion":4,
         "nodes":[{"id":"ghost","kind":"hologram","x":0,"y":0,"width":100,"z":0,
                   "promotedItemID":"res-ghost"}],
         "regions":[],"lines":[]}
        """
        let s = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8)).scene
        XCTAssertTrue(s.isEmpty)
    }
}
