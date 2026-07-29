import XCTest
@testable import Maugham

/// The third arm of the canvas inspector. Which SwiftUI arm renders cannot be
/// asserted (`_ConditionalContent` is branch-invariant), so the decision the
/// view makes is lifted into `artifactState` and pinned here — the same shape
/// `RegionInspector.citeAffordance` uses.
@MainActor
final class ScrapInspectorTests: XCTestCase {

    private let a = CanvasNodeID("a")

    /// `CanvasModel.attach` is what wires `CanvasUndo`'s two snapshot closures,
    /// so a model that has never been attached registers no undo step at all —
    /// and it must be called BEFORE the scene is built, because attaching reads
    /// the sidecar over whatever is there.
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scrap-inspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func model(promoted: String? = nil) -> CanvasModel {
        let m = CanvasModel()
        m.attach(projectRoot: root)
        m.withScene { s in
            s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80,
                                promotedItemID: promoted))
        }
        m.setScrapText("The falls at night\n\nSodium light.", for: a)
        return m
    }

    func test_theSelectedNodeResolvesThroughTheSceneAndNotTheRawId() {
        let m = model()
        XCTAssertNil(m.selectedNode, "no selection")
        m.selection = .node(a)
        XCTAssertEqual(m.selectedNode?.id, a)
        m.withScene { $0.remove(a) }
        XCTAssertNil(m.selectedNode,
                     "a stale id left by an undo answers nil rather than being "
                     + "handed out as a card that no longer exists")
    }

    func test_aRegionSelectionIsNotANodeSelection() {
        let m = model()
        m.selection = .region(CanvasRegionID("r1"))
        XCTAssertNil(m.selectedNode)
    }

    /// An item node has no arm of its own until 1C-d, and it must not take the
    /// card's: every sentence in `ScrapInspector` is wrong for a reference —
    /// "The words live on the card", "Promoting takes a copy" — and an item node
    /// cannot be promoted at all. The pane routed every `selectedNode` there.
    ///
    /// `selectedNode` itself still resolves; the guard is the `case .scrap` in
    /// `RegionInspectorPane`, and this is the fact that guard reads.
    func test_anItemNodeIsResolvedAndIsNotAScrap() {
        let m = CanvasModel()
        let ref = CanvasNodeID.item("r-9")
        m.withScene { s in
            s.insert(CanvasNode(id: ref, kind: .item(referenceId: "r-9"),
                                origin: .zero, width: 180, cachedHeight: 120))
        }
        m.selection = .node(ref)
        let node = m.selectedNode
        XCTAssertNotNil(node)
        if case .scrap = node?.kind {
            XCTFail("an item node must not answer the scrap arm's guard")
        }
    }

    // MARK: - What the pane says

    func test_anUnpromotedCardSaysSoRatherThanShowingNothing() {
        XCTAssertEqual(
            PromotedArtifactSection.artifactState(promotedItemID: nil, title: nil),
            .notPromoted)
    }

    func test_aPromotedCardNamesWhatItBecame() {
        XCTAssertEqual(
            PromotedArtifactSection.artifactState(promotedItemID: "res-a",
                                                  title: "The falls at night"),
            .promoted(itemID: "res-a", title: "The falls at night"))
    }

    /// The dangling mark: the note was deleted after the promotion. The pane has
    /// to say so — silently showing "not promoted" would be a lie the writer
    /// cannot check, and showing a raw id would be one they cannot read.
    func test_aMarkWhoseArtifactIsGoneSaysThatRatherThanPretendingItIsUnpromoted() {
        XCTAssertEqual(
            PromotedArtifactSection.artifactState(promotedItemID: "res-gone", title: nil),
            .artifactMissing(itemID: "res-gone"))
    }

    // MARK: - Both arms, one section

    /// **A region's mark had no surface at all for one slice.** The card arm
    /// said what it became, offered Open and rendered the dangling case; the
    /// region arm — same field, same drawn stripe, same VoiceOver term — said
    /// nothing, so a writer met a permanent stripe on a region's chrome bar with
    /// no way to learn what it produced. The section is now one implementation
    /// both arms are handed, and the copy is honest for each.
    func test_theRegionArmNamesThePaletteCardAndTheCardArmDoesNot() {
        XCTAssertEqual(PromotedArtifactSection.Subject.region.became("Act II fog"),
                       "Became the palette card “Act II fog”",
                       "a region's mark can only ever name a palette card — a "
                       + "piece binding produces no artifact and leaves no mark")
        XCTAssertEqual(PromotedArtifactSection.Subject.card.became("Act II fog"),
                       "Became “Act II fog”",
                       "a card's may name a note, a palette card or the craft "
                       + "intent, and this arm is not told which")
    }

    func test_theDanglingSentenceNamesWhichThingWasPromoted() {
        XCTAssertEqual(PromotedArtifactSection.Subject.card.noun, "card")
        XCTAssertEqual(PromotedArtifactSection.Subject.region.noun, "region")
    }

    /// The census that would have caught the omission: both arms mount the
    /// shared section, and both are handed the two closures that make **Open**
    /// work. A green suite cannot tell a rendered section from an absent one
    /// (`_ConditionalContent` is branch-invariant and a `Form`'s contents are
    /// not inspectable), and this directory's four unreachable halves were every
    /// one of them found by counting production sites.
    func test_bothInspectorArmsMountTheSharedPromotedSection() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for file in ["Maugham/Canvas/ScrapInspector.swift",
                     "Maugham/Canvas/RegionInspector.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file),
                                  encoding: .utf8)
            XCTAssertTrue(text.contains("PromotedArtifactSection(state:"),
                          "\(file) must render the shared section — a mark with no "
                          + "surface is CLAUDE.md rule 8 failing, and it failed for "
                          + "the region arm for a whole slice")
            XCTAssertTrue(text.contains("onOpen: onOpenResearchItem"),
                          "\(file) must wire Open, or the section names an artifact "
                          + "the writer cannot reach")
        }
        // Self-check: the scan can report an absence. Without this the two
        // assertions above are a census over a REQUIRED token, which is exactly
        // the shape that passes while blind.
        let unrelated = try String(
            contentsOf: root.appendingPathComponent("Maugham/Canvas/LineInspector.swift"),
            encoding: .utf8)
        XCTAssertFalse(unrelated.contains("PromotedArtifactSection(state:"),
                       "a line promotion writes text into somebody else's note and "
                       + "leaves no mark, so the line arm has nothing to show — and "
                       + "this proves the scan above reads the file rather than "
                       + "always answering true")
    }

    /// **The pane routes only a scrap to the card arm**, and this is the
    /// instrument that pins it.
    ///
    /// Which `_ConditionalContent` arm *renders* cannot be asserted — the type
    /// is branch-invariant — but the line's PRESENCE can be, and a deletion is
    /// what would remove it. Every sentence in `ScrapInspector` is wrong for a
    /// reference ("The words live on the card", "Promoting takes a copy") and an
    /// item node cannot be promoted at all, so the guard is the difference
    /// between an honest empty state and a pane telling the writer to promote
    /// something that already exists as itself.
    func test_thePaneRoutesOnlyAScrapToTheCardArm() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appendingPathComponent("Maugham/Canvas/RegionInspector.swift"),
            encoding: .utf8)
        XCTAssertTrue(text.contains("case .scrap = node.kind"),
                      "RegionInspectorPane must guard the selectedNode branch on the "
                      + "node's KIND — without it every node reaches ScrapInspector, "
                      + "whose whole copy assumes a scrap")
        // The companion: prove the scan reports an absent token rather than
        // always answering true. A census over a REQUIRED token is exactly the
        // shape that passes while blind, and the plant names a spelling that
        // cannot exist in production.
        XCTAssertFalse(text.contains("case .notARealKind = node.kind"),
                       "the scan reads the file rather than always answering true")
    }

    // MARK: - The piece association (spec §6.2)

    private func inspector(_ m: CanvasModel,
                           pieces: [RegionInspector.PieceChoice] =
                            [RegionInspector.PieceChoice(id: "ch-3", title: "Chapter Three")])
        -> ScrapInspector {
        ScrapInspector(model: m, nodeID: a, pieces: pieces,
                       artifactTitle: { _ in nil }, onOpenResearchItem: { _ in })
    }

    private let r1 = CanvasRegionID("r1")

    private func modelInRegion() -> CanvasModel {
        let m = model()
        m.withScene { s in
            s.insertRegion(CanvasRegion(id: self.r1, label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                        homeMembers: [self.a]))
        }
        return m
    }

    private var pieces: [RegionInspector.PieceChoice] {
        [RegionInspector.PieceChoice(id: "ch-3", title: "Chapter Three")]
    }

    /// **A card had no way to be given a piece at all.** Task 3 taught the
    /// performer to route a promotion by the association; only a region could set
    /// one, so a loose card on bare canvas could never have its own.
    func test_aCardCanBeGivenAPieceOfItsOwn() {
        let m = model()
        inspector(m).commitPiece("ch-3")
        XCTAssertEqual(m.scene.node(a)?.boundPieceID, "ch-3")
        XCTAssertEqual(Promotion.piece(for: .scrap(a), in: m.scene), "ch-3",
                       "and the resolver the performer reads sees it")
    }

    /// **Tripwire 32.** The Picker is in the right-hand column, and a focused
    /// scrap holds "Edit Scrap" open behind it — nested, this edit registers no
    /// step of its own and rides into the writer's next sentence. The step's NAME
    /// is the discriminator: a test whose only observable is the post-⌘Z scene
    /// cannot tell "its own step" from "folded into the neighbouring one".
    func test_associatingAndClearingUseDistinctUndoNames() {
        let m = model()
        m.undoManager.groupsByEvent = false
        inspector(m).commitPiece("ch-3")
        XCTAssertTrue(m.undo.undoMenuItemTitle.contains("Associate Card with Piece"),
                      "found: \(m.undo.undoMenuItemTitle)")
        inspector(m).commitPiece(nil)
        XCTAssertTrue(m.undo.undoMenuItemTitle.contains("Clear Card's Piece"),
                      "found: \(m.undo.undoMenuItemTitle)")
    }

    /// Clearing reaches a genuinely different state, so it is its own step —
    /// `LineInspector.commitBinding`'s Bind/Unbind precedent.
    func test_clearingIsItsOwnUndoStepAndNotASilentWrite() {
        let m = model()
        inspector(m).commitPiece("ch-3")
        inspector(m).commitPiece(nil)
        XCTAssertNil(m.scene.node(a)?.boundPieceID)
        m.undo.undo()
        XCTAssertEqual(m.scene.node(a)?.boundPieceID, "ch-3")
    }

    /// The commit guard every one of these inspectors carries: a `Picker` set to
    /// what it already shows must not push a step.
    func test_settingThePieceItAlreadyHasChangesNothing() {
        let m = model()
        inspector(m).commitPiece("ch-3")
        let before = m.sceneRevision
        inspector(m).commitPiece("ch-3")
        XCTAssertEqual(m.sceneRevision, before, "no snapshot, no disk write, no redraw")
    }

    /// **A region's association is never written onto its members** (§6.2): the
    /// more specific setting wins by being read first, never by being written
    /// down. So the card's own field stays empty and the pane says where the
    /// answer came from.
    func test_anInheritedAssociationIsShownAsInherited() {
        let m = modelInRegion()
        m.withScene { $0.updateRegion(self.r1) { $0.boundPieceID = "ch-3" } }
        XCTAssertNil(m.scene.node(a)?.boundPieceID, "nothing of its own")
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces),
                       .inherited(title: "Chapter Three"))
        XCTAssertEqual(
            ScrapInspector.association(for: a, in: m.scene, pieces: pieces).label,
            "Chapter Three (from its region)",
            "the precedence is visible, so the writer can see why an override "
            + "would matter")
    }

    /// The control, and the reason the distinction is worth drawing: the card's
    /// own association reads as its own.
    func test_anOwnAssociationIsShownWithoutTheRegionQualifier() {
        let m = modelInRegion()
        m.withScene { $0.updateRegion(self.r1) { $0.boundPieceID = "other" } }
        inspector(m).commitPiece("ch-3")
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces),
                       .own(title: "Chapter Three"))
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces).label,
                       "Chapter Three")
    }

    func test_noAssociationSaysTheProjectsResearchRatherThanNothing() {
        let m = model()
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces), .none)
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces).label,
                       "The project's research")
    }

    /// The stale association, in the pane rather than in the sheet: the piece was
    /// deleted, or converted to a reference. Shown rather than dropped — a
    /// `Picker` with no row matching its selection renders blank, which reads as
    /// "not bound" and invites the writer to fix a problem they cannot see.
    func test_anAssociationThePickerCannotOfferIsNamedAsMissing() {
        let m = model()
        inspector(m).commitPiece("ref-1")
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces),
                       .missing(id: "ref-1", inherited: false))
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces).label,
                       "Missing piece · ref-1",
                       "the card's OWN stale piece: the Picker beside this shows it "
                       + "too, and clearing it is one click away")
    }

    /// **The stale association the writer cannot clear**, and the case that
    /// `.missing` losing the inheritance made unreachable: the card lives in a
    /// region whose piece was deleted. Its own Picker reads None — correctly,
    /// it carries nothing — so a label saying only "Missing piece · gone-9"
    /// leaves the writer with nothing to clear and no idea where the value
    /// lives. The qualifier is what sends them to the region.
    func test_aStaleAssociationInheritedFromARegionSaysWhereItCameFrom() {
        let m = modelInRegion()
        m.withScene { $0.updateRegion(self.r1) { $0.boundPieceID = "gone-9" } }
        XCTAssertNil(m.scene.node(a)?.boundPieceID,
                     "there is nothing on the card for the writer to clear")
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces),
                       .missing(id: "gone-9", inherited: true))
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces).label,
                       "Missing piece · gone-9 (from its region)")
    }

    /// The card's OWN association wins even when the region's is stale, so the
    /// qualifier cannot start appearing wherever a region happens to be bound.
    func test_anOwnAssociationIsNotQualifiedJustBecauseItsRegionHasOne() {
        let m = modelInRegion()
        m.withScene { $0.updateRegion(self.r1) { $0.boundPieceID = "gone-9" } }
        inspector(m).commitPiece("ch-3")
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces).label,
                       "Chapter Three")
    }

    /// **The resolver is `Promotion.piece`'s, not a second walk.** One that read
    /// the node's field and then the region's would pass every test above and
    /// disagree with the performer the first time §6.2's precedence changed —
    /// the pane would name a destination the promotion does not use.
    func test_thePaneResolvesThroughTheSameFunctionThePerformerAsks() {
        let m = modelInRegion()
        m.withScene { $0.updateRegion(self.r1) { $0.boundPieceID = "ch-3" } }
        // A visitor is not luggage: cited in a region bound to a piece, the card
        // inherits nothing. `Promotion.piece` is where that rule lives.
        let visitor = CanvasNodeID("v")
        m.withScene { s in
            s.insert(CanvasNode(id: visitor, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80))
            CanvasMembership.addAppearance(visitor, to: self.r1, in: &s)
        }
        XCTAssertEqual(ScrapInspector.association(for: visitor, in: m.scene, pieces: pieces),
                       .none,
                       "home decides and visitors do not — and the pane must not "
                       + "invent a second answer to that")
    }

    /// **The census.** Which arm renders cannot be asserted, but the Picker's
    /// presence can — and the verb it commits through is the thing that fails
    /// silently. This directory's instrument, with its planted-offender
    /// companion.
    func test_theCardArmMountsThePiecePickerAndCommitsThroughTheOutsideVerb() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appendingPathComponent("Maugham/Canvas/ScrapInspector.swift"),
            encoding: .utf8)
        XCTAssertTrue(text.contains("Picker(\"Piece\""),
                      "a card that cannot be given a piece cannot override the "
                      + "region it lives in, and §6.2's precedence has only one "
                      + "reachable half")
        XCTAssertTrue(text.contains("commitPiece("),
                      "the Picker must commit through this pane's own guard rather "
                      + "than writing the scene from a binding setter")
        XCTAssertTrue(text.contains("mutateFromInspector("),
                      "tripwire 32: nested inside an open \"Edit Scrap\" gesture the "
                      + "edit registers no undo step and rides into the writer's "
                      + "next sentence")
        XCTAssertTrue(text.contains("association(for:"),
                      "an inherited association shown as its own is a precedence "
                      + "the writer cannot see")
        // The companion: prove the scan reports an absent token rather than
        // always answering true. The plant names a spelling that cannot exist in
        // production — a *plausible* plant makes this self-check go red under the
        // very mutation it is written to survive.
        XCTAssertFalse(text.contains("Picker(\"NotARealSection\""),
                       "the scan reads the file rather than always answering true")
    }
}
