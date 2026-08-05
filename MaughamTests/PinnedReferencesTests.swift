import XCTest
import MaughamCore
@testable import Maugham

/// M2 §: **what is pinned beside a document** — the research the writer linked
/// to it, unioned with the cards they clustered for it on the planning canvas,
/// each resolved to something a pane, a column or a prompt can render.
///
/// Everything here is pure: no project on disk, no store, no window. The
/// manifest arrives as a `CanvasItemIndex` and the scrap words as a dictionary,
/// which is what makes the union assertable at all — `CanvasItemFactsTests`'
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
                      scene: CanvasScene? = nil,
                      scraps: [CanvasNodeID: String] = [:],
                      docId: String? = nil) -> [PinnedReference] {
        PinnedReferences.pinned(forDocId: docId ?? self.docId,
                                links: links,
                                scene: scene,
                                scraps: scraps,
                                items: index())
    }

    // MARK: - The linked half

    func test_aLinkedResearchItemBecomesAPinWithItsRealTitle() {
        let out = pins(links: ["res-note"])
        XCTAssertEqual(out.map(\.id), ["res-note"])
        XCTAssertEqual(out.first?.title, "The falls at night",
                       "a pin carries the manifest's title, never the id")
        XCTAssertEqual(out.first?.kind, .research(itemId: "res-note"))
    }

    /// Contract 1. The writer deleted the note; a row reading `res-gone` is a
    /// code, and a reference LIST has nothing to show for it.
    func test_aDanglingLinkIsDroppedRatherThanRenderedAsARawId() {
        XCTAssertEqual(pins(links: ["res-gone", "res-note"]).map(\.id), ["res-note"])
    }

    func test_aRepeatedLinkAppearsOnce() {
        XCTAssertEqual(pins(links: ["res-note", "res-note"]).map(\.id), ["res-note"])
    }

    func test_noLinksAndNoSceneIsEmpty() {
        XCTAssertTrue(pins().isEmpty)
        XCTAssertTrue(pins(links: []).isEmpty)
    }

    // MARK: - The discriminator: research vs palette

    /// **The kind comes from the canvas's own spelling, and that spelling is a
    /// POSITION in the tree** (`PaletteLookup.paletteCards`, reached through
    /// `CanvasItemIndex`). Nothing about the two ids differs — they are both
    /// `res-`-prefixed `.document` assets — so an id-shape heuristic would call
    /// this one research and be wrong with nothing red.
    func test_aPaletteCardIsToldApartByItsPositionAndNotByItsId() {
        let out = pins(links: ["res-card", "res-note"])
        XCTAssertEqual(out.map(\.kind), [.palette(cardId: "res-card"),
                                         .research(itemId: "res-note")])
    }

    /// A research IMAGE is still a research pin: `.photo` means a picture the
    /// canvas itself ingested and owns, keyed by path. This one has an id, a
    /// manifest entry and a research preview to open in.
    func test_aResearchImageIsAResearchPinAndNotAPhotoPin() {
        XCTAssertEqual(pins(links: ["res-photo"]).map(\.kind),
                       [.research(itemId: "res-photo")])
    }

    // MARK: - The canvas half

    func test_aScrapClusteredForThePieceBecomesAPinTitledByItsFirstLine() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        let out = pins(scene: s, scraps: [scrapA: "The fog came down\n\nand stayed."])
        XCTAssertEqual(out.map(\.id), [scrapA.raw])
        XCTAssertEqual(out.first?.title, "The fog came down")
        XCTAssertEqual(out.first?.kind, .scrap(nodeId: scrapA.raw))
    }

    /// The canvas already has a word for a card with nothing on it, and a pin
    /// says the same one rather than showing a blank row.
    func test_anEmptyScrapSaysSoRatherThanRenderingNothing() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        XCTAssertEqual(pins(scene: s, scraps: [scrapA: "   \n\n  "]).first?.title,
                       CanvasAccessibility.emptyScrapValue)
    }

    func test_aLongFirstLineIsTruncatedAndSaysSo() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        let long = String(repeating: "x", count: 200)
        let title = pins(scene: s, scraps: [scrapA: long]).first?.title ?? ""
        XCTAssertTrue(title.hasSuffix(CanvasRenderer.ellipsis))
        XCTAssertEqual(title.count, PinnedReferences.scrapTitleCharacterLimit + 1,
                       "the limit is on the text; the mark is added to it")
    }

    /// §4.4, through `RegionBinding.references` and never re-derived: a card
    /// that merely *appears* in a bound region is cited, not owned.
    func test_aVisitingCardIsNotPinned() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        CanvasMembership.addAppearance(scrapB, to: region, in: &s)
        XCTAssertEqual(pins(scene: s, scraps: [scrapA: "one", scrapB: "two"]).map(\.id),
                       [scrapA.raw])
    }

    /// Task 1's widening: a card the writer tied to the piece ITSELF is pinned
    /// whether or not it lives in a region bound to the same piece.
    func test_aCardBoundToThePieceItselfIsPinned() {
        var s = scene()
        s.setBoundPiece(docId, for: scrapB)
        XCTAssertEqual(pins(scene: s, scraps: [scrapB: "its own"]).map(\.id), [scrapB.raw])
    }

    func test_aCardClusteredForAnotherPieceIsNotPinned() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        XCTAssertTrue(pins(scene: s, scraps: [scrapA: "one"], docId: otherDocId).isEmpty)
    }

    // MARK: - Item nodes on the canvas, both provenances

    func test_aReferencedItemOnTheCanvasResolvesThroughTheSameIndex() {
        var s = scene()
        let node = CanvasNodeID.item("res-card")
        s.insert(CanvasNode(id: node, kind: .item(.project(id: "res-card")),
                            origin: .zero, width: 240, cachedHeight: 80))
        CanvasMembership.join(node, home: region, in: &s)
        let out = pins(scene: s)
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
        XCTAssertTrue(pins(scene: s).isEmpty)
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
        let out = PinnedReferences.pinned(forDocId: docId, links: nil, scene: s,
                                          scraps: [:], items: .empty)
        XCTAssertEqual(out.map(\.id), [path])
        XCTAssertEqual(out.first?.kind, .photo(path: path))
        XCTAssertEqual(out.first?.title, CanvasItemFacts.ownedTitle)
    }

    // MARK: - The union

    /// Contract 3. The two sources are two ways of saying the same thing about
    /// one object, so the pin is the same pin — and it keeps the LINKED
    /// position, because the writer's explicit link is the older statement.
    func test_anItemBothLinkedAndOnTheCanvasAppearsOnce() {
        var s = scene()
        let node = CanvasNodeID.item("res-note")
        s.insert(CanvasNode(id: node, kind: .item(.project(id: "res-note")),
                            origin: .zero, width: 240, cachedHeight: 80))
        CanvasMembership.join(node, home: region, in: &s)
        CanvasMembership.join(scrapA, home: region, in: &s)
        let out = pins(links: ["res-note"], scene: s, scraps: [scrapA: "A scrap"])
        XCTAssertEqual(out.map(\.id), ["res-note", scrapA.raw])
        XCTAssertEqual(out.filter { $0.id == "res-note" }.count, 1)
    }

    /// Contract 4. Linked first in manifest order — which is NOT alphabetical
    /// here, so a sort applied to the whole list would fail this — then the
    /// canvas set by title.
    func test_linkedComeFirstInManifestOrderThenTheCanvasSetByTitle() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        CanvasMembership.join(scrapB, home: region, in: &s)
        let out = pins(links: ["res-photo", "res-note"], scene: s,
                       scraps: [scrapA: "Zebra", scrapB: "Antelope"])
        XCTAssertEqual(out.map(\.title),
                       ["The gorge from above", "The falls at night", "Antelope", "Zebra"])
    }

    /// The tiebreak is not decoration: every empty scrap answers with the same
    /// placeholder, so title alone would leave a `Set`'s iteration order
    /// deciding the list — a different order on every launch.
    /// `RegionInspector.rows` takes the identical discipline.
    func test_theCanvasOrderTiebreaksOnIdSoTwoEmptyScrapsDoNotSwap() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        CanvasMembership.join(scrapB, home: region, in: &s)
        for _ in 0..<20 {
            XCTAssertEqual(pins(scene: s, scraps: [scrapA: "", scrapB: ""]).map(\.id),
                           [scrapA.raw, scrapB.raw])
        }
    }

    /// Contract 5. A project whose Plan side has never been opened has no
    /// scene, and the links still pin.
    func test_noSceneDegradesToLinksOnly() {
        XCTAssertEqual(pins(links: ["res-note"], scene: nil).map(\.id), ["res-note"])
    }

    /// Contract: the id is the underlying id/path, so a recomputation over an
    /// unchanged project and scene is `Equatable`-identical — which is what
    /// lets a pane hold a selection across one.
    func test_recomputingOverAnUnchangedProjectGivesTheIdenticalList() {
        var s = scene()
        CanvasMembership.join(scrapA, home: region, in: &s)
        let scraps = [scrapA: "The fog came down"]
        XCTAssertEqual(pins(links: ["res-note"], scene: s, scraps: scraps),
                       pins(links: ["res-note"], scene: s, scraps: scraps))
    }
}
