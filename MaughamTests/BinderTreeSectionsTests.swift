import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The Research and Palette sections, in all three trees** (shell-finish
/// stage-2a Task 4).
///
/// Every persona gets ONE left column, so the sections are not a pane the writer
/// switches to — they are furniture at the foot of whichever tree the project
/// type puts up. There are three of those (`BinderView` for prose,
/// `CollectionPiecesPane` for a Collection, `SceneNavigatorPane` for a
/// screenplay) and the whole point of the milestone is that a writer cannot tell
/// which one they are looking at from the sections' behaviour. So every
/// assertion here is asked of all three.
///
/// **Mounted, not reasoned about**, for the reason `BinderProjectRowTests`
/// records: a row's whole implementation is a label and a `.tag`, and whether
/// `List(selection:)` matches that tag is exactly what a test built out of the
/// view's own data cannot see.
@MainActor
final class BinderTreeSectionsTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    /// Every fixture opens one — `addResearchTextNote` and `addPaletteCard`
    /// write through the typed mover and refuse outright without it. Closed in
    /// teardown so their autosave schedulers do not outlive the test.
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The sections exist, below everything the tree already had

    func test_theNovelTreeGrowsBothSectionsBelowItsChapters() async throws {
        let store = try await novel(notes: ["Ships", "Tides"], cards: ["Harbour"])
        let (window, _) = try await hostBinder(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        let chapters = store.manifest.structure.count
        XCTAssertEqual(
            table.numberOfRows,
            1 + chapters + (1 + 2) + (1 + 1),
            "the project row, the chapters, then a Research section (header + "
            + "two notes) and a Palette section (header + one card)")
    }

    func test_theCollectionTreeGrowsBothSectionsBelowItsPieces() async throws {
        let store = try await collection(pieces: ["One"],
                                         notes: ["Ships", "Tides"], cards: ["Harbour"])
        let (window, _) = try await hostCollection(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(
            table.numberOfRows,
            1 + store.manifest.structure.count + (1 + 2) + (1 + 1),
            "the project row, the pieces, then both sections")
    }

    func test_theScreenplayTreeGrowsBothSectionsBelowItsSluglines() async throws {
        let store = try await screenplay(notes: ["Ships", "Tides"], cards: ["Harbour"])
        let (window, _, _) = try await hostNavigator(store: store, script: Self.twoScenes)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(
            table.numberOfRows,
            1 + 1 + 2 + (1 + 2) + (1 + 1),
            "the project row, the script row, the two sluglines, then both sections")
    }

    /// **The palette group is not research.** It is a research group on disk —
    /// `addPaletteCard` writes under `research/palette/` — so a tree that renders
    /// `manifest.research` raw shows it twice: once as a group in Research and
    /// once as the Palette section. `TreeSectionDerivation.sharedResearchRoots`
    /// is what filters it, and this is the mounted proof it is being called.
    func test_thePaletteGroupIsNotAlsoARowInTheResearchSection() async throws {
        let store = try await novel(notes: ["Ships"], cards: ["Harbour"])
        XCTAssertNotNil(store.paletteGroup(), "fixture precondition: a palette group exists")

        let (window, _) = try await hostBinder(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(
            table.numberOfRows,
            1 + store.manifest.structure.count + (1 + 1) + (1 + 1),
            "Research must hold the ONE note and not the palette group beside it")
    }

    // MARK: - Selecting a research row, through the list

    func test_aResearchRowInTheNovelTreeMakesItselfTheSubject() async throws {
        let store = try await novel(notes: ["Ships"], cards: ["Harbour"])
        let (window, probe) = try await hostBinder(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))
        let note = try XCTUnwrap(researchNote(named: "Ships", in: store))

        let row = 1 + store.manifest.structure.count + 1
        await select(row: row, in: table, until: { probe.subject == .research(note.id) })

        XCTAssertEqual(probe.subject, .research(note.id),
                       "a research row is a subject of the window like any other")
    }

    func test_aResearchRowInTheCollectionTreeMakesItselfTheSubject() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"], cards: ["Harbour"])
        let (window, probe) = try await hostCollection(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))
        let note = try XCTUnwrap(researchNote(named: "Ships", in: store))

        let row = 1 + store.manifest.structure.count + 1
        await select(row: row, in: table, until: { probe.subject == .research(note.id) })

        XCTAssertEqual(probe.subject, .research(note.id))
    }

    func test_aResearchRowInTheScreenplayTreeMakesItselfTheSubject() async throws {
        let store = try await screenplay(notes: ["Ships"], cards: ["Harbour"])
        let (window, probe, _) = try await hostNavigator(store: store, script: Self.twoScenes)
        let table = try XCTUnwrap(firstTableView(in: window))
        let note = try XCTUnwrap(researchNote(named: "Ships", in: store))

        // project, script, two sluglines, Research header, then the note.
        await select(row: 5, in: table, until: { probe.subject == .research(note.id) })

        XCTAssertEqual(probe.subject, .research(note.id),
                       "the navigator's projection has to let a research write "
                       + "through — its List now draws rows that mean one")
    }

    // MARK: - Selecting a palette card, through the list

    /// A palette card IS a research item (`PaletteCard.id == researchItemId`), so
    /// it takes the same subject case. This is the mounted proof the tree agrees
    /// with that — a `.paletteCard` case would have been a second name for one id.
    func test_aPaletteCardRowMakesItselfTheSubjectInEveryTree() async throws {
        let novelStore = try await novel(notes: ["Ships"], cards: ["Harbour"])
        let (novelWindow, novelProbe) = try await hostBinder(store: novelStore)
        let novelTable = try XCTUnwrap(firstTableView(in: novelWindow))
        let novelCard = try XCTUnwrap(novelStore.loadPaletteCards().first)
        let novelRow = 1 + novelStore.manifest.structure.count + 2 + 1
        await select(row: novelRow, in: novelTable,
                     until: { novelProbe.subject == .research(novelCard.id) })
        XCTAssertEqual(novelProbe.subject, .research(novelCard.id), "novel tree")

        let collectionStore = try await collection(
            pieces: ["One"], notes: ["Ships"], cards: ["Harbour"])
        let (collectionWindow, collectionProbe) = try await hostCollection(store: collectionStore)
        let collectionTable = try XCTUnwrap(firstTableView(in: collectionWindow))
        let collectionCard = try XCTUnwrap(collectionStore.loadPaletteCards().first)
        let collectionRow = 1 + collectionStore.manifest.structure.count + 2 + 1
        await select(row: collectionRow, in: collectionTable,
                     until: { collectionProbe.subject == .research(collectionCard.id) })
        XCTAssertEqual(collectionProbe.subject, .research(collectionCard.id), "collection tree")

        let screenplayStore = try await screenplay(notes: ["Ships"], cards: ["Harbour"])
        let (screenplayWindow, screenplayProbe, _) = try await hostNavigator(
            store: screenplayStore, script: Self.twoScenes)
        let screenplayTable = try XCTUnwrap(firstTableView(in: screenplayWindow))
        let screenplayCard = try XCTUnwrap(screenplayStore.loadPaletteCards().first)
        await select(row: 7, in: screenplayTable,
                     until: { screenplayProbe.subject == .research(screenplayCard.id) })
        XCTAssertEqual(screenplayProbe.subject, .research(screenplayCard.id), "screenplay tree")
    }

    // MARK: - The project row is still row zero

    func test_theProjectRowIsStillRowZeroInEveryTree() async throws {
        let novelStore = try await novel(notes: ["Ships"], cards: ["Harbour"])
        let (novelWindow, novelProbe) = try await hostBinder(store: novelStore)
        await select(row: 0, in: try XCTUnwrap(firstTableView(in: novelWindow)),
                     until: { novelProbe.subject == .project })
        XCTAssertEqual(novelProbe.subject, .project, "novel tree")

        let collectionStore = try await collection(
            pieces: ["One"], notes: ["Ships"], cards: ["Harbour"])
        let (collectionWindow, collectionProbe) = try await hostCollection(store: collectionStore)
        await select(row: 0, in: try XCTUnwrap(firstTableView(in: collectionWindow)),
                     until: { collectionProbe.subject == .project })
        XCTAssertEqual(collectionProbe.subject, .project, "collection tree")

        let screenplayStore = try await screenplay(notes: ["Ships"], cards: ["Harbour"])
        let (screenplayWindow, screenplayProbe, _) = try await hostNavigator(
            store: screenplayStore, script: Self.twoScenes)
        await select(row: 0, in: try XCTUnwrap(firstTableView(in: screenplayWindow)),
                     until: { screenplayProbe.subject == .project })
        XCTAssertEqual(screenplayProbe.subject, .project, "screenplay tree")
    }

    // MARK: - The empty sections

    /// The headers are furniture: they are there whether or not the writer has
    /// made anything yet, because a section that appears and disappears is not a
    /// place. Each empty one carries exactly ONE placeholder row — Task 7's
    /// drop target, and the affordance that says where a note would land.
    func test_anEmptySectionKeepsItsHeaderAndCarriesOnePlaceholderRow() async throws {
        let store = try await novel(notes: [], cards: [])
        XCTAssertTrue(store.manifest.research.isEmpty, "fixture precondition")

        let (window, _) = try await hostBinder(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(
            table.numberOfRows,
            1 + store.manifest.structure.count + (1 + 1) + (1 + 1),
            "each empty section is its header plus one placeholder row")
    }

    /// **The placeholder row must not become the subject, and must not clear
    /// it.** `BinderView` measured (macOS 26.5) that an untagged row is selected
    /// anyway and writes `nil` through the binding — which blanks the centre
    /// column. That measurement is why the empty state is an overlay rather than
    /// a row; the placeholder rows re-open exactly that hazard, so every tree's
    /// selection binding refuses a `nil` write.
    func test_clickingAnEmptySectionsPlaceholderLeavesTheSubjectAlone() async throws {
        let store = try await novel(notes: [], cards: [])
        let (window, probe) = try await hostBinder(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project, "precondition")

        // The Research section's placeholder: header, then the row.
        let placeholder = 1 + store.manifest.structure.count + 1
        // fixed window: asserting an absence — the subject must still be there
        // after the placeholder's write has had its full chance to arrive.
        await select(row: placeholder, in: table)

        XCTAssertEqual(probe.subject, .project,
                       "a placeholder row is not a subject — selecting one must "
                       + "leave the window's subject exactly where it was")
    }

    /// The plant for the test above. Bound straight to the subject — the shape
    /// anyone writes first — the same untagged placeholder DOES clear it.
    func test_plantedOffender_aPlaceholderRowOnANaiveBindingClearsTheSubject() async throws {
        let probe = BinderSubjectProbe(.project)
        let window = try await mount(AnyView(NaivePlaceholderOffender(probe: probe)))
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(probe.subject, .project, "precondition")
        // fixed window: the assertion below is an XCTAssertNil, and a plant that
        // failed to fire looks exactly like one that has not landed yet.
        await select(row: 2, in: table)

        XCTAssertNil(probe.subject,
                     "PLANT DID NOT FIRE: an untagged placeholder row was "
                     + "expected to write nil through a direct binding. If this "
                     + "is nil-safe on this macOS then the trees' nil-refusing "
                     + "selection binding is guarding nothing and the test above "
                     + "is vacuous — read the finding, do not delete this test")
    }

    // MARK: - Creating from a header selects the new thing (fix round 1)

    /// **Add Link is a creation verb, so it points the window at the link.**
    ///
    /// It shipped discarding the created item, which made it the one verb on
    /// these headers that left the writer looking at whatever they were looking
    /// at before — and a regression against both panes the tree replaces, which
    /// have always selected a new link. New Note, New Group and New Card all go
    /// through `create`, which does the same thing; only the link, which needs a
    /// sheet, went the long way round and lost it.
    func test_addLinkPointsTheWindowAtTheLinkItMade() async throws {
        let store = try await novel(notes: [], cards: [])
        let probe = BinderSubjectProbe(.project)
        let state = BinderTreeSectionsState()

        await BinderTreeSections.addLink(
            title: "Tide tables", url: "https://example.invalid/tides",
            parentId: nil, store: store, state: state,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }))

        let link = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.research,
                           where: { $0.title == "Tide tables" }),
            "precondition: the link reached the manifest")
        XCTAssertEqual(probe.subject, .research(link.id),
                       "creating from a section header selects the new thing — "
                       + "the writer asked for a link, so the link is what the "
                       + "window is now about")
        XCTAssertNil(state.pendingRenameId,
                     "…but not into rename mode: the sheet already asked for "
                     + "the title, and asking twice is what both old panes "
                     + "deliberately avoid")
    }

    // MARK: - A drop the tree cannot route refuses (fix round 1, kept by Task 7)

    /// **A drop the tree cannot route must BOUNCE, not vanish.**
    ///
    /// `ResearchRow`'s `.dropDestination` used to `return true` unconditionally,
    /// so "accepted" was a property of the row rather than of the handler: a
    /// note dragged onto a populated research row animated home as accepted and
    /// was then silently discarded — the writer's drag, gone, with the
    /// animation that says it worked. The drop closures return `Bool` all the
    /// way down now.
    ///
    /// **Task 7 filled the routing and this test did not change**, which is the
    /// point of it: the ids here belong to nothing in the project, and an id the
    /// tree cannot place is refused by `TreeDropIntent` for exactly the reason
    /// the stub refused it. Where the drag CAN be routed is
    /// `BinderTreeDropRoutingTests`; that the row forwards this answer rather
    /// than a literal is `TripwireGrepTests`'.
    func test_theTreeRefusesADropItCannotPlace() async throws {
        let store = try await novel(notes: ["Ships"], cards: ["Harbour"])
        let target = try XCTUnwrap(researchNote(named: "Ships", in: store))
        let sections = BinderTreeSections(
            store: store,
            state: BinderTreeSectionsState(),
            selectedSubject: .constant(nil))

        XCTAssertFalse(
            sections.actions.internalDrop("some-other-id", .middle, target),
            "an id from outside this project — a canvas node, another window's "
            + "row — must bounce back to where the writer took it from. "
            + "Returning true accepts it and drops it on the floor")
        XCTAssertFalse(
            sections.actions.externalDrop([], .middle, target),
            "and a Finder file or a browser bitmap is refused outright: it has "
            + "to land in a SCOPE, and importing to a piece's root has no store "
            + "API (the hole Task 6 recorded for New Group). Stage 2b owns it")
    }

    /// The control, and it is what makes the assertion above mean something: the
    /// two panes the tree is replacing DO accept, through the very same bundle
    /// type. If `ResearchTreeActions` had simply become a type that always
    /// refuses, the test above would pass while saying nothing.
    func test_theOldPanesStillAcceptTheDropsTheyCanRoute() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let target = try XCTUnwrap(researchNote(named: "Ships", in: store))
        let pane = ResearchView(store: store, selectedResearchId: .constant(nil))

        XCTAssertTrue(
            pane.treeActions.internalDrop("some-other-id", .middle, target),
            "control: ResearchView's routing is built and accepts — so "
            + "'refuses' above is a property of the tree's stub, not of the "
            + "type every caller shares")
    }

    // MARK: - Fixtures

    private static let twoScenes = FountainTokenizer().parse(
        "INT. KITCHEN - DAY\n\nLarry sits.\n\nEXT. ROOF - NIGHT\n\nHe climbs.\n")

    private func novel(notes: [String], cards: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url),
                                 notes: notes, cards: cards)
    }

    private func collection(pieces: [String], notes: [String],
                            cards: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        for title in pieces { _ = try await store.addLoosePiece(title: title, mode: .prose) }
        return try await furnish(store, notes: notes, cards: cards)
    }

    private func screenplay(notes: [String], cards: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "Screenplay-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url),
                                 notes: notes, cards: cards)
    }

    private func furnish(_ store: ProjectStore, notes: [String],
                         cards: [String]) async throws -> ProjectStore {
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        for title in notes {
            _ = try await store.addResearchTextNote(parentId: nil, title: title)
        }
        for title in cards {
            _ = try await store.addPaletteCard(title: title, kind: .location)
        }
        await store.wordCountPopulationTask?.value
        return store
    }

    private func researchNote(named title: String, in store: ProjectStore) -> ResearchItem? {
        TreeWalk.first(in: store.manifest.research, where: { $0.title == title })
    }

    // MARK: - Hosting and driving

    private func hostBinder(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            BinderSectionsProbeView(store: store, probe: probe)))
        return (window, probe)
    }

    private func hostCollection(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            CollectionSectionsProbeView(store: store, probe: probe)))
        return (window, probe)
    }

    private func hostNavigator(
        store: ProjectStore, script: FountainScript?
    ) async throws -> (NSWindow, BinderSubjectProbe, String?) {
        let probe = BinderSubjectProbe()
        let documentID = TreeWalk.first(
            in: store.manifest.structure, where: { $0.type == .document })?.id
        let window = try await mount(AnyView(NavigatorSectionsProbeView(
            store: store, probe: probe, script: script, documentID: documentID)))
        return (window, probe, documentID)
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
        // The palette section loads its cards from disk once per manifest change,
        // so the rows it contributes arrive a turn after the table does.
        pump(0.2)
        return window
    }

    /// Move the table's selection and let SwiftUI's list coordinator write it
    /// back through the binding. `until` names what the caller's next assertion
    /// checks; a caller asserting an ABSENCE passes nothing and gets the fixed
    /// wall-clock window instead.
    private func select(row: Int, in table: NSTableView,
                        until settled: (() -> Bool)? = nil) async {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let settled {
            await pumpUntil(deadline: 5, settled)
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

@MainActor
private struct BinderSectionsProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe

    var body: some View {
        BinderView(store: store,
                   selectedSubject: Binding(get: { probe.subject },
                                            set: { probe.subject = $0 }))
    }
}

@MainActor
private struct CollectionSectionsProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    @State private var renaming: String?

    var body: some View {
        CollectionPiecesPane(
            store: store,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
            renamingItemId: $renaming)
    }
}

@MainActor
private struct NavigatorSectionsProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let script: FountainScript?
    let documentID: String?

    var body: some View {
        SceneNavigatorPane(
            store: store,
            script: script,
            projectTitle: store.manifest.title,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
            documentID: documentID,
            onSelect: { _ in })
    }
}

/// **The planted offender.** A tree whose List is bound STRAIGHT to the subject,
/// with an untagged placeholder row in it — the shape the empty sections would
/// take if nobody had measured what an untagged row does. Selecting the
/// placeholder must clear the subject here, or the guard the real trees carry is
/// protecting nothing.
@MainActor
private struct NaivePlaceholderOffender: View {
    let probe: BinderSubjectProbe

    var body: some View {
        List(selection: Binding(get: { probe.subject },
                                set: { probe.subject = $0 })) {
            ProjectRowLabel(title: "Offender")
                .tag(BinderSubject.project)
            Section("Research") {
                Text("No research yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}
