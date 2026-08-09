import XCTest
import MaughamCore
@testable import Maugham

/// An item node's two provenances, across the disk boundary (1C-d, spec §3.1's
/// 2026-07-30 amendment).
///
/// **The sibling files are the other halves of this codec, not a duplication of
/// it** — `CanvasRegionCodecTests`, `CanvasLineCodecTests`,
/// `CanvasPromotionCodecTests` and `CanvasAuthorCodecTests` each hold the slice
/// that added their fact. This file holds `CanvasItemReference`. The schema
/// literal itself is asserted in `CanvasLineCodecTests.test_theSchemaVersionIsNine`
/// and is deliberately not repeated here — three sites rebump already.
///
/// Schema 8 is additive-optional in BOTH directions, which is the pattern every
/// canvas bump has kept: a schema-7 sidecar decodes unchanged, and a newer one
/// costs an older build the arrangement and never the words (`CanvasStore.load`).
final class CanvasSceneCodecTests: XCTestCase {

    private let scrap = CanvasNodeID("aaaa")
    private let ref = CanvasNodeID("item:res-7")
    private let owned = CanvasNodeID("bbbb")

    private func roundTrip(_ s: CanvasScene) throws -> CanvasScene {
        let data = try JSONEncoder().encode(CanvasSceneDTO(scene: s))
        return try JSONDecoder().decode(CanvasSceneDTO.self, from: data).scene
    }

    private func encoded(_ s: CanvasScene) throws -> Data {
        let encoder = JSONEncoder()
        // `CanvasStore.writeNow`'s own settings. Byte comparison is meaningless
        // against an encoder whose key order is per-process.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(CanvasSceneDTO(scene: s))
    }

    // MARK: - The control

    /// **The control for this whole file.** A schema-7 sidecar — every canvas
    /// written before 1C-d, and the only kind of item node anything has ever
    /// created — must decode to exactly the scene it decoded to before the
    /// nested reference existed: a `.project` item, with its id in the field
    /// named for it.
    ///
    /// The fixture is a LITERAL, not a re-encode of today's DTO. A test that
    /// writes its own input cannot see a key that stopped being optional, and it
    /// cannot see `referenceId` quietly becoming a second spelling of the owned
    /// path either.
    func test_aSchemaSevenSidecarStillDecodesItsItemNodeAsAProjectReference() throws {
        let json = """
        {"schemaVersion":7,
         "nodes":[{"id":"aaaa","kind":"scrap","x":10,"y":20,"width":240,
                   "cachedHeight":80,"z":0},
                  {"id":"item:res-7","kind":"item","referenceId":"res-7",
                   "x":300,"y":20,"width":240,"cachedHeight":31,"z":1}]}
        """
        let s = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8)).scene

        let item = try XCTUnwrap(s.node(ref), "the item node must survive the bump")
        XCTAssertEqual(item.kind, .item(.project(id: "res-7")))
        XCTAssertEqual(item.origin, CGPoint(x: 300, y: 20))
        XCTAssertEqual(item.cachedHeight, 31, "the rest of the node must survive too")
        XCTAssertEqual(try XCTUnwrap(s.node(scrap)).kind, .scrap)
        XCTAssertEqual(s.count, 2)
    }

    /// The other direction of the same control: a project reference is still
    /// WRITTEN into `referenceId`, so a schema-8 file this build produces is
    /// read correctly by any build that understands 7's node shape.
    func test_aProjectReferenceIsStillWrittenIntoTheFieldNamedForIt() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: ref, kind: .item(.project(id: "res-7")),
                            origin: CGPoint(x: 300, y: 20), width: 240, cachedHeight: 31))
        let dto = try JSONDecoder().decode(CanvasSceneDTO.self, from: try encoded(s))
        let node = try XCTUnwrap(dto.nodes.first)
        XCTAssertEqual(node.referenceId, "res-7")
        XCTAssertNil(node.ownedPath, "a project reference owns no file")
    }

    // MARK: - The owned path

    func test_anOwnedItemKeepsItsPathAcrossARoundTrip() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: owned,
                            kind: .item(.owned(path: "canvas_assets/photo-20260730-121314.png")),
                            origin: CGPoint(x: 40, y: 60), width: 240, cachedHeight: 31))

        let loaded = try XCTUnwrap(roundTrip(s).node(owned),
                                   "the node itself must survive, or the kind assertion "
                                   + "below is about a node that is not there")
        XCTAssertEqual(loaded.kind,
                       .item(.owned(path: "canvas_assets/photo-20260730-121314.png")))
        XCTAssertEqual(loaded.origin, CGPoint(x: 40, y: 60))
    }

    /// A schema-8 fixture written by hand, for the reason the control gives:
    /// the round-trip above is blind to a key this build both writes and reads
    /// under a name nothing else agrees on.
    func test_aSchemaEightSidecarDecodesAnOwnedItem() throws {
        let json = """
        {"schemaVersion":8,
         "nodes":[{"id":"bbbb","kind":"item",
                   "ownedPath":"canvas_assets/photo-20260730-121314.png",
                   "x":40,"y":60,"width":240,"cachedHeight":31,"z":2}]}
        """
        let s = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8)).scene
        let node = try XCTUnwrap(s.node(owned))
        XCTAssertEqual(node.kind,
                       .item(.owned(path: "canvas_assets/photo-20260730-121314.png")))
        XCTAssertEqual(node.z, 2)
    }

    /// Encode → decode → encode is byte-stable. A round trip that *reads* an
    /// owned node correctly and writes it back under a different shape still
    /// churns every writer's sidecar on every save, and the second save is where
    /// that becomes visible rather than the first.
    func test_anOwnedItemReEncodesByteIdentically() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: owned,
                            kind: .item(.owned(path: "canvas_assets/photo-20260730-121314.png")),
                            origin: CGPoint(x: 40, y: 60), width: 240, cachedHeight: 31, z: 2))
        let first = try encoded(s)
        let second = try encoded(try JSONDecoder().decode(CanvasSceneDTO.self, from: first).scene)
        XCTAssertEqual(first, second,
                       "wrote: \(String(decoding: second, as: UTF8.self))")
    }

    /// **The failure this slice's type exists to prevent, measured on the
    /// bytes.** A project-relative path in `referenceId` is a path wearing an
    /// item id's name: an older build reads it as a research item and draws
    /// `Item · canvas_assets/photo-….png`, and every reader that resolves a
    /// reference id against the manifest dangles.
    func test_anOwnedItemNeverWritesItsPathIntoTheReferenceIdField() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: owned,
                            kind: .item(.owned(path: "canvas_assets/photo-20260730-121314.png")),
                            origin: .zero, width: 240, cachedHeight: 31))
        let text = String(decoding: try encoded(s), as: UTF8.self)
        XCTAssertFalse(text.contains("referenceId"), "found it in: \(text)")
        XCTAssertTrue(text.contains("ownedPath"),
                      "the control: the path must actually have been written somewhere")
    }

    /// An unchanged canvas's sidecar must not grow. MEASURED on the bytes rather
    /// than inferred from Codable's synthesis rules — the same assertion
    /// `CanvasAuthorCodecTests` makes for `author`, for the same reason: if this
    /// ever starts writing `"ownedPath":null` on every node, every writer's next
    /// save is a whole-file diff for a feature they have not used.
    func test_aCanvasWithNoOwnedAssetsWritesNoOwnedPathKey() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: scrap, kind: .scrap, origin: .zero, width: 240,
                            cachedHeight: 80))
        s.insert(CanvasNode(id: ref, kind: .item(.project(id: "res-7")),
                            origin: CGPoint(x: 300, y: 0), width: 240, cachedHeight: 31))
        let text = String(decoding: try encoded(s), as: UTF8.self)
        XCTAssertFalse(text.contains("ownedPath"), "found it in: \(text)")
    }

    // MARK: - A DTO carrying both

    /// **Both fields set: the owned path WINS, and the node is KEPT.**
    ///
    /// Only a hand-edited sidecar can produce this, and the loader has to answer
    /// it because it cannot ask. Three things decide it, and the third is why
    /// the answer is not "drop the contradictory node":
    ///
    /// - An owned path is a claim about a file **this project owns**, so
    ///   honouring it cannot dangle into another project's namespace; honouring
    ///   the `referenceId` instead points a card at an id this file gives no
    ///   evidence for.
    /// - It is the precedent one function down. The loader's other contradiction
    ///   — a node claimed as home by two regions — **demotes** the loser rather
    ///   than dropping it, because inventing a relationship and discarding a
    ///   true one are both worse than recording the weaker one.
    /// - Dropping loses a card the writer can see, and a card that disappears is
    ///   the worst failure available on a spatial surface.
    func test_aNodeCarryingBothProvenancesIsKeptAndReadsAsOwned() throws {
        let json = """
        {"schemaVersion":8,
         "nodes":[{"id":"bbbb","kind":"item","referenceId":"res-7",
                   "ownedPath":"canvas_assets/photo-20260730-121314.png",
                   "x":40,"y":60,"width":240,"cachedHeight":31,"z":2}]}
        """
        let s = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8)).scene
        XCTAssertEqual(s.count, 1, "a contradictory node must not be dropped")
        XCTAssertEqual(try XCTUnwrap(s.node(owned)).kind,
                       .item(.owned(path: "canvas_assets/photo-20260730-121314.png")))
    }

    /// The rule above is about a node carrying BOTH, not about the loader having
    /// stopped dropping anything: an item node carrying NEITHER is still
    /// dropped, exactly as it was before this slice — there is nothing to draw
    /// and nothing to point at.
    ///
    /// The scrap is the control. Without it this passes just as happily when the
    /// whole file failed to decode.
    func test_anItemNodeWithNoProvenanceAtAllIsStillDropped() throws {
        let json = """
        {"schemaVersion":8,
         "nodes":[{"id":"aaaa","kind":"scrap","x":10,"y":20,"width":240,
                   "cachedHeight":80,"z":0},
                  {"id":"bbbb","kind":"item","x":40,"y":60,"width":240,
                   "cachedHeight":31,"z":2}]}
        """
        let s = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8)).scene
        XCTAssertNil(s.node(owned), "an item pointing at nothing has nothing to draw")
        XCTAssertEqual(try XCTUnwrap(s.node(scrap)).kind, .scrap,
                       "the control: the rest of the file decoded")
    }

    // MARK: - Everything else an owned node carries

    /// The bump is additive and nothing else about a node moved: a region that
    /// homes an owned item still homes it, and a line to one still draws.
    func test_anOwnedItemIsAnOrdinaryNodeToRegionsAndLines() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: scrap, kind: .scrap, origin: .zero, width: 240,
                            cachedHeight: 80))
        s.insert(CanvasNode(id: owned, kind: .item(.owned(path: "canvas_assets/p.png")),
                            origin: CGPoint(x: 300, y: 0), width: 240, cachedHeight: 31))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: scrap, to: owned))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [owned]))

        let loaded = try roundTrip(s)
        XCTAssertEqual(try XCTUnwrap(loaded.region(CanvasRegionID("r1"))).homeMembers, [owned])
        XCTAssertEqual(loaded.lines.map(\.id), [CanvasLineID("l1")])
    }
}
