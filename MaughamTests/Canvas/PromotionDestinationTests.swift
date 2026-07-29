import XCTest
import MaughamCore
@testable import Maugham

/// Spec §6.2's other half: **the writer is told where a promotion will land, and
/// is only ever offered a piece it can land in.**
///
/// Task 3 made the association decide the destination. Nothing said so: the two
/// pickers offered every `.document` — including the Collection reference pieces
/// `researchRouting` throws on — and "Goes to" read `research/` whichever piece
/// the card carried. So a writer could choose a piece that made the promotion
/// fail, and could not tell a note bound for a piece's own folder from one bound
/// for shared `research/` with a link.
///
/// **The copy is asserted as a value, never as a rendered view.** A `Form`'s
/// contents are not inspectable and `_ConditionalContent` is branch-invariant,
/// so every sentence here is produced by a pure function the sheet reads —
/// `RegionInspector.citeAffordance`'s discipline.
@MainActor
final class PromotionDestinationTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let r1 = CanvasRegionID("r1")

    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }
    override func tearDown() async throws { temp = nil }

    // MARK: - Fixtures

    /// A Collection with one LOOSE piece and one REFERENCE piece — the shape
    /// that motivates the picker change, since only the reference piece is
    /// refused by the router.
    private func makeCollectionManifest() async throws -> ProjectStore {
        let tmp = temp.url.appendingPathComponent("PD-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("pieces/01-story-a"),
            withIntermediateDirectories: true)
        try "Story A\n".write(to: tmp.appendingPathComponent("pieces/01-story-a/story-a.md"),
                              atomically: true, encoding: .utf8)
        let loose = StructureItem(id: "loose-1", title: "Story A", type: .document,
                                  path: "pieces/01-story-a/story-a.md", pieceKind: .loose)
        let reference = StructureItem(id: "ref-1", title: "Elsewhere", type: .document,
                                      path: nil, pieceKind: .reference)
        let group = StructureItem(id: "grp-1", title: "Part One", type: .group,
                                  path: nil, children: [loose, reference])
        let manifest = ProjectManifest(
            type: .collection, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [group], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        return try await ProjectStore.load(from: tmp)
    }

    private func makeModel() -> CanvasModel {
        let model = CanvasModel()
        model.withScene { s in
            s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80))
            s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                        homeMembers: [a]))
        }
        model.setScrapText("The falls at night\n\nSodium light.", for: a)
        return model
    }

    // MARK: - The picker offers only what can be routed

    /// **The whole point of part 2.** `ProjectStore.researchScopeTargets()` exists
    /// for this — its own doc comment says it "drives the promote-target picker" —
    /// and `pieceChoices` walked every `.document` instead, so the reference piece
    /// the router throws on was on offer.
    ///
    /// The loose piece is the control: this is about routability, not about the
    /// function having gone empty or having started filtering on something else.
    func test_thePickerOffersOnlyPiecesAPromotionCanBeRoutedTo() async throws {
        let store = try await makeCollectionManifest()
        let ids = ProjectWindow.pieceChoices(in: store).map(\.id)
        XCTAssertEqual(ids, ["loose-1"],
                       "a reference piece keeps research in its own project — "
                       + "`researchRouting` throws on it, so offering it invites the "
                       + "writer to choose a piece that makes the promotion fail")
        XCTAssertEqual(ProjectWindow.pieceChoices(in: store).first?.title, "Story A",
                       "and it is still the title the writer reads, not the id")
    }

    /// The group is the second thing the old spelling could not exclude: a
    /// `TreeWalk` for `.document` already skipped it, but the filter that replaces
    /// it must not start letting one through.
    func test_theOfferNeverIncludesAGroup() async throws {
        let store = try await makeCollectionManifest()
        XCTAssertFalse(ProjectWindow.pieceChoices(in: store).contains { $0.id == "grp-1" })
    }

    // MARK: - Resolving an association against the live manifest

    func test_aLoosePieceResolvesToItsOwnResearch() async throws {
        let store = try await makeCollectionManifest()
        let model = makeModel()
        model.withScene { $0.setBoundPiece("loose-1", for: self.a) }
        XCTAssertEqual(
            PromotionPiece.resolve(for: .scrap(a), in: model.scene, store: store),
            .routed(id: "loose-1", title: "Story A", route: .ownResearch))
    }

    /// A reference piece is exactly the stale case the picker can no longer
    /// create and an existing association can still reach — the writer converted
    /// the piece after binding the card.
    func test_aReferencePieceResolvesAsUnroutableAndKeepsItsTitle() async throws {
        let store = try await makeCollectionManifest()
        let model = makeModel()
        model.withScene { $0.setBoundPiece("ref-1", for: self.a) }
        XCTAssertEqual(
            PromotionPiece.resolve(for: .scrap(a), in: model.scene, store: store),
            .unroutable(id: "ref-1", title: "Elsewhere"),
            "the title is what makes the refusal a sentence about the writer's "
            + "situation rather than about an id")
    }

    /// The other stale shape: the piece was deleted. No title to name, and the
    /// sentence has to be different because the act that fixes it is different.
    func test_aDeletedPieceResolvesAsUnroutableWithNoTitle() async throws {
        let store = try await makeCollectionManifest()
        let model = makeModel()
        model.withScene { $0.setBoundPiece("gone-9", for: self.a) }
        XCTAssertEqual(
            PromotionPiece.resolve(for: .scrap(a), in: model.scene, store: store),
            .unroutable(id: "gone-9", title: nil))
    }

    /// The ordinary case, and the control for all three above.
    func test_noAssociationAtAllResolvesToNone() async throws {
        let store = try await makeCollectionManifest()
        let model = makeModel()
        XCTAssertEqual(PromotionPiece.resolve(for: .scrap(a), in: model.scene, store: store),
                       .none)
    }

    /// The resolver reads §6.2's precedence through `Promotion.piece` rather than
    /// the node's own field — a resolver that read `node.boundPieceID` would pass
    /// every test above and answer `.none` here.
    func test_theResolverInheritsTheHomeRegionsPiece() async throws {
        let store = try await makeCollectionManifest()
        let model = makeModel()
        model.withScene { $0.updateRegion(self.r1) { $0.boundPieceID = "loose-1" } }
        XCTAssertNil(model.scene.node(a)?.boundPieceID, "nothing of its own")
        XCTAssertEqual(
            PromotionPiece.resolve(for: .scrap(a), in: model.scene, store: store),
            .routed(id: "loose-1", title: "Story A", route: .ownResearch))
    }

    // MARK: - What "Goes to" says

    private func plan(_ target: PromotionTarget, piece: PromotionPiece,
                      mode: PromotionMode = .new) -> PromotionPlan {
        let model = makeModel()
        return Promotion.plan(
            PromotionRequest(source: .scrap(a), target: target, mode: mode,
                             scraps: model.scraps,
                             artifacts: ArtifactIndex(titlesByID: [:]), piece: piece),
            in: model.scene)!
    }

    /// No association is not an error and must not read as one: in a novel the
    /// writer is not thinking in pieces at all (§6.2).
    func test_withNoAssociationTheNoteGoesToResearchAndSaysNothingElse() {
        XCTAssertEqual(plan(.researchNote, piece: .none).destinationDescription, "research/")
    }

    func test_aPieceThatKeepsItsOwnResearchSaysSo() {
        XCTAssertEqual(
            plan(.researchNote,
                 piece: .routed(id: "p", title: "Story A", route: .ownResearch))
                .destinationDescription,
            "“Story A”’s own research/")
    }

    /// The novel row. The link is written by `route` itself, and the writer is
    /// told — otherwise the two shared-research rows are indistinguishable on
    /// screen while one of them files the note under a chapter.
    func test_aNovelChapterSaysTheNoteIsSharedAndLinked() {
        XCTAssertEqual(
            plan(.researchNote,
                 piece: .routed(id: "p", title: "Chapter Three", route: .sharedPlusLink))
                .destinationDescription,
            "research/, linked to “Chapter Three”")
    }

    /// The single-document row: derivation already surfaces everything as that
    /// document's, so there is no link — and saying "linked to" here would be a
    /// promise nothing keeps.
    func test_aSingleDocumentProjectSaysTheResearchIsAlreadyThatPieces() {
        let text = plan(.researchNote,
                        piece: .routed(id: "p", title: "The Falls", route: .sharedOnly))
            .destinationDescription
        XCTAssertEqual(text, "research/, which is already “The Falls”’s")
        XCTAssertFalse(text.contains("linked"),
                       "`.sharedOnly` writes no link record")
    }

    /// **A palette card is never routed** — the wall is project-level. What the
    /// association buys it is the link, and only on the `.sharedPlusLink` row,
    /// which is the one condition `linkTargetForCard` actually tests.
    func test_aPaletteCardStaysOnTheWallAndOnlyNamesALinkWhereOneIsWritten() {
        XCTAssertEqual(
            plan(.paletteCard,
                 piece: .routed(id: "p", title: "Chapter Three", route: .sharedPlusLink))
                .destinationDescription,
            "the palette wall, linked to “Chapter Three”")
        for route in [PromotionPiece.Route.ownResearch, .sharedOnly] {
            XCTAssertEqual(
                plan(.paletteCard, piece: .routed(id: "p", title: "Story A", route: route))
                    .destinationDescription,
                "the palette wall",
                "only `.sharedPlusLink` writes a link for a card, so only that row "
                + "may say one is written — \(route)")
        }
        XCTAssertEqual(plan(.paletteCard, piece: .none).destinationDescription,
                       "the palette wall")
    }

    /// **The link promise cannot leak onto an update**, and the reason is
    /// structural rather than a second guard: `destination` answers
    /// "the existing “…”" for every updatable target before the target switch is
    /// reached. `performPaletteCard`'s `.update` arm writes no link, so a
    /// sentence promising one there would be false.
    func test_anUpdateNamesTheExistingArtifactAndPromisesNoLink() {
        let text = plan(.paletteCard,
                        piece: .routed(id: "p", title: "Chapter Three", route: .sharedPlusLink),
                        mode: .update(itemID: "res-1", title: "Act II fog"))
            .destinationDescription
        XCTAssertEqual(text, "the existing “Act II fog”")
        XCTAssertFalse(text.contains("linked"),
                       "the performer takes the link on `.new` only; copy and "
                       + "performer move together or the sheet lies")
        XCTAssertEqual(
            plan(.researchNote,
                 piece: .routed(id: "p", title: "Story A", route: .ownResearch),
                 mode: .update(itemID: "res-1", title: "The falls"))
                .destinationDescription,
            "the existing “The falls”",
            "an update is about the body and does not re-file the artifact, so "
            + "naming the piece here would describe a move that does not happen")
    }

    /// The craft intent takes the SCOPE and never the link, and only where the
    /// routing is `.pieceFolder` — so the copy has exactly two shapes, matching
    /// `PromotionPerformer.intentPiece`.
    func test_theCraftIntentNamesThePieceOnlyWhereItIsScopedToOne() {
        XCTAssertEqual(
            plan(.intentStatement,
                 piece: .routed(id: "p", title: "Story A", route: .ownResearch))
                .destinationDescription,
            "“Story A”’s craft intent, added to the end of what is already there")
        XCTAssertEqual(
            plan(.intentStatement,
                 piece: .routed(id: "p", title: "Chapter Three", route: .sharedPlusLink))
                .destinationDescription,
            "the project's craft intent, added to the end of what is already there",
            "an intent doc created under a novel chapter's shared+link routing "
            + "could never be found again, so it is the project's — and the copy "
            + "says the project's")
    }

    // MARK: - A stale association is refused, in the same words, on both sides

    func test_aStalePieceRefusesANewNoteAndNamesThePiece() throws {
        let failure = try XCTUnwrap(Promotion.pieceFailure(
            target: .researchNote, mode: .new,
            piece: .unroutable(id: "ref-1", title: "Elsewhere")))
        let sentence = try XCTUnwrap(failure.errorDescription)
        XCTAssertTrue(sentence.contains("“Elsewhere”"), "found: \(sentence)")
        XCTAssertTrue(sentence.contains("clear the association"),
                      "a refusal has to name the act that fixes it — found: \(sentence)")
    }

    func test_aDeletedPieceRefusesWithADifferentSentence() throws {
        let sentence = try XCTUnwrap(Promotion.pieceFailure(
            target: .researchNote, mode: .new,
            piece: .unroutable(id: "gone-9", title: nil))?.errorDescription)
        XCTAssertTrue(sentence.contains("no longer in the project"), "found: \(sentence)")
    }

    /// The three targets that degrade rather than fail, and the two modes. Each
    /// is a control for the refusal above: a rule that refused all of them would
    /// pass the two assertions above and block promotions §6.2 says must work.
    func test_onlyANewResearchNoteIsRefusedByAStaleAssociation() {
        let stale = PromotionPiece.unroutable(id: "ref-1", title: "Elsewhere")
        XCTAssertNil(Promotion.pieceFailure(target: .paletteCard, mode: .new, piece: stale),
                     "the wall is project-level; the card is created and simply "
                     + "takes no link")
        XCTAssertNil(Promotion.pieceFailure(target: .intentStatement, mode: .new, piece: stale),
                     "the intent falls back to project scope by design")
        XCTAssertNil(Promotion.pieceFailure(target: .wikiLink, mode: .new, piece: stale))
        XCTAssertNil(Promotion.pieceFailure(
            target: .researchNote, mode: .update(itemID: "res-1", title: "T"), piece: stale),
                     "an update does not route at all — the artifact already exists "
                     + "where it exists")
    }

    func test_aRoutablePieceIsNeverRefused() {
        for route in [PromotionPiece.Route.ownResearch, .sharedPlusLink, .sharedOnly] {
            XCTAssertNil(Promotion.pieceFailure(
                target: .researchNote, mode: .new,
                piece: .routed(id: "p", title: "Story A", route: route)))
        }
        XCTAssertNil(Promotion.pieceFailure(target: .researchNote, mode: .new, piece: .none))
    }

    // MARK: - The sheet says it before Commit

    private func sheet(_ piece: PromotionPiece, target: PromotionTarget = .researchNote)
        -> PromotionSheetModel {
        let model = makeModel()
        let m = PromotionSheetModel(source: .scrap(a), scene: model.scene,
                                    scraps: model.scraps,
                                    artifacts: ArtifactIndex(titlesByID: [:]),
                                    piece: piece, readBody: { _ in nil })
        m.select(target)
        return m
    }

    func test_theSheetsPreviewNamesThePieceAndTheRoute() {
        XCTAssertEqual(
            sheet(.routed(id: "p", title: "Story A", route: .ownResearch))
                .preview?.destinationDescription,
            "“Story A”’s own research/",
            "the piece has to reach the plan the sheet previews, not only the one "
            + "Commit builds")
    }

    /// **Before they commit rather than after.** The writer meets the refusal in
    /// the sheet with Commit disabled, in the same words the performer would
    /// throw — a refusal met before and one met after must not be two wordings
    /// of the same fact (`blockedReason`'s rule, one file over).
    func test_aStaleAssociationDisablesCommitAndSaysWhyInThePerformersWords() throws {
        let m = sheet(.unroutable(id: "ref-1", title: "Elsewhere"))
        XCTAssertFalse(m.canCommit)
        XCTAssertEqual(m.refusal,
                       PromotionFailure.pieceIsNotAResearchTarget(title: "Elsewhere")
                        .errorDescription)
        // The control: the same card with a routable piece commits, so this is
        // about the association and not about the fixture.
        let ok = sheet(.routed(id: "p", title: "Story A", route: .ownResearch))
        XCTAssertTrue(ok.canCommit)
        XCTAssertNil(ok.refusal)
    }

    /// And the sheet does not block the two targets that degrade — a refusal
    /// wired to the piece rather than to the target would.
    func test_aStaleAssociationStillLetsAPaletteCardCommit() {
        let m = sheet(.unroutable(id: "ref-1", title: "Elsewhere"), target: .paletteCard)
        XCTAssertTrue(m.canCommit)
        XCTAssertNil(m.refusal)
    }

    // MARK: - And the performer refuses, having written nothing

    /// Validate first, write second: a refused promotion leaves nothing behind.
    /// Today this throws `ProjectStoreError`'s store-shaped sentence from inside
    /// `createResearchNote`, which is the writer meeting "Referenced pieces keep
    /// research in their own project: ref-1".
    func test_thePerformerRefusesAStaleAssociationAndCreatesNothing() async throws {
        let store = try await makeCollectionManifest()
        let model = makeModel()
        model.withScene { $0.setBoundPiece("ref-1", for: self.a) }
        let plan = Promotion.plan(
            PromotionRequest(source: .scrap(a), target: .researchNote,
                             scraps: model.scraps,
                             artifacts: ArtifactIndex(titlesByID: [:])),
            in: model.scene)!

        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(plan)
            XCTFail("expected a refusal")
        } catch let failure as PromotionFailure {
            XCTAssertEqual(failure, .pieceIsNotAResearchTarget(title: "Elsewhere"))
        }
        XCTAssertTrue(store.manifest.research.isEmpty,
                      "validate first, write second — a half-created artifact is "
                      + "worse than a refusal")
        XCTAssertNil(model.scene.node(a)?.promotedItemID, "and no mark either")
    }
}
