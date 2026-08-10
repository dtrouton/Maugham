import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A research subject in Plan reaches a column the writer can see** —
/// shell-finish stage 2b's final-review Critical.
///
/// `ResearchSubjectRoutingTests` proves the placement sends a research subject
/// beside the canvas and that `ResearchSubjectInspector` draws it there. What no
/// test in that suite could see is whether the right column is SHOWING that
/// inspector: its probe mounts the inspector arm directly, so it skips the one
/// gate production has — `DetailPaneToggle` renders `inspectorContent` from its
/// `.inspector` arm alone, and `Persona.plan.defaultPane` is `.inbox`. Every
/// piece was right and the composition was dead.
///
/// **So this suite's probe mounts the real `DetailPaneToggle`, on Plan's own
/// default pane, and the real `ResearchRevealModifier`.** The only thing it
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

    /// **The Critical, on the path the writer takes.** A row in Plan's tree,
    /// clicked through `List(selection:)`, with the right column where Plan
    /// actually opens it.
    ///
    /// The assertion is the item's own content on screen — the title field
    /// `InspectorResearchPanel` mounts — rather than the segment value, because
    /// a segment that moved to a column nobody rendered is exactly the failure
    /// this suite exists to catch.
    func test_aResearchRowInPlansTreeReachesTheColumnThatShowsIt() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))

        let mount = try await host(store: store, persona: .plan, subject: .project)
        XCTAssertEqual(mount.probe.detailSegment, .inbox,
                       "precondition: Plan opens on its own default pane, which "
                       + "is not the inspector — the whole point of the case")

        let table = try XCTUnwrap(firstTableView(in: mount.window))
        // the project row, the chapters, the Research header, then the note.
        await select(row: 1 + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject == .research(note.id) })
        XCTAssertEqual(mount.probe.subject, .research(note.id),
                       "precondition: the tree wrote the window's subject")

        await pumpUntil(deadline: 5) {
            self.textFields(in: mount.window).contains { $0.stringValue == note.title }
        }
        XCTAssertTrue(
            textFields(in: mount.window).contains { $0.stringValue == note.title },
            "clicking a research row in Plan's tree must put that item somewhere "
            + "the writer can see it. The canvas keeps the centre, so the right "
            + "column is the only place left — and it is showing Inbox unless the "
            + "arriving subject reveals it")
        XCTAssertEqual(mount.probe.detailSegment, .inspector,
                       "and the pane it revealed is the one that renders the "
                       + "research inspector")
    }

    /// **Claude's `Show`, which is a subject write and not a click.** Same
    /// column, same gate: the banner in Plan is the persona a writer is most
    /// likely to be in when Claude adds research.
    func test_aResearchSubjectArrivingWithoutAClickRevealsTheColumnToo() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))

        let mount = try await host(store: store, persona: .plan, subject: .project)
        mount.probe.subject = .research(note.id)

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
    /// ever takes, from no subject at all, which is the one write
    /// `ProjectWindow.validSubject` guarantees can be told apart (it always
    /// answers, so nothing else arrives from `nil`).
    func test_aRestoredResearchSubjectDoesNotTakeTheWritersPane() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))

        let mount = try await host(store: store, persona: .plan, subject: nil)
        mount.probe.subject = .research(note.id)
        pump(0.4)

        XCTAssertEqual(
            mount.probe.detailSegment, .inbox,
            "the window's first subject is `load()`'s seed, and the pane beside "
            + "it was restored verbatim from the same UIState — a reveal there "
            + "would move the writer's last explicit pane choice every reopen")
    }

    /// **The control**: the same arrival where the centre takes the item writes
    /// nothing at all. Author's research subject is the centre column, so a
    /// reveal there would move a writer's pane for no reason.
    func test_anArrivalInAPersonaWhoseCentreTakesTheItemMovesNoPane() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))

        let mount = try await host(store: store, persona: .author, subject: .project)
        let before = mount.probe.detailSegment
        mount.probe.subject = .research(note.id)
        pump(0.4)

        XCTAssertEqual(mount.probe.detailSegment, before,
                       "in Author the centre column shows the item, so the right "
                       + "column has nothing it must reveal")
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

        let mount = try await host(store: store, persona: .plan, subject: .project)
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

        let mount = try await host(store: store, persona: .plan, subject: .project)
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

        let mount = try await host(store: store, persona: .plan, subject: .project)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        await select(row: 1 + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject == .research(note.id) })
        XCTAssertEqual(mount.probe.subject, .research(note.id),
                       "precondition: the note is the window's subject")
        let pane = mount.probe.detailSegment

        mount.probe.treeState.researchSectionExpanded = false
        pump(0.4)

        XCTAssertEqual(mount.probe.subject, .research(note.id),
                       "collapsing a section takes the selected row off screen; "
                       + "it must not take the window's subject with it")
        XCTAssertEqual(mount.probe.detailSegment, pane,
                       "and the centre and right columns stay where they were")
    }

    /// **The mirror above, pinned to production.** `openResearchItem` and
    /// `handleShowLatestMCPNote` are private to a view no test can mount, so the
    /// probe re-spells their two writes — and a mirror is worth exactly as much
    /// as the census that says production still looks like it.
    func test_theWindowsTwoForcedEntriesBothOpenTheTree() throws {
        let source = try Self.windowSource()
        for entry in ["private func openResearchItem(_ itemId: String) {",
                      "private func handleShowLatestMCPNote() {"] {
            let body = try XCTUnwrap(Self.declaration(named: entry, in: source),
                                     "\(entry) must still exist")
            // The bound, checked: an unterminated scan reads the rest of the
            // file and every assertion below it passes for free.
            XCTAssertFalse(body.contains("private func load() async {"),
                           "\(entry): the extracted body must stop at its own "
                           + "closing brace")
            XCTAssertTrue(
                body.contains("treeState.reveal("),
                "\(entry) must open the tree beside its subject write — a "
                + "forced entry names an item the writer is not looking at, and "
                + "selecting a row inside a closed section highlights nothing")
        }
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
            source.contains("guard previous != nil else { return }"),
            "control: the restore case this suite already pins is still the "
            + "reason the observer is the wrong place for a tree reveal")
    }

    // MARK: - The rule itself

    func test_theRevealIsThePlacementsOwnAnswer_askedNotRespelled() {
        for persona in Persona.allCases {
            var showInspector = false
            var segment = persona.defaultPane
            ProjectWindow.revealResearchColumn(
                persona: persona, subject: .research("r1"),
                showInspector: &showInspector, detailSegment: &segment)

            let previews = ProjectWindow.researchSubjectPlacement(
                persona: persona, subject: .research("r1")).previewsInTheRightColumn
            XCTAssertEqual(showInspector, previews,
                           "\(persona): the reveal fires exactly where the "
                           + "placement previews in the right column")
            XCTAssertEqual(segment, previews ? .inspector : persona.defaultPane,
                           "\(persona): and it moves the pane in the same cases")
        }
    }

    func test_aSubjectThatIsNotResearchRevealsNothing() {
        for subject in [BinderSubject.project, .item("doc-1")] {
            var showInspector = false
            var segment = DetailSegment.inbox
            ProjectWindow.revealResearchColumn(
                persona: .plan, subject: subject,
                showInspector: &showInspector, detailSegment: &segment)
            XCTAssertFalse(showInspector, "\(subject) is not a research subject")
            XCTAssertEqual(segment, .inbox)
        }
    }

    /// A collapsed right column (⌘⌥I, or `⌘\` on the canvas) is reopened by the
    /// reveal — the writer asked for the item, and refusing to show it would be
    /// the Critical wearing a different cause.
    func test_theRevealReopensAColumnTheWriterHadClosed() {
        var showInspector = false
        var segment = DetailSegment.inspector
        ProjectWindow.revealResearchColumn(
            persona: .plan, subject: .research("r1"),
            showInspector: &showInspector, detailSegment: &segment)
        XCTAssertTrue(showInspector,
                      "the pane was already the inspector; what was missing was "
                      + "the column being visible at all")
    }

    // MARK: - Reading the source

    /// This file sits in `MaughamTests/`, so it resolves the app's source
    /// directory itself — `CanvasSourceCensus` is reserved for the suites beside
    /// it in `MaughamTests/Canvas/`.
    private static let appSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MaughamTests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Maugham", isDirectory: true)

    private static func windowSource() throws -> String {
        try String(contentsOf: appSource.appendingPathComponent("Views/ProjectWindow.swift"),
                   encoding: .utf8)
    }

    /// A method body, from its opening line to the closing brace at member
    /// indentation — bounded, or a scan over it is a scan over the rest of the
    /// file.
    private static func declaration(named header: String, in source: String) -> String? {
        guard let start = source.range(of: header) else { return nil }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }

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

    private func host(store: ProjectStore, persona: Persona,
                      subject: BinderSubject?) async throws -> Mount {
        let probe = ResearchRevealProbe()
        probe.subject = subject
        probe.detailSegment = persona.defaultPane
        let suite = "research-subject-reveal-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let documentStore = try XCTUnwrap(store.documentStore)

        let root = ResearchRevealProbeView(
            store: store, documentStore: documentStore,
            persona: persona, probe: probe)
            .environment(preferences)

        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
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
    var subject: BinderSubject?
    var detailSegment: DetailSegment = .inbox
    var showInspector = true
    /// The tree's state — the window's since stage-3a Task 4, and this probe
    /// stands in for the window. Held here rather than inside the probe VIEW so
    /// a test can close a section before the tree is ever drawn.
    let treeState = BinderTreeSectionsState()

    /// **What `handleShowLatestMCPNote` and `openResearchItem` do**, in the
    /// order they do it: the subject, then the tree opened far enough to draw
    /// the row. The third write — the column reveal — is production's own
    /// `ResearchRevealModifier`, mounted by the probe view, which is why it is
    /// not spelled here.
    ///
    /// Mirrored rather than called because both window methods are private to a
    /// view that cannot be mounted headless; the mirror is only as good as the
    /// census that pins it
    /// (`test_theWindowsTwoForcedEntriesBothOpenTheTree`).
    func show(_ itemId: String, in store: ProjectStore) {
        subject = .research(itemId)
        treeState.reveal(itemId, research: store.manifest.research)
    }

    init() {}
}

/// **Plan's three columns, with production's own gate in the right one.**
///
/// `BinderView` is the real tree, `DetailPaneToggle` the real right column —
/// mounted on the persona's own default pane, which is the gate the routing
/// suite's probe skips — and `ResearchRevealModifier` the real rule under test.
/// The inspector closure is this view's only construction, and it asks
/// `ProjectWindow.researchSubjectPlacement` rather than deciding anything.
@MainActor
private struct ResearchRevealProbeView: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let persona: Persona
    let probe: ResearchRevealProbe

    private var subject: Binding<BinderSubject?> {
        Binding(get: { probe.subject }, set: { probe.subject = $0 })
    }

    private var segment: Binding<DetailSegment> {
        Binding(get: { probe.detailSegment }, set: { probe.detailSegment = $0 })
    }

    private var showInspector: Binding<Bool> {
        Binding(get: { probe.showInspector }, set: { probe.showInspector = $0 })
    }

    private var placement: ProjectWindow.ResearchSubjectPlacement {
        ProjectWindow.researchSubjectPlacement(persona: persona,
                                               subject: probe.subject)
    }

    var body: some View {
        HStack(spacing: 0) {
            BinderView(store: store, selectedSubject: subject,
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
        .modifier(ResearchRevealModifier(persona: persona,
                                         selectedSubject: subject,
                                         showInspector: showInspector,
                                         detailSegment: segment))
    }

    @ViewBuilder
    private var centre: some View {
        if let id = placement.centreItemID {
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: id, previewVisible: false)
        } else {
            Color.clear
        }
    }

    private var right: some View {
        DetailPaneToggle(
            store: store,
            segment: segment,
            selectedSubject: subject,
            activeManuscriptItemId: probe.subject?.itemID,
            persona: persona,
            projectURL: store.url,
            activeDocId: BinderSubject.activeDocId(for: probe.subject),
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
