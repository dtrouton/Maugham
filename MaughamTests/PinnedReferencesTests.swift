import XCTest
import MaughamCore
@testable import Maugham

/// M2 §, widened by the references-shelf design's §2: **what is pinned beside a
/// document** — the research the writer linked to it, the research their project
/// type CONTAINS for it, and the cards they clustered for it on the planning
/// canvas, resolved to something a pane, a column or a prompt can render, and
/// grouped the way the writer arranged them.
///
/// Everything here is pure: no project on disk, no store, no window. The
/// manifest arrives as a `CanvasItemIndex` and the scrap words as a dictionary,
/// which is what makes the projection assertable at all — `CanvasItemFactsTests`'
/// own shape, for its reason.
final class PinnedReferencesTests: XCTestCase {

    // MARK: - The manifest and the scene these tests read

    private let docId = "piece-3"
    private let otherDocId = "piece-9"

    private let scrapA = CanvasNodeID("a")
    private let scrapB = CanvasNodeID("b")
    private let region = CanvasRegionID("r1")
    private let otherRegion = CanvasRegionID("r2")

    /// Built the way production builds it: a palette card is a `.document`
    /// asset that lives inside the role-stamped palette GROUP, and nothing on
    /// the item itself says so. That is the whole point of resolving through
    /// the index rather than sniffing an id.
    private func research() -> [ResearchItem] {
        let card = ResearchItem(id: "res-card", title: "Act II fog", type: .asset,
                                kind: .document, path: "research/palette/act-ii-fog.md")
        let group = ResearchItem(id: "res-palette", title: "Palette", type: .group,
                                 path: PaletteConvention.folderPath,
                                 children: [card], role: .paletteGroup)
        let note = ResearchItem(id: "res-note", title: "The falls at night", type: .asset,
                                kind: .document, path: "research/the-falls-at-night.md")
        let photo = ResearchItem(id: "res-photo", title: "The gorge from above",
                                 type: .asset, kind: .image,
                                 path: "research/research_assets/gorge.jpg")
        return [group, note, photo]
    }

    private func index() -> CanvasItemIndex { CanvasItemIndex.over(research: research()) }

    /// Two scraps and one region bound to `docId`. Membership is left to each
    /// test, because who is a resident and who is a visitor is the rule under
    /// test in half of them.
    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for id in [scrapA, scrapB] {
            s.insert(CanvasNode(id: id, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80))
        }
        s.insertRegion(CanvasRegion(id: region, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        s.insertRegion(CanvasRegion(id: otherRegion, label: "Falls",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        RegionBinding.bind(region, toPiece: docId, in: &s)
        return s
    }

    private func pins(links: [String]? = nil,
                      derived: [String] = [],
                      scene: CanvasScene? = nil,
                      scraps: [CanvasNodeID: String] = [:],
                      docId: String? = nil) -> PinnedShelf {
        PinnedReferences.pinned(forDocId: docId ?? self.docId,
                                links: links,
                                derived: derived,
                                scene: scene,
                                scraps: scraps,
                                items: index())
    }

    // MARK: - The linked half

    func test_aLinkedResearchItemBecomesAPinWithItsRealTitle() {
        let out = pins(links: ["res-note"]).references
        XCTAssertEqual(out.map(\.id), ["res-note"])
        XCTAssertEqual(out.first?.title, "The falls at night",
                       "a pin carries the manifest's title, never the id")
        XCTAssertEqual(out.first?.kind, .research(itemId: "res-note"))
    }

    /// Contract 1. The writer deleted the note; a row reading `res-gone` is a
    /// code, and a reference LIST has nothing to show for it.
    func test_aDanglingLinkIsDroppedRatherThanRenderedAsARawId() {
        XCTAssertEqual(pins(links: ["res-gone", "res-note"]).references.map(\.id),
                       ["res-note"])
    }

    func test_aRepeatedLinkAppearsOnce() {
        XCTAssertEqual(pins(links: ["res-note", "res-note"]).references.map(\.id),
                       ["res-note"])
    }

    func test_noLinksAndNoSceneIsEmpty() {
        XCTAssertTrue(pins().references.isEmpty)
        XCTAssertTrue(pins(links: []).references.isEmpty)
    }

    /// A shelf with nothing on it has no sections at all — not one empty
    /// untitled section. The pane draws a section per element, so an empty one
    /// is an empty row of chrome, and the emptiness is `ReferencesPane`'s own
    /// question to ask of `references`.
    func test_anEmptyShelfHasNoSections() {
        XCTAssertTrue(pins().sections.isEmpty)
    }

    // MARK: - The derived half (§2.1)

    /// §2.1, the missing source. In a Collection the piece's research is routed
    /// by CONTAINMENT and nothing writes a link, so a shelf reading
    /// `linkedResearchIds` alone is empty for a piece with a full research
    /// folder — complete for Novels and silently short for everything else.
    func test_researchTheProjectTypeDerivesIsPinnedWithNoLinkAtAll() {
        let out = pins(derived: ["res-note"]).references
        XCTAssertEqual(out.map(\.id), ["res-note"])
        XCTAssertEqual(out.first?.kind, .research(itemId: "res-note"))
    }

    /// One untitled run of research at the top, links first: the link is the
    /// writer's explicit act and derivation is the project type's, and both are
    /// in manifest order — never sorted.
    func test_linkedResearchLeadsTheDerivedResearchInOneUntitledSection() {
        let shelf = pins(links: ["res-photo"], derived: ["res-note"])
        XCTAssertEqual(shelf.sections.map(\.title), [nil])
        XCTAssertEqual(shelf.references.map(\.id), ["res-photo", "res-note"])
    }

    /// The two sources are two ways of saying one thing about one object, so
    /// the pin is the same pin and it keeps the LINKED position — the same rule
    /// the canvas half has always taken.
    func test_researchBothLinkedAndDerivedLandsOnce() {
        XCTAssertEqual(pins(links: ["res-note"], derived: ["res-note"]).references.map(\.id),
                       ["res-note"])
    }

    // MARK: - The discriminator: research vs palette

    /// **The kind comes from the canvas's own spelling, and that spelling is a
    /// POSITION in the tree** (`PaletteLookup.paletteCards`, reached through
    /// `CanvasItemIndex`). Nothing about the two ids differs — they are both
    /// `res-`-prefixed `.document` assets — so an id-shape heuristic would call
    /// this one research and be wrong with nothing red.
    func test_aPaletteCardIsToldApartByItsPositionAndNotByItsId() {
        let out = pins(links: ["res-card", "res-note"]).references
        XCTAssertEqual(out.map(\.kind), [.palette(cardId: "res-card"),
                                         .research(itemId: "res-note")])
    }

    /// A research IMAGE is still a research pin: `.photo` means a picture the
    /// canvas itself ingested and owns, keyed by path. This one has an id, a
    /// manifest entry and a research preview to open in.
    func test_aResearchImageIsAResearchPinAndNotAPhotoPin() {
        XCTAssertEqual(pins(links: ["res-photo"]).references.map(\.kind),
                       [.research(itemId: "res-photo")])
    }

    // MARK: - The canvas half

    func test_aScrapClusteredForThePieceBecomesAPinTitledByItsFirstLine() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        let out = pins(scene: s, scraps: [scrapA: "The fog came down\n\nand stayed."]).references
        XCTAssertEqual(out.map(\.id), [scrapA.raw])
        XCTAssertEqual(out.first?.title, "The fog came down")
        XCTAssertEqual(out.first?.kind, .scrap(nodeId: scrapA.raw))
    }

    /// The canvas already has a word for a card with nothing on it, and a pin
    /// says the same one rather than showing a blank row.
    func test_anEmptyScrapSaysSoRatherThanRenderingNothing() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        XCTAssertEqual(pins(scene: s, scraps: [scrapA: "   \n\n  "]).references.first?.title,
                       CanvasAccessibility.emptyScrapValue)
    }

    func test_aLongFirstLineIsTruncatedAndSaysSo() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        let long = String(repeating: "x", count: 200)
        let title = pins(scene: s, scraps: [scrapA: long]).references.first?.title ?? ""
        XCTAssertTrue(title.hasSuffix(CanvasRenderer.ellipsis))
        XCTAssertEqual(title.count, PinnedReferences.scrapTitleCharacterLimit + 1,
                       "the limit is on the text; the mark is added to it")
    }

    /// §4.4, and never re-derived as `home ∪ appearances`: a card that merely
    /// *appears* in a bound region is cited, not owned. The projection reaches
    /// the residency rule through `CanvasMembership.residents` — the same
    /// function `RegionBinding.references` reaches it through — which is what
    /// keeps this green now that the shelf walks region by region.
    func test_aVisitingCardIsNotPinned() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        CanvasMembership.addAppearance(scrapB, to: region, in: &s)
        XCTAssertEqual(pins(scene: s, scraps: [scrapA: "one", scrapB: "two"]).references.map(\.id),
                       [scrapA.raw])
    }

    /// Task 1's widening: a card the writer tied to the piece ITSELF is pinned
    /// whether or not it lives in a region bound to the same piece.
    func test_aCardBoundToThePieceItselfIsPinned() {
        var s = scene()
        s.setBoundPiece(docId, for: scrapB)
        XCTAssertEqual(pins(scene: s, scraps: [scrapB: "its own"]).references.map(\.id),
                       [scrapB.raw])
    }

    func test_aCardClusteredForAnotherPieceIsNotPinned() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        XCTAssertTrue(pins(scene: s, scraps: [scrapA: "one"], docId: otherDocId)
                        .references.isEmpty)
    }

    // MARK: - Item nodes on the canvas, both provenances

    func test_aReferencedItemOnTheCanvasResolvesThroughTheSameIndex() {
        var s = scene()
        let node = CanvasNodeID.item("res-card")
        s.insert(CanvasNode(id: node, kind: .item(.project(id: "res-card")),
                            origin: .zero, width: 240, cachedHeight: 80))
        CanvasMembership.join(node, home: region, in: &s)
        let out = pins(scene: s).references
        XCTAssertEqual(out.map(\.id), ["res-card"], "the pin's id is what it points AT")
        XCTAssertEqual(out.first?.kind, .palette(cardId: "res-card"))
        XCTAssertEqual(out.first?.title, "Act II fog")
    }

    /// A card pointing at a note the writer deleted is dropped, exactly as a
    /// dangling link is. The CANVAS keeps drawing that card and says
    /// `CanvasItemFacts.missingTitle` on it — that is a drawing decision about
    /// a thing the writer placed. A reference list is not the canvas.
    func test_aCanvasReferenceToADeletedItemIsDropped() {
        var s = scene()
        let node = CanvasNodeID.item("res-gone")
        s.insert(CanvasNode(id: node, kind: .item(.project(id: "res-gone")),
                            origin: .zero, width: 240, cachedHeight: 80))
        CanvasMembership.join(node, home: region, in: &s)
        XCTAssertTrue(pins(scene: s).references.isEmpty)
    }

    /// An owned picture needs no manifest — it exists nowhere else in the
    /// project — so it resolves in full against an index that has never heard
    /// of it, and its id is its project-relative path.
    func test_anOwnedPictureIsAPhotoPinAndNeedsNoManifest() {
        var s = scene()
        let node = CanvasNodeID("owned-1")
        let path = "canvas_assets/image-20260730-121314.png"
        s.insert(CanvasNode(id: node, kind: .item(.owned(path: path)),
                            origin: .zero, width: 240, cachedHeight: 80))
        CanvasMembership.join(node, home: region, in: &s)
        let out = PinnedReferences.pinned(forDocId: docId, links: nil, derived: [], scene: s,
                                          scraps: [:], items: .empty).references
        XCTAssertEqual(out.map(\.id), [path])
        XCTAssertEqual(out.first?.kind, .photo(path: path))
        XCTAssertEqual(out.first?.title, CanvasItemFacts.ownedTitle)
    }

    // MARK: - The sections (§2.2)

    /// §2.2, the missing structure. A writer who arranged six cards under a
    /// titled region used to get six titles in dictionary order with nothing
    /// saying they belong together.
    func test_aBoundRegionIsItsOwnSectionTitledWithItsLabel() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        let shelf = pins(links: ["res-note"], scene: s, scraps: [scrapA: "The fog came down"])
        XCTAssertEqual(shelf.sections.map(\.title), [nil, "Act II fog"])
        XCTAssertEqual(shelf.sections.last?.references.map(\.id), [scrapA.raw])
    }

    /// The fallback is `Promotion.regionTitle`'s and is reached rather than
    /// restated: a region drawn by a drag is unlabelled for the first minute of
    /// its life, and a section header reading nothing at all is chrome.
    func test_anUnlabelledBoundRegionTakesPromotionsOwnFallbackTitle() {
        var s = scene()
        s.updateRegion(region) { $0.label = "   " }
        CanvasMembership.join(scrapA, home: region, in: &s)
        XCTAssertEqual(pins(scene: s, scraps: [scrapA: "one"]).sections.map(\.title),
                       [CanvasRegion.untitledLabel])
    }

    /// Regions in label order, `RegionInspector.rows`' discipline — with the id
    /// tiebreak that keeps two identically-labelled regions from swapping
    /// between launches on a `Dictionary`'s iteration order.
    func test_twoBoundRegionsAreOrderedByLabelThenById() {
        var s = scene()
        RegionBinding.bind(otherRegion, toPiece: docId, in: &s)
        CanvasMembership.join(scrapA, home: region, in: &s)
        CanvasMembership.join(scrapB, home: otherRegion, in: &s)
        XCTAssertEqual(pins(scene: s, scraps: [scrapA: "one", scrapB: "two"])
                        .sections.map(\.title), ["Act II fog", "Falls"])

        s.updateRegion(otherRegion) { $0.label = "Act II fog" }
        for _ in 0..<20 {
            XCTAssertEqual(pins(scene: s, scraps: [scrapA: "one", scrapB: "two"])
                            .sections.flatMap { $0.references.map(\.id) },
                           [scrapA.raw, scrapB.raw],
                           "r1 before r2 on the id tiebreak, on every run")
        }
    }

    /// A card lives in one place. Unioned across regions it would be pinned
    /// twice; the dedup is on the pin's id and the FIRST section wins, which is
    /// the section the writer sees first.
    func test_aCardResidentInTwoBoundRegionsAppearsInTheFirstSectionOnly() {
        var s = scene()
        RegionBinding.bind(otherRegion, toPiece: docId, in: &s)
        CanvasMembership.join(scrapA, home: region, in: &s)
        // Not `join`, which moves a card's home: a hand-edited sidecar can name
        // one node in two regions' `homeMembers`, and the shelf must not double it.
        s.updateRegion(otherRegion) { $0.addHome(self.scrapA) }
        let shelf = pins(scene: s, scraps: [scrapA: "one"])
        XCTAssertEqual(shelf.sections.map(\.title), ["Act II fog"],
                       "the second region's section is empty and omitted")
        XCTAssertEqual(shelf.references.map(\.id), [scrapA.raw])
    }

    /// §2.3, the promotion. The region BECAME that note; pinning both is the
    /// seventh-row defect Denver saw.
    func test_aPromotedRegionContributesTheNoteItBecameAndNotItsCards() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        s.updateRegion(region) { $0.promotedItemID = "res-note" }
        let shelf = pins(scene: s, scraps: [scrapA: "The fog came down"])
        XCTAssertEqual(shelf.sections.map(\.title), ["Act II fog"])
        XCTAssertEqual(shelf.references.map(\.id), ["res-note"])
        XCTAssertEqual(shelf.references.first?.kind, .research(itemId: "res-note"))
    }

    /// **The region keeps the heading over a note the piece ALSO holds** — the
    /// whole-branch review's M1, ruled 2026-08-26.
    ///
    /// In a Collection this is the normal case rather than an edge one: region
    /// promotion writes the note into the bound piece's own research folder, so
    /// `derivedResearchItems` carries it and the untitled run reached it first.
    /// Dedup-first-wins then dropped it from the region's section, `close` saw an
    /// empty `out`, and the heading vanished — the note was on the shelf exactly
    /// once and correctly, with nothing saying where it came from, in precisely
    /// the project shape this milestone was written for. The heading is what
    /// carries the writer's own word for the material, so the region wins the
    /// collision and the untitled run is one shorter.
    ///
    /// Driven from BOTH upstream sources, because the reservation has to happen
    /// before either of them takes the id, and a fix that only handled
    /// containment would leave the Novel-chapter path (a linked note promoted
    /// from a region) on the old behaviour.
    func test_aPromotedRegionKeepsItsHeadingOverANoteThePieceAlsoHolds() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        s.updateRegion(region) { $0.promotedItemID = "res-note" }

        for (source, shelf) in [
            ("contained", pins(derived: ["res-photo", "res-note"], scene: s,
                               scraps: [scrapA: "The fog came down"])),
            ("linked", pins(links: ["res-photo", "res-note"], scene: s,
                            scraps: [scrapA: "The fog came down"])),
        ] {
            XCTAssertEqual(shelf.sections.map(\.title), [nil, "Act II fog"],
                           "\(source): the region's own name is what tells the "
                           + "writer where the note came from, and it is the half "
                           + "that vanished when the untitled run claimed the id")
            XCTAssertEqual(shelf.sections.first?.references.map(\.id), ["res-photo"],
                           "\(source): the rest of the run is untouched — only "
                           + "the promoted note is reserved")
            XCTAssertEqual(shelf.sections.last?.references.map(\.id), ["res-note"],
                           "\(source): under the region's heading, and its cards "
                           + "are still not pinned beside it")
            XCTAssertEqual(shelf.references.map(\.id), ["res-photo", "res-note"],
                           "\(source): once on the shelf, not twice")
        }
    }

    /// The mark is a record of something that happened once, not a live link,
    /// so it can name a note the writer has since deleted. The fact is stale
    /// and the writer still has the material.
    func test_aPromotedRegionWhoseNoteIsGoneFallsBackToItsCards() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        s.updateRegion(region) { $0.promotedItemID = "gone" }
        XCTAssertEqual(pins(scene: s, scraps: [scrapA: "The fog came down"])
                        .references.map(\.id), [scrapA.raw])
    }

    /// A card's OWN promotion does not supersede the card: the writer pinned
    /// the card. A region is different because its promotion is what the region
    /// is FOR.
    func test_aCardsOwnPromotionDoesNotSupersedeTheCard() {
        var s = scene()
        s.setBoundPiece(docId, for: scrapB)
        s.setPromotedItem("res-note", for: scrapB)
        XCTAssertEqual(pins(scene: s, scraps: [scrapB: "its own"]).references.map(\.id),
                       [scrapB.raw])
    }

    func test_aSelfBoundCardOutsideEveryBoundRegionLandsUnderCards() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        s.setBoundPiece(docId, for: scrapB)
        let shelf = pins(scene: s, scraps: [scrapA: "in the region", scrapB: "on its own"])
        XCTAssertEqual(shelf.sections.map(\.title), ["Act II fog", PinnedShelf.looseCardsTitle])
        XCTAssertEqual(shelf.sections.last?.references.map(\.id), [scrapB.raw])
    }

    func test_theCardsSectionIsAbsentWhenNothingIsLooseInIt() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        XCTAssertEqual(pins(scene: s, scraps: [scrapA: "one"]).sections.map(\.title),
                       ["Act II fog"])
    }

    /// A resident of a bound region carries no `boundPieceID` of its own, so it
    /// is the region's and never the loose set's — the two sources are asked
    /// different questions and a card answering both lands once, in the region.
    func test_aSelfBoundResidentOfABoundRegionStaysInTheRegionsSection() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        s.setBoundPiece(docId, for: scrapA)
        let shelf = pins(scene: s, scraps: [scrapA: "one"])
        XCTAssertEqual(shelf.sections.map(\.title), ["Act II fog"])
        XCTAssertEqual(shelf.references.map(\.id), [scrapA.raw])
    }

    // MARK: - The flat projection

    /// The old return value, and what the compiler's listing and any reader
    /// wanting a list reads. The sections are disjoint by construction, so this
    /// is the concatenation — and every id in it is unique.
    func test_theFlatListIsTheSectionsConcatenatedWithNoIdTwice() {
        var s = scene()
        RegionBinding.bind(otherRegion, toPiece: docId, in: &s)
        CanvasMembership.join(scrapA, home: region, in: &s)
        let node = CanvasNodeID.item("res-note")
        s.insert(CanvasNode(id: node, kind: .item(.project(id: "res-note")),
                            origin: .zero, width: 240, cachedHeight: 80))
        CanvasMembership.join(node, home: otherRegion, in: &s)
        s.setBoundPiece(docId, for: scrapB)
        let shelf = pins(links: ["res-note"], derived: ["res-card"], scene: s,
                         scraps: [scrapA: "one", scrapB: "two"])
        XCTAssertEqual(shelf.references, shelf.sections.flatMap(\.references))
        XCTAssertEqual(Set(shelf.references.map(\.id)).count, shelf.references.count)
        XCTAssertEqual(shelf.references.map(\.id),
                       ["res-note", "res-card", scrapA.raw, scrapB.raw],
                       "the linked note takes the res-note card's place on the canvas")
    }

    // MARK: - Order

    /// Contract 4. Linked first in manifest order — which is NOT alphabetical
    /// here, so a sort applied to the whole list would fail this — then each
    /// region's cards in READING order: the writer arranged them, and the shelf
    /// reads the way the region reads (`Promotion.readingOrder`, the same order
    /// a promotion joins their words in).
    func test_linkedComeFirstInManifestOrderThenTheCanvasSetInReadingOrder() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        CanvasMembership.join(scrapB, home: region, in: &s)
        s.move(scrapB, to: CGPoint(x: 0, y: 0))
        s.move(scrapA, to: CGPoint(x: 0, y: 400))
        let out = pins(links: ["res-photo", "res-note"], scene: s,
                       scraps: [scrapA: "Antelope", scrapB: "Zebra"]).references
        XCTAssertEqual(out.map(\.title),
                       ["The gorge from above", "The falls at night", "Zebra", "Antelope"],
                       "B is above A on the canvas, so B is above A on the shelf — "
                       + "alphabetical order would put Antelope first")
    }

    /// The tiebreak is not decoration: two cards at the same origin would
    /// otherwise leave a `Set`'s iteration order deciding the list — a
    /// different order on every launch. `Promotion.readingOrder` takes the
    /// identical discipline, and this is the same order a promotion joins them
    /// in.
    func test_theReadingOrderTiebreaksOnIdSoTwoCardsAtOnePointDoNotSwap() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        CanvasMembership.join(scrapB, home: region, in: &s)
        for _ in 0..<20 {
            XCTAssertEqual(pins(scene: s, scraps: [scrapA: "", scrapB: ""]).references.map(\.id),
                           [scrapA.raw, scrapB.raw])
        }
    }

    /// Contract 5. A project whose Plan side has never been opened has no
    /// scene, and the research still pins — as one untitled section.
    func test_noSceneDegradesToTheResearchSectionOnly() {
        let shelf = pins(links: ["res-note"], scene: nil)
        XCTAssertEqual(shelf.sections.map(\.title), [nil])
        XCTAssertEqual(shelf.references.map(\.id), ["res-note"])
    }

    /// Contract: the id is the underlying id/path, so a recomputation over an
    /// unchanged project and scene is `Equatable`-identical — which is what
    /// lets a pane hold a selection across one. The shelf is `Equatable` for
    /// the same reason its rows are.
    func test_recomputingOverAnUnchangedProjectGivesTheIdenticalShelf() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        let scraps = [scrapA: "The fog came down"]
        XCTAssertEqual(pins(links: ["res-note"], scene: s, scraps: scraps),
                       pins(links: ["res-note"], scene: s, scraps: scraps))
    }
}
