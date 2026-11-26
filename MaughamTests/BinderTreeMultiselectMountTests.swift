import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Multiselect on the delivery path** (shell-finish stage-2b Task 3; re-made
/// in shell p4 Task 11).
///
/// `BinderTreeMultiselectTests` asks the rules over their whole input; this
/// file holds what only a mounted tree can say, read without waiting: that each
/// host's table takes a second row at all, that the tree-travel watcher's
/// "is this the one selected row" question is AppKit's, and the batch drag and
/// reorder routes over a selection the tree records. The select-then-wait
/// tests that drove `selectRowIndexes` and waited for SwiftUI's write-back are
/// culled (tripwire 33's shape; red once in a full gate with nothing wrong).
///
/// **The context menu itself is not readable from a mounted SwiftUI row** (the
/// measurement `BinderProjectRowTests` records), so "Delete 2 Items" is
/// asserted where the menu is BUILT from, `ResearchTreeActions.selectionForRow`,
/// in `BinderTreeMultiselectTests`.
@MainActor
final class BinderTreeMultiselectMountTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []
    private var state = BinderTreeSectionsState()

    override func setUp() async throws {
        temp = TempDirectory()
        state = BinderTreeSectionsState()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - Each tree takes a second row

    /// **What is left of the mounted half, and why** (shell p4 Task 11). This
    /// file used to select rows through the mounted table and then WAIT for
    /// SwiftUI's write-back (`selectRowIndexes`, then `pumpUntil` or a fixed
    /// `waitOut(0.4)`) — the select-then-wait shape tripwire 33 bans, which
    /// went red once in a full gate (0.41 s) with nothing wrong in the app.
    /// Those tests are culled. What they guarded stays pinned without a wait:
    /// the rules — two ⌘-clicks keep the window's subject, the acting set is
    /// `selectionForRow`'s in tree order, a row outside the set acts alone —
    /// by `BinderTreeMultiselectTests` over plain values; the structural half
    /// here, read synchronously off each host as mounted: SwiftUI sets
    /// `allowsMultipleSelection` from the selection's TYPE, so a host whose
    /// binding went single-valued refuses the second row outright.
    func test_everyTreeTakesASecondRow() async throws {
        let novel = try await novel(notes: ["Ships", "Tides"])
        let collection = try await collection(pieces: ["One"], notes: ["Ships", "Tides"])
        let screenplay = try await screenplay(notes: ["Ships", "Tides"])
        let hosts: [(String, NSWindow)] = [
            ("sections", try await hostSections(store: novel).0),
            ("novel", try await hostBinder(store: novel).0),
            ("collection", try await hostCollection(store: collection).0),
            ("screenplay", try await hostNavigator(store: screenplay).0),
        ]
        for (name, window) in hosts {
            let table = try XCTUnwrap(firstTableView(in: window), "\(name): no table mounted")
            XCTAssertTrue(table.allowsMultipleSelection,
                          "\(name): this tree's List selects a single value, so a "
                          + "second ⌘-click is thrown away")
        }
    }

    /// **The tree-travel watcher hears a click only on the ONE selected row**
    /// (fix round M2): with two rows selected a click on one collapses the
    /// set, which the `List` writes, so the watcher must not answer it too.
    /// `TreeTravel.rowIsSelected(holding:)` is AppKit's question alone — asked
    /// here of a plain table whose selection AppKit sets synchronously, with
    /// no SwiftUI write-back to wait for.
    func test_aRowCountsAsSelectedOnlyWhenItIsTheOneSelectedRow() throws {
        let rows = PlainRows(count: 3)
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.allowsMultipleSelection = true
        table.dataSource = rows
        table.delegate = rows
        let window = TestWindow.make(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120),
                                     present: .unshown)
        windows.append(window)
        window.contentView = table
        table.reloadData()
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let mark = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        cell.addSubview(mark)

        table.selectRowIndexes([1], byExtendingSelection: false)
        XCTAssertFalse(TreeTravel.rowIsSelected(holding: mark), "another row is the selected one")
        table.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertTrue(TreeTravel.rowIsSelected(holding: mark),
                      "one row selected: a click on it is the watcher's to hear")
        table.selectRowIndexes([0, 1], byExtendingSelection: false)
        XCTAssertFalse(TreeTravel.rowIsSelected(holding: mark),
                       "two rows selected: a click on one collapses the set, which the "
                       + "`List` writes — the watcher must not answer it too")
    }

    // MARK: - The batch verbs over the tree's selection

    /// Two notes in the tree's selection (recorded as the mounted `List`
    /// records it): the acting set the menu is built from is both, in tree
    /// order, and the batch verb removes both — the store's work awaited, no
    /// control pressed. A row outside the set acts alone.
    func test_theBatchVerbsActOnTheTreesSelection() async throws {
        let store = try await novel(notes: ["Ships", "Tides", "Moon"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let tides = try XCTUnwrap(research(named: "Tides", in: store))
        let moon = try XCTUnwrap(research(named: "Moon", in: store))
        state.record(selection: [.research(ships.id), .research(tides.id)],
                     subject: WindowSubject(open: .project, faces: .project,
                                            beside: .research(ships.id)))
        let actions = verbs(store, subject: .research(ships.id)).bundle

        XCTAssertEqual(actions.selectionForRow(tides.id), [ships.id, tides.id],
                       "the acting set is both notes in tree order — the value "
                       + "`ResearchTreeNode` titles \"Delete 2 Items\" from")
        XCTAssertEqual(actions.selectionForRow(moon.id), [moon.id],
                       "a right-click on an unselected row is about that row")

        actions.deleteMany([ships.id, tides.id])
        await settle(store) {
            store.manifest.research.allSatisfy { $0.title != "Ships" && $0.title != "Tides" }
        }
        XCTAssertNil(research(named: "Ships", in: store), "…and it works")
        XCTAssertNil(research(named: "Tides", in: store))
        XCTAssertNotNil(research(named: "Moon", in: store))
    }

    // MARK: - A batch DRAG

    /// **"Drag-multi into a piece rescopes both."** A real drag session is not
    /// synthesisable headless (`BinderTreeDrops`' own note), so this drives the
    /// route the row's `.dropDestination` calls, over a selection recorded as
    /// a mounted tree records it (`BinderTreeSectionsState.record`).
    func test_twoSelectedNotesDraggedOntoAPieceBothMoveIntoIt() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships", "Tides"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let tides = try XCTUnwrap(research(named: "Tides", in: store))
        let piece = try XCTUnwrap(store.manifest.structure.first)
        state.record(selection: [.research(ships.id), .research(tides.id)],
                     subject: WindowSubject(open: .project, faces: .project,
                                            beside: .research(ships.id)))

        let accepted = verbs(store, subject: .research(ships.id)).routePieceRowDrop(
            draggedId: ships.id, documentId: piece.id,
            structureReorder: { XCTFail("a research id is not a piece reorder") })

        XCTAssertTrue(accepted)
        await settle(store) {
            self.research(named: "Tides", in: store)?.path?.hasPrefix("pieces/") == true
        }
        for title in ["Ships", "Tides"] {
            let moved = try XCTUnwrap(research(named: title, in: store))
            XCTAssertEqual(moved.path?.hasPrefix("pieces/"), true,
                           "\(title) was in the selection the writer dragged — "
                           + "moving only the row under the cursor is the same "
                           + "defect as a menu verb acting on one of three. Got "
                           + "\(moved.path ?? "nil")")
        }
    }

    /// The control for the test above: with only the dragged note selected,
    /// exactly one note moves. Without it, "both moved" could pass on a route
    /// that moves everything it can find.
    func test_control_oneSelectedNoteDraggedOntoAPieceMovesOnlyItself() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships", "Tides"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let piece = try XCTUnwrap(store.manifest.structure.first)
        state.record(selection: [.research(ships.id)],
                     subject: WindowSubject(open: .project, faces: .project,
                                            beside: .research(ships.id)))

        XCTAssertTrue(verbs(store, subject: .research(ships.id)).routePieceRowDrop(
            draggedId: ships.id, documentId: piece.id, structureReorder: {}))

        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.hasPrefix("pieces/") == true
        }
        let stayed = try XCTUnwrap(research(named: "Tides", in: store))
        XCTAssertEqual(stayed.path?.hasPrefix("pieces/"), false,
                       "a note nobody selected and nobody dragged must not move")
    }

    /// **A mixed selection is not a batch.** The manuscript has no plural verbs,
    /// so a set holding a chapter degrades the drag to the row it started on
    /// rather than dragging the chapter's file anywhere.
    func test_aSelectionHoldingAPieceDragsOnlyTheRowItStartedOn() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships", "Tides"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let piece = try XCTUnwrap(store.manifest.structure.first)
        state.record(selection: [.research(ships.id), .research(
            try XCTUnwrap(research(named: "Tides", in: store)).id), .item(piece.id)],
                     subject: WindowSubject(open: .project, faces: .project,
                                            beside: .research(ships.id)))

        XCTAssertTrue(verbs(store, subject: .research(ships.id)).routePieceRowDrop(
            draggedId: ships.id, documentId: piece.id, structureReorder: {}))

        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.hasPrefix("pieces/") == true
        }
        let stayed = try XCTUnwrap(research(named: "Tides", in: store))
        XCTAssertEqual(stayed.path?.hasPrefix("pieces/"), false,
                       "the selection was not homogeneous research, so it was "
                       + "not a batch")
    }

    /// A row the batch would mean something ELSE for is left out rather than
    /// dragged along: Tides already lives in the piece, so the drop that moves
    /// Ships in classifies as `.alreadyThere` for Tides — and a mover asked to
    /// move it anyway would rewrite a file for no reason and could throw the
    /// whole validate-first batch away with it.
    func test_aRowAlreadyInTheDestinationIsLeftOutOfTheBatch() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"])
        let piece = try XCTUnwrap(store.manifest.structure.first)
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let inside = try await store.createResearchNote(
            scope: .document(piece.id), title: "Tides")
        state.record(selection: [.research(ships.id), .research(inside.id)],
                     subject: WindowSubject(open: .project, faces: .project,
                                            beside: .research(ships.id)))

        XCTAssertTrue(verbs(store, subject: .research(ships.id)).routePieceRowDrop(
            draggedId: ships.id, documentId: piece.id, structureReorder: {}))

        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.hasPrefix("pieces/") == true
        }
        XCTAssertNil(state.pendingError,
                     "the batch must not carry a row the classifier said had "
                     + "nothing to do — `moveResearchItems` validates the whole "
                     + "batch first, so one bad id moves nothing at all")
    }

    /// **A batch REORDER, and the case that makes it delicate.** The plural
    /// mover takes a destination rather than a parent id, and the destination
    /// for a piece's own research is `.piece` — spelling it as "no parent, so
    /// the shared root" would carry the writer's files out of the piece on a
    /// gesture that was only meant to change their order.
    func test_twoNotesReorderedInsideAPiecesFoldStayInsideThePiece() async throws {
        let store = try await collection(pieces: ["One"], notes: [])
        let piece = try XCTUnwrap(store.manifest.structure.first)
        let a = try await store.createResearchNote(scope: .document(piece.id), title: "A")
        let b = try await store.createResearchNote(scope: .document(piece.id), title: "B")
        let c = try await store.createResearchNote(scope: .document(piece.id), title: "C")
        state.record(selection: [.research(a.id), .research(b.id)],
                     subject: WindowSubject(open: .project, faces: .project,
                                            beside: .research(a.id)))

        XCTAssertTrue(verbs(store, subject: .research(a.id)).routeResearchRowDrop(
            draggedId: a.id, position: .bottom,
            target: try XCTUnwrap(research(named: "C", in: store)),
            inFoldOf: piece.id))

        let ids = [a.id, b.id, c.id]
        await settle(store) {
            store.manifest.research.filter { ids.contains($0.id) }
                .map(\.title) == ["C", "A", "B"]
        }
        for title in ["A", "B", "C"] {
            let item = try XCTUnwrap(research(named: title, in: store))
            XCTAssertEqual(item.path?.hasPrefix("pieces/"), true,
                           "\(title) must still live in the piece — a reorder is "
                           + "not a scope change. Got \(item.path ?? "nil")")
        }
        let order = store.manifest.research
            .filter { [a.id, b.id, c.id].contains($0.id) }.map(\.title)
        XCTAssertEqual(order, ["C", "A", "B"],
                       "both selected notes moved below C, in tree order")
    }

    // MARK: - Fixtures

    private func novel(notes: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url), notes: notes)
    }

    private func collection(pieces: [String], notes: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await furnish(try await ProjectStore.load(from: url), notes: notes)
        for title in pieces { _ = try await store.addLoosePiece(title: title, format: .markdown) }
        return store
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

    private func research(named title: String, in store: ProjectStore) -> ResearchItem? {
        TreeWalk.first(in: store.manifest.research, where: { $0.title == title })
    }

    private func verbs(_ store: ProjectStore, subject: BinderSubject?) -> BinderTreeVerbs {
        let box = BinderSubjectProbe(subject)
        return BinderTreeVerbs(store: store, state: state,
                               subject: .tree(probeBinding(box)))
    }

    private func probeBinding(_ probe: BinderSubjectProbe) -> Binding<BinderSubject?> {
        Binding(get: { probe.subject }, set: { probe.subject = $0 })
    }

    /// Waits for the store mutation a drop kicked off, and fails loudly if the
    /// store refused what the tree accepted (`BinderTreeDropRoutingTests`' shape).
    private func settle(_ store: ProjectStore, until condition: @escaping () -> Bool) async {
        _ = await pumpUntil(deadline: 5) {
            self.state.pendingError != nil || condition()
        }
        pump(0.1)
        XCTAssertNil(state.pendingError,
                     "the store refused the drop the tree accepted")
    }

    // MARK: - Hosting and driving

    private func hostSections(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(SectionsOnlyProbeView(
            store: store, probe: probe, state: state)))
        return (window, probe)
    }

    private func hostBinder(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            MultiselectBinderProbeView(store: store, probe: probe)))
        return (window, probe)
    }

    private func hostCollection(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            MultiselectCollectionProbeView(store: store, probe: probe)))
        return (window, probe)
    }

    private func hostNavigator(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let documentID = TreeWalk.first(
            in: store.manifest.structure, where: { $0.type == .document })?.id
        let window = try await mount(AnyView(MultiselectNavigatorProbeView(
            store: store, probe: probe, documentID: documentID)))
        return (window, probe)
    }

    private func mount(_ root: AnyView) async throws -> NSWindow {
        let window = TestWindow.mount(root, size: CGSize(width: 320, height: 800),
                                      as: SilentTestWindow.self)
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        // The palette section loads its cards from disk once per manifest
        // change, so its rows arrive a turn after the table does.
        pump(0.2)
        return window
    }

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.first
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}

// MARK: - Probes

/// A host reduced to the two touchpoints a host has: the sections' rows inside
/// one `List` bound the way production binds it, and the presentations outside
/// it. The state is the TEST's, which is the only reason the acting set is
/// readable at all — the three real hosts take one from the window (stage-3a
/// Task 4), and the tests that mount a whole host read the table instead.
/// A plain AppKit table of `count` empty rows.
@MainActor
private final class PlainRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let count: Int
    init(count: Int) { self.count = count }
    func numberOfRows(in tableView: NSTableView) -> Int { count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
    }
}

@MainActor
private struct SectionsOnlyProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let state: BinderTreeSectionsState

    var body: some View {
        let subject = Binding<WindowSubject>.tree(
            Binding(get: { probe.subject }, set: { probe.subject = $0 }))
        List(selection: BinderTreeSelection.binding(
                subject: subject, state: state, store: store)) {
            BinderTreeSections(store: store, state: state, subject: subject)
        }
        .listStyle(.sidebar)
        .binderTreeSections(store: store, state: state, subject: subject)
    }
}

@MainActor
private struct MultiselectBinderProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe

    let treeState = BinderTreeSectionsState()

    var body: some View {
        TreeHostFixture.binder(store: store,
                   subject: .tree(Binding(get: { probe.subject },
                                            set: { probe.subject = $0 })),
                   treeState: treeState)
    }
}

@MainActor
private struct MultiselectCollectionProbeView: View {
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
    }
}

@MainActor
private struct MultiselectNavigatorProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let documentID: String?
    let treeState = BinderTreeSectionsState()

    var body: some View {
        TreeHostFixture.scenes(
            store: store,
            script: FountainTokenizer().parse("INT. KITCHEN - DAY\n\nLarry sits.\n"),
            subject: .tree(Binding(get: { probe.subject },
                                     set: { probe.subject = $0 })),
            treeState: treeState,
            onSelect: { _ in })
    }
}
