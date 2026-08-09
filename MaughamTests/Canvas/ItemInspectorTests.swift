import XCTest
import MaughamCore
@testable import Maugham

/// The FOURTH arm of the canvas inspector (1C-d Task 7): a selected item node.
///
/// Until this slice a selected page card drew the selected stroke and the connect
/// dot while the pane said *"Select something on the canvas."* — recorded in
/// ADR 0026 §10 as a decision rather than a bug, because every sentence in the
/// card arm is wrong for a reference. This is the arm that closes it.
///
/// Which SwiftUI arm renders cannot be asserted (`_ConditionalContent` is
/// branch-invariant) and a `Form`'s contents are not inspectable, so the two
/// decisions the view makes — what it can offer, and whose hand put the card
/// there — are values, pinned here. The routing itself is pinned the way its
/// neighbours are: a caller census plus each resolver's behaviour.
@MainActor
final class ItemInspectorTests: XCTestCase {

    private let page = CanvasNodeID.item("res-note")
    private let photo = CanvasNodeID("photo")
    private let scrap = CanvasNodeID("a")
    private let r1 = CanvasRegionID("r1")

    /// `CanvasModel.attach` wires `CanvasUndo`'s snapshot closures and reads the
    /// sidecar over whatever is there, so it runs before the scene is built —
    /// `ScrapInspectorTests`' own note.
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("item-inspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - The manifest these tests read

    /// One note and one photograph, built the way production builds them.
    private func index() -> CanvasItemIndex {
        CanvasItemIndex.over(research: [
            ResearchItem(id: "res-note", title: "The falls at night", type: .asset,
                         kind: .document, path: "research/the-falls-at-night.md"),
            ResearchItem(id: "res-photo", title: "The gorge from above", type: .asset,
                         kind: .image, path: "research/research_assets/gorge.jpg")])
    }

    private let ownedPath = "canvas_assets/image-20260730-220430.png"

    // MARK: - What the arm can offer (spec §8A.1)

    /// The headline: a referenced item that is still in the project offers
    /// **Open in Research**, carrying the id the pane's `onOpenResearchItem`
    /// takes — this arm is that closure's third caller.
    func test_aReferencedItemOffersOpenInResearchNamingTheItemItself() {
        XCTAssertEqual(ItemInspector.openAffordance(for: .project(id: "res-note"),
                                                    in: index()),
                       .open(itemID: "res-note"))
        // The control the other way round: the SAME reference against an index
        // that does not hold it offers nothing. Without this the assertion above
        // could be satisfied by an arm that offers Open unconditionally.
        XCTAssertNotEqual(ItemInspector.openAffordance(for: .project(id: "res-note"),
                                                       in: .empty),
                          .open(itemID: "res-note"))
    }

    /// **A dangling reference is not an error state.** The writer deleted the
    /// note; the card is still theirs and still says what it is
    /// (`CanvasItemFacts.missingTitle`). What changes is that there is nothing
    /// left to open.
    ///
    /// **It carries no id**, which is `PromotedArtifactSection.contributionArtifactMissing`'s
    /// precedent held to: an id is not something the writer can read.
    func test_aReferenceTheWriterDeletedOffersNothingAndPrintsNoID() throws {
        let deleted = "res-3f2a"
        let affordance = ItemInspector.openAffordance(for: .project(id: deleted),
                                                      in: index())
        guard case .explanation(let why) = affordance else {
            return XCTFail("a deleted reference has nothing to open, found: \(affordance)")
        }
        XCTAssertFalse(why.contains(deleted), "found: \(why)")
        // **Two controls, because the assertion above is a negative and this file
        // does not ship one without a positive beside it.** The first says the
        // sentence exists at all — an empty string contains nothing and passes
        // every `contains` check. The second says the CHECK discriminates: run it
        // against the sentence a naive implementation writes (the placeholder
        // label this whole line of work replaced, `Item · <id>`) and it fires.
        // Without it, `contains` could be blind and the test would not know.
        XCTAssertFalse(why.isEmpty)
        XCTAssertTrue("Item · \(deleted)".contains(deleted),
                      "control: the predicate finds an id when there is one to find")
    }

    /// **Open in Research is meaningless for an OWNED node** — the canvas
    /// ingested the picture and there is no research item behind it. It gets its
    /// own sentence rather than the deleted reference's: those are two different
    /// facts and one sentence would be wrong for one of them.
    ///
    /// **And it must stay true after a promotion** (Task 8): the sentence said
    /// "There's nothing in Research to open." while the promotion section three
    /// rows down offered an **Open** onto exactly that. It names the act instead,
    /// and the assertion below is what keeps the old claim from coming back.
    func test_anOwnedPictureSaysThereIsNothingInResearchToOpen() throws {
        let owned = ItemInspector.openAffordance(for: .owned(path: ownedPath),
                                                 in: index())
        guard case .explanation(let ownedWhy) = owned else {
            return XCTFail("an owned picture has no research item, found: \(owned)")
        }
        // It needs no manifest at all — the strongest statement of the same
        // fact, and `CanvasItemFacts.resolve`'s own test discipline.
        XCTAssertEqual(ItemInspector.openAffordance(for: .owned(path: ownedPath),
                                                    in: .empty),
                       owned)
        // **Never the path.** `CanvasItemReference.owned` carries a storage
        // location the writer never chose (`ImagePasteHandler.destination` mints
        // it from the clock), and a pane printing it answers a question about
        // content with the storage answer.
        XCTAssertFalse(ownedWhy.contains(ownedPath), "found: \(ownedWhy)")
        XCTAssertFalse(ownedWhy.contains("canvas_assets"), "found: \(ownedWhy)")
        // **And never a claim about what Research holds.** A promoted picture's
        // own section, three rows down, offers an Open onto the copy it made;
        // this row asserting there is nothing to open is two sentences on one
        // screen with one of them false. It is about the CARD.
        XCTAssertFalse(ownedWhy.lowercased().contains("nothing in research"),
                       "found: \(ownedWhy)")
        XCTAssertTrue(ownedWhy.contains("canvas"),
                      "the control: it still says where the picture lives — "
                      + "found: \(ownedWhy)")

        guard case .explanation(let missingWhy) = ItemInspector
            .openAffordance(for: .project(id: "res-3f2a"), in: index()) else {
            return XCTFail("precondition: a deleted reference explains itself too")
        }
        XCTAssertNotEqual(ownedWhy, missingWhy,
                          "a picture the canvas owns and a note the writer deleted "
                          + "are different facts; one sentence is wrong for one of them")
    }

    /// **The missing state is asked of the INDEX, never read back out of the
    /// title.** Task 4 flagged this in `CanvasItemFacts`' own doc comment: three
    /// facts and no fourth, and *"a caller that needs to act differently on a
    /// deleted reference — to withhold an Open in Research button, say — asks
    /// `CanvasItemIndex`, which is the thing that knows"*.
    ///
    /// A `title == missingTitle` comparison would tie a control to a sentence
    /// somebody may reword, and would withhold the button from a real note the
    /// writer happened to title "No longer in the project."
    func test_theArmNeverReadsTheDeletedStateBackOutOfTheTitle() throws {
        let source = try CanvasSourceCensus.commentsStripped(
            CanvasSourceCensus.source(at: "Maugham/Canvas/ItemInspector.swift"))
        XCTAssertFalse(source.contains("missingTitle"),
                       "the arm must ask `CanvasItemIndex` whether the reference "
                       + "resolves, not compare the resolved title against a "
                       + "sentence — see `CanvasItemFacts`' doc comment")
        // The control, in the same read: a required token proves the scan reads
        // the file rather than always answering false. A census over a FORBIDDEN
        // token is exactly the shape that passes while blind.
        XCTAssertTrue(source.contains("CanvasItemFacts.resolve("),
                      "the arm names the card through the one resolver the canvas "
                      + "draws from — a title of its own would drift from the card")
    }

    /// The one honest use of the deleted title: a real research note whose title
    /// happens to *be* that sentence still opens. This is what the comparison
    /// above would break, and it is why the flag was refused rather than added.
    func test_aNoteTitledLikeTheDeletedSentenceStillOpens() {
        let index = CanvasItemIndex.over(research: [
            ResearchItem(id: "res-odd", title: CanvasItemFacts.missingTitle,
                         type: .asset, kind: .document, path: "research/odd.md")])
        XCTAssertEqual(ItemInspector.openAffordance(for: .project(id: "res-odd"),
                                                    in: index),
                       .open(itemID: "res-odd"),
                       "the item is in the project; what it is called is not the "
                       + "question the button asks")
    }

    // MARK: - Whose hand put the card there (spec §8A.2)

    /// A page `CanvasClaudePlacement` created carries `author == .claude` and is
    /// drawn at exactly 0°, and `CanvasAccessibility` says so aloud. The pane is
    /// where it is inspectable — CLAUDE.md rule 8, and the omission
    /// `CanvasAuthorLine`'s own doc comment records twice.
    func test_aPageClaudePlacedSaysSoInItsPane() {
        let m = claudePageModel()
        XCTAssertEqual(CanvasAuthorLine.forItem(page, in: m.scene), .claude)
        let sentence = CanvasAuthorLine.forItem(page, in: m.scene).sentence ?? ""
        XCTAssertTrue(sentence.lowercased()
            .contains(CanvasAccessibility.claudeTerm.lowercased()),
                      "one wording for one fact — found: \(sentence)")
    }

    /// The writer's own item nodes say nothing at all: a line reading "placed by
    /// you" is chrome stating the default, on every card they ever dropped.
    func test_theWritersOwnItemNodesSayNothingNew() {
        let m = claudePageModel(author: nil)
        XCTAssertEqual(CanvasAuthorLine.forItem(page, in: m.scene), .writer)
        XCTAssertNil(CanvasAuthorLine.writer.sentence)
        // The control: the same scene with the author restored does speak.
        XCTAssertNotNil(CanvasAuthorLine.forItem(page, in: claudePageModel().scene)
            .sentence)
    }

    /// **A page must not say it was read off itself, which is why this arm has a
    /// resolver of its own rather than borrowing `forCard`.**
    ///
    /// `CanvasAuthorLine.read(from:)` finds the source by asking which of the
    /// home region's members is an item node — and for the page card that member
    /// *is* the page. Routed through `forCard`, the source page's own pane would
    /// read *From Claude. Read from "The falls at night".* over the card that IS
    /// "The falls at night". The `forCard` assertion below is the control: it
    /// demonstrates the difference is load-bearing rather than decorative, and
    /// it goes red the moment `forItem` is quietly forwarded to it.
    func test_aSourcePageDoesNotSayItWasReadFromItself() {
        let m = claudePageModel()
        let title: (String) -> String? = { ["res-note": "The falls at night"][$0] }

        XCTAssertEqual(CanvasAuthorLine.forItem(page, in: m.scene), .claude,
                       "the page IS the source; there is no second page to name")
        XCTAssertEqual(CanvasAuthorLine.forCard(page, in: m.scene, title: title),
                       .claudeReadFrom(title: "The falls at night"),
                       "the control: the card resolver really would name the page "
                       + "itself, which is what this arm must not do")
        // And the scraps read off it are unaffected — the card arm's sentence is
        // the recovery path back to the page and must keep working.
        XCTAssertEqual(CanvasAuthorLine.forCard(scrap, in: m.scene, title: title),
                       .claudeReadFrom(title: "The falls at night"))
    }

    /// A selection naming a node the scene no longer holds — an undo, or a
    /// deletion — claims nothing rather than asserting the default.
    func test_anItemTheSceneNoLongerHoldsClaimsNothing() {
        let m = claudePageModel()
        m.withScene { $0.remove(self.page) }
        XCTAssertEqual(CanvasAuthorLine.forItem(page, in: m.scene), .writer)
    }

    // MARK: - The routing (the caller census, and each resolver's behaviour)

    /// **The pane routes an item node to this arm**, and this is the instrument
    /// that pins it — the shape `test_thePaneRoutesOnlyAScrapToTheCardArm` uses,
    /// because which `_ConditionalContent` arm renders cannot be asserted but a
    /// call site's PRESENCE can, and a deletion is what would remove it.
    ///
    /// **This is also the production-caller count.** Four halves have shipped in
    /// this directory built, tested and unreachable, and every one was found by
    /// `grep`, never by a test — so the answer is written down rather than left
    /// as a habit.
    func test_theItemArmHasAProductionCaller() throws {
        let source = try CanvasSourceCensus.commentsStripped(
            CanvasSourceCensus.source(at: "Maugham/Canvas/RegionInspector.swift"))
        XCTAssertTrue(source.contains("ItemInspector("),
                      "`RegionInspectorPane` is the arm's one production caller — "
                      + "without this line an item node falls back to the empty "
                      + "state with every test in this file still green")
        XCTAssertTrue(source.contains("case .item(let reference)"),
                      "the pane destructures the reference, which is what "
                      + "`CanvasItemReference`'s doc comment asks of the sites "
                      + "that genuinely differ between the two provenances")
        // The companion: prove the scan reports an absence rather than always
        // answering true. The plant names a spelling that cannot exist in
        // production.
        XCTAssertFalse(source.contains("NotARealInspector("),
                       "the scan reads the file rather than always answering true")
    }

    /// **The controls the new arm must not have cost.** The card arm and the
    /// empty state are still there, and the pane still routes by KIND — the
    /// `.scrap` ruling this task implements rather than overturns.
    func test_theCardArmAndTheEmptyStateSurvive() throws {
        let source = try CanvasSourceCensus.commentsStripped(
            CanvasSourceCensus.source(at: "Maugham/Canvas/RegionInspector.swift"))
        XCTAssertTrue(source.contains("ScrapInspector("),
                      "a selected scrap still gets the card arm")
        XCTAssertTrue(source.contains("ContentUnavailableView("),
                      "a selection of nothing still gets the empty state")
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"),
                      "tripwire 15: the empty state needs the full-frame chain or "
                      + "the segment picker floats to the middle of the window")
    }

    /// The behaviour half of the same claim, which the source scan cannot see:
    /// the three resolvers the pane switches on answer for the states that decide
    /// which arm is on screen.
    func test_eachResolverAnswersForTheArmItSelects() {
        let m = claudePageModel()

        m.selection = nil
        XCTAssertNil(m.selectedNode, "nothing selected — the empty state")
        XCTAssertNil(m.selectedRegion)
        XCTAssertNil(m.selectedLine)

        m.selection = .node(scrap)
        guard case .scrap = m.selectedNode?.kind else {
            return XCTFail("a selected scrap resolves to the card arm's kind")
        }

        m.selection = .node(page)
        guard case .item(let reference) = m.selectedNode?.kind else {
            return XCTFail("a selected page resolves to this arm's kind")
        }
        XCTAssertEqual(reference, .project(id: "res-note"),
                       "and it carries the reference the arm is handed")
    }

    /// **One noun for one primitive, across the two surfaces that name it.** The
    /// pane's heading is `CanvasAccessibility.itemKind` rather than a word of its
    /// own, so a writer who hears "Reference, from Claude" and then reads the pane
    /// does not meet two names for the card in front of them. Asserted against the
    /// SPOKEN label rather than against the constant — `header == itemKind` is
    /// true by assignment and would survive the AX arm going back to a literal.
    func test_theArmIsHeadedWithTheWordVoiceOverSays() throws {
        let m = claudePageModel()
        let spoken = try XCTUnwrap(
            CanvasAccessibility.elements(scene: m.scene, scraps: [:])
                .first { $0.id == .node(page) }?.label)
        XCTAssertTrue(spoken.hasPrefix(ItemInspector.header),
                      "the pane says “\(ItemInspector.header)” and the label says "
                      + "“\(spoken)”")
        // Control: the heading is not the empty string, which would prefix
        // anything at all.
        XCTAssertFalse(ItemInspector.header.isEmpty)
    }

    // MARK: - What this arm deliberately does not have

    /// **No Delete button and no mutation of any kind — and that survives the
    /// Promote button Task 8 added.**
    ///
    /// ⌫ remains the only route to deleting a node (`ScrapInspector`'s standing
    /// note, ADR 0026's consequence). This arm writes nothing to the scene, which
    /// is why tripwire 32's verb is absent rather than misapplied: with no
    /// mutation there is no bracket to close, and `mutateFromInspector` appearing
    /// here later means a control arrived that this test never saw.
    ///
    /// **Promote… is not a counter-example to that**, which is the distinction
    /// worth stating: the button POSTS `.maughamPromoteCanvasSelection` and
    /// writes nothing, and the scene change belongs to `PromotionPerformer` —
    /// which is why the tripwire-32 census names that file and not this one. The
    /// token is now REQUIRED here (see `test_theOwnedArmOffersThePromoteCommand`
    /// and `PromotionCommandTests`' wiring census), so its absence would be the
    /// bug rather than the rule.
    func test_theArmMutatesNothing() throws {
        let source = try CanvasSourceCensus.commentsStripped(
            CanvasSourceCensus.source(at: "Maugham/Canvas/ItemInspector.swift"))
        for verb in ["mutateFromInspector", ".mutate(", "withScene", "beginGesture"] {
            XCTAssertFalse(source.contains(verb),
                           "this arm reads and never writes; a \(verb) here is a "
                           + "control that needs tripwire 32's ruling applied to "
                           + "it deliberately, not inherited from this file")
        }
        XCTAssertFalse(source.contains("role: .destructive"),
                       "⌫ is the only route to deleting a node; a Delete button "
                       + "for symmetry with the region and line arms is a design "
                       + "change wearing a tidy-up's clothes")
        // The control: a required token in the same read, so the absences above
        // are not a scan that reads nothing.
        XCTAssertTrue(source.contains("onOpenResearchItem("),
                      "the one act this arm offers a reference")
    }

    // MARK: - What an OWNED picture gets, and a reference does not (Task 8)

    /// **The button posts the ONE command** the File item and ⌘⇧↩ post, so a
    /// writer who clicks and a writer who presses the keystroke take the same
    /// path — and it lives in the project window rather than in a sheet, which
    /// is what makes a `.keyWindow` post arrive at all.
    func test_theOwnedArmOffersThePromoteCommand() throws {
        let source = try CanvasSourceCensus.commentsStripped(
            CanvasSourceCensus.source(at: "Maugham/Canvas/ItemInspector.swift"))
        XCTAssertTrue(source.contains("maughamPromoteCanvasSelection"),
                      "an owned picture must be promotable from its own pane")
        XCTAssertTrue(source.contains("PromotedArtifactSection("),
                      "and what it produced must be inspectable — a mark nothing "
                      + "renders is the built-and-unreachable half this directory "
                      + "has shipped four times")
    }

    /// **One rule, three spellings, asserted against each other.** The pane's
    /// gate, `Promotion.targets` and `CanvasPromotionModifier.isPromotable` all
    /// answer "may this be promoted", and the drift between them is a dead sheet
    /// in one direction and a greyed-out command in the other.
    func test_theArmsGateAgreesWithTheTargetsAndTheCommand() {
        let owned = CanvasItemReference.owned(path: "canvas_assets/p.png")
        let referenced = CanvasItemReference.project(id: "r-9")
        var scene = CanvasScene()
        let ownedID = CanvasNodeID("owned-1")
        let referencedID = CanvasNodeID.item("r-9")
        scene.insert(CanvasNode(id: ownedID, kind: .item(owned), origin: .zero,
                                width: 180, cachedHeight: 200))
        scene.insert(CanvasNode(id: referencedID, kind: .item(referenced),
                                origin: CGPoint(x: 400, y: 0), width: 180, cachedHeight: 120))
        let artifacts = ArtifactIndex(titlesByID: ["r-9": "A note"])

        for (id, reference) in [(ownedID, owned), (referencedID, referenced)] {
            let offered = !Promotion.targets(for: .scrap(id), in: scene,
                                             artifacts: artifacts).isEmpty
            XCTAssertEqual(ItemInspector.promotes(reference), offered,
                           "the pane and §6's table must agree — \(reference)")
            XCTAssertEqual(
                CanvasPromotionModifier.isPromotable(persona: .plan,
                                                     selection: .node(id),
                                                     nodeKind: .item(reference)),
                offered,
                "and so must the command's enablement — \(reference)")
        }
        XCTAssertTrue(ItemInspector.promotes(owned), "the control: one of the two "
                      + "is really true, or every equality above holds on false")
        XCTAssertFalse(ItemInspector.promotes(referenced))
    }

    // MARK: - What a REFERENCE gets once it has contributed (Task 12a)

    /// **A reference cannot be promoted and CAN have contributed** (spec §6.3's
    /// 2026-07-31 amendment). A region's palette promotion copies the pictures
    /// in it onto the card whatever their provenance, so a research image
    /// dragged onto the canvas really does end up inside that card — and with
    /// the section gated on `promotes` alone, its pane said nothing at all about
    /// it. That is §6.3's own reported defect ("some think they weren't") on the
    /// arm the ruling reached last.
    func test_aReferenceThatContributedGetsASectionAndOneWithoutGetsNone() {
        let contributed = PromotedArtifactSection.Provenance(
            artifact: .notPromoted,
            contributions: [.contributed(itemID: "res-card", title: "Colour: October")])
        XCTAssertEqual(ItemInspector.referencedContributions(contributed),
                       [.contributed(itemID: "res-card", title: "Colour: October")])
        XCTAssertEqual(
            ItemInspector.referencedContributions(
                .init(artifact: .notPromoted,
                      contributions: [.artifactMissing(itemID: "res-x")])),
            [.artifactMissing(itemID: "res-x")],
            "a dangling record still has something to say — the writer deleted "
            + "the card, and silence would be the same lie one state over")
        XCTAssertNil(
            ItemInspector.referencedContributions(
                .init(artifact: .notPromoted, contributions: [])),
            "and a reference with no record mounts NO section, rather than one "
            + "reading \"Not promoted yet.\" about a card that can never be promoted")
    }

    /// **The mark half is withheld and the "Not promoted yet." line with it.**
    /// A mark on a reference says nothing true — a hand-edited sidecar can put
    /// the field there, which is why the renderer and `CanvasAccessibility`
    /// refuse to draw or speak one — so the arm hands `.notPromoted`, and
    /// `saysNotPromotedYet` is false because a contribution record exists.
    func test_aContributingReferenceIsNeverToldItWasNotPromotedYet() {
        let state = PromotedArtifactSection.Provenance(
            artifact: .notPromoted,
            contributions: [.contributed(itemID: "res-card", title: "Colour: October")])
        XCTAssertFalse(state.saysNotPromotedYet)
        XCTAssertTrue(
            PromotedArtifactSection.Provenance(artifact: .notPromoted, contributions: [])
                .saysNotPromotedYet,
            "the control: that sentence is reachable, so the assertion above is "
            + "about the contribution suppressing it")
    }

    /// **The caption is the whole of why this is a subject of its own.** A
    /// reference has no Promote… button, so `.picture`'s caption — *"Promoting
    /// this picture onto that card again…"* — names an act this arm does not
    /// have, which is exactly the failure `pieceIsNotAResearchTarget`'s third
    /// axis was added to prevent, one pane over.
    func test_theReferencedPicturesCaptionNamesNoActItsArmDoesNotHave() {
        let referenced = PromotedArtifactSection.Subject.referencedPicture
        XCTAssertFalse(referenced.contributionCaption.contains("Promoting"),
                       "found: \(referenced.contributionCaption)")
        XCTAssertTrue(PromotedArtifactSection.Subject.picture.contributionCaption
                        .contains("Promoting"),
                      "the control, and the reason this is an axis rather than a "
                      + "rewording: an OWNED picture really can be promoted again "
                      + "and its caption still says so")
        XCTAssertEqual(referenced.wordsAreIn("Colour: October"),
                       PromotedArtifactSection.Subject.picture.wordsAreIn("Colour: October"),
                       "the sentence that is true of both is the same sentence — "
                       + "a picture is in that card either way")
    }

    // MARK: - Fixtures

    /// The shape `CanvasClaudePlacement.apply` produces: a labelled region
    /// holding the scraps Claude wrote and the page they were read off, all of
    /// it authored by Claude.
    private func claudePageModel(author: AnnotationAuthor.SourceKind? = .claude)
        -> CanvasModel {
        let m = CanvasModel()
        m.attach(projectRoot: root)
        m.withScene { s in
            s.insert(CanvasNode(id: self.scrap, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80, author: .claude))
            s.insert(CanvasNode(id: self.page, kind: .item(.project(id: "res-note")),
                                origin: CGPoint(x: 0, y: 200), width: 240,
                                cachedHeight: 120, author: author))
            s.insertRegion(CanvasRegion(
                id: self.r1, label: CanvasClaudePlacement.defaultRegionLabel,
                frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                homeMembers: [self.scrap, self.page], author: .claude))
        }
        return m
    }
}
