import XCTest
import MaughamCore
@testable import Maugham

/// Spec §6's 2026-07-29 amendment, performed: a region that holds a picture
/// promotes to a palette card **with** the picture on it. Against a real
/// `ProjectStore` on a real temp project, because "the file was COPIED", "the
/// card's other images survived" and "nothing was written when it refused" are
/// facts about a disk.
///
/// The house pattern is `PromotionPicturePerformerTests`': a per-file helper,
/// not a shared fixture. There is no `TestProjectFixture` in this codebase.
@MainActor
final class PromotionRegionPicturePerformerTests: XCTestCase {

    private let topCard = CanvasNodeID("a")
    private let owned = CanvasNodeID("owned-1")
    private let secondOwned = CanvasNodeID("owned-2")
    private let r1 = CanvasRegionID("r1")

    private var documentStores: [DocumentStore] = []
    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for ds in documentStores { await ds.close() }
        documentStores = []
        temp = nil
    }

    private func makeProject() async throws -> (URL, ProjectStore) {
        let tmp = temp.url.appendingPathComponent("PRPic-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for sub in ["manuscript", "research"] {
            try FileManager.default.createDirectory(
                at: tmp.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds
        documentStores.append(ds)
        return (tmp, store)
    }

    /// Ingest through the **production** pair — `ingestCanvasAsset` is the one
    /// writer of `canvas_assets/`, and a hand-built path here would test a string
    /// this codebase deliberately does not spell. The bytes are arbitrary:
    /// nothing on either path decodes a picture, and the extension is what both
    /// read.
    /// **The BYTES identify the picture, because the filename cannot.**
    /// `ingestCanvasAsset` mints `image-yyyyMMdd-HHmmss.<ext>` and discards the
    /// writer's own name, and `addImage` mints again on the way onto the card —
    /// so two pictures ingested in the same second differ only by a `-2` suffix.
    /// Nothing on either path decodes an image, so arbitrary text is a legitimate
    /// payload and is what makes the ORDER assertion below readable.
    private func ingest(into store: ProjectStore, named: String) async throws -> String {
        let source = temp.url.appendingPathComponent("dropped-\(UUID())-\(named)")
        try Data("the picture called \(named)".utf8).write(to: source)
        return try await store.ingestCanvasAsset(fileURL: source)
    }

    private func contents(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// A **referenced** picture: a real research asset, so the index this task
    /// hands the request resolves it exactly as `ProjectWindow` does.
    private func fileInResearch(_ store: ProjectStore, named: String) async throws
        -> ResearchItem {
        let source = temp.url.appendingPathComponent("filed-\(UUID())-\(named)")
        try Data("a photograph already in research".utf8).write(to: source)
        return try await store.createResearchAsset(scope: .shared, fromURL: source)
    }

    /// `attach` before the inserts: `CanvasUndo`'s snapshot closures are wired
    /// there, so a bare `CanvasModel` registers no undo step at all and the
    /// one-⌘Z test would pass on an empty stack.
    ///
    /// Reading order is top-to-bottom, so the y values ARE the expected order.
    private func makeModel(at root: URL, pictures: [(CanvasNodeID, String)],
                           references: [CanvasNodeID] = []) -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.withScene { s in
            s.insert(CanvasNode(id: self.topCard, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80))
            var home: Set<CanvasNodeID> = [self.topCard]
            var y: CGFloat = 100
            for (id, path) in pictures {
                s.insert(CanvasNode(id: id, kind: .item(.owned(path: path)),
                                    origin: CGPoint(x: 0, y: y), width: 180,
                                    cachedHeight: 200))
                home.insert(id)
                y += 100
            }
            for id in references {
                s.insert(CanvasNode(id: id, kind: .item(.project(id: id.raw
                                                                 .replacingOccurrences(
                                                                    of: "item:", with: ""))),
                                    origin: CGPoint(x: 0, y: y), width: 180,
                                    cachedHeight: 200))
                home.insert(id)
                y += 100
            }
            s.insertRegion(CanvasRegion(id: self.r1, label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 800),
                                        homeMembers: home))
        }
        model.setScrapText("The falls at night.", for: topCard)
        return model
    }

    private func plan(_ store: ProjectStore, _ model: CanvasModel,
                      target: PromotionTarget = .paletteCard,
                      mode: PromotionMode = .new) throws -> PromotionPlan {
        try XCTUnwrap(Promotion.plan(
            PromotionRequest(source: .region(r1), target: target, mode: mode,
                             scraps: model.scraps,
                             artifacts: ArtifactIndex.over(research: store.manifest.research),
                             // The same builder `ProjectWindow` hands the sheet.
                             items: CanvasItemIndex.over(research: store.manifest.research)),
            in: model.scene))
    }

    private func card(_ store: ProjectStore, _ id: String) throws -> PaletteCard {
        try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == id })
    }

    // MARK: - The card is made with the pictures on it

    func test_aRegionsPaletteCardIsMadeWithTheProseAndThePicturesInIt() async throws {
        let (root, store) = try await makeProject()
        let first = try await ingest(into: store, named: "one.png")
        let second = try await ingest(into: store, named: "two.png")
        let filed = try await fileInResearch(store, named: "three.png")
        let model = makeModel(at: root, pictures: [(owned, first), (secondOwned, second)],
                              references: [CanvasNodeID.item(filed.id)])

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(store, model))

        let made = try card(store, try XCTUnwrap(result.createdItemID))
        XCTAssertEqual(made.body, "The falls at night.")
        XCTAssertEqual(made.imagePaths.count, 3,
                       "two owned pictures and one reference — found "
                       + "\(made.imagePaths)")
        for path in made.imagePaths {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(path).path),
                          "the card's copy is really on disk at \(path)")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(first).path),
                      "and the canvas keeps its own — a COPY was made (§6.1's "
                      + "ruling 1), so the writer's card still draws a picture")
    }

    /// **The picture appended second must not replace the first**, which is the
    /// 1C-c2 Critical's exact shape one row over. The order is the region's
    /// reading order, so a card assembled from a region reads the way the region
    /// reads.
    func test_thePicturesAreAppendedInOrderAndNeverReplaceEachOther() async throws {
        let (root, store) = try await makeProject()
        let first = try await ingest(into: store, named: "one.png")
        let second = try await ingest(into: store, named: "two.png")
        let model = makeModel(at: root, pictures: [(owned, first), (secondOwned, second)])

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(store, model))

        let made = try card(store, try XCTUnwrap(result.createdItemID))
        // One comparison over the whole list rather than two subscripts: an
        // assertion is not a `return`, so indexing after a failed count
        // assertion crashes the runner rather than reporting the failure — which
        // is what the disable experiment for this test produced.
        XCTAssertEqual(try made.imagePaths.map { try contents(root, $0) },
                       ["the picture called one.png", "the picture called two.png"],
                       "the higher card in the region is first, so the card is "
                       + "assembled the way the region reads — and the second "
                       + "landed BESIDE the first, not over it. found "
                       + "\(made.imagePaths)")
    }

    /// **The Critical's own assertion, and it is not optional.** A card the
    /// writer has since given swatches, sensory notes and an image of its own
    /// must keep every one of them when the region that made it is re-promoted —
    /// the 1C-c2 Critical is a promotion that rewrote a palette card's backing
    /// file and took exactly these with it, with ⌘Z restoring only the mark.
    ///
    /// It doubles as the rewrite rule: an update copies **no** picture again, or
    /// every re-promotion would stack another copy of every photograph in the
    /// region onto the writer's card.
    func test_anUpdateLeavesEverythingElseOnTheCardAndCopiesNoPictureTwice() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store, named: "one.png")
        let model = makeModel(at: root, pictures: [(owned, path)])
        let performer = PromotionPerformer(store: store, model: model)

        let made = try await performer.perform(try plan(store, model))
        let cardID = try XCTUnwrap(made.createdItemID)

        // The writer furnishes the card afterwards, which is the state a real
        // card is in by the time anyone re-promotes.
        let byHand = temp.url.appendingPathComponent("their-own.png")
        try Data("the writer's own picture".utf8).write(to: byHand)
        _ = try await store.addImage(toPaletteCard: cardID, fileURL: byHand)
        let furnished = try card(store, cardID)
        try await store.updatePaletteCard(PaletteCard(
            researchItemId: cardID, title: furnished.title, kind: furnished.kind,
            swatches: ["#112233"],
            notes: [PaletteCard.SensoryNote(sense: .sound, text: "the roar")],
            imagePaths: furnished.imagePaths, body: furnished.body))
        let before = try card(store, cardID)
        XCTAssertEqual(before.imagePaths.count, 2, "the control: two images going in")

        model.setScrapText("The falls at night, again.", for: topCard)
        let update = try XCTUnwrap(Promotion.existingArtifact(
            for: .region(r1), target: .paletteCard, in: model.scene,
            artifacts: ArtifactIndex.over(research: store.manifest.research)))
        _ = try await performer.perform(try plan(store, model, mode: update))

        let after = try card(store, cardID)
        XCTAssertEqual(after.imagePaths, before.imagePaths,
                       "every image survived, in order, and NONE was added — a "
                       + "rewrite is about the words. found \(after.imagePaths)")
        XCTAssertEqual(after.swatches, ["#112233"])
        XCTAssertEqual(after.notes.first?.text, "the roar")
        XCTAssertEqual(after.body, "The falls at night, again.",
                       "the control: the rewrite really did happen, so the four "
                       + "assertions above are about what it left alone")
    }

    // MARK: - What the pictures record (spec §6.3's 2026-07-31 amendment)

    /// Denver's ruling: *"they should report their promotion in the same way as
    /// the text scraps."* And §6.3's unchanged half — it is
    /// `contributedToItemID` and **never** the mark, because
    /// `Promotion.existingArtifact` reads only the mark to offer **Rewrite**, and
    /// a contributor carrying one could rewrite a whole multi-card note with a
    /// single card's content.
    func test_thePicturesRecordThatTheyAreInTheCardAndNeverThatTheyAreIt() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store, named: "one.png")
        let filed = try await fileInResearch(store, named: "two.png")
        let reference = CanvasNodeID.item(filed.id)
        let model = makeModel(at: root, pictures: [(owned, path)], references: [reference])

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(store, model))
        let cardID = try XCTUnwrap(result.createdItemID)

        for node in [owned, reference, topCard] {
            XCTAssertEqual(model.scene.node(node)?.contributedToItemID, cardID,
                           "\(node) put its content in that card and says so")
            XCTAssertNil(try XCTUnwrap(model.scene.node(node)).promotedItemID,
                         "and none of them IS the card — \(node)")
        }
        XCTAssertEqual(model.scene.region(r1)?.promotedItemID, cardID,
                       "the control: the region is what produced it, and carries "
                       + "the mark")
        for node in [owned, reference] {
            XCTAssertNil(Promotion.existingArtifact(
                for: .scrap(node), target: .paletteCard, in: model.scene,
                artifacts: ArtifactIndex.over(research: store.manifest.research)),
                         "which is the assertion that matters: nothing offers an "
                         + "Update against a contributor — \(node)")
        }
    }

    // MARK: - One gesture, one bracket, one undo step (tripwire 32)

    /// **A scene-only assertion cannot tell "its own step" from "folded into the
    /// neighbouring step".** The discriminator is the step's NAME, which is also
    /// what the writer reads in the Edit menu. A second `mutateFromInspector`
    /// opened for the pictures would leave a second "Promote Region" on the
    /// stack — or, nested, no step at all.
    func test_oneUndoTakesBackTheMarkAndEveryPictureRecordInOneStep() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store, named: "one.png")
        let model = makeModel(at: root, pictures: [(owned, path)])
        model.undoManager.groupsByEvent = false
        // A genuinely different step underneath, so "exactly one was consumed" is
        // observable rather than inferred from an empty stack.
        model.mutate("Move Card") { $0.move(self.topCard, to: CGPoint(x: 10, y: 10)) }

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(store, model))
        XCTAssertEqual(model.scene.node(owned)?.contributedToItemID, result.createdItemID,
                       "the control: there is a picture record to take back at all")
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promote Region"),
                      "found: \(model.undoManager.undoMenuItemTitle)")

        model.undo.undo()
        XCTAssertNil(try XCTUnwrap(model.scene.node(owned)).contributedToItemID)
        XCTAssertNil(try XCTUnwrap(model.scene.region(r1)).promotedItemID)
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Move Card"),
                      "exactly ONE step was consumed — a second bracket for the "
                      + "pictures would leave a second \"Promote Region\" on top. "
                      + "found: \(model.undoManager.undoMenuItemTitle)")
    }

    /// Tripwire 32's own repro: the promotion runs from the right-hand column
    /// while a focused scrap holds "Edit Scrap" open, and nothing on that side of
    /// the window closes it. With `mutate` the write nests, registers **no step
    /// at all**, and rides into the writer's next sentence.
    func test_theWholePromotionIsItsOwnStepWithAScrapGestureOpen() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store, named: "one.png")
        let model = makeModel(at: root, pictures: [(owned, path)])
        model.undoManager.groupsByEvent = false

        model.beginGesture("Edit Scrap")          // the writer is typing in a card
        _ = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(store, model))
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promote Region"),
                      "found: \(model.undoManager.undoMenuItemTitle)")
        model.endGesture()
    }

    // MARK: - Validate first, write second

    /// The well is content the writer can delete, so a region holding a node
    /// that names a file which is gone is a real state. Refused **before** the
    /// card is created, or the writer is left with a half-furnished palette card
    /// on the wall and a failure alert about it.
    func test_aRegionWhosePictureIsGoneRefusesAndCreatesNoCard() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store, named: "one.png")
        let model = makeModel(at: root, pictures: [(owned, path)])
        let request = try plan(store, model)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))

        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(request)
            XCTFail("a missing picture must refuse")
        } catch {
            XCTAssertEqual(error as? PromotionFailure,
                           .pictureIsGone(path: path, source: .region(r1)))
        }
        XCTAssertTrue(store.loadPaletteCards().isEmpty, "and made no card")
        XCTAssertNil(try XCTUnwrap(model.scene.region(r1)).promotedItemID,
                     "and marked nothing")
        XCTAssertNil(try XCTUnwrap(model.scene.node(topCard)).contributedToItemID,
                     "and recorded nothing on the members whose words would "
                     + "otherwise have gone in")
    }

    /// **The refusal names something the writer is looking at** (review Minor 1).
    /// This sentence said *"The picture this **card** shows…"* and became
    /// reachable from a REGION in this task, where no card is selected and the
    /// only identifier it offers is a minted path `CanvasItemFacts.ownedTitle`
    /// argues is a clock reading. `emptyBody` gained `PromotionSource.noun` for
    /// exactly this, one sentence over in the same file.
    func test_aRegionsMissingPictureIsNotDescribedAsACardTheWriterDidNotSelect() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store, named: "one.png")
        let model = makeModel(at: root, pictures: [(owned, path)])
        let request = try plan(store, model)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))

        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(request)
            XCTFail("a missing picture must refuse")
        } catch {
            let sentence = (error as? PromotionFailure)?.errorDescription
            XCTAssertEqual(sentence,
                           "A picture in this region is no longer in the project "
                           + "(\(path)), so there is nothing to copy.")
        }
        // The control, and the reason this is an axis rather than a rewording: a
        // CARD source really is a card the writer selected and is looking at, and
        // its sentence still says so.
        XCTAssertEqual(
            PromotionFailure.pictureIsGone(path: path, source: .scrap(owned)).errorDescription,
            "The picture this card shows is no longer in the project "
            + "(\(path)), so there is nothing to copy.")
    }

    // MARK: - The control

    /// Without this, the whole task could be passing by making every region
    /// promotion different.
    func test_aRegionWithNoPictureInItPromotesExactlyAsItDidBefore() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root, pictures: [])

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(store, model))

        let made = try card(store, try XCTUnwrap(result.createdItemID))
        XCTAssertTrue(made.imagePaths.isEmpty)
        XCTAssertEqual(made.body, "The falls at night.")
        XCTAssertEqual(made.title, "Act II fog")
        XCTAssertEqual(model.scene.node(topCard)?.contributedToItemID,
                       result.createdItemID)
    }
}
