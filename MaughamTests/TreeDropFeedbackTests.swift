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
            let shown = verbs.dropAnswers(on: target, pasteboard: board(payload)).look(at: nil)
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

    /// **Research rows, fold rows and group rows, at each position**
    /// (review I2, Minor 11): what the hover draws at a position is what the
    /// drop does there — accepted or refused, and into or between. A fresh
    /// project per case, since each drop moves something.
    func test_aResearchRowsHoverAtEachPositionIsItsDrop() async throws {
        struct Case {
            let name: String
            let target: (Fixture) -> (TreeDropIntent.Target, ResearchItem, String?)
            let payload: (Fixture) -> String
            let expected: [DropIntent.Position: TreeDropFeedback]
        }
        let cases: [Case] = [
            Case(name: "a note over a leaf", target: { f in (.researchRow(f.b.id), f.b, nil) },
                 payload: { $0.a.id },
                 expected: [.top: .above, .middle: .below, .bottom: .below]),
            Case(name: "a note over a group", target: { f in (.researchRow(f.group.id), f.group, nil) },
                 payload: { $0.a.id },
                 expected: [.top: .above, .middle: .into, .bottom: .below]),
            Case(name: "a note over itself", target: { f in (.researchRow(f.a.id), f.a, nil) },
                 payload: { $0.a.id },
                 expected: [.top: .none, .middle: .none, .bottom: .none]),
            Case(name: "a note over a chapter's fold row",
                 target: { f in (.foldRow(rowId: f.linked.id, documentId: f.chapter), f.linked, f.chapter) },
                 payload: { $0.a.id },
                 expected: [.top: .into, .middle: .into, .bottom: .into]),
            Case(name: "a linked note over its own fold",
                 target: { f in (.foldRow(rowId: f.linked.id, documentId: f.chapter), f.linked, f.chapter) },
                 payload: { $0.linked2.id },
                 expected: [.top: .none, .middle: .none, .bottom: .none]),
        ]
        for c in cases {
            for position: DropIntent.Position in [.top, .middle, .bottom] {
                let f = try await fixture()
                let verbs = BinderTreeVerbs(store: f.store, state: BinderTreeSectionsState(),
                                            subject: .constant(.book))
                let (target, row, doc) = c.target(f)
                let payload = c.payload(f)
                let shown = verbs.dropAnswers(on: target, pasteboard: board(payload)).look(at: position)
                XCTAssertEqual(shown, c.expected[position], "\(c.name) at \(position)")
                let accepted = verbs.routeResearchRowDrop(draggedId: payload, position: position,
                                                          target: row, inFoldOf: doc)
                XCTAssertEqual(shown.accepts, accepted, "\(c.name) at \(position): hover vs drop")
                if shown == .into, case .researchRow(let groupId) = target {
                    _ = await pumpUntil(deadline: 3) {
                        TreeWalk.find(id: groupId, in: f.store.manifest.research)?
                            .children?.contains { $0.id == payload } == true
                    }
                    XCTAssertTrue(TreeWalk.find(id: groupId, in: f.store.manifest.research)?
                        .children?.contains { $0.id == payload } == true,
                                  "\(c.name): the fill said into, and it went in")
                }
            }
        }
    }

    /// A chapter over a Part: the drop's own `DropIntent.classify` at each
    /// third — above, into, below (review I2's (b)).
    func test_aChapterOverAPartIsAboveIntoOrBelow() async throws {
        let store = try await novel()
        let part = try await store.addStructureItem(parentId: nil, title: "Part One", kind: .group)
        let chapter = try XCTUnwrap(store.manifest.structure.first { $0.type == .document })
        let verbs = BinderTreeVerbs(store: store, state: BinderTreeSectionsState(),
                                    subject: .constant(.book))
        let answers = verbs.dropAnswers(on: .pieceRow(part.id), pasteboard: board(chapter.id))
        XCTAssertEqual(answers, TreeDropAnswers(top: .above, middle: .into, bottom: .below))
        XCTAssertEqual(answers.look(at: nil), .beside, "unknown position: never 'into'")
        // A chapter over a chapter: halves for a Collection piece, thirds here.
        let other = try await store.addStructureItem(parentId: nil, title: "Two",
                                                     kind: .document(.markdown))
        XCTAssertEqual(verbs.dropAnswers(on: .pieceRow(other.id), pasteboard: board(chapter.id)),
                       TreeDropAnswers(top: .above, middle: .below, bottom: .below))
        // Halves never read a middle; its answer is the top half's.
        XCTAssertEqual(verbs.dropAnswers(on: .pieceRow(other.id), pasteboard: board(chapter.id),
                                         halves: true),
                       TreeDropAnswers(top: .above, middle: .above, bottom: .below))
    }

    /// Dragging one of several selected notes onto another of them: the
    /// hover and the drop ask one rule over the drag's own batch (Minor 3).
    func test_aBatchDragsHoverIsItsDrop() async throws {
        let f = try await fixture()
        let state = BinderTreeSectionsState()
        let subject = WindowSubject(open: .item(f.chapter), faces: .item(f.chapter),
                                    beside: .research(f.a.id))
        state.record(selection: [.research(f.a.id), .research(f.b.id)], subject: subject)
        let verbs = BinderTreeVerbs(store: f.store, state: state, subject: .constant(subject))
        let shown = verbs.dropAnswers(on: .researchRow(f.b.id), pasteboard: board(f.a.id))
            .look(at: .bottom)
        let accepted = verbs.routeResearchRowDrop(draggedId: f.a.id, position: .bottom,
                                                  target: f.b, inFoldOf: nil)
        XCTAssertEqual(shown, .below, "the batch is A alone (B's own drop on itself is refused)")
        XCTAssertEqual(shown.accepts, accepted, "the hover and the drop ask one rule")
    }

    /// A Finder file: the external rule at each position — a group's middle
    /// takes it in, its edges file it beside, which no line can draw.
    func test_aFilesHoverIsItsDropsOwnRule() async throws {
        let f = try await fixture()
        let verbs = BinderTreeVerbs(store: f.store, state: BinderTreeSectionsState(),
                                    subject: .constant(.book))
        let files = NSPasteboard(name: NSPasteboard.Name("tree-drop-\(UUID().uuidString)"))
        files.clearContents()
        files.writeObjects([temp.url as NSURL])
        XCTAssertEqual(verbs.dropAnswers(on: .pieceRow(f.chapter), pasteboard: files).look(at: nil),
                       .into, "a novel chapter imports and links, wherever it lands")
        XCTAssertEqual(verbs.dropAnswers(on: .sharedSection, pasteboard: files).look(at: nil), .into)
        XCTAssertEqual(verbs.dropAnswers(on: .figuresSection, pasteboard: files).look(at: nil), .none)
        let group = verbs.dropAnswers(on: .researchRow(f.group.id), pasteboard: files)
        XCTAssertEqual(group, TreeDropAnswers(top: .beside, middle: .into, bottom: .beside))
        XCTAssertEqual(group.look(at: nil), .beside,
                       "a file over a group: 'into' only where every third goes into")
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
        XCTAssertTrue(verbs.answers(draggedId: rows[0].id, on: .pieceRow(rows[1].id)).accepts)
        XCTAssertEqual(verbs.answers(draggedId: rows[0].id, on: .pieceRow(rows[1].id),
                                     refusesStructure: { _ in true }), .none)
    }

    // MARK: - Position and the look

    func test_theOnePositionReadingUsesTheRowsRealHeight() {
        XCTAssertEqual(DropIntent.Position.of(y: 5, height: 30), .top)
        XCTAssertEqual(DropIntent.Position.of(y: 15, height: 30), .middle)
        XCTAssertEqual(DropIntent.Position.of(y: 25, height: 30), .bottom)
        XCTAssertEqual(DropIntent.Position.of(y: 20, height: 30), .middle,
                       "a 30 pt row's middle third is where 22 pt's bottom was")
        XCTAssertEqual(DropIntent.Position.of(y: 14, height: 30, halves: true), .top)
        XCTAssertEqual(DropIntent.Position.of(y: 16, height: 30, halves: true), .bottom)
        XCTAssertEqual(DropIntent.Position.of(y: 0, height: 0), .top, "no height: no division by zero")
        // No drop closure assumes a height.
        for path in ["Maugham/Views/BinderRow.swift", "Maugham/Views/PieceRow.swift",
                     "Maugham/Views/ResearchRow.swift"] {
            let source = (try? CanvasSourceCensus.source(at: path)) ?? ""
            XCTAssertFalse(source.contains("let rowHeight: CGFloat = 22"), path)
            XCTAssertEqual(source.components(separatedBy: "DropIntent.Position.of(y: location.y, height: rowHeight")
                            .count - 1, 2, "\(path): both drops read the one position")
        }
    }

    func test_theHoverReadsThePointerOnTheRowsFrame() {
        let row = CGRect(x: 100, y: 500, width: 200, height: 30)   // screen, origin bottom-left
        XCTAssertEqual(TreeDropHover.position(mouse: CGPoint(x: 150, y: 528), rowOnScreen: row,
                                              halves: false), .top)
        XCTAssertEqual(TreeDropHover.position(mouse: CGPoint(x: 150, y: 515), rowOnScreen: row,
                                              halves: false), .middle)
        XCTAssertEqual(TreeDropHover.position(mouse: CGPoint(x: 150, y: 502), rowOnScreen: row,
                                              halves: false), .bottom)
        XCTAssertNil(TreeDropHover.position(mouse: CGPoint(x: 150, y: 600), rowOnScreen: row,
                                            halves: false), "off the row: unknown")
    }

    func test_theLookNeverPromisesWhatSomeThirdWouldNotDo() {
        let group = TreeDropAnswers(top: .above, middle: .into, bottom: .below)
        XCTAssertEqual(group.look(at: .middle), .into)
        XCTAssertEqual(group.look(at: .top), .above)
        XCTAssertEqual(group.look(at: nil), .beside)
        XCTAssertEqual(TreeDropAnswers(same: .into).look(at: nil), .into)
        XCTAssertEqual(TreeDropAnswers(same: .none).look(at: nil), .none)
        XCTAssertEqual(TreeDropAnswers(top: .none, middle: .into, bottom: .none).look(at: nil), .beside)
    }

    /// The drop look is one nothing else in the tree uses (review I3): a
    /// dashed ring and an insertion line; the standing marks stay solid.
    func test_theDropLookIsUnlikeAnyStandingMark() throws {
        let look = try CanvasSourceCensus.source(at: "Maugham/Views/TreeDropIntent.swift")
        XCTAssertTrue(look.contains("StrokeStyle(lineWidth: 2, dash: Self.ringDash)"))
        XCTAssertTrue(look.contains("TreeDropInsertionLine(ink: ink)"))
        XCTAssertTrue(look.contains("prominence == .increased ? Color.white : Color.accentColor"),
                      "readable on a selected row")
        for path in ["Maugham/Views/TreeTopRows.swift", "Maugham/Views/BinderPieceFold.swift"] {
            XCTAssertFalse(try CanvasSourceCensus.source(at: path).contains("dash:"),
                           "\(path): a standing mark never dashes")
        }
        XCTAssertNotNil(TreeDropHighlight.spoken(.above))
        XCTAssertNil(TreeDropHighlight.spoken(.none))
    }

    // MARK: - Fixtures for the research rows

    private struct Fixture {
        let store: ProjectStore
        let chapter: String
        let a: ResearchItem
        let b: ResearchItem
        let group: ResearchItem
        let linked: ResearchItem
        let linked2: ResearchItem
    }

    private func fixture() async throws -> Fixture {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let a = try await store.addResearchTextNote(parentId: nil, title: "A")
        let b = try await store.addResearchTextNote(parentId: nil, title: "B")
        let group = try await store.addResearchItem(parentId: nil, title: "G", kind: nil)
        _ = try await store.addResearchTextNote(parentId: group.id, title: "Inside")
        let linked = try await store.addResearchTextNote(parentId: nil, title: "L")
        let linked2 = try await store.addResearchTextNote(parentId: nil, title: "L2")
        try await store.linkResearch(researchId: linked.id, toDocumentId: chapter.id)
        try await store.linkResearch(researchId: linked2.id, toDocumentId: chapter.id)
        func fresh(_ item: ResearchItem) throws -> ResearchItem {
            try XCTUnwrap(TreeWalk.find(id: item.id, in: store.manifest.research))
        }
        return Fixture(store: store, chapter: chapter.id, a: try fresh(a), b: try fresh(b),
                       group: try fresh(group), linked: try fresh(linked), linked2: try fresh(linked2))
    }

    private func board(_ payload: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("tree-drop-\(UUID().uuidString)"))
        board.clearContents()
        board.setString(payload, forType: .string)
        return board
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
        XCTAssertEqual(TreeCanvasRowDrop.verdict(typeIdentifiers: file, draggedId: nil, items: items,
                                                 isReadOnly: false, carriesPictures: false), .refuse,
                       "a text file or a PDF is no picture: refused at the hover and the drop")
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
        XCTAssertTrue(TreeCanvasRowDrop.marksArrival(open: .item(chapter.id)))
        XCTAssertFalse(TreeCanvasRowDrop.marksArrival(open: .canvas), "one rule sets and clears")

        // A second drop of the same note lands on the same card.
        _ = TreeCanvasRowDrop.perform(verdict, providers: [], host: .init(store: store, state: state),
                                      report: { reported = $0 })
        let again = CanvasStore(projectRoot: store.url).load().scene
        XCTAssertEqual(again.unorderedNodes.filter { $0.id == .item(note.id) }.count, 1)
    }

    /// With this window's canvas in the centre the writer watches it land:
    /// no dot. The live model's arm lands it too, loose.
    func test_aDropWithTheCanvasOpenSetsNoDotAndLandsOnTheLiveModel() async throws {
        let store = try await novel()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        let model = CanvasModel()
        model.attach(projectRoot: store.url)
        store.liveCanvas = model
        let state = BinderTreeSectionsState()
        XCTAssertTrue(TreeCanvasRowDrop.perform(.research(note.id), providers: [],
                                                host: .init(store: store, state: state, open: .canvas),
                                                report: { XCTFail($0) }))
        XCTAssertNotNil(model.scene.node(.item(note.id)), "the live model holds the card")
        XCTAssertNil(CanvasMembership.homeRegion(of: .item(note.id), in: model.scene))
        XCTAssertFalse(state.canvasHasArrivals, "the canvas is open: nothing to announce")
        model.flush()
        store.liveCanvas = nil
    }

    /// The verdict's project facts are read once per manifest and canvas
    /// revision, never per drag entry.
    func test_theCanvasRowsFactsAreCachedPerRevision() async throws {
        let store = try await novel()
        let state = BinderTreeSectionsState()
        let first = TreeCanvasRowDrop.facts(store: store, state: state)
        XCTAssertEqual(state.canvasRowFacts?.key, first.key)
        XCTAssertEqual(TreeCanvasRowDrop.facts(store: store, state: state).key, first.key)
        _ = try await store.addResearchTextNote(parentId: nil, title: "New")
        let after = TreeCanvasRowDrop.facts(store: store, state: state)
        XCTAssertNotEqual(after.key, first.key, "a manifest change reads again")
        state.closedCanvasWrites += 1
        XCTAssertNotEqual(TreeCanvasRowDrop.facts(store: store, state: state).key, after.key,
                          "a closed-canvas write reads again")
    }

    /// A Collection script's Scenes follow the editor's re-parse: the window
    /// counts `.maughamScriptDidUpdate` into the Scenes' key (Minor 11).
    func test_theScriptUpdateMovesTheScenesKey() throws {
        let fold = try CanvasSourceCensus.source(at: "Maugham/Views/BinderPieceFold.swift")
        XCTAssertTrue(fold.contains(".onProjectEvent(.maughamScriptDidUpdate, url: store.url, window: nil) { _ in\n                state.scriptRevision += 1"))
        XCTAssertTrue(fold.contains(".task(id: PieceFoldScenesKey(modified: store.manifest.modified,\n                                         scriptRevision: state.scriptRevision))"))
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
        XCTAssertTrue(sections.contains("verbs.dropAnswers(on: .sharedSection)"))
        XCTAssertTrue(sections.contains("bundle.dropAnswers = { item in dropAnswers(on: .researchRow(item.id)) }"))
        let fold = try CanvasSourceCensus.source(at: "Maugham/Views/BinderPieceFold.swift")
        XCTAssertTrue(fold.contains("verbs.dropAnswers(on: .foldRow(rowId: item.id, documentId: documentId))"))
        let figures = try CanvasSourceCensus.source(at: "Maugham/Views/FigureSection.swift")
        XCTAssertTrue(figures.contains("verbs.dropAnswers(on: .figuresSection)"))
        XCTAssertTrue(figures.contains("verbs.dropAnswers(on: .figureRow(row.id))"))
        for host in ["Maugham/Views/BinderView.swift", "Maugham/Views/CollectionPiecesPane.swift",
                     "Maugham/Views/SceneNavigatorPane.swift"] {
            let source = try CanvasSourceCensus.source(at: host)
            XCTAssertTrue(source.contains("canvasDrop: .init(store: store, state: treeState,\n"
                                          + "                                              open: subject.open)"), host)
        }
        for host in ["Maugham/Views/BinderView.swift", "Maugham/Views/CollectionPiecesPane.swift"] {
            XCTAssertTrue(try CanvasSourceCensus.source(at: host)
                .contains("treeVerbs.dropAnswers(on: .pieceRow("), host)
        }
        let collection = try CanvasSourceCensus.source(at: "Maugham/Views/CollectionPiecesPane.swift")
        XCTAssertTrue(collection.contains("var destIdx = Self.landsBelow(position) ? targetIdx + 1 : targetIdx"),
                      "the Collection's drop and its line ask one rule")
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
