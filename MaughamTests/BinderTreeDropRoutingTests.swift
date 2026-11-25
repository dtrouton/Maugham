import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A drag across the binder tree, all the way to the manifest**
/// (shell-finish stage-2a Task 7).
///
/// `TreeDropIntentTests` says what each drop MEANS, over manifest values and
/// nothing else. This file says the meaning is carried out: the verbs the rows
/// call are asked on a real `ProjectStore`, and what is asserted afterwards is
/// the project on disk — a link that appeared, a file that moved between
/// `research/` and `pieces/<slug>/research/`, an order that changed.
///
/// **Why the verbs and not a drag.** A real drag session is not synthesisable
/// headless — nothing can drive the closure a `.dropDestination` installs — so
/// the production value the row's closure calls is as close to the writer's
/// gesture as a test can get. That the closures actually CALL it is a separate
/// question, held by `TripwireGrepTests.test_everyDropTargetInTheTreeReachesTheClassifier`.
@MainActor
final class BinderTreeDropRoutingTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []
    private var states: [ObjectIdentifier: BinderTreeSectionsState] = [:]
    /// A uniquely named pasteboard for the `draggedId(on:)` tests, released in
    /// teardown so nothing is left on the pasteboard server.
    private var pasteboard: NSPasteboard?

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        states.removeAll()
        pasteboard?.releaseGlobally()
        pasteboard = nil
        temp.cleanup()
        temp = nil
    }

    // MARK: - The Canvas row: a drop of several files is one step (shell p5 Task 4)

    /// Five photographs on the Canvas row with the canvas live: ⌘Z once and
    /// all five go, ⇧⌘Z and all five come back, under one name.
    func test_aFiveFileDropIsOneUndoStep() async throws {
        let (store, model) = try await canvasNovel()
        let paths = try await ingested(5, into: store)
        XCTAssertFalse(model.undoManager.canUndo, "premise: nothing to undo yet")

        let sent = try TreeCanvasRowDrop.land(pictures: paths, aspects: [:], store: store)
        XCTAssertEqual(sent.count, 5)
        let nodes = Set(sent.map(\.node))
        XCTAssertEqual(nodes.count, 5, "five cards")
        XCTAssertTrue(nodes.allSatisfy { model.scene.node($0) != nil })
        XCTAssertEqual(model.undoManager.undoActionName, "Add 5 Files")
        // One landing for the batch: its first card, where the run begins.
        let first = sent[0].node
        XCTAssertEqual(model.selection, .node(first), "the batch's first card is selected")
        XCTAssertEqual(model.pendingReveal, .node(first), "and revealed, once")
        let leftmost = try XCTUnwrap(nodes.min { model.scene.node($0)!.origin.x < model.scene.node($1)!.origin.x })
        XCTAssertEqual(first, leftmost, "the run goes rightwards from the card revealed")
        let landedAt = Dictionary(uniqueKeysWithValues: nodes.map { ($0, model.scene.node($0)!.origin) })

        model.undo.undo()
        XCTAssertTrue(nodes.allSatisfy { model.scene.node($0) == nil }, "one ⌘Z takes all five")
        XCTAssertFalse(model.undoManager.canUndo, "and it was one step")
        model.undo.redo()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: nodes.compactMap { id in
            model.scene.node(id).map { (id, $0.origin) } }), landedAt,
            "one ⇧⌘Z brings all five back where they landed")
        XCTAssertEqual(paths.filter { FileManager.default.fileExists(
            atPath: store.url.appendingPathComponent($0).path) }.count, 5,
            "the copies stay in the well, as any canvas undo leaves them")
        model.flush()
        store.liveCanvas = nil
    }

    /// One picture keeps the send's own name.
    func test_aOneFileDropKeepsItsName() async throws {
        let (store, model) = try await canvasNovel()
        let paths = try await ingested(1, into: store)
        _ = try TreeCanvasRowDrop.land(pictures: paths, aspects: [:], store: store)
        XCTAssertEqual(model.undoManager.undoActionName, CanvasCapture.undoStepName)
        XCTAssertEqual(TreeCanvasRowDrop.undoStepName(count: 1), "Send to Canvas")
        model.flush()
        store.liveCanvas = nil
    }

    /// A drop where one file fails its ingest names it, and its one step
    /// holds exactly the four that landed.
    func test_aDropWithAFailedFileNamesItAndItsStepHoldsTheRest() async throws {
        let (store, model) = try await canvasNovel()
        var providers: [NSItemProvider] = []
        for index in 0..<5 {
            let url = temp.url.appendingPathComponent("photo-\(index).png")
            try TestImageBytes.png(seed: index).write(to: url)
            providers.append(try XCTUnwrap(NSItemProvider(contentsOf: url)))
        }
        let outcome = await CanvasExternalDrop.ingest(
            providers: providers,
            using: CanvasAssetIngest(
                file: { url in
                    if url.lastPathComponent == "photo-2.png" {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    return try await store.ingestCanvasAsset(fileURL: url)
                },
                image: { try await store.ingestCanvasAsset(image: $0) }))
        XCTAssertEqual(outcome.paths.count, 4)
        XCTAssertEqual(outcome.message, "Couldn't add “photo-2.png” to the canvas.")
        let sent = try TreeCanvasRowDrop.land(pictures: outcome.paths, aspects: outcome.aspects,
                                              store: store)
        XCTAssertEqual(model.undoManager.undoActionName, "Add 4 Files")
        model.undo.undo()
        XCTAssertTrue(sent.allSatisfy { model.scene.node($0.node) == nil })
        XCTAssertFalse(model.undoManager.canUndo)
        model.flush()
        store.liveCanvas = nil
    }

    /// The closed canvas: one load and one save, five cards (no undo stack
    /// stands behind a closed canvas, as for one picture).
    func test_aFiveFileDropOnAClosedCanvasLandsAllFive() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let paths = try await ingested(5, into: store)
        let sent = try TreeCanvasRowDrop.land(pictures: paths, aspects: [:], store: store)
        let scene = CanvasStore(projectRoot: store.url).load().scene
        XCTAssertTrue(sent.allSatisfy { scene.node($0.node) != nil })
        XCTAssertEqual(Set(sent.map(\.node)).count, 5)
    }

    /// The Canvas row's drop lands through the batch: deleting the wiring
    /// turns this red.
    func test_theCanvasRowsDropLandsThroughTheBatch() throws {
        let code = SourceScan.codeLines(of: try SourceTree.declaration(
            named: "enum TreeCanvasRowDrop", under: "Maugham")).joined(separator: "\n")
        XCTAssertTrue(code.contains("let sent = try land(pictures: outcome.paths, aspects: outcome.aspects,"))
        XCTAssertTrue(code.contains("if !sent.isEmpty { arrived() }"), "one landing for the batch")
        XCTAssertTrue(code.contains("if let first = sent.first { CanvasCapture.show(first.node, in: store) }"))
        XCTAssertFalse(code.contains(".picture(path: path,"), "no per-file send")
    }

    private func canvasNovel() async throws -> (ProjectStore, CanvasModel) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let model = CanvasModel()
        model.attach(projectRoot: store.url)
        store.liveCanvas = model
        return (store, model)
    }

    /// `count` pictures ingested into the well, as a drop's ingest leaves them.
    private func ingested(_ count: Int, into store: ProjectStore) async throws -> [String] {
        var paths: [String] = []
        for index in 0..<count {
            let url = temp.url.appendingPathComponent("photo-\(index).png")
            try TestImageBytes.png(seed: index).write(to: url)
            paths.append(try await store.ingestCanvasAsset(fileURL: url))
        }
        return paths
    }

    // MARK: - A novel: the chapter row links

    func test_aNoteDroppedOnAChapterBecomesThatChaptersResearch() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)

        let accepted = verbs(store).routePieceRowDrop(
            draggedId: note.id, documentId: chapter.id,
            structureReorder: { XCTFail("a research id is not a manuscript reorder") })

        XCTAssertTrue(accepted, "the chapter can take it, so the drag lands")
        await settle(store) { !store.linkedResearchIds(forDocumentId: chapter.id).isEmpty }
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id), [note.id],
                       "a novel chapter's research is a LINK — the note has not "
                       + "moved anywhere, it now belongs to this chapter too")
    }

    func test_theSameNoteDraggedToTheResearchSectionLeavesTheChapter() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let accepted = verbs(store).routeSharedSectionDrop(draggedId: note.id)

        XCTAssertTrue(accepted)
        await settle(store) { store.linkedResearchIds(forDocumentId: chapter.id).isEmpty }
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id), [],
                       "out of the fold, out of the link — the drag is how a "
                       + "writer says this is the project's, not the chapter's")
        XCTAssertNotNil(research(named: "Ships", in: store),
                        "and the note itself is untouched: unlinking is not "
                        + "deleting, and shared research still holds it")
    }

    /// **A note given a closed chapter lands in sight** (shell p5 Task 4a, G):
    /// it leaves the Research section, so the chapter's fold opens and its row
    /// there is the one drawn selected — never a note that seems to vanish.
    func test_aNoteDroppedOnAClosedChapterOpensItsFold() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let state = state(for: store)
        XCTAssertFalse(state.expandedPieceFolds.contains(chapter.id), "premise: closed")

        XCTAssertTrue(verbs(store).routePieceRowDrop(
            draggedId: note.id, documentId: chapter.id, structureReorder: {}))

        XCTAssertTrue(state.expandedPieceFolds.contains(chapter.id))
        XCTAssertEqual(state.researchRowFolds[note.id], chapter.id)
        await settle(store) { !store.linkedResearchIds(forDocumentId: chapter.id).isEmpty }
        // And back: the section opens for it.
        state.researchSectionExpanded = false
        XCTAssertTrue(verbs(store).routeSharedSectionDrop(draggedId: note.id))
        XCTAssertTrue(state.researchSectionExpanded)
        XCTAssertNil(state.researchRowFolds[note.id])
        await settle(store) { store.linkedResearchIds(forDocumentId: chapter.id).isEmpty }
    }

    /// **Linked to two chapters, dragged out of the second one's fold**: the
    /// drag recorded its fold as it began (`researchDragSource`), and the drop
    /// unlinks that chapter alone.
    func test_aNoteDraggedOutOfOneOfItsTwoFoldsLeavesThatChapterOnly() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let one = try XCTUnwrap(store.manifest.structure.first)
        let two = try await store.addStructureItem(parentId: nil, title: "Two",
                                                   kind: .document(.markdown))
        try await store.linkResearch(researchId: note.id, toDocumentId: one.id)
        try await store.linkResearch(researchId: note.id, toDocumentId: two.id)

        let verbs = verbs(store)
        verbs.bundle.dragStarted(note.id, two.id)
        XCTAssertTrue(verbs.routeSharedSectionDrop(draggedId: note.id))
        await settle(store) { store.linkedResearchIds(forDocumentId: two.id).isEmpty }
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: one.id), [note.id],
                       "chapter one keeps it")
    }

    /// **A link edit asks what linking asks**: with no posture door behind the
    /// tree, the drop is refused, named, and its hover shows nothing.
    func test_aLinkThisMacMayNotMakeIsRefusedAndNamed() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let verbs = verbs(store)
        XCTAssertTrue(verbs.mayEditResearchLinks(of: chapter.id), "premise: the author may")
        store.documentStore = nil
        XCTAssertEqual(verbs.permitted(.link(researchId: note.id, toDocumentId: chapter.id)),
                       .refuse(.linksNotPermitted))
        XCTAssertEqual(TreeDropIntent.Reason.linksNotPermitted.explanation,
                       "this Mac may not change that piece's research links")
        XCTAssertFalse(verbs.routePieceRowDrop(draggedId: note.id, documentId: chapter.id,
                                               structureReorder: {}))
        XCTAssertFalse(verbs.answers(draggedId: note.id, on: .pieceRow(chapter.id)).accepts)
        XCTAssertEqual(verbs.permitted(.researchReorder), .researchReorder,
                       "control: a reorder is no link edit")
    }

    func test_aNoteDroppedInsideAChaptersFoldLinksToThatChapter() async throws {
        let store = try await novel(notes: ["Ships", "Tides"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let tides = try XCTUnwrap(research(named: "Tides", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        try await store.linkResearch(researchId: tides.id, toDocumentId: chapter.id)

        // The fold's own bundle — the one difference from the section's is the
        // document it carries, and this is the assertion that it carries it.
        let actions = TreeHostFixture.foldView(
            store: store, state: BinderTreeSectionsState(),
            subject: .constant(.book),
            documentId: chapter.id, layout: .rows([])).actions
        let accepted = actions.internalDrop(ships.id, .middle, tides)

        XCTAssertTrue(accepted)
        await settle(store) {
            store.linkedResearchIds(forDocumentId: chapter.id).count == 2
        }
        XCTAssertEqual(
            Set(store.linkedResearchIds(forDocumentId: chapter.id)),
            [ships.id, tides.id],
            "a fold row is a near-miss of the piece row above it and means the "
            + "same thing. Without the fold's re-route this would have been "
            + "read as an ordinary research row and quietly REORDERED shared "
            + "research instead — with nothing on screen to say so")
    }

    /// The control: the same drop on a row of the SHARED section, where there
    /// is no document, is the ordinary reorder and links nothing.
    func test_control_theSameDropOnTheSharedSectionsRowsLinksNothing() async throws {
        let store = try await novel(notes: ["Ships", "Tides"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let tides = try XCTUnwrap(research(named: "Tides", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let sections = BinderTreeSections(
            store: store, state: BinderTreeSectionsState(),
            subject: .constant(.book))

        XCTAssertTrue(sections.actions.internalDrop(ships.id, .top, tides))

        await settle(store) {
            store.manifest.research.filter { $0.role == nil }.first?.title == "Ships"
        }
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id), [],
                       "control: the section's rows carry no document, so the "
                       + "same gesture is a reorder — which is what makes the "
                       + "fold assertion above about the re-route")
        XCTAssertEqual(
            store.manifest.research.filter { $0.role == nil }.map(\.title),
            ["Ships", "Tides"],
            "…and the reorder happened: Ships moved above Tides")
    }

    // MARK: - A whole-book group over a chapter's notes (fix round 1, I2)

    /// "World" holds Maps (Chapter One's), Tides (Five's) and Coast (the
    /// book's). The section draws World with Coast alone.
    private func worldOverTwoChapters() async throws
        -> (ProjectStore, world: ResearchItem, maps: ResearchItem, tides: ResearchItem,
            coast: ResearchItem, one: StructureItem, five: StructureItem) {
        let store = try await novel(notes: [])
        let world = try await store.addResearchItem(parentId: nil, title: "World", kind: nil)
        let maps = try await store.addResearchTextNote(parentId: world.id, title: "Maps")
        let tides = try await store.addResearchTextNote(parentId: world.id, title: "Tides")
        let coast = try await store.addResearchTextNote(parentId: world.id, title: "Coast")
        let one = try XCTUnwrap(store.manifest.structure.first)
        let five = try await store.addStructureItem(parentId: nil, title: "Five",
                                                    kind: .document(.markdown))
        try await store.linkResearch(researchId: maps.id, toDocumentId: one.id)
        try await store.linkResearch(researchId: tides.id, toDocumentId: five.id)
        return (store, world, maps, tides, coast, one, five)
    }

    private func onDisk(_ item: ResearchItem, _ store: ProjectStore) -> Bool {
        guard let live = TreeWalk.find(id: item.id, in: store.manifest.research),
              let path = live.path else { return false }
        return FileManager.default.fileExists(atPath: store.url.appendingPathComponent(path).path)
    }

    /// **Delete on a group the section draws with one note trashes that one
    /// note**: the two chapters' notes stay in their folds, on disk and in the
    /// manifest, and the question named them before anything went.
    func test_aWholeBookGroupsDeleteTrashesOnlyWhatTheSectionShows() async throws {
        let (store, world, maps, tides, coast, one, five) = try await worldOverTwoChapters()
        let state = state(for: store)
        XCTAssertEqual(state.researchHomes(in: store.manifest).wholeBook
            .first { $0.id == world.id }?.children?.map(\.id), [coast.id],
                       "premise: the section shows World with Coast alone")

        verbs(store).bundle.delete(world.id)

        guard case .confirmHeld(let act)? = state.pendingAlert else {
            return XCTFail("a group over chapters' notes asks first; nothing was deleted yet")
        }
        XCTAssertTrue(onDisk(coast, store), "nothing goes before the answer")
        XCTAssertEqual(act.take.taken, [coast.id])
        XCTAssertEqual(act.take.held, [maps.id, tides.id])
        XCTAssertEqual(act.confirmTitle, "Delete")
        XCTAssertTrue(act.message.contains("“Maps” (\(one.title))"), act.message)
        XCTAssertTrue(act.message.contains("“Tides” (Five)"), act.message)
        XCTAssertTrue(act.message.contains("Trash"), act.message)

        try await BinderTreeVerbs.performHeld(act, store: store)

        XCTAssertNil(TreeWalk.find(id: coast.id, in: store.manifest.research), "Coast went")
        for kept in [maps, tides] {
            XCTAssertNotNil(TreeWalk.find(id: kept.id, in: store.manifest.research), kept.title)
            XCTAssertTrue(onDisk(kept, store), "\(kept.title) is still on disk")
        }
        XCTAssertNotNil(TreeWalk.find(id: world.id, in: store.manifest.research),
                        "World stays on as their group")
        let homes = state.researchHomes(in: store.manifest)
        XCTAssertTrue(homes.isContainer(world.id), "…drawn nowhere: it holds only theirs")
        XCTAssertFalse(homes.wholeBook.contains { $0.id == world.id },
                       "no empty-looking group carries notes in the section")
        XCTAssertEqual(homes.place(of: maps.id), "World", "their place still names it")
        for (note, chapter) in [(maps, one), (tides, five)] {
            guard case .rows(let rows)? = state.foldLayout(of: chapter.id, in: store.manifest) else {
                return XCTFail("\(chapter.title) draws a fold")
            }
            XCTAssertTrue(rows.contains(.research(id: note.id, title: note.title, owned: false)),
                          "\(note.title) is in \(chapter.title)'s fold")
        }
    }

    /// **Move takes the group and its whole-book research; the chapters'
    /// notes are lifted out first** and stay with their chapters, where the
    /// group stood.
    func test_aWholeBookGroupsMoveLeavesTheChaptersNotes() async throws {
        let (store, world, maps, tides, coast, one, five) = try await worldOverTwoChapters()
        let places = try await store.addResearchItem(parentId: nil, title: "Places", kind: nil)
        let state = state(for: store)

        verbs(store).bundle.move([world.id], .group(places.id))

        guard case .confirmHeld(let act)? = state.pendingAlert else {
            return XCTFail("a group over chapters' notes asks first")
        }
        XCTAssertEqual(act.title, "Move “World” to “Places”?")
        XCTAssertEqual(act.lifts, [HeldResearchAct.Lift(ids: [maps.id, tides.id], to: .sharedRoot)])
        try await BinderTreeVerbs.performHeld(act, store: store)

        let movedWorld = try XCTUnwrap(TreeWalk.find(id: places.id, in: store.manifest.research)?
            .children?.first { $0.id == world.id }, "World is in Places")
        XCTAssertEqual(movedWorld.children?.map(\.id), [coast.id], "with Coast, and only Coast")
        XCTAssertEqual(Set(store.manifest.research.map(\.id)).intersection([maps.id, tides.id]),
                       [maps.id, tides.id], "the chapters' notes stand where World stood")
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: one.id), [maps.id])
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: five.id), [tides.id])
        for note in [maps, tides, coast] { XCTAssertTrue(onDisk(note, store), note.title) }
    }

    // MARK: - Fix round 2: nested groups, the drag's Move, the fold's Delete

    /// World ▸ Coast ▸ [Tides (the book's), Maps (Chapter One's)], or with a
    /// third level (World ▸ Coast ▸ Bay ▸ […]).
    private func nestedWorld(depth: Int) async throws
        -> (ProjectStore, world: ResearchItem, inner: ResearchItem, tides: ResearchItem,
            maps: ResearchItem, one: StructureItem) {
        let store = try await novel(notes: [])
        let world = try await store.addResearchItem(parentId: nil, title: "World", kind: nil)
        var inner = try await store.addResearchItem(parentId: world.id, title: "Coast", kind: nil)
        if depth == 3 {
            inner = try await store.addResearchItem(parentId: inner.id, title: "Bay", kind: nil)
        }
        let tides = try await store.addResearchTextNote(parentId: inner.id, title: "Tides")
        let maps = try await store.addResearchTextNote(parentId: inner.id, title: "Maps")
        let one = try XCTUnwrap(store.manifest.structure.first)
        try await store.linkResearch(researchId: maps.id, toDocumentId: one.id)
        return (store, world, inner, tides, maps, one)
    }

    /// **A chapter's note two and three groups down is held too** (NB1):
    /// Delete on World asks, names Maps with its chapter, trashes Tides and
    /// never Maps.
    func test_aNestedChaptersNoteIsHeldByDelete() async throws {
        for depth in [2, 3] {
            let (store, world, _, tides, maps, one) = try await nestedWorld(depth: depth)
            let state = state(for: store)
            verbs(store).bundle.delete(world.id)
            guard case .confirmHeld(let act)? = state.pendingAlert else {
                return XCTFail("depth \(depth): Delete asks first")
            }
            XCTAssertEqual(act.take.held, [maps.id], "depth \(depth)")
            XCTAssertTrue(act.message.contains("“Maps” (\(one.title))"), act.message)
            XCTAssertEqual(act.take.taken, [tides.id], "depth \(depth): only the book's note goes")
            state.dismissAlert(.confirmHeld(act))
            try await BinderTreeVerbs.performHeld(act, store: store)
            XCTAssertNil(TreeWalk.find(id: tides.id, in: store.manifest.research))
            XCTAssertTrue(onDisk(maps, store), "depth \(depth): Maps stays")
            XCTAssertEqual(store.linkedResearchIds(forDocumentId: one.id), [maps.id])
        }
    }

    /// **Move lifts the nested note first** (NB1): World arrives in Places
    /// with Tides; Maps stands where World stood.
    func test_aNestedChaptersNoteIsLiftedByMove() async throws {
        for depth in [2, 3] {
            let (store, world, _, tides, maps, _) = try await nestedWorld(depth: depth)
            let places = try await store.addResearchItem(parentId: nil, title: "Places", kind: nil)
            let state = state(for: store)
            verbs(store).bundle.move([world.id], .group(places.id))
            guard case .confirmHeld(let act)? = state.pendingAlert else {
                return XCTFail("depth \(depth): Move asks first")
            }
            state.dismissAlert(.confirmHeld(act))
            try await BinderTreeVerbs.performHeld(act, store: store)
            XCTAssertTrue(store.manifest.research.contains { $0.id == maps.id }, "depth \(depth): lifted")
            let moved = try XCTUnwrap(TreeWalk.find(id: places.id, in: store.manifest.research))
            XCTAssertTrue(TreeWalk.contains(id: tides.id, in: moved.children ?? []),
                          "depth \(depth): Tides went with World")
        }
    }

    /// **A drag of a section group is the menu's Move** (NB2): onto another
    /// group, or beside a row, it asks the same question and lifts the same.
    func test_aGroupDraggedOntoAGroupAsksAsTheMenuDoes() async throws {
        let (store, world, maps, tides, coast, _, _) = try await worldOverTwoChapters()
        let places = try await store.addResearchItem(parentId: nil, title: "Places", kind: nil)
        let state = state(for: store)
        let verbs = verbs(store)

        XCTAssertTrue(verbs.routeResearchRowDrop(draggedId: world.id, position: .middle,
                                                 target: places, inFoldOf: nil))
        guard case .confirmHeld(let act)? = state.pendingAlert else {
            return XCTFail("the drag asks, as Move to ▸ does")
        }
        XCTAssertEqual(act.take.held, [maps.id, tides.id])
        XCTAssertEqual(act.lifts, [HeldResearchAct.Lift(ids: [maps.id, tides.id], to: .sharedRoot)])
        state.dismissAlert(.confirmHeld(act))
        try await BinderTreeVerbs.performHeld(act, store: store)
        let moved = try XCTUnwrap(TreeWalk.find(id: places.id, in: store.manifest.research)?
            .children?.first { $0.id == world.id })
        XCTAssertEqual(moved.children?.map(\.id), [coast.id], "the same result as the menu's")

        // Into a group in another Research group asks too: a different parent.
        let (store2, world2, _, _, _, _, _) = try await worldOverTwoChapters()
        let shelf = try await store2.addResearchItem(parentId: nil, title: "Shelf", kind: nil)
        let anchor = try await store2.addResearchTextNote(parentId: shelf.id, title: "Anchor")
        XCTAssertTrue(self.verbs(store2).routeResearchRowDrop(draggedId: world2.id, position: .bottom,
                                                         target: anchor, inFoldOf: nil))
        guard case .confirmHeld? = self.state(for: store2).pendingAlert else {
            return XCTFail("a move to another parent asks")
        }
    }

    /// **The half-done Move says what happened** (NB3): the chapters' notes
    /// were lifted out, then the group's move failed.
    func test_aMoveThatFailsAfterItsLiftSaysWhatHappened() async throws {
        let (store, world, maps, _, coast, _, _) = try await worldOverTwoChapters()
        let inside = try await store.addResearchItem(parentId: world.id, title: "Inside", kind: nil)
        _ = coast
        let act = try XCTUnwrap(verbs(store).heldAct(.move(.group(inside.id), landing: .end),
                                                     ids: [world.id]))
        do {
            try await BinderTreeVerbs.performHeld(act, store: store)
            XCTFail("a group cannot move into itself")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix(
                "The chapters’ notes were lifted out of “World”, but “World” couldn’t be moved: "),
                          error.localizedDescription)
        }
        XCTAssertTrue(store.manifest.research.contains { $0.id == maps.id }, "the lift stands")
    }

    /// **A fold's Delete on a linked group keeps a note another chapter
    /// links** (OOS1): it asks, names it with that chapter, and leaves it.
    func test_aFoldsDeleteOfALinkedGroupKeepsAnotherChaptersNote() async throws {
        let store = try await novel(notes: [])
        let group = try await store.addResearchItem(parentId: nil, title: "Ships", kind: nil)
        let shared = try await store.addResearchTextNote(parentId: group.id, title: "Hull")
        let own = try await store.addResearchTextNote(parentId: group.id, title: "Mast")
        let one = try XCTUnwrap(store.manifest.structure.first)
        let two = try await store.addStructureItem(parentId: nil, title: "Two", kind: .document(.markdown))
        try await store.linkResearch(researchId: group.id, toDocumentId: one.id)
        try await store.linkResearch(researchId: shared.id, toDocumentId: two.id)
        let state = state(for: store)
        let fold = TreeHostFixture.foldView(store: store, state: state, subject: .constant(.book),
                                            documentId: one.id, layout: .rows([]))
        fold.actions.delete(group.id)
        guard case .confirmHeld(let act)? = state.pendingAlert else {
            return XCTFail("the fold's Delete asks")
        }
        XCTAssertEqual(act.take.held, [shared.id])
        XCTAssertTrue(act.message.contains("“Hull” (Two)"), act.message)
        XCTAssertEqual(act.take.taken, [own.id])
        state.dismissAlert(.confirmHeld(act))
        try await BinderTreeVerbs.performHeld(act, store: store)
        XCTAssertTrue(onDisk(shared, store), "Hull stays, Two's")
        XCTAssertNil(TreeWalk.find(id: own.id, in: store.manifest.research))
    }

    /// **A fold row's Move is the plain move** (fix round 3, a): Ships,
    /// Chapter One's linked group holding Hull (which Chapter Two links too),
    /// moves whole into Places from Chapter One's fold — nothing asked,
    /// nothing lifted, and Hull is still in both folds. A link is held by id;
    /// a move never changes a chapter's membership.
    func test_aFoldRowsMoveIsThePlainMove() async throws {
        let store = try await novel(notes: [])
        let ships = try await store.addResearchItem(parentId: nil, title: "Ships", kind: nil)
        let hull = try await store.addResearchTextNote(parentId: ships.id, title: "Hull")
        _ = try await store.addResearchTextNote(parentId: ships.id, title: "Mast")
        let places = try await store.addResearchItem(parentId: nil, title: "Places", kind: nil)
        let one = try XCTUnwrap(store.manifest.structure.first)
        let two = try await store.addStructureItem(parentId: nil, title: "Two", kind: .document(.markdown))
        try await store.linkResearch(researchId: ships.id, toDocumentId: one.id)
        try await store.linkResearch(researchId: hull.id, toDocumentId: two.id)
        let state = state(for: store)
        XCTAssertNil(verbs(store).heldAct(.move(.group(places.id), landing: .end), ids: [ships.id]),
                     "no question from a fold row")
        let fold = TreeHostFixture.foldView(store: store, state: state, subject: .constant(.book),
                                            documentId: one.id, layout: .rows([]))
        fold.actions.move([ships.id], .group(places.id))
        XCTAssertNil(state.pendingAlert, "nothing asked")
        await settle(store) {
            TreeWalk.find(id: places.id, in: store.manifest.research)?.children?.contains { $0.id == ships.id } == true
        }
        let moved = try XCTUnwrap(TreeWalk.find(id: ships.id, in: store.manifest.research))
        XCTAssertTrue(TreeWalk.contains(id: hull.id, in: moved.children ?? []), "Ships moved whole")
        XCTAssertEqual(state.researchHomes(in: store.manifest).homes(of: hull.id), [one.id, two.id],
                       "Hull is in both folds still")
    }

    /// **A move never takes a note from a chapter** (round 3): Ships is
    /// Chapter One's; Hull, inside it, Chapter Two links too. Moving Hull out
    /// of Ships would take it from Chapter One: refused at the door, named,
    /// and not offered in Move to ▸. Within Ships it may go anywhere.
    func test_aNoteHeldThroughItsGroupDoesNotMoveOutOfIt() async throws {
        let store = try await novel(notes: [])
        let ships = try await store.addResearchItem(parentId: nil, title: "Ships", kind: nil)
        let hull = try await store.addResearchTextNote(parentId: ships.id, title: "Hull")
        let deck = try await store.addResearchItem(parentId: ships.id, title: "Deck", kind: nil)
        let places = try await store.addResearchItem(parentId: nil, title: "Places", kind: nil)
        let one = try XCTUnwrap(store.manifest.structure.first)
        let two = try await store.addStructureItem(parentId: nil, title: "Two", kind: .document(.markdown))
        try await store.linkResearch(researchId: ships.id, toDocumentId: one.id)
        try await store.linkResearch(researchId: hull.id, toDocumentId: two.id)
        let state = state(for: store)
        let verbs = verbs(store)
        XCTAssertFalse(verbs.requestMove([hull.id], to: .group(places.id), landing: .end))
        XCTAssertEqual(state.pendingError,
                       "Couldn’t move “Hull”: it is in a group a chapter holds, and moves with its group.")
        let targets = verbs.bundle.moveTargets([hull.id]).map(\.target)
        XCTAssertFalse(targets.contains(.group(places.id)), "not offered")
        XCTAssertTrue(targets.contains(.group(deck.id)), "inside its group it may go")
    }

    /// **A move into its own descendant is refused before anything is asked
    /// or lifted** (fix round 3, b): World dragged onto Coast inside it.
    func test_aMoveIntoItsOwnGroupIsRefusedBeforeAsking() async throws {
        let (store, world, maps, _, coast, _, _) = try await worldOverTwoChapters()
        let inner = try await store.addResearchItem(parentId: world.id, title: "Inner", kind: nil)
        _ = coast
        let state = state(for: store)
        XCTAssertFalse(verbs(store).routeResearchRowDrop(draggedId: world.id, position: .middle,
                                                         target: inner, inFoldOf: nil))
        XCTAssertEqual(state.pendingError, "Couldn’t move “World” into “Inner”: a group can’t go inside itself.")
        let after = try XCTUnwrap(TreeWalk.find(id: world.id, in: store.manifest.research))
        XCTAssertTrue(TreeWalk.contains(id: maps.id, in: after.children ?? []), "nothing lifted")
    }

    /// **The answer acts on the manifest as it is then** (fix round 3, c): a
    /// note linked while the question was up is not trashed — the question
    /// is asked again, naming it.
    func test_theAnswerActsOnTheLiveManifest() async throws {
        let (store, world, maps, tides, coast, one, _) = try await worldOverTwoChapters()
        let state = state(for: store)
        verbs(store).bundle.delete(world.id)
        guard case .confirmHeld(let asked)? = state.pendingAlert else { return XCTFail("asks") }
        XCTAssertEqual(asked.take.held, [maps.id, tides.id])
        try await store.linkResearch(researchId: coast.id, toDocumentId: one.id)

        BinderTreeVerbs.confirmHeld(asked, store: store, state: state)
        guard case .confirmHeld(let again)? = state.pendingAlert else {
            return XCTFail("what is held changed: it asks again")
        }
        XCTAssertEqual(Set(again.take.held), [maps.id, tides.id, coast.id])
        XCTAssertTrue(again.message.contains("“Coast”"), again.message)
        XCTAssertTrue(onDisk(coast, store), "Coast, now a chapter's, was not trashed")
    }

    /// **A same-parent reorder of a Research group asks nothing** (fix round
    /// 3, e): nothing about the chapters' notes changes.
    func test_aSameParentReorderOfAGroupAsksNothing() async throws {
        let (store, world, maps, _, _, _, _) = try await worldOverTwoChapters()
        let anchor = try await store.addResearchTextNote(parentId: nil, title: "Anchor")
        let state = state(for: store)
        XCTAssertTrue(verbs(store).routeResearchRowDrop(draggedId: world.id, position: .bottom,
                                                        target: anchor, inFoldOf: nil))
        XCTAssertNil(state.pendingAlert, "a reorder asks nothing")
        await settle(store) { store.manifest.research.last?.id == world.id }
        let after = try XCTUnwrap(TreeWalk.find(id: world.id, in: store.manifest.research))
        XCTAssertTrue(TreeWalk.contains(id: maps.id, in: after.children ?? []), "nothing lifted")
    }

    /// **Every tree research delete goes through the one door** (fix round
    /// 3, d): `requestDelete` and the answered question, counted per file.
    func test_everyTreeResearchDeleteGoesThroughTheHeldDoor() throws {
        var found: [String: Int] = [:]
        for file in try SourceTree.swiftFiles(under: "Maugham/Views") {
            let count = Self.storeDeletes(in: try SourceTree.read(file))
            if count > 0 { found[file] = count }
        }
        XCTAssertEqual(found, ["Maugham/Views/BinderTreeSections.swift": 1], "`performDelete`")
    }

    func test_theDeleteDoorCensusSeesAPlantedOffender() {
        XCTAssertEqual(Self.storeDeletes(in: """
            perform { try await store.deleteResearchItems(ids: ids) }
            perform { try await store.deleteResearchItem(id: id) }
            """), 2)
        XCTAssertEqual(Self.storeDeletes(in: """
            requestDelete([id])
            // store.deleteResearchItems( in a comment
            """), 0)
    }

    static func storeDeletes(in text: String) -> Int {
        SourceScan.codeLines(of: text).filter {
            !$0.contains("func ") && ($0.contains(".deleteResearchItems(") || $0.contains(".deleteResearchItem("))
        }.count
    }

    /// **No group move reaches the store but through the one door** (NB2):
    /// the tree's research moves are counted per file, so a drop or a menu
    /// that calls the mover itself fails here.
    func test_everyTreeResearchMoveGoesThroughTheHeldDoor() throws {
        var found: [String: Int] = [:]
        for file in try SourceTree.swiftFiles(under: "Maugham/Views") {
            let count = Self.storeMoves(in: try SourceTree.read(file))
            if count > 0 { found[file] = count }
        }
        XCTAssertEqual(found, [
            // `performMove`, the door's one call: its lift and its move.
            "Maugham/Views/BinderTreeSections.swift": 2,
            // A figure's copy into a group it was sent to: one new note.
            "Maugham/Views/FigureActions.swift": 1,
        ])
    }

    func test_theMoveDoorCensusSeesAPlantedOffender() {
        XCTAssertEqual(Self.storeMoves(in: """
            perform { try await store.moveResearchItems(ids: ids, to: target) }
            perform { try await store.moveResearchItem(id: id, toParentId: nil, atIndex: 0) }
            """), 2)
        XCTAssertEqual(Self.storeMoves(in: """
            requestMove(ids, to: target, landing: .end)
            // store.moveResearchItems( in a comment
            """), 0)
    }

    static func storeMoves(in text: String) -> Int {
        SourceScan.codeLines(of: text).filter {
            !$0.contains("func ") && ($0.contains(".moveResearchItems(") || $0.contains(".moveResearchItem("))
        }.count
    }

    /// **Filing into a Collection piece's own folder is creation** (NB5): a
    /// Finder drop there and the fold's New Note ask the same — nothing the
    /// link door asks. Only a link edit asks the posture's link question.
    func test_aCollectionPiecesFolderTakesAFinderDropAsItsNewNoteDoes() async throws {
        let store = try await collection(pieces: ["Alpha"], notes: [])
        let piece = try XCTUnwrap(store.manifest.structure.first { $0.title == "Alpha" })
        store.documentStore = nil
        let verbs = verbs(store)
        XCTAssertFalse(verbs.mayEditResearchLinks(of: piece.id), "premise: the link door refuses")
        XCTAssertEqual(verbs.externalIntent(on: .pieceRow(piece.id), position: .middle),
                       .importFiles(.piece(piece.id)))
        XCTAssertNil(BinderPieceFold.creationRefusal(
            inFoldOf: piece.id, homes: state(for: store).researchHomes(in: store.manifest),
            mayLink: false, pieceTitle: piece.title))
    }

    /// **Where the posture refuses the link, New Note is not offered on the
    /// rows whose note would link** (ruling 10): a chapter's root rows;
    /// inside a group the chapter holds it lands without a link and stays.
    func test_aFoldOffersNoNoteItCouldNotMake() async throws {
        let store = try await novel(notes: ["Ships"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let group = try await store.addResearchItem(parentId: nil, title: "World", kind: nil)
        let inner = try await store.addResearchTextNote(parentId: group.id, title: "Maps")
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        try await store.linkResearch(researchId: ships.id, toDocumentId: chapter.id)
        try await store.linkResearch(researchId: group.id, toDocumentId: chapter.id)
        let state = state(for: store)
        func fold() -> BinderPieceFold {
            TreeHostFixture.foldView(store: store, state: state, subject: .constant(.book),
                                     documentId: chapter.id, layout: .rows([]))
        }
        XCTAssertTrue(fold().actions.offersMaking(ships), "premise: the author may")
        store.documentStore = nil
        let actions = fold().actions
        XCTAssertFalse(actions.offersMaking(ships), "a root row's note would link")
        XCTAssertTrue(actions.offersMaking(group), "inside the group the chapter holds")
        XCTAssertTrue(actions.offersMaking(TreeWalk.find(id: inner.id, in: store.manifest.research)!))
        let node = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ResearchTree.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(node.contains("if actions.offersMaking(item) {"))
    }

    /// **The fold offers no New Group, Add File or Add Link at its top**
    /// (OOS2): a row offers them on a group only, and makes them inside that
    /// group — which a fold draws only where its piece holds it.
    func test_aFoldsGroupVerbsLandInsideTheGroupTheRowIs() throws {
        let node = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ResearchTree.swift"))
            .joined(separator: "\n")
        let lines = node.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let start = try XCTUnwrap(lines.firstIndex(of: "Button(\"New Group\") { actions.newGroup(item.id) }"))
        XCTAssertEqual(lines[start - 1], "if item.type == .group {", "offered on a group row only")
        XCTAssertEqual(lines[start + 1], "Button(\"Add File…\") { actions.addFile(item.id) }")
        XCTAssertEqual(lines[start + 2], "Button(\"Add Link…\") { actions.addLink(item.id) }")
        let fold = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/BinderPieceFold.swift"))
            .joined(separator: "\n")
        XCTAssertFalse(fold.contains("newGroup(nil)") || fold.contains("addFile(nil)")
                       || fold.contains("addLink(nil)"), "no top-level maker in the fold")
    }

    /// The control: a group with nothing of a chapter's under it deletes as
    /// it always did, asking nothing.
    func test_control_aPlainGroupDeletesWithoutAsking() async throws {
        let store = try await novel(notes: [])
        let world = try await store.addResearchItem(parentId: nil, title: "World", kind: nil)
        _ = try await store.addResearchTextNote(parentId: world.id, title: "Coast")
        let state = state(for: store)
        XCTAssertNil(BinderTreeVerbs(store: store, state: state, subject: .constant(.book))
            .heldAct(.delete, ids: [world.id]))
    }

    // MARK: - Drags and menus out of a fold (fix round 1: I1, I4, I5, M4, M7, M9)

    /// **A drag of three notes out of chapter one's fold moves all three**
    /// (I1): the rows the drag did not start on take their source from the
    /// fold each was selected in.
    func test_aThreeRowDragOutOfAFoldMovesEveryRow() async throws {
        let store = try await novel(notes: ["Ships", "Tides", "Maps"])
        let notes = ["Ships", "Tides", "Maps"].compactMap { research(named: $0, in: store) }
        let one = try XCTUnwrap(store.manifest.structure.first)
        let two = try await store.addStructureItem(parentId: nil, title: "Two", kind: .document(.markdown))
        for note in notes { try await store.linkResearch(researchId: note.id, toDocumentId: one.id) }
        let state = state(for: store)
        // Three rows chosen in chapter one's fold, the last one pulled up.
        var chosen = WindowSubject.book
        chosen.beside = .research(notes[2].id)
        state.record(selection: Set(notes.map { .research($0.id) }), subject: chosen)
        for note in notes { state.researchRowFolds[note.id] = one.id }

        let verbs = BinderTreeVerbs(store: store, state: state, subject: .constant(chosen))
        XCTAssertEqual(Set(verbs.actingIds(forRow: notes[1].id)), Set(notes.map(\.id)), "premise: a batch")
        verbs.bundle.dragStarted(notes[1].id, one.id)
        XCTAssertTrue(verbs.routePieceRowDrop(draggedId: notes[1].id, documentId: two.id,
                                              structureReorder: {}))
        await settle(store) { store.linkedResearchIds(forDocumentId: one.id).isEmpty }
        XCTAssertEqual(Set(store.linkedResearchIds(forDocumentId: two.id)), Set(notes.map(\.id)),
                       "every dragged row moved")
        XCTAssertNil(state.researchDragSource, "the drop clears the drag's record (M9)")
    }

    /// **A drag's record goes at the next press** (M9): a drag cancelled in
    /// this window, then one begun anywhere else, never lends the old source.
    func test_aPressClearsTheLastDragsSource() {
        let state = BinderTreeSectionsState()
        state.researchDragSource = ("n", "ch1")
        state.pointerWentDown()
        XCTAssertNil(state.researchDragSource)
    }

    /// **A move between chapters is one save** (M7): unlinked from one and
    /// linked to the other together, or neither.
    func test_aMoveBetweenChaptersIsOneSave() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let one = try XCTUnwrap(store.manifest.structure.first)
        let two = try await store.addStructureItem(parentId: nil, title: "Two", kind: .document(.markdown))
        try await store.linkResearch(researchId: note.id, toDocumentId: one.id)
        let saves = store.manifestSaveCount
        try await verbs(store).relink([note.id], from: [one.id], to: two.id)
        XCTAssertEqual(store.manifestSaveCount, saves + 1)
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: one.id), [])
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: two.id), [note.id])
    }

    /// **Every link edit asks the posture** (I4): a Finder file dropped on a
    /// chapter this Mac may not change is refused, its hover shows nothing,
    /// and nothing is imported.
    func test_aFinderDropOnAChapterThePostureRefusesIsRefused() async throws {
        let store = try await novel(notes: [])
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let file = try makeFile(named: "Notes.txt", contents: "x")
        let before = store.manifest.research.count
        store.documentStore = nil
        let verbs = verbs(store)
        XCTAssertFalse(verbs.routeExternalDrop(providers: [provider(for: file)], position: .middle,
                                               target: .pieceRow(chapter.id)))
        XCTAssertEqual(verbs.externalFeedback(on: .pieceRow(chapter.id), position: .middle), .none)
        XCTAssertEqual(store.manifest.research.count, before, "nothing imported")
    }

    /// **A fold's New Note links, so it asks too** (I4) — and the answer to
    /// "is it offered on a view-only share": the row menu offers New Note
    /// everywhere (only New Table is withheld, `offersNewTable`); in a
    /// chapter's fold on a Mac that may not change the chapter's links it is
    /// refused, named, and makes nothing.
    func test_aFoldsNewNoteIsRefusedWhereThePostureRefusesTheLink() async throws {
        let store = try await novel(notes: [])
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let state = state(for: store)
        store.documentStore = nil
        let fold = TreeHostFixture.foldView(store: store, state: state, subject: .constant(.book),
                                            documentId: chapter.id, layout: .rows([]))
        fold.actions.newNote(nil)
        _ = await pumpUntil(deadline: 5) { state.pendingError != nil }
        XCTAssertEqual(state.pendingError,
                       "Couldn’t add to “\(chapter.title)”: this Mac may not change that piece's research links.")
        XCTAssertTrue(store.manifest.research.filter { $0.role == nil }.isEmpty, "nothing was made")
        let node = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ResearchTree.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(node.contains("Button(\"New Note\") {"), "offered on every row")
    }

    /// **Duplicate from a fold lands in that fold** (M4): the copy of a note
    /// the chapter links is linked to the chapter too.
    func test_duplicateFromAFoldLandsInThatFold() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)
        let fold = TreeHostFixture.foldView(store: store, state: state(for: store), subject: .constant(.book),
                                            documentId: chapter.id, layout: .rows([]))
        fold.actions.duplicate(note.id)
        await settle(store) { store.linkedResearchIds(forDocumentId: chapter.id).count == 2 }
        let copy = try XCTUnwrap(research(named: "Copy of Ships", in: store))
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id), [note.id, copy.id])
        XCTAssertFalse(state(for: store).researchHomes(in: store.manifest).isWholeBook(copy.id),
                       "not in the Research section")
    }

    /// **A landing is always in sight** (I5): Move to Chapter into a chapter
    /// inside a closed Part opens the Part and scrolls to the row; Make
    /// Whole-Book into a closed group opens the group and scrolls there.
    func test_aMenuLandingOpensWhatIsAboveItAndScrollsToIt() async throws {
        let store = try await novel(notes: [])
        let world = try await store.addResearchItem(parentId: nil, title: "World", kind: nil)
        let maps = try await store.addResearchTextNote(parentId: world.id, title: "Maps")
        let part = try await store.addStructureItem(parentId: nil, title: "Part", kind: .group)
        let deep = try await store.addStructureItem(parentId: part.id, title: "Deep",
                                                    kind: .document(.markdown))
        let state = state(for: store)
        let verbs = verbs(store)

        verbs.performHome(.link(researchId: maps.id, to: deep.id))
        XCTAssertTrue(state.expandedStructureGroups.contains(part.id), "the Part above opens")
        XCTAssertTrue(state.folds.isOpen(deep.id))
        XCTAssertEqual(state.scrollRequest, .foldRow(researchId: maps.id, piece: deep.id))
        await settle(store) { !store.linkedResearchIds(forDocumentId: deep.id).isEmpty }

        state.scrollRequest = nil
        verbs.performHome(.unlink(researchId: maps.id, from: [deep.id]))
        XCTAssertTrue(state.expandedResearchGroups.contains(world.id), "its own group opens")
        XCTAssertTrue(state.researchSectionExpanded)
        XCTAssertEqual(state.scrollRequest, .row(.research(maps.id)))
        await settle(store) { store.linkedResearchIds(forDocumentId: deep.id).isEmpty }
    }

    /// **A row's drag payload is built when a drag begins, never when the row
    /// is drawn** (the review's unverifiable point (a)). `ResearchRow` hands
    /// `.draggable` an autoclosure that records the drag's fold; were SwiftUI
    /// to evaluate it in the body, every drawn row would record itself and the
    /// last one drawn would be every drag's "source". Mounted here, both a
    /// section row and a fold row drawn: nothing is recorded. What remains
    /// unprovable headless — that a real drag evaluates it once, at its start
    /// — the design no longer depends on alone: a press clears the record
    /// (`pointerWentDown`), a drop clears it, the other rows of a drag read the
    /// fold they were chosen in, and with no record a note in two chapters is
    /// refused (`ambiguousSource`), never unlinked from the wrong one.
    func test_aRowsDragPayloadIsNotBuiltWhenTheRowIsDrawn() async throws {
        let store = try await novel(notes: ["Ships"])
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let tides = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: tides.id, toDocumentId: chapter.id)
        let state = state(for: store)
        state.researchSectionExpanded = true
        let window = TestWindow.mount(AnyView(DragPayloadProbe(store: store, state: state)),
                                      size: CGSize(width: 320, height: 800), as: SilentTestWindow.self)
        windows.append(window)
        _ = await pumpUntil(deadline: 5) { (Self.outline(in: window.contentView)?.numberOfRows ?? 0) > 0 }
        let outline = try XCTUnwrap(Self.outline(in: window.contentView))
        let closed = outline.numberOfRows
        // Premise: opening the chapter's fold adds exactly its one row, Tides.
        state.setFold(chapter.id, open: true)
        let opened = await pumpUntil(deadline: 5) { outline.numberOfRows == closed + 1 }
        XCTAssertTrue(opened, "premise: the fold's row is drawn (\(closed) → \(outline.numberOfRows))")
        // Every row's view built now, synchronously — the fold row's body included.
        for row in 0..<outline.numberOfRows {
            XCTAssertNotNil(outline.view(atColumn: 0, row: row, makeIfNecessary: true), "row \(row)")
        }
        window.displayIfNeeded()
        XCTAssertNil(state.researchDragSource, "drawing a row records no drag")
    }

    private static func outline(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView { return outline }
        for sub in view.subviews { if let found = outline(in: sub) { return found } }
        return nil
    }

    /// **Every link the tree writes goes through one door** (I4): counted per
    /// file, so a new caller that skips the posture fails here.
    func test_theStoresLinkVerbsHaveCountedCallers() throws {
        let verbs = [".linkResearch(", ".unlinkResearch(", ".relinkResearch(", " linkResearch(researchId"]
        var found: [String: Int] = [:]
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            let count = SourceScan.codeLines(of: try SourceTree.read(file)).filter { line in
                !line.contains("func ") && verbs.contains { line.contains($0) }
            }.count
            if count > 0 { found[file] = count }
        }
        XCTAssertEqual(found, [
            // The tree's door: asks the posture, one save.
            "Maugham/Views/BinderTreeSections.swift": 1,
            // "Link Research…", opened only where the posture allows.
            "Maugham/Views/ResearchLinkPickerSheet.swift": 2,
            // A new note in a document's scope (`createResearchAsset`).
            "Maugham/Stores/ResearchScope.swift": 1,
            // The assistant's link tools (its own permission).
            "Maugham/MCP/Tools/ResearchLinkTools.swift": 2,
            // A canvas promotion's link.
            "Maugham/Canvas/PromotionPerformer.swift": 1,
        ])
    }

    // MARK: - A collection: the piece row moves the file

    func test_aNoteDroppedOnALoosePieceMovesIntoThatPiecesFolder() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let piece = try XCTUnwrap(store.manifest.structure.first)
        XCTAssertEqual(note.path, "research/ships.md", "fixture precondition")

        let accepted = verbs(store).routePieceRowDrop(
            draggedId: note.id, documentId: piece.id,
            structureReorder: { XCTFail("a research id is not a piece reorder") })

        XCTAssertTrue(accepted)
        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.hasPrefix("pieces/") == true
        }
        let moved = try XCTUnwrap(research(named: "Ships", in: store))
        XCTAssertEqual(moved.path?.hasPrefix("pieces/"), true,
                       "a Collection piece's research is CONTAINMENT — the file "
                       + "itself moves, and the tree hands that to the typed "
                       + "mover rather than moving anything itself. Got "
                       + "\(moved.path ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.url.appendingPathComponent(moved.path ?? "").path),
            "and the file is where the manifest says it is")
    }

    func test_thePiecesOwnNoteDraggedToTheResearchSectionComesBackOut() async throws {
        let store = try await collection(pieces: ["One"], notes: [])
        let piece = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.createResearchNote(
            scope: .document(piece.id), title: "Ships")

        XCTAssertTrue(verbs(store).routeSharedSectionDrop(draggedId: note.id))

        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.hasPrefix("pieces/") == false
        }
        let moved = try XCTUnwrap(research(named: "Ships", in: store))
        XCTAssertEqual(moved.path?.hasPrefix("pieces/"), false,
                       "the section IS the shared root. Got \(moved.path ?? "nil")")
    }

    /// **A scope move leaves the links alone** — the dormant-link semantics
    /// (`ProjectStore+ResearchMove`), asserted through the drag rather than
    /// through the store, because the drag is the new caller.
    ///
    /// A link on a Collection piece is dormant data: the Collection's own scope
    /// is its folder, so nothing in the app reads it — but it is reachable
    /// (`link_research` over MCP, a project that was another type once), and a
    /// drag that silently deleted it would be destroying something the writer
    /// cannot see and did not point at. Both halves are pinned: the move keeps
    /// the link, and a drop on the shared section reads the piece's scope
    /// rather than the dormant link.
    func test_aDragThatChangesScopeDoesNotSilentlyUnlink() async throws {
        let store = try await collection(pieces: ["One", "Two"], notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let one = try XCTUnwrap(store.manifest.structure.first)
        let two = try XCTUnwrap(store.manifest.structure.last)
        try await store.linkResearch(researchId: note.id, toDocumentId: one.id)

        XCTAssertTrue(verbs(store).routePieceRowDrop(
            draggedId: note.id, documentId: two.id, structureReorder: {}))
        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.contains("/research/") == true
        }

        XCTAssertEqual(store.linkedResearchIds(forDocumentId: one.id), [note.id],
                       "the scope move rewrote the note's path and left every "
                       + "link exactly as it found it")
        let moved = try XCTUnwrap(research(named: "Ships", in: store))
        XCTAssertEqual(moved.path?.contains("/research/"), true,
                       "…and the move did happen. Got \(moved.path ?? "nil")")

        // The second half: with a dormant link present, the shared section is
        // still a SCOPE move and not an unlink.
        XCTAssertTrue(verbs(store).routeSharedSectionDrop(draggedId: note.id))
        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.hasPrefix("pieces/") == false
        }
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: one.id), [note.id],
                       "a Collection piece's routing does not use links, so a "
                       + "link on one must never be what a drop on the shared "
                       + "section answers")
    }

    func test_aReferencedPieceRefusesTheDropRatherThanSwallowingIt() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let reference = try await linkedReferencePiece(in: store)
        let before = store.manifest.research

        let accepted = verbs(store).routePieceRowDrop(
            draggedId: note.id, documentId: reference.id, structureReorder: {})

        XCTAssertFalse(accepted,
                       "a referenced piece keeps its research in its own "
                       + "project — the drag must bounce back to where the "
                       + "writer took it from, not animate home and vanish")
        await settle(store)
        XCTAssertEqual(store.manifest.research, before, "and nothing moved")
    }

    // MARK: - The single-document types have no scope to change

    func test_aScreenplaysScriptRowRefusesAResearchDrop() async throws {
        let store = try await screenplay(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let script = try XCTUnwrap(TreeWalk.first(
            in: store.manifest.structure, where: { $0.type == .document }))

        XCTAssertFalse(
            verbs(store).routePieceRowDrop(
                draggedId: note.id, documentId: script.id, structureReorder: {}),
            "everything in a screenplay's research is already the script's, so "
            + "there is nothing for the drop to change and it says so")
    }

    // MARK: - Ids the tree cannot place

    func test_anIdFromSomewhereElseIsRefusedAtEveryTarget() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let sections = BinderTreeSections(
            store: store, state: BinderTreeSectionsState(),
            subject: .constant(.book))

        XCTAssertFalse(verbs(store).routePieceRowDrop(
            draggedId: "canvas-node-1", documentId: chapter.id,
            structureReorder: { XCTFail("an unknown id is not a reorder") }))
        XCTAssertFalse(sections.actions.internalDrop("canvas-node-1", .middle, note))
        XCTAssertFalse(sections.sharedSectionDrop(["canvas-node-1"]))
    }

    // MARK: - A file from Finder, all the way to the folder (stage-2b Task 4)

    /// **The capability the dying panes carried, on the tree's own targets.**
    ///
    /// These go through `NSItemProvider`s built from real files, so the whole
    /// path is exercised — `DropClassification`'s classification, the store
    /// verb the destination names, and the file that has to end up somewhere a
    /// writer can find. A drop that imports to the wrong scope does not lose a
    /// row: it files the writer's photograph where they never pointed.

    func test_aFileDroppedOnTheResearchSectionLandsInSharedResearch() async throws {
        let store = try await novel(notes: [])
        let file = try makeFile(named: "harbour.md", contents: "# Harbour")

        let accepted = verbs(store).routeExternalDrop(
            providers: [provider(for: file)], position: .middle,
            target: .sharedSection)

        XCTAssertTrue(accepted)
        await settle(store) { self.research(named: "harbour", in: store) != nil }
        let imported = try XCTUnwrap(research(named: "harbour", in: store))
        XCTAssertEqual(imported.path, "research/harbour.md",
                       "the section IS the shared root. Got \(imported.path ?? "nil")")
    }

    func test_aFileDroppedOnANovelChapterIsImportedAndLinkedInOneAct() async throws {
        let store = try await novel(notes: [])
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let file = try makeFile(named: "tides.md", contents: "# Tides")

        XCTAssertTrue(verbs(store).routeExternalDrop(
            providers: [provider(for: file)], position: .middle,
            target: .pieceRow(chapter.id)))

        await settle(store) {
            !store.linkedResearchIds(forDocumentId: chapter.id).isEmpty
        }
        let imported = try XCTUnwrap(research(named: "tides", in: store))
        XCTAssertEqual(imported.path, "research/tides.md",
                       "a novel chapter has no research folder of its own, so "
                       + "the file lands in shared research")
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id),
                       [imported.id],
                       "…and the link is the other half of the same act. "
                       + "Importing without linking leaves the writer's file in "
                       + "the section they did not aim at")
    }

    func test_aFileDroppedOnACollectionPieceLandsInThatPiecesFolder() async throws {
        let store = try await collection(pieces: ["One"], notes: [])
        let piece = try XCTUnwrap(store.manifest.structure.first)
        let file = try makeFile(named: "map.md", contents: "# Map")

        XCTAssertTrue(verbs(store).routeExternalDrop(
            providers: [provider(for: file)], position: .middle,
            target: .pieceRow(piece.id)))

        await settle(store) { self.research(named: "map", in: store) != nil }
        let imported = try XCTUnwrap(research(named: "map", in: store))
        XCTAssertEqual(imported.path?.hasPrefix("pieces/"), true,
                       "a Collection piece's research is containment — this is "
                       + "`importPieceResearchFiles`, whose only caller before "
                       + "this task was the pane the milestone deletes. Got "
                       + "\(imported.path ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.url.appendingPathComponent(imported.path ?? "").path),
            "and the file is where the manifest says it is")
    }

    /// **The fold's external drop carries the fold's own document**, which is
    /// the same re-route its internal drop needed and fails the same silent
    /// way: without it the row reads as an ordinary shared research row and the
    /// writer's file lands in shared research, unlinked, with nothing on screen
    /// to say the chapter never got it.
    func test_aFileDroppedInsideAChaptersFoldReachesThatChapter() async throws {
        let store = try await novel(notes: ["Ships"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        try await store.linkResearch(researchId: ships.id, toDocumentId: chapter.id)
        let file = try makeFile(named: "charts.md", contents: "# Charts")

        let actions = TreeHostFixture.foldView(
            store: store, state: state(for: store),
            subject: .constant(.book),
            documentId: chapter.id, layout: .rows([])).actions
        XCTAssertTrue(actions.externalDrop([provider(for: file)], .bottom, ships))

        await settle(store) {
            store.linkedResearchIds(forDocumentId: chapter.id).count == 2
        }
        let imported = try XCTUnwrap(research(named: "charts", in: store))
        XCTAssertTrue(
            store.linkedResearchIds(forDocumentId: chapter.id).contains(imported.id),
            "a file dropped in chapter one's fold is chapter one's")
    }

    /// The control for the fold: the SAME drop on a row of the shared section,
    /// where there is no document, imports and links nothing.
    func test_control_theSameFileDroppedOnASharedRowLinksNothing() async throws {
        let store = try await novel(notes: ["Ships"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let sections = BinderTreeSections(
            store: store, state: state(for: store), subject: .constant(.book))
        let file = try makeFile(named: "charts.md", contents: "# Charts")

        XCTAssertTrue(sections.actions.externalDrop(
            [provider(for: file)], .bottom, ships))

        await settle(store) { self.research(named: "charts", in: store) != nil }
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id), [],
                       "control: the section's rows carry no document, so the "
                       + "same gesture is a plain import — which is what makes "
                       + "the fold assertion above about the re-route")
    }

    func test_aFileDroppedIntoAGroupRowLandsInsideThatGroup() async throws {
        let store = try await novel(notes: [])
        let group = try await store.addResearchItem(
            parentId: nil, title: "World", kind: nil)
        let sections = BinderTreeSections(
            store: store, state: state(for: store), subject: .constant(.book))
        let file = try makeFile(named: "maps.md", contents: "# Maps")

        XCTAssertTrue(sections.actions.externalDrop(
            [provider(for: file)], .middle, group))

        await settle(store) { self.research(named: "maps", in: store) != nil }
        let imported = try XCTUnwrap(research(named: "maps", in: store))
        XCTAssertEqual(imported.path, "research/world/maps.md",
                       "dropped ON a group is INTO it — the same gesture that "
                       + "moves a note into one. Got \(imported.path ?? "nil")")
    }

    func test_aScreenplaysScriptRowBouncesAFileAndImportsNothing() async throws {
        let store = try await screenplay(notes: [])
        let script = try XCTUnwrap(TreeWalk.first(
            in: store.manifest.structure, where: { $0.type == .document }))
        let file = try makeFile(named: "notes.md", contents: "# Notes")
        let before = store.manifest.research

        XCTAssertFalse(
            verbs(store).routeExternalDrop(
                providers: [provider(for: file)], position: .middle,
                target: .pieceRow(script.id)),
            "everything in a screenplay's research is already the script's, so "
            + "there is no scope the drop is asking for — and a refusal the "
            + "writer can see beats a file quietly appearing elsewhere")
        await settle(store)
        XCTAssertEqual(store.manifest.research, before, "and nothing imported")
    }

    // MARK: - ⌘V (stage-2b Task 4)

    /// The paste table `ResearchView` owned, on its new host. A pasted URL is a
    /// research link; a pasted image or file is an asset; pasted text is a
    /// note. All in shared research, which is what the pane did.
    func test_aPastedURLBecomesALinkInSharedResearch() async throws {
        let store = try await novel(notes: [])
        let importer = ResearchPasteImporter(store: store, reportError: { _ in })

        await importer.paste([NSItemProvider(
            object: URL(string: "https://example.com/tides")! as NSURL)])

        // The provider answers `loadItem` with the URL's BYTES rather than a
        // `URL` — measured, and the reason the moved table needed its one
        // change: `ResearchView` cast to `URL` alone, so this paste fell
        // through every arm and did nothing, silently. See
        // `ResearchPasteImporter.url(from:)`.
        let link = try XCTUnwrap(
            store.manifest.research.first { $0.kind == .link },
            "a pasted URL is a link, titled by its host")
        XCTAssertEqual(link.url, "https://example.com/tides")
        XCTAssertEqual(link.title, "example.com")
    }

    func test_pastedTextBecomesANoteInSharedResearch() async throws {
        let store = try await novel(notes: [])
        let importer = ResearchPasteImporter(store: store, reportError: { _ in })
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: "public.text", visibility: .all) { completion in
                completion(Data("The tide was out.".utf8), nil)
                return nil
            }

        await importer.paste([provider])

        let note = try XCTUnwrap(
            store.manifest.research.first { $0.role == nil && $0.kind == .document },
            "pasted text lands as a research document")
        let path = try XCTUnwrap(note.path)
        XCTAssertEqual(
            try String(contentsOf: store.url.appendingPathComponent(path),
                       encoding: .utf8),
            "The tide was out.",
            "…carrying the words that were pasted")
    }

    /// **Which window states a paste belongs to research at all.** The tree is
    /// one `List` holding manuscript rows as well as research ones, so a ⌘V
    /// with a chapter selected is not research's to take.
    func test_aPasteBelongsToResearchOnlyWhenTheWindowIsAboutResearchOrTheProject() {
        XCTAssertTrue(TreePasteRouting.acceptsPaste(subject: .research("res-1")))
        XCTAssertTrue(TreePasteRouting.acceptsPaste(subject: .project))
        XCTAssertFalse(TreePasteRouting.acceptsPaste(subject: .item("ch1")),
                       "a chapter is selected: the writer's ⌘V is about the "
                       + "manuscript, and a research note appearing instead is "
                       + "a surprise the old pane could never have produced")
        XCTAssertFalse(TreePasteRouting.acceptsPaste(subject: nil))
    }

    // MARK: - Add File… (stage-2b Task 4)

    /// **The panel takes folders again.** `ResearchView`'s always has —
    /// `importResearchFiles` imports a folder as a group with its contents
    /// under it — and stage 2a's tree narrowed it to files without saying so.
    /// The pane is about to be deleted, so the narrowing would have shipped as
    /// a lost capability.
    ///
    /// Asserts the CONFIGURATION as a value rather than allocating a real
    /// `NSOpenPanel` — the panel used to be constructed here, and under
    /// parallel-worker/window-server contention its XPC service could stall
    /// ~64s and blow the test's allowance (six sightings 2026-08-16..19,
    /// isolation-clean). `AddFilePanelConfiguration` is what production
    /// applies to the real panel; nothing in this suite touches AppKit.
    func test_theTreesAddFilePanelTakesFoldersAsWellAsFiles() {
        let configuration = BinderTreeVerbs.addFilePanelConfiguration
        XCTAssertTrue(configuration.canChooseDirectories,
                      "a folder imports as a group of its contents — the tree "
                      + "is the only surface left that can ask for one")
        XCTAssertTrue(configuration.canChooseFiles)
        XCTAssertTrue(configuration.allowsMultipleSelection)
    }

    // MARK: - The subject survives its own rescope

    /// **The window keeps pointing at the note the writer just moved**
    /// (Task 2's fingerprint blindness, through the drop path).
    ///
    /// A scope move rewrites the item's path and — in a Collection — takes it
    /// out of the tree's Research section and into the piece's fold, which is
    /// exactly the kind of manifest change that a subject sweep watching the
    /// wrong thing would read as "the subject is gone". It is not gone: it is
    /// the same id, one folder over, and the writer is still looking at it.
    ///
    /// Mounted, because the sweep runs on the window and not on the store. The
    /// drag itself is not synthesisable, so the drop is driven through the
    /// production verb while the tree is on screen.
    func test_theSubjectSurvivesItsOwnRescope() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let piece = try XCTUnwrap(store.manifest.structure.first)
        let probe = BinderSubjectProbe(.research(note.id))
        _ = try await mountCollection(store: store, probe: probe)

        XCTAssertTrue(verbs(store).routePieceRowDrop(
            draggedId: note.id, documentId: piece.id, structureReorder: {}))
        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.hasPrefix("pieces/") == true
        }
        pump(0.3)

        XCTAssertEqual(probe.subject, .research(note.id),
                       "the note moved scope; it did not stop existing, and the "
                       + "window must still be about it")
        let moved = try XCTUnwrap(research(named: "Ships", in: store))
        XCTAssertEqual(moved.path?.hasPrefix("pieces/"), true,
                       "precondition for the assertion above: the move DID "
                       + "happen. Got \(moved.path ?? "nil")")
    }

    /// The control, and the test above says nothing without it: the sweep it
    /// survives has to be a sweep that WOULD have fired. Delete the same note
    /// under the same mounted tree and the window stops being about it.
    func test_control_theSweepStillClearsASubjectThatReallyWentAway() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let probe = BinderSubjectProbe(.research(note.id))
        _ = try await mountCollection(store: store, probe: probe)

        try await store.deleteResearchItem(id: note.id)
        _ = await pumpUntil(deadline: 5) { probe.subject != .research(note.id) }

        XCTAssertNotEqual(probe.subject, .research(note.id),
                          "control: the sweep is live under this mount, so the "
                          + "survival above is about the rescope and not about "
                          + "a sweep that never ran")
    }

    // MARK: - The Research section header's one provider drop (#109)

    /// **A Finder file dropped on the Research HEADER lands in shared
    /// research.** #109: the header mounted a String destination in front of its
    /// file drop, AppKit offered the drag to that one alone, and a Finder PNG
    /// sprang back. The header now takes every drag through one provider
    /// `.onDrop` routed by `ProviderDropRoute`; this is that route, asked with
    /// the type list a real file provider registers.
    func test_aFileDroppedOnTheResearchHeaderLandsInSharedResearch() async throws {
        let store = try await novel(notes: [])
        let file = try makeFile(named: "harbour.md", contents: "# Harbour")
        let item = provider(for: file)

        let accepted = sections(store).sharedSectionHeaderDrop(
            typeIdentifiers: item.registeredTypeIdentifiers, providers: [item],
            draggedId: {
                XCTFail("a file drag is routed by its type, never by a dragged id")
                return nil
            })

        XCTAssertTrue(accepted)
        await settle(store) { self.research(named: "harbour", in: store) != nil }
        XCTAssertEqual(research(named: "harbour", in: store)?.path, "research/harbour.md",
                       "the header is the shared section, so the file lands at its root")
    }

    /// **A note dragged onto the header leaves its chapter's fold**, by the id
    /// read off the drag pasteboard: the same answer `sharedSectionDrop` gives.
    func test_aLinkedNoteDroppedOnTheResearchHeaderLeavesTheChapter() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let accepted = sections(store).sharedSectionHeaderDrop(
            typeIdentifiers: ["public.utf8-plain-text"], providers: [],
            draggedId: { note.id })

        XCTAssertTrue(accepted)
        await settle(store) { store.linkedResearchIds(forDocumentId: chapter.id).isEmpty }
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id), [])
    }

    /// The id route refuses what `sharedSectionDrop` refuses, and refuses when
    /// no id can be read at all — a refusal is what springs the drag back.
    func test_theResearchHeaderRefusesAnIdTheSectionRefusesAndAMissingOne() async throws {
        let store = try await novel(notes: [])
        let header = sections(store)
        let text = ["public.utf8-plain-text"]

        XCTAssertFalse(header.sharedSectionDrop(["canvas-node-1"]),
                       "control: the section itself refuses an id from elsewhere")
        XCTAssertFalse(header.sharedSectionHeaderDrop(
            typeIdentifiers: text, providers: [], draggedId: { "canvas-node-1" }),
            "the header gives the section's answer, not one of its own")
        XCTAssertFalse(header.sharedSectionHeaderDrop(
            typeIdentifiers: text, providers: [], draggedId: { nil }),
            "a text drag whose id cannot be read is refused, never accepted blind")
    }

    /// A type the route does not know is refused without asking for an id.
    func test_theResearchHeaderRefusesATypeItCannotTake() async throws {
        let store = try await novel(notes: [])
        XCTAssertFalse(sections(store).sharedSectionHeaderDrop(
            typeIdentifiers: ["com.adobe.pdf"], providers: [],
            draggedId: {
                XCTFail("a refused type never reaches the id route")
                return nil
            }))
    }

    /// `draggedId(on:)` reads `.draggable(String)`'s text, trimmed, and gives
    /// nil for a blank or missing string.
    func test_theDraggedIdIsTheTrimmedStringOnThePasteboard() {
        let board = NSPasteboard(name: NSPasteboard.Name("maugham-test-drag-\(UUID().uuidString)"))
        pasteboard = board

        board.clearContents()
        XCTAssertNil(BinderTreeSections.draggedId(on: board), "no string: no id")

        board.clearContents()
        board.setString("note-123", forType: .string)
        XCTAssertEqual(BinderTreeSections.draggedId(on: board), "note-123")

        board.clearContents()
        board.setString("  note-123\n", forType: .string)
        XCTAssertEqual(BinderTreeSections.draggedId(on: board), "note-123",
                       "surrounding whitespace is trimmed")

        board.clearContents()
        board.setString("   ", forType: .string)
        XCTAssertNil(BinderTreeSections.draggedId(on: board), "a blank string is no id")

        board.clearContents()
        board.setString("", forType: .string)
        XCTAssertNil(BinderTreeSections.draggedId(on: board), "an empty string is no id")
    }

    // MARK: - Fixtures

    /// The verbs as a row holds them, over ONE state object per test — so a
    /// store refusal (`pendingError`) is visible to `settle` instead of being
    /// a mystery about why nothing happened.
    private func verbs(_ store: ProjectStore) -> BinderTreeVerbs {
        BinderTreeVerbs(store: store, state: state(for: store),
                        subject: .constant(.book))
    }

    /// The section over the same state, so `settle` sees a store refusal.
    private func sections(_ store: ProjectStore) -> BinderTreeSections {
        BinderTreeSections(store: store, state: state(for: store),
                           subject: .constant(.book))
    }

    private func state(for store: ProjectStore) -> BinderTreeSectionsState {
        if let existing = states[ObjectIdentifier(store)] { return existing }
        let fresh = BinderTreeSectionsState()
        states[ObjectIdentifier(store)] = fresh
        return fresh
    }

    /// The drop verbs hand their work to a detached `Task`, exactly as every
    /// other verb in the tree does. Waits for what the caller is about to
    /// assert, then fails loudly if the store refused — the alert the writer
    /// would have seen is the same channel.
    private func settle(_ store: ProjectStore,
                        until condition: @escaping () -> Bool = { true }) async {
        _ = await pumpUntil(deadline: 5) {
            self.states[ObjectIdentifier(store)]?.pendingError != nil || condition()
        }
        pump(0.1)
        XCTAssertNil(states[ObjectIdentifier(store)]?.pendingError,
                     "the store refused the drop the tree accepted")
    }

    private func novel(notes: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url), notes: notes)
    }

    private func collection(pieces: [String], notes: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let furnished = try await furnish(store, notes: notes)
        for title in pieces { _ = try await furnished.addLoosePiece(title: title, format: .markdown) }
        return furnished
    }

    private func screenplay(notes: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "Screenplay-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url), notes: notes)
    }

    private func furnish(_ store: ProjectStore, notes: [String]) async throws -> ProjectStore {
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        for title in notes {
            _ = try await store.addResearchTextNote(parentId: nil, title: title)
        }
        await store.wordCountPopulationTask?.value
        return store
    }

    /// A referenced piece: a second project on disk, linked into the
    /// Collection. Its research lives in that project, which is why the tree
    /// refuses to move anything into it.
    private func linkedReferencePiece(in store: ProjectStore) async throws -> StructureItem {
        let other = try await ProjectFactory.createShortStoryProject(
            named: "Elsewhere-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await store.addProjectReference(targetURL: other)
    }

    /// A real file on disk for an external drop to carry. Written under the
    /// test's own temp directory, so nothing here touches the writer's Finder.
    private func makeFile(named name: String, contents: String) throws -> URL {
        let dir = temp.url.appendingPathComponent("dropped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A Finder drag's payload. `NSURL` registers `public.file-url`, which is
    /// the identifier `DropClassification` classifies on — so these tests go
    /// through the real classification rather than around it. (A browser drag
    /// carries a rendered bitmap instead and falls to the same classifier's
    /// `.image` arm; the file arm is the one the tree's routing turns on.)
    private func provider(for url: URL) -> NSItemProvider {
        NSItemProvider(object: url as NSURL)
    }

    private func research(named title: String, in store: ProjectStore) -> ResearchItem? {
        TreeWalk.first(in: store.manifest.research, where: { $0.title == title })
    }

    private func mountCollection(
        store: ProjectStore, probe: BinderSubjectProbe
    ) async throws -> NSWindow {
        let window = TestWindow.mount(
            AnyView(DropRoutingProbeView(store: store, probe: probe)),
            size: CGSize(width: 320, height: 800), as: SilentTestWindow.self)
        windows.append(window)
        pump(0.3)
        return window
    }
}

/// The Collection tree with its subject bound to a probe, and the window's own
/// subject sweep attached — the sweep is what a rescope has to survive.
@MainActor
private struct DropRoutingProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    @State private var renaming: String?
    let treeState = BinderTreeSectionsState()

    var body: some View {
        TreeHostFixture.collection(
            store: store,
            subject: .tree(Binding(get: { probe.subject },
                                     set: { probe.subject = $0 })),
            renamingItemId: $renaming,
            treeState: treeState)
            .modifier(SubjectValidationModifier(
                store: store, documentStore: nil,
                subject: .bridging(Binding(get: { probe.subject },
                                           set: { probe.subject = $0 }))))
    }
}

/// The binder as the window mounts it, over a given tree state.
@MainActor
private struct DragPayloadProbe: View {
    let store: ProjectStore
    let state: BinderTreeSectionsState
    @State private var subject = WindowSubject.book

    var body: some View {
        TreeHostFixture.binder(store: store, subject: $subject, treeState: state)
    }
}
