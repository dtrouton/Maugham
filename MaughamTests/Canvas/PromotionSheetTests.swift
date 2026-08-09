import XCTest
import MaughamCore
@testable import Maugham

/// The sheet's model — §6.1's "previewable", made a value a test can drive.
/// Which SwiftUI arm renders cannot be asserted (`_ConditionalContent`'s type is
/// branch-invariant), so everything the view branches on lives here instead.
@MainActor
final class PromotionSheetTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let r1 = CanvasRegionID("r1")
    private let l1 = CanvasLineID("l1")

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 0, y: 200),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [a, b]))
        s.insertLine(CanvasLine(id: l1, from: a, to: b))
        return s
    }

    private let texts: [CanvasNodeID: String] = [
        CanvasNodeID("a"): "The falls\n\nbody",
        CanvasNodeID("b"): "October's doctor",
    ]

    private func model(_ source: PromotionSource,
                       scene: CanvasScene? = nil,
                       artifacts: [String: String] = [:],
                       body: @escaping (String) -> String? = { _ in nil }) -> PromotionSheetModel {
        PromotionSheetModel(source: source, scene: scene ?? self.scene(), scraps: texts,
                            artifacts: ArtifactIndex(titlesByID: artifacts),
                            items: .empty,
                            piece: .none, readBody: body)
    }

    // MARK: - Opening

    func test_theSheetOffersExactlyTheTargetsTheModelAllows() {
        XCTAssertEqual(Set(model(.scrap(a)).availableTargets),
                       [.researchNote, .paletteCard, .intentStatement])
        XCTAssertEqual(Set(model(.region(r1)).availableTargets),
                       [.researchNote, .paletteCard])
    }

    func test_itStartsWithNothingSelectedSoNothingCommitsByAccident() {
        let m = model(.scrap(a))
        XCTAssertNil(m.selectedTarget)
        XCTAssertNil(m.preview)
        XCTAssertFalse(m.canCommit)
        // Nothing is wrong yet — the reason Commit is off is simply "choose a
        // target", which `refusal` explicitly does not speak to (its own doc
        // comment says so). Before this fix, `resolvedPlan` fell back to
        // `.researchNote` even with no target chosen, so this read
        // "This needs a name." at the moment the sheet first appears.
        XCTAssertNil(m.refusal)
    }

    func test_aBlockedSourceSaysWhyInsteadOfShowingAnEmptyList() {
        let m = model(.line(l1))
        XCTAssertTrue(m.availableTargets.isEmpty)
        XCTAssertNotNil(m.blockedReason)
        XCTAssertFalse(m.canCommit)
    }

    func test_theSourceIsNamedSoTheWriterKnowsWhatTheyInvokedItOn() {
        XCTAssertTrue(model(.scrap(a)).sourceDescription.contains("The falls"))
        XCTAssertTrue(model(.region(r1)).sourceDescription.contains("Act II fog"))
    }

    // MARK: - An owned picture (spec §6's 2026-07-30 amendment)

    private let picture = CanvasNodeID("owned-1")

    /// A scene whose owned picture is what the sheet is opened on.
    private func pictureScene() -> CanvasScene {
        var s = scene()
        s.insert(CanvasNode(id: picture,
                            kind: .item(.owned(path: "canvas_assets/p.png")),
                            origin: CGPoint(x: 400, y: 0), width: 180, cachedHeight: 200))
        return s
    }

    private func pictureModel(cards: Bool = true) -> PromotionSheetModel {
        var entries: [String: ArtifactIndex.Entry] = [:]
        if cards {
            entries["res-card"] = .init(title: "Colour: October", kind: .paletteCard)
            entries["res-other"] = .init(title: "Zinc", kind: .paletteCard)
        }
        return PromotionSheetModel(source: .scrap(picture), scene: pictureScene(),
                                   scraps: texts,
                                   artifacts: ArtifactIndex(entriesByID: entries),
                                   items: .empty,
                                   piece: .none, readBody: { _ in nil })
    }

    /// **"The card “Image”" is what this said**, and it is a false noun wrapped
    /// around a word that identifies nothing: every owned picture resolves to the
    /// same title, and what tells one from another is the picture drawn on it.
    func test_anOwnedPictureIsNamedAsAPictureAndNotAsACard() {
        XCTAssertEqual(pictureModel().sourceDescription, "This picture")
        XCTAssertTrue(model(.scrap(a)).sourceDescription.hasPrefix("The card"),
                      "the control: a scrap is still a card")
    }

    /// **The sentence is true of ONE provenance, so it destructures one** (review
    /// M3). `if case .item` alone described a referenced research note as "This
    /// picture" — unreachable, since `isPromotable` refuses a reference and
    /// `ItemInspector` withholds the button, but it was the one site in this task
    /// testing the KIND where every other site that differs destructures the
    /// provenance.
    func test_aReferencedItemIsNotDescribedAsAPicture() {
        var s = pictureScene()
        let referenced = CanvasNodeID.item("r-9")
        s.insert(CanvasNode(id: referenced, kind: .item(.project(id: "r-9")),
                            origin: CGPoint(x: 800, y: 0), width: 180, cachedHeight: 120))
        let m = PromotionSheetModel(source: .scrap(referenced), scene: s, scraps: texts,
                                    artifacts: ArtifactIndex(titlesByID: ["r-9": "A note"]),
                                    items: .empty,
                                    piece: .none, readBody: { _ in nil })
        XCTAssertNotEqual(m.sourceDescription, "This picture",
                          "a reference is not a picture — found: \(m.sourceDescription)")
        XCTAssertEqual(pictureModel().sourceDescription, "This picture",
                       "the control: the owned one still is")
    }

    /// The picker is SEEDED, so the writer never meets an empty control over a
    /// dead Promote button — `Promotion.plan` returns nothing without a card.
    func test_choosingThePaletteRowSeedsACardAndCommitsWithoutAName() {
        let m = pictureModel()
        m.select(.paletteCardImage)
        XCTAssertEqual(m.paletteCardID, "res-card", "the first by title")
        XCTAssertEqual(m.preview?.destinationDescription, "the palette card “Colour: October”")
        XCTAssertTrue(m.canCommit)
        XCTAssertNil(m.refusal,
                     "and no \"This needs a name.\" — an appended image names "
                     + "nothing, so the sheet does not ask")
        XCTAssertTrue(m.editedTitle.isEmpty || m.selectedTarget?.namesItsArtifact == false)
    }

    /// Changing the card moves what "Goes to" says, not only what Commit does —
    /// `mode`'s rule, on the other picker. A frozen destination is the exact lie
    /// §6.1 exists to prevent.
    func test_changingTheCardMovesThePreview() {
        let m = pictureModel()
        m.select(.paletteCardImage)
        m.paletteCardID = "res-other"
        XCTAssertEqual(m.preview?.destinationDescription, "the palette card “Zinc”")
        XCTAssertEqual(m.resolvedPlan?.pictures.first?.paletteCardID, "res-other")
    }

    func test_theResearchRowCarriesNoCardAndStillCommits() {
        let m = pictureModel()
        m.select(.researchAsset)
        XCTAssertNil(m.paletteCardID,
                     "a card chosen on the other row must not survive into this one")
        XCTAssertEqual(m.preview?.destinationDescription, "research/")
        XCTAssertTrue(m.canCommit)
    }

    func test_aProjectWithNoPaletteCardsIsOfferedOnlyTheResearchRow() {
        XCTAssertEqual(pictureModel(cards: false).availableTargets, [.researchAsset])
        XCTAssertEqual(pictureModel().availableTargets, [.researchAsset, .paletteCardImage],
                       "the control")
    }

    // MARK: - Choosing a target

    func test_choosingATargetProducesAPreviewBeforeAnythingIsWritten() {
        let m = model(.scrap(a))
        m.select(.researchNote)
        XCTAssertEqual(m.preview?.title, "The falls")
        XCTAssertEqual(m.preview?.destinationDescription, "research/")
        XCTAssertTrue(m.canCommit)
    }

    func test_choosingATargetSeedsTheEditableTitle() {
        let m = model(.scrap(a))
        m.select(.researchNote)
        XCTAssertEqual(m.editedTitle, "The falls")
    }

    func test_theWriterCanEditTheTitleBeforeCommitting() {
        let m = model(.scrap(a))
        m.select(.researchNote)
        m.editedTitle = "Niagara, 3am"
        XCTAssertEqual(m.resolvedPlan?.title, "Niagara, 3am")
        XCTAssertEqual(m.resolvedPlan?.body, "The falls\n\nbody",
                       "editing the title must not touch the body")
    }

    func test_anEmptyEditedTitleBlocksCommit() {
        let m = model(.scrap(a))
        m.select(.researchNote)
        m.editedTitle = "   "
        XCTAssertFalse(m.canCommit, "the performer would refuse it; the sheet says so first")
    }

    func test_switchingTargetsReseedsTheTitleRatherThanKeepingAnEdit() {
        let m = model(.scrap(a))
        m.select(.researchNote)
        m.editedTitle = "Niagara, 3am"
        m.select(.paletteCard)
        XCTAssertEqual(m.editedTitle, "The falls")
    }

    // MARK: - Update or New

    func test_anUnpromotedSourceOffersOnlyNew() {
        let m = model(.scrap(a))
        m.select(.researchNote)
        XCTAssertEqual(m.availableModes, [.new])
    }

    func test_aPromotedSourceOffersBothAndStartsOnNew() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let m = model(.scrap(a), scene: s, artifacts: ["res-a": "The falls"])
        m.select(.researchNote)
        XCTAssertEqual(m.availableModes, [.new, .update(itemID: "res-a", title: "The falls")])
        XCTAssertEqual(m.mode, .new,
                       "rewriting the writer's note must never be the thing under "
                       + "the cursor")
    }

    func test_choosingUpdateNamesTheNoteThatWillBeRewritten() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let m = model(.scrap(a), scene: s, artifacts: ["res-a": "The falls"])
        m.select(.researchNote)
        m.mode = .update(itemID: "res-a", title: "The falls")
        XCTAssertTrue(m.resolvedPlan!.destinationDescription.contains("The falls"))
    }

    /// `previewSection` renders `model.preview` — and only `model.preview` —
    /// for the "Goes to" line and the body excerpt. Before this fix, `preview`
    /// was captured once inside `select(_:)` under a hardcoded `mode: .new`,
    /// so choosing "Rewrite "The falls"" from the mode picker left the sheet
    /// still showing "research/" a line above the Promote button, while
    /// Commit was about to overwrite the existing note. That is the one
    /// signal §6.1 requires before an overwrite, and it was the value the
    /// view actually renders that lied — not `resolvedPlan`, which was always
    /// correct and is what `test_choosingUpdateNamesTheNoteThatWillBeRewritten`
    /// above already pins.
    func test_thePreviewDisplayTracksTheChosenModeRatherThanAFrozenNewSnapshot() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let m = model(.scrap(a), scene: s, artifacts: ["res-a": "The falls"])
        m.select(.researchNote)
        XCTAssertEqual(m.preview?.destinationDescription, "research/")
        m.mode = .update(itemID: "res-a", title: "The falls")
        XCTAssertTrue(m.preview!.destinationDescription.contains("The falls"),
                      "the sheet's own \"Goes to\" line must show the note "
                      + "Commit is about to overwrite, not a snapshot frozen "
                      + "at the moment the target was chosen")
    }

    /// M6-PR-038/M6-PR-039, RULING-22, fixed 2026-08-09 — the sheet's third
    /// string can no longer disagree with its other two.
    ///
    /// The Name field was seeded from the card's first line by `select(_:)` and
    /// never re-seeded when the writer chose Rewrite. `resolvedPlan` writes that
    /// field over `plan.title`, and the performer renamed the note (and its file)
    /// to match — so the writer's own rename of that note in the research pane
    /// was silently reverted by an act neither of the sheet's labels described.
    func test_choosingRewriteWithdrawsTheNameFieldAndCarriesTheArtifactsOwnName() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let m = model(.scrap(a), scene: s, artifacts: ["res-a": "Fog, act II"])
        m.select(.researchNote)
        XCTAssertTrue(m.namesTheArtifact, "a NEW note is the writer's to name")
        XCTAssertEqual(m.editedTitle, "The falls", "seeded from the card's first line")

        m.mode = .update(itemID: "res-a", title: "Fog, act II")
        XCTAssertFalse(m.namesTheArtifact,
                       "a rewrite writes into an artifact that is already named, and a "
                       + "field that renames it is not a control the sheet described")
        XCTAssertEqual(m.editedTitle, "Fog, act II",
                       "and the name it carries to Commit is the artifact's own")
        XCTAssertEqual(m.resolvedPlan?.title, "Fog, act II")
        XCTAssertEqual(m.resolvedPlan?.destinationDescription, "the existing “Fog, act II”",
                       "one name for one artifact — this is the value `title` now reads")
        XCTAssertNil(m.refusal)
        XCTAssertTrue(m.canCommit)

        m.mode = .new
        XCTAssertTrue(m.namesTheArtifact)
        XCTAssertEqual(m.editedTitle, "The falls",
                       "and a new promotion is seeded from the card again")
    }

    /// Whole-branch review, 2026-08-09 — looking at Rewrite and coming back
    /// must not cost the writer what they typed.
    ///
    /// The re-seed that fixed M6-PR-039 is one-way by construction: the way back
    /// is the same assignment reading a `.new` plan, which answers with the
    /// card's first line. So a writer who named their note, opened the mode
    /// picker to see what Rewrite would do, and chose New again found their name
    /// replaced. Typing is the one thing on this sheet that clicking again
    /// cannot recover.
    func test_aNameTheWriterTypedSurvivesALookAtRewriteAndBack() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let m = model(.scrap(a), scene: s, artifacts: ["res-a": "Fog, act II"])
        m.select(.researchNote)
        m.editedTitle = "Sodium light on the spray"

        m.mode = .update(itemID: "res-a", title: "Fog, act II")
        XCTAssertEqual(m.editedTitle, "Fog, act II",
                       "a rewrite still carries the artifact's own name (M6-PR-039)")

        m.mode = .new
        XCTAssertEqual(m.editedTitle, "Sodium light on the spray",
                       "and the writer's own name is given back, not the card's first line")
        XCTAssertEqual(m.resolvedPlan?.title, "Sodium light on the spray",
                       "which is the value Commit would carry")
    }

    /// Whole-branch review, 2026-08-09 — `canCommit` and `refusal` read ONE
    /// condition, so they cannot disagree.
    ///
    /// A rewrite withdraws the Name field (`namesTheArtifact` is false) and the
    /// refusal is gated on that same value — but `canCommit` still asked the
    /// TARGET, which says a research note is named. A rewrite whose resolved
    /// title came back empty therefore disabled Promote and explained nothing:
    /// the dead sheet, reached by two conditions drifting rather than by either
    /// being wrong on its own.
    func test_aRewriteNeverDisablesCommitWithoutSayingWhy() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let m = model(.scrap(a), scene: s, artifacts: ["res-a": ""])
        m.select(.researchNote)
        m.mode = .update(itemID: "res-a", title: "")
        XCTAssertEqual(m.editedTitle, "", "the artifact's own name, such as it is")
        XCTAssertFalse(m.namesTheArtifact, "and no field on the sheet asks for one")
        XCTAssertNil(m.refusal, "the sheet says nothing is wrong")
        XCTAssertTrue(m.canCommit,
                      "so Commit must be live — the performers fall back to the "
                      + "artifact's live name, and a rewrite was never about the name")
    }

    func test_switchingToATargetThatCannotUpdateResetsTheMode() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let m = model(.scrap(a), scene: s, artifacts: ["res-a": "The falls"])
        m.select(.researchNote)
        m.mode = .update(itemID: "res-a", title: "The falls")
        m.select(.intentStatement)
        XCTAssertEqual(m.mode, .new)
        XCTAssertEqual(m.availableModes, [.new], "an intent doc accumulates")
    }

    // MARK: - The offer, the discards, the kind

    func test_theLinkOfferArrivesUncheckedForARegion() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let m = model(.region(r1), scene: s, artifacts: ["res-a": "The falls"])
        m.select(.paletteCard)
        XCTAssertEqual(m.preview?.offeredLinks.count, 1)
        XCTAssertFalse(m.linksAccepted)
        XCTAssertFalse(m.resolvedPlan!.linksAccepted)
        m.linksAccepted = true
        XCTAssertTrue(m.resolvedPlan!.linksAccepted)
    }

    func test_theDiscardsAreSpelledOutForARegionAndAbsentForAScrap() {
        let region = model(.region(r1))
        region.select(.paletteCard)
        let notice = try? XCTUnwrap(region.discardNotice)
        XCTAssertTrue(notice?.lowercased().contains("line") == true)
        XCTAssertTrue(notice?.lowercased().contains("layout") == true)

        let scrap = model(.scrap(a))
        scrap.select(.researchNote)
        XCTAssertNil(scrap.discardNotice)
    }

    func test_thePaletteKindRidesTheResolvedPlan() {
        let m = model(.scrap(a))
        m.select(.paletteCard)
        m.paletteKind = .motif
        XCTAssertEqual(m.resolvedPlan?.paletteKind, .motif)
    }

    // MARK: - Wiki-links

    private func promotedScene() -> CanvasScene {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setPromotedItem("res-b", for: b)
        return s
    }

    func test_aLineWithBothEndsPromotedPreviewsTheExactTextItWillAppend() {
        let m = model(.line(l1), scene: promotedScene(),
                      artifacts: ["res-a": "The falls", "res-b": "October's doctor"])
        XCTAssertEqual(m.availableTargets, [.wikiLink])
        m.select(.wikiLink)
        XCTAssertEqual(m.preview?.wikiLinkWrite?.linkText, "[[October's doctor]]")
        XCTAssertTrue(m.canCommit)
    }

    /// The destination is read ONCE, when the target is chosen — not per body
    /// evaluation, and not per keystroke in the title field.
    func test_theDestinationIsReadOnceAndARepeatedLinkRefusesCommit() {
        var reads = 0
        let m = model(.line(l1), scene: promotedScene(),
                      artifacts: ["res-a": "The falls", "res-b": "October's doctor"],
                      body: { _ in reads += 1; return "The falls.\n\n[[October's doctor]]\n" })
        m.select(.wikiLink)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(m.preview!.linkAlreadyPresent)
        XCTAssertFalse(m.canCommit)
        XCTAssertNotNil(m.refusal)
        _ = m.resolvedPlan
        XCTAssertEqual(reads, 1, "resolving a plan must not go back to disk")
    }

    /// A wiki-link names nothing: `performWikiLink` never reads `plan.title`.
    /// The field was shown anyway, seeded from the *destination note's* title,
    /// and clearing it disabled Promote with "This needs a name."
    func test_aWikiLinkNeedsNoNameAndCommitsWithTheFieldEmpty() {
        let m = model(.line(l1), scene: promotedScene(),
                      artifacts: ["res-a": "The falls", "res-b": "October's doctor"])
        m.select(.wikiLink)
        XCTAssertFalse(m.selectedTarget!.namesItsArtifact,
                       "the sheet renders the Name field on this flag")
        m.editedTitle = ""
        XCTAssertTrue(m.canCommit, "a line promotion names nothing, so an empty "
                      + "field cannot be what stops it")
        XCTAssertNil(m.refusal)
    }

    /// The craft intent is find-or-create at a fixed title and the body is
    /// appended — `performCraftIntent` never reads `plan.title` either.
    func test_aCraftIntentNeedsNoNameAndCommitsWithTheFieldEmpty() {
        let m = model(.scrap(a))
        m.select(.intentStatement)
        XCTAssertFalse(m.selectedTarget!.namesItsArtifact)
        m.editedTitle = "  "
        XCTAssertTrue(m.canCommit)
        XCTAssertNil(m.refusal)
    }

    /// The control for both of the above: the two targets that DO name their
    /// artifact still refuse an empty field, so the fix narrowed the rule rather
    /// than deleting it.
    func test_theTargetsThatDoNameTheirArtifactStillRefuseAnEmptyName() {
        for target in [PromotionTarget.researchNote, .paletteCard] {
            let m = model(.scrap(a))
            m.select(target)
            XCTAssertTrue(m.selectedTarget!.namesItsArtifact, "\(target)")
            m.editedTitle = "   "
            XCTAssertFalse(m.canCommit, "\(target)")
            XCTAssertEqual(m.refusal, "This needs a name.", "\(target)")
        }
    }

    // MARK: - Sources that cannot commit say why

    /// The dead sheet: all three targets offered, no plan behind any of them, so
    /// `preview`, `resolvedPlan` and `refusal` were nil together and the writer
    /// got an empty Name field, no destination and a dead button.
    func test_anEmptyScrapIsBlockedWithAReasonRatherThanOfferingTargets() {
        let m = PromotionSheetModel(source: .scrap(a), scene: scene(),
                                    scraps: [a: "   "],
                                    artifacts: ArtifactIndex(titlesByID: [:]),
                                    items: .empty,
                                    piece: .none, readBody: { _ in nil })
        XCTAssertNotNil(m.blockedReason)
        XCTAssertFalse(m.canCommit)
        // The control: the same card with words in it is not blocked, so the
        // assertion above is about emptiness and not about the fixture.
        XCTAssertNil(model(.scrap(a)).blockedReason)
    }

    /// **What is shown BESIDE a reason has to be about the writer's situation
    /// too.** `precedenceNote` is line-specific, and while `blockedReason` was
    /// non-nil only for lines the pairing was right by construction. Widening
    /// the reason to cover the empty scrap and the item node made it wrong — a
    /// writer with an empty card read "There is nothing in this card to
    /// promote." followed by a paragraph about lines and wiki-links — which is
    /// finding 8's own defect one file over.
    ///
    /// The line arm is the control: it is the source the note is about, and it
    /// still carries it, so this is about the pairing and not about the note
    /// having been deleted.
    func test_thePrecedenceNoteIsShownOnlyForTheSourceItIsAbout() {
        let line = model(.line(l1))
        XCTAssertNotNil(line.blockedReason)
        XCTAssertEqual(line.blockedNote, PromotionSheetModel.precedenceNote,
                       "the control: a line is what the note is about")

        let emptyCard = PromotionSheetModel(source: .scrap(a), scene: scene(),
                                            scraps: [a: "   "],
                                            artifacts: ArtifactIndex(titlesByID: [:]),
                                            items: .empty,
                                            piece: .none, readBody: { _ in nil })
        XCTAssertNotNil(emptyCard.blockedReason, "it is still blocked, and still says why")
        XCTAssertNil(emptyCard.blockedNote,
                     "an empty card has nothing to do with the wiki-link precedence")

        var withItem = scene()
        withItem.insert(CanvasNode(id: .item("r-9"), kind: .item(.project(id: "r-9")),
                                   origin: CGPoint(x: 800, y: 0), width: 180,
                                   cachedHeight: 120))
        let reference = PromotionSheetModel(source: .scrap(.item("r-9")), scene: withItem,
                                            scraps: texts,
                                            artifacts: ArtifactIndex(titlesByID: [:]),
                                            items: .empty,
                                            piece: .none, readBody: { _ in nil })
        XCTAssertNotNil(reference.blockedReason)
        XCTAssertNil(reference.blockedNote)
    }

    func test_thePrecedenceNoteSaysWhichLayerIsDurable() {
        XCTAssertTrue(PromotionSheetModel.precedenceNote.lowercased().contains("scratch"))
        XCTAssertTrue(PromotionSheetModel.precedenceNote.contains("[["))
    }
}
