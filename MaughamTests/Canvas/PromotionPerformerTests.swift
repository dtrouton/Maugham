import XCTest
import MaughamCore
@testable import Maugham

/// Promotion, performed against a real `ProjectStore` on a real temp project.
///
/// The house pattern (`MaughamTests/MCP/Tools/ListAllLinksToolTests.swift:7`):
/// a per-file helper, not a shared fixture. There is no `TestProjectFixture` in
/// this codebase.
@MainActor
final class PromotionPerformerTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let r1 = CanvasRegionID("r1")
    private let l1 = CanvasLineID("l1")

    /// `ProjectStore.documentStore` is a WEAK var, so the test has to hold the
    /// stores it wires. Closed in `tearDown`.
    private var documentStores: [DocumentStore] = []

    /// `TempDirectory` removes its tree on teardown; a bare
    /// `temporaryDirectory.appendingPathComponent` leaves ~20 project trees per
    /// run under `/var/folders`.
    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for ds in documentStores { await ds.close() }
        documentStores = []
        temp = nil
    }

    /// A real `DocumentStore` is wired in, following the house pattern
    /// (`ProjectStorePaletteTests.makeNovel`): `addResearchItem` refuses to
    /// create a research GROUP without one, and the palette group is a group —
    /// so every palette promotion needs it. It also puts the body writes on the
    /// coordinated `performFileSave` path production takes, rather than on the
    /// no-`DocumentStore` fallback.
    private func makeProject() async throws -> (URL, ProjectStore) {
        let tmp = temp.url.appendingPathComponent("PP-\(UUID())")
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

    private func makeModel(at root: URL) -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.withScene { s in
            s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80))
            s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 0, y: 200),
                                width: 240, cachedHeight: 80))
            s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                        homeMembers: [a, b]))
            s.insertLine(CanvasLine(id: l1, from: a, to: b))
        }
        model.setScrapText("The falls at night\n\nSodium light on the spray.", for: a)
        model.setScrapText("October's doctor", for: b)
        return model
    }

    private func index(_ store: ProjectStore) -> ArtifactIndex {
        ArtifactIndex.over(research: store.manifest.research)
    }

    private func plan(_ source: PromotionSource, _ target: PromotionTarget,
                      store: ProjectStore, model: CanvasModel,
                      mode: PromotionMode = .new,
                      kind: PaletteCard.Kind = .other) -> PromotionPlan {
        Promotion.plan(
            PromotionRequest(source: source, target: target, mode: mode,
                             scraps: model.scraps, paletteKind: kind,
                             artifacts: index(store)),
            in: model.scene)!
    }

    private func body(of item: ResearchItem, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(item.path ?? ""), encoding: .utf8)
    }

    private func item(_ title: String, in store: ProjectStore) throws -> ResearchItem {
        try XCTUnwrap(TreeWalk.first(in: store.manifest.research, where: { $0.title == title }))
    }

    // MARK: - Scrap → research note

    func test_promotingAScrapCreatesARealNoteWithItsBody() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        let created = try item("The falls at night", in: store)
        XCTAssertEqual(result.createdItemID, created.id)
        XCTAssertTrue(try body(of: created, in: root).contains("Sodium light on the spray."))
    }

    /// §1 and §6: promotion is a seam, not a move. The canvas is scratch and
    /// stays scratch — the card keeps its words and gains a mark.
    func test_promotingAScrapLeavesItOnTheCanvasAndMarksIt() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        XCTAssertNotNil(model.scene.node(a))
        XCTAssertEqual(model.scraps[a], "The falls at night\n\nSodium light on the spray.")
        XCTAssertEqual(model.scene.node(a)?.promotedItemID, result.createdItemID)
        XCTAssertNil(try XCTUnwrap(model.scene.node(b)).promotedItemID,
                     "and only the one promoted")
    }

    /// The mark is a scene change made from OUTSIDE `CanvasView`, so it has to
    /// arrive as its own undo step — see tripwire 32. An assertion on the scene
    /// alone cannot tell "its own step" from "folded into the open one"; the
    /// discriminator is the step's NAME, which is also what the writer reads in
    /// the Edit menu.
    func test_theMarkIsItsOwnUndoStepEvenWithAScrapGestureOpen() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        model.beginGesture("Edit Scrap")          // the writer is typing in a card
        _ = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promote Scrap"),
                      "found: \(model.undoManager.undoMenuItemTitle)")
        model.endGesture()
    }

    func test_undoTakesBackTheMarkAndLeavesTheNote() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        _ = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        model.undo.undo()
        XCTAssertNil(try XCTUnwrap(model.scene.node(a)).promotedItemID)
        XCTAssertNotNil(TreeWalk.first(in: store.manifest.research,
                                       where: { $0.title == "The falls at night" }),
                        "the canvas's undo is scene-scoped; the note is a real file "
                        + "with its own lifecycle, and the guide says so")
    }

    // MARK: - Update or New

    func test_promotingAgainAsNewProducesASecondArtifact() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            plan(.scrap(a), .researchNote, store: store, model: model))
        let second = try await performer.perform(
            plan(.scrap(a), .researchNote, store: store, model: model))

        XCTAssertNotEqual(first.createdItemID, second.createdItemID)
        XCTAssertEqual(TreeWalk.collect(in: store.manifest.research,
                                        where: { $0.type == .asset }).count, 2)
        XCTAssertEqual(model.scene.node(a)?.promotedItemID, second.createdItemID,
                       "the mark names the most recent")
    }

    func test_updatingRewritesTheSameNoteAndMintsNothing() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            plan(.scrap(a), .researchNote, store: store, model: model))

        model.setScrapText("The falls at night\n\nAnd the ponchos.", for: a)
        let existing = Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                  in: model.scene, artifacts: index(store))
        XCTAssertEqual(existing, .update(itemID: first.createdItemID!,
                                         title: "The falls at night"))
        let second = try await performer.perform(
            plan(.scrap(a), .researchNote, store: store, model: model, mode: existing!))

        XCTAssertEqual(second.createdItemID, first.createdItemID)
        XCTAssertEqual(TreeWalk.collect(in: store.manifest.research,
                                        where: { $0.type == .asset }).count, 1)
        let note = try item("The falls at night", in: store)
        let text = try body(of: note, in: root)
        XCTAssertTrue(text.contains("And the ponchos."))
        XCTAssertFalse(text.contains("Sodium light on the spray."),
                       "an update REWRITES the body — that is what the preview says "
                       + "it will do")
    }

    func test_updatingAnArtifactThatHasSinceBeenDeletedRefusesRatherThanCreating() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let stale = PromotionPlan(
            source: .scrap(a), producedKind: .researchNote, title: "T", body: "B",
            destinationDescription: "the existing “T”", discards: [], offeredLinks: [],
            wikiLinkWrite: nil,
            mode: .update(itemID: "res-gone", title: "T"), paletteKind: .other,
            contributors: [], linkAlreadyPresent: false, pictures: [])
        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(stale)
            XCTFail("expected a refusal")
        } catch PromotionFailure.artifactMissing {
            XCTAssertTrue(store.manifest.research.isEmpty, "and nothing was created instead")
        }
        _ = root
    }

    // MARK: - Scrap → palette card

    func test_promotingAScrapToAPaletteCardPutsItOnTheWallWithItsKind() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        _ = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .paletteCard, store: store, model: model, kind: .location))

        let card = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.title == "The falls at night" })
        XCTAssertEqual(card.kind, .location)
        XCTAssertTrue(card.body.contains("Sodium light on the spray."),
                      "a palette card whose prose was dropped is not the scrap promoted")
        _ = root
    }

    /// A card the writer has since given swatches and images must not lose them
    /// to an update that was only ever about the prose.
    func test_updatingAPaletteCardKeepsItsSwatchesAndImages() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            plan(.scrap(a), .paletteCard, store: store, model: model))

        let original = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == first.createdItemID })
        try await store.updatePaletteCard(PaletteCard(
            researchItemId: original.researchItemId, title: original.title,
            kind: original.kind, swatches: ["#112233"],
            notes: [PaletteCard.SensoryNote(sense: .sound, text: "the roar")],
            imagePaths: original.imagePaths, body: original.body))

        model.setScrapText("The falls at night\n\nAnd the ponchos.", for: a)
        let existing = Promotion.existingArtifact(for: .scrap(a), target: .paletteCard,
                                                  in: model.scene, artifacts: index(store))
        _ = try await performer.perform(
            plan(.scrap(a), .paletteCard, store: store, model: model, mode: existing!))

        let updated = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == first.createdItemID })
        XCTAssertEqual(updated.swatches, ["#112233"])
        XCTAssertEqual(updated.notes.first?.text, "the roar")
        XCTAssertTrue(updated.body.contains("And the ponchos."))
        _ = root
    }

    // MARK: - A second promotion to a DIFFERENT target may not eat the first

    /// **The whole destructive sequence, end to end.** Promote a card to a
    /// palette card, give the card swatches and a sensory note the way a writer
    /// would, then promote the same card as a **research note**.
    ///
    /// Before the kind term, the mark resolved for every updatable target: the
    /// sheet offered "Rewrite “The falls at night”", previewed "Goes to: the
    /// existing “The falls at night”" — both sentences literally true — and
    /// committing sent `performResearchNote`'s `.update` branch at the palette
    /// card, which renamed its backing file and wrote raw scrap text over it.
    /// The swatches, the kind, the sensory notes and the `<slug>_assets/` image
    /// references all went, and ⌘Z takes back only the mark, so there was no
    /// route back.
    ///
    /// Two halves, and both are needed: **the sheet never offers it** (the model
    /// half) and **the performer refuses it anyway** (the plan is a snapshot and
    /// the artifact can change under it). The control is the last block: the
    /// promotion the writer actually asked for still lands.
    func test_aResearchNotePromotionCannotOverwriteThePaletteCardTheCardMade() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            plan(.scrap(a), .paletteCard, store: store, model: model, kind: .location))
        let cardID = try XCTUnwrap(first.createdItemID)

        let original = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == cardID })
        try await store.updatePaletteCard(PaletteCard(
            researchItemId: cardID, title: original.title, kind: original.kind,
            swatches: ["#112233"],
            notes: [PaletteCard.SensoryNote(sense: .sound, text: "the roar")],
            imagePaths: original.imagePaths, body: original.body))

        // 1. The sheet never offers the rewrite.
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                in: model.scene, artifacts: index(store)),
                     "the mark names a palette card; a research-note promotion "
                     + "must not offer to rewrite it")

        // 2. And a plan that names it anyway — a stale snapshot, or a hand-built
        //    one — is refused rather than trusted.
        let overwrite = PromotionPlan(
            source: .scrap(a), producedKind: .researchNote,
            title: "The falls at night", body: "raw scrap text",
            destinationDescription: "the existing “The falls at night”",
            discards: [], offeredLinks: [], wikiLinkWrite: nil,
            mode: .update(itemID: cardID, title: "The falls at night"),
            paletteKind: .other, contributors: [], linkAlreadyPresent: false, pictures: [])
        do {
            _ = try await performer.perform(overwrite)
            XCTFail("expected a refusal")
        } catch PromotionFailure.artifactIsADifferentKind(let itemID, _) {
            XCTAssertEqual(itemID, cardID)
        }

        // 3. The writer's work is all still there.
        let after = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == cardID })
        XCTAssertEqual(after.swatches, ["#112233"])
        XCTAssertEqual(after.notes.first?.text, "the roar")
        XCTAssertEqual(after.kind, .location)
        XCTAssertTrue(after.body.contains("Sodium light on the spray."))
        XCTAssertFalse(after.body.contains("raw scrap text"))
        XCTAssertEqual(after.title, "The falls at night")

        // 4. The control: the promotion this card CAN update still lands, so the
        //    guard narrowed the rule rather than breaking updates.
        model.setScrapText("The falls at night\n\nAnd the ponchos.", for: a)
        let legitimate = try XCTUnwrap(
            Promotion.existingArtifact(for: .scrap(a), target: .paletteCard,
                                       in: model.scene, artifacts: index(store)))
        _ = try await performer.perform(
            plan(.scrap(a), .paletteCard, store: store, model: model, mode: legitimate,
                 kind: .location))
        let updated = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == cardID })
        XCTAssertTrue(updated.body.contains("And the ponchos."))
        XCTAssertEqual(updated.swatches, ["#112233"])
    }

    /// The sharper variant: the craft-intent doc ACCUMULATES, so a research-note
    /// "update" over it replaces the writer's whole intent statement with one
    /// card — which is precisely what excluding `.intentStatement` from
    /// `updatableTargets` exists to prevent, arriving through the other door.
    func test_aResearchNotePromotionCannotOverwriteTheCraftIntent() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        _ = try await performer.perform(
            plan(.scrap(a), .intentStatement, store: store, model: model))
        let intent = try XCTUnwrap(store.craftIntentItem(forPieceId: nil))
        let before = try body(of: intent, in: root)

        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                in: model.scene, artifacts: index(store)))
        let overwrite = PromotionPlan(
            source: .scrap(a), producedKind: .researchNote, title: "Craft Intent",
            body: "one card's worth of text",
            destinationDescription: "the existing “Craft Intent”", discards: [],
            offeredLinks: [], wikiLinkWrite: nil,
            mode: .update(itemID: intent.id, title: "Craft Intent"),
            paletteKind: .other, contributors: [], linkAlreadyPresent: false, pictures: [])
        do {
            _ = try await performer.perform(overwrite)
            XCTFail("expected a refusal")
        } catch PromotionFailure.artifactIsADifferentKind {}
        XCTAssertEqual(try body(of: intent, in: root), before,
                       "the writer's accumulated intent statement is untouched")
    }

    /// The control for the guard itself: an update whose mark really does name a
    /// plain research note is not refused. Without this, throwing
    /// unconditionally would satisfy both refusal tests above.
    func test_theKindGuardDoesNotRefuseAnOrdinaryNoteUpdate() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            plan(.scrap(a), .researchNote, store: store, model: model))
        model.setScrapText("The falls at night\n\nAnd the ponchos.", for: a)
        let existing = try XCTUnwrap(
            Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                       in: model.scene, artifacts: index(store)))
        let second = try await performer.perform(
            plan(.scrap(a), .researchNote, store: store, model: model, mode: existing))
        XCTAssertEqual(second.createdItemID, first.createdItemID)
        XCTAssertTrue(try body(of: item("The falls at night", in: store), in: root)
                        .contains("And the ponchos."))
        _ = root
    }

    /// The palette path is the one that escaped the flush:
    /// `paletteCoordinatedWrite` does not flush either, so a 750 ms
    /// `scheduleFileSave` queued while the writer was editing the card in the
    /// research pane would land AFTER the promotion and restore the old prose.
    ///
    /// The queue is drained EXPLICITLY at the end rather than waited out: if the
    /// promotion did not flush first, the stale payload is still sitting in the
    /// scheduler and this flush is what puts it back — so the test fails on the
    /// defect rather than on the clock.
    func test_aQueuedResearchPaneSaveCannotUndoAPalettePromotion() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            plan(.scrap(a), .paletteCard, store: store, model: model))
        let itemID = try XCTUnwrap(first.createdItemID)
        let cardPath = try XCTUnwrap(
            TreeWalk.find(id: itemID, in: store.manifest.research)?.path)
        let ds = try XCTUnwrap(store.documentStore)

        ds.scheduleFileSave(for: cardPath,
                            text: "# The falls at night\n\nSodium light on the spray.\n")

        model.setScrapText("The falls at night\n\nAnd the ponchos.", for: a)
        let existing = Promotion.existingArtifact(for: .scrap(a), target: .paletteCard,
                                                  in: model.scene, artifacts: index(store))
        _ = try await performer.perform(
            plan(.scrap(a), .paletteCard, store: store, model: model, mode: existing!))

        try await ds.flushPendingSave()
        let text = try String(contentsOf: root.appendingPathComponent(cardPath),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("And the ponchos."))
        XCTAssertFalse(text.contains("Sodium light on the spray."),
                       "a promotion that appears to succeed and then silently reverts "
                       + "is worse than one that refuses")
    }

    // MARK: - Scrap → craft intent

    func test_promotingToAnIntentAppendsRatherThanReplacing() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        _ = try await performer.perform(
            plan(.scrap(a), .intentStatement, store: store, model: model))
        _ = try await performer.perform(
            plan(.scrap(b), .intentStatement, store: store, model: model))

        let intent = try XCTUnwrap(store.craftIntentItem(forPieceId: nil))
        let text = try body(of: intent, in: root)
        XCTAssertTrue(text.contains("Sodium light on the spray."))
        XCTAssertTrue(text.contains("October's doctor"),
                      "an intent doc accumulates; the second statement must not "
                      + "replace the first")
        XCTAssertEqual(TreeWalk.collect(in: store.manifest.research,
                                        where: { $0.role == .craftIntent }).count, 1)
    }

    // MARK: - Region → palette card, and the offer (§6.1)

    private func promoteBothScraps(_ store: ProjectStore, _ model: CanvasModel) async throws {
        let performer = PromotionPerformer(store: store, model: model)
        for id in [a, b] {
            _ = try await performer.perform(
                plan(.scrap(id), .researchNote, store: store, model: model))
        }
    }

    func test_aDeclinedOfferWritesNoLinksAtAll() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        let p = plan(.region(r1), .paletteCard, store: store, model: model)
        XCTAssertEqual(p.offeredLinks.count, 2)
        XCTAssertFalse(p.linksAccepted)

        let result = try await PromotionPerformer(store: store, model: model).perform(p)
        XCTAssertTrue(result.writtenLinks.isEmpty)
        for item in TreeWalk.collect(in: store.manifest.research, where: { $0.type == .asset })
        where item.path?.hasSuffix(".md") == true {
            XCTAssertFalse(try body(of: item, in: root).contains("[["),
                           "a declined offer must write nothing at all")
        }
    }

    func test_anAcceptedOfferWritesExactlyTheOfferedLinks() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        var p = plan(.region(r1), .paletteCard, store: store, model: model)
        p.linksAccepted = true

        let result = try await PromotionPerformer(store: store, model: model).perform(p)
        XCTAssertEqual(Set(result.writtenLinks), [a, b])
        XCTAssertTrue(try body(of: item("The falls at night", in: store), in: root)
                        .contains("[[Act II fog]]"),
                      "the member's own note points AT the artifact the region produced")
    }

    /// `writtenLinks` is what the sheet will show the writer, so it reports what
    /// was WRITTEN and not what was offered. A member whose note already holds
    /// the link is skipped — and must not be counted.
    func test_theResultReportsTheLinksWrittenAndNotTheOnesOffered() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        let noteA = try item("The falls at night", in: store)
        let urlA = root.appendingPathComponent(noteA.path ?? "")
        try (try String(contentsOf: urlA, encoding: .utf8) + "\n\n[[Act II fog]]\n")
            .write(to: urlA, atomically: true, encoding: .utf8)

        var p = plan(.region(r1), .paletteCard, store: store, model: model)
        p.linksAccepted = true
        XCTAssertEqual(p.offeredLinks.count, 2, "both were offered")

        let result = try await PromotionPerformer(store: store, model: model).perform(p)
        XCTAssertEqual(result.writtenLinks, [b],
                       "the skipped member must not be reported as linked")
        let text = try body(of: item("The falls at night", in: store), in: root)
        XCTAssertEqual(text.components(separatedBy: "[[Act II fog]]").count - 1, 1,
                       "and it is still linked exactly once")
    }

    /// The one branch that picks its undo name conditionally, so it is the one
    /// that needs the name asserted — the two hardcoded names are asserted
    /// above.
    func test_promotingARegionMarksTheRegionUnderTheRegionsOwnUndoName() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.region(r1), .paletteCard, store: store, model: model))
        XCTAssertEqual(model.scene.region(r1)?.promotedItemID, result.createdItemID)
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promote Region"),
                      "found: \(model.undoManager.undoMenuItemTitle)")
        _ = root
    }

    // MARK: - Region → research note (spec §6's 2026-07-29 amendment)

    /// The end-to-end wiring for the region's new target: a real note, joining
    /// the residents' bodies in reading order — the same join
    /// `test_regionPromotionJoinsItsResidentsInReadingOrder` (`PromotionTests`)
    /// already pins as a pure plan; this is the performer actually writing it.
    func test_promotingARegionToAResearchNoteCreatesARealNoteJoiningItsMembers() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.region(r1), .researchNote, store: store, model: model))

        let created = try item("Act II fog", in: store)
        XCTAssertEqual(result.createdItemID, created.id)
        let text = try body(of: created, in: root)
        XCTAssertTrue(text.contains("The falls at night"))
        XCTAssertTrue(text.contains("October's doctor"))
    }

    /// **RED before this task's fix**: `performResearchNote`'s mark used a
    /// hardcoded `"Promote Scrap"`, which was correct only while a scrap was
    /// the sole source that could reach it. Now that a region can too, the
    /// undo name has to distinguish sources the same way
    /// `performPaletteCard` already does — this is the twin of
    /// `test_promotingARegionMarksTheRegionUnderTheRegionsOwnUndoName` for the
    /// new target.
    func test_promotingARegionToAResearchNoteMarksItUnderTheRegionsOwnUndoName() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.region(r1), .researchNote, store: store, model: model))
        XCTAssertEqual(model.scene.region(r1)?.promotedItemID, result.createdItemID)
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promote Region"),
                      "a region's mark must read \"Promote Region\", not \"Promote "
                      + "Scrap\", however it reaches performResearchNote. found: "
                      + model.undoManager.undoMenuItemTitle)
        _ = root
    }

    // MARK: - Line → wiki-link

    func test_promotingALineAppendsOneLinkToTheFromEndsNote() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        model.mutate("Label Line") {
            $0.updateLine(l1) { $0.label = "because of the ponchos" }
        }
        _ = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.line(l1), .wikiLink, store: store, model: model))

        let textA = try body(of: item("The falls at night", in: store), in: root)
        XCTAssertTrue(textA.contains("[[October's doctor]] — because of the ponchos"))
        XCTAssertTrue(textA.contains("Sodium light on the spray."),
                      "appending must not replace the note")
        XCTAssertFalse(try body(of: item("October's doctor", in: store), in: root)
                        .contains("[["),
                       "a line writes ONE link, into the from end — not both ways")
    }

    /// The plan's `destinationBody` is a snapshot taken when the sheet opened.
    /// The performer checks the LIVE file, because the writer may have promoted
    /// the same line from another window in between.
    func test_aSecondPromotionOfTheSameLineIsRefusedAgainstTheLiveFile() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        let performer = PromotionPerformer(store: store, model: model)
        let p = plan(.line(l1), .wikiLink, store: store, model: model)
        _ = try await performer.perform(p)
        do {
            _ = try await performer.perform(p)     // the same stale plan
            XCTFail("expected a refusal")
        } catch PromotionFailure.linkAlreadyPresent {
            let text = try body(of: item("The falls at night", in: store), in: root)
            XCTAssertEqual(text.components(separatedBy: "[[October's doctor]]").count - 1, 1)
        }
    }

    /// The scene assertions alone cannot see the likely bug: node `a`'s existing
    /// mark IS the wiki-link's `intoItemID`, so a regression that re-marked the
    /// from-node with it would leave them true. The discriminator is the undo
    /// stack — an unrelated step is put on top first, and a promotion that
    /// marked either card would push a "Promote" step over it.
    func test_aLinePromotionLeavesNoMarkAndRegistersNoStep() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        try await promoteBothScraps(store, model)
        let before = (model.scene.node(a)?.promotedItemID, model.scene.node(b)?.promotedItemID)
        model.mutate("Label Line") { $0.updateLine(l1) { $0.label = "the ponchos" } }

        _ = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.line(l1), .wikiLink, store: store, model: model))

        XCTAssertEqual(model.scene.node(a)?.promotedItemID, before.0,
                       "a line's artifact is text inside somebody else's note; there "
                       + "is nothing on the line to mark")
        XCTAssertEqual(model.scene.node(b)?.promotedItemID, before.1)
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Label Line"),
                      "a line promotion registers no step of its own; the top of the "
                      + "stack must still be the edit made before it. found: "
                      + model.undoManager.undoMenuItemTitle)
        _ = root
    }

    // MARK: - Failure leaves nothing behind

    /// Constitution must #1, on the append paths. "No file there" is legitimately
    /// empty — a just-created note is zero bytes — but a file that EXISTS and
    /// will not read must refuse, because every caller appends to what the read
    /// returned and writes the result back. Swallowed, the note becomes the link
    /// and nothing else.
    ///
    /// The failure is a real one and not a stub: invalid UTF-8 on disk, which is
    /// what a decoding failure or a half-materialised iCloud file looks like from
    /// the read's side. `FileManager.fileExists` says yes; `String(contentsOf:)`
    /// throws.
    func test_anUnreadableDestinationRefusesRatherThanOverwritingIt() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        let noteA = try item("The falls at night", in: store)
        let urlA = root.appendingPathComponent(noteA.path ?? "")
        let corrupt = Data([0x54, 0x68, 0x65, 0xFF, 0xFE, 0x0A])
        try corrupt.write(to: urlA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path),
                      "present, not absent — that is the whole distinction")

        do {
            _ = try await PromotionPerformer(store: store, model: model)
                .perform(plan(.line(l1), .wikiLink, store: store, model: model))
            XCTFail("expected a refusal")
        } catch PromotionFailure.unreadableFile {
            XCTAssertEqual(try Data(contentsOf: urlA), corrupt,
                           "the words are safe: a read we could not trust must not "
                           + "become a write")
        }
    }

    /// The control for the test above: an EMPTY destination is not a failure.
    /// `addResearchTextNote` writes a zero-byte file and the craft intent is
    /// created empty, so a `readBody` that threw on absence would refuse the
    /// first promotion a writer ever makes.
    func test_anEmptyDestinationIsWrittenRatherThanRefused() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        _ = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .intentStatement, store: store, model: model))
        let intent = try XCTUnwrap(store.craftIntentItem(forPieceId: nil))
        XCTAssertTrue(try body(of: intent, in: root).contains("Sodium light on the spray."))
    }

    /// The other half of `readBody`'s "absent is not unreadable" rule, and the
    /// one the existing empty-destination control cannot reach:
    /// `addResearchTextNote` writes a **zero-byte file**, so that test exercises
    /// an existing empty file and never `fileExists == false`.
    ///
    /// Here the file is deleted out from under a live manifest entry — the
    /// manifest/disk drift the rule is written for. It must read as empty and
    /// append, not throw: the branch it guards is the one where a truncating
    /// write would cost the writer their words, so its two directions have to be
    /// told apart by test rather than by reading.
    func test_aDestinationFileThatIsGenuinelyAbsentReadsAsEmptyRatherThanThrowing() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        let noteA = try item("The falls at night", in: store)
        let urlA = root.appendingPathComponent(noteA.path ?? "")
        try FileManager.default.removeItem(at: urlA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlA.path),
                       "absent, not present-and-unreadable — that is the whole "
                       + "distinction, and it is the opposite fixture to "
                       + "test_anUnreadableDestinationRefusesRatherThanOverwritingIt")

        _ = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.line(l1), .wikiLink, store: store, model: model))
        XCTAssertEqual(try String(contentsOf: urlA, encoding: .utf8),
                       "\n\n[[October's doctor]]\n",
                       "an absent file is legitimately empty and the append lands "
                       + "on it; a `readBody` that threw here would refuse a "
                       + "promotion for a file nobody has lost anything to")
    }

    // MARK: - The result reaches the writer

    /// **Every field of `PromotionResult` was built and discarded** at the only
    /// call site, while `writeOfferedLinks`'s doc comment said the count
    /// "reaches the writer". It reached nobody. This is the sentence that
    /// reaches them, driven off real results rather than hand-built ones.
    func test_theConfirmationNamesWhatWasProducedAndCountsTheLinksWritten() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        var p = plan(.region(r1), .paletteCard, store: store, model: model)
        p.linksAccepted = true
        let result = try await PromotionPerformer(store: store, model: model).perform(p)
        XCTAssertEqual(result.confirmation(for: p),
                       "Promoted to the palette card “Act II fog”. Linked 2 notes to it.")
        _ = root
    }

    /// The count is what was WRITTEN, not what was offered — the same rule
    /// `writtenLinks` already follows, now that a writer can read it.
    func test_theConfirmationCountsOnlyTheLinksThatWereActuallyWritten() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        let noteA = try item("The falls at night", in: store)
        let urlA = root.appendingPathComponent(noteA.path ?? "")
        try (try String(contentsOf: urlA, encoding: .utf8) + "\n\n[[Act II fog]]\n")
            .write(to: urlA, atomically: true, encoding: .utf8)
        var p = plan(.region(r1), .paletteCard, store: store, model: model)
        p.linksAccepted = true
        XCTAssertEqual(p.offeredLinks.count, 2, "both were offered")

        let result = try await PromotionPerformer(store: store, model: model).perform(p)
        XCTAssertTrue(result.confirmation(for: p).hasSuffix("Linked 1 note to it."),
                      "found: \(result.confirmation(for: p))")
    }

    func test_aDeclinedOfferSaysNothingAboutLinks() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        let p = plan(.region(r1), .paletteCard, store: store, model: model)
        let result = try await PromotionPerformer(store: store, model: model).perform(p)
        XCTAssertEqual(result.confirmation(for: p),
                       "Promoted to the palette card “Act II fog”.",
                       "\"linked 0 notes\" on a declined offer is noise")
        _ = root
    }

    /// **The line is the one that needed this most**: a wiki-link promotion sets
    /// no mark by design, so without a confirmation the sheet closed and nothing
    /// observable changed anywhere — no stripe, no navigation, and the link in a
    /// note the writer would have to go and find.
    func test_aLinePromotionConfirmsWhereTheLinkWent() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        let p = plan(.line(l1), .wikiLink, store: store, model: model)
        let result = try await PromotionPerformer(store: store, model: model).perform(p)
        XCTAssertEqual(result.confirmation(for: p),
                       "Wrote the link into the note “The falls at night”.")
        _ = root
    }

    func test_anIntentPromotionConfirmsThatItWasAddedToTheIntent() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let p = plan(.scrap(a), .intentStatement, store: store, model: model)
        let result = try await PromotionPerformer(store: store, model: model).perform(p)
        XCTAssertEqual(result.confirmation(for: p),
                       "Added to the project's craft intent, at the end of what "
                       + "is already there.")
        _ = root
    }

    /// **The confirmation and the preview were two spellings, and this slice
    /// made them contradict.** `confirmation(for:)` said "Added to the project's
    /// craft intent." unconditionally — written while an intent was always the
    /// project's — and 1C-c2a taught `craftIntentDestination` to scope one to a
    /// Collection loose piece. So in a Collection the sheet said *"Story A"'s
    /// craft intent*, the writer committed, and the banner a second later named
    /// the project's, sending them to look in the wrong `research/`. The arm
    /// reads the plan's own resolved sentence now, so there is nothing left to
    /// drift.
    ///
    /// Driven off `Promotion`'s real destination rather than a hand-built
    /// string, or the test would pin the same two spellings it exists to
    /// collapse.
    func test_theIntentConfirmationIsThePlansOwnDestinationAndNotASecondSpelling() {
        for piece: PromotionPiece in [
            .none,
            .routed(id: "p", title: "Story A", route: .ownResearch),
            .routed(id: "c", title: "Chapter Three", route: .sharedPlusLink),
        ] {
            let destination = Promotion.craftIntentDestination(piece)
            let p = PromotionPlan(
                source: .scrap(a), producedKind: .intentStatement, title: "T",
                body: "Sodium light.", destinationDescription: destination,
                discards: [], offeredLinks: [], wikiLinkWrite: nil, mode: .new,
                paletteKind: .other, contributors: [], linkAlreadyPresent: false, pictures: [])
            let sentence = PromotionResult(createdItemID: "res-1", title: "Craft intent",
                                           writtenLinks: []).confirmation(for: p)
            XCTAssertEqual(sentence, "Added to \(destination).")
            XCTAssertTrue(sentence.contains(destination),
                          "the banner must not restate what the sheet resolved — "
                          + "found: \(sentence)")
        }
        XCTAssertTrue(
            Promotion.craftIntentDestination(
                .routed(id: "p", title: "Story A", route: .ownResearch))
                .contains("“Story A”"),
            "and the piece-scoped route really does name the piece, or the "
            + "contradiction this pins could not have happened")
    }

    // MARK: - Who is asked for a name

    /// `performCraftIntent` never reads `plan.title`, so `validate` must not
    /// demand one — the sheet stopped asking in the same edit, and a performer
    /// that still refused would make the sheet's Promote button write a failure
    /// alert instead of an intent.
    func test_anIntentPromotionWithNoTitleStillLands() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        var p = plan(.scrap(a), .intentStatement, store: store, model: model)
        p.title = ""
        _ = try await PromotionPerformer(store: store, model: model).perform(p)
        let intent = try XCTUnwrap(store.craftIntentItem(forPieceId: nil))
        XCTAssertTrue(try body(of: intent, in: root).contains("Sodium light on the spray."))
    }

    /// The control: an EMPTY BODY is still refused for an intent, so dropping
    /// the title guard did not drop the whole arm.
    func test_anIntentPromotionWithNoBodyIsStillRefused() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let empty = PromotionPlan(
            source: .scrap(a), producedKind: .intentStatement, title: "T", body: "   ",
            destinationDescription: "the project's craft intent", discards: [],
            offeredLinks: [], wikiLinkWrite: nil, mode: .new,
            paletteKind: .other, contributors: [], linkAlreadyPresent: false, pictures: [])
        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(empty)
            XCTFail("expected a refusal")
        } catch PromotionFailure.emptyBody(_) {
            XCTAssertTrue(store.manifest.research.isEmpty)
        }
        _ = root
    }

    func test_anEmptyTitleThrowsAndCreatesNothing() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let blank = PromotionPlan(
            source: .scrap(a), producedKind: .researchNote, title: "  ", body: "something",
            destinationDescription: "research/", discards: [], offeredLinks: [],
            wikiLinkWrite: nil, mode: .new, paletteKind: .other,
            contributors: [], linkAlreadyPresent: false, pictures: [])
        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(blank)
            XCTFail("expected a refusal")
        } catch PromotionFailure.emptyTitle {
            XCTAssertTrue(store.manifest.research.isEmpty)
            XCTAssertNil(try XCTUnwrap(model.scene.node(a)).promotedItemID,
                     "and no mark either")
        }
        _ = root
    }

    func test_aPlanRefusedByTheSheetIsRefusedHereToo() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let already = PromotionPlan(
            source: .line(l1), producedKind: .wikiLink, title: "T", body: "[[X]]",
            destinationDescription: "the note “T”", discards: [], offeredLinks: [],
            wikiLinkWrite: WikiLinkWrite(intoNode: a, intoItemID: "res-x", linkText: "[[X]]"),
            mode: .new, paletteKind: .other, contributors: [], linkAlreadyPresent: true, pictures: [])
        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(already)
            XCTFail("expected a refusal")
        } catch PromotionFailure.linkAlreadyPresent {}
        _ = root
    }
}
