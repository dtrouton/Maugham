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

    private let pieces = [RegionInspector.PieceChoice(id: "piece-3", title: "Chapter Three")]

    private func model(_ source: PromotionSource,
                       scene: CanvasScene? = nil,
                       artifacts: [String: String] = [:],
                       body: @escaping (String) -> String? = { _ in nil }) -> PromotionSheetModel {
        PromotionSheetModel(source: source, scene: scene ?? self.scene(), scraps: texts,
                            pieces: pieces, artifacts: ArtifactIndex(titlesByID: artifacts),
                            readBody: body)
    }

    // MARK: - Opening

    func test_theSheetOffersExactlyTheTargetsTheModelAllows() {
        XCTAssertEqual(Set(model(.scrap(a)).availableTargets),
                       [.researchNote, .paletteCard, .intentStatement])
        XCTAssertEqual(Set(model(.region(r1)).availableTargets),
                       [.paletteCard, .pieceBinding])
    }

    func test_itStartsWithNothingSelectedSoNothingCommitsByAccident() {
        let m = model(.scrap(a))
        XCTAssertNil(m.selectedTarget)
        XCTAssertNil(m.preview)
        XCTAssertFalse(m.canCommit)
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

    // MARK: - The offer, the discards, the piece, the kind

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

    func test_aPieceBindingCannotCommitUntilAPieceIsChosen() {
        let m = model(.region(r1))
        m.select(.pieceBinding)
        XCTAssertFalse(m.canCommit)
        m.selectedPieceID = "piece-3"
        XCTAssertTrue(m.canCommit)
        XCTAssertEqual(m.resolvedPlan?.pieceID, "piece-3")
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

    func test_thePrecedenceNoteSaysWhichLayerIsDurable() {
        XCTAssertTrue(PromotionSheetModel.precedenceNote.lowercased().contains("scratch"))
        XCTAssertTrue(PromotionSheetModel.precedenceNote.contains("[["))
    }
}
