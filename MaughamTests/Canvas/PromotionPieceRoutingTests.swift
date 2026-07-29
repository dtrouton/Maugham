import XCTest
import MaughamCore
@testable import Maugham

/// Spec §6.2: a scrap's (or its home region's) piece association decides **where
/// a promotion lands** — and the deciding is `ResearchScope.route`'s, not this
/// area's. The performer passes a scope; the routing that has shipped since the
/// 2026-07-07 scoped-research milestone does the rest.
///
/// **These tests assert where the file actually landed and whether a link record
/// exists**, never that a particular scope value was passed in. A test of the
/// argument would pass against a broken route, and the writer's complaint is
/// about the note not being in the piece — which is a fact about the disk and the
/// manifest.
///
/// Four project shapes, because the four rows of §6.2's table are four different
/// answers to the same act:
///
/// | Project | Route | Where the note lands |
/// |---|---|---|
/// | Collection, loose piece | `.pieceFolder` | the piece's own `research/`, no link |
/// | Novel | `.sharedPlusLink` | shared `research/` **plus** a link record |
/// | Short story / screenplay | `.sharedOnly` | shared `research/`, no link |
/// | (no association) | — | shared `research/`, no link |
@MainActor
final class PromotionPieceRoutingTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let r1 = CanvasRegionID("r1")

    /// `ProjectStore.documentStore` is a WEAK var, so the test has to hold the
    /// stores it wires. Closed in `tearDown`.
    private var documentStores: [DocumentStore] = []

    /// `TempDirectory` removes its tree on teardown.
    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for ds in documentStores { await ds.close() }
        documentStores = []
        temp = nil
    }

    // MARK: - Fixtures

    /// A hand-built single-document project of the given type
    /// (`ResearchScopeTests.makeProject`'s pattern), with a real `DocumentStore`
    /// wired the way `PromotionPerformerTests.makeProject` does — the palette
    /// group is a research GROUP, and `addResearchItem` refuses to create one
    /// without a `DocumentStore`.
    private func makeProject(type: ProjectType) async throws -> (URL, ProjectStore) {
        let tmp = temp.url.appendingPathComponent("PPR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for sub in ["manuscript", "research"] {
            try FileManager.default.createDirectory(
                at: tmp.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try "Chapter 1\n".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                                atomically: true, encoding: .utf8)
        let chapter = StructureItem(id: "ch-1", title: "Chapter 1", type: .document,
                                    path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: type, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [chapter], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds
        documentStores.append(ds)
        return (tmp, store)
    }

    /// A real Collection with one LOOSE piece — the shape that motivates the
    /// whole task, and the only one `pieceResearchPrefix` answers for.
    private func makeCollection() async throws -> (URL, ProjectStore, StructureItem) {
        let parent = temp.url.appendingPathComponent("PPRC-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "C", in: parent)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        return (url, store, piece)
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
        }
        model.setScrapText("The falls at night\n\nSodium light on the spray.", for: a)
        model.setScrapText("October's doctor\n\nShe knows the river.", for: b)
        return model
    }

    private func plan(_ source: PromotionSource, _ target: PromotionTarget,
                      store: ProjectStore, model: CanvasModel,
                      mode: PromotionMode = .new,
                      kind: PaletteCard.Kind = .other) -> PromotionPlan {
        Promotion.plan(
            PromotionRequest(source: source, target: target, mode: mode,
                             scraps: model.scraps, paletteKind: kind,
                             artifacts: ArtifactIndex.over(research: store.manifest.research)),
            in: model.scene)!
    }

    /// The created item, resolved off the live manifest — and its file asserted
    /// to be REALLY THERE. "The manifest says `pieces/01-story-a/research/…`" and
    /// "the note is in the piece's folder" are the same claim only if the file
    /// exists at that path.
    private func landed(_ result: PromotionResult,
                        in store: ProjectStore, root: URL) throws -> ResearchItem {
        let id = try XCTUnwrap(result.createdItemID)
        let item = try XCTUnwrap(TreeWalk.find(id: id, in: store.manifest.research))
        let path = try XCTUnwrap(item.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(path).path),
                      "the manifest says \(path) and nothing is there")
        return item
    }

    private func craftIntents(in store: ProjectStore) -> [ResearchItem] {
        TreeWalk.collect(in: store.manifest.research, where: { $0.role == .craftIntent })
    }

    private func text(of item: ResearchItem, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(item.path ?? ""), encoding: .utf8)
    }

    // MARK: - Research note: the four shapes

    /// The case the writer asked for. A Collection loose piece keeps its research
    /// in its own folder — containment, which travels with the piece — so the
    /// note is created there and NO link record is written: containment and a
    /// link double-counting the same pair is what the 2026-07-17 dormant-link
    /// rule exists to stop.
    func test_aScrapBoundToACollectionLoosePiecePutsTheNoteInThatPiecesOwnResearch() async throws {
        let (root, store, piece) = try await makeCollection()
        let model = makeModel(at: root)
        model.withScene { $0.setBoundPiece(piece.id, for: a) }

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        let item = try landed(result, in: store, root: root)
        XCTAssertTrue(item.path?.hasPrefix(prefix) == true,
                      "expected the note under \(prefix); got: \(item.path ?? "nil")")
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: piece.id), [],
                       "containment must not ALSO write a link record")
    }

    /// A novel has no per-chapter research folder, so the association becomes a
    /// link record — written by `route` itself, not by anything here.
    func test_aScrapBoundToANovelChapterPutsTheNoteInSharedResearchAndLinksIt() async throws {
        let (root, store) = try await makeProject(type: .novel)
        let model = makeModel(at: root)
        model.withScene { $0.setBoundPiece("ch-1", for: a) }

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        let item = try landed(result, in: store, root: root)
        XCTAssertTrue(item.path?.hasPrefix("research/") == true,
                      "got: \(item.path ?? "nil")")
        XCTAssertTrue(store.linkedResearchIds(forDocumentId: "ch-1").contains(item.id),
                      "a novel chapter's association IS the link record; without it "
                      + "the note is not that chapter's by any surface that reads the "
                      + "manifest")
    }

    /// A short story is one document, and derivation already surfaces every
    /// shared research item as that document's — so a link here would be
    /// redundant, and redundancy in this layer is double-counting.
    func test_aScrapBoundToAShortStorysDocumentPutsTheNoteInSharedResearchWithNoLink() async throws {
        let (root, store) = try await makeProject(type: .shortStory)
        let model = makeModel(at: root)
        model.withScene { $0.setBoundPiece("ch-1", for: a) }

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        let item = try landed(result, in: store, root: root)
        XCTAssertTrue(item.path?.hasPrefix("research/") == true,
                      "got: \(item.path ?? "nil")")
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), [],
                       "single-doc derivation covers it")
    }

    /// The ordinary case, and the control for all three above: no association is
    /// not an error and not a fallback with an apology — in a novel the writer is
    /// not thinking in pieces at all.
    func test_aScrapWithNoAssociationAtAllPutsTheNoteInSharedResearchWithNoLink() async throws {
        let (root, store) = try await makeProject(type: .novel)
        let model = makeModel(at: root)

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        let item = try landed(result, in: store, root: root)
        XCTAssertTrue(item.path?.hasPrefix("research/") == true,
                      "got: \(item.path ?? "nil")")
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), [])
    }

    // MARK: - The precedence resolver is what the performer asks

    /// The scrap carries nothing of its own; its HOME region does. A performer
    /// that read `node.boundPieceID` directly would pass every one of the tests
    /// above and fail this one — which is the whole reason `Promotion.piece` is a
    /// resolver and not a field read.
    func test_aScrapInheritsItsHomeRegionsPieceWhenDecidingWhereTheNoteGoes() async throws {
        let (root, store) = try await makeProject(type: .novel)
        let model = makeModel(at: root)
        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "ch-1" } }
        XCTAssertNil(model.scene.node(a)?.boundPieceID, "nothing of its own")

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        let item = try landed(result, in: store, root: root)
        XCTAssertTrue(store.linkedResearchIds(forDocumentId: "ch-1").contains(item.id))
    }

    /// A region promotes too, and answers with its own association.
    func test_aRegionsOwnPieceDecidesWhereTheRegionsNoteGoes() async throws {
        let (root, store, piece) = try await makeCollection()
        let model = makeModel(at: root)
        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = piece.id } }

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.region(r1), .researchNote, store: store, model: model))

        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        let item = try landed(result, in: store, root: root)
        XCTAssertTrue(item.path?.hasPrefix(prefix) == true,
                      "expected the region's note under \(prefix); got: \(item.path ?? "nil")")
        XCTAssertTrue(try text(of: item, in: root).contains("October's doctor"),
                      "and it is still the joined region, not an empty file in the "
                      + "right place")
    }

    // MARK: - An update changes nothing about where

    /// The artifact already exists where it exists. Re-promoting an existing note
    /// as an update must not move it, and must not retrofit a link — the writer
    /// asked to rewrite a body, and a promotion that quietly re-files their note
    /// is the surprise this whole area is built to avoid.
    func test_anUpdatePromotionNeitherMovesTheNoteNorRetrofitsALink() async throws {
        let (root, store) = try await makeProject(type: .novel)
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            plan(.scrap(a), .researchNote, store: store, model: model))
        let originalPath = try landed(first, in: store, root: root).path

        model.withScene { $0.setBoundPiece("ch-1", for: a) }
        model.setScrapText("The falls at night\n\nAnd the ponchos.", for: a)
        let existing = try XCTUnwrap(Promotion.existingArtifact(
            for: .scrap(a), target: .researchNote, in: model.scene,
            artifacts: ArtifactIndex.over(research: store.manifest.research)))
        let second = try await performer.perform(
            plan(.scrap(a), .researchNote, store: store, model: model, mode: existing))

        XCTAssertEqual(second.createdItemID, first.createdItemID)
        let item = try landed(second, in: store, root: root)
        XCTAssertEqual(item.path, originalPath)
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), [],
                       "an update is about the body; it does not re-file the artifact")
        XCTAssertTrue(try text(of: item, in: root).contains("And the ponchos."))
    }

    // MARK: - Craft intent: the piece only where the routing is .pieceFolder

    /// **The guard, stated as its consequence.** `craftIntentItem(forPieceId:)`
    /// finds an existing intent doc by the piece's research PREFIX, and
    /// `pieceResearchPrefix` is nil for a novel chapter — so an intent doc created
    /// under `.document("ch-1")` (shared + linked) could never be found again, and
    /// every promotion after the first would mint another one.
    ///
    /// Falsified by the disable experiment: pass the piece unconditionally and
    /// this goes red with two docs.
    func test_twoNovelChapterScrapsPromotedToIntentFindTheSameOneIntentDoc() async throws {
        let (root, store) = try await makeProject(type: .novel)
        let model = makeModel(at: root)
        model.withScene {
            $0.setBoundPiece("ch-1", for: a)
            $0.setBoundPiece("ch-1", for: b)
        }
        let performer = PromotionPerformer(store: store, model: model)
        _ = try await performer.perform(
            plan(.scrap(a), .intentStatement, store: store, model: model))
        _ = try await performer.perform(
            plan(.scrap(b), .intentStatement, store: store, model: model))

        XCTAssertEqual(craftIntents(in: store).count, 1,
                       "an intent doc is a singleton per scope; a second one is the "
                       + "writer's intent statement silently split in two")
        let intent = try XCTUnwrap(store.craftIntentItem(forPieceId: nil))
        let body = try text(of: intent, in: root)
        XCTAssertTrue(body.contains("Sodium light on the spray."))
        XCTAssertTrue(body.contains("She knows the river."))
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), [],
                       "the intent takes the scope and NEVER the link: linking the "
                       + "project's intent to one chapter misrepresents what it is")
    }

    /// The control for that guard, and the case that proves it narrowed the rule
    /// rather than deleting it: a Collection loose piece DOES route to
    /// `.pieceFolder`, so its intent doc belongs in the piece — and a second
    /// promotion finds it there.
    func test_twoCollectionPieceScrapsShareOneIntentDocInsideThePiece() async throws {
        let (root, store, piece) = try await makeCollection()
        let model = makeModel(at: root)
        model.withScene {
            $0.setBoundPiece(piece.id, for: a)
            $0.setBoundPiece(piece.id, for: b)
        }
        let performer = PromotionPerformer(store: store, model: model)
        _ = try await performer.perform(
            plan(.scrap(a), .intentStatement, store: store, model: model))
        _ = try await performer.perform(
            plan(.scrap(b), .intentStatement, store: store, model: model))

        XCTAssertEqual(craftIntents(in: store).count, 1)
        let intent = try XCTUnwrap(store.craftIntentItem(forPieceId: piece.id))
        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: piece))
        XCTAssertTrue(intent.path?.hasPrefix(prefix) == true,
                      "expected the piece's own intent doc under \(prefix); got: "
                      + (intent.path ?? "nil"))
        let body = try text(of: intent, in: root)
        XCTAssertTrue(body.contains("Sodium light on the spray."))
        XCTAssertTrue(body.contains("She knows the river."))
        XCTAssertNil(store.craftIntentItem(forPieceId: nil),
                     "and the PROJECT's intent was not the one written to")
    }

    // MARK: - A palette card is never routed

    /// The wall is project-level: whatever the association, the card lives under
    /// the palette group. What the association buys is the link, and only where
    /// the routing would have been `.sharedPlusLink`.
    func test_aNovelChapterBoundScrapsPaletteCardStaysOnTheWallAndTakesTheLink() async throws {
        let (root, store) = try await makeProject(type: .novel)
        let model = makeModel(at: root)
        model.withScene { $0.setBoundPiece("ch-1", for: a) }

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .paletteCard, store: store, model: model, kind: .location))

        let item = try landed(result, in: store, root: root)
        XCTAssertTrue(item.path?.hasPrefix(ProjectStore.paletteFolderPath + "/") == true,
                      "got: \(item.path ?? "nil")")
        XCTAssertTrue(store.paletteCardItems().contains(where: { $0.id == item.id }),
                      "a card that is not under the palette group is not on the wall")
        XCTAssertTrue(store.linkedResearchIds(forDocumentId: "ch-1").contains(item.id))
    }

    /// The piece-folder shape is where "never routed" earns its keep: the note
    /// would have gone into `pieces/…/research/`, and the card must not follow it
    /// there — nor take a link, because that routing writes none.
    func test_aCollectionPieceBoundScrapsPaletteCardStillGoesToTheWallWithNoLink() async throws {
        let (root, store, piece) = try await makeCollection()
        let model = makeModel(at: root)
        model.withScene { $0.setBoundPiece(piece.id, for: a) }

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .paletteCard, store: store, model: model))

        let item = try landed(result, in: store, root: root)
        XCTAssertTrue(item.path?.hasPrefix(ProjectStore.paletteFolderPath + "/") == true,
                      "the wall is project-level; a card in the piece's research "
                      + "folder is off the wall entirely. got: \(item.path ?? "nil")")
        XCTAssertTrue(store.paletteCardItems().contains(where: { $0.id == item.id }))
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: piece.id), [])
    }

    func test_aShortStoryBoundScrapsPaletteCardTakesNoLink() async throws {
        let (root, store) = try await makeProject(type: .shortStory)
        let model = makeModel(at: root)
        model.withScene { $0.setBoundPiece("ch-1", for: a) }

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .paletteCard, store: store, model: model))

        let item = try landed(result, in: store, root: root)
        XCTAssertTrue(item.path?.hasPrefix(ProjectStore.paletteFolderPath + "/") == true)
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: "ch-1"), [],
                       "only `.sharedPlusLink` writes a link, and a short story is "
                       + "`.sharedOnly`")
    }
}
