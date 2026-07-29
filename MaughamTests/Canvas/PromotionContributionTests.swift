import XCTest
@testable import Maugham

/// Spec §6.3: what a promotion records on the cards it CONSUMED, and the
/// guard that keeps that record from being mistaken for the promotion mark.
///
/// A region's promotion joins several cards' text into one artifact and only
/// marks the region (`CanvasRegion.promotedItemID`) — so every member card
/// says "Not promoted yet" even though its words are in the note. The fix is
/// a SEPARATE field: `PromotionPlan.contributors` names who is recorded, and
/// `CanvasNode.contributedToItemID` is where Task 2's performer writes it (not
/// wired here). Stamping a contributor with `promotedItemID` instead would let
/// promoting one member afterwards offer to Rewrite the whole joint note with
/// that one card's text — the 1C-c2 Critical (a mark that did not record the
/// artifact's kind) returning as a mark that does not record its cardinality.
/// This file pins the record's shape and proves `existingArtifact` never
/// reads it.
final class PromotionContributionTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let c = CanvasNodeID("c")
    private let r1 = CanvasRegionID("r1")
    private let l1 = CanvasLineID("l1")

    /// `a` above `b`, matching `PromotionTests`' reading-order convention —
    /// top card first. `c` merely APPEARS in `r1`; it does not live there.
    private func scene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 0, y: 0),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 0, y: 200),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: c, kind: .scrap, origin: CGPoint(x: 0, y: 400),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 600),
                                    homeMembers: [a, b], appearances: [c]))
        s.insertLine(CanvasLine(id: l1, from: a, to: b))
        return s
    }

    private func index(_ pairs: [String: String] = [:]) -> ArtifactIndex {
        ArtifactIndex(titlesByID: pairs)
    }

    private func request(_ source: PromotionSource, _ target: PromotionTarget,
                         scraps: [CanvasNodeID: String],
                         artifacts: ArtifactIndex? = nil) -> PromotionRequest {
        PromotionRequest(source: source, target: target, scraps: scraps,
                         artifacts: artifacts ?? index())
    }

    // MARK: - Who is a contributor (spec §6.3)

    func test_aRegionsContributorsAreItsHomeMembersWithTextInReadingOrder() {
        let texts: [CanvasNodeID: String] = [
            a: "The falls at night.", b: "October's doctor was kind about it.",
        ]
        let plan = Promotion.plan(request(.region(r1), .researchNote, scraps: texts), in: scene())
        XCTAssertEqual(plan?.contributors, [a, b])
    }

    func test_aMemberWithEmptyTextIsNotAContributor() {
        let texts: [CanvasNodeID: String] = [a: "The falls at night.", b: "   \n  "]
        let plan = Promotion.plan(request(.region(r1), .researchNote, scraps: texts), in: scene())
        XCTAssertEqual(plan?.contributors, [a],
                       "an empty member's words never reached the note, so it is not "
                       + "a contributor")
    }

    func test_anAppearanceOnlyCardIsNotAContributor() {
        let texts: [CanvasNodeID: String] = [
            a: "The falls at night.", b: "October's doctor was kind about it.",
            c: "This text must never appear in the contributors list.",
        ]
        let plan = Promotion.plan(request(.region(r1), .paletteCard, scraps: texts), in: scene())
        XCTAssertEqual(plan?.contributors, [a, b])
        XCTAssertFalse(plan!.contributors.contains(c),
                       "an appearance is a citation, not luggage — its words are not "
                       + "what the region's promotion joins")
    }

    /// **With a positive control**, and it needs one twice over: the field is
    /// `[]` here, so an assertion that it is `[]` is the shape that passes while
    /// blind — and it passed on a memberwise default until the whole-branch
    /// review took the default away. The control drives the same `plan` through
    /// the same helpers to a NON-empty list, so this test rests on the scrap arm
    /// naming nobody rather than on nobody ever being named.
    func test_aScrapPlanHasNoContributors() {
        let scraps = [a: "The falls at night.", b: "Sodium light."]
        let plan = Promotion.plan(
            request(.scrap(a), .researchNote, scraps: scraps), in: scene())
        XCTAssertEqual(plan?.contributors, [])
        XCTAssertEqual(Promotion.plan(request(.region(r1), .researchNote, scraps: scraps),
                                      in: scene())?.contributors, [a, b],
                       "the control: this machinery does produce contributors, so "
                       + "the assertion above is about the scrap arm")
    }

    /// The line arm, with the same positive control and for the same reason.
    func test_aLinePlanHasNoContributors() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setPromotedItem("res-b", for: b)
        let idx = index(["res-a": "The falls at night.", "res-b": "October's doctor"])
        let plan = Promotion.plan(
            request(.line(l1), .wikiLink, scraps: [:], artifacts: idx), in: s)
        XCTAssertEqual(plan?.contributors, [])
        XCTAssertEqual(
            Promotion.plan(request(.region(r1), .researchNote,
                                   scraps: [a: "The falls at night.", b: "Sodium light."],
                                   artifacts: idx), in: s)?.contributors, [a, b],
            "the control: same scene, same index, and a region does name its "
            + "contributors")
    }

    // MARK: - The guard that matters most: a contribution record offers no Update

    /// Set `contributedToItemID`, leave `promotedItemID` nil: this card
    /// produced nothing of its own, and `existingArtifact` — the function
    /// that offers Rewrite — must say so for every updatable target.
    func test_aCardCarryingOnlyAContributionRecordOffersNoUpdate() {
        var s = scene()
        s.setContributedItem("res-fog", for: a)
        XCTAssertNil(s.node(a)?.promotedItemID, "the control: only the contribution is set")
        let idx = index(["res-fog": "Act II fog"])
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                in: s, artifacts: idx),
                     "a contributor did not produce the artifact and must never offer "
                     + "to rewrite it with its own single-card text")
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .paletteCard,
                                                in: s, artifacts: idx))
    }

    /// A card may carry both, and they say different things: it produced its
    /// own note, AND its words are in a region's. Only the first is an Update.
    func test_aCardWithBothItsOwnMarkAndAContributionRecordUpdatesOnlyItsOwn() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setContributedItem("res-fog", for: a)
        let idx = index(["res-a": "The falls at night.", "res-fog": "Act II fog"])
        XCTAssertEqual(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                  in: s, artifacts: idx),
                       .update(itemID: "res-a", title: "The falls at night."))
    }

    // MARK: - Schema trio

    func test_aContributionRecordRoundTripsThroughDisk() throws {
        var s = scene()
        s.setContributedItem("res-fog", for: a)
        let data = try JSONEncoder().encode(CanvasSceneDTO(scene: s))
        let loaded = try JSONDecoder().decode(CanvasSceneDTO.self, from: data).scene
        XCTAssertEqual(loaded.node(a)?.contributedToItemID, "res-fog")
    }

    /// A schema-5 sidecar literal — every canvas 1C-c2a wrote — has no
    /// `contributedToItemID` key on its node at all. It must decode with the
    /// field nil and lose nothing else.
    func test_aSchemaFiveSidecarLiteralDecodesWithContributedToItemIDNilAndLosesNothingElse() throws {
        let json = """
        {"schemaVersion":5,"nodes":[{"id":"a","kind":"scrap","x":5,"y":6,\
        "width":240,"cachedHeight":80,"z":1,"promotedItemID":"res-1","boundPieceID":"piece-1"}]}
        """
        let dto = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8))
        let scene = dto.scene
        let node = scene.node(a)
        XCTAssertEqual(node?.origin, CGPoint(x: 5, y: 6))
        XCTAssertEqual(node?.width, 240)
        XCTAssertEqual(node?.cachedHeight, 80)
        XCTAssertEqual(node?.z, 1)
        XCTAssertEqual(node?.promotedItemID, "res-1")
        XCTAssertEqual(node?.boundPieceID, "piece-1")
        XCTAssertNil(node?.contributedToItemID)
    }

    /// Measured, not reasoned from Codable's synthesis: an unrecorded canvas's
    /// JSON contains no `contributedToItemID` key at all.
    func test_anUnrecordedCanvasesJSONContainsNoContributedToItemIDKey() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        let data = try JSONEncoder().encode(CanvasSceneDTO(scene: s))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("contributedToItemID"),
                        "an unrecorded node must not write a contributedToItemID key at all")
    }

    func test_theSchemaIsSixBecauseThisTaskAddedAField() {
        XCTAssertEqual(CanvasSceneDTO.currentSchemaVersion, 6)
    }
}
