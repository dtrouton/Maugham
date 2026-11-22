import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// Shell p4 Task 10 (Denver's answer 4): **the tree says which drop is about
/// to happen, and a drop on the Canvas row puts it on the canvas.** A real
/// drag session is not synthesisable headless, so what is pinned is the one
/// predicate (the hover and the drop ask the same classification, read off
/// the same drag pasteboard), the feedback table, the Canvas row's verdict
/// and landing, and the wiring by census.
@MainActor
final class TreeDropFeedbackTests: XCTestCase {

    private var temp: TempDirectory!
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The feedback table

    func test_eachIntentShowsIntoBesideOrNothing() {
        let piece = TreeDropIntent.Target.pieceRow("ch-1")
        XCTAssertEqual(TreeDropFeedback.of(.link(researchId: "n", toDocumentId: "ch-1"), on: piece), .into)
        XCTAssertEqual(TreeDropFeedback.of(TreeDropIntent.Intent.refuse(.alreadyThere), on: piece), .none)
        XCTAssertEqual(TreeDropFeedback.of(.structureReorder, on: piece), .beside)
        XCTAssertEqual(TreeDropFeedback.of(.rescope(ids: ["n"], to: .piece("pc-1")),
                                           on: .pieceRow("pc-1")), .into)
        XCTAssertEqual(TreeDropFeedback.of(.rescope(ids: ["n"], to: .group("g")),
                                           on: .researchRow("g")), .into, "into the group")
        XCTAssertEqual(TreeDropFeedback.of(.rescope(ids: ["n"], to: .group("g")),
                                           on: .researchRow("leaf")), .beside, "beside a leaf")
        XCTAssertEqual(TreeDropFeedback.of(.unlink(researchId: "n", fromDocumentId: "ch-1"),
                                           on: .sharedSection), .into)
        XCTAssertEqual(TreeDropFeedback.of(.researchReorder, on: .researchRow("x")), .beside)
        XCTAssertEqual(TreeDropFeedback.of(.useInDocument(researchId: "t"), on: .figuresSection), .into)
        XCTAssertEqual(TreeDropFeedback.of(TreeDropIntent.Intent.refuse(.figuresHaveNoOrder), on: .figureRow("f")), .none)

        XCTAssertEqual(TreeDropFeedback.of(.importFiles(.sharedAndLink("ch-1")), on: piece), .into)
        XCTAssertEqual(TreeDropFeedback.of(.importFiles(.sharedGroup(nil)), on: .sharedSection), .into)
        XCTAssertEqual(TreeDropFeedback.of(.importFiles(.sharedGroup("g")),
                                           on: .researchRow("leaf")), .beside)
        XCTAssertEqual(TreeDropFeedback.of(TreeDropIntent.ExternalIntent.refuse(.sharedOnly),
                                           on: piece), .none)
    }

    // MARK: - One predicate: what the hover shows is what the drop does

    func test_theHoverAndTheDropAgreeOnEveryTarget() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        let linked = try await store.addResearchTextNote(parentId: nil, title: "Linked")
        try await store.linkResearch(researchId: linked.id, toDocumentId: chapter.id)
        let refreshed = try XCTUnwrap(store.manifest.structure.first)

        let cases: [(payload: String, target: TreeDropIntent.Target)] = [
            (note.id, .pieceRow(refreshed.id)),            // a link: accepted
            (linked.id, .pieceRow(refreshed.id)),          // already linked: refused
            ("not-an-id", .pieceRow(refreshed.id)),        // unknown: refused
            (refreshed.id, .sharedSection),                // a chapter onto Research: refused
            (note.id, .sharedSection),                     // already at the root: refused
            (linked.id, .sharedSection),                   // unlink: accepted
            (note.id, .figuresSection),                    // a note is no figure: refused
        ]
        for (payload, target) in cases {
            let verbs = BinderTreeVerbs(store: store, state: BinderTreeSectionsState(),
                                        subject: .constant(.book))
            // The hover, through the drag pasteboard as production reads it.
            let board = NSPasteboard(name: NSPasteboard.Name("tree-drop-\(UUID().uuidString)"))
            board.clearContents()
            board.setString(payload, forType: .string)
            let shown = verbs.dropFeedback(on: target, pasteboard: board)
            // The drop: the very route the row's closure calls.
            let accepted: Bool
            switch target {
            case .pieceRow(let id):
                accepted = verbs.routePieceRowDrop(draggedId: payload, documentId: id,
                                                   structureReorder: {})
            case .sharedSection:
                accepted = verbs.routeSharedSectionDrop(draggedId: payload)
            case .figuresSection, .figureRow:
                accepted = verbs.routeFiguresDrop(draggedId: payload, target: target)
            case .researchRow, .foldRow:
                return XCTFail("not in this table")
            }
            XCTAssertEqual(shown.accepts, accepted,
                           "\(payload) on \(target): the hover showed \(shown), the drop said \(accepted)")
            pump(0.2)
        }
    }

    /// A Finder file: the external rule, on the target's own routing.
    func test_aFilesFeedbackIsItsDropsOwnRule() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let verbs = BinderTreeVerbs(store: store, state: BinderTreeSectionsState(),
                                    subject: .constant(.book))
        let board = NSPasteboard(name: NSPasteboard.Name("tree-drop-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects([temp.url as NSURL])
        XCTAssertEqual(verbs.dropFeedback(on: .pieceRow(chapter.id), pasteboard: board), .into,
                       "a novel chapter imports and links")
        XCTAssertEqual(verbs.dropFeedback(on: .sharedSection, pasteboard: board), .into)
        XCTAssertEqual(verbs.dropFeedback(on: .figuresSection, pasteboard: board), .none,
                       "no file lands on Figures")
    }

    /// A structure row the posture may not move shows nothing, as its drop
    /// refuses (`BinderView`'s `onDrop`).
    func test_aStructureRowThePostureRefusesShowsNothing() async throws {
        let store = try await novel()
        _ = try await store.addStructureItem(parentId: nil, title: "Chapter Two",
                                             kind: .document(.markdown))
        let rows = store.manifest.structure
        XCTAssertGreaterThan(rows.count, 1, "premise: two chapters")
        let verbs = BinderTreeVerbs(store: store, state: BinderTreeSectionsState(),
                                    subject: .constant(.book))
        XCTAssertEqual(verbs.feedback(draggedId: rows[0].id, on: .pieceRow(rows[1].id)), .beside)
        XCTAssertEqual(verbs.feedback(draggedId: rows[0].id, on: .pieceRow(rows[1].id),
                                      refusesStructure: { _ in true }), .none)
    }

    // MARK: - The Canvas row

    private let items = CanvasItemIndex.over(research: [
        ResearchItem(id: "res-1", title: "Tides", type: .asset, kind: .document, path: "research/t.md"),
    ])

    func test_theCanvasRowsVerdict() {
        let text = ["public.utf8-plain-text"]
        let file = ["public.file-url"]
        func verdict(_ types: [String], _ id: String?, readOnly: Bool = false) -> TreeCanvasRowDrop.Verdict {
            TreeCanvasRowDrop.verdict(typeIdentifiers: types, draggedId: id, items: items,
                                      isReadOnly: readOnly)
        }
        XCTAssertEqual(verdict(text, CanvasDrop.inboxPayload(for: "E1")), .capture(entryID: "E1"))
        XCTAssertEqual(verdict(text, "res-1"), .research("res-1"))
        XCTAssertEqual(verdict(file, nil), .files)
        XCTAssertEqual(verdict(file + text, "res-1"), .files, "a file always wins over text")
        XCTAssertEqual(verdict(text, "ch-1"), .refuse, "a chapter is no canvas card")
        XCTAssertEqual(verdict(text, nil), .refuse)
        XCTAssertEqual(verdict(["com.example.nothing"], "res-1"), .refuse)
        // A canvas this build refused takes nothing — the canvas's own gate.
        for (types, id) in [(text, CanvasDrop.inboxPayload(for: "E1")), (text, "res-1"), (file, nil)] {
            XCTAssertEqual(verdict(types, id, readOnly: true), .refuse)
        }
    }

    /// A research note dropped on the row lands loose — clear of the
    /// writer's work, in no region — selected for the canvas's next opening,
    /// and the row marks it.
    func test_aNoteDroppedOnTheCanvasRowLandsLooseAndTheRowSaysSo() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        // The writer's work: a region bound to the chapter, holding a scrap.
        var scene = CanvasScene()
        let scrap = CanvasNodeID("s1")
        scene.insert(CanvasNode(id: scrap, kind: .scrap, origin: CGPoint(x: 20, y: 20),
                                width: 240, cachedHeight: 80))
        let region = CanvasRegionID("r1")
        scene.insertRegion(CanvasRegion(id: region, label: "Fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        RegionBinding.bind(region, toPiece: chapter.id, in: &scene)
        CanvasMembership.join(scrap, home: region, in: &scene)
        CanvasStore(projectRoot: store.url).save(scene: scene, scraps: [scrap: "a thought"])

        let state = BinderTreeSectionsState()
        let verdict = TreeCanvasRowDrop.verdict(
            typeIdentifiers: ["public.utf8-plain-text"], draggedId: note.id,
            items: CanvasItemIndex.over(research: store.manifest.research), isReadOnly: false)
        XCTAssertEqual(verdict, .research(note.id))
        var reported: String?
        XCTAssertTrue(TreeCanvasRowDrop.perform(verdict, providers: [],
                                                host: .init(store: store, state: state),
                                                report: { reported = $0 }))
        XCTAssertNil(reported)

        let landed = CanvasStore(projectRoot: store.url).load().scene
        let node = try XCTUnwrap(landed.node(.item(note.id)), "the card is on the canvas")
        XCTAssertNil(CanvasMembership.homeRegion(of: node.id, in: landed),
                     "loose: no region it did not ask for (tripwire 31)")
        XCTAssertFalse(landed.region(region)!.frame.intersects(node.frame ?? .zero),
                       "clear of the writer's work")
        XCTAssertTrue(state.canvasHasArrivals, "the Canvas row marks it")

        // A second drop of the same note lands on the same card.
        _ = TreeCanvasRowDrop.perform(verdict, providers: [], host: .init(store: store, state: state),
                                      report: { reported = $0 })
        let again = CanvasStore(projectRoot: store.url).load().scene
        XCTAssertEqual(again.unorderedNodes.filter { $0.id == .item(note.id) }.count, 1)
    }

    /// The row asks the verdict for its highlight and its drop alike, off the
    /// drag pasteboard; a capture goes through the Send to Canvas route.
    func test_theCanvasRowsHoverAndDropAskOneVerdict() throws {
        let source = try CanvasSourceCensus.source(at: "Maugham/Views/TreeTopRows.swift")
        XCTAssertEqual(source.components(
            separatedBy: "TreeCanvasRowDrop.verdict(on: NSPasteboard(name: .drag)").count - 1, 2,
            "the hover and the drop")
        XCTAssertTrue(source.contains("inbox.sendToCanvas(\n                        entryID: entryID, projectStore: store, placement: .loose)"))
        XCTAssertTrue(source.contains(".treeDropHighlight(TreeDropFeedback.into(isTargeted && hovering.accepts))"))
    }

    /// Every drop target the tree mounts reports its hover to a feedback
    /// asked of the drop's own rule.
    func test_everyTreeDropTargetShowsItsFeedback() throws {
        let rows = ["Maugham/Views/BinderRow.swift", "Maugham/Views/PieceRow.swift",
                    "Maugham/Views/ResearchRow.swift"]
        for path in rows {
            let source = try CanvasSourceCensus.source(at: path)
            XCTAssertTrue(source.contains("isTargeted: { internalDropTargeted = $0 }"), path)
            XCTAssertTrue(source.contains("isTargeted: $externalDropTargeted"), path)
            XCTAssertTrue(source.contains(".treeDropHover(internalTargeted: internalDropTargeted"), path)
        }
        let sections = try CanvasSourceCensus.source(at: "Maugham/Views/BinderTreeSections.swift")
        XCTAssertTrue(sections.contains("isTargeted: $researchHeaderTargeted"))
        XCTAssertTrue(sections.contains("verbs.dropFeedback(on: .sharedSection)"))
        XCTAssertTrue(sections.contains("bundle.dropFeedback = { item in dropFeedback(on: .researchRow(item.id)) }"))
        let fold = try CanvasSourceCensus.source(at: "Maugham/Views/BinderPieceFold.swift")
        XCTAssertTrue(fold.contains("verbs.dropFeedback(on: .foldRow(rowId: item.id, documentId: documentId))"))
        let figures = try CanvasSourceCensus.source(at: "Maugham/Views/FigureSection.swift")
        XCTAssertTrue(figures.contains("verbs.dropFeedback(on: .figuresSection)"))
        XCTAssertTrue(figures.contains("verbs.dropFeedback(on: .figureRow(row.id))"))
        for host in ["Maugham/Views/BinderView.swift", "Maugham/Views/CollectionPiecesPane.swift"] {
            let source = try CanvasSourceCensus.source(at: host)
            XCTAssertTrue(source.contains("treeVerbs.dropFeedback(on: .pieceRow("), host)
            XCTAssertTrue(source.contains("canvasDrop: .init(store: store, state: treeState)"), host)
        }
    }

    // MARK: - Fixtures

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return store
    }
}
