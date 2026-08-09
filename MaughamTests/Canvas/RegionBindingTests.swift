import XCTest
import MaughamCore
@testable import Maugham

final class RegionBindingTests: XCTestCase {

    private var root: URL!
    private let r1 = CanvasRegionID("r1")
    private let r2 = CanvasRegionID("r2")
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let c = CanvasNodeID("c")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("region-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for id in [a, b, c] {
            s.insert(CanvasNode(id: id, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80))
        }
        for (id, label) in [(r1, "Act II fog"), (r2, "Falls")] {
            s.insertRegion(CanvasRegion(id: id, label: label,
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        }
        return s
    }

    private func model() -> CanvasModel {
        let m = CanvasModel()
        m.attach(projectRoot: root)
        m.withScene { $0 = self.scene() }
        m.selection = .region(r1)
        return m
    }

    private func inspector(_ m: CanvasModel) -> RegionInspector {
        RegionInspector(model: m, regionID: r1,
                        pieces: [RegionInspector.PieceChoice(id: "piece-3", title: "October")],
                        artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                        onOpenResearchItem: { _ in })
    }

    // MARK: - The binding rules

    func test_onlyResidentsAreBoundToThePiece() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: s), [a],
                       "§4.4: a visitor is not bound, or two regions sharing a "
                       + "card would each claim it")
    }

    func test_twoRegionsBoundToOnePieceUnionTheirResidents() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.join(b, home: r2, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        RegionBinding.bind(r2, toPiece: "piece-3", in: &s)
        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: s), [a, b])
    }

    func test_unbindingKeepsMembershipIntact() throws {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        RegionBinding.unbind(r1, in: &s)
        XCTAssertNil(RegionBinding.boundPiece(of: r1, in: s))
        XCTAssertTrue(try XCTUnwrap(s.region(r1)).livesHere(a), "the binding is not the membership")
        XCTAssertTrue(RegionBinding.references(forPiece: "piece-3", in: s).isEmpty)
    }

    /// The brief's version ran against a scene with no members at all, so
    /// dropping the `boundPieceID == piece` filter entirely left it green —
    /// every region matched and every region contributed nothing. A resident and
    /// a real binding to a DIFFERENT piece are what make the filter observable.
    func test_aPieceNobodyBoundToHasNoReferences() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        XCTAssertTrue(RegionBinding.references(forPiece: "piece-9", in: s).isEmpty)
        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: s), [a],
                       "the control: the filter lets the right piece through")
    }

    /// `remove` scrubs the region records, but a hand-edited sidecar is not
    /// obliged to be coherent — and a stale id here becomes a pinned reference
    /// to a card that is not on the canvas.
    func test_aResidentThatIsNoLongerACardIsNotAReference() throws {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.join(b, home: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        // Reach past `CanvasScene.remove`, which would scrub the membership too.
        var starved = CanvasScene(nodes: [CanvasNode(id: b, kind: .scrap, origin: .zero,
                                                     width: 240, cachedHeight: 80)],
                                  regions: s.regions)
        starved.insertRegion(try XCTUnwrap(s.region(r1)))
        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: starved), [b])
    }

    /// M2's widening: a card's OWN `boundPieceID` (§6.2's association) now
    /// makes it a reference too, alongside a region's binding (§4.4's). The
    /// card here is loose — no home region at all — and the piece has no
    /// region bound to it either, so the old region-only rule would report
    /// nothing.
    func test_aCardBoundByItselfIsReferenced() {
        var s = scene()
        s.setBoundPiece("piece-3", for: a)
        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: s), [a])
    }

    /// Union, dedupe: a card that is BOTH a resident of a bound region AND
    /// self-bound to the same piece must appear once, not twice — the
    /// contract is a `Set`, but a naive `+` of the two sources would still
    /// pass a `[CanvasNodeID]` equality check by accident.
    func test_selfBoundResidentIsNotDoubled() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        s.setBoundPiece("piece-3", for: a)
        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: s), [a])
    }

    // MARK: - The inspector, which is the only way any of this is reachable

    func test_renamingThroughTheInspectorIsOneUndoStepAndReachesDisk() {
        let m = model()
        inspector(m).commitLabel("Falls at night")
        m.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.region(r1)?.label,
                       "Falls at night")
        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.label, "Act II fog")
        XCTAssertFalse(m.undo.canUndo, "one rename, one step — not one per keystroke")
    }

    /// The writer-facing rule. **It does not pin the guard** — `endGesture`
    /// already declines an unchanged gesture, so this stays green with
    /// `commitLabel`'s `region.label != new` deleted. The test below is the one
    /// that pins it; this one says what the writer is owed.
    func test_committingTheSameLabelTwiceLeavesOneStep() {
        let m = model()
        inspector(m).commitLabel("Falls")
        inspector(m).commitLabel("Falls")
        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.label, "Act II fog",
                       "a commit on focus loss that changed nothing must not push "
                       + "a step the writer has to press ⌘Z twice to get past")
    }

    /// A rename typed into r1's field and committed after the selection has
    /// already moved to r2 must land on r1. The inspector commits on focus loss
    /// and on the selection moving on, and it does not control which of those
    /// two AppKit and SwiftUI deliver first.
    func test_aRenameCommitsToTheRegionItWasTypedIn() {
        let m = model()
        let showingTheOtherRegion = RegionInspector(model: m, regionID: r2, pieces: [],
                        artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                        onOpenResearchItem: { _ in })
        showingTheOtherRegion.commitLabel("Falls at night", to: r1)
        XCTAssertEqual(m.scene.region(r1)?.label, "Falls at night")
        XCTAssertEqual(m.scene.region(r2)?.label, "Falls",
                       "and not on whichever region is on screen by then")
    }

    /// Both directions of the change-check, which is the trap the brief names:
    /// a guard that is easy to test only in the direction that passes.
    ///
    /// The observable is the structural counter, because that is what the guard
    /// actually protects — a canvas redraw and a queued disk write for an edit
    /// that changed nothing.
    func test_theChangeCheckSwallowsNoOpsAndOnlyNoOps() {
        let m = model()
        let i = inspector(m)

        let before = m.sceneRevision
        i.commitLabel("Act II fog")
        i.commitCollapsed(false)
        i.commitBinding(nil)
        i.remove(a)
        XCTAssertEqual(m.sceneRevision, before,
                       "four commits, none of which changed anything — remove the "
                       + "`!=` guards and every one of them redraws the canvas")

        i.commitLabel("Falls at night")
        XCTAssertEqual(m.sceneRevision, before + 1)
        i.commitCollapsed(true)
        XCTAssertEqual(m.sceneRevision, before + 2)
        i.commitBinding("piece-3")
        XCTAssertEqual(m.sceneRevision, before + 3,
                       "and a guard that swallows a REAL change is the same defect "
                       + "wearing the opposite sign")
        i.cite(a)
        XCTAssertEqual(m.sceneRevision, before + 4,
                       "a citation changes what the canvas DRAWS — a chip inside "
                       + "the region, hairlined back to the card — and nothing in "
                       + "`CanvasView`'s own state moved, so this bump is the only "
                       + "thing that gets the redraw")
    }

    func test_collapsingThroughTheInspectorHidesTheResidents() {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r1, in: &$0) }
        inspector(m).commitCollapsed(true)
        XCTAssertTrue(m.scene.isHidden(a))
        inspector(m).commitCollapsed(false)
        XCTAssertFalse(m.scene.isHidden(a))
    }

    func test_collapsingIsOneUndoStepAndReachesDisk() {
        let m = model()
        inspector(m).commitCollapsed(true)
        m.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.region(r1)?.isCollapsed,
                       true, "the field Task 2 round-trips and only a test could set")
        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.isCollapsed, false)
    }

    func test_bindingThroughTheInspectorReachesDisk() {
        let m = model()
        inspector(m).commitBinding("piece-3")
        m.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.region(r1)?.boundPieceID,
                       "piece-3")
    }

    func test_unbindingThroughTheInspectorClearsIt() {
        let m = model()
        inspector(m).commitBinding("piece-3")
        inspector(m).commitBinding(nil)
        XCTAssertNil(try XCTUnwrap(m.scene.region(r1)).boundPieceID)
        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.boundPieceID, "piece-3",
                       "the unbind is its own step, not a silent write")
    }

    /// **The writer-facing names, now that the inspector's Picker is the only
    /// route to a binding.** `PromotionPerformerTests.test_bindingSharesTheInspectors
    /// UndoName` used to cross-check this against the now-removed piece-binding
    /// promotion target (spec §6's 2026-07-29 amendment: a binding produces no
    /// artifact, so it is §6.2's association rather than a promotion target) —
    /// this is where that coverage survives.
    func test_bindingAndUnbindingUseDistinctUndoNames() {
        let m = model()
        m.undoManager.groupsByEvent = false
        inspector(m).commitBinding("piece-3")
        XCTAssertTrue(m.undo.undoMenuItemTitle.contains("Bind Region"),
                      "found: \(m.undo.undoMenuItemTitle)")
        inspector(m).commitBinding(nil)
        XCTAssertTrue(m.undo.undoMenuItemTitle.contains("Unbind Region"),
                      "found: \(m.undo.undoMenuItemTitle)")
    }

    /// **The footer described only 1A's reference rail**, which is unbuilt — so
    /// the one thing a region's binding does *today* went unsaid. A held constant
    /// rather than a literal in `body` for the reason `CanvasAccessibility.
    /// regionKind` is one: a `Form`'s contents are not inspectable, so this is
    /// the only way a test can read what ships.
    func test_theRegionFooterSaysBothThingsThePieceDecides() {
        let footer = RegionInspector.pieceFooter
        XCTAssertTrue(footer.contains("pinned references"),
                      "§4.4's bridge is still what the binding is FOR — found: \(footer)")
        XCTAssertTrue(footer.contains("promoted"),
                      "and since 1C-c2a it also decides where a promotion lands, "
                      + "which is the half the writer met first — found: \(footer)")
    }

    /// The Promote caption named a target that no longer exists: a piece binding
    /// produces no artifact, so it stopped being a promotion target in this
    /// milestone (spec §6's 2026-07-29 amendment) while the sentence offering it
    /// stayed. A region promotes to a note or a palette card.
    func test_thePromoteCaptionOffersOnlyTheTwoTargetsARegionHas() {
        let caption = RegionInspector.promoteCaption
        XCTAssertTrue(caption.contains("research note"), "found: \(caption)")
        XCTAssertTrue(caption.contains("palette card"), "found: \(caption)")
        XCTAssertFalse(caption.lowercased().contains("bind"),
                       "binding is not a promotion — found: \(caption)")
    }

    func test_removingAMemberThroughTheInspectorIsAnExplicitAct() throws {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r1, in: &$0) }
        inspector(m).remove(a)
        XCTAssertFalse(try XCTUnwrap(m.scene.region(r1)).livesHere(a))
        XCTAssertNotNil(m.scene.node(a), "removing from a region never deletes the card")
        m.undo.undo()
        XCTAssertTrue(try XCTUnwrap(m.scene.region(r1)).livesHere(a))
    }

    func test_removingAVisitorLeavesTheRegionItLivesIn() throws {
        let m = model()
        m.withScene {
            CanvasMembership.join(self.a, home: self.r2, in: &$0)
            CanvasMembership.addAppearance(self.a, to: self.r1, in: &$0)
        }
        inspector(m).remove(a)
        XCTAssertFalse(try XCTUnwrap(m.scene.region(r1)).appearsHere(a))
        XCTAssertTrue(try XCTUnwrap(m.scene.region(r2)).livesHere(a),
                      "the inspector removes from THIS region, not from every region")
    }

    // MARK: - Citing a card, which is the only way an appearance is ever made

    /// §4.3, and the reason this control exists: a citation is a REFERENCE, so
    /// the card keeps whatever home it had.
    ///
    /// The home assertion is the one that fails on the obvious bug — `cite`
    /// reaching for `CanvasMembership.join` instead of `addAppearance` satisfies
    /// "r1 now mentions the card" and quietly moves it out of r2.
    func test_citingACardMakesItAVisitorAndLeavesItsHomeAlone() throws {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r2, in: &$0) }
        inspector(m).cite(a)

        let r1After = try XCTUnwrap(m.scene.region(r1))
        XCTAssertTrue(r1After.appearsHere(a))
        XCTAssertFalse(r1After.livesHere(a), "cited, not moved")
        XCTAssertTrue(try XCTUnwrap(m.scene.region(r2)).livesHere(a),
                      "one home, many appearances — the citation does not take "
                      + "the card away from the region it lives in")
        XCTAssertNotNil(m.scene.node(a), "and it is still one card, not two")
    }

    /// The full round trip the smoke script walks: cite → it is listed under
    /// "Appears here" → it is drawn as a chip hairlined back to the real card.
    /// Before this control, every one of those three was reachable only from a
    /// test.
    func test_aCitedCardIsListedAsAVisitorAndDrawnAsAChip() throws {
        let m = model()
        // Parked well outside the region, which is the interesting case: the
        // chip is drawn inside r1 and hairlined back to where the card actually
        // is. Nothing about that geometry decides membership (§4.2).
        m.withScene { $0.move(self.a, to: CGPoint(x: 900, y: 900)) }
        m.setScrapText("The lamp on the bridge", for: a)
        inspector(m).cite(a)

        XCTAssertEqual(inspector(m).visitors.map(\.title), ["The lamp on the bridge"])
        let chips = CanvasRenderer.appearanceChips(in: m.scene)
        XCTAssertEqual(chips.map(\.node), [a],
                       "Task 4 draws this and nothing could put anything in it")
        XCTAssertEqual(try XCTUnwrap(chips.first).region, r1)
    }

    func test_citingReachesDiskAndIsUndoable() throws {
        let m = model()
        inspector(m).cite(a)
        m.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.region(r1)?.appearances,
                       [a], "Task 2 round-trips appearances; this is the first "
                       + "production write that makes one")
        m.undo.undo()
        XCTAssertTrue(try XCTUnwrap(m.scene.region(r1)).appearances.isEmpty)
    }

    /// **The nesting test, and the one that needs the step's NAME.** A visit to a
    /// scrap holds "Edit Scrap" open and nothing on the inspector's side closes
    /// it; through `CanvasModel.mutate` the citation nests, registers nothing of
    /// its own, and rides into the writer's next keystroke.
    ///
    /// Asserting only the post-⌘Z scene cannot see that: the enclosing bracket's
    /// snapshot predates the citation too, so undoing it also removes the
    /// appearance and every scene assertion is satisfied by the coincidence.
    /// Measured twice already in this task (M13, M31). The discriminator is what
    /// the writer reads in the Edit menu.
    func test_aCitationIsItsOwnStepWithAScrapStillFocused() throws {
        let m = model()
        m.beginGesture("Edit Scrap")
        m.setScrapText("The fog came down.", for: b)

        inspector(m).cite(a)
        XCTAssertTrue(m.undo.undoMenuItemTitle.contains("Cite in Region"),
                      "the step on top must be the citation's own — through "
                      + "`mutate` it would be \"Edit Scrap\", and the scene "
                      + "assertions below pass either way. Got: "
                      + m.undo.undoMenuItemTitle)

        m.undo.undo()
        XCTAssertTrue(try XCTUnwrap(m.scene.region(r1)).appearances.isEmpty,
                      "one ⌘Z takes back the citation…")
        XCTAssertEqual(m.scraps[b], "The fog came down.",
                       "…and the sentence in flight is not collateral damage")
    }

    /// The offer: everything on the canvas that is not already in this region,
    /// counted from both sides so a filter that drops the wrong set is visible.
    func test_theOfferIsEveryCardNotAlreadyInThisRegion() {
        let m = model()
        m.withScene {
            CanvasMembership.join(self.a, home: self.r1, in: &$0)
            CanvasMembership.addAppearance(self.b, to: self.r1, in: &$0)
        }
        XCTAssertEqual(inspector(m).candidates.map(\.node), [c],
                       "a resident is not offered (it is already here) and neither "
                       + "is an existing visitor (citing it twice is a no-op step)")
    }

    /// A card that lives in ANOTHER region is the whole point of the control, so
    /// it must be on the list. This is the assertion that dies if the candidate
    /// filter is written against every region's membership rather than this
    /// region's.
    func test_aCardLivingInAnotherRegionIsOffered() {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r2, in: &$0) }
        XCTAssertTrue(inspector(m).candidates.map(\.node).contains(a),
                      "the street photo belongs to the piece it illustrates AND "
                      + "to the book's visual language — offering only homeless "
                      + "cards is the premature single choice again")
    }

    /// Same comparator as the member lists, and the same reason: every empty card
    /// answers `chipTitle` with the same placeholder, so title alone leaves a
    /// `Set`'s iteration order deciding a menu the writer is reading.
    func test_theOfferIsOrderedByTitleThenId() {
        let m = model()
        m.setScrapText("Zermatt", for: a)
        m.setScrapText("Aare", for: b)
        m.setScrapText("Matterhorn", for: c)
        XCTAssertEqual(inspector(m).candidates.map(\.title),
                       ["Aare", "Matterhorn", "Zermatt"])
    }

    /// **Empty state: no live control onto nothing.** Both ways in — a region
    /// that already holds everything, and a canvas with no cards at all — and
    /// they get different sentences, because they are different acts for the
    /// writer (make a card, or accept that this region holds the lot).
    func test_aRegionWithNothingLeftToOfferPresentsNoControl() throws {
        let m = model()
        m.withScene {
            for id in [self.a, self.b, self.c] {
                CanvasMembership.join(id, home: self.r1, in: &$0)
            }
        }
        m.bumpSceneRevision()
        let i = inspector(m)
        XCTAssertEqual(i.citeAffordance(from: i.refreshedRows(from: .init())),
                       .explanation("Every card on the canvas is already in this region."))

        let bare = CanvasModel()
        bare.attach(projectRoot: root.appendingPathComponent("bare"))
        bare.withScene {
            $0.insertRegion(CanvasRegion(id: self.r1, label: "Only",
                                         frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        }
        let onEmptyCanvas = RegionInspector(model: bare, regionID: r1, pieces: [],
                        artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                        onOpenResearchItem: { _ in })
        XCTAssertEqual(onEmptyCanvas.citeAffordance(from: onEmptyCanvas.refreshedRows(from: .init())),
                       .explanation("There are no cards on the canvas to cite."),
                       "and it is a DIFFERENT sentence — the writer's next act is "
                       + "to make a card, not to accept a full region")
    }

    /// The control, and the other side of the rule above: with something to
    /// offer, the affordance is the live menu carrying exactly the gated list.
    func test_aRegionWithSomethingToOfferPresentsTheMenu() {
        let m = model()
        m.bumpSceneRevision()
        let i = inspector(m)
        let rows = i.refreshedRows(from: .init())
        guard case .menu(let offer) = i.citeAffordance(from: rows) else {
            return XCTFail("a canvas with three uncited cards must offer a live menu")
        }
        XCTAssertEqual(offer.map(\.node), [a, b, c])
        XCTAssertEqual(offer, rows.candidates,
                       "the menu offers the gated snapshot and nothing it "
                       + "recomputed for itself")
    }

    /// Citing something already here must not push a step. It is reachable: the
    /// candidate list is a gated snapshot, so an undo can put the card into this
    /// region between the menu opening and the writer choosing.
    func test_citingACardThatIsAlreadyHereIsANoOp() {
        let m = model()
        m.withScene {
            CanvasMembership.join(self.a, home: self.r1, in: &$0)
            CanvasMembership.addAppearance(self.b, to: self.r1, in: &$0)
        }
        m.bumpSceneRevision()
        let before = m.sceneRevision
        inspector(m).cite(a)
        inspector(m).cite(b)
        XCTAssertEqual(m.sceneRevision, before,
                       "two citations of cards already in the region — without the "
                       + "guard each one redraws the canvas and costs a ⌘Z")
        XCTAssertFalse(m.undo.canUndo)
    }

    /// The other half of that window: an undo took the card off the canvas
    /// entirely while the menu was open.
    func test_citingACardThatHasLeftTheCanvasIsANoOp() throws {
        let m = model()
        let stale = inspector(m).candidates
        XCTAssertTrue(stale.map(\.node).contains(a), "the control: it was offered")
        m.withScene { $0.remove(self.a) }
        m.bumpSceneRevision()
        let before = m.sceneRevision
        inspector(m).cite(a)
        XCTAssertEqual(m.sceneRevision, before)
        XCTAssertTrue(try XCTUnwrap(m.scene.region(r1)).appearances.isEmpty,
                      "a stale menu row must not cite a card that is gone — the "
                      + "region would carry an id nothing on the canvas answers to")
    }

    /// The candidate list is behind the SAME gate as the member lists, and it
    /// needs it more: it walks every node in the scene rather than one region's
    /// members. Both directions, exactly as the member-list gate is tested.
    func test_theCandidateListIsGatedOnTheStructuralCounterToo() {
        let m = model()
        m.bumpSceneRevision()
        let i = inspector(m)

        var rows = i.refreshedRows(from: RegionInspector.MemberRows())
        XCTAssertEqual(rows.candidates.map(\.node), [a, b, c])

        // A membership change with no structural bump — a drag frame's shape.
        m.withScene(persist: false) { CanvasMembership.addAppearance(self.a, to: self.r1, in: &$0) }
        rows = i.refreshedRows(from: rows)
        XCTAssertEqual(rows.candidates.map(\.node), [a, b, c],
                       "no bump, no rebuild — this is the frame-path saving, and "
                       + "the candidate walk is the biggest thing behind the gate")

        m.bumpSceneRevision()
        rows = i.refreshedRows(from: rows)
        XCTAssertEqual(rows.candidates.map(\.node), [b, c],
                       "and a real structural change is picked up, or the gate has "
                       + "simply frozen the offer")
    }

    /// **A drag frame does not move the key.** The gate above is only worth
    /// anything if the thing it is keyed on is genuinely still during a drag —
    /// this is the half of the claim that names the frame path.
    func test_aDragFrameDoesNotMoveTheKeyTheOfferIsGatedOn() {
        let m = model()
        let i = inspector(m)
        let before = i.currentRowsKey
        for x in stride(from: 0.0, through: 200.0, by: 10.0) {
            m.withScene(persist: false) { $0.move(self.a, to: CGPoint(x: x, y: x)) }
        }
        XCTAssertEqual(i.currentRowsKey, before,
                       "twenty-one frames of a card drag. If this ever fails, "
                       + "something started bumping the STRUCTURAL counter per "
                       + "frame and every list in this inspector is back on the "
                       + "drag loop (tripwire 30).")
    }

    /// **The view must read the gated snapshot, not the computed property.** The
    /// gate is what keeps a scene-wide walk off the frame path, and `body` is one
    /// character away from bypassing it — `ForEach(candidates)` compiles, reads
    /// correctly, and runs the whole walk on every drag frame. No behavioural
    /// test can see that; only the source can.
    func test_theOfferReachesTheViewOnlyThroughTheGatedSnapshot() throws {
        let source = try CanvasSourceCensus.commentsStripped(regionInspectorSource())
        XCTAssertTrue(source.contains("citeAffordance(from: memberRows)"),
                      "the control is HANDED the gated snapshot — that call is the "
                      + "whole wiring, and without it the branch below has nothing "
                      + "to police")
        XCTAssertTrue(bypassesTheGate(source).isEmpty,
                      "outside the snapshot type, the computed property and the "
                      + "refresh, `candidates` may only be read off a VALUE "
                      + "(`rows.candidates`) and never as this view's own "
                      + "scene-walking property. Found: \(bypassesTheGate(source))")
    }

    /// The menu's rows must actually call `cite`. This is a source assertion and
    /// it is the weakest thing in this file — a mounted-`Menu` test that opens
    /// the menu and clicks a row is the real delivery path, and it is not worth
    /// the flake. It fires on the one bug it can see: a control that renders the
    /// offer and wires it to nothing.
    func test_theMenusRowsAreWiredToTheCommit() throws {
        let control = try XCTUnwrap(
            declaration(named: "private var citeControl: some View {",
                        in: CanvasSourceCensus.commentsStripped(regionInspectorSource())))
        XCTAssertTrue(control.contains("cite(row.node)"),
                      "the offer is rendered and the click does nothing")
    }

    /// The house self-check (`test_applyExternalTextCensusFiresOnPlantedSecondCallSite`
    /// is the precedent), because a scan over a token that is REQUIRED to be
    /// present is exactly the shape that passes while blind — this task shipped
    /// one such census and only the planted offender caught it.
    func test_theGateScanFiresOnAPlantedBypass() {
        let offender = """
            struct RegionInspector: View {
                struct MemberRows: Equatable {
                    var candidates: [Row] = []
                }
                var body: some View {
                    Menu { ForEach(candidates) { row in Button(row.title) {} } }
                }
                var candidates: [Row] {
                    rows([])
                }
                func refreshedRows(from current: MemberRows) -> MemberRows {
                    MemberRows(candidates: candidates)
                }
            }
            """
        XCTAssertFalse(bypassesTheGate(offender).isEmpty,
                       "a `ForEach(candidates)` in the body is the bug this scan "
                       + "exists for, and the scan must see it")

        let sanctioned = offender.replacingOccurrences(of: "ForEach(candidates)",
                                                       with: "ForEach(memberRows.candidates)")
        XCTAssertTrue(bypassesTheGate(sanctioned).isEmpty,
                      "and the control: the same file reading the snapshot passes")

        // The nesting case, which an indentation-based block finder gets wrong:
        // `MemberRows` holds `Key`, so stopping at the FIRST close brace at
        // member indentation would leave the struct's own field behind and this
        // scan would fail on a clean file.
        XCTAssertTrue(bypassesTheGate("""
            struct RegionInspector: View {
                struct MemberRows: Equatable {
                    struct Key: Equatable { let revision: Int }
                    var candidates: [Row] = []
                }
            }
            """).isEmpty, "the stored field inside a nested type is not a bypass")
    }

    /// **The check that would have caught this gap a task earlier.** A green
    /// suite cannot tell a fully-exercised function from a reachable one;
    /// `CanvasMembership.addAppearance` was stored, drawn, listed and removable
    /// with no production caller at all, exactly as `CanvasScene.remove` was one
    /// slice before it. Only a caller count sees that.
    ///
    /// **Each name here is an admission, and it carries its reason.** A name with
    /// no reason beside it is the census eroding into a list somebody appends to
    /// when the build goes red:
    ///
    /// - `RegionInspector.swift` — the writer citing a card by hand, through
    ///   "Cite a Card". Citing is an inspector act rather than a gesture,
    ///   deliberately: a modifier-held drop would need a flag threaded through
    ///   `CanvasEventNSView`'s callbacks for something nobody would discover.
    /// - `CanvasClaudePlacement.swift` *(1C-c3)* — a second Claude batch read off
    ///   a page the canvas already holds. The page keeps its home and the new
    ///   region **cites** it, because moving it would make a geometry change into
    ///   a membership change, which is the transition rule §4.2 exists to refuse
    ///   (tripwire 31) — the one tldraw ships despite storing membership. One
    ///   home, many appearances is what makes citing the available answer.
    func test_makingAnAppearanceHasAProductionCaller() throws {
        let callers = try CanvasSourceCensus.productionFiles()
            .filter { $0.name != "CanvasMembership.swift" && $0.name != "CanvasRegion.swift" }
            .filter {
                CanvasSourceCensus.commentsStripped($0.source)
                    .contains("CanvasMembership.addAppearance(")
            }
            .map(\.name)
            .sorted()
        XCTAssertEqual(callers, ["CanvasClaudePlacement.swift", "RegionInspector.swift"],
                       "if this is ever empty again, appearances are persisted, "
                       + "drawn, listed and removable — and uncreatable. If it "
                       + "grows, the new caller is a deliberate edit here — and "
                       + "it gets a line in this test's doc comment saying why it "
                       + "cites rather than joins.")
    }

    /// **The same check, on the projection this file spends its first section
    /// testing** — and until M1A Task 10 it came back EMPTY. Six tests above
    /// pin two rules (residents only, unioned across regions) that no production
    /// code had ever asked for, while `list_canvas` shipped `bound_piece_id`,
    /// `home_node_ids` and `appearance_node_ids` raw. That is worse than an
    /// unused function: a reader derives the piece's context from the fields it
    /// can see, gets `home ∪ appearances`, and nothing anywhere says otherwise.
    ///
    /// - `CanvasTools.swift` — `list_canvas` reports the projection as
    ///   `piece_references`, so the two rules are on the wire rather than in a
    ///   doc comment nothing reads. It CALLS the function rather than deriving
    ///   the rule a second time, which is tripwire 19's reasoning one layer down.
    /// - `CanvasHighlight.swift` *(slice 3)* — the DIM. §4's *"its bound regions
    ///   and their resident cards lit; everything else dimmed"* is this
    ///   projection made visible in the app rather than only over MCP, and it
    ///   consumes it for the *cards* half only: the projection dissolves the
    ///   regions away, so which regions light is a second derivation that file
    ///   owns. It calls rather than re-derives for the reason above, and the
    ///   failure re-deriving produces is on screen: `home ∪ appearances` lights
    ///   a card merely visiting a bound region.
    /// - `PinnedReferences.swift` *(M2 Task 2)* — **the rail itself**, arriving
    ///   where the entry below said it would. It consumes the projection as the
    ///   CANVAS HALF of what is pinned beside a document, unioned with the
    ///   research the writer linked, and it is the only caller with three
    ///   readers downstream of it (the References pane, the assistant column,
    ///   the compiler's context listing) — which is precisely why none of those
    ///   three may see `bound_piece_id` at all. Note it is not in
    ///   `Maugham/Canvas/`: the census walks the production tree, and a rail
    ///   built one directory over is exactly the reader this test exists to
    ///   catch re-deriving.
    ///
    /// The rail was **M2's** (umbrella spec §10 — the intent strip, pinned
    /// references and the assistant column) and is now built. A `RegionInspector`
    /// or `Persona` entry appearing here is still not that rail: those are the
    /// canvas's own panes, and one calling the projection needs its own
    /// argument, not a line in this list.
    func test_theProjectionHasAProductionCaller() throws {
        let files = try CanvasSourceCensus.productionFiles()
        let callers = files
            .filter { $0.name != "RegionBinding.swift" }
            .filter {
                CanvasSourceCensus.commentsStripped($0.source)
                    .contains("RegionBinding.references(")
            }
            .map(\.name)
            .sorted()
        XCTAssertEqual(callers, ["CanvasHighlight.swift", "CanvasTools.swift",
                                 "PinnedReferences.swift"],
                       "if this is ever empty again, the two rules below §4.4 are "
                       + "reachable only from this file and every other reader "
                       + "re-derives them wrongly. If it grows, the new caller is a "
                       + "deliberate edit here — and it gets a line in this test's "
                       + "doc comment saying what it consumes the projection for.")

        // The companion. `CanvasScene.remove`'s doc comment names this function
        // in prose, so a scan that under-stripped would count it as a caller and
        // a scan that read nothing at all would report the same empty list as a
        // genuinely dormant projection.
        let scene = try XCTUnwrap(files.first { $0.name == "CanvasScene.swift" })
        XCTAssertTrue(scene.source.contains("RegionBinding.references("),
                      "the corpus is not being read — this file discusses the "
                      + "projection by name")
        XCTAssertFalse(
            CanvasSourceCensus.commentsStripped(scene.source)
                .contains("RegionBinding.references("),
            "…and a mention in a doc comment is not a call, or every file in this "
            + "directory that discusses the projection counts as one")
    }

    func test_theInspectorListsResidentsAndVisitorsSeparately() {
        let m = model()
        m.withScene {
            CanvasMembership.join(self.a, home: self.r1, in: &$0)
            CanvasMembership.addAppearance(self.b, to: self.r1, in: &$0)
        }
        let i = inspector(m)
        XCTAssertEqual(i.residents.map(\.node), [a])
        XCTAssertEqual(i.visitors.map(\.node), [b],
                       "§4.3: any region should answer 'which of these live here "
                       + "and which are visiting' at a glance")
    }

    /// Three residents whose titles sort the opposite way from their ids, so a
    /// list that fell back on the id — or on `Set` iteration order — is a
    /// different list.
    func test_theMemberListIsOrderedByTheTitleTheCanvasShows() {
        let m = model()
        m.withScene {
            for id in [self.a, self.b, self.c] {
                CanvasMembership.join(id, home: self.r1, in: &$0)
            }
        }
        m.setScrapText("Zermatt", for: a)
        m.setScrapText("Aare", for: b)
        m.setScrapText("Matterhorn", for: c)
        XCTAssertEqual(inspector(m).residents.map(\.title),
                       ["Aare", "Matterhorn", "Zermatt"])
        XCTAssertEqual(inspector(m).residents.map(\.node), [b, c, a],
                       "title order, which here is not the id order")
    }

    /// The id tiebreak. Every empty card answers `chipTitle` with the same
    /// placeholder, so title alone leaves a `Set`'s iteration order deciding the
    /// list, through a `sorted(by:)` that is not documented as stable — a
    /// different order on every launch, in the common case of a region full of
    /// cards the writer has just made and not yet typed into.
    ///
    /// **EIGHT cards, and the count is the assertion.** With two or three, a
    /// title-only comparator lands on the id order by chance often enough that
    /// the mutation stays green — measured. At eight there are 40,320 orders and
    /// only one of them passes.
    func test_cardsSharingATitleAreOrderedByIdRatherThanByChance() {
        let m = model()
        let empties = (1...8).map { CanvasNodeID("n\($0)") }
        m.withScene { scene in
            for id in empties {
                scene.insert(CanvasNode(id: id, kind: .scrap, origin: .zero,
                                        width: 240, cachedHeight: 80))
                CanvasMembership.join(id, home: self.r1, in: &scene)
            }
        }
        for id in empties { m.setScrapText("", for: id) }

        let rows = inspector(m).residents
        XCTAssertEqual(Set(rows.map(\.title)), [CanvasAccessibility.emptyScrapValue],
                       "the control: every one of them has the same title")
        XCTAssertEqual(rows.map(\.node.raw), empties.map(\.raw).sorted())
    }

    func test_aMemberThatIsNoLongerACardIsNotListed() {
        let m = model()
        m.withScene {
            CanvasMembership.join(self.a, home: self.r1, in: &$0)
            CanvasMembership.addAppearance(self.b, to: self.r1, in: &$0)
        }
        // Reach past `CanvasScene.remove`, which scrubs the region records too.
        m.withScene { scene in
            var rebuilt = CanvasScene(nodes: [], regions: scene.regions)
            rebuilt.insert(CanvasNode(id: self.c, kind: .scrap, origin: .zero,
                                      width: 240, cachedHeight: 80))
            scene = rebuilt
        }
        let i = inspector(m)
        XCTAssertTrue(i.residents.isEmpty, "a stale resident id is not a row")
        XCTAssertTrue(i.visitors.isEmpty, "and neither is a stale visitor id")
    }

    func test_deletingTheRegionFromTheInspectorLeavesTheCards() {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r1, in: &$0) }
        inspector(m).deleteRegion()
        XCTAssertEqual(m.scene.regionCount, 1, "r2 survives")
        XCTAssertNil(m.scene.region(r1))
        XCTAssertNotNil(m.scene.node(a))
        XCTAssertNil(m.selection)
    }

    func test_deletingTheRegionIsUndoable() throws {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r1, in: &$0) }
        inspector(m).deleteRegion()
        m.undo.undo()
        XCTAssertTrue(try XCTUnwrap(m.scene.region(r1)).livesHere(a),
                      "the membership records die with the region and come back with it")
    }

    /// Every commit is reachable with a stale `regionID` — an undo can take the
    /// region away a frame before the button is pressed. None of them may trap,
    /// and none of them may push a step.
    func test_everyCommitIsANoOpOnARegionThatIsGone() {
        let m = model()
        let i = inspector(m)
        m.withScene { $0.removeRegion(self.r1) }
        let before = m.sceneRevision
        i.commitLabel("Falls")
        i.commitCollapsed(true)
        i.commitBinding("piece-3")
        i.remove(a)
        i.cite(b)
        i.deleteRegion()
        XCTAssertEqual(m.sceneRevision, before)
        XCTAssertFalse(m.undo.canUndo)
    }

    /// **The member lists are gated on the STRUCTURAL counter**, because
    /// building them is scene-proportional and `body` runs on every drag, coast
    /// and straighten frame (tripwire 30's shape, one column over).
    ///
    /// Both directions. A membership change that does NOT bump the counter must
    /// not appear — that is the gate doing its job; and one that DOES bump it
    /// must, or the gate has frozen the list.
    ///
    /// **This test drives the bump BY HAND, so it pins the gate and is
    /// structurally incapable of seeing its own premise.** That premise — that
    /// every production path which changes membership really does bump
    /// `CanvasModel.sceneRevision` — used to be asserted here in prose, and was
    /// false: the drop at `handleDrag(.ended)` bumped `CanvasView`'s own `@State`
    /// copy, the mirror runs model → view and never back, and so the inspector
    /// went stale on a card the canvas had already drawn inside the region. Do
    /// not add a hand-driven "drop" case here to cover it; the test that can see
    /// it drops a real card through the real event view, and it is
    /// `CanvasViewMountingRegionTests.test_aDropIntoARegionReachesThatRegionsInspector`.
    func test_theMemberListsAreRebuiltOnlyOnAStructuralChange() {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r1, in: &$0) }
        m.bumpSceneRevision()
        let i = inspector(m)

        var rows = i.refreshedRows(from: RegionInspector.MemberRows())
        XCTAssertEqual(rows.residents.map(\.node), [a])

        // A membership change smuggled in WITHOUT a structural bump — which no
        // production path does, and which is what the gate trades away.
        m.withScene { CanvasMembership.leave(self.a, from: self.r1, in: &$0) }
        rows = i.refreshedRows(from: rows)
        XCTAssertEqual(rows.residents.map(\.node), [a],
                       "no bump, no rebuild — this is the frame-path saving")

        m.bumpSceneRevision()
        rows = i.refreshedRows(from: rows)
        XCTAssertTrue(rows.residents.isEmpty,
                      "and a real structural change is picked up, or the gate has "
                      + "simply frozen the list")
    }

    /// Selecting a different region is NOT a structural change, so the counter
    /// does not move — and the rows would otherwise still be the old region's.
    func test_theMemberListsAlsoRebuildWhenTheSelectedRegionChanges() {
        let m = model()
        m.withScene {
            CanvasMembership.join(self.a, home: self.r1, in: &$0)
            CanvasMembership.join(self.b, home: self.r2, in: &$0)
        }
        m.bumpSceneRevision()
        let showingR1 = inspector(m)
        let rows = showingR1.refreshedRows(from: RegionInspector.MemberRows())
        XCTAssertEqual(rows.residents.map(\.node), [a])

        let showingR2 = RegionInspector(model: m, regionID: r2, pieces: [],
                        artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                        onOpenResearchItem: { _ in })
        let carriedOver = showingR2.refreshedRows(from: rows)
        XCTAssertEqual(carriedOver.residents.map(\.node), [b],
                       "the counter has not moved, so `regionID` is the term that "
                       + "has to force this rebuild")
    }

    // MARK: - The inspector edits a scene the canvas is still holding open

    /// **A visit to a scrap holds "Edit Scrap" open, and nothing on the
    /// inspector's side of the window closes it.** Select a region's chrome,
    /// double-click a card (which deliberately leaves `selection` alone), then
    /// rename the region: through `CanvasModel.mutate` that rename nests, depth
    /// 2 takes no snapshot, depth 1 registers nothing, and the rename is not on
    /// the stack at all — while the writer's next keystroke carries it into a
    /// step called "Edit Scrap".
    func test_anInspectorEditIsItsOwnStepWithAScrapStillFocused() {
        let m = model()
        m.beginGesture("Edit Scrap")
        m.setScrapText("The fog came down.", for: a)

        inspector(m).commitLabel("Falls at night")
        XCTAssertEqual(m.scene.region(r1)?.label, "Falls at night")

        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.label, "Act II fog",
                       "one ⌘Z takes back the rename")
        XCTAssertEqual(m.scraps[a], "The fog came down.",
                       "and the sentence the writer was in the middle of is not "
                       + "collateral damage")
    }

    /// The other half: the visit RESUMES, so what the writer types after the
    /// inspector edit is still bracketed. Drop the reopen and this run of typing
    /// belongs to no gesture at all.
    func test_theOpenVisitResumesAfterAnInspectorEdit() {
        let m = model()
        m.beginGesture("Edit Scrap")
        m.setScrapText("One.", for: a)
        inspector(m).commitLabel("Falls")
        m.setScrapText("One. Two.", for: a)
        m.endGesture()

        m.undo.undo()
        XCTAssertEqual(m.scraps[a], "One.", "the typing after the rename is its own step…")
        // **This is the assertion that sees the reopen**, and the version without
        // it passed with the reopen deleted (mutation, 2026-07-28): with no
        // gesture open, the second run of typing is registered nowhere at all,
        // so the first ⌘Z lands on the rename's snapshot — which happens to hold
        // "One." too, and every other assertion here is satisfied by the
        // coincidence.
        XCTAssertEqual(m.scene.region(r1)?.label, "Falls",
                       "…and ONLY that. The rename is a step of its own and is "
                       + "still standing after one ⌘Z.")
        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.label, "Act II fog")
        XCTAssertEqual(m.scraps[a], "One.", "and the typing is not collateral")
        m.undo.undo()
        XCTAssertNil(m.scraps[a], "the typing before the rename is the step under that")
    }

    // MARK: - Mounted only beside a live canvas

    /// **The invariant this surface must not break.** After `detach()` the model
    /// still has a store, so a write still reaches disk — but `readSnapshot` and
    /// `applySnapshot` are nil, so `beginGesture` snapshots nothing,
    /// `endGesture` returns on its `guard let before`, and the edit registers no
    /// undo step **silently**.
    ///
    /// A guard inside the inspector was considered and rejected: `store = nil`
    /// would turn the failure from *wrong* to *silently nothing*, which is not
    /// better. The answer is that the inspector is only ever mounted beside a
    /// live canvas — pinned structurally in the two tests below. This one
    /// measures what is on the other side of that rule, so the next author does
    /// not have to rediscover it.
    func test_aDetachedModelTakesTheEditAndRegistersNothing() {
        let m = model()
        m.detach()
        inspector(m).commitLabel("Falls at night")
        XCTAssertEqual(m.scene.region(r1)?.label, "Falls at night",
                       "the write still lands…")
        XCTAssertFalse(m.undo.canUndo,
                       "…and no step is registered for it, which is why the "
                       + "inspector must never outlive the canvas")
    }

    /// **The canvas is mounted ONCE in each column, and this census counts the
    /// mounts.**
    ///
    /// It used to count the SWITCHES as well — two of them, over `binderSegment`,
    /// one per column, each with a joined `.canvas, .tree` arm. Both switches and
    /// the enum they dispatched on died in shell-finish stage 2b Task 7, and with
    /// them the unreachable arms that existed only because the compiler demanded
    /// an answer for every case. What is left is the question that was always the
    /// real one: how many places build the board.
    ///
    /// **A second mount is a second view identity**, and what that costs the
    /// writer is their camera, every scrap layout, the thumbnail cache and the
    /// in-progress scrap edit — with nothing red anywhere, because both mounts
    /// draw the same scene. Measured on macOS 26.5 (2026-08-02) across the
    /// `.canvas` ↔ `.tree` flip that used to make the point: an arm apiece put a
    /// camera at pan (−680, −420) / zoom 1.5 back at the origin at zoom 1, with a
    /// different `CanvasEventNSView` and `load()` having run twice.
    func test_theCanvasIsBuiltInExactlyOnePlacePerColumn() throws {
        let source = try projectWindowSource()

        XCTAssertEqual(occurrences(of: "CanvasView(", in: source), 1,
                       "one mount for the canvas, in `canvasCentre`. A second is "
                       + "a second view identity, and the writer pays for it in "
                       + "camera, layouts and thumbnails")
        XCTAssertEqual(occurrences(of: "canvasCentre(", in: source), 2,
                       "the declaration and exactly ONE call — `editorPane`'s "
                       + "`.canvas` route, taken above everything that could "
                       + "give the board a second branch. A THIRD occurrence is "
                       + "a real second mount point.")

        XCTAssertEqual(occurrences(of: "RegionInspectorPane(", in: source), 1,
                       "one mount point each; a second would not be gated on the "
                       + "route above")
        XCTAssertEqual(occurrences(of: "canvasInspector(", in: source), 2,
                       "the declaration and exactly ONE call — `researchOrSubject`'s "
                       + "`.canvas` route, taken ABOVE the project-type split so a "
                       + "Collection reaches it (smoke, 2026-07-28). Which route "
                       + "the canvas actually takes is pinned behaviourally and "
                       + "exhaustively by `CanvasRouteTests`, which is the test "
                       + "this census could not be.")
    }

    /// Tripwire 30's rule, one column over: `CanvasModel` is `@Observable` and
    /// `scene` is one stored property that every drag and coast frame writes, so
    /// reading it from `ProjectWindow.body` puts the largest body in the app on
    /// the drag loop.
    func test_theCanvasInspectorArmReadsNothingOffTheModel() throws {
        let source = try projectWindowSource()
        let arm = try XCTUnwrap(declaration(named: "private func canvasInspector(",
                                            in: source))
        XCTAssertTrue(arm.contains("RegionInspectorPane("))
        XCTAssertFalse(arm.contains("canvasModel."),
                       "resolving the selection here re-evaluates ProjectWindow.body "
                       + "at frame rate for the length of every canvas drag — "
                       + "`RegionInspectorPane` does the resolving one leaf down")
    }

    /// **The control that says where the dependency stops.**
    ///
    /// The first version of this asserted the opposite — that constructing the
    /// pane observes nothing — and it could not fail:
    /// `withObservationTracking` registers only reads performed inside its
    /// closure, and that closure ran a memberwise `init` touching no observable
    /// property, so `fired` was false unconditionally. It stayed green with the
    /// pane's body reading the whole scene, which it does and must.
    ///
    /// Inverted, it is honest and it is falsifiable: the pane's BODY observes
    /// the scene, which is the whole design — the per-frame dependency exists,
    /// one leaf below `ProjectWindow.body`, where re-evaluating it is cheap.
    /// The pin on the arm above it is
    /// `test_theCanvasInspectorArmReadsNothingOffTheModel`, and that is the test
    /// the M22 mutation dies on.
    func test_thePanesBodyIsWhereTheSceneDependencyStops() {
        let m = model()
        var fired = false
        withObservationTracking {
            _ = RegionInspectorPane(model: m, pieces: [],
                                    artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                                    onOpenResearchItem: { _ in }).body
        } onChange: {
            fired = true
        }
        m.withScene(persist: false) {
            $0.setRegionFrame(CGRect(x: 40, y: 40, width: 600, height: 400), for: self.r1)
        }
        XCTAssertTrue(fired,
                      "the pane's body reads the scene, so a drag frame invalidates "
                      + "THIS view — and nothing above it. If this ever goes false "
                      + "the pane has stopped reading the model and the inspector "
                      + "is showing a frozen region.")
    }

    // MARK: - Whose region this is (spec §8A.2)

    /// The index both panes already hold, standing in for the manifest.
    private let artifacts: (String) -> String? = { id in
        ["res-fog": "Act II fog", "res-a": "The falls at night"][id]
    }

    /// A Claude region, optionally holding the page the batch was read off — the
    /// shape `CanvasClaudePlacement.apply` produces.
    private func claudeRegionModel(source: String? = nil,
                                   author: AnnotationAuthor.SourceKind? = .claude)
        -> CanvasModel {
        let m = model()
        m.withScene { s in
            s.insertRegion(CanvasRegion(
                id: self.r1, label: CanvasClaudePlacement.defaultRegionLabel,
                frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                homeMembers: [self.a], author: author))
            if let source {
                let page = CanvasNodeID.item(source)
                s.insert(CanvasNode(id: page, kind: .item(.project(id: source)),
                                    origin: CGPoint(x: 0, y: 200), width: 240,
                                    cachedHeight: 40, author: .claude))
                CanvasMembership.join(page, home: self.r1, in: &s)
            }
        }
        return m
    }

    /// **The asymmetry CLAUDE.md rule 8 exists for.** A Claude region is drawn at
    /// exactly 0° and announced with `CanvasAccessibility.claudeTerm`, and for one
    /// round the only pane a writer could inspect one in said nothing about it —
    /// which is the previous slice's Critical (a region drew the stripe, carried
    /// the field, was announced, and its own pane was silent) arriving on the
    /// other field.
    func test_aClaudeRegionSaysSoInItsInspector() {
        let m = claudeRegionModel()
        let line = CanvasAuthorLine.forRegion(r1, in: m.scene, title: artifacts)
        XCTAssertEqual(line, .claude)
        let sentence = line.sentence ?? ""
        XCTAssertFalse(sentence.isEmpty,
                       "a region the writer did not sweep must say so in its own pane")
        // One wording for one fact: the spoken term, the default region label and
        // the undo step are the other three, and the card arm's line is this same
        // sentence — not a fifth phrasing and not a sixth.
        XCTAssertTrue(sentence.lowercased()
            .contains(CanvasAccessibility.claudeTerm.lowercased()),
                      "found: \(sentence), which does not contain "
                      + "\"\(CanvasAccessibility.claudeTerm)\"")
    }

    /// The source page, named — through the **deferred** `artifactTitle` closure
    /// this pane already holds, which has no default for the reason
    /// `PromotedArtifactSection` records: a default is how a section went missing
    /// with nothing red.
    func test_aClaudeRegionWhoseSourceIsKnownNamesIt() {
        let m = claudeRegionModel(source: "res-fog")
        XCTAssertEqual(CanvasAuthorLine.forRegion(r1, in: m.scene, title: artifacts),
                       .claudeReadFrom(title: "Act II fog"))
        XCTAssertEqual(
            CanvasAuthorLine.forRegion(r1, in: m.scene, title: artifacts).sentence,
            "From Claude. Read from “Act II fog”.")
    }

    /// The one-source rule, on this arm too: with two item members in the region
    /// there is no fact to state, so it names neither rather than whichever sorted
    /// first.
    func test_twoPagesInTheRegionMeanTheRegionNamesNoSource() {
        let m = claudeRegionModel(source: "res-fog")
        m.withScene { s in
            let second = CanvasNodeID.item("res-a")
            s.insert(CanvasNode(id: second, kind: .item(.project(id: "res-a")),
                                origin: CGPoint(x: 300, y: 200), width: 240,
                                cachedHeight: 40))
            CanvasMembership.join(second, home: self.r1, in: &s)
        }
        XCTAssertEqual(CanvasAuthorLine.forRegion(r1, in: m.scene, title: artifacts),
                       .claude)
        // The control, so this is about the COUNT: one page and it is named.
        XCTAssertEqual(
            CanvasAuthorLine.forRegion(r1, in: claudeRegionModel(source: "res-fog").scene,
                                       title: artifacts),
            .claudeReadFrom(title: "Act II fog"))
    }

    /// A page the writer has since deleted is not printed as an id — the treatment
    /// both promotion records already get.
    func test_aDeletedSourcePageIsNotNamedByItsId() {
        let m = claudeRegionModel(source: "res-gone")
        let line = CanvasAuthorLine.forRegion(r1, in: m.scene, title: artifacts)
        XCTAssertEqual(line, .claude)
        XCTAssertFalse((line.sentence ?? "").contains("res-gone"),
                       "found: \(line.sentence ?? "nil")")
    }

    /// **The writer's own regions say nothing new.** `author` nil is the writer, so
    /// this guards a line reading "swept by you" — chrome stating the default, on
    /// every region on every canvas made before 1C-c3.
    func test_theWritersOwnRegionsSayNothingNew() {
        let mine = claudeRegionModel(source: "res-fog", author: nil)
        XCTAssertEqual(CanvasAuthorLine.forRegion(r1, in: mine.scene, title: artifacts),
                       .writer,
                       "a nil author is the writer's own sweep, and a source page "
                       + "sitting in the region must not make it claim otherwise")
        XCTAssertNil(CanvasAuthorLine.writer.sentence,
                     "the writer's own region has no provenance line at all")
        // The control: the same scene with the author restored does speak.
        XCTAssertNotNil(CanvasAuthorLine
            .forRegion(r1, in: claudeRegionModel(source: "res-fog").scene,
                       title: artifacts).sentence)
    }

    /// A selection naming a region the scene no longer holds — an undo, or a
    /// deletion — answers `.writer` rather than asserting anything.
    func test_aRegionTheSceneNoLongerHoldsClaimsNothing() {
        let m = claudeRegionModel()
        m.withScene { $0.removeRegion(self.r1) }
        XCTAssertEqual(CanvasAuthorLine.forRegion(r1, in: m.scene, title: artifacts),
                       .writer)
    }

    /// **Two facts on this arm now, and they must read as different claims** — the
    /// region is Claude's, *and* it produced an artifact. §6.3's rule against one
    /// sentence serving two records is what makes this worth pinning, and the
    /// provenance line specifically must not read as a promotion: re-promoting a
    /// Claude region is as available as re-promoting the writer's own.
    func test_theRegionsProvenanceLineIsNotItsPromotedMark() {
        let m = claudeRegionModel()
        m.withScene { $0.updateRegion(self.r1) { $0.promotedItemID = "res-fog" } }
        let line = CanvasAuthorLine.forRegion(r1, in: m.scene, title: artifacts)
        // `artifactState` takes the RESOLVED title (the region arm resolves it with
        // `flatMap(artifactTitle)`), unlike `provenance`, which takes the lookup.
        let markID = m.scene.region(r1)?.promotedItemID
        let mark = PromotedArtifactSection.artifactState(
            promotedItemID: markID, title: markID.flatMap(artifacts))

        XCTAssertEqual(mark,
                       PromotedArtifactSection.ArtifactState.promoted(itemID: "res-fog",
                                                                      title: "Act II fog"),
                       "precondition: both facts are true of this region at once")
        let sentences = [line.sentence,
                         PromotedArtifactSection.Subject.region.became("Act II fog")]
            .compactMap { $0 }
        XCTAssertEqual(sentences.count, 2,
                       "both facts must have a sentence, or the comparison below "
                       + "passes by having nothing to compare")
        XCTAssertEqual(Set(sentences).count, 2, "found: \(sentences)")
        let provenance = line.sentence ?? ""
        XCTAssertFalse(provenance.contains("Became"), "found: \(provenance)")
        XCTAssertFalse(provenance.lowercased().contains("promot"),
                       "a provenance line that reads as a promotion is a region "
                       + "telling the writer it has already been promoted — found: "
                       + "\(provenance)")
    }

    /// **Every arm that can carry the fact renders the ONE row, and none builds
    /// its own.**
    ///
    /// Which arm of a `_ConditionalContent` renders cannot be asserted and a
    /// `Form`'s contents are not inspectable, so what is pinned is that each arm
    /// reaches the shared implementation. This line lived in `ScrapInspector` alone
    /// for a round — the same shape as `PromotedArtifactSection`, which only the
    /// card arm mounted for a whole slice — and a second resolver on this side
    /// would be a second spelling of both the wording and the one-source rule.
    ///
    /// **Three arms as of 1C-d Task 7**, `ItemInspector` being the newest: a page
    /// `CanvasClaudePlacement` created is drawn at 0° and announced with
    /// `claudeTerm`, so it carries the same field with the same two signals and
    /// needs the same surface.
    ///
    /// **The file list is DISCOVERED, not written down**, which is what makes this
    /// fail when the set grows as well as when it empties. A literal array is the
    /// shape that goes quietly out of date — a prose count one directory over
    /// survived three review passes over a list that said something else — and the
    /// failure it cannot see is precisely the one this exists for: a *new* arm that
    /// does not render the row. Every `*Inspector.swift` in this directory is
    /// either in the table below or on the exemption list beside it, with a reason.
    ///
    /// A LINE is exempt and must not be added: its author is spoken inside
    /// `connectionPhrase` and it has no name of its own for a row to sit beside —
    /// which is also what makes `LineInspector` the planted-offender companion at
    /// the bottom.
    func test_everyInspectorArmRendersTheOneAuthorLine() throws {
        let arms = ["ScrapInspector.swift": "CanvasAuthorLine.forCard(",
                    "RegionInspector.swift": "CanvasAuthorLine.forRegion(",
                    "ItemInspector.swift": "CanvasAuthorLine.forItem("]
        let exempt = ["LineInspector.swift"]

        let directory = CanvasSourceCensus.repoRoot.appendingPathComponent("Maugham/Canvas")
        let discovered = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix("Inspector.swift") }
            .sorted()
        XCTAssertEqual(discovered, (Array(arms.keys) + exempt).sorted(),
                       "an inspector arm was added or removed and this census was "
                       + "not told. Every arm that can carry `author` renders the "
                       + "ONE row (`CanvasAuthorLineRow`); one that cannot goes on "
                       + "the exemption list with its reason. Found: \(discovered)")

        for (name, token) in arms {
            let file = "Maugham/Canvas/\(name)"
            let text = CanvasSourceCensus.commentsStripped(
                try CanvasSourceCensus.source(at: file))
            XCTAssertTrue(text.contains("CanvasAuthorLineRow("),
                          "\(file) must render the shared row — a field with a drawn "
                          + "signal, a spoken term and no inspectable surface is "
                          + "CLAUDE.md rule 8 failing, and it failed for the region "
                          + "arm for a round")
            XCTAssertTrue(text.contains(token),
                          "\(file) must resolve through \(token)")
            XCTAssertFalse(text.contains("\"From Claude.\""),
                           "\(file) spells the sentence itself — there are already "
                           + "four strings for this one fact and the shared type "
                           + "owns the wording")
        }
        // The companion: prove the scan reports an absence rather than always
        // answering true. The plant names a spelling that cannot exist in
        // production.
        let line = try CanvasSourceCensus.source(at: "Maugham/Canvas/LineInspector.swift")
        XCTAssertFalse(line.contains("CanvasAuthorLineRow("),
                       "a line carries no pane-side provenance line (its author is "
                       + "spoken inside `connectionPhrase` and it has no name of its "
                       + "own to sit beside) — and this proves the scan above reads "
                       + "the file rather than always answering true")
    }

    // MARK: - Source helpers

    private func projectWindowSource() throws -> String {
        try CanvasSourceCensus.source(at: "Maugham/Views/ProjectWindow.swift")
    }

    private func regionInspectorSource() throws -> String {
        try CanvasSourceCensus.source(at: "Maugham/Canvas/RegionInspector.swift")
    }

    /// Every mention of `candidates` outside the three places allowed to build or
    /// store it — the `MemberRows` type, the computed property, and the refresh
    /// that fills one from the other — **that is not read off a value**.
    ///
    /// The rule is deliberately about the character before it rather than a list
    /// of blessed spellings: `rows.candidates` and `memberRows.candidates` are
    /// both reads of a snapshot somebody already paid for, and `ForEach(candidates)`
    /// is the scene-wide walk landing in `body`. A whitelist of names would have
    /// to be edited every time the snapshot is passed under a new label; this
    /// does not.
    private func bypassesTheGate(_ strippedSource: String) -> [String] {
        var rest = strippedSource
        for header in ["struct MemberRows: Equatable {",
                       "var candidates: [Row] {",
                       "func refreshedRows(from current: MemberRows) -> MemberRows {"] {
            rest = removingBracedBlock(startingAt: header, in: rest)
        }
        var found: [String] = []
        var search = rest.startIndex..<rest.endIndex
        while let hit = rest.range(of: "candidates", range: search) {
            let precededByADot = hit.lowerBound > rest.startIndex
                && rest[rest.index(before: hit.lowerBound)] == "."
            if !precededByADot {
                let line = rest[..<hit.lowerBound].components(separatedBy: "\n").count
                found.append("line \(line) of the stripped source")
            }
            search = hit.upperBound..<rest.endIndex
        }
        return found
    }

    /// Deletes from `header` to its matching close brace, counted rather than
    /// found by indentation — the three blocks above nest (`MemberRows` holds
    /// `Key`), and an indentation rule would stop at the inner one.
    private func removingBracedBlock(startingAt header: String, in source: String) -> String {
        guard let start = source.range(of: header) else { return source }
        var depth = 0
        var index = start.lowerBound
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[..<start.lowerBound])
                        + String(source[source.index(after: index)...])
                }
            }
            index = source.index(after: index)
        }
        return String(source[..<start.lowerBound])
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// A member declaration, from its opening line to the closing brace at
    /// member indentation.
    private func declaration(named header: String, in source: String) -> String? {
        guard let start = source.range(of: header) else { return nil }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }
}
