import XCTest
import MaughamCore
@testable import Maugham

/// **Spec §6's 2026-07-29 amendment, built:** *"The palette card **stays** on
/// the row, and its case gets stronger rather than weaker in 1C-d: a palette
/// card is worth making from a region that holds an *image*, which the canvas
/// cannot hold until then."* The canvas holds one as of this slice, and until
/// this task promoting such a region still produced a card with no images.
///
/// And **spec §6.3's 2026-07-31 amendment**, which is what a picture's node
/// records afterwards: *"they should report their promotion in the same way as
/// the text scraps."* The record covers any home member whose CONTENT went in —
/// words or picture — and it is `contributedToItemID` and never the mark.
///
/// The pure half: the plan, the discards, the contributors, and the sheet's
/// sentence. `PromotionRegionPicturePerformerTests` is the half that touches
/// disk, separated for the reason `Promotion` and `PromotionPerformer` are.
@MainActor
final class PromotionRegionPictureTests: XCTestCase {

    private let topCard = CanvasNodeID("a")
    private let owned = CanvasNodeID("owned-1")
    private let lowCard = CanvasNodeID("b")
    /// A *referenced* research image — the node id spells the item id, matching
    /// `PromotionPictureTests`' convention.
    private let referenced = CanvasNodeID.item("res-img")
    /// A referenced research NOTE, which is a reference with no file to carry.
    private let referencedNote = CanvasNodeID.item("res-note")
    private let visitor = CanvasNodeID("owned-visiting")
    private let r1 = CanvasRegionID("r1")

    private let ownedPath = "canvas_assets/image-20260731-090000.png"
    private let visitorPath = "canvas_assets/image-20260731-090001.png"
    private let referencedPath = "research/a-photograph.png"

    /// Reading order is top-to-bottom, so the y coordinates below ARE the
    /// expected order: card, picture, card, reference.
    private func scene(includePictures: Bool = true) -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: topCard, kind: .scrap, origin: CGPoint(x: 0, y: 0),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: lowCard, kind: .scrap, origin: CGPoint(x: 0, y: 200),
                            width: 240, cachedHeight: 80))
        var home: Set<CanvasNodeID> = [topCard, lowCard]
        if includePictures {
            s.insert(CanvasNode(id: owned, kind: .item(.owned(path: ownedPath)),
                                origin: CGPoint(x: 0, y: 100), width: 180, cachedHeight: 200))
            s.insert(CanvasNode(id: referenced, kind: .item(.project(id: "res-img")),
                                origin: CGPoint(x: 0, y: 300), width: 180, cachedHeight: 200))
            s.insert(CanvasNode(id: referencedNote, kind: .item(.project(id: "res-note")),
                                origin: CGPoint(x: 0, y: 400), width: 180, cachedHeight: 120))
            home.formUnion([owned, referenced, referencedNote])
        }
        // A picture the region merely CITES. §4.3: a visitor is not luggage.
        s.insert(CanvasNode(id: visitor, kind: .item(.owned(path: visitorPath)),
                            origin: CGPoint(x: 0, y: 50), width: 180, cachedHeight: 200))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 600),
                                    homeMembers: home, appearances: [visitor]))
        return s
    }

    private let texts: [CanvasNodeID: String] = [
        CanvasNodeID("a"): "The falls at night.",
        CanvasNodeID("b"): "October's doctor was kind about it.",
    ]

    /// A referenced picture and a referenced note, so "which references carry a
    /// file" is a question this index really answers rather than one the test
    /// arranges away.
    private func items() -> CanvasItemIndex {
        CanvasItemIndex(entriesByID: [
            "res-img": .init(title: "A photograph", kind: .image,
                             thumbnailPath: referencedPath),
            "res-note": .init(title: "The falls", kind: .researchNote),
        ])
    }

    private func artifacts(_ pairs: [String: ArtifactIndex.Entry] = [:]) -> ArtifactIndex {
        ArtifactIndex(entriesByID: pairs)
    }

    private func plan(_ target: PromotionTarget = .paletteCard,
                      mode: PromotionMode = .new,
                      scene: CanvasScene? = nil,
                      items: CanvasItemIndex? = nil,
                      artifacts: ArtifactIndex? = nil) -> PromotionPlan? {
        Promotion.plan(
            PromotionRequest(source: .region(r1), target: target, mode: mode,
                             scraps: texts, artifacts: artifacts ?? self.artifacts(),
                             items: items ?? self.items()),
            in: scene ?? self.scene())
    }

    // MARK: - What the palette row carries

    func test_aRegionsPaletteCardCarriesTheJoinedProseAndThePicturesInIt() throws {
        let plan = try XCTUnwrap(plan())
        XCTAssertEqual(plan.body,
                       "The falls at night.\n\nOctober's doctor was kind about it.",
                       "the prose is unchanged — this task adds to the card, it "
                       + "does not rewrite what was already right")
        XCTAssertEqual(plan.pictures, [
            PromotedPicture(node: owned, assetPath: ownedPath, paletteCardID: nil),
            PromotedPicture(node: referenced, assetPath: referencedPath, paletteCardID: nil),
        ])
    }

    /// **Reading order, and both of them.** The picture between the two cards
    /// comes before the reference below them because that is where the writer
    /// put it — the same top-to-bottom rule the joined prose follows, so the
    /// card reads the way the region reads.
    func test_thePicturesLandInTheRegionsReadingOrderAndNotInIdOrder() throws {
        var moved = scene()
        // **These two ids sort the OTHER way**: `.item("res-img")` spells
        // `item:res-img`, which precedes `owned-1`. So the test above — where
        // the owned picture sits higher and is planned first — already rules out
        // id order, and this one, where the reference is moved above it, rules
        // out any fixed order. Together they pin position.
        moved.move(referenced, to: CGPoint(x: 0, y: 10))
        let plan = try XCTUnwrap(plan(scene: moved))
        XCTAssertEqual(plan.pictures.map(\.node), [referenced, owned],
                       "the writer arranged these, and the card is assembled the "
                       + "way the region reads")
    }

    /// §4.3, already this file's rule for the words: a card *cited* in a region
    /// is not carried by its promotion. A photograph cited in two regions bound
    /// to different cards must not be copied into whichever was promoted last.
    func test_aVisitingPictureIsNotLuggage() throws {
        let plan = try XCTUnwrap(plan())
        XCTAssertFalse(plan.pictures.contains { $0.node == visitor },
                       "an appearance is a citation — found \(plan.pictures)")
        XCTAssertFalse(plan.contributors.contains(visitor),
                       "and it records nothing either: its picture is not on that card")
        XCTAssertFalse(plan.pictures.isEmpty,
                       "the control: this region really does carry pictures, so the "
                       + "two assertions above are about the visitor")
    }

    /// A reference with no pixels has no file to carry, and the same `nil` that
    /// drops an empty scrap drops it — `CanvasItemFacts.thumbnailPath` is set
    /// for a picture and for nothing else.
    func test_aReferencedNoteInTheRegionCarriesNothing() throws {
        let plan = try XCTUnwrap(plan())
        XCTAssertFalse(plan.pictures.contains { $0.node == referencedNote },
                       "found \(plan.pictures)")
        XCTAssertFalse(plan.contributors.contains(referencedNote),
                       "nothing of it went into the card, so it records nothing")
        XCTAssertTrue(plan.pictures.contains { $0.node == referenced },
                      "the control: a referenced PICTURE in the same region, "
                      + "resolved through the same index, is carried")
    }

    /// **The one line that would ship owned-only**, asserted from the other
    /// side: with an empty index a referenced picture resolves to no path, so
    /// omitting `items:` at the production call site is the whole difference
    /// between both provenances and one.
    func test_aReferencedPictureNeedsTheIndexAndAnOwnedOneDoesNot() throws {
        let plan = try XCTUnwrap(plan(items: .empty))
        XCTAssertEqual(plan.pictures.map(\.node), [owned],
                       "an owned picture carries its own path in its kind; a "
                       + "referenced one is the manifest's to know")
    }

    // MARK: - The rows that carry none, and say so

    /// A research note is prose, and a region holding a photograph must be told
    /// the photograph is not coming — §6.1's "allowed to be lossy, and the
    /// writer is told which parts", which is what `PromotionDiscard` is.
    func test_theResearchNoteRowCarriesNoPictureAndDeclaresTheDiscard() throws {
        let note = try XCTUnwrap(plan(.researchNote))
        XCTAssertTrue(note.pictures.isEmpty)
        XCTAssertEqual(note.discards, [.lines, .layout, .pictures])
        let card = try XCTUnwrap(plan(.paletteCard))
        XCTAssertEqual(card.discards, [.lines, .layout],
                       "the control: the row that DOES carry them declares no "
                       + "picture discard, or the notice would contradict itself")
    }

    /// **A rewrite is about the words.** `performPaletteCard`'s update branch
    /// carries `current.imagePaths` across untouched, so appending on every
    /// update would stack another copy of every photograph on the writer's card
    /// each time they re-promoted the region.
    func test_rewritingAnExistingCardCopiesNoPictureAgainAndSaysSo() throws {
        let update = PromotionMode.update(itemID: "res-card", title: "Act II fog")
        let plan = try XCTUnwrap(plan(.paletteCard, mode: update,
                                      artifacts: artifacts([
                                        "res-card": .init(title: "Act II fog",
                                                          kind: .paletteCard)])))
        XCTAssertTrue(plan.pictures.isEmpty)
        XCTAssertTrue(plan.discards.contains(.pictures))
        XCTAssertFalse(plan.contributors.contains(owned),
                       "and a picture this promotion did not copy records nothing "
                       + "for it — the record is written at promotion time and is "
                       + "never a claim about what some earlier one did")
        XCTAssertEqual(plan.contributors, [topCard, lowCard],
                       "the control: the members whose words this rewrite really "
                       + "does put in the card are still recorded")
    }

    /// **The control the whole task rests on**: without it every assertion here
    /// could be passing by making every region promotion different.
    func test_aRegionWithNoPicturesInItPromotesExactlyAsItDidBefore() throws {
        let plan = try XCTUnwrap(plan(scene: scene(includePictures: false)))
        XCTAssertTrue(plan.pictures.isEmpty)
        XCTAssertEqual(plan.discards, [.lines, .layout],
                       "no picture discard, because there is no picture — a "
                       + "notice about pictures over a region with none is the "
                       + "same class of false sentence in the other direction")
        XCTAssertEqual(plan.contributors, [topCard, lowCard])
        XCTAssertEqual(plan.body,
                       "The falls at night.\n\nOctober's doctor was kind about it.")
    }

    // MARK: - What the pictures record (spec §6.3's 2026-07-31 amendment)

    /// Denver's ruling, asserted: *"they should report their promotion in the
    /// same way as the text scraps."* Before it, `contributors` came from
    /// `regionBodies` — which reads the scrap table and structurally cannot see
    /// a picture — so a photograph carried into a palette card recorded nothing
    /// and its card said "Not promoted yet" while its picture sat in the
    /// artifact. That is word for word the failure §6.3 was written to answer.
    func test_everyHomeMemberWhoseContentWentInIsAContributorInReadingOrder() throws {
        let plan = try XCTUnwrap(plan())
        XCTAssertEqual(plan.contributors, [topCard, owned, lowCard, referenced],
                       "words or picture, in one reading order — a picture is on "
                       + "the same side of §6.3's distinction as a paragraph")
    }

    /// **The load-bearing half of §6.3, on the row this task added.** The record
    /// is `contributedToItemID` and never the mark: `promotedItemID` means "I am
    /// this artifact" and `Promotion.existingArtifact` reads only it to offer
    /// **Rewrite**, so a contributing picture carrying the mark would let a
    /// later promotion rewrite a six-card palette card with one photograph.
    ///
    /// Driven through every target, because the guard is `existingArtifact`'s
    /// and not one row's.
    func test_aContributingPictureOffersNoUpdateOnAnyRow() throws {
        var s = scene()
        s.setContributedItem("res-card", for: owned)
        s.setContributedItem("res-card", for: referenced)
        XCTAssertNil(try XCTUnwrap(s.node(owned)).promotedItemID,
                     "the control: only the contribution is set")
        let idx = artifacts(["res-card": .init(title: "Act II fog", kind: .paletteCard)])
        for node in [owned, referenced] {
            for target in PromotionTarget.allCases {
                XCTAssertNil(Promotion.existingArtifact(for: .scrap(node), target: target,
                                                        in: s, artifacts: idx),
                             "\(node) / \(target)")
            }
        }
        // The control, without which every line above passes on a broken
        // `existingArtifact`: a card whose own MARK names an artifact of the
        // right kind still offers one.
        var marked = s
        marked.setPromotedItem("res-card", for: topCard)
        XCTAssertEqual(Promotion.existingArtifact(for: .scrap(topCard), target: .paletteCard,
                                                  in: marked, artifacts: idx),
                       .update(itemID: "res-card", title: "Act II fog"))
    }

    // MARK: - The preview says what will be copied (§6.1)

    private func sheet(_ target: PromotionTarget, scene: CanvasScene? = nil,
                       artifacts: ArtifactIndex? = nil) -> PromotionSheetModel {
        let m = PromotionSheetModel(source: .region(r1), scene: scene ?? self.scene(),
                                    scraps: texts,
                                    artifacts: artifacts ?? self.artifacts(),
                                    items: items(), piece: .none, readBody: { _ in nil })
        m.select(target)
        return m
    }

    /// §6.1 requires the writer see what will be produced *and where*. A sheet
    /// that names joined prose while silently copying two photographs fails that
    /// on its own terms.
    func test_theSheetSaysThePicturesAreComingWithTheProse() {
        XCTAssertEqual(sheet(.paletteCard).pictureNotice,
                       "Also copies the 2 pictures in this region onto the card.")
        XCTAssertNil(sheet(.paletteCard, scene: scene(includePictures: false)).pictureNotice,
                     "the control: a region with no pictures says nothing about "
                     + "pictures")
    }

    func test_theSheetSaysItInTheSingularForOne() throws {
        var one = scene()
        one.remove(referenced)
        XCTAssertEqual(sheet(.paletteCard, scene: one).pictureNotice,
                       "Also copies the picture in this region onto the card.")
    }

    /// The other direction, through the machine §6.1 already has for it.
    func test_theSheetSaysWhenThePicturesAreNotCarried() throws {
        let notice = try XCTUnwrap(sheet(.researchNote).discardNotice)
        XCTAssertEqual(notice,
                       "Not carried across: the lines between these cards, their "
                       + "layout and the pictures in it. The canvas keeps them.")
        XCTAssertNil(sheet(.researchNote).pictureNotice,
                     "and it does not ALSO claim to copy them — the two notices "
                     + "are one machine each, not one sentence with a `not` in it")
        let carried = try XCTUnwrap(sheet(.paletteCard).discardNotice)
        XCTAssertEqual(carried,
                       "Not carried across: the lines between these cards and "
                       + "their layout. The canvas keeps them.",
                       "the control, and the two-part wording is unchanged: a "
                       + "third clause joined on \" and \" would have read \"…and "
                       + "their layout and the pictures in it\"")
    }

    // MARK: - The stated gap, pinned rather than described

    /// **A region holding ONLY pictures is still "empty", and this asserts what
    /// the writer actually meets** — recorded rather than closed, because
    /// closing it is a decision about what "empty" means per row and Denver has
    /// not made it.
    ///
    /// **The behaviour is a refusal with a FALSE reason, and it is not the dead
    /// sheet** (fix round 1: both the report and the review had the mechanism
    /// wrong, in different directions, and this test is why it is now asserted
    /// instead of argued). `Promotion.blockedReason` answers **before** `plan` is
    /// ever consulted and `PromotionSheet.body` branches on it, so the writer
    /// gets the sentence and no target picker — never the reason-less disabled
    /// button. The sentence is *"There is nothing in this region to promote."*
    /// said over a photograph.
    ///
    /// Closing it needs three per-target changes, and this test names the first:
    /// `blockedReason` takes no target and is called once when the sheet opens,
    /// so it cannot say "empty for a note, fine for a card".
    func test_aRegionHoldingOnlyPicturesIsRefusedWithASentenceThatIsNotTrueOfIt() throws {
        var pictureOnly = scene()
        pictureOnly.remove(topCard)
        pictureOnly.remove(lowCard)
        let why = Promotion.blockedReason(for: .region(r1), in: pictureOnly,
                                          scraps: [:], artifacts: artifacts())
        XCTAssertEqual(why, "There is nothing in this region to promote.",
                       "the recorded gap: a refusal whose sentence is false of "
                       + "the region the writer is looking at")
        XCTAssertNil(Promotion.plan(
            PromotionRequest(source: .region(r1), target: .paletteCard, scraps: [:],
                             artifacts: artifacts(), items: items()),
            in: pictureOnly),
                     "and no plan on the row that COULD hold a picture — the "
                     + "emptiness guard runs before the target is dispatched on")

        let m = PromotionSheetModel(source: .region(r1), scene: pictureOnly, scraps: [:],
                                    artifacts: artifacts(), items: items(),
                                    piece: .none, readBody: { _ in nil })
        XCTAssertEqual(m.blockedReason, why,
                       "which is what the sheet shows INSTEAD of the target "
                       + "picker — so this is a wrong reason and not the "
                       + "reason-less dead sheet")
        XCTAssertFalse(m.canCommit)

        // The control: the same region, with its text cards back, is not blocked
        // — so the refusal above is about the emptiness rule and not about
        // something else in this scene.
        XCTAssertNil(Promotion.blockedReason(for: .region(r1), in: scene(),
                                             scraps: texts, artifacts: artifacts()))
    }

    /// **"Not carried across … the pictures in it" reads as a threat over a card
    /// that already holds them** (review Minor 2). It is true of the *act* — a
    /// rewrite copies none — and a writer re-promoting a region whose pictures
    /// went onto that card on the first promotion can read it as the card about
    /// to lose them, which is the one thing a rewrite is careful not to do. The
    /// positive fact was stated nowhere in the sheet.
    func test_aRewriteSaysTheCardKeepsTheImagesItAlreadyHas() throws {
        let m = PromotionSheetModel(
            source: .region(r1), scene: scene(), scraps: texts,
            artifacts: artifacts(["res-card": .init(title: "Act II fog",
                                                    kind: .paletteCard)]),
            items: items(), piece: .none, readBody: { _ in nil })
        m.select(.paletteCard)
        m.mode = .update(itemID: "res-card", title: "Act II fog")
        let notice = try XCTUnwrap(m.discardNotice)
        XCTAssertTrue(notice.hasSuffix("The card keeps the images it already has."),
                      "found: \(notice)")

        // Two controls, because the clause must appear on exactly one row.
        m.mode = .new
        XCTAssertEqual(try XCTUnwrap(m.discardNotice).contains("keeps the images"), false,
                       "a NEW card is not keeping anything — it is being made")
        XCTAssertFalse(try XCTUnwrap(sheet(.researchNote).discardNotice)
                        .contains("keeps the images"),
                       "and a research note has no image well to reassure "
                       + "anybody about")
    }
}
