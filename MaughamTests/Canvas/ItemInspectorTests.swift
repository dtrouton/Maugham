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

    /// **No Delete button, no Promote button, and no mutation of any kind.**
    ///
    /// ⌫ remains the only route to deleting a node (`ScrapInspector`'s standing
    /// note, ADR 0026's consequence), and an item node cannot be promoted at all
    /// — `Promotion.itemNodeReason` is the sentence, and making an *owned* node
    /// promotable is Task 8's. This arm writes nothing to the scene, which is why
    /// tripwire 32's verb is absent rather than misapplied: with no mutation
    /// there is no bracket to close, and `mutateFromInspector` appearing here
    /// later means a control arrived that this test never saw.
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
        XCTAssertFalse(source.contains("maughamPromoteCanvasSelection"),
                       "an item node already exists as itself and cannot be "
                       + "promoted (Task 8 makes an OWNED one promotable)")
        // The control: a required token in the same read, so the four absences
        // above are not a scan that reads nothing.
        XCTAssertTrue(source.contains("onOpenResearchItem("),
                      "the one act this arm offers")
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
