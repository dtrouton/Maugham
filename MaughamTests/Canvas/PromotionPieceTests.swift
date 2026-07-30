import XCTest
@testable import Maugham

/// §6.2's precedence rule, executable: a scrap's own piece association wins,
/// then its HOME region's, then none. Never an appearance — a citation is not
/// luggage (§4.3's rule for dragging, applied here to destination), and
/// nothing a region's own `boundPieceID` write ever touches a member's field.
final class PromotionPieceTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let r1 = CanvasRegionID("r1")
    private let r2 = CanvasRegionID("r2")

    // MARK: - Scrap precedence

    func test_aScrapsOwnPieceWinsOverADifferingHomeRegionsPiece() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        s.setBoundPiece("piece-own", for: a)
        s.insertRegion(CanvasRegion(id: r1, label: "Fog", frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [a], boundPieceID: "piece-region"))
        XCTAssertEqual(Promotion.piece(for: .scrap(a), in: s), "piece-own")
    }

    func test_aScrapWithNoneOfItsOwnInheritsItsHomeRegions() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Fog", frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [a], boundPieceID: "piece-region"))
        XCTAssertEqual(Promotion.piece(for: .scrap(a), in: s), "piece-region")
    }

    /// The appearance case — the one that matters. A scrap merely CITED in a
    /// bound region must inherit nothing: a citation is not luggage, and this
    /// is the case §4.2's rejected bug class would reappear through if the
    /// resolver read appearances as well as homes. Falsified by the disable
    /// experiment described in the task report.
    func test_aScrapWhoseOnlyAssociationIsAnAppearanceInABoundRegionInheritsNothing() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Fog", frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    appearances: [a], boundPieceID: "piece-region"))
        XCTAssertNil(Promotion.piece(for: .scrap(a), in: s))
    }

    func test_aLooseScrapAnswersNil() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        XCTAssertNil(Promotion.piece(for: .scrap(a), in: s))
    }

    // MARK: - Region: its own only, no home to inherit from

    func test_aRegionAnswersItsOwn() {
        var s = CanvasScene()
        s.insertRegion(CanvasRegion(id: r1, label: "Fog", frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    boundPieceID: "piece-region"))
        XCTAssertEqual(Promotion.piece(for: .region(r1), in: s), "piece-region")
    }

    func test_aRegionWithNoneAnswersNil() {
        var s = CanvasScene()
        s.insertRegion(CanvasRegion(id: r1, label: "Fog", frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        XCTAssertNil(Promotion.piece(for: .region(r1), in: s))
    }

    // MARK: - Line: never associated

    func test_aLineAnswersNil() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 0, y: 200), width: 240, cachedHeight: 80))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: a, to: b))
        XCTAssertNil(Promotion.piece(for: .line(CanvasLineID("l1")), in: s))
    }

    // MARK: - Unknown id

    func test_anUnknownScrapIdAnswersNil() {
        let s = CanvasScene()
        XCTAssertNil(Promotion.piece(for: .scrap(CanvasNodeID("ghost")), in: s))
    }

    func test_anUnknownRegionIdAnswersNil() {
        let s = CanvasScene()
        XCTAssertNil(Promotion.piece(for: .region(CanvasRegionID("ghost")), in: s))
    }

    // MARK: - Never overwritten — setting a region's piece never touches members

    func test_settingARegionsPieceNeverWritesToAMembersOwnField() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Fog", frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [a]))
        s.updateRegion(r1) { $0.boundPieceID = "piece-region" }
        XCTAssertNil(try XCTUnwrap(s.node(a)).boundPieceID,
                     "the region binding must never cascade onto its members' own field")
    }

    // MARK: - Round trip and schema

    func test_aScrapsBoundPieceSurvivesSaveAndLoad() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 10, y: 20), width: 240, cachedHeight: 80))
        s.setBoundPiece("piece-9", for: a)
        let data = try JSONEncoder().encode(CanvasSceneDTO(scene: s))
        let loaded = try JSONDecoder().decode(CanvasSceneDTO.self, from: data).scene
        XCTAssertEqual(loaded.node(a)?.boundPieceID, "piece-9")
    }

    /// A schema-4 sidecar literal — every canvas 1C-c2 wrote — has no
    /// `boundPieceID` key on its node at all. It must decode with the field
    /// nil and lose nothing else.
    func test_aSchemaFourSidecarLiteralDecodesWithBoundPieceIDNilAndLosesNothingElse() throws {
        let json = """
        {"schemaVersion":4,"nodes":[{"id":"a","kind":"scrap","x":5,"y":6,\
        "width":240,"cachedHeight":80,"z":1,"promotedItemID":"res-1"}]}
        """
        let dto = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8))
        let scene = dto.scene
        let node = scene.node(a)
        XCTAssertEqual(node?.origin, CGPoint(x: 5, y: 6))
        XCTAssertEqual(node?.width, 240)
        XCTAssertEqual(node?.cachedHeight, 80)
        XCTAssertEqual(node?.z, 1)
        XCTAssertEqual(node?.promotedItemID, "res-1")
        XCTAssertNil(try XCTUnwrap(node).boundPieceID)
    }

    /// Measured, not reasoned from Codable's synthesis: an unassociated
    /// canvas's JSON contains no `boundPieceID` key at all.
    func test_anUnassociatedCanvasesJSONContainsNoBoundPieceIDKey() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        let data = try JSONEncoder().encode(CanvasSceneDTO(scene: s))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("boundPieceID"),
                        "an unassociated node must not write a boundPieceID key at all")
    }

    func test_theSchemaIsFiveBecauseThisTaskAddedAField() {
        // The literal moved to 6 in 1C-c2b, which added `contributedToItemID`,
        // to 7 in 1C-c3, which added `author`, and to 8 in 1C-d, which added
        // `ownedPath` — see `CanvasLineCodecTests.test_theSchemaVersionIsEight`
        // for the other assertion of the same literal.
        XCTAssertEqual(CanvasSceneDTO.currentSchemaVersion, 8)
    }
}
