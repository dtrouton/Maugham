import XCTest
import MaughamCore
@testable import Maugham

/// **Characterisation of `Maugham/Canvas/Promotion*.swift`** — the behavioural
/// claim set `M6-PR-nnn`, one passing assertion per claim.
///
/// Every assertion here was written from OBSERVED output (the probes at
/// `register/history/app-layer-tests/PromotionProbe*.swift`), never from what the code
/// looks like it should do. Three came out against the reading:
/// a promotion that throws has already created and marked its artifact
/// (M6-PR-070), a region's REFERENCED pictures vanish from the plan when the
/// caller omits the item index (M6-PR-055), and `linkAlreadyPresent` is a raw
/// substring test that answers asymmetrically for a labelled line (M6-PR-024).
///
/// **A red test here means PINNED BEHAVIOUR CHANGED.** Check
/// `register/reconciliation/Promotion.filings.json` before "fixing" it: a
/// defect fix must flip its claim and its filing in the same branch.
///
/// House pattern is `PromotionPerformerTests`': a per-file helper, not a shared
/// fixture.
@MainActor
final class PromotionCharacterization: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let c = CanvasNodeID("c")
    private let own = CanvasNodeID("own-1")
    private let own2 = CanvasNodeID("own-2")
    private let ref = CanvasNodeID("ref-1")
    private let r1 = CanvasRegionID("r1")
    private let r2 = CanvasRegionID("r2")
    private let l1 = CanvasLineID("l1")

    private var documentStores: [DocumentStore] = []
    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }
    override func tearDown() async throws {
        for ds in documentStores { await ds.close() }
        documentStores = []
        temp = nil
    }

    // MARK: - Fixtures

    private func makeProject() async throws -> (URL, ProjectStore) {
        let tmp = temp.url.appendingPathComponent("PC-\(UUID())")
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

    private func withChapter(_ root: URL, _ store: ProjectStore) async throws {
        try "Chapter 1\n".write(to: root.appendingPathComponent("manuscript/c1.md"),
                                atomically: true, encoding: .utf8)
        store.manifest.structure = [
            StructureItem(id: "ch-1", title: "Chapter 1", type: .document,
                          path: "manuscript/c1.md")]
        try await store.saveManifest()
    }

    /// Two cards, one region holding both, one line between them.
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
        ArtifactIndex.over(research: store.manifest.research,
                           statements: store.manifest.statements,
                           structure: store.manifest.structure)
    }

    private func ingest(into store: ProjectStore) async throws -> String {
        let source = temp.url.appendingPathComponent("dropped-\(UUID()).png")
        try Data("bytes".utf8).write(to: source)
        return try await store.ingestCanvasAsset(fileURL: source)
    }

    private func request(_ s: PromotionSource, _ t: PromotionTarget,
                         store: ProjectStore, model: CanvasModel,
                         mode: PromotionMode = .new,
                         items: CanvasItemIndex = .empty,
                         paletteCardID: String? = nil,
                         destinationBody: String? = nil,
                         piece: PromotionPiece = .none) -> PromotionRequest {
        PromotionRequest(source: s, target: t, mode: mode, scraps: model.scraps,
                         artifacts: index(store), items: items,
                         destinationBody: destinationBody,
                         paletteCardID: paletteCardID, piece: piece)
    }

    private func plan(_ s: PromotionSource, _ t: PromotionTarget,
                      store: ProjectStore, model: CanvasModel,
                      mode: PromotionMode = .new,
                      items: CanvasItemIndex = .empty,
                      paletteCardID: String? = nil,
                      destinationBody: String? = nil,
                      piece: PromotionPiece = .none) throws -> PromotionPlan {
        try XCTUnwrap(Promotion.plan(
            request(s, t, store: store, model: model, mode: mode, items: items,
                    paletteCardID: paletteCardID, destinationBody: destinationBody,
                    piece: piece),
            in: model.scene))
    }

    private func bodyOf(_ id: String, store: ProjectStore, root: URL) throws -> String {
        let item = try XCTUnwrap(TreeWalk.find(id: id, in: store.manifest.research))
        return try String(contentsOf: root.appendingPathComponent(try XCTUnwrap(item.path)),
                          encoding: .utf8)
    }

    private func failure(_ body: () async throws -> Void) async -> PromotionFailure? {
        do { try await body(); return nil } catch { return error as? PromotionFailure }
    }

    // MARK: - A. What is offered, and what is refused

    /// M6-PR-001, M6-PR-006
    func test_theTargetsEachSourceIsOffered() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        XCTAssertEqual(Promotion.targets(for: .scrap(a), in: model.scene, artifacts: index(store)),
                       [.researchNote, .paletteCard, .intentStatement],
                       "M6-PR-001: a card's three targets, in this order")
        XCTAssertEqual(Promotion.targets(for: .region(r1), in: model.scene, artifacts: index(store)),
                       [.researchNote, .paletteCard],
                       "M6-PR-006: a region is not offered the craft intent")
    }

    /// M6-PR-002 — emptiness is not a targets question.
    func test_anEmptyCardIsOfferedEveryTargetAndPlansNone() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.withScene { $0.insert(CanvasNode(id: c, kind: .scrap, origin: .zero,
                                               width: 100, cachedHeight: 10)) }
        model.setScrapText("   ", for: c)
        XCTAssertEqual(Promotion.targets(for: .scrap(c), in: model.scene, artifacts: index(store)),
                       [.researchNote, .paletteCard, .intentStatement])
        XCTAssertNil(Promotion.plan(request(.scrap(c), .researchNote, store: store, model: model),
                                    in: model.scene))
        XCTAssertEqual(Promotion.blockedReason(for: .scrap(c), in: model.scene,
                                               scraps: model.scraps, artifacts: index(store)),
                       "There is nothing in this card to promote.")
    }

    /// M6-PR-007 — the same shape one row down, in the region's own noun.
    func test_anEmptyRegionIsOfferedEveryTargetAndPlansNone() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.withScene { $0.insertRegion(CanvasRegion(id: r2, label: "",
                                                       frame: CGRect(x: 0, y: 900, width: 100, height: 100),
                                                       homeMembers: [])) }
        XCTAssertEqual(Promotion.targets(for: .region(r2), in: model.scene, artifacts: index(store)),
                       [.researchNote, .paletteCard])
        XCTAssertNil(Promotion.plan(request(.region(r2), .researchNote, store: store, model: model),
                                    in: model.scene))
        XCTAssertEqual(Promotion.blockedReason(for: .region(r2), in: model.scene,
                                               scraps: model.scraps, artifacts: index(store)),
                       "There is nothing in this region to promote.")
    }

    /// M6-PR-003, M6-PR-004, M6-PR-005 — the provenance split.
    func test_aReferencedItemRefusesAndAnOwnedOneIsOfferedTwoRows() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let path = try await ingest(into: store)
        model.withScene {
            $0.insert(CanvasNode(id: ref, kind: .item(.project(id: "res-x")),
                                 origin: CGPoint(x: 900, y: 0), width: 180, cachedHeight: 200))
            $0.insert(CanvasNode(id: own, kind: .item(.owned(path: path)),
                                 origin: CGPoint(x: 900, y: 300), width: 180, cachedHeight: 200))
        }
        XCTAssertEqual(Promotion.targets(for: .scrap(ref), in: model.scene, artifacts: index(store)),
                       [], "M6-PR-003")
        XCTAssertEqual(Promotion.blockedReason(for: .scrap(ref), in: model.scene,
                                               scraps: model.scraps, artifacts: index(store)),
                       Promotion.itemNodeReason, "M6-PR-003")
        XCTAssertEqual(Promotion.targets(for: .scrap(own), in: model.scene, artifacts: index(store)),
                       [.researchAsset],
                       "M6-PR-004: no palette row while the project holds no cards")
        XCTAssertNil(Promotion.blockedReason(for: .scrap(own), in: model.scene,
                                             scraps: model.scraps, artifacts: index(store)),
                     "M6-PR-005: a picture is blocked by nothing")
        _ = try await store.addPaletteCard(title: "Fog", kind: .other)
        XCTAssertEqual(Promotion.targets(for: .scrap(own), in: model.scene, artifacts: index(store)),
                       [.researchAsset, .paletteCardImage], "M6-PR-004")
    }

    /// M6-PR-008, M6-PR-009, M6-PR-010, M6-PR-011 — the line's four states.
    func test_aLineIsOfferedTheWikiLinkOnlyWhenBothEndsResolve() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        XCTAssertEqual(Promotion.targets(for: .line(l1), in: model.scene, artifacts: index(store)), [])
        XCTAssertEqual(Promotion.blockedReason(for: .line(l1), in: model.scene,
                                               scraps: model.scraps, artifacts: index(store)),
                       "Promote both cards first. A wiki-link has to point at something "
                       + "that exists outside the canvas — a canvas line is scratch.",
                       "M6-PR-008")
        model.withScene {
            $0.setPromotedItem("ghost-1", for: a)
            $0.setPromotedItem("ghost-2", for: b)
        }
        XCTAssertEqual(Promotion.blockedReason(for: .line(l1), in: model.scene,
                                               scraps: model.scraps, artifacts: index(store)),
                       "What one of these cards produced is no longer in the "
                       + "project, so there is nothing left for a link to point at. "
                       + "Promote that card again first.",
                       "M6-PR-009: a dangling mark is a different act from never promoting")
        let n1 = try await store.createResearchNote(scope: .shared, title: "From note")
        let n2 = try await store.createResearchNote(scope: .shared, title: "To note")
        model.withScene {
            $0.setPromotedItem(n1.id, for: a)
            $0.setPromotedItem(n2.id, for: b)
        }
        XCTAssertEqual(Promotion.targets(for: .line(l1), in: model.scene, artifacts: index(store)),
                       [.wikiLink], "M6-PR-011")
        XCTAssertNil(Promotion.blockedReason(for: .line(l1), in: model.scene,
                                             scraps: model.scraps, artifacts: index(store)))
        let path = try await ingest(into: store)
        model.withScene {
            $0.insert(CanvasNode(id: own, kind: .item(.owned(path: path)),
                                 origin: CGPoint(x: 400, y: 0), width: 180, cachedHeight: 200))
            $0.insertLine(CanvasLine(id: CanvasLineID("l2"), from: a, to: own))
        }
        XCTAssertEqual(Promotion.blockedReason(for: .line(CanvasLineID("l2")), in: model.scene,
                                               scraps: model.scraps, artifacts: index(store)),
                       "A line becomes a wiki-link only between two cards of text.",
                       "M6-PR-010")
    }

    /// M6-PR-012 — a source the scene does not hold offers nothing AND says nothing.
    func test_aSourceTheSceneDoesNotHoldIsSilent() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let ghost = PromotionSource.scrap(CanvasNodeID("not-in-the-scene"))
        XCTAssertEqual(Promotion.targets(for: ghost, in: model.scene, artifacts: index(store)), [])
        XCTAssertNil(Promotion.blockedReason(for: ghost, in: model.scene,
                                             scraps: model.scraps, artifacts: index(store)))
    }

    // MARK: - B. The plan

    /// M6-PR-013 — the preview is honest because building it touches nothing.
    func test_planningMutatesNeitherTheSceneNorTheWords() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let scene = model.scene
        let scraps = model.scraps
        _ = try plan(.scrap(a), .researchNote, store: store, model: model)
        _ = try plan(.region(r1), .paletteCard, store: store, model: model)
        XCTAssertEqual(scene, model.scene)
        XCTAssertEqual(scraps, model.scraps)
    }

    /// M6-PR-014, M6-PR-015
    func test_aCardsPlanIsItsFirstLineAndItsWholeText() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let pl = try plan(.scrap(a), .researchNote, store: store, model: model)
        XCTAssertEqual(pl.title, "The falls at night", "M6-PR-014")
        XCTAssertEqual(pl.body, "The falls at night\n\nSodium light on the spray.", "M6-PR-014")
        XCTAssertEqual(pl.discards, [], "M6-PR-015: a card loses nothing")
        XCTAssertEqual(pl.contributors, [], "M6-PR-015")
        XCTAssertEqual(pl.pictures.count, 0, "M6-PR-015")
        XCTAssertEqual(pl.offeredLinks.count, 0, "M6-PR-015")
        XCTAssertFalse(pl.linksAccepted, "M6-PR-015: the offer is never pre-accepted")
        XCTAssertEqual(Promotion.title(from: "   Hello there  \nsecond"), "Hello there")
        XCTAssertEqual(Promotion.title(from: ""), "")
    }

    /// M6-PR-016, M6-PR-017, M6-PR-018, M6-PR-019
    func test_aRegionsPlanReadsTopToBottomAndDropsWhatIsEmpty() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        var pl = try plan(.region(r1), .researchNote, store: store, model: model)
        XCTAssertEqual(pl.title, "Act II fog")
        XCTAssertEqual(pl.body,
                       "The falls at night\n\nSodium light on the spray.\n\nOctober's doctor",
                       "M6-PR-016")
        XCTAssertEqual(pl.contributors, [a, b], "M6-PR-016")
        XCTAssertEqual(pl.discards, [.lines, .layout], "M6-PR-018")

        model.withScene { $0.move(b, to: CGPoint(x: 0, y: -500)) }
        pl = try plan(.region(r1), .researchNote, store: store, model: model)
        XCTAssertEqual(pl.body,
                       "October's doctor\n\nThe falls at night\n\nSodium light on the spray.",
                       "M6-PR-016: the joined text reads the way the region reads")
        XCTAssertEqual(pl.contributors, [b, a], "M6-PR-016")
        model.withScene { $0.move(b, to: CGPoint(x: 0, y: 200)) }

        model.withScene {
            $0.insert(CanvasNode(id: c, kind: .scrap, origin: CGPoint(x: 0, y: 400),
                                 width: 100, cachedHeight: 10))
            CanvasMembership.join(c, home: r1, in: &$0)
        }
        model.setScrapText("   ", for: c)
        pl = try plan(.region(r1), .researchNote, store: store, model: model)
        XCTAssertEqual(pl.contributors, [a, b],
                       "M6-PR-017: an empty member contributes nothing and is not recorded")

        model.withScene {
            $0.insertRegion(CanvasRegion(id: r2, label: "   ",
                                         frame: CGRect(x: 0, y: 700, width: 300, height: 300),
                                         homeMembers: []))
            CanvasMembership.join(c, home: r2, in: &$0)
        }
        model.setScrapText("A newcomer", for: c)
        XCTAssertEqual(try plan(.region(r2), .researchNote, store: store, model: model).title,
                       CanvasRegion.untitledLabel, "M6-PR-019")
    }

    /// M6-PR-020 — only a promoted member has anywhere for a link to be written.
    func test_aRegionOffersLinksOnlyForMembersWhoseMarkResolves() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let note = try await store.createResearchNote(scope: .shared, title: "A's note")
        model.withScene {
            $0.setPromotedItem(note.id, for: a)
            $0.setPromotedItem("dangling", for: b)
        }
        let pl = try plan(.region(r1), .researchNote, store: store, model: model)
        XCTAssertEqual(pl.offeredLinks.map(\.node), [a])
        XCTAssertEqual(pl.offeredLinks.first?.title, "A's note")
    }

    /// M6-PR-021, M6-PR-022, M6-PR-023
    func test_aLinePlanWritesIntoTheFromEnd() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let n1 = try await store.createResearchNote(scope: .shared, title: "From note")
        let n2 = try await store.createResearchNote(scope: .shared, title: "To note")
        model.withScene {
            $0.setPromotedItem(n1.id, for: a)
            $0.setPromotedItem(n2.id, for: b)
        }
        var pl = try plan(.line(l1), .wikiLink, store: store, model: model)
        XCTAssertEqual(pl.title, "From note")
        XCTAssertEqual(pl.body, "[[To note]]", "M6-PR-021")
        XCTAssertEqual(pl.destinationDescription, "the note “From note”", "M6-PR-023")
        XCTAssertEqual(pl.wikiLinkWrite?.intoItemID, n1.id, "M6-PR-021")
        XCTAssertEqual(pl.wikiLinkWrite?.appendedText, "\n\n[[To note]]\n", "M6-PR-021")
        XCTAssertEqual(pl.mode, .new)

        model.withScene { $0.updateLine(l1) { $0.label = "why" } }
        pl = try plan(.line(l1), .wikiLink, store: store, model: model)
        XCTAssertEqual(pl.body, "[[To note]] — why", "M6-PR-022")
        XCTAssertEqual(Promotion.linkText(to: "X", label: "   "), "[[X]]", "M6-PR-022")
        model.withScene { $0.updateLine(l1) { $0.label = nil } }

        try await withChapter(root, store)
        let st = try await store.createStatement(kind: .intent, scope: .document("ch-1"))
        model.withScene { $0.setPromotedItem(st.id, for: a) }
        pl = try plan(.line(l1), .wikiLink, store: store, model: model)
        XCTAssertEqual(pl.destinationDescription, "the craft intent “Craft Intent · Chapter 1”",
                       "M6-PR-023: the noun follows the artifact's kind")
    }

    /// M6-PR-024 — the duplicate check compares link TARGETS: promotion never
    /// adds a link to an artifact the destination already points at, under any
    /// label, in either direction (RULING-50, fixed 2026-08-09 — the asymmetric
    /// raw substring test this pin used to record let a plain link's labelled
    /// twin through).
    func test_theDuplicateLinkCheckComparesTargetsNotSpellings() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let n1 = try await store.createResearchNote(scope: .shared, title: "From note")
        let n2 = try await store.createResearchNote(scope: .shared, title: "To note")
        model.withScene {
            $0.setPromotedItem(n1.id, for: a)
            $0.setPromotedItem(n2.id, for: b)
        }
        XCTAssertTrue(try plan(.line(l1), .wikiLink, store: store, model: model,
                               destinationBody: "prose\n\n[[To note]]\n").linkAlreadyPresent)
        XCTAssertTrue(try plan(.line(l1), .wikiLink, store: store, model: model,
                               destinationBody: "prose\n\n[[To note]] — why\n").linkAlreadyPresent,
                      "a LABELLED link in the destination suppresses the plain one")
        XCTAssertFalse(try plan(.line(l1), .wikiLink, store: store, model: model,
                                destinationBody: "prose\n\n[[To notebook]]\n").linkAlreadyPresent)
        model.withScene { $0.updateLine(l1) { $0.label = "why" } }
        XCTAssertTrue(try plan(.line(l1), .wikiLink, store: store, model: model,
                               destinationBody: "prose\n\n[[To note]]\n").linkAlreadyPresent,
                      "and the plain link suppresses the labelled one too — the check "
                      + "compares TARGETS, not spellings (RULING-50, fixed from the "
                      + "asymmetric substring test this pin used to record)")
    }

    /// M6-PR-025, M6-PR-026, M6-PR-027, M6-PR-028 — §6.2's rows, in the sheet's words.
    func test_theDestinationSentenceNamesTheRouteItWillTake() {
        XCTAssertEqual(Promotion.researchNoteDestination(.none), "research/")
        XCTAssertEqual(Promotion.researchNoteDestination(
            .routed(id: "p", title: "Story A", route: .ownResearch)),
                       "“Story A”’s own research/")
        XCTAssertEqual(Promotion.researchNoteDestination(
            .routed(id: "p", title: "Chapter 1", route: .sharedPlusLink)),
                       "research/, linked to “Chapter 1”")
        XCTAssertEqual(Promotion.researchNoteDestination(
            .routed(id: "p", title: "The story", route: .sharedOnly)),
                       "research/, which is already “The story”’s")
        XCTAssertEqual(Promotion.researchNoteDestination(
            .unroutable(id: "p", title: nil, inherited: true)),
                       "nowhere, until the association is fixed", "M6-PR-028")
        XCTAssertEqual(Promotion.paletteCardDestination(
            .routed(id: "p", title: "Chapter 1", route: .sharedPlusLink)),
                       "the palette wall, linked to “Chapter 1”", "M6-PR-026")
        XCTAssertEqual(Promotion.paletteCardDestination(
            .routed(id: "p", title: "Story A", route: .ownResearch)),
                       "the palette wall", "M6-PR-026: a card is never routed")
        XCTAssertEqual(Promotion.craftIntentDestination(
            .routed(id: "p", title: "Chapter 1", route: .sharedOnly)),
                       "“Chapter 1”’s craft intent, at the end of what is already there",
                       "M6-PR-027: it says that it appends")
        XCTAssertEqual(Promotion.craftIntentDestination(.none),
                       "the project's craft intent, at the end of what is already there")
    }

    // MARK: - C. Update or new

    /// M6-PR-029, M6-PR-030, M6-PR-031, M6-PR-032, M6-PR-033, M6-PR-034
    func test_whenARewriteIsOffered() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let note = try await store.createResearchNote(scope: .shared, title: "Note A")
        model.withScene { $0.setPromotedItem(note.id, for: a) }
        XCTAssertEqual(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                  in: model.scene, artifacts: index(store)),
                       .update(itemID: note.id, title: "Note A"), "M6-PR-029")
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .intentStatement,
                                                in: model.scene, artifacts: index(store)),
                     "M6-PR-029: the craft intent accumulates and is never rewritten")
        XCTAssertEqual(Promotion.updatableTargets, [.researchNote, .paletteCard])
        XCTAssertEqual(Promotion.modes(for: .researchNote, existing: .update(itemID: note.id,
                                                                            title: "Note A")),
                       [.new, .update(itemID: note.id, title: "Note A")],
                       "M6-PR-033: .new is never the second item")

        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .paletteCard,
                                                in: model.scene, artifacts: index(store)),
                     "M6-PR-030: a mark of the wrong KIND offers no rewrite")
        let card = try await store.addPaletteCard(title: "Fog", kind: .other)
        model.withScene { $0.setPromotedItem(card.id, for: a) }
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                in: model.scene, artifacts: index(store)),
                     "M6-PR-030")
        XCTAssertEqual(Promotion.existingArtifact(for: .scrap(a), target: .paletteCard,
                                                  in: model.scene, artifacts: index(store)),
                       .update(itemID: card.id, title: "Fog"))

        model.withScene { $0.setPromotedItem("gone", for: a) }
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                in: model.scene, artifacts: index(store)),
                     "M6-PR-031: a dangling mark offers no rewrite")
        model.withScene {
            $0.setPromotedItem(nil, for: a)
            $0.addContribution(note.id, to: a)
        }
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                in: model.scene, artifacts: index(store)),
                     "M6-PR-032: a contributor is not the artifact's producer")
        XCTAssertNil(Promotion.existingArtifact(for: .line(l1), target: .researchNote,
                                                in: model.scene, artifacts: index(store)),
                     "M6-PR-034")
    }

    // MARK: - D. The arms, performed

    /// M6-PR-035, M6-PR-036
    func test_aCardBecomesANoteWithItsWordsVerbatim() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let pl = try plan(.scrap(a), .researchNote, store: store, model: model)
        let res = try await performer.perform(pl)
        let id = try XCTUnwrap(res.createdItemID)
        XCTAssertEqual(try bodyOf(id, store: store, root: root),
                       "The falls at night\n\nSodium light on the spray.", "M6-PR-035")
        XCTAssertEqual(res.title, "The falls at night")
        XCTAssertEqual(model.scene.node(a)?.promotedItemID, id, "M6-PR-035: the card is marked")
        XCTAssertEqual(model.scene.node(a)?.contributedToItemIDs, [],
                       "M6-PR-035: one card behind one artifact records no contribution")
        XCTAssertEqual(res.confirmation(for: pl),
                       "Promoted to the note “The falls at night”.", "M6-PR-036")
    }

    /// M6-PR-037, M6-PR-038, M6-PR-039 — what a Rewrite costs, and what it no
    /// longer costs.
    ///
    /// **All three fixed 2026-08-09** — M6-PR-038/039 under RULING-22 (the
    /// sheet's two labels named the artifact and its quietest field renamed it),
    /// M6-PR-037 under RULING-24 (research is recoverable but not versioned, and
    /// a rewrite left no route back at all). The body is still replaced — that is
    /// what Rewrite says it does — but the previous text is in the trash for the
    /// retention window, the standard a deleted note already had.
    func test_aRewriteReplacesTheNoteAndRevertsTheWritersName() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            try plan(.scrap(a), .researchNote, store: store, model: model))
        let id = try XCTUnwrap(first.createdItemID)

        // The writer works on the note in the research pane, and renames it.
        let path = try XCTUnwrap(TreeWalk.find(id: id, in: store.manifest.research)?.path)
        try "The falls at night\n\nAn afternoon of my own prose.\n"
            .write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try await store.updateResearchItem(id: id, title: "Fog, act II")
        XCTAssertEqual(TreeWalk.find(id: id, in: store.manifest.research)?.path,
                       "research/fog-act-ii.md")

        let existing = try XCTUnwrap(Promotion.existingArtifact(
            for: .scrap(a), target: .researchNote, in: model.scene, artifacts: index(store)))
        model.setScrapText("The falls at night\n\nRewritten on the canvas.", for: a)
        let pl = try plan(.scrap(a), .researchNote, store: store, model: model, mode: existing)
        XCTAssertEqual(pl.destinationDescription, "the existing “Fog, act II”")
        XCTAssertEqual(pl.title, "Fog, act II",
                       "M6-PR-039: fixed under RULING-22, 2026-08-09 — the Name the plan "
                       + "carries is the artifact's own, the same value the destination "
                       + "names, so the sheet shows one name for one artifact")

        _ = try await performer.perform(pl)
        XCTAssertEqual(try bodyOf(id, store: store, root: root),
                       "The falls at night\n\nRewritten on the canvas.",
                       "M6-PR-037: the body is still replaced — that is what Rewrite says")
        XCTAssertEqual(TreeWalk.find(id: id, in: store.manifest.research)?.title,
                       "Fog, act II",
                       "M6-PR-038: fixed under RULING-22, 2026-08-09 — their rename stands")
        XCTAssertEqual(TreeWalk.find(id: id, in: store.manifest.research)?.path,
                       "research/fog-act-ii.md",
                       "M6-PR-038: and the file on disk is not renamed either")

        // M6-PR-037: fixed under RULING-24, 2026-08-09 — the afternoon of prose
        // is reachable for the trash's retention window, the same standard a
        // DELETED note gets. The minimal bridge; not versioning (GAP-P1).
        let entries = try await store.trashStore.list()
        let preserved = try XCTUnwrap(entries.first { $0.subject == .priorVersion },
                                      "M6-PR-037: the prior version is in the trash, and "
                                      + "in the pane — `list()` is the writer's view")
        XCTAssertEqual(preserved.displayTitle, "Fog, act II")
        try await store.restoreTrashEntry(id: preserved.id)
        let returned = try XCTUnwrap(
            (try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent("research").path))
                .first { $0.hasPrefix("fog-act-ii") && $0 != "fog-act-ii.md" },
            "M6-PR-037: it comes back beside the live note rather than over it")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("research/\(returned)"),
                       encoding: .utf8),
            "The falls at night\n\nAn afternoon of my own prose.\n",
            "M6-PR-037: with the writer's own words in it")
        XCTAssertEqual(try bodyOf(id, store: store, root: root),
                       "The falls at night\n\nRewritten on the canvas.",
                       "M6-PR-037: and the rewritten note is untouched by the restore")

        // And the restore is VISIBLE (whole-branch review, 2026-08-09). The
        // entry used to restore as a file alone: correct about there being
        // nothing to rewire, and it left the writer's afternoon in `research/`
        // where no surface in Maugham looks. They had asked for it back and been
        // told it came.
        let restoredRow = try XCTUnwrap(
            store.manifest.research.first { $0.title == "Fog, act II (previous version)" },
            "the prior version comes back with a row of its own — the live note's "
            + "row still points at the rewritten text, so this is a second artifact")
        XCTAssertEqual(restoredRow.path, "research/\(returned)",
                       "and the row points at where the file actually landed")
    }

    /// M6-PR-037's other half (whole-branch review, 2026-08-09) — keeping the
    /// prior version must not be a window in which the note exists ONLY in the
    /// trash.
    ///
    /// The keep is a move, for the typed mover's flush discipline (tripwire 14),
    /// and the caller's next act — writing the new body — is fallible. Between
    /// the two, the manifest row pointed at a path with no file at it: a failed
    /// rewrite told the writer nothing had happened while their note had left
    /// the research pane. Pinned as the property rather than by breaking the
    /// write, because the property is what the fix owes: after the keep, the
    /// live file is still there with the pre-rewrite words in it, and the trash
    /// holds the same words.
    func test_keepingThePriorVersionLeavesTheNoteWhereItIs() async throws {
        let (root, store) = try await makeProject()
        let item = try await store.addResearchTextNote(parentId: nil, title: "Fog, act II")
        let path = try XCTUnwrap(item.path)
        let afternoon = "The falls at night\n\nAn afternoon of my own prose.\n"
        try afternoon.write(to: root.appendingPathComponent(path),
                            atomically: true, encoding: .utf8)

        _ = try await store.trashPriorVersion(at: path, displayTitle: item.title, id: item.id)

        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8),
            afternoon,
            "the live note never stops existing — a rewrite that fails after this "
            + "point leaves the writer's note exactly as it was")
        let entries = try await store.trashStore.list()
        let kept = try XCTUnwrap(entries.first { $0.subject == .priorVersion })
        let inTheTrash = try XCTUnwrap(store.trashStore.entryFileURL(trashId: kept.id))
        XCTAssertEqual(try String(contentsOf: inTheTrash, encoding: .utf8), afternoon,
                       "and the trash holds the same words, which is the whole point of "
                       + "the move this copies back from")
    }

    /// M6-PR-048's other half (whole-branch review, 2026-08-09) — a rewritten
    /// PALETTE CARD's prose is recoverable too.
    ///
    /// M6-PR-037 gave a research note the standard RULING-24 owes it and stopped
    /// there. The same Rewrite aimed at a palette card replaced the writer's
    /// prose with no route back at all — and a card's prose is the more likely
    /// of the two to be theirs by hand, since a card is developed in the pane
    /// rather than generated.
    func test_aPaletteRewriteKeepsThePriorProseWhereTheWriterCanReachIt() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let res = try await performer.perform(
            try plan(.scrap(a), .paletteCard, store: store, model: model))
        let id = try XCTUnwrap(res.createdItemID)
        let before = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == id })

        model.setScrapText("The falls at night\n\nRewritten.", for: a)
        _ = try await performer.perform(
            try plan(.scrap(a), .paletteCard, store: store, model: model,
                     mode: .update(itemID: id, title: before.title)))
        XCTAssertEqual(
            try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == id }).body,
            "The falls at night\n\nRewritten.",
            "the body is still replaced — that is what Rewrite says it does")

        let entries = try await store.trashStore.list()
        let kept = try XCTUnwrap(entries.first { $0.subject == .priorVersion },
                                 "the prose the rewrite replaced is in the trash, "
                                 + "and in the pane")
        XCTAssertEqual(kept.displayTitle, before.title)

        // And it comes back as something the writer can open: a research note
        // with their prose in it.
        try await store.restoreTrashEntry(id: kept.id)
        let row = try XCTUnwrap(
            store.manifest.research.first { $0.title == "\(before.title) (previous version)" },
            "a restore the writer cannot see is not a restore")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent(try XCTUnwrap(row.path)),
                       encoding: .utf8),
            before.body,
            "with the prose the rewrite took")
    }

    /// M6-PR-040 — a second `.new` promotion of a card that already produced one.
    func test_aSecondNewPromotionDuplicatesAndMovesTheMark() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            try plan(.scrap(a), .researchNote, store: store, model: model))
        let second = try await performer.perform(
            try plan(.scrap(a), .researchNote, store: store, model: model))
        XCTAssertNotEqual(first.createdItemID, second.createdItemID)
        XCTAssertEqual(second.title, "The falls at night 2",
                       "the store dedupes the TITLE rather than refusing")
        XCTAssertEqual(model.scene.node(a)?.promotedItemID, second.createdItemID,
                       "the mark moves to the newest artifact")
        XCTAssertNotNil(TreeWalk.find(id: try XCTUnwrap(first.createdItemID),
                                      in: store.manifest.research),
                        "and the first artifact stays, now claimed by no card")
    }

    /// M6-PR-041, M6-PR-042, M6-PR-043 — validate first, write second.
    func test_theRefusalsThatKeepARewriteOffTheWrongArtifact() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let missing = await failure {
            _ = try await performer.perform(
                try self.plan(.scrap(self.a), .researchNote, store: store, model: model,
                              mode: .update(itemID: "gone-id", title: "Gone")))
        }
        XCTAssertEqual(missing?.errorDescription,
                       "The artifact this card produced is no longer in the project (gone-id).",
                       "M6-PR-041")

        let card = try await store.addPaletteCard(title: "Cardy", kind: .other)
        let wrongKind = await failure {
            _ = try await performer.perform(
                try self.plan(.scrap(self.a), .researchNote, store: store, model: model,
                              mode: .update(itemID: card.id, title: "Cardy")))
        }
        XCTAssertEqual(wrongKind?.errorDescription,
                       "What this produced is a palette card now, not a research note, so "
                       + "Maugham did not write over it.", "M6-PR-042")
        XCTAssertEqual(store.loadPaletteCards().first(where: { $0.researchItemId == card.id })?.title,
                       "Cardy", "M6-PR-042: and the card is untouched")

        var noName = try plan(.scrap(a), .researchNote, store: store, model: model)
        noName.title = "   "
        let empty = await failure { _ = try await performer.perform(noName) }
        XCTAssertEqual(empty?.errorDescription, "This needs a name before it can be promoted.",
                       "M6-PR-043")
    }

    /// M6-PR-044, M6-PR-045, M6-PR-046, M6-PR-047 — the craft intent accumulates.
    func test_theCraftIntentIsAppendedToOneStatementPerScope() async throws {
        let (root, store) = try await makeProject()
        try await withChapter(root, store)
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)

        var pl = try plan(.scrap(a), .intentStatement, store: store, model: model)
        pl.title = ""
        let res = try await performer.perform(pl)
        XCTAssertEqual(res.title, "Craft Intent",
                       "M6-PR-044: this target names nothing, so an empty name is not refused")
        let statement = try XCTUnwrap(store.manifest.statements.first)
        XCTAssertEqual(statement.scope, .project, "M6-PR-046: no piece means the project's")
        XCTAssertEqual(model.scene.node(a)?.promotedItemID, statement.id,
                       "M6-PR-047: the mark is the STATEMENT's id")
        XCTAssertEqual(try store.statementText(of: statement),
                       "The falls at night\n\nSodium light on the spray.")

        let second = try await performer.perform(
            try plan(.scrap(b), .intentStatement, store: store, model: model))
        XCTAssertEqual(second.createdItemID, statement.id, "M6-PR-045: find-or-create")
        XCTAssertEqual(store.manifest.statements.count, 1)
        XCTAssertEqual(try store.statementText(of: statement),
                       "The falls at night\n\nSodium light on the spray.\n\nOctober's doctor",
                       "M6-PR-045: it appends, it never replaces")

        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "ch-1" } }
        let chapterIntent = try await performer.perform(
            try plan(.scrap(a), .intentStatement, store: store, model: model))
        XCTAssertEqual(chapterIntent.title, "Craft Intent · Chapter 1", "M6-PR-046")
        XCTAssertEqual(store.manifest.statements.count, 2)

        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "no-such-piece" } }
        let fallback = try await performer.perform(
            try plan(.scrap(a), .intentStatement, store: store, model: model))
        XCTAssertEqual(fallback.title, "Craft Intent",
                       "M6-PR-046: a stale association falls back to the project, silently")
        XCTAssertEqual(store.manifest.statements.count, 2)
    }

    /// M6-PR-048 — a palette rewrite is about the prose.
    func test_aPaletteRewriteKeepsEverythingThatIsNotTheProse() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let res = try await performer.perform(
            try plan(.scrap(a), .paletteCard, store: store, model: model))
        let id = try XCTUnwrap(res.createdItemID)
        let current = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == id })
        try await store.updatePaletteCard(PaletteCard(
            researchItemId: id, title: current.title, kind: .location,
            swatches: ["#123456"],
            notes: [PaletteCard.SensoryNote(sense: .sight, text: "a sensory note")],
            imagePaths: current.imagePaths, body: current.body))
        model.setScrapText("The falls at night\n\nRewritten.", for: a)
        _ = try await performer.perform(
            try plan(.scrap(a), .paletteCard, store: store, model: model,
                     mode: .update(itemID: id, title: current.title)))
        let after = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == id })
        XCTAssertEqual(after.body, "The falls at night\n\nRewritten.")
        XCTAssertEqual(after.swatches, ["#123456"], "M6-PR-048")
        XCTAssertEqual(after.notes.map(\.text), ["a sensory note"], "M6-PR-048")
    }

    /// M6-PR-049, M6-PR-050
    func test_aLineAppendsALinkAndRefusesTheSecondAgainstTheLiveFile() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        _ = try await performer.perform(try plan(.scrap(a), .researchNote, store: store, model: model))
        _ = try await performer.perform(try plan(.scrap(b), .researchNote, store: store, model: model))
        let fromID = try XCTUnwrap(model.scene.node(a)?.promotedItemID)
        let pl = try plan(.line(l1), .wikiLink, store: store, model: model)
        let res = try await performer.perform(pl)
        XCTAssertEqual(try bodyOf(fromID, store: store, root: root),
                       "The falls at night\n\nSodium light on the spray.\n\n[[October's doctor]]\n",
                       "M6-PR-049")
        XCTAssertNil(model.scene.line(l1)?.author)
        XCTAssertEqual(res.confirmation(for: pl),
                       "Wrote the link into the note “The falls at night”.")

        // The plan's own duplicate flag is a snapshot; this one is the file.
        let again = await failure {
            _ = try await performer.perform(
                try self.plan(.line(self.l1), .wikiLink, store: store, model: model))
        }
        XCTAssertEqual(again?.errorDescription,
                       "That link is already in the note “The falls at night”.", "M6-PR-050")
        XCTAssertEqual(try bodyOf(fromID, store: store, root: root),
                       "The falls at night\n\nSodium light on the spray.\n\n[[October's doctor]]\n",
                       "M6-PR-050: and nothing was written")
    }

    // MARK: - E. Pictures

    /// M6-PR-051 — a copy, and the canvas keeps its picture.
    func test_anOwnedPictureIsCopiedIntoResearchAndMarked() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store)
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        model.withScene {
            $0.insert(CanvasNode(id: own, kind: .item(.owned(path: path)),
                                 origin: CGPoint(x: 0, y: 500), width: 180, cachedHeight: 200))
        }
        let performer = PromotionPerformer(store: store, model: model)
        let pl = try plan(.scrap(own), .researchAsset, store: store, model: model)
        XCTAssertEqual(pl.body, "", "a picture has no prose to excerpt")
        XCTAssertEqual(pl.pictures.map(\.assetPath), [path])
        let res = try await performer.perform(pl)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                      "M6-PR-051: the original stays in canvas_assets/")
        XCTAssertEqual(model.scene.node(own)?.kind, .item(.owned(path: path)),
                       "M6-PR-051: and the node is still owned")
        XCTAssertEqual(model.scene.node(own)?.promotedItemID, res.createdItemID,
                       "M6-PR-051: this produced an artifact of its own, so it is a MARK")
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promote Picture"),
                      "found: \(model.undoManager.undoMenuItemTitle)")
        XCTAssertEqual(res.confirmation(for: pl),
                       "Copied the picture into research as “\(res.title)”.")
    }

    /// M6-PR-052 — the palette row records a contribution and never the mark.
    func test_aPictureOnAPaletteCardIsRecordedAsAContribution() async throws {
        let (root, store) = try await makeProject()
        let p1 = try await ingest(into: store)
        let p2 = try await ingest(into: store)
        let model = makeModel(at: root)
        model.withScene {
            $0.insert(CanvasNode(id: own, kind: .item(.owned(path: p1)),
                                 origin: CGPoint(x: 0, y: 500), width: 180, cachedHeight: 200))
            $0.insert(CanvasNode(id: own2, kind: .item(.owned(path: p2)),
                                 origin: CGPoint(x: 300, y: 500), width: 180, cachedHeight: 200))
        }
        let card = try await store.addPaletteCard(title: "Fog", kind: .other)
        let seeded = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == card.id })
        try await store.updatePaletteCard(PaletteCard(
            researchItemId: card.id, title: "Fog", kind: .other, swatches: seeded.swatches,
            notes: seeded.notes, imagePaths: seeded.imagePaths, body: "Card prose"))
        let performer = PromotionPerformer(store: store, model: model)
        let pl = try plan(.scrap(own), .paletteCardImage, store: store, model: model,
                          paletteCardID: card.id)
        let res = try await performer.perform(pl)
        XCTAssertNil(model.scene.node(own)?.promotedItemID,
                     "M6-PR-052: a picture stamped with the card's id would be offered a Rewrite")
        XCTAssertEqual(model.scene.node(own)?.contributedToItemIDs, [card.id], "M6-PR-052")
        let after = try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == card.id })
        XCTAssertEqual(after.imagePaths.count, 1)
        XCTAssertEqual(after.body, "Card prose", "M6-PR-052: the card's prose survives")
        XCTAssertEqual(res.confirmation(for: pl),
                       "Added a copy of the picture to the palette card “Fog”.")

        _ = try await performer.perform(
            try plan(.scrap(own2), .paletteCardImage, store: store, model: model,
                     paletteCardID: card.id))
        XCTAssertEqual(model.scene.node(own)?.contributedToItemIDs, [card.id],
                       "M6-PR-052: the well is appended to, so the first record stands")
        XCTAssertEqual(model.scene.node(own2)?.contributedToItemIDs, [card.id])
        XCTAssertEqual(try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == card.id }).imagePaths.count, 2)
    }

    /// M6-PR-053 — a picture must not land on whichever card sorted first.
    func test_aPaletteImagePromotionWithNoCardProducesNoPlan() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store)
        let model = makeModel(at: root)
        model.withScene {
            $0.insert(CanvasNode(id: own, kind: .item(.owned(path: path)),
                                 origin: CGPoint(x: 0, y: 500), width: 180, cachedHeight: 200))
        }
        _ = try await store.addPaletteCard(title: "Fog", kind: .other)
        XCTAssertNil(Promotion.plan(request(.scrap(own), .paletteCardImage,
                                            store: store, model: model), in: model.scene))
        XCTAssertNil(Promotion.plan(request(.scrap(own), .paletteCardImage, store: store,
                                            model: model, paletteCardID: "not-a-card"),
                                    in: model.scene))
    }

    /// M6-PR-054, M6-PR-055, M6-PR-056 — the picture refusals, and their order.
    func test_thePictureRefusalsNameTheFileBeforeTheCard() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        func handBuilt(_ source: PromotionSource, _ kind: PromotionTarget,
                       pictures: [PromotedPicture]) -> PromotionPlan {
            PromotionPlan(source: source, producedKind: kind, title: "x", body: "words",
                          destinationDescription: "somewhere", discards: [], offeredLinks: [],
                          wikiLinkWrite: nil, mode: .new, paletteKind: .other, contributors: [],
                          linkAlreadyPresent: false, pictures: pictures)
        }
        let none = await failure {
            _ = try await performer.perform(handBuilt(.scrap(self.own), .researchAsset,
                                                      pictures: []))
        }
        XCTAssertEqual(none?.errorDescription, "There is no picture on this card to promote.",
                       "M6-PR-054")

        let path = try await ingest(into: store)
        let cardGone = await failure {
            _ = try await performer.perform(handBuilt(
                .scrap(self.own), .paletteCardImage,
                pictures: [PromotedPicture(node: self.own, assetPath: path,
                                           paletteCardID: "not-a-card")]))
        }
        XCTAssertEqual(cardGone?.errorDescription,
                       "That palette card is no longer in the project, so the picture "
                       + "has nowhere to go.")

        let bothGone = await failure {
            _ = try await performer.perform(handBuilt(
                .scrap(self.own), .paletteCardImage,
                pictures: [PromotedPicture(node: self.own, assetPath: "canvas_assets/nope.png",
                                           paletteCardID: "not-a-card")]))
        }
        XCTAssertEqual(bothGone?.errorDescription,
                       "The picture this card shows is no longer in the project "
                       + "(canvas_assets/nope.png), so there is nothing to copy.",
                       "M6-PR-055: the more fundamental refusal goes first")

        let fromRegion = await failure {
            _ = try await performer.perform(handBuilt(
                .region(self.r1), .paletteCard,
                pictures: [PromotedPicture(node: self.own, assetPath: "canvas_assets/nope.png",
                                           paletteCardID: nil)]))
        }
        XCTAssertEqual(fromRegion?.errorDescription,
                       "A picture in this region is no longer in the project "
                       + "(canvas_assets/nope.png), so there is nothing to copy.",
                       "M6-PR-056: the subject follows the source")
    }

    /// M6-PR-057, M6-PR-058, M6-PR-059 — a region carries its pictures onto a
    /// palette card, on `.new` only.
    func test_aRegionsPaletteCardCarriesThePicturesInIt() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store)
        let model = makeModel(at: root)
        model.withScene {
            $0.insert(CanvasNode(id: own, kind: .item(.owned(path: path)),
                                 origin: CGPoint(x: 0, y: 100), width: 180, cachedHeight: 200))
            CanvasMembership.join(own, home: r1, in: &$0)
        }
        let notePlan = try plan(.region(r1), .researchNote, store: store, model: model)
        XCTAssertEqual(notePlan.discards, [.lines, .layout, .pictures],
                       "M6-PR-059: a note is prose and the writer is told the picture stays behind")
        XCTAssertEqual(notePlan.pictures.count, 0)
        XCTAssertEqual(notePlan.contributors, [a, b],
                       "M6-PR-059: a picture that did not travel contributed nothing")

        let palettePlan = try plan(.region(r1), .paletteCard, store: store, model: model)
        XCTAssertEqual(palettePlan.discards, [.lines, .layout])
        XCTAssertEqual(palettePlan.pictures.map(\.assetPath), [path], "M6-PR-057")
        XCTAssertEqual(palettePlan.contributors, [a, own, b],
                       "M6-PR-057: whoever's CONTENT went in, words or picture, in reading order")
        let res = try await performer(store, model).perform(palettePlan)
        let id = try XCTUnwrap(res.createdItemID)
        XCTAssertEqual(try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == id })
            .imagePaths.count, 1, "M6-PR-057")
        XCTAssertEqual(model.scene.node(own)?.contributedToItemIDs, [id], "M6-PR-057")
        XCTAssertNil(model.scene.node(own)?.promotedItemID)

        let existing = try XCTUnwrap(Promotion.existingArtifact(
            for: .region(r1), target: .paletteCard, in: model.scene, artifacts: index(store)))
        let updPlan = try plan(.region(r1), .paletteCard, store: store, model: model, mode: existing)
        XCTAssertEqual(updPlan.pictures.count, 0,
                       "M6-PR-058: a rewrite is about the prose; the well is not re-stacked")
        XCTAssertEqual(updPlan.discards, [.lines, .layout, .pictures], "M6-PR-058")
        XCTAssertEqual(updPlan.contributors, [a, b], "M6-PR-058")
        _ = try await performer(store, model).perform(updPlan)
        XCTAssertEqual(try XCTUnwrap(store.loadPaletteCards().first { $0.researchItemId == id })
            .imagePaths.count, 1)
        XCTAssertEqual(model.scene.node(own)?.contributedToItemIDs, [id],
                       "M6-PR-058: and the picture's record survives the rewrite")
    }

    /// M6-PR-060 — a REFERENCED picture in the region travels too, and only
    /// when the caller passed the item index.
    func test_aReferencedPictureTravelsOnlyWhenTheItemIndexWasPassed() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let source = temp.url.appendingPathComponent("ref-\(UUID()).png")
        try Data("bytes".utf8).write(to: source)
        let asset = try await store.createResearchAsset(scope: .shared, fromURL: source)
        model.withScene {
            $0.insert(CanvasNode(id: ref, kind: .item(.project(id: asset.id)),
                                 origin: CGPoint(x: 0, y: 100), width: 180, cachedHeight: 200))
            CanvasMembership.join(ref, home: r1, in: &$0)
        }
        let items = CanvasItemIndex.over(research: store.manifest.research)
        let withIndex = try plan(.region(r1), .paletteCard, store: store, model: model, items: items)
        XCTAssertEqual(withIndex.pictures.map(\.assetPath), [asset.path], "M6-PR-060")
        XCTAssertEqual(withIndex.contributors, [a, ref, b], "M6-PR-060")

        let withoutIndex = try plan(.region(r1), .paletteCard, store: store, model: model)
        XCTAssertEqual(withoutIndex.pictures.count, 0,
                       "M6-PR-060: with items: .empty the same region carries nothing, silently")
        XCTAssertEqual(withoutIndex.contributors, [a, b], "M6-PR-060")
    }

    // MARK: - F. Pieces

    /// M6-PR-061, M6-PR-062, M6-PR-063, M6-PR-064, M6-PR-065
    func test_thePiecePrecedence() async throws {
        let (root, store) = try await makeProject()
        try await withChapter(root, store)
        let model = makeModel(at: root)
        XCTAssertNil(Promotion.piece(for: .scrap(a), in: model.scene), "M6-PR-061")
        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "ch-1" } }
        XCTAssertEqual(Promotion.piece(for: .scrap(a), in: model.scene), "ch-1",
                       "M6-PR-061: a card inherits its home region's piece")
        XCTAssertTrue(Promotion.pieceIsInherited(for: .scrap(a), in: model.scene), "M6-PR-065")
        model.withScene { $0.setBoundPiece("its-own", for: a) }
        XCTAssertEqual(Promotion.piece(for: .scrap(a), in: model.scene), "its-own",
                       "M6-PR-061: its own wins")
        XCTAssertFalse(Promotion.pieceIsInherited(for: .scrap(a), in: model.scene), "M6-PR-065")
        model.withScene { $0.setBoundPiece(nil, for: a) }

        model.withScene {
            $0.insert(CanvasNode(id: c, kind: .scrap, origin: CGPoint(x: 0, y: 400),
                                 width: 100, cachedHeight: 10))
            CanvasMembership.addAppearance(c, to: r1, in: &$0)
        }
        XCTAssertNil(Promotion.piece(for: .scrap(c), in: model.scene),
                     "M6-PR-062: a citation is not luggage")
        XCTAssertEqual(Promotion.piece(for: .region(r1), in: model.scene), "ch-1", "M6-PR-063")
        XCTAssertNil(Promotion.piece(for: .line(l1), in: model.scene), "M6-PR-063")
        XCTAssertFalse(Promotion.pieceIsInherited(for: .region(r1), in: model.scene), "M6-PR-065")

        let path = try await ingest(into: store)
        model.withScene {
            $0.insert(CanvasNode(id: own, kind: .item(.owned(path: path)),
                                 origin: CGPoint(x: 10, y: 10), width: 100, cachedHeight: 100))
            CanvasMembership.join(own, home: r1, in: &$0)
        }
        XCTAssertEqual(Promotion.piece(for: .scrap(own), in: model.scene), "ch-1", "M6-PR-064")
        XCTAssertFalse(Promotion.canCarryItsOwnPiece(.scrap(own), in: model.scene),
                       "M6-PR-064: there is nothing about a photograph to associate")
        XCTAssertTrue(Promotion.canCarryItsOwnPiece(.scrap(a), in: model.scene))
        XCTAssertTrue(Promotion.canCarryItsOwnPiece(.region(r1), in: model.scene))
        XCTAssertFalse(Promotion.canCarryItsOwnPiece(.line(l1), in: model.scene))
    }

    /// M6-PR-066, M6-PR-067 — a stale association, and who the refusal points at.
    func test_aStaleAssociationRefusesOnlyTheRowsThatRoute() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "gone-piece" } }
        let stale = PromotionPiece.resolve(for: .scrap(a), in: model.scene, store: store)
        XCTAssertEqual(stale, .unroutable(id: "gone-piece", title: nil, inherited: true))
        XCTAssertEqual(Promotion.scopedTargets, [.researchNote, .researchAsset], "M6-PR-066")
        for target in PromotionTarget.allCases {
            let failure = Promotion.pieceFailure(target: target, mode: .new, piece: stale,
                                                 canCarryItsOwnPiece: true)
            XCTAssertEqual(failure != nil, Promotion.scopedTargets.contains(target),
                           "M6-PR-066: \(target.rawValue)")
        }
        XCTAssertNil(Promotion.pieceFailure(target: .researchNote,
                                            mode: .update(itemID: "x", title: "y"),
                                            piece: stale, canCarryItsOwnPiece: true),
                     "M6-PR-066: an update does not route")
        XCTAssertEqual(Promotion.pieceFailure(target: .researchNote, mode: .new, piece: stale,
                                              canCarryItsOwnPiece: true)?.errorDescription,
                       "The piece this is associated with is no longer in the project, so "
                       + "there is nowhere to file it. That piece comes from the region this "
                       + "card lives in — change it there, or give this card a piece of its own.",
                       "M6-PR-067")
        XCTAssertEqual(Promotion.pieceFailure(target: .researchNote, mode: .new, piece: stale,
                                              canCarryItsOwnPiece: false)?.errorDescription,
                       "The piece this is associated with is no longer in the project, so "
                       + "there is nowhere to file it. That piece comes from the region this "
                       + "lives in — change it there.",
                       "M6-PR-067: a picture is not offered a control it does not have")
        XCTAssertEqual(Promotion.pieceFailure(
            target: .researchNote, mode: .new,
            piece: .unroutable(id: "p", title: "Piece", inherited: false),
            canCarryItsOwnPiece: true)?.errorDescription,
                       "“Piece” cannot keep research of its own, so there is nowhere to file it. "
                       + "Pick another piece in the inspector, or clear the association.",
                       "M6-PR-067")
    }

    /// M6-PR-068 — the refusal is thrown before anything is written, and the
    /// unrouted rows still work.
    func test_aStaleAssociationWritesNothingAndDoesNotBlockThePaletteRow() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "gone-piece" } }
        let performer = PromotionPerformer(store: store, model: model)
        let before = TreeWalk.collect(in: store.manifest.research, where: { _ in true }).count
        let refused = await failure {
            _ = try await performer.perform(
                try self.plan(.scrap(self.a), .researchNote, store: store, model: model))
        }
        XCTAssertNotNil(refused)
        XCTAssertEqual(TreeWalk.collect(in: store.manifest.research, where: { _ in true }).count,
                       before, "M6-PR-068: nothing was created")
        XCTAssertNil(model.scene.node(a)?.promotedItemID, "M6-PR-068: and nothing was marked")
        let card = try await performer.perform(
            try plan(.scrap(a), .paletteCard, store: store, model: model))
        XCTAssertEqual(card.title, "The falls at night",
                       "M6-PR-068: a palette card is never routed, so it is not refused")
    }

    /// M6-PR-069, M6-PR-070 — a novel chapter's routing, end to end.
    func test_aChapterBoundPromotionIsFiledSharedAndLinkedToTheChapter() async throws {
        let (root, store) = try await makeProject()
        try await withChapter(root, store)
        let model = makeModel(at: root)
        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "ch-1" } }
        let performer = PromotionPerformer(store: store, model: model)
        let note = try await performer.perform(
            try plan(.scrap(a), .researchNote, store: store, model: model))
        let item = try XCTUnwrap(TreeWalk.find(id: try XCTUnwrap(note.createdItemID),
                                               in: store.manifest.research))
        XCTAssertEqual(item.path, "research/the-falls-at-night.md",
                       "M6-PR-069: a novel chapter's note is filed in SHARED research")
        XCTAssertEqual(store.manifest.structure.first?.linkedResearchIds, [item.id],
                       "M6-PR-069: plus a link record on the chapter")

        let card = try await performer.perform(
            try plan(.region(r1), .paletteCard, store: store, model: model))
        let cardItem = try XCTUnwrap(TreeWalk.find(id: try XCTUnwrap(card.createdItemID),
                                                   in: store.manifest.research))
        XCTAssertEqual(cardItem.path, "research/palette/act-ii-fog.md",
                       "M6-PR-070: a card goes on the wall wherever the piece is")
        XCTAssertEqual(store.manifest.structure.first?.linkedResearchIds, [item.id, cardItem.id],
                       "M6-PR-070: and takes the link the association buys it")
    }

    // MARK: - G. Contributions (spec §6.3)

    /// M6-PR-071, M6-PR-072, M6-PR-073
    func test_theContributionRecordFollowsTheRegionsCurrentMembers() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            try plan(.region(r1), .researchNote, store: store, model: model))
        let noteA = try XCTUnwrap(first.createdItemID)
        XCTAssertEqual(model.scene.node(a)?.contributedToItemIDs, [noteA], "M6-PR-071")
        XCTAssertEqual(model.scene.node(b)?.contributedToItemIDs, [noteA], "M6-PR-071")
        XCTAssertEqual(model.scene.region(r1)?.promotedItemID, noteA,
                       "M6-PR-071: the region carries the mark, the members the record")

        model.withScene {
            $0.insert(CanvasNode(id: c, kind: .scrap, origin: CGPoint(x: 0, y: 300),
                                 width: 100, cachedHeight: 10))
            CanvasMembership.leave(b, from: r1, in: &$0)
            CanvasMembership.join(c, home: r1, in: &$0)
        }
        model.setScrapText("A newcomer", for: c)
        let existing = try XCTUnwrap(Promotion.existingArtifact(
            for: .region(r1), target: .researchNote, in: model.scene, artifacts: index(store)))
        _ = try await performer.perform(
            try plan(.region(r1), .researchNote, store: store, model: model, mode: existing))
        XCTAssertEqual(model.scene.node(b)?.contributedToItemIDs, [],
                       "M6-PR-072: a card that has left stops claiming the note — the "
                       + "removal scoped to THIS artifact (RULING-51, fixed 2026-08-09; "
                       + "the stamp used to overwrite the whole record)")
        XCTAssertEqual(model.scene.node(c)?.contributedToItemIDs, [noteA], "M6-PR-072")
        XCTAssertEqual(model.scene.node(a)?.contributedToItemIDs, [noteA])

        model.withScene {
            $0.insertRegion(CanvasRegion(id: r2, label: "Other",
                                         frame: CGRect(x: 0, y: 800, width: 300, height: 300),
                                         homeMembers: []))
            CanvasMembership.join(a, home: r2, in: &$0)
        }
        let second = try await performer.perform(
            try plan(.region(r2), .researchNote, store: store, model: model))
        let noteB = try XCTUnwrap(second.createdItemID)
        XCTAssertEqual(model.scene.node(a)?.contributedToItemIDs, [noteA, noteB],
                       "M6-PR-073: the record holds EVERY artifact the card's words "
                       + "fed, in contribution order (RULING-51, fixed 2026-08-09 "
                       + "from single-valued latest-wins)")
        XCTAssertTrue(try bodyOf(noteA, store: store, root: root).contains("The falls at night"),
                      "M6-PR-073: the earlier note still holds them — which is why "
                      + "the record must too")
    }

    /// M6-PR-074 — the clear reaches scrap nodes only.
    func test_aRewriteDoesNotClearAPicturesRecord() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store)
        let model = makeModel(at: root)
        model.withScene {
            $0.insert(CanvasNode(id: own, kind: .item(.owned(path: path)),
                                 origin: CGPoint(x: 0, y: 100), width: 180, cachedHeight: 200))
            CanvasMembership.join(own, home: r1, in: &$0)
        }
        let performer = PromotionPerformer(store: store, model: model)
        let res = try await performer.perform(
            try plan(.region(r1), .paletteCard, store: store, model: model))
        let id = try XCTUnwrap(res.createdItemID)
        XCTAssertEqual(model.scene.node(own)?.contributedToItemIDs, [id])
        let existing = try XCTUnwrap(Promotion.existingArtifact(
            for: .region(r1), target: .paletteCard, in: model.scene, artifacts: index(store)))
        _ = try await performer.perform(
            try plan(.region(r1), .paletteCard, store: store, model: model, mode: existing))
        XCTAssertEqual(model.scene.node(own)?.contributedToItemIDs, [id],
                       "M6-PR-074: the image well is append-only, so the picture is still in it")
    }

    // MARK: - H. What a failure leaves behind, and what ⌘Z takes back

    /// M6-PR-075 — fixed under RULING-22, 2026-08-09. The refusal now leaves
    /// nothing behind, which is what this file's own contract ("validate first,
    /// write second") always said and what a writer takes from a failure
    /// message. The read that can fail is asked before anything is created.
    func test_aLinkWriteFailureThrowsAfterTheArtifactExists() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        _ = try await performer.perform(try plan(.scrap(a), .researchNote, store: store, model: model))
        let memberID = try XCTUnwrap(model.scene.node(a)?.promotedItemID)
        let memberPath = try XCTUnwrap(TreeWalk.find(id: memberID,
                                                     in: store.manifest.research)?.path)
        // A member's note that exists and will not read as UTF-8.
        try Data([0xFF, 0xFE, 0xFF]).write(to: root.appendingPathComponent(memberPath))

        var regionPlan = try plan(.region(r1), .researchNote, store: store, model: model)
        regionPlan.linksAccepted = true
        let thrown = await failure { _ = try await performer.perform(regionPlan) }
        XCTAssertEqual(thrown?.errorDescription,
                       "Maugham could not read what is already in \(memberPath), so it did "
                       + "not write over it.")
        XCTAssertNil(model.scene.region(r1)?.promotedItemID,
                     "M6-PR-075: the region is not marked")
        XCTAssertEqual(TreeWalk.collect(in: store.manifest.research,
                                        where: { $0.title.hasPrefix("Act II fog") }).count, 0,
                       "M6-PR-075: no artifact was created")
        XCTAssertEqual(model.scene.node(a)?.contributedToItemIDs, [],
                       "M6-PR-075: and no contribution record was stamped")
    }

    /// M6-PR-076 — the count reported is what was written, not what was offered.
    func test_anOfferedMemberWhoseArtifactVanishedIsSkipped() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        _ = try await performer.perform(try plan(.scrap(b), .researchNote, store: store, model: model))
        var regionPlan = try plan(.region(r1), .researchNote, store: store, model: model)
        regionPlan.linksAccepted = true
        XCTAssertEqual(regionPlan.offeredLinks.count, 1)
        let bID = try XCTUnwrap(model.scene.node(b)?.promotedItemID)
        store.manifest.research.removeAll { $0.id == bID }
        try await store.saveManifest()
        let res = try await performer.perform(regionPlan)
        XCTAssertEqual(res.writtenLinks, [], "M6-PR-076")
        XCTAssertFalse(res.confirmation(for: regionPlan).contains("Linked"),
                       "M6-PR-076: no link sentence when none was written")
    }

    /// M6-PR-077 (RULING-46, 2026-08-09) — ⌘Z is scene-scoped by design and
    /// the label now says so: the undo is named for the MARK it takes back
    /// ("Undo Promotion Mark"), never for the promotion it does not undo.
    func test_undoTakesBackTheMarkAndNotTheArtifact() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        let performer = PromotionPerformer(store: store, model: model)
        let res = try await performer.perform(
            try plan(.scrap(a), .researchNote, store: store, model: model))
        let id = try XCTUnwrap(res.createdItemID)
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promotion Mark"),
                      "found: \(model.undoManager.undoMenuItemTitle)")
        model.undo.undo()
        XCTAssertNil(model.scene.node(a)?.promotedItemID, "M6-PR-077")
        XCTAssertNotNil(TreeWalk.find(id: id, in: store.manifest.research), "M6-PR-077")
        XCTAssertEqual(try bodyOf(id, store: store, root: root),
                       "The falls at night\n\nSodium light on the spray.", "M6-PR-077")
    }

    /// M6-PR-078 — a queued research-pane save cannot overwrite the promotion.
    func test_aQueuedSaveForTheDestinationDoesNotSurviveThePromotion() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let res = try await performer.perform(
            try plan(.scrap(a), .researchNote, store: store, model: model))
        let id = try XCTUnwrap(res.createdItemID)
        let path = try XCTUnwrap(TreeWalk.find(id: id, in: store.manifest.research)?.path)
        store.documentStore?.scheduleFileSave(for: path, text: "STALE PANE CONTENT")
        model.setScrapText("The falls at night\n\nFresh from the canvas.", for: a)
        _ = try await performer.perform(
            try plan(.scrap(a), .researchNote, store: store, model: model,
                     mode: .update(itemID: id, title: "x")))
        XCTAssertEqual(try bodyOf(id, store: store, root: root),
                       "The falls at night\n\nFresh from the canvas.")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(try bodyOf(id, store: store, root: root),
                       "The falls at night\n\nFresh from the canvas.",
                       "M6-PR-078: and the debounce window passes without clobbering it")
    }

    private func performer(_ store: ProjectStore, _ model: CanvasModel) -> PromotionPerformer {
        PromotionPerformer(store: store, model: model)
    }
}
