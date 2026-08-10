import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Multiselect on the delivery path** (shell-finish stage-2b Task 3).
///
/// `BinderTreeMultiselectTests` asks the rules over their whole input; this
/// drives the real `NSTableView` SwiftUI mounted, because the rules being right
/// says nothing about whether the `List` is wired to them — M1A's lesson was 22
/// green undo tests sitting on a ⌘Z that could not reach the stack. What is
/// asserted here is what a writer does: pick one note, ⌘-click a second, and
/// find the verbs acting on both while the editor stays where it was.
///
/// **The context menu itself is not readable from a mounted SwiftUI row** (the
/// measurement `BinderProjectRowTests` records: a row's subtree carries no
/// `NSTextField` and no accessibility tree in this host). So "Delete 2 Items
/// appears" is asserted at the value the menu is BUILT from —
/// `ResearchTreeActions.selectionForRow`, whose count is literally what
/// `ResearchTreeNode` titles the item with — and "and works" by running the verb
/// the item calls and reading the manifest afterwards.
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

    // MARK: - Two notes, one tree

    /// The whole task in one test: two rows selected through the real table, the
    /// acting set the batch verbs are built from, and the batch verb doing what
    /// it says.
    func test_twoNotesSelectedInTheTreeAreWhatTheBatchVerbsActOn() async throws {
        let store = try await novel(notes: ["Ships", "Tides"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let tides = try XCTUnwrap(research(named: "Tides", in: store))
        let (window, probe) = try await hostSections(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        let shipsRow = try await rowIndex(of: .research(ships.id), in: table, probe: probe)
        let tidesRow = try await rowIndex(of: .research(tides.id), in: table, probe: probe)

        XCTAssertTrue(table.allowsMultipleSelection,
                      "a `Set` selection is what makes the table take a second "
                      + "⌘-click at all — without it every rule below is unreachable")

        await select(rows: [shipsRow], in: table,
                     until: { probe.subject == .research(ships.id) })
        await select(rows: [shipsRow, tidesRow], in: table,
                     until: { self.state.selection.count == 2 })

        XCTAssertEqual(state.selection,
                       [.research(ships.id), .research(tides.id)],
                       "both rows are in the tree's selection")
        XCTAssertEqual(probe.subject, .research(ships.id),
                       "and the window is still about the note the writer had "
                       + "open — a second ⌘-click adds a row, it does not move "
                       + "the editor")

        let actions = BinderTreeVerbs(store: store, state: state,
                                      selectedSubject: probeBinding(probe)).bundle
        XCTAssertEqual(actions.selectionForRow(tides.id), [ships.id, tides.id],
                       "the acting set is both notes in tree order — this is the "
                       + "value `ResearchTreeNode` titles \"Delete 2 Items\" from "
                       + "and hands to `Move to ▸`")

        actions.deleteMany([ships.id, tides.id])
        await pumpUntil(deadline: 5) {
            store.manifest.research.allSatisfy { $0.title != "Ships" && $0.title != "Tides" }
        }
        XCTAssertNil(research(named: "Ships", in: store), "…and it works")
        XCTAssertNil(research(named: "Tides", in: store))
        XCTAssertNil(state.pendingError,
                     "the store refused the batch the tree offered")
    }

    /// The other half of the acting set: a row the writer right-clicked WITHOUT
    /// selecting acts alone, even with two rows highlighted. Standard Mac
    /// behaviour, and the reason `selectionForRow` takes the row at all.
    func test_aRowOutsideTheSelectionStillActsAlone() async throws {
        let store = try await novel(notes: ["Ships", "Tides", "Moon"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let tides = try XCTUnwrap(research(named: "Tides", in: store))
        let moon = try XCTUnwrap(research(named: "Moon", in: store))
        let (window, probe) = try await hostSections(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))
        let shipsRow = try await rowIndex(of: .research(ships.id), in: table, probe: probe)
        let tidesRow = try await rowIndex(of: .research(tides.id), in: table, probe: probe)

        await select(rows: [shipsRow, tidesRow], in: table,
                     until: { self.state.selection.count == 2 })

        let actions = BinderTreeVerbs(store: store, state: state,
                                      selectedSubject: probeBinding(probe)).bundle
        XCTAssertEqual(actions.selectionForRow(moon.id), [moon.id],
                       "a right-click on an unselected row is about that row")
    }

    // MARK: - Each host takes a second row

    func test_theNovelTreeHoldsTwoRowsAndKeepsItsAnchor() async throws {
        let store = try await novel(notes: ["Ships", "Tides"])
        try await assertHoldsTwoResearchRows(
            store: store, mount: { try await self.hostBinder(store: store) })
    }

    func test_theCollectionTreeHoldsTwoRowsAndKeepsItsAnchor() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships", "Tides"])
        try await assertHoldsTwoResearchRows(
            store: store, mount: { try await self.hostCollection(store: store) })
    }

    func test_theScreenplayTreeHoldsTwoRowsAndKeepsItsAnchor() async throws {
        let store = try await screenplay(notes: ["Ships", "Tides"])
        try await assertHoldsTwoResearchRows(
            store: store, mount: { try await self.hostNavigator(store: store) })
    }

    /// **The selection-shape test every host gets.** The three trees are three
    /// different `List`s over three different projections, and a host whose
    /// binding stayed single-valued would take the second ⌘-click and throw it
    /// away — with nothing else failing, because its rows still select one at a
    /// time perfectly. `allowsMultipleSelection` is the structural half of that:
    /// SwiftUI sets it from the selection's TYPE, so on a single-valued binding
    /// the table refuses the second row outright and the selection below is one
    /// row, not two.
    ///
    /// **What it deliberately does not claim.** The hosts own their sections'
    /// state privately, so this cannot read the acting set — and the table's own
    /// `selectedRowIndexes` is AppKit's answer, not the binding's: a resolver
    /// that took both rows and stored one was planted, and this assertion did
    /// NOT catch it (the `List` does not push a shrinking `get` back over a
    /// selection the user just made). The behaviour behind the shape is asserted
    /// where the state is readable —
    /// `test_twoNotesSelectedInTheTreeAreWhatTheBatchVerbsActOn`, which the same
    /// plant did fail.
    private func assertHoldsTwoResearchRows(
        store: ProjectStore, mount: () async throws -> (NSWindow, BinderSubjectProbe)
    ) async throws {
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let tides = try XCTUnwrap(research(named: "Tides", in: store))
        let (window, probe) = try await mount()
        let table = try XCTUnwrap(firstTableView(in: window))
        let shipsRow = try await rowIndex(of: .research(ships.id), in: table, probe: probe)
        let tidesRow = try await rowIndex(of: .research(tides.id), in: table, probe: probe)

        XCTAssertTrue(table.allowsMultipleSelection,
                      "this tree's List still selects a single value")

        await select(rows: [shipsRow], in: table,
                     until: { probe.subject == .research(ships.id) })
        await select(rows: [shipsRow, tidesRow], in: table,
                     until: { table.selectedRowIndexes.count == 2 })

        XCTAssertEqual(table.selectedRowIndexes, IndexSet([shipsRow, tidesRow]),
                       "the table took both rows — on a single-valued binding "
                       + "it would have taken one")
        XCTAssertEqual(probe.subject, .research(ships.id),
                       "and the window is still about the first — the anchor "
                       + "survives a grown set")
    }

    // MARK: - A batch DRAG

    /// **"Drag-multi into a piece rescopes both."** A real drag session is not
    /// synthesisable headless (`BinderTreeDrops`' own note), so this drives the
    /// route the row's `.dropDestination` calls, over the selection a mounted
    /// tree produces — which the tests above prove is what the table writes.
    func test_twoSelectedNotesDraggedOntoAPieceBothMoveIntoIt() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships", "Tides"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let tides = try XCTUnwrap(research(named: "Tides", in: store))
        let piece = try XCTUnwrap(store.manifest.structure.first)
        state.selection = [.research(ships.id), .research(tides.id)]

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
        state.selection = [.research(ships.id)]

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
        state.selection = [.research(ships.id), .research(
            try XCTUnwrap(research(named: "Tides", in: store)).id), .item(piece.id)]

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
        state.selection = [.research(ships.id), .research(inside.id)]

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
        state.selection = [.research(a.id), .research(b.id)]

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
        for title in pieces { _ = try await store.addLoosePiece(title: title, mode: .prose) }
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
                               selectedSubject: probeBinding(box))
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
        let frame = CGRect(x: 0, y: 0, width: 320, height: 800)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        // The palette section loads its cards from disk once per manifest
        // change, so its rows arrive a turn after the table does.
        pump(0.2)
        return window
    }

    /// Which row of the mounted table writes `subject`, found by asking every
    /// row rather than counting headers and placeholders — the row a note lands
    /// on differs per host, and a hand-counted index is a fixture that goes
    /// quietly wrong the next time the tree grows furniture.
    ///
    /// The subject is cleared before each candidate, so a row that REFUSES to
    /// write (a placeholder, a section header) cannot be mistaken for a match by
    /// leaving the previous answer in place.
    private func rowIndex(of subject: BinderSubject, in table: NSTableView,
                          probe: BinderSubjectProbe) async throws -> Int {
        for row in 0..<table.numberOfRows {
            probe.subject = nil
            state.selection = []
            // A short deadline, because most rows in this scan are EXPECTED to
            // write nothing — a section header, a placeholder — and waiting the
            // full write-back budget on each of those is the difference between
            // a fast test and a minute of nothing happening.
            await select(rows: [row], in: table, deadline: 0.6,
                         until: { probe.subject != nil })
            if probe.subject == subject { return row }
        }
        XCTFail("no row in this tree writes \(subject)")
        throw XCTSkip("row not found")
    }

    private func select(rows: [Int], in table: NSTableView,
                        deadline: TimeInterval = 5,
                        until settled: (() -> Bool)? = nil) async {
        table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        if let settled {
            await pumpUntil(deadline: deadline, settled)
        } else {
            await waitOut(0.4)
        }
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
@MainActor
private struct SectionsOnlyProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let state: BinderTreeSectionsState

    var body: some View {
        let subject = Binding(get: { probe.subject }, set: { probe.subject = $0 })
        List(selection: BinderTreeSelection.binding(
                subject: subject, state: state, store: store)) {
            BinderTreeSections(store: store, state: state, selectedSubject: subject)
        }
        .listStyle(.sidebar)
        .binderTreeSections(store: store, state: state, selectedSubject: subject)
    }
}

@MainActor
private struct MultiselectBinderProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe

    let treeState = BinderTreeSectionsState()

    var body: some View {
        BinderView(store: store,
                   selectedSubject: Binding(get: { probe.subject },
                                            set: { probe.subject = $0 }),
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
        CollectionPiecesPane(
            store: store,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
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
        SceneNavigatorPane(
            store: store,
            script: FountainTokenizer().parse("INT. KITCHEN - DAY\n\nLarry sits.\n"),
            projectTitle: store.manifest.title,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
            documentID: documentID,
            treeState: treeState,
            onSelect: { _ in })
    }
}
