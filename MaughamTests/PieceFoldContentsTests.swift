import XCTest
import MaughamCore
@testable import Maugham

/// Shell plan 3 Task 2: **what a piece's fold holds and how it groups.**
///
/// Pure throughout: the shelf is built by the real `PinnedReferences.pinned`
/// (the one projection, reached here as a test may), the research fold by the
/// real `TreeSectionDerivation.pieceFold`, and the fold's entries by
/// `PieceFoldIndex.entries` over those values — no store, no disk, no window.
final class PieceFoldContentsTests: XCTestCase {

    // MARK: - Fixtures

    private let novelChapter = "ch-1"
    private let otherChapter = "ch-2"
    private let piece = "pc-1"

    private func note(_ id: String, _ title: String, path: String) -> ResearchItem {
        ResearchItem(id: id, title: title, type: .asset, kind: .document, path: path)
    }

    /// A palette card lives in the role-stamped palette group, told apart by
    /// position (`CanvasItemIndex`), never by its id.
    private func paletteGroup(_ cards: [ResearchItem]) -> ResearchItem {
        ResearchItem(id: "res-palette", title: "Palette", type: .group,
                     path: PaletteConvention.folderPath, children: cards, role: .paletteGroup)
    }

    private func card(_ id: String, _ title: String) -> ResearchItem {
        ResearchItem(id: id, title: title, type: .asset, kind: .document,
                     path: "research/palette/\(id).md")
    }

    private func chapter(_ id: String, _ title: String, links: [String]? = nil,
                         linkedResearch: [String]? = nil) -> StructureItem {
        StructureItem(id: id, title: title, type: .document, path: "manuscript/\(id).md",
                      links: links, linkedResearchIds: linkedResearch)
    }

    private func loosePiece(_ id: String, _ title: String) -> StructureItem {
        StructureItem(id: id, title: title, type: .document,
                      path: "pieces/\(id)/\(id).md", pieceKind: .loose)
    }

    /// The fold entries for `docId`, every input derived exactly as `build`
    /// derives it — the shelf by the projection, the research fold by the
    /// tree's own derivation.
    private func entries(for docId: String, structure: [StructureItem],
                         research: [ResearchItem], projectType: ProjectType,
                         figures: [FigureRecord] = [], scene: CanvasScene? = nil,
                         scraps: [CanvasNodeID: String] = [:],
                         derived: [String] = []) -> [PieceFoldEntry] {
        let item = TreeWalk.find(id: docId, in: structure)!
        let shelf = PinnedReferences.pinned(
            forDocId: docId, links: item.linkedResearchIds, derived: derived,
            scene: scene, scraps: scraps, items: CanvasItemIndex.over(research: research))
        let fold = TreeSectionDerivation.pieceFold(
            for: item, structure: structure, research: research, projectType: projectType)
        return PieceFoldIndex.entries(docId: docId, shelf: shelf, fold: fold,
                                      figures: figures, links: item.links ?? [],
                                      structure: structure, research: research)
    }

    private func groups(_ entries: [PieceFoldEntry]) -> [PieceFoldGroup] {
        entries.map(\.group)
    }

    // MARK: - Contents and order

    func test_entriesComeInGroupOrder() {
        let research = [note("res-a", "Falls", path: "research/falls.md"),
                        paletteGroup([card("pal-1", "Fog")])]
        let structure = [
            chapter(novelChapter, "One", links: [otherChapter],
                    linkedResearch: ["pal-1", "res-a"]),
            chapter(otherChapter, "Two", links: [novelChapter]),
        ]
        var s = CanvasScene()
        let scrap = CanvasNodeID("s1")
        s.insert(CanvasNode(id: scrap, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        s.setBoundPiece(novelChapter, for: scrap)
        let figures = [FigureRecord(id: "fig-1", name: "Map", kind: .image,
                                    piece: novelChapter, path: "figures/map.png")]

        let out = entries(for: novelChapter, structure: structure, research: research,
                          projectType: .novel, figures: figures, scene: s,
                          scraps: [scrap: "a thought"])

        XCTAssertEqual(groups(out), [.research, .cards, .palette, .figures, .links, .links],
                       "Research, Cards, Palette, Figures, Links — whatever order the shelf "
                       + "met them in (the palette card was linked FIRST)")
        XCTAssertEqual(out.last, .link(pieceId: otherChapter, title: "Two", incoming: true),
                       "the backlink is kept and marked as incoming (controller's amendment)")
        XCTAssertEqual(out[out.count - 2], .link(pieceId: otherChapter, title: "Two",
                                                 incoming: false))
        XCTAssertEqual(Set(out.map(\.id)).count, out.count, "ids are unique within a fold")
    }

    func test_aCollectionPiecesResearchIsOwnedANovelsIsLinked() {
        // A Collection piece OWNS what lives in its own research folder.
        let owned = note("res-own", "Her notebook", path: "pieces/\(piece)/research/notebook.md")
        let collection = entries(for: piece, structure: [loosePiece(piece, "Story")],
                                 research: [owned], projectType: .collection,
                                 derived: ["res-own"])
        XCTAssertEqual(collection, [.research(id: "res-own", title: "Her notebook", owned: true)])

        // A novel's chapter LINKS to shared research.
        let shared = note("res-sh", "The river", path: "research/river.md")
        let novel = entries(for: novelChapter,
                            structure: [chapter(novelChapter, "One", linkedResearch: ["res-sh"])],
                            research: [shared], projectType: .novel)
        XCTAssertEqual(novel, [.research(id: "res-sh", title: "The river", owned: false)])
    }

    /// The shelf's flattened derivation and the fold's section roots both name
    /// the piece's research; a group root is one entry and its contents are
    /// not listed beside it a second time.
    func test_aResearchIdPinnedTwiceAppearsOnce() {
        // Linked twice and listed by the fold too.
        let shared = note("res-sh", "The river", path: "research/river.md")
        let novel = entries(for: novelChapter,
                            structure: [chapter(novelChapter, "One",
                                                linkedResearch: ["res-sh", "res-sh"])],
                            research: [shared], projectType: .novel)
        XCTAssertEqual(novel.map(\.id), ["research:res-sh"])

        // A Collection piece's group root and the asset inside it.
        let inner = note("res-in", "Inside", path: "pieces/\(piece)/research/g/inside.md")
        let group = ResearchItem(id: "res-g", title: "Group", type: .group,
                                 path: "pieces/\(piece)/research/g", children: [inner])
        let collection = entries(for: piece, structure: [loosePiece(piece, "Story")],
                                 research: [group], projectType: .collection,
                                 derived: ["res-in"])
        XCTAssertEqual(collection, [.research(id: "res-g", title: "Group", owned: true)],
                       "the group root is the row; its asset is inside it, not beside it")
    }

    func test_aCardInARegionCarriesTheRegionsTitle() {
        var s = CanvasScene()
        let inRegion = CanvasNodeID("a")
        let loose = CanvasNodeID("b")
        for id in [inRegion, loose] {
            s.insert(CanvasNode(id: id, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        }
        let region = CanvasRegionID("r1")
        s.insertRegion(CanvasRegion(id: region, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        RegionBinding.bind(region, toPiece: novelChapter, in: &s)
        CanvasMembership.join(inRegion, home: region, in: &s)
        s.setBoundPiece(novelChapter, for: loose)

        let out = entries(for: novelChapter, structure: [chapter(novelChapter, "One")],
                          research: [], projectType: .novel, scene: s,
                          scraps: [inRegion: "in the fog", loose: "on its own"])
        guard out.count == 2,
              case .card(let first, let firstRegion) = out[0],
              case .card(let second, let secondRegion) = out[1] else {
            return XCTFail("expected two cards, got \(out)")
        }
        XCTAssertEqual(first.id, inRegion.raw)
        XCTAssertEqual(firstRegion, "Act II fog")
        XCTAssertEqual(second.id, loose.raw)
        XCTAssertNil(secondRegion, "a loose card belongs to no region")
    }

    func test_aFigureOwnedByThePieceIsInItsFold() {
        let figures = [
            FigureRecord(id: "fig-b", name: "Zebra table", kind: .table,
                         piece: novelChapter, path: "figures/b.csv"),
            FigureRecord(id: "fig-a", name: "Atlas", kind: .image,
                         piece: novelChapter, path: "figures/a.png"),
            FigureRecord(id: "fig-o", name: "Other's", kind: .image,
                         piece: otherChapter, path: "figures/o.png"),
            FigureRecord(id: "fig-w", name: "Whole book", kind: .image,
                         piece: nil, path: "figures/w.png"),
        ]
        let out = entries(for: novelChapter,
                          structure: [chapter(novelChapter, "One"), chapter(otherChapter, "Two")],
                          research: [], projectType: .novel, figures: figures)
        XCTAssertEqual(out, [.figure(id: "fig-a", name: "Atlas"),
                             .figure(id: "fig-b", name: "Zebra table")],
                       "the piece's own figures, by name; another piece's and a whole-book "
                       + "figure are not this fold's")
    }

    func test_aLinkToADeletedPieceIsDropped() {
        let structure = [chapter(novelChapter, "One", links: ["ch-gone", otherChapter]),
                         chapter(otherChapter, "Two")]
        let out = entries(for: novelChapter, structure: structure, research: [],
                          projectType: .novel)
        XCTAssertEqual(out, [.link(pieceId: otherChapter, title: "Two", incoming: false)])
    }

    func test_aPinWhoseResearchWasTrashedIsNotAnEntry() {
        // Trash removes the item from `manifest.research`; the link record
        // stays behind. The shelf's dangling rule drops it, and so does the fold.
        let kept = note("res-kept", "Kept", path: "research/kept.md")
        let out = entries(for: novelChapter,
                          structure: [chapter(novelChapter, "One",
                                              linkedResearch: ["res-trashed", "res-kept"])],
                          research: [kept], projectType: .novel)
        XCTAssertEqual(out, [.research(id: "res-kept", title: "Kept", owned: false)])
    }

    /// A Collection reference piece lives in another project: its fold is empty
    /// even where a card on this canvas names it.
    func test_aReferencePieceHasAnEmptyFold() {
        let ref = StructureItem(id: "pc-ref", title: "Elsewhere", type: .document,
                                pieceKind: .reference, linkedProjectPath: "/x/y.maugham",
                                links: [piece])
        var s = CanvasScene()
        let scrap = CanvasNodeID("s1")
        s.insert(CanvasNode(id: scrap, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        s.setBoundPiece("pc-ref", for: scrap)
        let out = entries(for: "pc-ref", structure: [ref, loosePiece(piece, "Story")],
                          research: [], projectType: .collection, scene: s,
                          scraps: [scrap: "x"])
        XCTAssertEqual(out, [])
    }

    // MARK: - Grouping

    private func researchEntries(_ n: Int) -> [PieceFoldEntry] {
        (0..<n).map { .research(id: "r\($0)", title: "R\($0)", owned: false) }
    }

    func test_sixEntriesAreRowsSevenAreGroups() {
        XCTAssertEqual(PieceFoldLayout.groupsAbove, 6)
        let six = researchEntries(6)
        XCTAssertEqual(PieceFoldLayout.of(six), .rows(six))
        let seven = researchEntries(7)
        XCTAssertEqual(PieceFoldLayout.of(seven),
                       .groups([PieceFoldGroupRun(group: .research, entries: seven)]))
        XCTAssertEqual(PieceFoldLayout.of([]), .rows([]))
    }

    /// Review Focus 4: a chapter with forty things pinned to it, one gone.
    func test_fortyPinsGroupWithCountsAndNoEmptyGroup() {
        let notes = (0..<30).map { note("res-\($0)", "Note \($0)", path: "research/n\($0).md") }
        let cards = (0..<10).map { card("pal-\($0)", "Card \($0)") }
        let research = notes + [paletteGroup(cards)]
        // Forty pinned, and one more whose note the writer has since trashed.
        let linked = notes.map(\.id) + cards.map(\.id) + ["res-trashed"]
        let out = entries(for: novelChapter,
                          structure: [chapter(novelChapter, "One", linkedResearch: linked)],
                          research: research, projectType: .novel)
        XCTAssertEqual(out.count, 40, "the trashed pin is dropped, not listed as a code")

        guard case .groups(let runs) = PieceFoldLayout.of(out) else {
            return XCTFail("forty entries must group")
        }
        XCTAssertEqual(runs.map(\.group), [.research, .palette],
                       "only non-empty groups — no Cards, Figures or Links header over nothing")
        XCTAssertEqual(runs.map(\.entries.count), [30, 10])
    }

    // MARK: - The index's key and where it is built

    /// Every signal that changes a fold moves the key, and nothing else is in
    /// it: the manifest (research index, links, pins, figures — every manifest
    /// mutator stamps `modified`), the live canvas's structural revision, and
    /// a closed-canvas write from Claude (`.maughamCanvasNodesAdded`).
    func test_theFoldIndexKeyMovesOnAManifestOrSceneChange() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let base = PieceFoldIndex.Key(modified: t0, sceneRevision: nil, canvasWrites: 0)
        XCTAssertEqual(base, PieceFoldIndex.Key(modified: t0, sceneRevision: nil, canvasWrites: 0))

        XCTAssertNotEqual(base, PieceFoldIndex.Key(modified: t0.addingTimeInterval(1),
                                                   sceneRevision: nil, canvasWrites: 0),
                          "a manifest change (research, pins, links, figures) moves the key")
        XCTAssertNotEqual(base, PieceFoldIndex.Key(modified: t0, sceneRevision: 0, canvasWrites: 0),
                          "the canvas becoming live moves the key: the live model is ahead "
                          + "of the sidecar")
        XCTAssertNotEqual(PieceFoldIndex.Key(modified: t0, sceneRevision: 3, canvasWrites: 0),
                          PieceFoldIndex.Key(modified: t0, sceneRevision: 4, canvasWrites: 0),
                          "a structural canvas edit moves the key")
        XCTAssertNotEqual(base, PieceFoldIndex.Key(modified: t0, sceneRevision: nil, canvasWrites: 1),
                          "Claude's write into a closed canvas's sidecar moves the key")
    }

    func test_theIndexIsBuiltOnlyInATask() throws {
        XCTAssertEqual(try Self.offendingBuildSites(in: Self.appSourceDir), [],
                       "PieceFoldIndex.build( runs once per key inside a tree host's .task, "
                       + "never from a row or a body (tripwire 4)")
        // **The census reads the real call** (shell p3 Task 7): exactly one
        // build, inside the `.task` keyed on the fold key with the host's count
        // of closed-canvas writes, and that count moved by the event.
        let fold = try SourceTree.read("Maugham/Views/BinderPieceFold.swift")
        XCTAssertEqual(fold.components(separatedBy: "PieceFoldIndex.build(").count - 1, 1)
        XCTAssertTrue(fold.contains(
            ".task(id: PieceFoldIndex.key(store: store, canvasWrites: state.foldCanvasWrites)) {\n"
            + "                state.foldIndex = PieceFoldIndex.build(store: store, projectRoot: store.url)"),
            "the build is the .task's body, keyed on the fold key")
        XCTAssertTrue(fold.contains(
            ".onProjectEvent(.maughamCanvasNodesAdded, url: store.url, window: window) { _ in\n"
            + "                state.foldCanvasWrites += 1"),
            "a closed-canvas write moves the key")
        // Both fold hosts attach it, to the list their folds are drawn in.
        for host in ["Maugham/Views/BinderView.swift", "Maugham/Views/CollectionPiecesPane.swift"] {
            let text = try SourceTree.read(host)
            XCTAssertEqual(text.components(separatedBy: ".pieceFoldIndex(store: store, state: treeState)")
                            .count - 1, 1, "\(host) builds the window's fold index once")
        }
    }

    /// The planted offenders, without which the census could be scanning
    /// nothing.
    func test_theBuildCensusCatchesABodyCallAndAStrangeFile() throws {
        let planted = try Self.offendingBuildSites(in: Self.appSourceDir, plus: [
            "BinderView.swift#planted":
                "var body: some View {\n    let index = PieceFoldIndex.build(store: store, projectRoot: url)\n",
            "SomeRow.swift":
                ".task(id: key) {\n    state.foldIndex = PieceFoldIndex.build(store: store, projectRoot: url)\n",
        ])
        XCTAssertEqual(Set(planted), ["BinderView.swift#planted", "SomeRow.swift"])
        let allowed = try Self.offendingBuildSites(in: Self.appSourceDir, plus: [
            "BinderPieceFold.swift#planted":
                ".task(id: PieceFoldIndex.key(store: store, canvasWrites: n)) {\n"
                + "    state.foldIndex = PieceFoldIndex.build(store: store, projectRoot: url)\n",
        ])
        XCTAssertEqual(allowed, [], "a call inside a host's .task is allowed")
    }

    /// The one host: `PieceFoldIndexing`, which both fold trees attach.
    static let buildHosts: Set<String> = ["BinderPieceFold.swift"]
    static let declaringFile = "PieceFoldContents.swift"
    /// How far above a call its `.task` may open.
    static let taskReach = 4

    static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Maugham", isDirectory: true)
    }

    /// Each file (named as its last path component, a planted one by its key)
    /// holding a `PieceFoldIndex.build(` that is outside the two hosts or not
    /// inside a `.task` opened within `taskReach` lines above it.
    static func offendingBuildSites(in root: URL,
                                    plus extra: [String: String] = [:]) throws -> [String] {
        var sources: [(String, String)] = extra.map { ($0.key, $0.value) }
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != declaringFile else { continue }
            sources.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        var offenders: [String] = []
        for (name, text) in sources {
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("PieceFoldIndex.build(") {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let file = String(name.split(separator: "#").first ?? "")
                let above = lines[max(0, i - taskReach)...i].joined(separator: "\n")
                if !buildHosts.contains(file) || !above.contains(".task(") {
                    offenders.append(name)
                }
            }
        }
        return offenders.sorted()
    }
}

/// The index's production seams over a real `ProjectStore`: `key(store:…)`
/// reads each signal off the store, and `build` wires the piece's own
/// `links`, the figure registry and the shelves into `entries`.
@MainActor
final class PieceFoldIndexStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = TestTemp.root.appendingPathComponent("piece-fold-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func project() async throws -> (store: ProjectStore, url: URL) {
        let url = try await ProjectFactory.createNovelProject(named: "Fold", in: root)
        return (try await ProjectStore.load(from: url), url)
    }

    private func attachCanvas(to store: ProjectStore, at url: URL) -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: url)
        store.liveCanvas = model
        return model
    }

    func test_theKeyReadsEachSignalOffTheStore() async throws {
        let (store, url) = try await project()
        let k0 = PieceFoldIndex.key(store: store, canvasWrites: 0)
        XCTAssertEqual(k0, PieceFoldIndex.key(store: store, canvasWrites: 0), "stable at rest")

        store.manifest.modified = store.manifest.modified.addingTimeInterval(5)
        let k1 = PieceFoldIndex.key(store: store, canvasWrites: 0)
        XCTAssertNotEqual(k1, k0, "a manifest change moves the key")

        let model = attachCanvas(to: store, at: url)
        let k2 = PieceFoldIndex.key(store: store, canvasWrites: 0)
        XCTAssertNotEqual(k2, k1, "a canvas going live moves the key")
        model.bumpSceneRevision()
        let k3 = PieceFoldIndex.key(store: store, canvasWrites: 0)
        XCTAssertNotEqual(k3, k2, "a structural canvas change moves the key")

        XCTAssertNotEqual(PieceFoldIndex.key(store: store, canvasWrites: 1), k3,
                          "a closed-canvas write from Claude moves the key")
        withExtendedLifetime(model) {}
    }

    func test_buildListsAPiecesMaterialAndGroupsPastSix() async throws {
        let (store, url) = try await project()
        let note = ResearchItem(id: "res-a", title: "The falls", type: .asset,
                                kind: .document, path: "research/falls.md")
        let extra = ResearchItem(id: "res-b", title: "The gorge", type: .asset,
                                 kind: .document, path: "research/gorge.md")
        let card = ResearchItem(id: "pal-1", title: "Fog", type: .asset, kind: .document,
                                path: "research/palette/fog.md")
        let palette = ResearchItem(id: "res-palette", title: "Palette", type: .group,
                                   path: PaletteConvention.folderPath, children: [card],
                                   role: .paletteGroup)
        store.manifest.research = [note, extra, palette]
        store.manifest.structure = [
            StructureItem(id: "ch-a", title: "Alpha", type: .document,
                          path: "manuscript/a.md", links: ["ch-b"],
                          linkedResearchIds: ["res-a", "pal-1"]),
            StructureItem(id: "ch-b", title: "Beta", type: .document,
                          path: "manuscript/b.md", links: ["ch-a"]),
        ]
        store.manifest.figures = [FigureRecord(id: "fig-1", name: "Map", kind: .image,
                                               piece: "ch-a", path: "figures/map.png")]
        let model = attachCanvas(to: store, at: url)
        let scrap = CanvasNodeID("s1")
        model.mutate("Add") { scene in
            scene.insert(CanvasNode(id: scrap, kind: .scrap, origin: .zero,
                                    width: 240, cachedHeight: 80))
            scene.setBoundPiece("ch-a", for: scrap)
        }

        let index = PieceFoldIndex.build(store: store, projectRoot: url)
        let alpha = try XCTUnwrap(index.entries["ch-a"])
        XCTAssertEqual(alpha.map(\.id), ["research:res-a", "card:s1", "palette:pal-1",
                                         "figure:fig-1", "link:ch-b", "linkedFrom:ch-b"])
        XCTAssertEqual(PieceFoldLayout.of(alpha), .rows(alpha), "six entries are rows")
        XCTAssertEqual(index.entries["ch-b"]?.map(\.id), ["link:ch-a", "linkedFrom:ch-a"])

        // A seventh thing pinned: the fold groups, only the non-empty groups.
        store.manifest.structure[0].linkedResearchIds = ["res-a", "pal-1", "res-b"]
        let grown = try XCTUnwrap(PieceFoldIndex.build(store: store, projectRoot: url)
            .entries["ch-a"])
        guard case .groups(let runs) = PieceFoldLayout.of(grown) else {
            return XCTFail("seven entries must group, got \(grown)")
        }
        XCTAssertEqual(runs.map(\.group), [.research, .cards, .palette, .figures, .links])
        XCTAssertEqual(runs.map(\.entries.count), [2, 1, 1, 1, 2])
        withExtendedLifetime(model) {}
    }
}
