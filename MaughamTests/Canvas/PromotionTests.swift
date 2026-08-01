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
        s.insert(CanvasNode(id: img, kind: .item(.project(id: "r-9")),
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

    private func index(_ pairs: [String: String] = [:]) -> ArtifactIndex {
        ArtifactIndex(titlesByID: pairs)
    }

    private func request(_ source: PromotionSource,
                         _ target: PromotionTarget,
                         scene: CanvasScene? = nil,
                         mode: PromotionMode = .new,
                         kind: PaletteCard.Kind = .other,
                         artifacts: ArtifactIndex? = nil,
                         destinationBody: String? = nil) -> PromotionRequest {
        PromotionRequest(source: source, target: target, mode: mode, scraps: texts,
                         paletteKind: kind,
                         artifacts: artifacts ?? index(), destinationBody: destinationBody)
    }

    // MARK: - §6's table, exactly

    func test_aScrapCanBecomeANoteAPaletteCardOrAnIntent() {
        XCTAssertEqual(Set(Promotion.targets(for: .scrap(a), in: scene(), artifacts: index())),
                       [.researchNote, .paletteCard, .intentStatement])
    }

    /// A region's binding to a piece is spec §6.2's ASSOCIATION now (set by the
    /// inspector's own picker), not a promotion target — it produces no
    /// artifact, and the picker already sets it. Amendment, 2026-07-29.
    func test_aRegionCanBecomeANoteOrAPaletteCard() {
        XCTAssertEqual(Set(Promotion.targets(for: .region(r1), in: scene(), artifacts: index())),
                       [.researchNote, .paletteCard])
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
        let reason = Promotion.blockedReason(for: .line(l1), in: s, scraps: texts,
                                             artifacts: index())
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("promote"),
                      "the refusal has to teach the precedence at the moment it "
                      + "bites, not show an empty list")
        XCTAssertTrue(reason!.hasPrefix("Promote both cards first."),
                      "the never-promoted message, which is the CONTROL for the "
                      + "dangling-mark one below: both are non-nil and only the "
                      + "wording tells them apart. found: \(reason!)")
    }

    func test_aLineBetweenTwoPromotedScrapsBecomesAWikiLink() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setPromotedItem("res-b", for: b)
        let idx = index(["res-a": "The falls at night.", "res-b": "October's doctor"])
        XCTAssertEqual(Promotion.targets(for: .line(l1), in: s, artifacts: idx), [.wikiLink])
        XCTAssertNil(Promotion.blockedReason(for: .line(l1), in: s, scraps: texts, artifacts: idx))
    }

    func test_aLineWithOnlyOneEndPromotedOffersNothing() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        XCTAssertTrue(Promotion.targets(for: .line(l1), in: s,
                                        artifacts: index(["res-a": "The falls"])).isEmpty)
    }

    /// The dangling mark, which is the case only the index can see: the scrap
    /// still says it was promoted and the note has been deleted since.
    ///
    /// **The message must not be the other one.** "Promote both cards first"
    /// tells this writer to do the thing they already did — they promoted the
    /// card and then deleted the note — and `blockedReason` has the same
    /// information `ScrapInspector` uses to distinguish the two states.
    func test_aLineWhosePromotedNoteIsGoneSaysThatRatherThanTellingThemToPromoteIt() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setPromotedItem("res-b", for: b)
        let stale = index(["res-a": "The falls at night."])   // res-b deleted
        XCTAssertTrue(Promotion.targets(for: .line(l1), in: s, artifacts: stale).isEmpty)
        let reason = Promotion.blockedReason(for: .line(l1), in: s, scraps: texts,
                                             artifacts: stale)
        XCTAssertEqual(reason,
                       "What one of these cards produced is no longer in the "
                       + "project, so there is nothing left for a link to point at. "
                       + "Promote that card again first.")
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
        XCTAssertEqual(Promotion.blockedReason(for: .line(l2), in: s, scraps: texts, artifacts: idx),
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
        // A scrap never offers `.wikiLink` — only a line does.
        XCTAssertNil(Promotion.plan(request(.scrap(a), .wikiLink), in: scene()))
    }

    func test_planningNeverMutatesTheScene() {
        let before = scene()
        let s = before
        _ = Promotion.plan(request(.scrap(a), .researchNote), in: s)
        _ = Promotion.plan(request(.region(r1), .paletteCard), in: s)
        _ = Promotion.plan(request(.region(r1), .researchNote), in: s)
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

    /// Amendment, 2026-07-29: a region's binding is no longer a promotion
    /// target — its case for `.researchNote` is the natural artifact for a
    /// cluster of text scraps, joined in the region's own reading order
    /// exactly as `.paletteCard` already is.
    func test_aRegionPromotedToAResearchNoteJoinsItsResidentsInReadingOrder() {
        let plan = Promotion.plan(request(.region(r1), .researchNote), in: scene())
        XCTAssertEqual(plan?.title, "Act II fog")
        XCTAssertEqual(plan?.body,
                       "The falls at night.\n\nSodium light on the spray."
                       + "\n\nOctober's doctor was kind about it.")
        XCTAssertEqual(plan?.destinationDescription, "research/")
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

    /// The other region target discards the same things, for the same reason —
    /// this is what makes it safe for the two targets to share one plan branch.
    func test_aRegionsResearchNoteDiscardsLinesAndLayoutToo() {
        XCTAssertEqual(Promotion.plan(request(.region(r1), .researchNote), in: scene())?.discards,
                       [.lines, .layout])
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

    /// "Its link offer is unchanged" (task brief) — the same offer a region's
    /// palette-card plan carries.
    func test_aRegionsResearchNoteOffersLinkingOnlyForAlreadyPromotedMembersToo() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let plan = Promotion.plan(
            request(.region(r1), .researchNote,
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

    func test_thePaletteKindRidesThePlan() {
        let plan = Promotion.plan(request(.scrap(a), .paletteCard, kind: .location),
                                  in: scene())
        XCTAssertEqual(plan?.paletteKind, .location)
    }

    // MARK: - A mark names a KIND, and a second promotion may not overwrite it

    /// The index, built the way production builds it: the palette group with a
    /// card inside it, a craft-intent doc, and a plain note.
    private func realIndex() -> ArtifactIndex {
        let card = ResearchItem(id: "res-card", title: "Act II fog", type: .asset,
                                kind: .document, path: "research/palette/act-ii-fog.md")
        let group = ResearchItem(id: "res-palette", title: "Palette", type: .group,
                                 path: PaletteConvention.folderPath,
                                 children: [card], role: .paletteGroup)
        let intent = ResearchItem(id: "res-intent", title: "Craft Intent", type: .asset,
                                  kind: .document, path: "research/craft-intent.md",
                                  role: .craftIntent)
        let note = ResearchItem(id: "res-note", title: "The falls at night", type: .asset,
                                kind: .document, path: "research/the-falls-at-night.md")
        return ArtifactIndex.over(research: [group, intent, note],
                                  statements: [], structure: [])
    }

    func test_theIndexSaysWhatKindOfArtifactEachIdNames() {
        let idx = realIndex()
        XCTAssertEqual(idx.kind(of: "res-card"), .paletteCard)
        XCTAssertEqual(idx.kind(of: "res-intent"), .craftIntent)
        XCTAssertEqual(idx.kind(of: "res-note"), .researchNote)
        XCTAssertNil(idx.kind(of: "res-gone"))
    }

    /// **The destructive sequence, in the model.** Promote a card to a palette
    /// card, then promote the same card as a research note: the mark names the
    /// palette card, and before the kind term every mark resolved for every
    /// updatable target — so the sheet offered "Rewrite “Act II fog”" and
    /// committing renamed the palette card's file and wrote raw scrap text over
    /// its body.
    ///
    /// The control is the line below it: the SAME mark, asked for the target it
    /// actually produced, still answers `.update`. Without that, deleting
    /// `existingArtifact`'s body entirely would satisfy the first assertion.
    func test_aPaletteCardsMarkOffersNoUpdateToAResearchNote() {
        var s = scene()
        s.setPromotedItem("res-card", for: a)
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                in: s, artifacts: realIndex()),
                     "a research-note promotion must never offer to rewrite the "
                     + "writer's palette card — the swatches, the kind, the sensory "
                     + "notes and the image references are not in the plan")
        XCTAssertEqual(Promotion.existingArtifact(for: .scrap(a), target: .paletteCard,
                                                  in: s, artifacts: realIndex()),
                       .update(itemID: "res-card", title: "Act II fog"),
                       "and the mark still updates the thing it actually named")
    }

    /// The sharper variant: the craft intent is one accumulating doc per scope,
    /// and a research-note "update" over it replaces the writer's whole intent
    /// statement with one card — which is exactly what excluding
    /// `.intentStatement` from `updatableTargets` exists to prevent, arriving
    /// through the other door.
    func test_aCraftIntentsMarkOffersNoUpdateToAResearchNote() {
        var s = scene()
        s.setPromotedItem("res-intent", for: a)
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                in: s, artifacts: realIndex()))
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .paletteCard,
                                                in: s, artifacts: realIndex()))
    }

    /// A region's mark takes the same rule, and by the same route.
    func test_aRegionsResearchNoteMarkOffersNoUpdateToAPaletteCard() {
        var s = scene()
        s.updateRegion(r1) { $0.promotedItemID = "res-note" }
        XCTAssertNil(Promotion.existingArtifact(for: .region(r1), target: .paletteCard,
                                                in: s, artifacts: realIndex()))
        XCTAssertEqual(Promotion.existingArtifact(for: .region(r1), target: .researchNote,
                                                  in: s, artifacts: realIndex()),
                       .update(itemID: "res-note", title: "The falls at night"))
    }

    // MARK: - Why a source offers nothing (§6.1's "say why")

    /// An empty scrap IS offered all three targets — emptiness is not a targets
    /// question — and then `plan` returns nil, so `preview`, `resolvedPlan` and
    /// `refusal` were all nil together and the writer met a dead sheet with no
    /// message in it. Empty scraps persist; a stray double-click leaves one.
    func test_anEmptyScrapSaysWhyRatherThanOpeningADeadSheet() {
        let reason = Promotion.blockedReason(for: .scrap(a), in: scene(),
                                             scraps: [a: "   \n  "], artifacts: index())
        XCTAssertEqual(reason, PromotionFailure.emptyBody(source: .scrap(a)).errorDescription,
                       "the performer's own sentence rather than a second wording")
        XCTAssertEqual(reason, "There is nothing in this card to promote.",
                       "found: \(reason ?? "nil")")
        XCTAssertNil(Promotion.blockedReason(for: .scrap(a), in: scene(), scraps: texts,
                                             artifacts: index()),
                     "and a card with words in it is not blocked — the control")
    }

    func test_anItemNodeSaysWhyRatherThanOfferingAnEmptyList() {
        XCTAssertEqual(Promotion.blockedReason(for: .scrap(img), in: scene(),
                                               scraps: texts, artifacts: index()),
                       Promotion.itemNodeReason)
    }

    func test_aRegionWithWordsInItIsNotBlocked() {
        XCTAssertNil(Promotion.blockedReason(for: .region(r1), in: scene(),
                                             scraps: texts, artifacts: index()))
    }

    /// **The scrap arm's defect, on the other row.** `blockedReason` answered
    /// nil unconditionally for a region and `plan` had no emptiness guard, so a
    /// region holding nothing previewed an empty body with Promote enabled and
    /// then threw at Commit — and threw in the SCRAP's noun. It is pre-existing,
    /// and 1C-c2a is what made it matter: `.researchNote` is the headline verb on
    /// this row now, so "a cluster of scraps is a note" is exactly what a writer
    /// tries on a region they have only just drawn.
    func test_anEmptyRegionSaysWhyAndSaysItInTheRightNoun() {
        let empty: [CanvasNodeID: String] = [a: "  ", b: "\n"]
        let reason = Promotion.blockedReason(for: .region(r1), in: scene(),
                                             scraps: empty, artifacts: index())
        XCTAssertEqual(reason, "There is nothing in this region to promote.",
                       "found: \(reason ?? "nil")")
        XCTAssertEqual(reason, PromotionFailure.emptyBody(source: .region(r1)).errorDescription,
                       "the performer's own sentence rather than a second wording")
    }

    /// A region with no residents at all — the state a freshly swept region on
    /// bare canvas is in.
    func test_aRegionWithNoResidentsIsBlockedTheSameWay() {
        var s = scene()
        let bare = CanvasRegionID("r2")
        s.insertRegion(CanvasRegion(id: bare, label: "Just drawn",
                                    frame: CGRect(x: 900, y: 0, width: 300, height: 200)))
        XCTAssertEqual(Promotion.blockedReason(for: .region(bare), in: s,
                                               scraps: texts, artifacts: index()),
                       "There is nothing in this region to promote.")
    }

    /// The other half of the pair: the preview and the refusal must agree about
    /// what "empty" means, or the writer meets a dead sheet again.
    func test_anEmptyRegionPlansNothingRatherThanPreviewingAnEmptyBody() {
        var request = self.request(.region(r1), .researchNote)
        request.scraps = [a: "   ", b: ""]
        XCTAssertNil(Promotion.plan(request, in: scene()))
    }

    // MARK: - Who is asked for a name

    /// `previewSection` rendered a `Name` field for four of the five targets and
    /// `canCommit` required one — but `performWikiLink` never reads `plan.title`
    /// and neither does `performCraftIntent`. So promoting a line showed a field
    /// seeded with the source note's title that changed nothing, and clearing it
    /// disabled Promote with "This needs a name." for an act that names nothing.
    func test_onlyTheTargetsWhoseArtifactTheWriterNamesAskForOne() {
        XCTAssertEqual(PromotionTarget.allCases.filter(\.namesItsArtifact),
                       [.researchNote, .paletteCard])
    }

    func test_everyTargetThatProducesAResearchItemSaysWhichKind() {
        XCTAssertEqual(PromotionTarget.researchNote.producedArtifactKind, .researchNote)
        XCTAssertEqual(PromotionTarget.paletteCard.producedArtifactKind, .paletteCard)
        XCTAssertEqual(PromotionTarget.intentStatement.producedArtifactKind, .craftIntent)
        XCTAssertNil(PromotionTarget.wikiLink.producedArtifactKind,
                     "a link is text inside somebody else's note")
    }

    /// §6.1 requires the writer see what will be produced and where — and the
    /// craft intent APPENDS, which the destination line did not say.
    func test_theCraftIntentDestinationSaysThatItAppends() {
        let plan = Promotion.plan(request(.scrap(a), .intentStatement), in: scene())
        XCTAssertTrue(plan!.destinationDescription.contains("craft intent"))
        XCTAssertTrue(plan!.destinationDescription.contains("already there"),
                      "two cards promoted to craft intent stack; saying only "
                      + "\"the project's craft intent\" leaves that to be "
                      + "discovered by doing it. found: \(plan!.destinationDescription)")
    }

    // MARK: - The index

    func test_theIndexIsBuiltFromTheWholeResearchTreeIncludingChildren() {
        let child = ResearchItem(id: "res-child", title: "Child", type: .asset,
                                 kind: .document, path: "research/g/child.md", addedAt: Date())
        let group = ResearchItem(id: "res-grp", title: "Group", type: .group,
                                 path: "research/g", addedAt: Date(), children: [child])
        let idx = ArtifactIndex.over(research: [group], statements: [], structure: [])
        XCTAssertEqual(idx.title(of: "res-child"), "Child")
        XCTAssertEqual(idx.title(of: "res-grp"), "Group")
        XCTAssertNil(idx.title(of: "res-nope"))
    }
}
