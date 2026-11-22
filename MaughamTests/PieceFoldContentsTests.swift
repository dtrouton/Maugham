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

    /// **A bound region is one group row holding its cards in the canvas's
    /// visual order; a card bound to the piece itself stays a plain row**
    /// (owner, 2026-11-20).
    func test_aBoundRegionIsOneGroupWithItsCardsInOrderThenTheLooseCards() {
        var s = CanvasScene()
        // Placed out of id order, so reading order is what the test sees.
        let lower = CanvasNodeID("a")
        let upper = CanvasNodeID("b")
        let loose = CanvasNodeID("c")
        s.insert(CanvasNode(id: lower, kind: .scrap, origin: CGPoint(x: 0, y: 200),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: upper, kind: .scrap, origin: CGPoint(x: 0, y: 0),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: loose, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        let region = CanvasRegionID("r1")
        s.insertRegion(CanvasRegion(id: region, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        RegionBinding.bind(region, toPiece: novelChapter, in: &s)
        CanvasMembership.join(lower, home: region, in: &s)
        CanvasMembership.join(upper, home: region, in: &s)
        s.setBoundPiece(novelChapter, for: loose)

        let out = entries(for: novelChapter, structure: [chapter(novelChapter, "One")],
                          research: [], projectType: .novel, scene: s,
                          scraps: [lower: "lower", upper: "upper", loose: "on its own"])
        guard out.count == 2,
              case .region(let id, let title, let cards) = out[0],
              case .card(let single) = out[1] else {
            return XCTFail("expected one region and one loose card, got \(out)")
        }
        XCTAssertEqual(id, region.raw)
        XCTAssertEqual(title, "Act II fog")
        XCTAssertEqual(cards.map(\.id), [upper.raw, lower.raw],
                       "the region's cards in the canvas's visual order, top to bottom")
        XCTAssertEqual(cards.map(\.id),
                       PinnedReferences.readingOrder(ofRegion: region, in: s).map(\.raw),
                       "the one ordering, the shelf's")
        XCTAssertEqual(single.id, loose.raw, "a card bound to the piece itself is a plain row")
        XCTAssertEqual(out.map(\.group), [.cards, .cards], "a region lives in the Cards group")
        XCTAssertEqual(out[0].pulledUp, .canvasRegion(id: region.raw), "its row pulls the region up")
        XCTAssertEqual(out[0].regionCards, cards.map(PieceFoldEntry.card))
    }

    /// A region is told from the loose cards by its id, never its title: a
    /// region the writer titled "Cards" is still a region.
    func test_aRegionTitledCardsIsStillARegion() {
        var s = CanvasScene()
        let inRegion = CanvasNodeID("a")
        s.insert(CanvasNode(id: inRegion, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        let region = CanvasRegionID("r1")
        s.insertRegion(CanvasRegion(id: region, label: PinnedShelf.looseCardsTitle,
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        RegionBinding.bind(region, toPiece: novelChapter, in: &s)
        CanvasMembership.join(inRegion, home: region, in: &s)
        let out = entries(for: novelChapter, structure: [chapter(novelChapter, "One")],
                          research: [], projectType: .novel, scene: s, scraps: [inRegion: "x"])
        XCTAssertEqual(out.map(\.id), ["region:r1"])
    }

    /// A region counts as one entry toward the six past which the fold groups.
    func test_aRegionIsOneEntryTowardTheGroupingRule() {
        let cards = (0..<5).map { PinnedReference(id: "n\($0)", kind: .scrap(nodeId: "n\($0)"), title: "S") }
        let six: [PieceFoldEntry] = researchEntries(5) + [.region(id: "r1", title: "Fog", cards: cards)]
        XCTAssertEqual(PieceFoldLayout.of(six), .rows(six), "five notes and a five-card region are six rows")
        let seven = six + [.link(pieceId: "ch-2", title: "Two", incoming: false)]
        guard case .groups(let runs) = PieceFoldLayout.of(seven) else { return XCTFail("seven group") }
        XCTAssertEqual(runs.map(\.group), [.research, .cards, .links])
        XCTAssertEqual(runs[1].entries.map(\.id), ["region:r1"], "the region row lives inside Cards")
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
        func key(_ modified: Date, _ revision: Int?, _ writes: Int) -> PieceFoldIndex.Key {
            PieceFoldIndex.Key(modified: modified,
                               canvas: CanvasCardsRevision(sceneRevision: revision, closedCanvasWrites: writes))
        }
        let base = key(t0, nil, 0)
        XCTAssertEqual(base, key(t0, nil, 0))

        XCTAssertNotEqual(base, key(t0.addingTimeInterval(1), nil, 0),
                          "a manifest change (research, pins, links, figures) moves the key")
        XCTAssertNotEqual(base, key(t0, 0, 0),
                          "the canvas becoming live moves the key: the live model is ahead "
                          + "of the sidecar")
        XCTAssertNotEqual(key(t0, 3, 0), key(t0, 4, 0), "a structural canvas edit moves the key")
        XCTAssertNotEqual(base, key(t0, nil, 1),
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
            ".task(id: PieceFoldIndex.key(store: store, canvasWrites: state.closedCanvasWrites)) {\n"
            + "                state.foldIndexBase = PieceFoldIndex.build(store: store, projectRoot: store.url)"),
            "the build is the .task's body, keyed on the fold key")
        // The count is the window's, kept with the tree hidden (appraisal wave).
        let wiring = try SourceTree.read("Maugham/Views/TreeWindowWiring.swift")
        XCTAssertTrue(wiring.contains(
            ".onProjectEvent(.maughamCanvasNodesAdded, url: url, window: window) { _ in\n"
            + "                state.closedCanvasWrites += 1"),
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

    // MARK: - A row's glyph is the canvas's (the References shelf's row tests, at the fold)

    private func glyphResearch() -> [ResearchItem] {
        [paletteGroup([card("res-card", "Act II fog")]),
         note("res-note", "The falls at night", path: "research/the-falls-at-night.md"),
         ResearchItem(id: "res-photo", title: "The gorge from above", type: .asset, kind: .image,
                      path: "research/research_assets/gorge.jpg"),
         ResearchItem(id: "res-pdf", title: "Survey", type: .asset, kind: .pdf,
                      path: "research/research_assets/survey.pdf"),
         ResearchItem(id: "res-audio", title: "Interview", type: .asset, kind: .audio,
                      path: "research/research_assets/interview.m4a")]
    }

    private func cardEntry(_ id: String, _ kind: PinnedReference.Kind) -> PieceFoldEntry {
        .card(PinnedReference(id: id, kind: kind, title: id))
    }

    /// **A fold row's glyph is `CanvasItemFacts`' — the canvas's own table,
    /// and no second one** (the old shelf's rule; the fold spelled its own for
    /// one task, so a pinned PDF, recording or picture drew `doc.text` where
    /// the board draws its real glyph).
    func test_aCardRowsGlyphIsTheCanvasesForEveryKindOfItem() {
        let items = CanvasItemIndex.over(research: glyphResearch())
        let expected: [(PieceFoldEntry, String)] = [
            (cardEntry("res-note", .research(itemId: "res-note")), CanvasItemKind.researchNote.glyph),
            (cardEntry("res-photo", .research(itemId: "res-photo")), CanvasItemKind.image.glyph),
            (cardEntry("res-pdf", .research(itemId: "res-pdf")), CanvasItemKind.pdf.glyph),
            (cardEntry("res-audio", .research(itemId: "res-audio")), CanvasItemKind.audio.glyph),
            (cardEntry("res-card", .palette(cardId: "res-card")), CanvasItemKind.paletteCard.glyph),
            (.palette(id: "res-card", title: "Act II fog"), CanvasItemKind.paletteCard.glyph),
        ]
        for (entry, glyph) in expected {
            XCTAssertEqual(PieceFoldIndex.glyph(for: entry, in: items), glyph, entry.id)
            // …and it is the very answer the canvas gives for the same item.
            if case .card(let ref) = entry, case .research(let id) = ref.kind {
                XCTAssertEqual(glyph, CanvasItemFacts.resolve(.project(id: id), in: items).glyph)
            }
        }
        XCTAssertEqual(Set(expected.map(\.1)).count, 5,
                       "premise: the five kinds draw five different glyphs")
        // The index resolves them once, with the entries; a row looks its up.
        let index = PieceFoldIndex(entries: ["ch-1": expected.map(\.0)], items: items)
        for (entry, glyph) in expected {
            XCTAssertEqual(index.glyph(of: entry), glyph, entry.id)
        }
    }

    /// An *owned* picture has no manifest entry and never will, so it resolves
    /// against an empty index.
    func test_anOwnedPhotoRowResolvesWithoutAManifestEntry() {
        let entry = cardEntry("canvas_assets/image-1.png", .photo(path: "canvas_assets/image-1.png"))
        XCTAssertEqual(PieceFoldIndex.glyph(for: entry, in: .empty), CanvasItemKind.image.glyph)
    }

    /// **A scrap is not an item and has no `CanvasItemKind`**: its glyph is
    /// the fold's one glyph of its own, and never an item kind's — sharing one
    /// would make the two unreadable apart.
    func test_aScrapRowUsesTheScrapGlyphAndNeverAnItemKind() {
        let entry = cardEntry("n1", .scrap(nodeId: "n1"))
        XCTAssertEqual(PieceFoldIndex.glyph(for: entry, in: .empty), PieceFoldIndex.scrapGlyph)
        XCTAssertFalse(CanvasItemKind.allCases.map(\.glyph).contains(PieceFoldIndex.scrapGlyph))
    }

    /// A card whose item left the project draws the canvas's missing glyph;
    /// a research row, a figure and a link are not canvas items and have none.
    func test_aGoneItemDrawsTheMissingGlyphAndNonItemsHaveNone() {
        XCTAssertEqual(PieceFoldIndex.glyph(for: cardEntry("gone", .research(itemId: "gone")), in: .empty),
                       CanvasItemKind.missingGlyph)
        for entry in [PieceFoldEntry.research(id: "r", title: "R", owned: true),
                      .figure(id: "f", name: "F"), .link(pieceId: "p", title: "P", incoming: false)] {
            XCTAssertNil(PieceFoldIndex.glyph(for: entry, in: .empty), entry.id)
        }
    }

    /// The fold's view spells no glyph table of its own, and draws no
    /// thumbnail (the shelf's thumbnails are gone by design: the tree's rows
    /// are one line with a glyph).
    func test_theFoldSpellsNoGlyphTableAndDrawsNoThumbnail() throws {
        let fold = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/BinderPieceFold.swift"))
            .joined(separator: "\n")
        XCTAssertFalse(fold.contains("cardGlyph"), "the fold's own table is back")
        for literal in CanvasItemKind.allCases.map(\.glyph) where literal != "link" {
            XCTAssertFalse(fold.contains("\"\(literal)\""),
                           "the fold spells the item glyph \"\(literal)\" itself")
        }
        XCTAssertEqual(fold.components(separatedBy: "state.foldIndex.glyph(of: entry)").count - 1, 3,
                       "the card row, the region row and the palette row each ask the index")
        XCTAssertFalse(fold.contains("CanvasThumbnails") || fold.contains("thumbnailPath"),
                       "no thumbnail is drawn in the tree")
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
