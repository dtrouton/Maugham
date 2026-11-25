import XCTest
import MaughamCore
import SwiftUI
@testable import Maugham

/// Shell p4 Task 10: **a Collection script's fold has its Scenes, and a
/// region holds its palette cards.** Pure where the rule is pure (the fold's
/// entries, a script's sluglines, the index's merge); a store where the rule
/// reads one (which pieces are scripts, the build's grouping).
@MainActor
final class PieceFoldIndexTests: XCTestCase {

    private let chapterId = "ch-1"

    // MARK: - A Collection script's Scenes

    private func paragraphs(_ texts: [String]) -> (sequence: [String], paragraphs: [String: String]) {
        let ids = texts.indices.map { "p\($0)" }
        return (ids, Dictionary(uniqueKeysWithValues: zip(ids, texts)))
    }

    func test_aScriptsSluglinesAreRowsNamingTheParagraphTheyBegin() {
        let (sequence, text) = paragraphs([
            "Title: The Long Walk",
            "INT. KITCHEN - DAY",
            "Larry sits.",
            "EXT. GARDEN - NIGHT",
            "The wind.",
        ])
        let scenes = PieceFoldIndex.sceneEntries(docId: "pc-1", sequence: sequence,
                                                 paragraphs: text)
        XCTAssertEqual(scenes, [
            .scene(docId: "pc-1", paragraphId: "p1", heading: "INT. KITCHEN - DAY"),
            .scene(docId: "pc-1", paragraphId: "p3", heading: "EXT. GARDEN - NIGHT"),
        ])
        XCTAssertEqual(scenes.map(\.group), [.scenes, .scenes])
        XCTAssertEqual(scenes.map(\.pulledUp), [nil, nil], "a scene travels; it is never pulled up")
    }

    func test_aCollectionScriptsFoldIsAlwaysGroupedWithScenesFirst() {
        // One research row and two scenes: three entries, under the six past
        // which a fold groups — and still grouped, Scenes first.
        let research: PieceFoldEntry = .research(id: "res-1", title: "Notes", owned: true)
        let base = PieceFoldIndex(entries: ["pc-1": [research]], alwaysGrouped: ["pc-1"])
        let scenes: [PieceFoldEntry] = [
            .scene(docId: "pc-1", paragraphId: "p1", heading: "INT. KITCHEN - DAY"),
            .scene(docId: "pc-1", paragraphId: "p3", heading: "EXT. GARDEN - NIGHT"),
        ]
        let index = base.withScenes(["pc-1": scenes])
        guard case .groups(let runs)? = index.layout(of: "pc-1") else {
            return XCTFail("a script's fold is always grouped: \(String(describing: index.layout(of: "pc-1")))")
        }
        XCTAssertEqual(runs.map(\.group), [.scenes, .research], "Scenes first, then Research")
        XCTAssertEqual(runs[0].entries, scenes)
        XCTAssertEqual(BinderPieceFold.groupTitle(runs[0]), "Scenes (2)")
    }

    func test_aScriptWithNothingButScenesStillGetsAFold() {
        let index = PieceFoldIndex(entries: [:], alwaysGrouped: ["pc-1"])
            .withScenes(["pc-1": [.scene(docId: "pc-1", paragraphId: "p0", heading: "INT. A - DAY")]])
        XCTAssertEqual(index.layout(of: "pc-1").map { layout -> [PieceFoldGroup] in
            if case .groups(let runs) = layout { return runs.map(\.group) }
            return []
        }, [.scenes])
    }

    func test_theScenesFollowAnEditOfTheScript() {
        let first = PieceFoldIndex(entries: [:], alwaysGrouped: ["pc-1"])
            .withScenes(["pc-1": [.scene(docId: "pc-1", paragraphId: "p0", heading: "INT. A - DAY")]])
        // A re-read replaces the scenes and keeps the rest.
        let edited = first.withScenes(["pc-1": [
            .scene(docId: "pc-1", paragraphId: "p0", heading: "INT. A - NIGHT"),
            .scene(docId: "pc-1", paragraphId: "p4", heading: "EXT. B - DAY"),
        ]])
        XCTAssertEqual(edited.entries["pc-1"]?.count, 2, "replaced, never added to")
        // Every sluglines gone: the fold goes with them.
        XCTAssertNil(edited.withScenes([:]).layout(of: "pc-1"))

        // The read's key moves on the editor's re-parse (`.maughamScriptDidUpdate`)
        // and on a manifest change, and on nothing else.
        let date = Date(timeIntervalSince1970: 100)
        XCTAssertNotEqual(PieceFoldScenesKey(modified: date, scriptRevision: 0),
                          PieceFoldScenesKey(modified: date, scriptRevision: 1))
        XCTAssertNotEqual(PieceFoldScenesKey(modified: date, scriptRevision: 0),
                          PieceFoldScenesKey(modified: date.addingTimeInterval(1), scriptRevision: 0))
    }

    func test_aSceneRowOpensTheScriptAtItsSlugline() {
        let row: PieceFoldEntry = .scene(docId: "pc-1", paragraphId: "p3", heading: "EXT. GARDEN")
        let destination = BinderPieceFold.sceneDestination(row)
        XCTAssertEqual(destination?.docId, "pc-1")
        XCTAssertEqual(destination?.paragraphId, "p3")
        XCTAssertNil(BinderPieceFold.sceneDestination(.link(pieceId: "x", title: "X", incoming: false)))
        XCTAssertEqual(BinderPieceFold.act(of: row), .goToScene(docId: "pc-1", paragraphId: "p3"))
        // Its click never moves the subject itself: the posted place does.
        let subject = WindowSubject(open: .item("pc-2"), faces: .item("pc-2"))
        XCTAssertEqual(BinderPieceFold.clicked(row, subject: subject, structure: [],
                                               projectType: .collection), subject)
    }

    /// The scene row goes through `ResolveNavigation.go` and carries no tag.
    func test_theSceneRowTravelsThroughTheOneNavigation() throws {
        let source = try CanvasSourceCensus.source(at: "Maugham/Views/BinderPieceFold.swift")
        let start = try XCTUnwrap(source.range(of: "case .scene(let docId, let paragraphId, let heading):"))
        let end = try XCTUnwrap(source.range(of: "case .link(let pieceId", range: start.upperBound..<source.endIndex))
        let arm = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(arm.contains("ResolveNavigation.go(toDocId: docId, paragraphId: paragraphId)"))
        XCTAssertFalse(arm.contains(".tag("), "a scene row travels; arrowing onto it must not")
    }

    func test_onlyACollectionsScriptIsACollectionScript() {
        let script = StructureItem(id: "pc-1", title: "S", type: .document,
                                   path: "pieces/01-s/s.fountain", pieceKind: .loose)
        let prose = StructureItem(id: "pc-2", title: "P", type: .document,
                                  path: "pieces/02-p/p.md", pieceKind: .loose)
        let reference = StructureItem(id: "pc-3", title: "R", type: .document,
                                      path: "elsewhere/r.fountain", pieceKind: .reference)
        XCTAssertTrue(PieceFoldIndex.isCollectionScript(script, projectType: .collection))
        XCTAssertFalse(PieceFoldIndex.isCollectionScript(prose, projectType: .collection))
        XCTAssertFalse(PieceFoldIndex.isCollectionScript(reference, projectType: .collection))
        XCTAssertFalse(PieceFoldIndex.isCollectionScript(script, projectType: .screenplay),
                       "a standalone screenplay's tree is its own Scenes navigator")
    }

    func test_theBuildGroupsACollectionsScriptAndTheReaderListsIt() async throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        defer { Task { await ds.close() } }
        let script = try await store.addLoosePiece(title: "The Walk", format: .fountain)
        let prose = try await store.addLoosePiece(title: "A Story", format: .markdown)

        let index = PieceFoldIndex.build(store: store, projectRoot: store.url)
        XCTAssertTrue(index.alwaysGrouped.contains(script.id))
        XCTAssertFalse(index.alwaysGrouped.contains(prose.id))
        let scenes = PieceFoldIndex.scenes(store: store)
        XCTAssertNotNil(scenes[script.id], "the script is read")
        XCTAssertNil(scenes[prose.id], "prose has no Scenes")
    }

    // MARK: - A peer's sync into a closed script (shell p5 Task 4)

    /// Which arrivals re-read the Scenes: a closed Collection script's, or
    /// an event naming no document; never an open script's (it re-parses
    /// itself), prose's, or a project that holds no pieces.
    func test_whichArrivalsMoveTheScenes() {
        let script = StructureItem(id: "pc-1", title: "Walk", type: .document,
                                   path: "pieces/01-walk/walk.fountain")
        let prose = StructureItem(id: "pc-2", title: "Story", type: .document,
                                  path: "pieces/02-story/story.md")
        let structure = [script, prose]
        XCTAssertTrue(PieceFoldIndex.arrivalMovesScenes(
            docId: "pc-1", isOpen: false, structure: structure, projectType: .collection))
        XCTAssertFalse(PieceFoldIndex.arrivalMovesScenes(
            docId: "pc-1", isOpen: true, structure: structure, projectType: .collection))
        XCTAssertFalse(PieceFoldIndex.arrivalMovesScenes(
            docId: "pc-2", isOpen: false, structure: structure, projectType: .collection))
        XCTAssertFalse(PieceFoldIndex.arrivalMovesScenes(
            docId: "gone", isOpen: false, structure: structure, projectType: .collection))
        XCTAssertTrue(PieceFoldIndex.arrivalMovesScenes(
            docId: nil, isOpen: false, structure: structure, projectType: .collection))
        XCTAssertFalse(PieceFoldIndex.arrivalMovesScenes(
            docId: "pc-1", isOpen: false, structure: structure, projectType: .novel))
    }

    /// **A peer's edit moves a closed script's Scenes, through the window's
    /// own listener**: the sync lands on disk, the store's presenter posts
    /// the arrival, and the mounted `TreeWindowWiring` — on a real, live
    /// window, handed in as `ProjectWindow` hands in its own — re-reads at
    /// once: read synchronously, no wait. Only the arriving script is
    /// re-read: the other script's entry, struck out before, stays out.
    func test_aPeersEditMovesAClosedScriptsScenes() async throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        ds.projectStore = store
        let script = try await store.addLoosePiece(title: "The Walk", format: .fountain)
        let other = try await store.addLoosePiece(title: "The Run", format: .fountain)
        XCTAssertNil(ds.document(forDocId: script.id), "premise: the script is closed")
        let state = BinderTreeSectionsState()
        let window = TestWindow.make(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView = NSHostingView(rootView: Color.clear.modifier(TreeWindowWiring(
            store: store, url: store.url, window: window, state: state,
            subject: .constant(WindowSubject(open: .project, faces: .project)),
            showInspector: .constant(false), position: .constant(.brief))))
        defer {
            window.contentView = NSView(frame: .zero)
            Task { await ds.close() }
        }
        pump(0.1)
        XCTAssertTrue(MaughamEvent.isLive(window), "premise: the receiver's window is live")
        // The Scenes as the fold's `.task` read them, the other struck out.
        state.foldScenes = PieceFoldIndex.scenes(store: store)
        let kitchen: (PieceFoldEntry) -> Bool = {
            if case .scene(_, _, "INT. KITCHEN - DAY") = $0 { return true }; return false
        }
        XCTAssertEqual(state.foldScenes[script.id]?.contains(where: kitchen), false,
                       "premise: read, and no kitchen yet")
        XCTAssertNotNil(state.foldScenes.removeValue(forKey: other.id), "premise: the other was read")

        // The peer's op: a new paragraph holding a slugline, at the end.
        let read = try store.derivedCache.state(forDocId: script.id, in: store.url)
        let added = ParagraphID.mintUnique(excluding: Set(read.sequence))
        let op = Op(opId: ULID.generate(), docId: script.id, at: Date(), device: "peer-mac",
                    session: "peer-session", kind: .typingBurst,
                    changes: [.init(paragraphId: added, prior: nil, next: "INT. KITCHEN - DAY")],
                    sequence: read.sequence + [added], provenance: nil)
        try await OpLogStore(projectURL: store.url).append(op)
        let log = try XCTUnwrap(OpLogStore.opLogFileURLs(forDocId: script.id, in: store.url).first)
        let revision = state.scriptRevision
        ds.presenterDidChangeSubitem(at: log)

        XCTAssertTrue(state.foldScenes[script.id]?.contains {
            if case .scene(_, added, "INT. KITCHEN - DAY") = $0 { return true }; return false
        } == true, "the window's listener re-read the script and lists the peer's slugline")
        XCTAssertTrue(state.foldIndex.entries[script.id]?.contains(where: kitchen) == true,
                      "and the fold draws it")
        XCTAssertNil(state.foldScenes[other.id], "the other script was not re-read")
        XCTAssertEqual(state.scriptRevision, revision, "nor every script, through the key")
    }

    /// **The Editions rows hear their three arrivals** (shell p5 Task 4a fix
    /// round 1): a translation written, publishing set up and a proposed
    /// brief, each posted as production posts it, move the rows' key on the
    /// window's own wiring — synchronously, as the post is heard.
    func test_theEditionsRowsHearTheirArrivalsOnTheWindow() async throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let state = BinderTreeSectionsState()
        let window = TestWindow.make(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView = NSHostingView(rootView: Color.clear.modifier(TreeWindowWiring(
            store: store, url: store.url, window: window, state: state,
            subject: .constant(WindowSubject(open: .project, faces: .project)),
            showInspector: .constant(false), position: .constant(.brief))))
        defer { window.contentView = NSView(frame: .zero) }
        pump(0.1)
        XCTAssertTrue(MaughamEvent.isLive(window), "premise: the receiver's window is live")

        var revision = state.translationRevision
        MaughamEvent.post(.maughamTranslationDidUpdate, to: .project(for: store.url))
        XCTAssertEqual(state.translationRevision, revision + 1, "a translation written")
        revision = state.translationRevision
        MaughamEvent.post(.maughamPublishInitialized, to: .project(for: store.url))
        XCTAssertEqual(state.translationRevision, revision + 1, "publishing set up")
        revision = state.translationRevision
        MaughamEvent.postStatementProposalsChanged(projectURL: store.url)
        XCTAssertEqual(state.translationRevision, revision + 1, "a proposed brief")
    }

    /// **No receiver without a window, anywhere in the app**: one declared
    /// with `window: nil` is never live (`MaughamEvent.isLive(nil)` is false)
    /// and hears nothing, silently. Four did, for months.
    func test_noEventReceiverIsDeclaredWithoutAWindow() throws {
        var found: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            found += Self.windowlessReceivers(in: try SourceTree.read(file)).map { "\(file): \($0)" }
        }
        XCTAssertEqual(found, [])
    }

    func test_theWindowlessReceiverCensusSeesAPlantedOffender() {
        XCTAssertEqual(Self.windowlessReceivers(in: """
            .onProjectEvent(.maughamPublishInitialized, url: store.url, window: nil) { _ in }
            .onKeyWindowCommand(.maughamShowPieceFold,
                                window: nil) { _ in }
            """).count, 2)
        // Control: a receiver on its window, and a comment naming the shape.
        XCTAssertEqual(Self.windowlessReceivers(in: """
            .onProjectEvent(.maughamPublishInitialized, url: url, window: window) { _ in }
            // a receiver with `window: nil` hears nothing
            """), [])
    }

    /// The receivers in `text` whose window is `nil`, a call spanning lines
    /// included.
    static func windowlessReceivers(in text: String) -> [String] {
        let code = SourceScan.codeLines(of: text).joined(separator: "\n")
        let pattern = #"\.on(ProjectEvent|KeyWindowCommand)\([^{}]*?window:\s*nil"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["bad pattern"] }
        let range = NSRange(code.startIndex..., in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    /// An arrival's re-read replaces its own script's Scenes and no other's.
    func test_anArrivalReplacesOnlyItsScriptsScenes() {
        let walk: [PieceFoldEntry] = [.scene(docId: "pc-1", paragraphId: "p1", heading: "INT. A")]
        let run: [PieceFoldEntry] = [.scene(docId: "pc-2", paragraphId: "p1", heading: "INT. B")]
        let fresh: [PieceFoldEntry] = [.scene(docId: "pc-1", paragraphId: "p2", heading: "INT. C")]
        let before = ["pc-1": walk, "pc-2": run]
        XCTAssertEqual(PieceFoldIndex.merging(fresh, for: "pc-1", into: before),
                       ["pc-1": fresh, "pc-2": run])
        XCTAssertEqual(PieceFoldIndex.merging(nil, for: "pc-1", into: before), ["pc-2": run],
                       "a script that cannot be read lists no scenes")
    }

    /// The window's wiring hears the arrival and the re-parse, and the
    /// arrival asks the rule and re-reads one script: deleting the wiring
    /// turns this red.
    func test_theFoldHearsClosedArrivals() throws {
        let wiring = SourceScan.codeLines(of: try SourceTree.declaration(
            named: "struct TreeWindowWiring", under: "Maugham")).joined(separator: "\n")
        XCTAssertTrue(wiring.contains(".onProjectEvent(.maughamAnnotationsChanged, url: url, window: window)"))
        XCTAssertTrue(wiring.contains("PieceFoldIndexing.arrived("))
        XCTAssertTrue(wiring.contains(".onProjectEvent(.maughamScriptDidUpdate, url: url, window: window)"))
        let fold = SourceScan.codeLines(of: try SourceTree.declaration(
            named: "struct PieceFoldIndexing", under: "Maugham")).joined(separator: "\n")
        XCTAssertTrue(fold.contains("PieceFoldIndex.arrivalMovesScenes("))
        XCTAssertTrue(fold.contains("PieceFoldIndex.scenes(ofScript: docId, store: store)"),
                      "a named arrival re-reads its own script")
        XCTAssertFalse(fold.contains("window: nil"), "a receiver with no window hears nothing")
    }

    // MARK: - A palette card inside a region

    private func paletteGroup(_ cards: [ResearchItem]) -> ResearchItem {
        ResearchItem(id: "res-palette", title: "Palette", type: .group,
                     path: PaletteConvention.folderPath, children: cards, role: .paletteGroup)
    }

    private func card(_ id: String, _ title: String) -> ResearchItem {
        ResearchItem(id: id, title: title, type: .asset, kind: .document,
                     path: "research/palette/\(id).md")
    }

    private func chapter(linkedResearch: [String]? = nil) -> StructureItem {
        StructureItem(id: chapterId, title: "One", type: .document,
                      path: "manuscript/one.md", linkedResearchIds: linkedResearch)
    }

    /// A region bound to the chapter holding a scrap and the palette card's
    /// item node.
    private func regionScene(cardId: String) -> (CanvasScene, CanvasRegionID, [CanvasNodeID: String]) {
        var s = CanvasScene()
        let scrap = CanvasNodeID("s1")
        let item = CanvasNodeID.item(cardId)
        s.insert(CanvasNode(id: scrap, kind: .scrap, origin: CGPoint(x: 0, y: 0),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: item, kind: .item(.project(id: cardId)),
                            origin: CGPoint(x: 0, y: 200), width: 240, cachedHeight: 80))
        let region = CanvasRegionID("r1")
        s.insertRegion(CanvasRegion(id: region, label: "Fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        RegionBinding.bind(region, toPiece: chapterId, in: &s)
        CanvasMembership.join(scrap, home: region, in: &s)
        CanvasMembership.join(item, home: region, in: &s)
        return (s, region, [scrap: "a thought"])
    }

    private func entries(structure: [StructureItem], research: [ResearchItem],
                         scene: CanvasScene?, scraps: [CanvasNodeID: String]) -> [PieceFoldEntry] {
        let item = structure[0]
        let shelf = PinnedReferences.pinned(
            forDocId: item.id, links: item.linkedResearchIds, derived: [],
            scene: scene, scraps: scraps, items: CanvasItemIndex.over(research: research))
        let fold = TreeSectionDerivation.pieceFold(
            for: item, projectType: .novel,
            homes: ResearchHomes.derive(structure: structure, research: research,
                                        projectType: .novel))
        return PieceFoldIndex.entries(docId: item.id, shelf: shelf, fold: fold, figures: [],
                                      links: [], structure: structure, research: research)
    }

    func test_aPaletteCardInARegionListsUnderItsRegion() {
        let research = [paletteGroup([card("pal-1", "Fog card")])]
        let (scene, region, scraps) = regionScene(cardId: "pal-1")
        let out = entries(structure: [chapter()], research: research, scene: scene, scraps: scraps)
        guard out.count == 1, case .region(let id, _, let cards) = out[0] else {
            return XCTFail("one region and nothing under Palette, got \(out)")
        }
        XCTAssertEqual(id, region.raw)
        XCTAssertEqual(cards.map(\.kind), [.scrap(nodeId: "s1"), .palette(cardId: "pal-1")],
                       "the card is among the region's cards, in the canvas's reading order")
        XCTAssertFalse(out.contains { $0.group == .palette }, "never ALSO under Palette")
        XCTAssertEqual(out[0].regionCards.last?.pulledUp, .research("pal-1"),
                       "its row pulls the card up, as a palette row does")
    }

    /// Pinned to the chapter AND set inside its region: one card, one row.
    /// The shelf gives it to its first claim, the pin (`PinnedReferences
    /// .pinned` dedups across the whole shelf, as it does a research card
    /// linked to the chapter and set in its region), so it is the Palette's.
    func test_aPaletteCardPinnedAndInARegionIsListedOnce() {
        let research = [paletteGroup([card("pal-1", "Fog card")])]
        let (scene, _, scraps) = regionScene(cardId: "pal-1")
        let out = entries(structure: [chapter(linkedResearch: ["pal-1"])], research: research,
                          scene: scene, scraps: scraps)
        let all = out.flatMap { [$0] + $0.regionCards }
        XCTAssertEqual(all.filter { $0.pulledUp == .research("pal-1") }.count, 1,
                       "one card, one row: \(out)")
    }

    func test_aPaletteCardOutsideARegionListsUnderPalette() {
        let research = [paletteGroup([card("pal-1", "Fog card")])]
        let out = entries(structure: [chapter(linkedResearch: ["pal-1"])], research: research,
                          scene: nil, scraps: [:])
        XCTAssertEqual(out, [.palette(id: "pal-1", title: "Fog card")])
    }

    /// Review M2's rule: the fold's region row and the region pulled up list
    /// the same cards in the same order (`PinnedReferences.readingOrder`).
    func test_thePulledUpRegionAndItsFoldRowAgree() {
        let research = [paletteGroup([card("pal-1", "Fog card")])]
        let (scene, region, scraps) = regionScene(cardId: "pal-1")
        let out = entries(structure: [chapter()], research: research, scene: scene, scraps: scraps)
        guard case .region(_, _, let cards)? = out.first else { return XCTFail("\(out)") }
        let beside = PinnedReferences.readingOrder(ofRegion: region, in: scene)
        XCTAssertEqual(beside, [CanvasNodeID("s1"), CanvasNodeID.item("pal-1")])
        XCTAssertEqual(cards.count, beside.count, "every card the region shows, and no other")
        XCTAssertEqual(cards.map(\.id), ["s1", "pal-1"])
    }
}
