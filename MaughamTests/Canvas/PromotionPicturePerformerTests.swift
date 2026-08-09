import XCTest
import MaughamCore
@testable import Maugham

/// Spec §6's fourth row, performed: an owned picture becomes a research asset,
/// or an image on a palette card — against a real `ProjectStore` on a real temp
/// project, because "the file was COPIED" and "the original survives" are facts
/// about a disk.
///
/// The house pattern is `PromotionPerformerTests`': a per-file helper, not a
/// shared fixture. There is no `TestProjectFixture` in this codebase.
@MainActor
final class PromotionPicturePerformerTests: XCTestCase {

    private let owned = CanvasNodeID("owned-1")
    private let second = CanvasNodeID("owned-2")
    private let scrap = CanvasNodeID("a")
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
        let tmp = temp.url.appendingPathComponent("PPic-\(UUID())")
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

    /// Ingest a file through the **production** pair rather than writing into
    /// `canvas_assets/` by hand — `ProjectStore.ingestCanvasAsset(fileURL:)` is
    /// the one writer of that well, and a hand-built path here would test a
    /// string this codebase deliberately does not spell.
    ///
    /// The bytes are arbitrary: nothing on either path decodes the picture
    /// (`ImagePasteHandler.saveAndReferenceFile` copies, `createResearchAsset`
    /// copies), and the extension is what both read.
    private func ingest(into store: ProjectStore, named: String = "shot.png") async throws
        -> String {
        let source = temp.url.appendingPathComponent("dropped-\(UUID())-\(named)")
        try Data("not really a png, and nothing here decodes one".utf8).write(to: source)
        return try await store.ingestCanvasAsset(fileURL: source)
    }

    /// **`attach` before the inserts**: `CanvasUndo`'s snapshot closures are
    /// wired there, so a bare `CanvasModel` registers no undo step at all and the
    /// one-⌘Z test would pass on an empty stack.
    private func makeModel(at root: URL, ownedPath: String,
                           secondPath: String? = nil) -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.withScene { s in
            s.insert(CanvasNode(id: scrap, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80))
            s.insert(CanvasNode(id: owned, kind: .item(.owned(path: ownedPath)),
                                origin: CGPoint(x: 400, y: 0), width: 180, cachedHeight: 200))
            if let secondPath {
                s.insert(CanvasNode(id: second, kind: .item(.owned(path: secondPath)),
                                    origin: CGPoint(x: 700, y: 0), width: 180,
                                    cachedHeight: 200))
            }
        }
        model.setScrapText("The falls at night", for: scrap)
        return model
    }

    private func index(_ store: ProjectStore) -> ArtifactIndex {
        ArtifactIndex.over(research: store.manifest.research,
                           statements: store.manifest.statements,
                           structure: store.manifest.structure)
    }

    private func plan(_ node: CanvasNodeID, _ target: PromotionTarget,
                      store: ProjectStore, model: CanvasModel,
                      paletteCardID: String? = nil) throws -> PromotionPlan {
        try planFor(.scrap(node), target, store: store, model: model,
                    paletteCardID: paletteCardID)
    }

    /// The same, for a source that is not a node — the region arm, which the
    /// two-producers test needs.
    private func planFor(_ source: PromotionSource, _ target: PromotionTarget,
                         store: ProjectStore, model: CanvasModel,
                         mode: PromotionMode = .new,
                         paletteCardID: String? = nil) throws -> PromotionPlan {
        try XCTUnwrap(Promotion.plan(
            PromotionRequest(source: source, target: target, mode: mode,
                             scraps: model.scraps, artifacts: index(store),
                             paletteCardID: paletteCardID),
            in: model.scene))
    }

    /// A palette card with swatches, a sensory note and a picture already on it —
    /// the state a writer's card is actually in, which is what an append must
    /// leave alone.
    private func makeFurnishedCard(in store: ProjectStore) async throws -> PaletteCard {
        let item = try await store.addPaletteCard(title: "Colour: October", kind: .other)
        let existingImage = temp.url.appendingPathComponent("already-there.png")
        try Data("the card's own picture".utf8).write(to: existingImage)
        _ = try await store.addImage(toPaletteCard: item.id, fileURL: existingImage)
        let card = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == item.id })
        try await store.updatePaletteCard(PaletteCard(
            researchItemId: card.researchItemId, title: card.title, kind: card.kind,
            swatches: ["#112233"],
            notes: [PaletteCard.SensoryNote(sense: .sound, text: "the roar")],
            imagePaths: card.imagePaths, body: "Sodium light."))
        return try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == item.id })
    }

    // MARK: - A research asset

    func test_promotingAPictureFilesACopyInResearch() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store)
        let model = makeModel(at: root, ownedPath: path)

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(owned, .researchAsset, store: store, model: model))

        let created = try XCTUnwrap(TreeWalk.find(id: try XCTUnwrap(result.createdItemID),
                                                  in: store.manifest.research))
        XCTAssertEqual(created.kind, .image, "it is filed as a picture, not as prose")
        let filed = root.appendingPathComponent(try XCTUnwrap(created.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: filed.path),
                      "the copy is really on disk at \(created.path ?? "nil")")
    }

    /// **The snapshot rule** (§6.1's ruling 1, restated in §6's 2026-07-30
    /// amendment): the asset is COPIED and the node stays owned. Promotion does
    /// not hand the file to research and turn the card into a reference — that
    /// variant would make this the one verb on the surface that MOVES, and a
    /// writer who promoted and then pressed ⌘Z would be relying on a file move
    /// to reverse.
    func test_theCanvasKeepsItsPictureAndItsFile() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store)
        let model = makeModel(at: root, ownedPath: path)
        let original = root.appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path),
                      "the control: the well really holds the file before we start")

        _ = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(owned, .researchAsset, store: store, model: model))

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path),
                      "the original stays in canvas_assets/ — a COPY was filed")
        XCTAssertEqual(model.scene.node(owned)?.kind, .item(.owned(path: path)),
                       "and the node is still OWNED, pointing at the same file: "
                       + "promotion never rewrites it into a reference")
    }

    /// The mark, because this row really did produce an artifact of its own —
    /// "I am this thing" is true of it, which is what `promotedItemID` means.
    func test_thePictureCarriesTheMarkOfWhatItProduced() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store)
        let model = makeModel(at: root, ownedPath: path)

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(owned, .researchAsset, store: store, model: model))

        XCTAssertEqual(model.scene.node(owned)?.promotedItemID, result.createdItemID)
        XCTAssertEqual(try XCTUnwrap(model.scene.node(owned)).contributedToItemIDs, [],
                       "and no contribution record: nothing of this picture went "
                       + "into somebody else's artifact")
        XCTAssertNil(try XCTUnwrap(model.scene.node(scrap)).promotedItemID,
                     "the control: only the promoted node is marked")
    }

    // MARK: - An image on a palette card

    func test_promotingAPictureOntoACardLeavesEverythingElseOnIt() async throws {
        let (root, store) = try await makeProject()
        let before = try await makeFurnishedCard(in: store)
        let path = try await ingest(into: store)
        let model = makeModel(at: root, ownedPath: path)

        _ = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(owned, .paletteCardImage, store: store, model: model,
                              paletteCardID: before.researchItemId))

        let after = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == before.researchItemId })
        XCTAssertEqual(after.imagePaths.count, before.imagePaths.count + 1,
                       "appended, never replaced")
        XCTAssertEqual(Array(after.imagePaths.prefix(before.imagePaths.count)),
                       before.imagePaths,
                       "and the card's own picture is still the first one on it")
        XCTAssertEqual(after.swatches, ["#112233"])
        XCTAssertEqual(after.notes.first?.text, "the roar")
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.body, before.body,
                       "nothing about a picture is a reason to rewrite the card's "
                       + "prose — this is the 1C-c2 Critical's shape, and what it "
                       + "cost was exactly these four lines")
    }

    /// **A CONTRIBUTION record, never the mark** (spec §6.3, on a new row). The
    /// picture is *in* that card alongside whatever else is; stamping
    /// `promotedItemID` would say it IS the card, and `Promotion.existingArtifact`
    /// reads that field — only it — to offer **Rewrite**.
    func test_aPictureOnACardRecordsThatItIsInItAndNeverThatItIsIt() async throws {
        let (root, store) = try await makeProject()
        let card = try await makeFurnishedCard(in: store)
        let path = try await ingest(into: store)
        let model = makeModel(at: root, ownedPath: path)

        _ = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(owned, .paletteCardImage, store: store, model: model,
                              paletteCardID: card.researchItemId))

        XCTAssertEqual(model.scene.node(owned)?.contributedToItemIDs, [card.researchItemId])
        XCTAssertNil(try XCTUnwrap(model.scene.node(owned)).promotedItemID,
                     "no mark — with one, promoting again would offer to rewrite "
                     + "the card and replace its other images")
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(owned), target: .paletteCardImage,
                                                in: model.scene, artifacts: index(store)),
                     "which is the assertion that matters: nothing offers an "
                     + "Update afterwards")
    }

    /// **The append is not a rewrite, so the record is STAMPED and never
    /// cleared** — the difference from `PromotionPerformer.record`, which clears
    /// first because a region's note is rebuilt from its current members. Two
    /// pictures on one card are both in it, and both say so.
    func test_asecondPictureOnTheSameCardDoesNotEraseTheFirstsRecord() async throws {
        let (root, store) = try await makeProject()
        let card = try await makeFurnishedCard(in: store)
        let first = try await ingest(into: store, named: "one.png")
        let other = try await ingest(into: store, named: "two.png")
        let model = makeModel(at: root, ownedPath: first, secondPath: other)
        let performer = PromotionPerformer(store: store, model: model)

        _ = try await performer.perform(
            try plan(owned, .paletteCardImage, store: store, model: model,
                     paletteCardID: card.researchItemId))
        _ = try await performer.perform(
            try plan(second, .paletteCardImage, store: store, model: model,
                     paletteCardID: card.researchItemId))

        XCTAssertEqual(model.scene.node(owned)?.contributedToItemIDs, [card.researchItemId],
                       "the first picture's record survives the second promotion — "
                       + "routed through the region path's clear-then-stamp it "
                       + "would have been wiped, and its words really are still there")
        XCTAssertEqual(model.scene.node(second)?.contributedToItemIDs, [card.researchItemId])
        let after = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == card.researchItemId })
        XCTAssertEqual(after.imagePaths.count, card.imagePaths.count + 2,
                       "the control: both pictures really landed on the card")
    }

    /// **A palette card has TWO producers now, and a region's Update must not
    /// take back a record it never wrote** (review M1). Promote region R to card
    /// P; promote an owned picture onto P; re-promote R with **Update**. Scoped
    /// to the artifact id alone, `PromotionPerformer.record`'s clear reached the
    /// picture — and its image is still in P's well, so the pane went silent
    /// about a photograph demonstrably on that card. §6.3's own false-pane
    /// defect, in its mild direction.
    ///
    /// The region's own re-stamp is the control: the clear still does its job for
    /// the producer that owns those records.
    func test_aRegionsUpdateDoesNotClearAPicturesRecordOnTheSameCard() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store)
        let model = makeModel(at: root, ownedPath: path)
        model.withScene { s in
            s.insertRegion(CanvasRegion(id: self.r1, label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                        homeMembers: [self.scrap]))
        }
        let performer = PromotionPerformer(store: store, model: model)

        let made = try await performer.perform(
            try planFor(.region(r1), .paletteCard, store: store, model: model))
        let cardID = try XCTUnwrap(made.createdItemID)
        _ = try await performer.perform(
            try plan(owned, .paletteCardImage, store: store, model: model,
                     paletteCardID: cardID))
        XCTAssertEqual(model.scene.node(owned)?.contributedToItemIDs, [cardID],
                       "the control: the picture really recorded the card before "
                       + "the Update, or the assertion below holds on nothing")

        let update = try XCTUnwrap(Promotion.existingArtifact(
            for: .region(r1), target: .paletteCard, in: model.scene,
            artifacts: index(store)))
        _ = try await performer.perform(
            try planFor(.region(r1), .paletteCard, store: store, model: model, mode: update))

        XCTAssertEqual(model.scene.node(owned)?.contributedToItemIDs, [cardID],
                       "the picture's record survives a producer that never wrote it")
        XCTAssertEqual(model.scene.node(scrap)?.contributedToItemIDs, [cardID],
                       "and the region's own member is re-stamped — the clear still "
                       + "does its job for the records it does own")
        let after = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == cardID })
        XCTAssertEqual(after.imagePaths.count, 1,
                       "the control that makes the silence a lie: the image really "
                       + "is still on the card the pane would have stopped naming")
    }

    // MARK: - One promotion, one ⌘Z (tripwire 32)

    /// **A scene-only assertion cannot tell "its own step" from "folded into the
    /// neighbouring one".** The discriminator is the step's NAME — the top of the
    /// stack after the promotion, and what is underneath it after one ⌘Z — which
    /// is also what the writer reads in the Edit menu.
    ///
    /// No gesture is open here — the step underneath is an ordinary edit, which
    /// is what makes "exactly one was consumed" readable. The mid-gesture case
    /// is `test_theMarkIsItsOwnStepWithAScrapGestureOpen` below, and it is the
    /// one tripwire 32 is actually about.
    func test_oneUndoTakesBackTheWholePicturePromotionInOneStep() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store)
        let model = makeModel(at: root, ownedPath: path)
        model.undoManager.groupsByEvent = false
        // A genuinely different step underneath, so "exactly one was consumed" is
        // observable rather than inferred from an empty stack.
        model.mutate("Move Card") { $0.move(self.scrap, to: CGPoint(x: 10, y: 10)) }

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(owned, .researchAsset, store: store, model: model))
        XCTAssertEqual(model.scene.node(owned)?.promotedItemID, result.createdItemID,
                       "the control: there is a mark to take back at all")
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promote Picture"),
                      "found: \(model.undoManager.undoMenuItemTitle)")

        model.undo.undo()
        XCTAssertNil(try XCTUnwrap(model.scene.node(owned)).promotedItemID)
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Move Card"),
                      "exactly ONE step was consumed — a second bracket in the "
                      + "performer would leave a second \"Promote Picture\" on "
                      + "top. found: \(model.undoManager.undoMenuItemTitle)")
        XCTAssertNotNil(TreeWalk.find(id: try XCTUnwrap(result.createdItemID),
                                      in: store.manifest.research),
                        "and ⌘Z takes back the MARK, not the artifact — the canvas's "
                        + "undo is scene-scoped by design (ADR 0026 §5)")
    }

    func test_thePaletteRowIsOneStepToo() async throws {
        let (root, store) = try await makeProject()
        let card = try await makeFurnishedCard(in: store)
        let path = try await ingest(into: store)
        let model = makeModel(at: root, ownedPath: path)
        model.undoManager.groupsByEvent = false
        model.mutate("Move Card") { $0.move(self.scrap, to: CGPoint(x: 10, y: 10)) }

        _ = try await PromotionPerformer(store: store, model: model)
            .perform(try plan(owned, .paletteCardImage, store: store, model: model,
                              paletteCardID: card.researchItemId))
        XCTAssertEqual(model.scene.node(owned)?.contributedToItemIDs, [card.researchItemId],
                       "the control")
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promote Picture"),
                      "found: \(model.undoManager.undoMenuItemTitle)")

        model.undo.undo()
        XCTAssertEqual(try XCTUnwrap(model.scene.node(owned)).contributedToItemIDs, [])
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Move Card"),
                      "found: \(model.undoManager.undoMenuItemTitle)")
    }

    /// **Tripwire 32's own repro, on both picture rows.** The promotion runs from
    /// the right-hand column while a focused scrap holds "Edit Scrap" open —
    /// nothing on that side of the window closes it, and the performer has no
    /// gesture of its own to protect. With `mutate` instead of
    /// `mutateFromInspector` the write nests, registers **no step at all**, and
    /// rides into the writer's next sentence, so a ⌘Z aimed at a sentence takes
    /// the mark with it.
    ///
    /// The assertion is the step's NAME again: mid-gesture, a nested write leaves
    /// "Edit Scrap" on top.
    func test_theMarkIsItsOwnStepWithAScrapGestureOpen() async throws {
        let (root, store) = try await makeProject()
        let card = try await makeFurnishedCard(in: store)
        let path = try await ingest(into: store, named: "one.png")
        let other = try await ingest(into: store, named: "two.png")
        let model = makeModel(at: root, ownedPath: path, secondPath: other)
        let performer = PromotionPerformer(store: store, model: model)
        model.undoManager.groupsByEvent = false

        model.beginGesture("Edit Scrap")          // the writer is typing in a card
        _ = try await performer.perform(try plan(owned, .researchAsset,
                                                 store: store, model: model))
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promote Picture"),
                      "found: \(model.undoManager.undoMenuItemTitle)")

        _ = try await performer.perform(
            try plan(second, .paletteCardImage, store: store, model: model,
                     paletteCardID: card.researchItemId))
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promote Picture"),
                      "the contribution row takes the same bracket — found: "
                      + "\(model.undoManager.undoMenuItemTitle)")
        model.endGesture()
    }

    // MARK: - Validate first, write second

    /// A refused promotion leaves nothing behind. The well is content the writer
    /// can delete, so a node naming a file that is gone is a real state — and
    /// refusing it inside `createResearchAsset` instead would already be past the
    /// flush, with a manifest entry pointing at nothing.
    func test_aPictureWhoseFileIsGoneRefusesAndWritesNothing() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store)
        let model = makeModel(at: root, ownedPath: path)
        let request = try plan(owned, .researchAsset, store: store, model: model)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))

        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(request)
            XCTFail("a missing picture must refuse")
        } catch {
            XCTAssertEqual(error as? PromotionFailure,
                           .pictureIsGone(path: path, source: .scrap(owned)))
        }
        XCTAssertTrue(store.manifest.research.isEmpty, "and created nothing")
        XCTAssertNil(try XCTUnwrap(model.scene.node(owned)).promotedItemID, "and marked nothing")
    }

    func test_aDeletedPaletteCardRefusesInTheWritersWords() async throws {
        let (root, store) = try await makeProject()
        let card = try await makeFurnishedCard(in: store)
        let path = try await ingest(into: store)
        let model = makeModel(at: root, ownedPath: path)
        let stale = try plan(owned, .paletteCardImage, store: store, model: model,
                             paletteCardID: card.researchItemId)
        try await store.deleteResearchItem(id: card.researchItemId)

        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(stale)
            XCTFail("a deleted card must refuse")
        } catch {
            XCTAssertEqual(error as? PromotionFailure, .paletteCardIsGone)
        }
        XCTAssertEqual(try XCTUnwrap(model.scene.node(owned)).contributedToItemIDs, [])
    }

    /// **Which refusal comes first when BOTH are true** (1C-d Task 12a, review
    /// Minor 3). A missing file kills the promotion whatever card is chosen; a
    /// missing card does not. Told about the card first, the writer picks
    /// another one and meets the picture refusal on the next attempt — two round
    /// trips for one dead promotion.
    ///
    /// Unpinned until now, which is how hoisting the file check out of the arm
    /// silently swapped the two. The order is `validate`'s statement order and
    /// nothing else, so this is the assertion that makes the next hoist a
    /// decision.
    func test_aPromotionWhosePictureAndCardAreBothGoneNamesThePictureFirst() async throws {
        let (root, store) = try await makeProject()
        let card = try await makeFurnishedCard(in: store)
        let first = try await ingest(into: store, named: "one.png")
        let other = try await ingest(into: store, named: "two.png")
        let model = makeModel(at: root, ownedPath: first, secondPath: other)
        // **Both plans are built while the card still exists**, because a plan is
        // a SNAPSHOT — `Promotion.targets` withholds the palette row from a
        // project with no palette cards, so a plan built after the deletion is
        // nil and there is no refusal to order.
        let bothGone = try plan(owned, .paletteCardImage, store: store, model: model,
                                paletteCardID: card.researchItemId)
        let cardOnly = try plan(second, .paletteCardImage, store: store, model: model,
                                paletteCardID: card.researchItemId)
        try FileManager.default.removeItem(at: root.appendingPathComponent(first))
        try await store.deleteResearchItem(id: card.researchItemId)

        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(bothGone)
            XCTFail("both gone must refuse")
        } catch {
            XCTAssertEqual(error as? PromotionFailure,
                           .pictureIsGone(path: first, source: .scrap(owned)),
                           "the more fundamental refusal goes first")
        }
        // The control: the same deleted card, with its picture still on disk,
        // still refuses with the CARD's sentence — so the assertion above is
        // about the order and not about `paletteCardIsGone` having stopped
        // working.
        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(cardOnly)
            XCTFail("a deleted card must refuse")
        } catch {
            XCTAssertEqual(error as? PromotionFailure, .paletteCardIsGone)
        }
    }

    /// The confirmation is what tells the writer anything happened at all — and
    /// both sentences say **copy**, because the picture staying put is the fact
    /// they will test.
    func test_theWriterIsToldACopyWasMade() async throws {
        let (root, store) = try await makeProject()
        let card = try await makeFurnishedCard(in: store)
        let path = try await ingest(into: store)
        let model = makeModel(at: root, ownedPath: path)
        let performer = PromotionPerformer(store: store, model: model)

        let researchPlan = try plan(owned, .researchAsset, store: store, model: model)
        let filed = try await performer.perform(researchPlan)
        XCTAssertTrue(filed.confirmation(for: researchPlan).hasPrefix("Copied the picture"),
                      "found: \(filed.confirmation(for: researchPlan))")

        let cardPlan = try plan(owned, .paletteCardImage, store: store, model: model,
                                paletteCardID: card.researchItemId)
        let added = try await performer.perform(cardPlan)
        XCTAssertEqual(added.confirmation(for: cardPlan),
                       "Added a copy of the picture to the palette card “Colour: October”.")
    }
}
