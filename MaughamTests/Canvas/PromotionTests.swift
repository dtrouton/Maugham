import XCTest
import MaughamCore
@testable import Maugham

/// Spec §6's table, executable — and §6.1's rules, including the one that
/// refuses. Every function here is pure: `test_planningNeverMutatesTheScene`
/// is what keeps the preview honest.
final class PromotionTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let img = CanvasNodeID.item("r-9")
    private let r1 = CanvasRegionID("r1")
    private let l1 = CanvasLineID("l1")
    private let l2 = CanvasLineID("l2")

    /// `a` sits above `b`, so the region body's reading order is testable.
    private func scene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 0, y: 0),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 0, y: 200),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: img, kind: .item(referenceId: "r-9"),
                            origin: CGPoint(x: 800, y: 0), width: 180, cachedHeight: 120))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [a, b]))
        s.insertLine(CanvasLine(id: l1, from: a, to: b))
        s.insertLine(CanvasLine(id: l2, from: a, to: img))
        return s
    }

    private let texts: [CanvasNodeID: String] = [
        CanvasNodeID("a"): "The falls at night.\n\nSodium light on the spray.",
        CanvasNodeID("b"): "October's doctor was kind about it.",
    ]

    private let piece = RegionInspector.PieceChoice(id: "piece-3", title: "Chapter Three")

    private func index(_ pairs: [String: String] = [:]) -> ArtifactIndex {
        ArtifactIndex(titlesByID: pairs)
    }

    private func request(_ source: PromotionSource,
                         _ target: PromotionTarget,
                         scene: CanvasScene? = nil,
                         mode: PromotionMode = .new,
                         piece: RegionInspector.PieceChoice? = nil,
                         kind: PaletteCard.Kind = .other,
                         artifacts: ArtifactIndex? = nil,
                         destinationBody: String? = nil) -> PromotionRequest {
        PromotionRequest(source: source, target: target, mode: mode, scraps: texts,
                         piece: piece, paletteKind: kind,
                         artifacts: artifacts ?? index(), destinationBody: destinationBody)
    }

    // MARK: - §6's table, exactly

    func test_aScrapCanBecomeANoteAPaletteCardOrAnIntent() {
        XCTAssertEqual(Set(Promotion.targets(for: .scrap(a), in: scene(), artifacts: index())),
                       [.researchNote, .paletteCard, .intentStatement])
    }

    func test_aRegionCanBecomeAPaletteCardOrAPieceBinding() {
        XCTAssertEqual(Set(Promotion.targets(for: .region(r1), in: scene(), artifacts: index())),
                       [.paletteCard, .pieceBinding])
    }

    func test_anItemNodeOffersNothingBecauseItAlreadyExists() {
        XCTAssertTrue(Promotion.targets(for: .scrap(img), in: scene(),
                                        artifacts: index()).isEmpty)
    }

    func test_anUnknownSourceOffersNothing() {
        let s = scene()
        XCTAssertTrue(Promotion.targets(for: .scrap(CanvasNodeID("ghost")), in: s,
                                        artifacts: index()).isEmpty)
        XCTAssertTrue(Promotion.targets(for: .region(CanvasRegionID("ghost")), in: s,
                                        artifacts: index()).isEmpty)
        XCTAssertTrue(Promotion.targets(for: .line(CanvasLineID("ghost")), in: s,
                                        artifacts: index()).isEmpty)
    }

    // MARK: - A line links two DURABLE things or nothing (§6.1)

    func test_aLineBetweenTwoUnpromotedScrapsOffersNothingAndSaysWhy() {
        let s = scene()
        XCTAssertTrue(Promotion.targets(for: .line(l1), in: s, artifacts: index()).isEmpty)
        let reason = Promotion.blockedReason(for: .line(l1), in: s, artifacts: index())
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("promote"),
                      "the refusal has to teach the precedence at the moment it "
                      + "bites, not show an empty list")
    }

    func test_aLineBetweenTwoPromotedScrapsBecomesAWikiLink() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setPromotedItem("res-b", for: b)
        let idx = index(["res-a": "The falls at night.", "res-b": "October's doctor"])
        XCTAssertEqual(Promotion.targets(for: .line(l1), in: s, artifacts: idx), [.wikiLink])
        XCTAssertNil(Promotion.blockedReason(for: .line(l1), in: s, artifacts: idx))
    }

    func test_aLineWithOnlyOneEndPromotedOffersNothing() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        XCTAssertTrue(Promotion.targets(for: .line(l1), in: s,
                                        artifacts: index(["res-a": "The falls"])).isEmpty)
    }

    /// The dangling mark, which is the case only the index can see: the scrap
    /// still says it was promoted and the note has been deleted since.
    func test_aLineWhosePromotedNoteIsGoneOffersNothing() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setPromotedItem("res-b", for: b)
        let stale = index(["res-a": "The falls at night."])   // res-b deleted
        XCTAssertTrue(Promotion.targets(for: .line(l1), in: s, artifacts: stale).isEmpty)
        XCTAssertNotNil(Promotion.blockedReason(for: .line(l1), in: s, artifacts: stale))
    }

    /// `img` is given a mark that genuinely RESOLVES — the only thing left
    /// refusing this line is the `case .scrap = node.kind` guard in
    /// `resolvedArtifact`. Without a resolving mark on `img`, this would pass
    /// for the "no mark" reason `test_aLineWithOnlyOneEndPromotedOffersNothing`
    /// already covers, and the kind guard could be deleted with the suite
    /// still green. The `blockedReason` assertion pins the specific message
    /// that branch produces, not merely non-nil.
    func test_aLineTouchingANonTextNodeOffersNothing() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setPromotedItem("res-9", for: img)
        let idx = index(["res-a": "The falls", "res-9": "Some placeholder title"])
        XCTAssertTrue(Promotion.targets(for: .line(l2), in: s, artifacts: idx).isEmpty)
        XCTAssertEqual(Promotion.blockedReason(for: .line(l2), in: s, artifacts: idx),
                       "A line becomes a wiki-link only between two cards of text.")
    }

    // MARK: - The plan is a PREVIEW

    func test_planNamesWhatWillBeProducedAndWhere() {
        let plan = Promotion.plan(request(.scrap(a), .researchNote), in: scene())
        XCTAssertEqual(plan?.producedKind, .researchNote)
        XCTAssertEqual(plan?.title, "The falls at night.")
        XCTAssertEqual(plan?.body, "The falls at night.\n\nSodium light on the spray.")
        XCTAssertEqual(plan?.destinationDescription, "research/")
    }

    func test_aTitleComesFromTheFirstLine() {
        XCTAssertEqual(Promotion.title(from: "  The falls at night.  \n\nSodium light."),
                       "The falls at night.")
    }

    func test_anEmptyScrapProducesNoPlan() {
        var r = request(.scrap(a), .researchNote)
        r.scraps = [a: "   \n  "]
        XCTAssertNil(Promotion.plan(r, in: scene()))
    }

    func test_aTargetTheSourceDoesNotOfferProducesNoPlan() {
        XCTAssertNil(Promotion.plan(request(.scrap(a), .pieceBinding, piece: piece),
                                    in: scene()))
    }

    func test_planningNeverMutatesTheScene() {
        let before = scene()
        let s = before
        _ = Promotion.plan(request(.scrap(a), .researchNote), in: s)
        _ = Promotion.plan(request(.region(r1), .paletteCard), in: s)
        _ = Promotion.plan(request(.region(r1), .pieceBinding, piece: piece), in: s)
        XCTAssertEqual(s, before,
                       "nothing promotes because it sat somewhere long enough or "
                       + "looked like something (§6.1)")
    }

    // MARK: - Regions

    func test_regionPromotionJoinsItsResidentsInReadingOrder() {
        let plan = Promotion.plan(request(.region(r1), .paletteCard), in: scene())
        XCTAssertEqual(plan?.title, "Act II fog")
        XCTAssertEqual(plan?.body,
                       "The falls at night.\n\nSodium light on the spray."
                       + "\n\nOctober's doctor was kind about it.",
                       "top card first — the writer's own arrangement, not id order")
    }

    func test_theReadingOrderIsSpatialAndNotTheIdOrder() {
        var s = scene()
        s.move(a, to: CGPoint(x: 0, y: 900))    // "a" now sits BELOW "b"
        let plan = Promotion.plan(request(.region(r1), .paletteCard), in: s)
        XCTAssertEqual(plan?.body,
                       "October's doctor was kind about it."
                       + "\n\nThe falls at night.\n\nSodium light on the spray.")
    }

    func test_anUnlabelledRegionGetsAWriterFacingFallbackTitle() {
        var s = scene()
        s.updateRegion(r1) { $0.label = "" }
        XCTAssertEqual(Promotion.plan(request(.region(r1), .paletteCard), in: s)?.title,
                       CanvasRegion.untitledLabel,
                       "regions are created unlabelled; an untitled palette card "
                       + "is unfindable on the wall")
    }

    /// §6.1: promotion is ALLOWED to be lossy and that is a feature — but the
    /// writer is told which parts are dropped.
    func test_regionPromotionDiscardsLinesAndLayoutAndSaysSo() {
        XCTAssertEqual(Promotion.plan(request(.region(r1), .paletteCard), in: scene())?.discards,
                       [.lines, .layout])
    }

    func test_scrapPromotionDiscardsNothing() {
        XCTAssertTrue(Promotion.plan(request(.scrap(a), .researchNote), in: scene())!
                        .discards.isEmpty)
    }

    // MARK: - The offer (§6.1: may suggest, must never impose)

    func test_regionPromotionOffersLinkingOnlyForAlreadyPromotedMembers() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let plan = Promotion.plan(
            request(.region(r1), .paletteCard,
                    artifacts: index(["res-a": "The falls at night."])), in: s)
        XCTAssertEqual(plan?.offeredLinks.map(\.node), [a])
        XCTAssertEqual(plan?.offeredLinks.first?.itemID, "res-a")
    }

    func test_theOfferDefaultsToDeclined() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let plan = Promotion.plan(
            request(.region(r1), .paletteCard,
                    artifacts: index(["res-a": "The falls at night."])), in: s)
        XCTAssertFalse(plan!.linksAccepted,
                       "an offer that arrives pre-accepted is an imposition with a "
                       + "checkbox; the silent conversion is what §6.1 forbids outright")
    }

    func test_thereIsNoOfferWhenNoMemberIsPromoted() {
        XCTAssertTrue(Promotion.plan(request(.region(r1), .paletteCard), in: scene())!
                        .offeredLinks.isEmpty)
    }

    // MARK: - Update or New (spec §6.1, 2026-07-28 amendment)

    func test_anUnpromotedCardOffersOnlyANewArtifact() {
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                in: scene(), artifacts: index()))
        XCTAssertEqual(Promotion.modes(for: .researchNote, existing: nil), [.new])
    }

    func test_aPromotedCardOffersUpdateAndNewNamingTheArtifact() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let existing = Promotion.existingArtifact(
            for: .scrap(a), target: .researchNote, in: s,
            artifacts: index(["res-a": "The falls at night."]))
        XCTAssertEqual(existing, .update(itemID: "res-a", title: "The falls at night."))
        XCTAssertEqual(Promotion.modes(for: .researchNote, existing: existing),
                       [.new, .update(itemID: "res-a", title: "The falls at night.")])
    }

    func test_aMarkThatNoLongerResolvesOffersNoUpdate() {
        var s = scene()
        s.setPromotedItem("res-gone", for: a)
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                in: s, artifacts: index()),
                     "you cannot update a note that is not in the project any more")
    }

    /// The craft-intent doc ACCUMULATES — one doc per scope, appended to. There
    /// is no "update" that would not mean "replace the writer's whole intent",
    /// so the choice is not offered at all.
    func test_anIntentStatementIsNeverAnUpdate() {
        var s = scene()
        s.setPromotedItem("res-intent", for: a)
        XCTAssertNil(Promotion.existingArtifact(
            for: .scrap(a), target: .intentStatement, in: s,
            artifacts: index(["res-intent": "Craft Intent"])))
    }

    func test_updatingCarriesTheArtifactIntoThePlan() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let plan = Promotion.plan(
            request(.scrap(a), .researchNote,
                    mode: .update(itemID: "res-a", title: "The falls at night."),
                    artifacts: index(["res-a": "The falls at night."])), in: s)
        XCTAssertEqual(plan?.mode, .update(itemID: "res-a", title: "The falls at night."))
        XCTAssertTrue(plan!.destinationDescription.contains("The falls at night."),
                      "the writer must see WHICH note is about to be rewritten")
    }

    // MARK: - Wiki-links and bindings carry their execution path

    private func promotedScene() -> CanvasScene {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setPromotedItem("res-b", for: b)
        return s
    }

    private var bothPromoted: ArtifactIndex {
        index(["res-a": "The falls at night.", "res-b": "October's doctor"])
    }

    func test_theWikiLinkPlanNamesBothEndsAndWhereTheTextGoes() {
        var s = promotedScene()
        s.updateLine(l1) { $0.label = "because of the ponchos" }
        let plan = Promotion.plan(
            request(.line(l1), .wikiLink, artifacts: bothPromoted), in: s)
        XCTAssertEqual(plan?.wikiLinkWrite?.intoNode, a)
        XCTAssertEqual(plan?.wikiLinkWrite?.intoItemID, "res-a")
        XCTAssertEqual(plan?.wikiLinkWrite?.linkText,
                       "[[October's doctor]] — because of the ponchos")
        XCTAssertEqual(plan?.wikiLinkWrite?.appendedText,
                       "\n\n[[October's doctor]] — because of the ponchos\n")
    }

    /// The link names the ARTIFACT, not the scrap. A `[[…]]` naming the card's
    /// first line would resolve to nothing — which is the failure §6.1 forbids,
    /// arriving one step later than the rule that guards against it.
    func test_theLinkNamesTheArtifactAndNotTheCardsFirstLine() {
        let plan = Promotion.plan(request(.line(l1), .wikiLink, artifacts: bothPromoted),
                                  in: promotedScene())
        XCTAssertEqual(plan?.wikiLinkWrite?.linkText, "[[October's doctor]]")
        XCTAssertFalse(plan!.wikiLinkWrite!.linkText.contains("was kind about it"))
    }

    func test_aLinkAlreadyInTheDestinationIsRefusedRatherThanAppendedTwice() {
        let plan = Promotion.plan(
            request(.line(l1), .wikiLink, artifacts: bothPromoted,
                    destinationBody: "The falls.\n\n[[October's doctor]]\n"),
            in: promotedScene())
        XCTAssertTrue(plan!.linkAlreadyPresent)
    }

    func test_aDestinationWithoutTheLinkIsNotRefused() {
        let plan = Promotion.plan(
            request(.line(l1), .wikiLink, artifacts: bothPromoted,
                    destinationBody: "The falls.\n\n[[Something else]]\n"),
            in: promotedScene())
        XCTAssertFalse(plan!.linkAlreadyPresent)
    }

    func test_thePieceBindingPlanCarriesThePieceAndNamesItInTheDestination() {
        let plan = Promotion.plan(request(.region(r1), .pieceBinding, piece: piece),
                                  in: scene())
        XCTAssertEqual(plan?.pieceID, "piece-3")
        XCTAssertTrue(plan!.destinationDescription.contains("Chapter Three"))
        XCTAssertTrue(plan!.discards.isEmpty,
                      "binding drops nothing — the region stays exactly as it is")
    }

    func test_aPieceBindingWithNoPieceChosenProducesNoPlan() {
        XCTAssertNil(Promotion.plan(request(.region(r1), .pieceBinding), in: scene()))
    }

    func test_thePaletteKindRidesThePlan() {
        let plan = Promotion.plan(request(.scrap(a), .paletteCard, kind: .location),
                                  in: scene())
        XCTAssertEqual(plan?.paletteKind, .location)
    }

    // MARK: - The index

    func test_theIndexIsBuiltFromTheWholeResearchTreeIncludingChildren() {
        let child = ResearchItem(id: "res-child", title: "Child", type: .asset,
                                 kind: .document, path: "research/g/child.md", addedAt: Date())
        let group = ResearchItem(id: "res-grp", title: "Group", type: .group,
                                 path: "research/g", addedAt: Date(), children: [child])
        let idx = ArtifactIndex.over(research: [group])
        XCTAssertEqual(idx.title(of: "res-child"), "Child")
        XCTAssertEqual(idx.title(of: "res-grp"), "Group")
        XCTAssertNil(idx.title(of: "res-nope"))
    }
}
