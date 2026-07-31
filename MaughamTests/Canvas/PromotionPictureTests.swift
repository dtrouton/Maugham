import XCTest
import MaughamCore
@testable import Maugham

/// **Spec §6's fourth row** (the 2026-07-30 amendment): an OWNED item node
/// promotes and a REFERENCED one does not.
///
/// The pure half — targets, the refusal, and the plan. `PromotionPicturePerformerTests`
/// is the half that touches disk, and the two are separated for the reason
/// `Promotion` and `PromotionPerformer` are: planning never mutates anything,
/// which is what makes the preview honest.
final class PromotionPictureTests: XCTestCase {

    private let scrap = CanvasNodeID("a")
    /// An owned picture: a minted id, because there is nothing to deduplicate
    /// and a path does not belong in an identity (`CanvasNodeID`'s own rule).
    private let owned = CanvasNodeID("owned-1")
    private let reference = CanvasNodeID.item("r-9")
    private let path = "canvas_assets/image-20260730-121314.png"
    private let r1 = CanvasRegionID("r1")

    private func scene(homeOfOwned: Bool = false) -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: scrap, kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: owned, kind: .item(.owned(path: path)),
                            origin: CGPoint(x: 400, y: 0), width: 180, cachedHeight: 200))
        s.insert(CanvasNode(id: reference, kind: .item(.project(id: "r-9")),
                            origin: CGPoint(x: 800, y: 0), width: 180, cachedHeight: 120))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: homeOfOwned ? [scrap, owned] : [scrap],
                                    boundPieceID: "doc-3"))
        return s
    }

    private let texts: [CanvasNodeID: String] = [CanvasNodeID("a"): "The falls at night."]

    /// A project with one palette card and one ordinary note, so the palette
    /// row has somewhere to go.
    private func index(withPaletteCard: Bool = true) -> ArtifactIndex {
        var entries: [String: ArtifactIndex.Entry] = [
            "res-note": .init(title: "The falls at night", kind: .researchNote),
        ]
        if withPaletteCard {
            entries["res-card"] = .init(title: "Colour: October", kind: .paletteCard)
        }
        return ArtifactIndex(entriesByID: entries)
    }

    private func request(_ target: PromotionTarget,
                         source: PromotionSource? = nil,
                         paletteCardID: String? = nil,
                         piece: PromotionPiece = .none,
                         artifacts: ArtifactIndex? = nil) -> PromotionRequest {
        PromotionRequest(source: source ?? .scrap(owned), target: target,
                         scraps: texts, artifacts: artifacts ?? index(),
                         paletteCardID: paletteCardID, piece: piece)
    }

    // MARK: - §6's table

    func test_anOwnedPictureOffersTheTwoDestinationsTheInboxAlreadyHas() {
        XCTAssertEqual(Promotion.targets(for: .scrap(owned), in: scene(), artifacts: index()),
                       [.researchAsset, .paletteCardImage],
                       "a research asset, or an image on a palette card — §6's "
                       + "amendment, and neither is new machinery")
    }

    /// The CONTROL for every assertion above: the refusal is about the
    /// provenance and not about the kind, so a referenced node in the same scene
    /// with the same index must still offer nothing.
    func test_aReferencedItemStillOffersNothingAndStillSaysWhy() {
        XCTAssertTrue(Promotion.targets(for: .scrap(reference), in: scene(),
                                        artifacts: index()).isEmpty)
        XCTAssertEqual(Promotion.blockedReason(for: .scrap(reference), in: scene(),
                                               scraps: texts, artifacts: index()),
                       Promotion.itemNodeReason,
                       "`itemNodeReason` stays alive and becomes the REFERENCED "
                       + "node's sentence")
    }

    /// A target that could only ever produce "there is nowhere to put this" is
    /// not an offer — the line arm's rule, on another row. The research row is
    /// always there, so the writer is never left with nothing.
    func test_thePaletteRowIsWithheldFromAProjectWithNoPaletteCards() {
        XCTAssertEqual(
            Promotion.targets(for: .scrap(owned), in: scene(),
                              artifacts: index(withPaletteCard: false)),
            [.researchAsset])
    }

    func test_aScrapIsUnaffectedByAnyOfThis() {
        XCTAssertEqual(Set(Promotion.targets(for: .scrap(scrap), in: scene(),
                                             artifacts: index())),
                       [.researchNote, .paletteCard, .intentStatement],
                       "the three text rows, unchanged — and no picture row, "
                       + "because a scrap has no file")
    }

    // MARK: - The refusal, and the noun

    /// **The line that changes must not let an owned node fall THROUGH.** An
    /// owned node has no scrap text by construction, so a relaxed guard drops it
    /// into the empty-text check below and refuses the photograph with "There is
    /// nothing in this card to promote." — the wrong reason, in the wrong noun.
    func test_anOwnedPictureIsNotBlockedAtAll() {
        XCTAssertNil(Promotion.blockedReason(for: .scrap(owned), in: scene(),
                                             scraps: texts, artifacts: index()))
        XCTAssertNil(Promotion.blockedReason(for: .scrap(owned), in: scene(),
                                             scraps: [:], artifacts: index()),
                     "and not with an empty scrap table either — that is the "
                     + "fall-through this guard exists to stop, and the table is "
                     + "empty for every owned node in production")
    }

    /// **The noun decision, asserted rather than reasoned about.**
    /// `PromotionSource.noun` still answers "card" for a `.scrap`, which now
    /// names an owned picture as well — and that survives only while no sentence
    /// built from it can reach one. The only such sentence is
    /// `emptyBody`'s, and the two guards that keep a picture away from it are
    /// `blockedReason` (above) and `targets`: an owned node is never offered a
    /// row whose validation tests a body.
    func test_noRefusalAnOwnedNodeCanReachCallsItACard() {
        let cardWord = PromotionFailure.emptyBody(source: .scrap(owned)).errorDescription
        XCTAssertEqual(cardWord, "There is nothing in this card to promote.",
                       "the sentence exists and says card — the control, without "
                       + "which the assertions below would pass on a typo")
        XCTAssertNil(Promotion.blockedReason(for: .scrap(owned), in: scene(),
                                             scraps: [:], artifacts: index()),
                     "so the writer never reads it before Commit")
        let offered = Promotion.targets(for: .scrap(owned), in: scene(), artifacts: index())
        XCTAssertFalse(offered.isEmpty,
                       "the control for the loop below, which would pass over an "
                       + "empty list — and an empty list is what this whole task "
                       + "changed")
        for target in offered {
            XCTAssertFalse([PromotionTarget.researchNote, .paletteCard, .intentStatement]
                            .contains(target),
                           "and never after: the three rows whose `validate` arm "
                           + "throws `emptyBody` are not offered to a picture — "
                           + "found \(target)")
        }
    }

    // MARK: - The plan

    func test_theResearchRowPlansACopyOfTheFileAndRoutesLikeANote() throws {
        let plan = try XCTUnwrap(Promotion.plan(
            request(.researchAsset,
                    piece: .routed(id: "doc-3", title: "Chapter Three", route: .sharedPlusLink)),
            in: scene()))
        XCTAssertEqual(plan.picture,
                       PromotedPicture(node: owned, assetPath: path, paletteCardID: nil))
        XCTAssertEqual(plan.destinationDescription, "research/, linked to “Chapter Three”",
                       "the same sentence a research NOTE gets, because it is the "
                       + "same `ResearchScope.route`")
        XCTAssertEqual(plan.mode, .new)
        XCTAssertTrue(plan.body.isEmpty, "a picture has no prose to excerpt")
        XCTAssertTrue(plan.discards.isEmpty, "and nothing spatial to lose")
        XCTAssertTrue(plan.contributors.isEmpty,
                      "the record an appended picture leaves is written by the "
                      + "performer, never through this list — see `recordPicture`")
    }

    func test_thePaletteRowPlansTheCardTheWriterChose() throws {
        let plan = try XCTUnwrap(Promotion.plan(
            request(.paletteCardImage, paletteCardID: "res-card"), in: scene()))
        XCTAssertEqual(plan.picture,
                       PromotedPicture(node: owned, assetPath: path, paletteCardID: "res-card"))
        XCTAssertEqual(plan.destinationDescription, "the palette card “Colour: October”")
        XCTAssertEqual(plan.title, "Colour: October")
    }

    /// A picture must not land on whichever card sorted first, so no card means
    /// **no plan** — which is what disables Promote. The sheet seeds the picker,
    /// so this is reachable only from a hand-built request.
    func test_thePaletteRowPlansNothingWithoutACard() {
        XCTAssertNil(Promotion.plan(request(.paletteCardImage), in: scene()))
        XCTAssertNil(Promotion.plan(request(.paletteCardImage, paletteCardID: "res-note"),
                                    in: scene()),
                     "and not onto an ordinary research note either — the id has "
                     + "to name a palette card")
        XCTAssertNotNil(Promotion.plan(request(.paletteCardImage, paletteCardID: "res-card"),
                                       in: scene()),
                        "the control: the same request with a real card plans")
    }

    func test_aReferencedNodePlansNothingOnEitherRow() {
        for target in [PromotionTarget.researchAsset, .paletteCardImage] {
            XCTAssertNil(Promotion.plan(request(target, source: .scrap(reference),
                                                paletteCardID: "res-card"), in: scene()),
                         "\(target)")
        }
    }

    /// §6.2's precedence, unchanged: an item node carries no association of its
    /// own (its arm has no picker), so it inherits its HOME region's — and a
    /// picture merely visiting inherits nothing.
    func test_aPictureInheritsItsHomeRegionsPiece() {
        XCTAssertEqual(Promotion.piece(for: .scrap(owned), in: scene(homeOfOwned: true)),
                       "doc-3")
        XCTAssertTrue(Promotion.pieceIsInherited(for: .scrap(owned),
                                                 in: scene(homeOfOwned: true)),
                      "and the refusal has to say whose association it is, or it "
                      + "sends the writer to a Picker already reading None")
        XCTAssertNil(Promotion.piece(for: .scrap(owned), in: scene()),
                     "the control: outside the region it inherits nothing")
    }

    /// A stale association refuses the picture the way it refuses a note — both
    /// hand a scope to a `create…` call — and refuses neither of the rows that
    /// route nothing.
    func test_aStalePieceRefusesTheResearchRowAndOnlyThat() {
        let stale = PromotionPiece.unroutable(id: "doc-9", title: "Elsewhere", inherited: true)
        XCTAssertNotNil(Promotion.pieceFailure(target: .researchAsset, mode: .new, piece: stale))
        XCTAssertNil(Promotion.pieceFailure(target: .paletteCardImage, mode: .new, piece: stale),
                     "an appended image is not routed — the card is where it is")
        let sentence = Promotion.pieceFailure(target: .researchAsset, mode: .new,
                                              piece: stale)?.errorDescription
        XCTAssertFalse(sentence?.contains("the note") ?? true,
                       "and the sentence must not tell a picture its NOTE has "
                       + "nowhere to go. found: \(sentence ?? "nil")")
    }

    // MARK: - The failure it must not have (§6's amendment, named)

    /// **Promoting a picture twice must never offer to REWRITE the palette card
    /// it went into** — that is the 1C-c2 Critical's exact shape, and it would
    /// replace the card's other images, swatches and sensory notes with one
    /// photograph, with ⌘Z taking back only the record.
    ///
    /// Three independent guards, and this drives all three: the palette row
    /// writes a CONTRIBUTION rather than the mark (so there is no id to resolve),
    /// neither picture row is in `updatableTargets`, and no updatable target's
    /// `producedArtifactKind` is what a picture's mark names.
    func test_aPictureNeverOffersToRewriteAnything() {
        var s = scene()
        // The state after both promotions: a mark naming the research asset it
        // produced, and a record naming the card it was added to.
        s.setPromotedItem("res-asset", for: owned)
        s.setContributedItem("res-card", for: owned)
        let artifacts = ArtifactIndex(entriesByID: [
            "res-card": .init(title: "Colour: October", kind: .paletteCard),
            "res-asset": .init(title: "image-20260730-121314", kind: .researchAsset),
        ])
        for target in PromotionTarget.allCases {
            XCTAssertNil(Promotion.existingArtifact(for: .scrap(owned), target: target,
                                                    in: s, artifacts: artifacts),
                         "no target may offer an Update against a picture — \(target)")
        }
        // The control, without which every line above passes on a broken
        // `existingArtifact`: an ordinary scrap whose mark names a note of the
        // right kind DOES offer one.
        var withScrap = s
        withScrap.setPromotedItem("res-note", for: scrap)
        XCTAssertEqual(
            Promotion.existingArtifact(
                for: .scrap(scrap), target: .researchNote, in: withScrap,
                artifacts: ArtifactIndex(entriesByID: [
                    "res-note": .init(title: "The falls at night", kind: .researchNote)])),
            .update(itemID: "res-note", title: "The falls at night"))
    }

    /// The kind on each side of that comparison, stated: a target that produces
    /// a file says so, and the row that produces no research item at all says
    /// nil — `.wikiLink`'s answer, for `.wikiLink`'s reason.
    func test_eachPictureRowAnswersForTheKindItProduces() {
        XCTAssertEqual(PromotionTarget.researchAsset.producedArtifactKind, .researchAsset)
        XCTAssertNil(PromotionTarget.paletteCardImage.producedArtifactKind)
        XCTAssertFalse(Promotion.updatableTargets.contains(.researchAsset))
        XCTAssertFalse(Promotion.updatableTargets.contains(.paletteCardImage))
        XCTAssertFalse(PromotionTarget.researchAsset.namesItsArtifact,
                       "`createResearchAsset` titles the item from the file it "
                       + "copies; a Name field here would change nothing")
        XCTAssertFalse(PromotionTarget.paletteCardImage.namesItsArtifact)
    }

    /// The index has to KNOW an asset is one, or the kind above compares against
    /// a lie. A `.png` in `research/` answered `.researchNote` until 1C-d, which
    /// is `performResearchNote`'s update branch renaming it and writing prose in.
    func test_theIndexCallsAFileAFileAndProseProse() {
        let research = [
            ResearchItem(id: "res-img", title: "A photograph", type: .asset, kind: .image,
                         path: "research/a-photograph.png"),
            ResearchItem(id: "res-note", title: "The falls", type: .asset, kind: .document,
                         path: "research/the-falls.md"),
            ResearchItem(id: "res-pdf", title: "A score", type: .asset, kind: .pdf,
                         path: "research/a-score.pdf"),
        ]
        let index = ArtifactIndex.over(research: research)
        XCTAssertEqual(index.kind(of: "res-img"), .researchAsset)
        XCTAssertEqual(index.kind(of: "res-pdf"), .researchAsset)
        XCTAssertEqual(index.kind(of: "res-note"), .researchNote,
                       "the control: prose is still prose, or this would refuse "
                       + "every ordinary re-promotion in the app")

        // **And the consequence, chained to it through the REAL index** — the
        // reason the classification is worth a case at all. A card whose mark
        // names a picture must not be offered a research-note Update: that arm
        // renames the backing file and writes plan text over it, which for a
        // `.png` is the file replaced by a card's prose.
        var s = scene()
        s.setPromotedItem("res-img", for: scrap)
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(scrap), target: .researchNote,
                                                in: s, artifacts: index))
        var prose = scene()
        prose.setPromotedItem("res-note", for: scrap)
        XCTAssertEqual(Promotion.existingArtifact(for: .scrap(scrap), target: .researchNote,
                                                  in: prose, artifacts: index),
                       .update(itemID: "res-note", title: "The falls"),
                       "the control: a mark naming a real NOTE still offers one, "
                       + "so the nil above is about the kind and not about the "
                       + "index being empty")
    }

    /// The sheet's picker is built from the index, so it has to answer with the
    /// palette cards and nothing else — and in a stable order, or a different
    /// card sits under the writer's cursor on each launch.
    func test_theIndexOffersThePaletteCardsSorted() {
        let index = ArtifactIndex(entriesByID: [
            "res-2": .init(title: "Colour: October", kind: .paletteCard),
            "res-1": .init(title: "Zinc", kind: .paletteCard),
            "res-3": .init(title: "A note", kind: .researchNote),
            "res-4": .init(title: "The intent", kind: .craftIntent),
        ])
        XCTAssertEqual(index.paletteCards.map(\.id), ["res-2", "res-1"])
        XCTAssertEqual(index.paletteCards.map(\.title), ["Colour: October", "Zinc"])
    }
}
