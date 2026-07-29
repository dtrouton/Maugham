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
                            readBody: body)
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
                                    readBody: { _ in nil })
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
                                            readBody: { _ in nil })
        XCTAssertNotNil(emptyCard.blockedReason, "it is still blocked, and still says why")
        XCTAssertNil(emptyCard.blockedNote,
                     "an empty card has nothing to do with the wiki-link precedence")

        var withItem = scene()
        withItem.insert(CanvasNode(id: .item("r-9"), kind: .item(referenceId: "r-9"),
                                   origin: CGPoint(x: 800, y: 0), width: 180,
                                   cachedHeight: 120))
        let reference = PromotionSheetModel(source: .scrap(.item("r-9")), scene: withItem,
                                            scraps: texts,
                                            artifacts: ArtifactIndex(titlesByID: [:]),
                                            readBody: { _ in nil })
        XCTAssertNotNil(reference.blockedReason)
        XCTAssertNil(reference.blockedNote)
    }

    func test_thePrecedenceNoteSaysWhichLayerIsDurable() {
        XCTAssertTrue(PromotionSheetModel.precedenceNote.lowercased().contains("scratch"))
        XCTAssertTrue(PromotionSheetModel.precedenceNote.contains("[["))
    }
}
