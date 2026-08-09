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

    @State private var outlineLayout: OutlineLayout = .table

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
            BinderView(store: store, selectedSubject: subject)
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
            outlineLayout: $outlineLayout,
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
