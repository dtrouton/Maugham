import XCTest
import MaughamCore
@testable import Maugham

/// The third arm of the canvas inspector. Which SwiftUI arm renders cannot be
/// asserted (`_ConditionalContent` is branch-invariant), so the decision the
/// view makes is lifted into `artifactState`/`provenance` and pinned here — the
/// same shape `RegionInspector.citeAffordance` uses.
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

    // MARK: - What a card's words are IN (spec §6.3)

    /// The index the pane already has, standing in for the manifest: `res-fog`
    /// is a note that exists, `res-gone` is one the writer deleted.
    private let artifacts: (String) -> String? = { id in
        ["res-fog": "Act II fog", "res-a": "The falls at night"][id]
    }

    /// **The reported bug, as a value.** A card whose words a region's promotion
    /// folded into a note said *"Not promoted yet."* — while its text sat in
    /// that note. It carries no mark of its own and must not: `promotedItemID`
    /// is what `existingArtifact` reads to offer **Rewrite**, and a contributor
    /// offering to rewrite a six-card note with one card's text is the Critical
    /// §6.3 exists to prevent.
    func test_aContributingCardStopsSayingNotPromotedYet() {
        let p = PromotedArtifactSection.provenance(promotedItemID: nil,
                                                   contributedToItemID: "res-fog",
                                                   title: artifacts)
        XCTAssertEqual(p.artifact, .notPromoted, "it produced nothing itself")
        XCTAssertEqual(p.contribution, .contributed(itemID: "res-fog",
                                                    title: "Act II fog"))
        XCTAssertFalse(p.saysNotPromotedYet,
                       "the writer's report: \"some think they weren't [promoted]\" "
                       + "— the words are in a note and the pane must not deny it")
    }

    /// The control: no records at all, and the sentence is still the honest one.
    func test_aCardWithNeitherRecordStillSaysNotPromotedYet() {
        let p = PromotedArtifactSection.provenance(promotedItemID: nil,
                                                   contributedToItemID: nil,
                                                   title: artifacts)
        XCTAssertEqual(p.artifact, .notPromoted)
        XCTAssertEqual(p.contribution, PromotedArtifactSection.ContributionState.none)
        XCTAssertTrue(p.saysNotPromotedYet)
    }

    /// Own mark only — the state the pane has shown correctly since 1C-c2.
    func test_anOwnMarkAloneCarriesNoContribution() {
        let p = PromotedArtifactSection.provenance(promotedItemID: "res-a",
                                                   contributedToItemID: nil,
                                                   title: artifacts)
        XCTAssertEqual(p.artifact, .promoted(itemID: "res-a",
                                             title: "The falls at night"))
        XCTAssertEqual(p.contribution, PromotedArtifactSection.ContributionState.none)
        XCTAssertFalse(p.saysNotPromotedYet)
    }

    /// **Both, and they say different things** (§6.3): it produced its own note,
    /// *and* its words are in a region's. The pane shows both rather than
    /// choosing — so this value carries both rather than collapsing to one.
    func test_aCardMayCarryBothAndNeitherHidesTheOther() {
        let p = PromotedArtifactSection.provenance(promotedItemID: "res-a",
                                                   contributedToItemID: "res-fog",
                                                   title: artifacts)
        XCTAssertEqual(p.artifact, .promoted(itemID: "res-a",
                                             title: "The falls at night"))
        XCTAssertEqual(p.contribution, .contributed(itemID: "res-fog",
                                                    title: "Act II fog"))
        XCTAssertFalse(p.saysNotPromotedYet)
    }

    /// **A contribution can dangle, and nothing rebuilds it.** The record
    /// persists through the codec and is never recomputed on load, so a card
    /// really can name a note the writer has since deleted. Same treatment
    /// `promotedItemID` already gets: say so, rather than showing a raw id.
    func test_aContributionWhoseArtifactIsGoneSaysSoRatherThanShowingAnId() {
        let p = PromotedArtifactSection.provenance(promotedItemID: nil,
                                                   contributedToItemID: "res-gone",
                                                   title: artifacts)
        XCTAssertEqual(p.contribution, .artifactMissing(itemID: "res-gone"))
        XCTAssertFalse(p.saysNotPromotedYet,
                       "something did go somewhere; \"not promoted yet\" is the "
                       + "one sentence that is false here")
        XCTAssertFalse(PromotedArtifactSection.contributionArtifactMissing
            .contains("res-gone"),
                       "an id is not a sentence the writer can read")
    }

    /// **The line must be visibly different from "Became …".** They are two
    /// different facts — one produced an artifact, the other's text went into
    /// somebody else's — and one sentence for both is the pane telling the
    /// writer they can rewrite a joint note.
    func test_theContributionLineDoesNotReadLikeTheOwnMarksLine() {
        let contributed = PromotedArtifactSection.wordsAreIn("Act II fog")
        let became = PromotedArtifactSection.Subject.card.became("Act II fog")
        XCTAssertNotEqual(contributed, became)
        XCTAssertFalse(contributed.contains("Became"),
                       "found: \(contributed)")
        XCTAssertTrue(contributed.contains("Act II fog"),
                      "it still names the artifact — found: \(contributed)")
    }

    /// The caption is where the writer learns what Promote… will do to a card
    /// that only contributed: a **new** artifact, never a rewrite. That is the
    /// one smoke step that matters, and the pane is where it is discoverable.
    func test_theContributionCaptionSaysAPromotionFromHereMakesSomethingNew() {
        let caption = PromotedArtifactSection.contributionCaption
        XCTAssertTrue(caption.lowercased().contains("new"), "found: \(caption)")
        XCTAssertFalse(caption.lowercased().contains("rewrite that one"),
                       "found: \(caption)")
    }

    /// **The census.** Which arm renders cannot be asserted, so what is pinned is
    /// that the card arm reads the record at all — and that the region arm names
    /// the absence rather than being handed one by a default. A region has no
    /// such field: §6.3 records a contribution on the CARDS whose text went in.
    func test_theCardArmReadsTheRecordAndTheRegionArmNamesItsAbsence() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let card = try String(
            contentsOf: root.appendingPathComponent("Maugham/Canvas/ScrapInspector.swift"),
            encoding: .utf8)
        XCTAssertTrue(card.contains("contributedToItemID"),
                      "the card arm must read the contribution record, or the "
                      + "reported bug is unfixed with a green suite")
        let region = try String(
            contentsOf: root.appendingPathComponent("Maugham/Canvas/RegionInspector.swift"),
            encoding: .utf8)
        XCTAssertTrue(region.contains("contribution: .none"),
                      "the region arm names the absence rather than taking a "
                      + "default — a default is how the card arm would lose its "
                      + "half with nothing red")
        // The companion: prove the scan reports an absent token rather than
        // always answering true.
        XCTAssertFalse(card.contains("contributedToNotARealField"),
                       "the scan reads the file rather than always answering true")
    }

    // MARK: - Both arms, one section

    /// **Neither arm names a kind, and the region arm's did until 1C-c2a.** Its
    /// sentence read "Became the palette card “…”" on the stated grounds that a
    /// region's mark could only ever be one — and the task that put
    /// `.researchNote` on the region's row did not touch this file, so nothing
    /// recompiled, nothing failed, and a region promoted to a research note was
    /// told it had become a palette card over an **Open** button that opened a
    /// note. This assertion was green throughout, with the removed piece-binding
    /// concept as its rationale.
    func test_neitherArmNamesAKindItCannotKnow() {
        XCTAssertEqual(PromotedArtifactSection.Subject.region.became("Act II fog"),
                       "Became “Act II fog”",
                       "a region's mark may name a research note or a palette "
                       + "card (spec §6, 2026-07-29), and this arm is not told "
                       + "which")
        XCTAssertEqual(PromotedArtifactSection.Subject.card.became("Act II fog"),
                       "Became “Act II fog”",
                       "a card's may name either of those or the craft intent, "
                       + "and this arm is not told which either")
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
                       artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                       onOpenResearchItem: { _ in })
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

    /// The BINDER — the whole structure, which is a wider set than the offer.
    /// `ref-1` is a Collection reference piece: in the writer's binder, in front
    /// of them, and refused by `researchRouting`, so `pieceChoices` filters it
    /// out while `manifest.structure` still names it. `gone-9` is in neither.
    private let binder: (String) -> String? = { id in
        id == "ref-1" ? "Elsewhere" : nil
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
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder),
                       .inherited(title: "Chapter Three"))
        XCTAssertEqual(
            ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder).label,
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
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder),
                       .own(title: "Chapter Three"))
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder).label,
                       "Chapter Three")
    }

    func test_noAssociationSaysTheProjectsResearchRatherThanNothing() {
        let m = model()
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder), .none)
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder).label,
                       "The project's research")
    }

    /// The association whose piece is GONE from the project: nothing in the
    /// binder answers to the id. Shown rather than dropped — a `Picker` with no
    /// row matching its selection renders blank, which reads as "not bound" and
    /// invites the writer to fix a problem they cannot see.
    func test_anAssociationWhosePieceIsGoneSaysSoWithTheIdItHasLeft() {
        let m = model()
        inspector(m).commitPiece("gone-9")
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder),
                       .gone(id: "gone-9", inherited: false))
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder).label,
                       "Missing piece · gone-9",
                       "the card's OWN stale piece: the Picker beside this shows it "
                       + "too, and clearing it is one click away")
    }

    /// **The piece in the writer's binder that the pane called missing.** Task 4
    /// narrowed the offer to `researchScopeTargets()`, correctly — and the label
    /// went on resolving its title out of that same narrowed list, so a
    /// Collection reference piece rendered as "Missing piece · ref-1" while
    /// `PromotionPiece.resolve` found it in `manifest.structure` and refused with
    /// *"Elsewhere" cannot keep research of its own*. Two surfaces, one state,
    /// two stories — and the pane's sent the writer hunting for something sitting
    /// in their binder.
    func test_aPieceThatKeepsNoResearchIsNotCalledMissing() {
        let m = model()
        inspector(m).commitPiece("ref-1")
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder),
                       .keepsNoResearch(title: "Elsewhere", inherited: false))
        let label = ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                               pieceTitle: binder).label
        XCTAssertEqual(label, "Elsewhere · keeps no research of its own")
        XCTAssertFalse(label.contains("Missing"),
                       "it is in the binder in front of them — found: \(label)")
        // The same words the refusal reaches for, so the pane and the sheet tell
        // one story.
        let refusal = PromotionFailure
            .pieceIsNotAResearchTarget(title: "Elsewhere", inherited: false)
            .errorDescription ?? ""
        XCTAssertTrue(refusal.contains("keep research of its own"),
                      "found: \(refusal)")
    }

    /// **The stale association the writer cannot clear**, and the case that
    /// dropping the inheritance made unreachable: the card lives in a region
    /// whose piece was deleted. Its own Picker reads None — correctly, it
    /// carries nothing — so a label saying only "Missing piece · gone-9" leaves
    /// the writer with nothing to clear and no idea where the value lives. The
    /// qualifier is what sends them to the region.
    func test_aStaleAssociationInheritedFromARegionSaysWhereItCameFrom() {
        let m = modelInRegion()
        m.withScene { $0.updateRegion(self.r1) { $0.boundPieceID = "gone-9" } }
        XCTAssertNil(m.scene.node(a)?.boundPieceID,
                     "there is nothing on the card for the writer to clear")
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder),
                       .gone(id: "gone-9", inherited: true))
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder).label,
                       "Missing piece · gone-9 (from its region)")
    }

    /// The qualifier reaches the other unoffered case too — a card inheriting a
    /// reference piece from its region has nothing of its own to change, which
    /// is precisely what the refusal's `inherited` half says.
    func test_anInheritedPieceThatKeepsNoResearchAlsoSaysWhereItCameFrom() {
        let m = modelInRegion()
        m.withScene { $0.updateRegion(self.r1) { $0.boundPieceID = "ref-1" } }
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder).label,
                       "Elsewhere · keeps no research of its own (from its region)")
    }

    /// **Both pickers' orphan row is the same value**, so the card arm and the
    /// region arm cannot describe one state two ways. The region arm's property
    /// was called `boundPieceMissingFromTheManuscript`, which after Task 4 was
    /// literally false for `ref-1`.
    func test_bothPickersSpellTheUnofferedRowTheSameWay() {
        XCTAssertEqual(ScrapInspector.unoffered("ref-1", pieceTitle: binder,
                                                inherited: false).label,
                       "Elsewhere · keeps no research of its own")
        XCTAssertEqual(ScrapInspector.unoffered("gone-9", pieceTitle: binder,
                                                inherited: false).label,
                       "Missing piece · gone-9")
    }

    /// The card's OWN association wins even when the region's is stale, so the
    /// qualifier cannot start appearing wherever a region happens to be bound.
    func test_anOwnAssociationIsNotQualifiedJustBecauseItsRegionHasOne() {
        let m = modelInRegion()
        m.withScene { $0.updateRegion(self.r1) { $0.boundPieceID = "gone-9" } }
        inspector(m).commitPiece("ch-3")
        XCTAssertEqual(ScrapInspector.association(for: a, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder).label,
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
        XCTAssertEqual(ScrapInspector.association(for: visitor, in: m.scene, pieces: pieces,
                                                  pieceTitle: binder),
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

    // MARK: - Where the card came from (spec §8A.2)

    /// A card in a Claude region, with the page the words were read off in the
    /// region beside it — the shape `CanvasClaudePlacement.plan` produces for a
    /// call carrying `source_item_id`.
    private func claudeModel(source: String? = nil,
                             author: AnnotationAuthor.SourceKind? = .claude) -> CanvasModel {
        let m = CanvasModel()
        m.attach(projectRoot: root)
        m.withScene { s in
            s.insert(CanvasNode(id: self.a, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80, author: author))
            s.insertRegion(CanvasRegion(
                id: self.r1, label: CanvasClaudePlacement.defaultRegionLabel,
                frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                homeMembers: [self.a], author: .claude))
            if let source {
                let page = CanvasNodeID.item(source)
                s.insert(CanvasNode(id: page, kind: .item(referenceId: source),
                                    origin: CGPoint(x: 0, y: 200), width: 240,
                                    cachedHeight: 40, author: .claude))
                CanvasMembership.join(page, home: self.r1, in: &s)
            }
        }
        m.setScrapText("The falls at night", for: a)
        return m
    }

    /// **CLAUDE.md rule 8, on `CanvasNode.author`.** The tint and the tilt say
    /// *this is not yours* to a writer who is looking at the canvas; the pane is
    /// where the fact is inspectable, and a card's pane said nothing about it.
    func test_aClaudeCardSaysSoInItsInspector() {
        let m = claudeModel()
        let origin = ScrapInspector.origin(for: a, in: m.scene, title: artifacts)
        XCTAssertEqual(origin, .claude)
        let sentence = origin.sentence ?? ""
        XCTAssertFalse(sentence.isEmpty,
                       "a card the writer did not write must say so in its own pane")
        // **One wording for one fact.** The spoken term is `claudeTerm`, the
        // region a batch lands in is `defaultRegionLabel`, and the undo step is
        // `undoStepName`. A fifth phrasing here would make one thing sound like
        // several.
        XCTAssertTrue(sentence.lowercased()
            .contains(CanvasAccessibility.claudeTerm.lowercased()),
                      "found: \(sentence), which does not contain "
                      + "\"\(CanvasAccessibility.claudeTerm)\"")
    }

    /// The source page, named — resolved through the **deferred** `artifactTitle`
    /// closure the pane already holds, which is the same lookup the promoted mark
    /// and the contribution record use. A `store` is never read from a `body` or
    /// from anything a `body` calls.
    func test_aCardWhoseSourceIsKnownNamesIt() {
        let m = claudeModel(source: "res-fog")
        let origin = ScrapInspector.origin(for: a, in: m.scene, title: artifacts)
        XCTAssertEqual(origin, .claudeReadFrom(title: "Act II fog"))
        XCTAssertEqual(origin.sentence,
                       "From Claude. Read from “Act II fog”.")
    }

    /// The page the writer has since deleted. It falls back to the plain sentence
    /// rather than printing `res-gone` — the treatment both promotion records
    /// already get, for the reason `contributionArtifactMissing` records: an id is
    /// not something the writer can read.
    func test_aSourcePageTheWriterHasDeletedIsNotNamedByItsId() {
        let m = claudeModel(source: "res-gone")
        let origin = ScrapInspector.origin(for: a, in: m.scene, title: artifacts)
        XCTAssertEqual(origin, .claude)
        XCTAssertFalse((origin.sentence ?? "").contains("res-gone"),
                       "found: \(origin.sentence ?? "nil")")
    }

    /// **Nothing new for the writer's own cards.** `nil` author means the writer
    /// (`CanvasNode.author`), so this guards against a line reading "Added by
    /// you" — chrome stating the default, on every card on every canvas made
    /// before this slice.
    func test_theWritersOwnCardsSayNothingNew() {
        let mine = claudeModel(source: "res-fog", author: nil)
        XCTAssertEqual(ScrapInspector.origin(for: a, in: mine.scene, title: artifacts),
                       .writer,
                       "a nil author is the writer, and the source page sitting in "
                       + "the same region must not make their own card claim to have "
                       + "been read off it")
        XCTAssertNil(ScrapInspector.Origin.writer.sentence,
                     "the writer's own card has no provenance line at all")
        // The control, so this is about the AUTHOR and not about the fixture: the
        // same scene with the author restored does say something.
        let theirs = claudeModel(source: "res-fog")
        XCTAssertNotNil(ScrapInspector.origin(for: a, in: theirs.scene,
                                              title: artifacts).sentence)
    }

    /// **Two pages in the region and the line names neither.** A call carries at
    /// most one `source_item_id`, so this is not a state the planner produces — it
    /// is the state a writer produces by dragging another research item into
    /// Claude's region afterwards, and there is then no fact here to state. Naming
    /// whichever one sorted first would be a caption asserting something nothing in
    /// the model knows, so the misattribution is removed rather than documented.
    func test_twoPagesInTheRegionMeanTheSourceIsNotNamed() {
        let m = claudeModel(source: "res-fog")
        m.withScene { s in
            let second = CanvasNodeID.item("res-a")
            s.insert(CanvasNode(id: second, kind: .item(referenceId: "res-a"),
                                origin: CGPoint(x: 300, y: 200), width: 240,
                                cachedHeight: 40))
            CanvasMembership.join(second, home: self.r1, in: &s)
        }
        // The control is the fixture one test up: the SAME model with one page
        // names it, so this is about the count and not about the scene.
        XCTAssertEqual(ScrapInspector.origin(for: a, in: claudeModel(source: "res-fog").scene,
                                             title: artifacts),
                       .claudeReadFrom(title: "Act II fog"))
        XCTAssertEqual(ScrapInspector.origin(for: a, in: m.scene, title: artifacts),
                       .claude,
                       "with two pages in the region there is no source to name")
    }

    /// A card with no region at all — Claude always lands in one, but an undo, a
    /// hand-edited sidecar or a later drag can leave one loose. It still says
    /// whose it is; only the source half goes.
    func test_aClaudeCardOutsideAnyRegionStillSaysWhoseItIs() {
        let m = CanvasModel()
        m.withScene { s in
            s.insert(CanvasNode(id: self.a, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80, author: .claude))
        }
        XCTAssertEqual(ScrapInspector.origin(for: a, in: m.scene, title: artifacts),
                       .claude)
    }

    /// **Three facts, three sentences.** A card can be Claude's, *and* have
    /// produced an artifact, *and* have had its words folded into a region's — and
    /// §6.3's rule is that one sentence for two records is the pane inviting the
    /// rewrite it forbids. The provenance line is a THIRD fact, so it must read
    /// like neither of the other two, and specifically must not read as a
    /// promotion: re-promoting a Claude card is as available as re-promoting the
    /// writer's own.
    func test_theProvenanceLineIsNotTheMarkOrTheContribution() {
        let m = claudeModel(source: "res-fog")
        m.withScene { s in
            s.setPromotedItem("res-a", for: self.a)
            s.setContributedItem("res-fog", for: self.a)
        }
        let provenance = PromotedArtifactSection.provenance(
            promotedItemID: m.scene.node(a)?.promotedItemID,
            contributedToItemID: m.scene.node(a)?.contributedToItemID,
            title: artifacts)
        let origin = ScrapInspector.origin(for: a, in: m.scene, title: artifacts)

        // All three are present at once, and none of them is the other two.
        let sentences = [origin.sentence,
                         PromotedArtifactSection.Subject.card.became("The falls at night"),
                         PromotedArtifactSection.wordsAreIn("Act II fog")]
            .compactMap { $0 }
        XCTAssertEqual(sentences.count, 3,
                       "all three facts must have a sentence, or the loop below "
                       + "passes by having nothing to compare")
        XCTAssertEqual(Set(sentences).count, 3, "found: \(sentences)")
        XCTAssertEqual(provenance.artifact,
                       .promoted(itemID: "res-a", title: "The falls at night"))
        XCTAssertEqual(provenance.contribution,
                       .contributed(itemID: "res-fog", title: "Act II fog"))

        // And the provenance line does not borrow either record's words. Both are
        // checked, because "Became" and "words are in" are the two phrasings a
        // fourth sentence would drift into.
        let line = origin.sentence ?? ""
        XCTAssertFalse(line.contains("Became"), "found: \(line)")
        XCTAssertFalse(line.lowercased().contains("words are in"), "found: \(line)")
        XCTAssertFalse(line.lowercased().contains("promot"),
                       "a provenance line that reads as a promotion is a card "
                       + "telling the writer it has already been promoted — found: "
                       + "\(line)")
    }
}
