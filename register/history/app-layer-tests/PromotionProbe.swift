import XCTest
import MaughamCore
@testable import Maugham

/// PROBE — prints observed behaviour. No assertions about what I expect.
/// Characterisation assertions are written FROM this output.
@MainActor
final class PromotionProbe: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let c = CanvasNodeID("c")
    private let ref = CanvasNodeID("refnode")
    private let own = CanvasNodeID("ownnode")
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

    private func makeProject(type: ProjectType = .novel) async throws -> (URL, ProjectStore) {
        let tmp = temp.url.appendingPathComponent("PR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for sub in ["manuscript", "research"] {
            try FileManager.default.createDirectory(
                at: tmp.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let manifest = ProjectManifest(
            type: type, title: "T", author: "A",
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

    private func ingest(into store: ProjectStore, named: String = "shot.png") async throws
        -> String {
        let source = temp.url.appendingPathComponent("dropped-\(UUID())-\(named)")
        try Data("bytes".utf8).write(to: source)
        return try await store.ingestCanvasAsset(fileURL: source)
    }

    private func body(_ item: ResearchItem, in root: URL) -> String {
        (try? String(contentsOf: root.appendingPathComponent(item.path ?? ""),
                     encoding: .utf8)) ?? "<<unreadable>>"
    }

    private func p(_ label: String, _ value: Any) { ProbeLog.write("\(label): \(value)") }

    // MARK: - P1  targets and blockedReason

    func test_probe1_targetsAndBlockedReason() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        var idx = index(store)

        p("scrap targets", Promotion.targets(for: .scrap(a), in: model.scene, artifacts: idx))
        p("scrap blocked", Promotion.blockedReason(for: .scrap(a), in: model.scene,
                                                   scraps: model.scraps, artifacts: idx) ?? "nil")
        model.setScrapText("   ", for: c)
        model.withScene { $0.insert(CanvasNode(id: c, kind: .scrap, origin: .zero,
                                               width: 100, cachedHeight: 10)) }
        p("empty scrap targets", Promotion.targets(for: .scrap(c), in: model.scene, artifacts: idx))
        p("empty scrap blocked", Promotion.blockedReason(for: .scrap(c), in: model.scene,
                                                         scraps: model.scraps, artifacts: idx) ?? "nil")
        p("missing node targets",
          Promotion.targets(for: .scrap(CanvasNodeID("zz")), in: model.scene, artifacts: idx))
        p("missing node blocked",
          Promotion.blockedReason(for: .scrap(CanvasNodeID("zz")), in: model.scene,
                                  scraps: model.scraps, artifacts: idx) ?? "nil")

        // item nodes
        let path = try await ingest(into: store)
        model.withScene {
            $0.insert(CanvasNode(id: ref, kind: .item(.project(id: "res-1")),
                                 origin: CGPoint(x: 900, y: 0), width: 180, cachedHeight: 200))
            $0.insert(CanvasNode(id: own, kind: .item(.owned(path: path)),
                                 origin: CGPoint(x: 900, y: 300), width: 180, cachedHeight: 200))
        }
        p("referenced targets", Promotion.targets(for: .scrap(ref), in: model.scene, artifacts: idx))
        p("referenced blocked", Promotion.blockedReason(for: .scrap(ref), in: model.scene,
                                                        scraps: model.scraps, artifacts: idx) ?? "nil")
        p("owned targets (no palette cards)",
          Promotion.targets(for: .scrap(own), in: model.scene, artifacts: idx))
        p("owned blocked", Promotion.blockedReason(for: .scrap(own), in: model.scene,
                                                   scraps: model.scraps, artifacts: idx) ?? "nil")
        _ = try await store.addPaletteCard(title: "Fog", kind: .other)
        idx = index(store)
        p("owned targets (one palette card)",
          Promotion.targets(for: .scrap(own), in: model.scene, artifacts: idx))

        // region
        p("region targets", Promotion.targets(for: .region(r1), in: model.scene, artifacts: idx))
        p("region blocked", Promotion.blockedReason(for: .region(r1), in: model.scene,
                                                    scraps: model.scraps, artifacts: idx) ?? "nil")
        model.withScene { $0.insertRegion(CanvasRegion(id: r2, label: "",
                                                       frame: CGRect(x: 0, y: 900, width: 100, height: 100),
                                                       homeMembers: [])) }
        p("empty region targets", Promotion.targets(for: .region(r2), in: model.scene, artifacts: idx))
        p("empty region blocked", Promotion.blockedReason(for: .region(r2), in: model.scene,
                                                          scraps: model.scraps, artifacts: idx) ?? "nil")

        // line
        p("line targets (unpromoted)", Promotion.targets(for: .line(l1), in: model.scene, artifacts: idx))
        p("line blocked (unpromoted)", Promotion.blockedReason(for: .line(l1), in: model.scene,
                                                               scraps: model.scraps, artifacts: idx) ?? "nil")
        model.withScene {
            $0.setPromotedItem("ghost-id", for: a)
            $0.setPromotedItem("ghost-id2", for: b)
        }
        p("line blocked (dangling marks)", Promotion.blockedReason(for: .line(l1), in: model.scene,
                                                                   scraps: model.scraps, artifacts: idx) ?? "nil")
        let note = try await store.createResearchNote(scope: .shared, title: "Note A")
        let note2 = try await store.createResearchNote(scope: .shared, title: "Note B")
        idx = index(store)
        model.withScene {
            $0.setPromotedItem(note.id, for: a)
            $0.setPromotedItem(note2.id, for: b)
        }
        p("line targets (both promoted)", Promotion.targets(for: .line(l1), in: model.scene, artifacts: idx))
        p("line blocked (both promoted)", Promotion.blockedReason(for: .line(l1), in: model.scene,
                                                                  scraps: model.scraps, artifacts: idx) ?? "nil")
        model.withScene { $0.insertLine(CanvasLine(id: CanvasLineID("l2"), from: a, to: own)) }
        p("line to an item node blocked",
          Promotion.blockedReason(for: .line(CanvasLineID("l2")), in: model.scene,
                                  scraps: model.scraps, artifacts: idx) ?? "nil")
    }

    // MARK: - P2  plan shapes

    func test_probe2_planShapes() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let idx = index(store)
        let before = model.scene

        func plan(_ s: PromotionSource, _ t: PromotionTarget,
                  mode: PromotionMode = .new) -> PromotionPlan? {
            Promotion.plan(PromotionRequest(source: s, target: t, mode: mode,
                                            scraps: model.scraps, artifacts: idx),
                           in: model.scene)
        }
        if let pl = plan(.scrap(a), .researchNote) {
            p("scrap plan title", pl.title)
            p("scrap plan body", pl.body)
            p("scrap plan destination", pl.destinationDescription)
            p("scrap plan discards", pl.discards)
            p("scrap plan contributors", pl.contributors)
            p("scrap plan pictures", pl.pictures.count)
            p("scrap plan offeredLinks", pl.offeredLinks.count)
            p("scrap plan linksAccepted default", pl.linksAccepted)
        }
        p("scrap plan palette destination", plan(.scrap(a), .paletteCard)?.destinationDescription ?? "nil")
        p("scrap plan intent destination", plan(.scrap(a), .intentStatement)?.destinationDescription ?? "nil")
        if let pl = plan(.region(r1), .researchNote) {
            p("region plan title", pl.title)
            p("region plan body", pl.body.replacingOccurrences(of: "\n", with: "\\n"))
            p("region plan discards", pl.discards)
            p("region plan contributors", pl.contributors.map(\.raw))
            p("region plan destination", pl.destinationDescription)
        }
        // reading order: move b above a
        model.withScene { $0.move(b, to: CGPoint(x: 0, y: -500)) }
        p("region plan body after reorder",
          plan(.region(r1), .researchNote)?.body.replacingOccurrences(of: "\n", with: "\\n") ?? "nil")
        p("region contributors after reorder",
          plan(.region(r1), .researchNote)?.contributors.map(\.raw) ?? [])
        model.withScene { $0.move(b, to: CGPoint(x: 0, y: 200)) }

        // an empty member is dropped
        model.withScene {
            $0.insert(CanvasNode(id: c, kind: .scrap, origin: CGPoint(x: 0, y: 400),
                                 width: 100, cachedHeight: 10))
            CanvasMembership.join(c, home: r1, in: &$0)
        }
        p("region plan contributors with an empty member",
          plan(.region(r1), .researchNote)?.contributors.map(\.raw) ?? [])

        p("untitled region title",
          Promotion.plan(PromotionRequest(source: .region(r2), target: .researchNote,
                                          scraps: model.scraps, artifacts: idx),
                         in: model.scene)?.title ?? "nil-plan")
        p("scene unchanged by planning", before == model.scene)

        p("title(from:) leading spaces", Promotion.title(from: "   Hello there  \nsecond"))
        p("title(from:) empty", "[" + Promotion.title(from: "") + "]")
        p("linkText no label", Promotion.linkText(to: "X", label: nil))
        p("linkText blank label", Promotion.linkText(to: "X", label: "   "))
        p("linkText label", Promotion.linkText(to: "X", label: "because"))
    }

    // MARK: - P3  line plan / duplicate detection

    func test_probe3_linePlan() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let n1 = try await store.createResearchNote(scope: .shared, title: "From note")
        let n2 = try await store.createResearchNote(scope: .shared, title: "To note")
        model.withScene {
            $0.setPromotedItem(n1.id, for: a)
            $0.setPromotedItem(n2.id, for: b)
        }
        let idx = index(store)
        func plan(_ body: String?) -> PromotionPlan? {
            Promotion.plan(PromotionRequest(source: .line(l1), target: .wikiLink,
                                            scraps: model.scraps, artifacts: idx,
                                            destinationBody: body),
                           in: model.scene)
        }
        if let pl = plan(nil) {
            p("line plan title", pl.title)
            p("line plan body", pl.body)
            p("line plan destination", pl.destinationDescription)
            p("line plan write into", pl.wikiLinkWrite!.intoItemID == n1.id ? "from-end" : "to-end")
            p("line plan appendedText", pl.wikiLinkWrite!.appendedText.debugDescription)
            p("line plan mode", pl.mode)
        }
        p("linkAlreadyPresent exact", plan("prose\n\n[[To note]]\n")?.linkAlreadyPresent ?? "nil")
        p("linkAlreadyPresent when body has a LABELLED form",
          plan("prose\n\n[[To note]] — why\n")?.linkAlreadyPresent ?? "nil")
        p("linkAlreadyPresent substring of a longer title",
          plan("prose\n\n[[To notebook]]\n")?.linkAlreadyPresent ?? "nil")
        model.withScene { $0.updateLine(l1) { $0.label = "why" } }
        p("labelled line plan body", plan(nil)?.body ?? "nil")
        p("labelled line vs unlabelled body present",
          plan("[[To note]]\n")?.linkAlreadyPresent ?? "nil")
        model.withScene { $0.updateLine(l1) { $0.label = nil } }

        // from-end is a craft-intent statement
        try await withChapter(root, store)
        let st = try await store.createStatement(kind: .intent, scope: .document("ch-1"))
        model.withScene { $0.setPromotedItem(st.id, for: a) }
        let idx2 = index(store)
        let pl2 = Promotion.plan(PromotionRequest(source: .line(l1), target: .wikiLink,
                                                  scraps: model.scraps, artifacts: idx2),
                                 in: model.scene)
        p("line-from-statement destination", pl2?.destinationDescription ?? "nil")
        p("statement title in index", idx2.title(of: st.id) ?? "nil")
        p("statement kind in index", String(describing: idx2.kind(of: st.id)))
    }

    // MARK: - P4  existingArtifact / modes

    func test_probe4_modes() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let note = try await store.createResearchNote(scope: .shared, title: "Note A")
        model.withScene { $0.setPromotedItem(note.id, for: a) }
        var idx = index(store)
        p("existing for researchNote", String(describing:
            Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                       in: model.scene, artifacts: idx)))
        p("existing for paletteCard (mark is a note)", String(describing:
            Promotion.existingArtifact(for: .scrap(a), target: .paletteCard,
                                       in: model.scene, artifacts: idx)))
        p("existing for intentStatement", String(describing:
            Promotion.existingArtifact(for: .scrap(a), target: .intentStatement,
                                       in: model.scene, artifacts: idx)))
        p("modes for researchNote", Promotion.modes(for: .researchNote, existing:
            Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                       in: model.scene, artifacts: idx)).map(\.id))
        // dangling mark
        model.withScene { $0.setPromotedItem("gone", for: a) }
        p("existing with a dangling mark", String(describing:
            Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                       in: model.scene, artifacts: idx)))
        // mark names a palette card
        let card = try await store.addPaletteCard(title: "Fog", kind: .other)
        idx = index(store)
        model.withScene { $0.setPromotedItem(card.id, for: a) }
        p("existing researchNote when mark is a palette card", String(describing:
            Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                       in: model.scene, artifacts: idx)))
        p("existing paletteCard when mark is a palette card", String(describing:
            Promotion.existingArtifact(for: .scrap(a), target: .paletteCard,
                                       in: model.scene, artifacts: idx)))
        p("index kind of palette card", String(describing: idx.kind(of: card.id)))
        // contribution record is not read
        model.withScene {
            $0.setPromotedItem(nil, for: a)
            $0.setContributedItem(note.id, for: a)
        }
        p("existing from a contribution record only", String(describing:
            Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                       in: model.scene, artifacts: idx)))
        p("region existing (no mark)", String(describing:
            Promotion.existingArtifact(for: .region(r1), target: .researchNote,
                                       in: model.scene, artifacts: idx)))
        p("line existing", String(describing:
            Promotion.existingArtifact(for: .line(l1), target: .researchNote,
                                       in: model.scene, artifacts: idx)))
        p("updatableTargets", Promotion.updatableTargets.map(\.rawValue).sorted())
        p("scopedTargets", Promotion.scopedTargets.map(\.rawValue).sorted())
        for t in PromotionTarget.allCases {
            p("target \(t.rawValue) namesItsArtifact/producedKind",
              "\(t.namesItsArtifact) / \(String(describing: t.producedArtifactKind)) / \(t.writerFacingName)")
        }
    }

    // MARK: - P5  piece precedence

    func test_probe5_piece() async throws {
        let (root, store) = try await makeProject()
        try await withChapter(root, store)
        let model = makeModel(at: root)
        p("piece none", String(describing: Promotion.piece(for: .scrap(a), in: model.scene)))
        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "ch-1" } }
        p("piece inherited from home region",
          String(describing: Promotion.piece(for: .scrap(a), in: model.scene)))
        p("pieceIsInherited", Promotion.pieceIsInherited(for: .scrap(a), in: model.scene))
        model.withScene { $0.setBoundPiece("own-piece", for: a) }
        p("piece own wins", String(describing: Promotion.piece(for: .scrap(a), in: model.scene)))
        p("pieceIsInherited with own", Promotion.pieceIsInherited(for: .scrap(a), in: model.scene))
        model.withScene { $0.setBoundPiece(nil, for: a) }
        // visitor: c is an APPEARANCE of r1, not a home member
        model.withScene {
            $0.insert(CanvasNode(id: c, kind: .scrap, origin: CGPoint(x: 0, y: 400),
                                 width: 100, cachedHeight: 10))
            CanvasMembership.addAppearance(c, to: r1, in: &$0)
        }
        p("piece for a visitor", String(describing: Promotion.piece(for: .scrap(c), in: model.scene)))
        p("region piece", String(describing: Promotion.piece(for: .region(r1), in: model.scene)))
        p("line piece", String(describing: Promotion.piece(for: .line(l1), in: model.scene)))
        p("region pieceIsInherited", Promotion.pieceIsInherited(for: .region(r1), in: model.scene))
        p("canCarryItsOwnPiece scrap", Promotion.canCarryItsOwnPiece(.scrap(a), in: model.scene))
        p("canCarryItsOwnPiece region", Promotion.canCarryItsOwnPiece(.region(r1), in: model.scene))
        p("canCarryItsOwnPiece line", Promotion.canCarryItsOwnPiece(.line(l1), in: model.scene))
        let path = try await ingest(into: store)
        model.withScene {
            $0.insert(CanvasNode(id: own, kind: .item(.owned(path: path)),
                                 origin: CGPoint(x: 10, y: 10), width: 100, cachedHeight: 100))
            CanvasMembership.join(own, home: r1, in: &$0)
        }
        p("canCarryItsOwnPiece owned item", Promotion.canCarryItsOwnPiece(.scrap(own), in: model.scene))
        p("owned item inherits piece", String(describing: Promotion.piece(for: .scrap(own), in: model.scene)))

        // resolve against the manifest
        let resolved = PromotionPiece.resolve(for: .scrap(a), in: model.scene, store: store)
        p("resolve novel chapter", String(describing: resolved))
        p("destination for that piece", Promotion.researchNoteDestination(resolved))
        p("palette destination for that piece", Promotion.paletteCardDestination(resolved))
        p("intent destination for that piece", Promotion.craftIntentDestination(resolved))
        model.withScene { $0.updateRegion(r1) { $0.boundPieceID = "not-a-piece" } }
        let stale = PromotionPiece.resolve(for: .scrap(a), in: model.scene, store: store)
        p("resolve deleted piece", String(describing: stale))
        p("destination unroutable", Promotion.researchNoteDestination(stale))
        for target in PromotionTarget.allCases {
            p("pieceFailure \(target.rawValue) new",
              Promotion.pieceFailure(target: target, mode: .new, piece: stale,
                                     canCarryItsOwnPiece: true)?.errorDescription ?? "nil")
        }
        p("pieceFailure researchNote update",
          Promotion.pieceFailure(target: .researchNote, mode: .update(itemID: "x", title: "y"),
                                 piece: stale, canCarryItsOwnPiece: true)?.errorDescription ?? "nil")
        p("pieceFailure inherited/cannot-carry",
          Promotion.pieceFailure(target: .researchNote, mode: .new, piece: stale,
                                 canCarryItsOwnPiece: false)?.errorDescription ?? "nil")
        p("pieceFailure not inherited",
          Promotion.pieceFailure(target: .researchNote, mode: .new,
                                 piece: .unroutable(id: "x", title: "Piece", inherited: false),
                                 canCarryItsOwnPiece: true)?.errorDescription ?? "nil")
    }
}
