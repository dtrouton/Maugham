import XCTest
import MaughamCore
@testable import Maugham

/// PROBE 3 — the gaps probes 1 and 2 left, and the two places probe 2's own
/// setup was wrong (the mutation check measured my own edits; the palette card
/// was "deleted" by a top-level removeAll that does not reach a nested child).
@MainActor
final class PromotionProbe3: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let own = CanvasNodeID("ownnode")
    private let r1 = CanvasRegionID("r1")
    private let r3 = CanvasRegionID("r3")
    private let l1 = CanvasLineID("l1")

    private var documentStores: [DocumentStore] = []
    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }
    override func tearDown() async throws {
        for ds in documentStores { await ds.close() }
        documentStores = []
        temp = nil
    }

    private func makeProject() async throws -> (URL, ProjectStore) {
        let tmp = temp.url.appendingPathComponent("PR3-\(UUID())")
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
        ArtifactIndex.over(research: store.manifest.research,
                           statements: store.manifest.statements,
                           structure: store.manifest.structure)
    }

    private func ingest(into store: ProjectStore) async throws -> String {
        let source = temp.url.appendingPathComponent("dropped-\(UUID()).png")
        try Data("bytes".utf8).write(to: source)
        return try await store.ingestCanvasAsset(fileURL: source)
    }

    private func plan(_ s: PromotionSource, _ t: PromotionTarget,
                      store: ProjectStore, model: CanvasModel,
                      mode: PromotionMode = .new) throws -> PromotionPlan {
        try XCTUnwrap(Promotion.plan(
            PromotionRequest(source: s, target: t, mode: mode, scraps: model.scraps,
                             artifacts: index(store)),
            in: model.scene))
    }

    private func p(_ label: String, _ value: Any) { ProbeLog.write("P3 \(label): \(value)") }

    func test_probe14_gaps() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)

        // 1. planning, measured either side of the call and nothing else
        let before = model.scene
        let beforeScraps = model.scraps
        _ = try plan(.scrap(a), .researchNote, store: store, model: model)
        _ = try plan(.region(r1), .paletteCard, store: store, model: model)
        p("scene identical across two plan calls", before == model.scene)
        p("scraps identical across two plan calls", beforeScraps == model.scraps)

        // 2. an UNLABELLED region that has content
        model.withScene {
            $0.insertRegion(CanvasRegion(id: r3, label: "   ",
                                         frame: CGRect(x: 0, y: 700, width: 300, height: 300),
                                         homeMembers: []))
            CanvasMembership.join(b, home: r3, in: &$0)
        }
        p("untitled region plan title", try plan(.region(r3), .researchNote,
                                                 store: store, model: model).title)
        p("CanvasRegion.untitledLabel", CanvasRegion.untitledLabel)

        // 3. craft intent has no title guard and does have a body guard
        let performer = PromotionPerformer(store: store, model: model)
        var intent = try plan(.scrap(a), .intentStatement, store: store, model: model)
        intent.title = ""
        let res = try await performer.perform(intent)
        p("craft intent with an empty title", res.title)

        // 4. a hand-built plan: the picture rows' own refusals
        let empty = PromotionPlan(
            source: .scrap(a), producedKind: .researchAsset, title: "x", body: "",
            destinationDescription: "research/", discards: [], offeredLinks: [],
            wikiLinkWrite: nil, mode: .new, paletteKind: .other, contributors: [],
            linkAlreadyPresent: false, pictures: [])
        do { _ = try await performer.perform(empty); p("picture row, empty list", "no throw") }
        catch { p("picture row, empty list",
                  (error as? PromotionFailure)?.errorDescription ?? "\(error)") }

        let path = try await ingest(into: store)
        let bogusCard = PromotionPlan(
            source: .scrap(a), producedKind: .paletteCardImage, title: "x", body: "",
            destinationDescription: "a card", discards: [], offeredLinks: [],
            wikiLinkWrite: nil, mode: .new, paletteKind: .other, contributors: [],
            linkAlreadyPresent: false,
            pictures: [PromotedPicture(node: own, assetPath: path,
                                       paletteCardID: "not-a-card")])
        do { _ = try await performer.perform(bogusCard); p("picture row, unknown card", "no throw") }
        catch { p("picture row, unknown card",
                  (error as? PromotionFailure)?.errorDescription ?? "\(error)") }

        let bothGone = PromotionPlan(
            source: .scrap(a), producedKind: .paletteCardImage, title: "x", body: "",
            destinationDescription: "a card", discards: [], offeredLinks: [],
            wikiLinkWrite: nil, mode: .new, paletteKind: .other, contributors: [],
            linkAlreadyPresent: false,
            pictures: [PromotedPicture(node: own, assetPath: "canvas_assets/nope.png",
                                       paletteCardID: "not-a-card")])
        do { _ = try await performer.perform(bothGone); p("picture and card both gone", "no throw") }
        catch { p("picture and card both gone",
                  (error as? PromotionFailure)?.errorDescription ?? "\(error)") }

        let regionSourced = PromotionPlan(
            source: .region(r1), producedKind: .paletteCard, title: "x", body: "words",
            destinationDescription: "the palette wall", discards: [], offeredLinks: [],
            wikiLinkWrite: nil, mode: .new, paletteKind: .other, contributors: [],
            linkAlreadyPresent: false,
            pictures: [PromotedPicture(node: own, assetPath: "canvas_assets/nope.png",
                                       paletteCardID: nil)])
        do { _ = try await performer.perform(regionSourced); p("region picture gone", "no throw") }
        catch { p("region picture gone",
                  (error as? PromotionFailure)?.errorDescription ?? "\(error)") }

        let noWrite = PromotionPlan(
            source: .line(l1), producedKind: .wikiLink, title: "x", body: "",
            destinationDescription: "the note “x”", discards: [], offeredLinks: [],
            wikiLinkWrite: nil, mode: .new, paletteKind: .other, contributors: [],
            linkAlreadyPresent: false, pictures: [])
        do { _ = try await performer.perform(noWrite); p("line with no write", "no throw") }
        catch { p("line with no write",
                  (error as? PromotionFailure)?.errorDescription ?? "\(error)") }
    }

    func test_probe15_routing() async throws {
        let (root, store) = try await makeProject()
        try "Chapter 1\n".write(to: root.appendingPathComponent("manuscript/c1.md"),
                                atomically: true, encoding: .utf8)
        store.manifest.structure = [
            StructureItem(id: "ch-1", title: "Chapter 1", type: .document,
                          path: "manuscript/c1.md")]
        try await store.saveManifest()
        let model = makeModel(at: root)
        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "ch-1" } }
        let performer = PromotionPerformer(store: store, model: model)

        let note = try await performer.perform(try plan(.scrap(a), .researchNote,
                                                        store: store, model: model))
        let item = TreeWalk.find(id: note.createdItemID!, in: store.manifest.research)!
        p("chapter-bound note path", item.path ?? "nil")
        p("chapter-bound note links", item.links ?? [])

        let card = try await performer.perform(try plan(.region(r1), .paletteCard,
                                                        store: store, model: model))
        let cardItem = TreeWalk.find(id: card.createdItemID!, in: store.manifest.research)!
        p("chapter-bound palette card path", cardItem.path ?? "nil")
        p("chapter-bound palette card links", cardItem.links ?? [])

        // a stale association refuses the note row before anything is written
        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "gone-piece" } }
        let researchCount = TreeWalk.collect(in: store.manifest.research, where: { _ in true }).count
        do {
            _ = try await performer.perform(try plan(.scrap(b), .researchNote,
                                                     store: store, model: model))
            p("stale piece, research note", "no throw")
        } catch {
            p("stale piece, research note",
              (error as? PromotionFailure)?.errorDescription ?? "\(error)")
        }
        p("nothing created by the refusal",
          TreeWalk.collect(in: store.manifest.research, where: { _ in true }).count == researchCount)
        p("no mark left by the refusal", model.scene.node(b)?.promotedItemID ?? "nil")
        // …and the palette row still works with the same stale association
        let card2 = try await performer.perform(try plan(.scrap(b), .paletteCard,
                                                         store: store, model: model))
        p("stale piece, palette card", card2.title)
    }

    func test_probe16_secondNewPromotion() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(try plan(.scrap(a), .researchNote,
                                                         store: store, model: model))
        let second = try await performer.perform(try plan(.scrap(a), .researchNote,
                                                          store: store, model: model))
        p("first id", first.createdItemID ?? "nil")
        p("second id", second.createdItemID ?? "nil")
        p("second title", second.title)
        p("mark after the second .new promotion", model.scene.node(a)?.promotedItemID ?? "nil")
        p("first artifact still present",
          TreeWalk.find(id: first.createdItemID!, in: store.manifest.research)?.title ?? "gone")
        p("titles in research", TreeWalk.collect(in: store.manifest.research,
                                                 where: { _ in true }).map(\.title))
    }
}
