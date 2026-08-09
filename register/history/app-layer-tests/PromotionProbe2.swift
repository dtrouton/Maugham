import XCTest
import MaughamCore
@testable import Maugham

/// PROBE 2 — the performer, against a real store. Prints only.
@MainActor
final class PromotionProbe2: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let c = CanvasNodeID("c")
    private let own = CanvasNodeID("ownnode")
    private let own2 = CanvasNodeID("ownnode2")
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

    private func makeProject() async throws -> (URL, ProjectStore) {
        let tmp = temp.url.appendingPathComponent("PR2-\(UUID())")
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
                      mode: PromotionMode = .new,
                      items: CanvasItemIndex = .empty,
                      paletteCardID: String? = nil,
                      destinationBody: String? = nil) throws -> PromotionPlan {
        try XCTUnwrap(Promotion.plan(
            PromotionRequest(source: s, target: t, mode: mode, scraps: model.scraps,
                             artifacts: index(store), items: items,
                             destinationBody: destinationBody,
                             paletteCardID: paletteCardID),
            in: model.scene))
    }

    private func bodyOf(_ id: String, store: ProjectStore, root: URL) -> String {
        guard let item = TreeWalk.find(id: id, in: store.manifest.research),
              let path = item.path else { return "<<no path>>" }
        return (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
            ?? "<<unreadable>>"
    }

    private func p(_ label: String, _ value: Any) { ProbeLog.write("\(label): \(value)") }

    // MARK: - P6  research note, new and update

    func test_probe6_researchNote() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let r1res = try await performer.perform(try plan(.scrap(a), .researchNote,
                                                         store: store, model: model))
        p("new result id/title", "\(r1res.createdItemID ?? "nil") / \(r1res.title)")
        p("new result links", r1res.writtenLinks.count)
        p("mark on node", model.scene.node(a)?.promotedItemID ?? "nil")
        p("contribution on node", model.scene.node(a)?.contributedToItemID ?? "nil")
        let itemID = r1res.createdItemID!
        p("file body", bodyOf(itemID, store: store, root: root).debugDescription)
        p("item path", TreeWalk.find(id: itemID, in: store.manifest.research)?.path ?? "nil")
        p("confirmation", r1res.confirmation(for: try plan(.scrap(a), .researchNote,
                                                           store: store, model: model)))

        // The writer edits the note and renames it
        let path = TreeWalk.find(id: itemID, in: store.manifest.research)!.path!
        try "The falls at night\n\nAn afternoon of my own prose.\n"
            .write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try await store.updateResearchItem(id: itemID, title: "Fog, act II")
        p("after writer rename: title", TreeWalk.find(id: itemID, in: store.manifest.research)!.title)
        p("after writer rename: path", TreeWalk.find(id: itemID, in: store.manifest.research)!.path!)

        // Re-promote with Update
        let existing = Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                  in: model.scene, artifacts: index(store))
        p("offered mode", String(describing: existing))
        model.setScrapText("The falls at night\n\nRewritten on the canvas.", for: a)
        let upd = try await performer.perform(
            try plan(.scrap(a), .researchNote, store: store, model: model, mode: existing!))
        p("update result title", upd.title)
        p("update body", bodyOf(itemID, store: store, root: root).debugDescription)
        p("update item title", TreeWalk.find(id: itemID, in: store.manifest.research)!.title)
        p("update item path", TreeWalk.find(id: itemID, in: store.manifest.research)!.path!)
        p("old file still there",
          FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        p("destination of the update plan",
          try plan(.scrap(a), .researchNote, store: store, model: model, mode: existing!)
            .destinationDescription)

        // Update whose artifact has been deleted from the manifest
        let ghost = PromotionMode.update(itemID: "gone-id", title: "Gone")
        do {
            _ = try await performer.perform(
                try plan(.scrap(a), .researchNote, store: store, model: model, mode: ghost))
            p("update against a missing artifact", "no throw")
        } catch {
            p("update against a missing artifact",
              (error as? PromotionFailure)?.errorDescription ?? "\(error)")
        }
        // Update whose artifact is a palette card
        let card = try await store.addPaletteCard(title: "Cardy", kind: .other)
        do {
            _ = try await performer.perform(
                try plan(.scrap(a), .researchNote, store: store, model: model,
                         mode: .update(itemID: card.id, title: card.title)))
            p("update against a palette card", "no throw")
        } catch {
            p("update against a palette card",
              (error as? PromotionFailure)?.errorDescription ?? "\(error)")
        }
        p("palette card body after the refused update",
          store.loadPaletteCards().first(where: { $0.researchItemId == card.id })?.body ?? "nil")

        // Empty title
        var emptyTitled = try plan(.scrap(a), .researchNote, store: store, model: model)
        emptyTitled.title = "   "
        do {
            _ = try await performer.perform(emptyTitled)
            p("empty title", "no throw")
        } catch { p("empty title", (error as? PromotionFailure)?.errorDescription ?? "\(error)") }
    }

    // MARK: - P7  region: contributors, palette, links

    func test_probe7_region() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        // promote member a first so the region offers a link
        _ = try await performer.perform(try plan(.scrap(a), .researchNote,
                                                 store: store, model: model))
        var regionPlan = try plan(.region(r1), .researchNote, store: store, model: model)
        p("region offeredLinks", regionPlan.offeredLinks.map { "\($0.node.raw)=\($0.title)" })
        p("region contributors", regionPlan.contributors.map(\.raw))
        regionPlan.linksAccepted = true
        let res = try await performer.perform(regionPlan)
        p("region result", "\(res.createdItemID ?? "nil") / \(res.title) / links=\(res.writtenLinks.map(\.raw))")
        p("region confirmation", res.confirmation(for: regionPlan))
        p("region mark", model.scene.region(r1)?.promotedItemID ?? "nil")
        p("contribution a", model.scene.node(a)?.contributedToItemID ?? "nil")
        p("contribution b", model.scene.node(b)?.contributedToItemID ?? "nil")
        p("mark a (still its own note)", model.scene.node(a)?.promotedItemID ?? "nil")
        p("member a's note body after the link write",
          bodyOf(model.scene.node(a)!.promotedItemID!, store: store, root: root).debugDescription)
        p("region note body", bodyOf(res.createdItemID!, store: store, root: root).debugDescription)

        // Re-promote with a changed membership: b leaves, c joins
        model.withScene {
            $0.insert(CanvasNode(id: c, kind: .scrap, origin: CGPoint(x: 0, y: 300),
                                 width: 100, cachedHeight: 10))
            CanvasMembership.leave(b, from: r1, in: &$0)
            CanvasMembership.join(c, home: r1, in: &$0)
        }
        model.setScrapText("A newcomer", for: c)
        let existing = Promotion.existingArtifact(for: .region(r1), target: .researchNote,
                                                  in: model.scene, artifacts: index(store))
        let upd = try await performer.perform(
            try plan(.region(r1), .researchNote, store: store, model: model, mode: existing!))
        p("re-promote body", bodyOf(upd.createdItemID!, store: store, root: root).debugDescription)
        p("contribution a after re-promote", model.scene.node(a)?.contributedToItemID ?? "nil")
        p("contribution b after re-promote (left the region)",
          model.scene.node(b)?.contributedToItemID ?? "nil")
        p("contribution c after re-promote", model.scene.node(c)?.contributedToItemID ?? "nil")

        // A second region promoted with a shared member: most recent wins?
        model.withScene {
            $0.insertRegion(CanvasRegion(id: r2, label: "Other",
                                         frame: CGRect(x: 0, y: 800, width: 300, height: 300),
                                         homeMembers: []))
            CanvasMembership.join(a, home: r2, in: &$0)
        }
        let res2 = try await performer.perform(try plan(.region(r2), .researchNote,
                                                        store: store, model: model))
        p("contribution a after joining and promoting r2",
          model.scene.node(a)?.contributedToItemID ?? "nil")
        p("r2 artifact", res2.createdItemID ?? "nil")
        p("r1 artifact", upd.createdItemID ?? "nil")
    }

    // MARK: - P8  craft intent

    func test_probe8_craftIntent() async throws {
        let (root, store) = try await makeProject()
        try "Chapter 1\n".write(to: root.appendingPathComponent("manuscript/c1.md"),
                                atomically: true, encoding: .utf8)
        store.manifest.structure = [
            StructureItem(id: "ch-1", title: "Chapter 1", type: .document,
                          path: "manuscript/c1.md")]
        try await store.saveManifest()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let res = try await performer.perform(try plan(.scrap(a), .intentStatement,
                                                       store: store, model: model))
        p("intent result", "\(res.createdItemID ?? "nil") / \(res.title)")
        p("intent mark on node", model.scene.node(a)?.promotedItemID ?? "nil")
        let st = store.manifest.statements.first!
        p("intent scope", String(describing: st.scope))
        p("intent text", store.statementText(of: st).debugDescription)
        p("confirmation", res.confirmation(for: try plan(.scrap(a), .intentStatement,
                                                         store: store, model: model)))
        // second promotion of another card appends
        let res2 = try await performer.perform(try plan(.scrap(b), .intentStatement,
                                                        store: store, model: model))
        p("statements count after two promotions", store.manifest.statements.count)
        p("intent text after second", store.statementText(of: store.manifest.statements.first!).debugDescription)
        p("second result id equals first", res2.createdItemID == res.createdItemID)
        // scoped to a chapter
        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "ch-1" } }
        let res3 = try await performer.perform(try plan(.scrap(a), .intentStatement,
                                                        store: store, model: model))
        p("chapter intent title", res3.title)
        p("statements after chapter promotion",
          store.manifest.statements.map { "\($0.kind.rawValue)/\($0.scope.rawValue)" })
        // stale piece falls back to project
        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "nope" } }
        let res4 = try await performer.perform(try plan(.scrap(a), .intentStatement,
                                                        store: store, model: model))
        p("stale piece intent title", res4.title)
        p("statements after stale", store.manifest.statements.count)
    }

    // MARK: - P9  wiki-link

    func test_probe9_wikiLink() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        _ = try await performer.perform(try plan(.scrap(a), .researchNote, store: store, model: model))
        _ = try await performer.perform(try plan(.scrap(b), .researchNote, store: store, model: model))
        let fromID = model.scene.node(a)!.promotedItemID!
        let res = try await performer.perform(try plan(.line(l1), .wikiLink,
                                                       store: store, model: model))
        p("wiki result", "\(res.createdItemID ?? "nil") / \(res.title)")
        p("from note body", bodyOf(fromID, store: store, root: root).debugDescription)
        p("line mark", String(describing: model.scene.line(l1)))
        p("confirmation", res.confirmation(for: try plan(.line(l1), .wikiLink,
                                                         store: store, model: model)))
        // second time
        do {
            _ = try await performer.perform(try plan(.line(l1), .wikiLink,
                                                     store: store, model: model))
            p("second wiki-link", "no throw")
        } catch {
            p("second wiki-link", (error as? PromotionFailure)?.errorDescription ?? "\(error)")
        }
        p("from note body after the refused second",
          bodyOf(fromID, store: store, root: root).debugDescription)
    }

    // MARK: - P10  pictures

    func test_probe10_pictures() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store)
        let path2 = try await ingest(into: store)
        let model = makeModel(at: root)
        model.withScene {
            $0.insert(CanvasNode(id: own, kind: .item(.owned(path: path)),
                                 origin: CGPoint(x: 0, y: 500), width: 180, cachedHeight: 200))
            $0.insert(CanvasNode(id: own2, kind: .item(.owned(path: path2)),
                                 origin: CGPoint(x: 300, y: 500), width: 180, cachedHeight: 200))
        }
        let performer = PromotionPerformer(store: store, model: model)
        let res = try await performer.perform(try plan(.scrap(own), .researchAsset,
                                                       store: store, model: model))
        p("asset result", "\(res.createdItemID ?? "nil") / \(res.title)")
        p("asset item path", TreeWalk.find(id: res.createdItemID!, in: store.manifest.research)?.path ?? "nil")
        p("original still on disk",
          FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        p("owned node kind after promote", String(describing: model.scene.node(own)?.kind))
        p("mark on owned node", model.scene.node(own)?.promotedItemID ?? "nil")
        p("contribution on owned node", model.scene.node(own)?.contributedToItemID ?? "nil")
        p("confirmation", res.confirmation(for: try plan(.scrap(own), .researchAsset,
                                                         store: store, model: model)))
        p("undo step name", model.undoManager.undoMenuItemTitle)

        // palette card image
        let card = try await store.addPaletteCard(title: "Fog", kind: .other)
        var withSwatch = store.loadPaletteCards().first(where: { $0.researchItemId == card.id })!
        withSwatch = PaletteCard(researchItemId: card.id, title: "Fog", kind: .other,
                                 swatches: withSwatch.swatches, notes: withSwatch.notes,
                                 imagePaths: withSwatch.imagePaths, body: "Card prose")
        try await store.updatePaletteCard(withSwatch)
        let pRes = try await performer.perform(
            try plan(.scrap(own2), .paletteCardImage, store: store, model: model,
                     paletteCardID: card.id))
        p("palette image result", "\(pRes.createdItemID ?? "nil") / \(pRes.title)")
        p("mark on own2", model.scene.node(own2)?.promotedItemID ?? "nil")
        p("contribution on own2", model.scene.node(own2)?.contributedToItemID ?? "nil")
        let after = store.loadPaletteCards().first(where: { $0.researchItemId == card.id })!
        p("card images", after.imagePaths)
        p("card body preserved", after.body ?? "nil")
        p("confirmation", pRes.confirmation(for:
            try plan(.scrap(own2), .paletteCardImage, store: store, model: model,
                     paletteCardID: card.id)))
        // second picture onto the same card keeps the first record
        let path3 = try await ingest(into: store)
        model.withScene {
            $0.insert(CanvasNode(id: CanvasNodeID("own3"), kind: .item(.owned(path: path3)),
                                 origin: CGPoint(x: 600, y: 500), width: 180, cachedHeight: 200))
        }
        _ = try await performer.perform(
            try plan(.scrap(CanvasNodeID("own3")), .paletteCardImage, store: store,
                     model: model, paletteCardID: card.id))
        p("first picture's record survives", model.scene.node(own2)?.contributedToItemID ?? "nil")
        p("second picture's record", model.scene.node(CanvasNodeID("own3"))?.contributedToItemID ?? "nil")
        p("card images after second", store.loadPaletteCards()
            .first(where: { $0.researchItemId == card.id })!.imagePaths.count)

        // a plan whose picture has been deleted
        let gonePlan = try plan(.scrap(own), .researchAsset, store: store, model: model)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        do {
            _ = try await performer.perform(gonePlan)
            p("missing picture", "no throw")
        } catch { p("missing picture", (error as? PromotionFailure)?.errorDescription ?? "\(error)") }
        // a picture row with no card, and with a card that is not one
        p("plan with a nil palette card", Promotion.plan(
            PromotionRequest(source: .scrap(own2), target: .paletteCardImage,
                             scraps: model.scraps, artifacts: index(store)),
            in: model.scene) == nil ? "nil plan" : "a plan")
        p("plan with an unknown palette card", Promotion.plan(
            PromotionRequest(source: .scrap(own2), target: .paletteCardImage,
                             scraps: model.scraps, artifacts: index(store),
                             paletteCardID: "not-a-card"),
            in: model.scene) == nil ? "nil plan" : "a plan")
        // the card is deleted between the sheet opening and Commit
        let stalePlan = try plan(.scrap(own2), .paletteCardImage, store: store, model: model,
                                 paletteCardID: card.id)
        store.manifest.research.removeAll { $0.id == card.id }
        try await store.saveManifest()
        do {
            _ = try await performer.perform(stalePlan)
            p("palette card deleted before Commit", "no throw")
        } catch {
            p("palette card deleted before Commit",
              (error as? PromotionFailure)?.errorDescription ?? "\(error)")
        }
        // and with the picture gone TOO — which refusal comes first
        let path4 = try await ingest(into: store)
        model.withScene {
            $0.insert(CanvasNode(id: CanvasNodeID("own4"), kind: .item(.owned(path: path4)),
                                 origin: CGPoint(x: 900, y: 500), width: 180, cachedHeight: 200))
        }
        let card2 = try await store.addPaletteCard(title: "Second", kind: .other)
        let bothPlan = try plan(.scrap(CanvasNodeID("own4")), .paletteCardImage, store: store,
                                model: model, paletteCardID: card2.id)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path4))
        store.manifest.research.removeAll { $0.id == card2.id }
        try await store.saveManifest()
        do {
            _ = try await performer.perform(bothPlan)
            p("picture and card both gone", "no throw")
        } catch {
            p("picture and card both gone",
              (error as? PromotionFailure)?.errorDescription ?? "\(error)")
        }
    }

    // MARK: - P11  region pictures

    func test_probe11_regionPictures() async throws {
        let (root, store) = try await makeProject()
        let path = try await ingest(into: store)
        let model = makeModel(at: root)
        model.withScene {
            $0.insert(CanvasNode(id: own, kind: .item(.owned(path: path)),
                                 origin: CGPoint(x: 0, y: 100), width: 180, cachedHeight: 200))
            CanvasMembership.join(own, home: r1, in: &$0)
        }
        let performer = PromotionPerformer(store: store, model: model)
        let notePlan = try plan(.region(r1), .researchNote, store: store, model: model)
        p("region researchNote discards with a picture in it", notePlan.discards)
        p("region researchNote pictures", notePlan.pictures.count)
        p("region researchNote contributors", notePlan.contributors.map(\.raw))
        let palettePlan = try plan(.region(r1), .paletteCard, store: store, model: model)
        p("region paletteCard discards", palettePlan.discards)
        p("region paletteCard pictures", palettePlan.pictures.map(\.assetPath))
        p("region paletteCard contributors", palettePlan.contributors.map(\.raw))
        let res = try await performer.perform(palettePlan)
        let card = store.loadPaletteCards().first(where: { $0.researchItemId == res.createdItemID })!
        p("card images after region promote", card.imagePaths.count)
        p("card body", (card.body ?? "").debugDescription)
        p("owned node contribution", model.scene.node(own)?.contributedToItemID ?? "nil")
        p("owned node mark", model.scene.node(own)?.promotedItemID ?? "nil")
        // update: pictures not carried again
        let existing = Promotion.existingArtifact(for: .region(r1), target: .paletteCard,
                                                  in: model.scene, artifacts: index(store))
        let updPlan = try plan(.region(r1), .paletteCard, store: store, model: model,
                               mode: existing!)
        p("update plan pictures", updPlan.pictures.count)
        p("update plan discards", updPlan.discards)
        p("update plan contributors", updPlan.contributors.map(\.raw))
        _ = try await performer.perform(updPlan)
        let card2 = store.loadPaletteCards().first(where: { $0.researchItemId == res.createdItemID })!
        p("card images after update", card2.imagePaths.count)
        p("owned node contribution after the update", model.scene.node(own)?.contributedToItemID ?? "nil")

        // a REFERENCED picture in the region
        let assetSrc = temp.url.appendingPathComponent("ref-\(UUID()).png")
        try Data("bytes".utf8).write(to: assetSrc)
        let refItem = try await store.createResearchAsset(scope: .shared, fromURL: assetSrc)
        let items = CanvasItemIndex.over(research: store.manifest.research)
        model.withScene {
            $0.insert(CanvasNode(id: CanvasNodeID("refnode"), kind: .item(.project(id: refItem.id)),
                                 origin: CGPoint(x: 0, y: 150), width: 180, cachedHeight: 200))
            CanvasMembership.join(CanvasNodeID("refnode"), home: r1, in: &$0)
        }
        let refPlan = try plan(.region(r1), .paletteCard, store: store, model: model, items: items)
        p("region palette pictures with a referenced item", refPlan.pictures.map(\.assetPath))
        p("region palette contributors with a referenced item", refPlan.contributors.map(\.raw))
        let refPlanNoIndex = try plan(.region(r1), .paletteCard, store: store, model: model)
        p("same plan built with items: .empty", refPlanNoIndex.pictures.map(\.assetPath))
    }

    // MARK: - P12  a partial failure

    func test_probe12_partialFailure() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        _ = try await performer.perform(try plan(.scrap(a), .researchNote, store: store, model: model))
        let memberID = model.scene.node(a)!.promotedItemID!
        let memberPath = TreeWalk.find(id: memberID, in: store.manifest.research)!.path!
        // Invalid UTF-8 in the member's note
        try Data([0xFF, 0xFE, 0xFF]).write(to: root.appendingPathComponent(memberPath))
        var regionPlan = try plan(.region(r1), .researchNote, store: store, model: model)
        regionPlan.linksAccepted = true
        do {
            let res = try await performer.perform(regionPlan)
            p("promote with an unreadable member", "no throw: \(res.writtenLinks.count) links")
        } catch {
            p("promote with an unreadable member",
              (error as? PromotionFailure)?.errorDescription ?? "\(error)")
        }
        p("region mark after the failure", model.scene.region(r1)?.promotedItemID ?? "nil")
        let created = model.scene.region(r1)?.promotedItemID
        p("region artifact exists in the manifest",
          created.flatMap { TreeWalk.find(id: $0, in: store.manifest.research)?.title } ?? "nil")
        p("region artifact body",
          created.map { bodyOf($0, store: store, root: root).debugDescription } ?? "nil")
        p("contribution stamped despite the failure", model.scene.node(a)?.contributedToItemID ?? "nil")
        p("undo title", model.undoManager.undoMenuItemTitle)

        // an offered member whose artifact has vanished is skipped
        try "ok\n".write(to: root.appendingPathComponent(memberPath), atomically: true, encoding: .utf8)
        model.withScene { $0.setPromotedItem(nil, for: a) }
        _ = try await performer.perform(try plan(.scrap(b), .researchNote, store: store, model: model))
        var p2 = try plan(.region(r1), .researchNote, store: store, model: model)
        p2.linksAccepted = true
        p("offers", p2.offeredLinks.map(\.title))
        // delete b's artifact from the manifest before committing
        let bID = model.scene.node(b)!.promotedItemID!
        store.manifest.research.removeAll { $0.id == bID }
        try await store.saveManifest()
        let res2 = try await performer.perform(p2)
        p("links actually written", res2.writtenLinks.count)
        p("confirmation with zero written", res2.confirmation(for: p2))
    }

    // MARK: - P13  undo, and the flush

    func test_probe13_undoAndFlush() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        let performer = PromotionPerformer(store: store, model: model)
        let res = try await performer.perform(try plan(.scrap(a), .researchNote,
                                                       store: store, model: model))
        p("undo title after promote", model.undoManager.undoMenuItemTitle)
        model.undo.undo()
        p("mark after undo", model.scene.node(a)?.promotedItemID ?? "nil")
        p("artifact still in the manifest",
          TreeWalk.find(id: res.createdItemID!, in: store.manifest.research)?.title ?? "gone")
        p("artifact file still on disk", bodyOf(res.createdItemID!, store: store, root: root).debugDescription)

        // the flush: a queued save for the note's path must not survive the promotion
        let itemID = res.createdItemID!
        let path = TreeWalk.find(id: itemID, in: store.manifest.research)!.path!
        store.documentStore?.scheduleFileSave(for: path, text: "STALE PANE CONTENT")
        model.setScrapText("The falls at night\n\nFresh from the canvas.", for: a)
        model.withScene { $0.setPromotedItem(itemID, for: a) }
        _ = try await performer.perform(
            try plan(.scrap(a), .researchNote, store: store, model: model,
                     mode: .update(itemID: itemID, title: "x")))
        p("body right after the promotion", bodyOf(itemID, store: store, root: root).debugDescription)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        p("body after the debounce window", bodyOf(itemID, store: store, root: root).debugDescription)
    }
}
