import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Research opened beside reaches a column the writer can see** —
/// shell-finish stage 2b's final-review Critical, asked of the window's subject.
///
/// `ResearchSubjectRoutingTests` proves the placement sends a research item
/// beside and that `ResearchSubjectInspector` draws it there. What no test in
/// that suite could see is whether the right column is SHOWING that inspector:
/// its probe mounts the inspector arm directly, so it skips the one gate
/// production has — `DetailPaneToggle` renders `inspectorContent` from its
/// `.inspector` arm alone, and the writer may be on another pane (`.history`
/// here). Every piece was right and the composition was dead.
///
/// **So this suite's probe mounts the real `DetailPaneToggle`, on a pane that
/// is not the inspector, and the real `ResearchRevealModifier`.** The only thing it
/// supplies is the window's inspector closure, and it builds that from
/// `ProjectWindow.researchSubjectPlacement` rather than deciding for itself —
/// the same discipline `ResearchRoutingProbeView` keeps one file over.
@MainActor
final class ResearchSubjectRevealTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []
    private var defaultsSuites: [String] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        for suite in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        defaultsSuites.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The delivery path

    /// **The Critical, on the path the writer takes.** A row in the tree,
    /// clicked through `List(selection:)` while the canvas is open, with the
    /// right column on another pane.
    ///
    /// The assertion is the item's own content on screen — the title field
    /// `InspectorResearchPanel` mounts — rather than the segment value, because
    /// a segment that moved to a column nobody rendered is exactly the failure
    /// this suite exists to catch.
    func test_aResearchRowClickedOverTheCanvasReachesTheColumnThatShowsIt() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))

        let mount = try await host(store: store, subject: Self.canvas)
        XCTAssertEqual(mount.probe.detailSegment, .history,
                       "precondition: the right column is on a pane that is not "
                       + "the inspector — the whole point of the case")

        let table = try XCTUnwrap(firstTableView(in: mount.window))
        // the project row, the chapters, the Research header, then the note.
        await select(row: 1 + TreeFurniture.topRows + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject?.beside == .research(note.id) })
        XCTAssertEqual(mount.probe.subject?.beside, .research(note.id),
                       "precondition: the tree opened the note beside")

        await pumpUntil(deadline: 5) {
            self.textFields(in: mount.window).contains { $0.stringValue == note.title }
        }
        XCTAssertTrue(
            textFields(in: mount.window).contains { $0.stringValue == note.title },
            "clicking a research row must put that item somewhere the writer "
            + "can see it. The canvas keeps the centre, so the right column is "
            + "the only place left — and it is showing Inbox unless the arriving "
            + "subject reveals it")
        XCTAssertEqual(mount.probe.detailSegment, .inspector,
                       "and the pane it revealed is the one that renders the "
                       + "research inspector")
    }

    /// **Claude's `Show`, which is a subject write and not a click.** Same
    /// column, same gate.
    func test_aResearchSubjectArrivingWithoutAClickRevealsTheColumnToo() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))

        let mount = try await host(store: store, subject: Self.canvas)
        mount.probe.subject?.beside = .research(note.id)

        await pumpUntil(deadline: 5) {
            self.textFields(in: mount.window).contains { $0.stringValue == note.title }
        }
        XCTAssertTrue(
            textFields(in: mount.window).contains { $0.stringValue == note.title },
            "a subject written by `handleShowLatestMCPNote` reaches the same "
            + "column a tree click does — the rule is about the subject, not "
            + "about who wrote it")
    }

    /// **A restored subject does not force the pane.** `ProjectWindow.load`
    /// seeds the window's first subject from `UIState` beside a `detailSegment`
    /// restored verbatim from the same state; revealing there would overwrite
    /// the writer's last explicit pane choice on every reopen.
    ///
    /// Driven as the load path drives it — the FIRST write the window's subject
    /// ever takes, from no subject at all (`ProjectWindow.subjectState` is `nil`
    /// until `load()`), which is the one write that can be told apart.
    func test_aRestoredResearchSubjectDoesNotTakeTheWritersPane() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))

        let mount = try await host(store: store, subject: nil)
        mount.probe.subject = WindowSubject(open: .canvas, faces: .canvas,
                                            beside: .research(note.id))
        pump(0.4)

        XCTAssertEqual(
            mount.probe.detailSegment, .history,
            "the window's first subject is `load()`'s seed, and the pane beside "
            + "it was restored verbatim from the same UIState — a reveal there "
            + "would move the writer's last explicit pane choice every reopen")
    }

    /// **The control**: the same item opened in the centre writes nothing at
    /// all — the centre shows it, so a reveal would move a writer's pane for no
    /// reason.
    func test_anItemOpenedInTheCentreMovesNoPane() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))

        let mount = try await host(store: store, subject: .book)
        let before = mount.probe.detailSegment
        mount.probe.subject = SubjectSamples.opened(.research(note.id))
        pump(0.4)

        XCTAssertEqual(mount.probe.detailSegment, before,
                       "the centre column shows the item, so the right column has "
                       + "nothing it must reveal")
    }

    // MARK: - The tree opens far enough to draw the row (stage-3a Task 4)

    /// **The gap `openResearchItem` recorded, closed.** Until this task the tree
    /// had no expansion state at all — both `Section`s and every research group
    /// took the no-binding initialisers, so SwiftUI held the flags privately and
    /// the window could point every column at a note whose row was not drawn.
    ///
    /// Driven through row COUNTS rather than row text: a SwiftUI list row's
    /// subtree carries no `NSTextField` and no accessibility label in this test
    /// host (`BinderProjectRowTests`' measurement), so *the row exists* is
    /// counted, not read.
    func test_showOpensAResearchSectionTheWriterHadClosed() async throws {
        let store = try await novel(notes: ["Ships", "Tides"])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))

        let mount = try await host(store: store, subject: Self.canvas)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        let open = table.numberOfRows

        mount.probe.treeState.researchSectionExpanded = false
        await pumpUntil(deadline: 5) { table.numberOfRows == open - 2 }
        XCTAssertEqual(table.numberOfRows, open - 2,
                       "precondition: a closed Research section draws its header "
                       + "and neither note")

        mount.probe.show(note.id, in: store)
        await pumpUntil(deadline: 5) { table.numberOfRows == open }

        XCTAssertEqual(table.numberOfRows, open,
                       "Show must open the section it named an item in — a "
                       + "subject whose row nothing draws is the selection "
                       + "landing nowhere the writer can see")
        XCTAssertTrue(mount.probe.treeState.researchSectionExpanded)
        await pumpUntil(deadline: 5) {
            self.textFields(in: mount.window).contains { $0.stringValue == note.title }
        }
        XCTAssertTrue(
            textFields(in: mount.window).contains { $0.stringValue == note.title },
            "and the right column still reveals as it did before — opening the "
            + "tree is an addition to that rule, not a replacement for it")
    }

    /// **Every group between the item and the root**, not just the section over
    /// it. A note three levels down inside closed groups is exactly as invisible
    /// as one inside a closed section.
    func test_theRevealOpensEveryGroupBetweenTheItemAndTheRoot() async throws {
        let store = try await novel(notes: [])
        let outer = try await store.addResearchItem(
            parentId: nil, title: "World", kind: nil)
        let inner = try await store.addResearchItem(
            parentId: outer.id, title: "Maps", kind: nil)
        let note = try await store.addResearchTextNote(
            parentId: inner.id, title: "Harbour")

        let mount = try await host(store: store, subject: Self.canvas)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        let closed = table.numberOfRows

        mount.probe.show(note.id, in: store)
        await pumpUntil(deadline: 5) { table.numberOfRows == closed + 2 }

        XCTAssertEqual(table.numberOfRows, closed + 2,
                       "the inner group's row and the note's row both appear — "
                       + "opening only the outermost group would leave the note "
                       + "as undrawn as it was")
        XCTAssertEqual(mount.probe.treeState.expandedResearchGroups,
                       [outer.id, inner.id])
    }

    /// **Closing a section is not a navigation** — the trash disclosure's own
    /// discipline. The rows inside it leave the `List`, and the selected one may
    /// be among them; `BinderTreeSelection`'s refusal of a `nil` write is what
    /// keeps the window pointed where the writer left it.
    func test_closingASectionMovesNeitherTheSubjectNorThePane() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))

        let mount = try await host(store: store, subject: Self.canvas)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        await select(row: 1 + TreeFurniture.topRows + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject?.beside == .research(note.id) })
        XCTAssertEqual(mount.probe.subject?.beside, .research(note.id),
                       "precondition: the note is beside")
        let pane = mount.probe.detailSegment

        mount.probe.treeState.researchSectionExpanded = false
        pump(0.4)

        XCTAssertEqual(mount.probe.subject?.beside, .research(note.id),
                       "collapsing a section takes the selected row off screen; "
                       + "it must not take the window's subject with it")
        XCTAssertEqual(mount.probe.detailSegment, pane,
                       "and the centre and right columns stay where they were")
    }

    /// **The converse**: the observer must NOT reveal, because a subject can also
    /// arrive from a restore and a restore may not move the writer's tree.
    func test_theSubjectObserverOpensNothingOnItsOwn() throws {
        let source = try String(
            contentsOf: Self.appSource.appendingPathComponent(
                "Views/ResearchRevealModifier.swift"), encoding: .utf8)
        XCTAssertFalse(
            source.contains("BinderTreeSectionsState"),
            "the tree's reveal belongs at the two forced entries, not on the "
            + "subject observer: the observer also sees `load()`'s restored "
            + "subject, and opening the tree there would move a writer's "
            + "sections on every reopen. Holding the tree's state is what would "
            + "make that possible, so the modifier must not hold one")
        XCTAssertTrue(
            source.contains("guard Self.isAnArrival(from: previous, to: next)"),
            "control: the restore case this suite already pins is still the "
            + "reason the observer is the wrong place for a tree reveal")
    }

    // MARK: - The rule itself

    func test_theRevealIsThePlacementsOwnAnswer_askedNotRespelled() {
        var subjects = SubjectSamples.everySubject
        subjects += SubjectSamples.everyOpen.map {
            WindowSubject(open: $0, faces: $0, beside: .research("r1"))
        }
        for subject in subjects {
            var showInspector = false
            var segment = DetailSegment.history
            ProjectWindow.revealResearchColumn(
                subject: subject, showInspector: &showInspector, detailSegment: &segment)

            let previews = ProjectWindow.researchSubjectPlacement(subject: subject)
                .previewsInTheRightColumn
                || ProjectWindow.figureSubjectPlacement(subject: subject).besideFigureID != nil
            XCTAssertEqual(showInspector, previews,
                           "\(subject): the reveal fires exactly where the "
                           + "placement previews in the right column")
            XCTAssertEqual(segment, previews ? .inspector : .history,
                           "\(subject): and it moves the pane in the same cases")
        }
    }

    /// **Only an item ARRIVING beside reveals** (review Important 1).
    /// `beside` is sticky across clicks, so a change that leaves it alone — the
    /// faces moving to a chapter, the Book opening — must not take the
    /// writer's chosen pane away again.
    func test_movingTheFacesWithAnItemAlreadyBesideMovesNoPane() {
        let besideChapter = WindowSubject(open: .item(SubjectSamples.pieceID),
                                          faces: .item(SubjectSamples.pieceID),
                                          beside: .research("r1"))
        let facesMoved = ClickRule.navigate(to: .item("pc02"), current: besideChapter,
                                                 structure: SubjectSamples.structure,
                                                 projectType: .novel)
        XCTAssertEqual(facesMoved.beside, .research("r1"), "premise: beside stays")
        XCTAssertFalse(ResearchRevealModifier.isAnArrival(from: besideChapter, to: facesMoved))
        XCTAssertTrue(ResearchRevealModifier.isAnArrival(
            from: SubjectSamples.opened(.item(SubjectSamples.pieceID)), to: besideChapter),
            "control: a note arriving beside does reveal")
        XCTAssertFalse(ResearchRevealModifier.isAnArrival(from: nil, to: besideChapter),
                       "the restore is not an arrival")
    }

    func test_aSubjectWithNothingBesideRevealsNothing() {
        for subject in SubjectSamples.everySubject {
            var showInspector = false
            var segment = DetailSegment.history
            ProjectWindow.revealResearchColumn(
                subject: subject, showInspector: &showInspector, detailSegment: &segment)
            XCTAssertFalse(showInspector, "\(subject.open) open, nothing beside")
            XCTAssertEqual(segment, .history)
        }
    }

    /// A collapsed right column (⌘⌥I, or `⌘\` on the canvas) is reopened by the
    /// reveal — the writer asked for the item, and refusing to show it would be
    /// the Critical wearing a different cause.
    func test_theRevealReopensAColumnTheWriterHadClosed() {
        var showInspector = false
        var segment = DetailSegment.inspector
        ProjectWindow.revealResearchColumn(
            subject: WindowSubject(open: .canvas, faces: .canvas, beside: .research("r1")),
            showInspector: &showInspector, detailSegment: &segment)
        XCTAssertTrue(showInspector,
                      "the pane was already the inspector; what was missing was "
                      + "the column being visible at all")
    }

    /// The canvas open, the faces on the Book — the subject these mounted
    /// cases start from.
    private static let canvas = SubjectSamples.opened(.canvas)

    // MARK: - Reading the source

    /// This file sits in `MaughamTests/`, so it resolves the app's source
    /// directory itself — `CanvasSourceCensus` is reserved for the suites beside
    /// it in `MaughamTests/Canvas/`.
    private static let appSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MaughamTests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Maugham", isDirectory: true)

    // MARK: - Fixtures

    private func novel(notes: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        for title in notes {
            _ = try await store.addResearchTextNote(parentId: nil, title: title)
        }
        await store.wordCountPopulationTask?.value
        return store
    }

    private func researchItem(named title: String, in store: ProjectStore) -> ResearchItem? {
        TreeWalk.first(in: store.manifest.research, where: { $0.title == title })
    }

    // MARK: - Hosting

    private struct Mount {
        let window: NSWindow
        let probe: ResearchRevealProbe
    }

    /// The probe starts on `.history`, a pane that is not the inspector.
    private func host(store: ProjectStore,
                      subject: WindowSubject?) async throws -> Mount {
        let probe = ResearchRevealProbe()
        probe.subject = subject
        probe.detailSegment = .history
        let suite = "research-subject-reveal-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let documentStore = try XCTUnwrap(store.documentStore)

        let root = ResearchRevealProbeView(
            store: store, documentStore: documentStore,
            probe: probe)
            .environment(preferences)

        let window = TestWindow.mount(AnyView(root),
                                      size: CGSize(width: 1200, height: 800),
                                      as: SilentTestWindow.self)
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        pump(0.2)
        return Mount(window: window, probe: probe)
    }

    private func select(row: Int, in table: NSTableView,
                        until settled: (() -> Bool)? = nil) async {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let settled {
            await pumpUntil(deadline: 5, settled)
        } else {
            pump(0.2)
        }
    }

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        collect(NSTableView.self, in: window).first
    }

    private func textFields(in window: NSWindow) -> [NSTextField] {
        collect(NSTextField.self, in: window)
    }

    private func collect<T: NSView>(_ type: T.Type, in window: NSWindow) -> [T] {
        guard let root = window.contentView else { return [] }
        var found: [T] = []
        func walk(_ view: NSView) {
            if let hit = view as? T { found.append(hit) }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return found
    }
}

/// The window state this suite drives and reads: the subject a tree row writes,
/// and the two values the reveal moves.
@Observable
@MainActor
final class ResearchRevealProbe {
    /// `nil` before the window's `load()`, as production's `subjectState` is.
    var subject: WindowSubject?
    var detailSegment: DetailSegment = .history
    var showInspector = true
    /// The tree's state — the window's since stage-3a Task 4, and this probe
    /// stands in for the window. Held here rather than inside the probe VIEW so
    /// a test can close a section before the tree is ever drawn.
    let treeState = BinderTreeSectionsState()

    /// **What `handleShowLatestMCPNote` and `openResearchItem` do**, in the
    /// order they do it: the subject, then the tree opened far enough to draw
    /// the row, then (stage-3b Task 8) the scroll request from what `reveal`
    /// returned. The fourth write — the column reveal — is production's own
    /// `ResearchRevealModifier`, mounted by the probe view, which is why it is
    /// not spelled here.
    ///
    /// Mirrored rather than called because both window methods are private to a
    /// view that cannot be mounted headless; the mirror is only as good as the
    /// census that pins it (`WiringCensusTests`' entries for
    /// `openResearchItem` and `handleShowLatestMCPNote`).
    @discardableResult
    func show(_ itemId: String, in store: ProjectStore) -> BinderSubject? {
        subject = ClickRule.navigate(to: .research(itemId), current: subject ?? .book,
                                          structure: store.manifest.structure,
                                          projectType: store.manifest.type)
        let revealed = treeState.reveal(itemId, structure: store.manifest.structure,
                                        research: store.manifest.research,
                                        projectType: store.manifest.type)
        if let revealed { treeState.scrollRequest = .row(revealed) }
        return revealed
    }

    init() {}
}

/// **Three columns, with production's own gate in the right one.**
///
/// `BinderView` is the real tree, `DetailPaneToggle` the real right column —
/// mounted on a pane that is not the inspector, which is the gate the routing
/// suite's probe skips — and `ResearchRevealModifier` the real rule under test.
/// The inspector closure is this view's only construction, and it asks
/// `ProjectWindow.researchSubjectPlacement` rather than deciding anything.
@MainActor
private struct ResearchRevealProbeView: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let probe: ResearchRevealProbe

    /// The right column's view of the subject, as `ProjectWindow`'s
    /// `facesNavigation`: the faces, written through `ClickRule.navigate`.
    private var subject: Binding<BinderSubject?> {
        Binding(
            get: { probe.subject?.faces },
            set: { newValue in
                probe.subject = ClickRule.navigate(to: 
                    newValue, current: probe.subject ?? .book,
                    structure: store.manifest.structure, projectType: store.manifest.type)
            })
    }

    private var segment: Binding<DetailSegment> {
        Binding(get: { probe.detailSegment }, set: { probe.detailSegment = $0 })
    }

    private var showInspector: Binding<Bool> {
        Binding(get: { probe.showInspector }, set: { probe.showInspector = $0 })
    }

    private var placement: ProjectWindow.ResearchSubjectPlacement {
        ProjectWindow.researchSubjectPlacement(subject: probe.subject ?? .book)
    }

    var body: some View {
        HStack(spacing: 0) {
            BinderView(store: store,
                       subject: Binding(get: { probe.subject ?? .book },
                                        set: { probe.subject = $0 }),
                       treeState: probe.treeState)
                .frame(width: 280)
            centre.frame(maxWidth: .infinity, maxHeight: .infinity)
            // `ProjectWindow.detailColumn` renders nothing while the column is
            // hidden, so the probe must too — half of what the reveal writes is
            // this visibility.
            if probe.showInspector {
                right.frame(width: 340)
            }
        }
        .modifier(ResearchRevealModifier(subject: probe.subject,
                                         showInspector: showInspector,
                                         detailSegment: segment))
    }

    @ViewBuilder
    private var centre: some View {
        if let id = placement.centreItemID {
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: id, previewVisible: false,
                                  readOnly: WindowLock.refusesEdits(isLocked: WindowLock.atOpen))
        } else {
            Color.clear
        }
    }

    private var right: some View {
        DetailPaneToggle(
            store: store,
            segment: segment,
            selectedSubject: subject,
            activeManuscriptItemId: probe.subject?.faces.itemID,
            subject: probe.subject ?? .book,
            projectURL: store.url,
            activeDocId: BinderSubject.activeDocId(for: probe.subject?.faces),
            documentStore: documentStore
        ) {
            if let id = placement.inspectedItemID {
                ResearchSubjectInspector(
                    store: store, itemID: id,
                    showsPreview: placement.previewsInTheRightColumn)
            } else {
                Color.clear
            }
        }
    }
}
