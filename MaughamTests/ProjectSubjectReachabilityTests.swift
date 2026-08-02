import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Can the writer point the window at the project — in every project type?**
///
/// `BinderSubject.project` is the scope project-level Intent and Visual Language
/// resolve to (`StatementPane.effectiveScope`), and since slice 1 deleted the
/// pane's own `[Chapter | Project]` switch the tree is the ONLY thing that
/// constructs it. So "is there a project row" is not a question about a view; it
/// is a question about a project type, and it has to be asked of all of them.
///
/// **Why this shape and not one more test per view.** Each of slice 1's tasks
/// tested the surface it touched — task 2 `BinderView`, task 2b
/// `CollectionPiecesPane` — and both passed while a screenplay had no project row
/// at all, because a screenplay's document home is the Scenes navigator and no
/// task's diff contained it. A per-view test cannot see a surface nobody wrote a
/// test for. This one enumerates `ProjectType.allCases` and re-drives
/// **production's own routing** to reach whatever surface that type actually
/// mounts:
///
/// - `ProjectWindow.BinderShell.shell(for:)` — which binder shell the left column
///   mounts. It is the single rule `binderColumn` itself switches on, so a third
///   shell is a new case and this file stops compiling until it is enumerated
///   here too.
/// - `BinderSegment.documentHome(for:)` — where that shell's manuscript content
///   lives. For a screenplay that is `.scenes`, which is the whole reason the
///   defect existed.
///
/// **Mounted, not reasoned about**, for the reason `BinderProjectRowTests`
/// records: a project row's implementation is a label and a `.tag`, and whether
/// `List(selection:)` matches that tag is invisible to a test built from the
/// view's own data. These drive the real `NSTableView` and read the real binding.
@MainActor
final class ProjectSubjectReachabilityTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The census

    /// Every project type, at its own document home, as a **fresh project** —
    /// which for a screenplay means no parsed script yet, because nothing has
    /// opened the `.fountain`, and for a Collection means no pieces at all.
    /// Those are the states in which a writer most wants project-scope intent,
    /// and the states in which an empty-state view that REPLACES its list takes
    /// the only project row with it.
    func test_everyProjectTypeCanNameItsOwnProject() async throws {
        for type in ProjectType.allCases {
            let store = try await project(of: type)
            let (window, probe) = try await host(store: store, script: nil)
            let table = try XCTUnwrap(
                firstTableView(in: window),
                "\(type.rawValue): the binder surface at its document home "
                + "(\(BinderSegment.documentHome(for: type).rawValue)) never put a "
                + "List in the hierarchy — there is no row to select, so the "
                + "project is unreachable")

            await select(row: 0, in: table)

            XCTAssertEqual(
                probe.subject, .project,
                "\(type.rawValue): selecting the head row of the surface at "
                + "\(BinderSegment.documentHome(for: type).rawValue) must produce "
                + "BinderSubject.project — nothing else constructs it, and "
                + "without it project-scope Intent is unreachable in this "
                + "project type")
        }
    }

    /// The same question of a screenplay that has been **opened and parsed**, so
    /// the navigator is a real list of sluglines rather than its empty state.
    /// The empty and non-empty shapes are two different view bodies, and the
    /// project row has to survive both.
    func test_aScreenplayWithScenesCanStillNameItsProject() async throws {
        let store = try await project(of: .screenplay)
        let script = FountainTokenizer().parse(
            "INT. KITCHEN - DAY\n\nLarry sits.\n\nEXT. ROOF - NIGHT\n\nHe climbs.\n")
        XCTAssertEqual(script.sceneSummaries().count, 2, "fixture precondition")

        let (window, probe) = try await host(store: store, script: script)
        let table = try XCTUnwrap(firstTableView(in: window))

        await select(row: 0, in: table)
        XCTAssertEqual(probe.subject, .project,
                       "the scene navigator's head row must be the project row, "
                       + "not the first slugline")
    }

    // MARK: - Plan's tree (slice 2)

    /// **The same census, one segment over.** Plan's `.tree` shows the project's
    /// own manuscript tree with the canvas still in the centre (spec §3.1), and
    /// "the tree" is three views — so the question this file was written to ask
    /// has to be asked of the new segment too, or `.tree` is exactly where the
    /// slice-1 Critical returns.
    func test_everyProjectTypeCanNameItsOwnProjectFromPlansTree() async throws {
        for type in ProjectType.allCases {
            let store = try await project(of: type)
            let (window, probe) = try await host(store: store, script: nil,
                                                 segment: .tree, persona: .plan)
            let table = try XCTUnwrap(
                firstTableView(in: window),
                "\(type.rawValue): Plan's tree segment put no List in the "
                + "hierarchy — the writer opens Plan, clicks Structure, and gets "
                + "a blank column")

            await select(row: 0, in: table)

            XCTAssertEqual(
                probe.subject, .project,
                "\(type.rawValue): the head row of Plan's tree must be the "
                + "project row, exactly as at the document home")
        }
    }

    /// **The discriminator, and the reason the test above is not enough on its
    /// own.** Every one of the three trees carries a project row at row 0, so a
    /// `.tree` arm that mounted `BinderView` for a screenplay would pass it —
    /// which is the 2026-07-02 bug's exact shape (the writer lands in a one-row
    /// `BinderView` instead of the navigator).
    ///
    /// A parsed screenplay tells them apart by what is BELOW the head row:
    /// `SceneNavigatorPane` renders project + script + one row per slugline,
    /// `BinderView` renders project + the one document. Row 1 selects the script
    /// in the navigator; in a `BinderView` it would be the document too, so the
    /// count is what discriminates and the count is asserted.
    ///
    /// `selectRowIndexes` is the right driver here and the Button half is not
    /// needed: both rows under test are `List(selection:)` rows carrying a
    /// `.tag` (the sluglines below them are the `Button`s, and this test never
    /// touches one).
    func test_aScreenplaysTreeIsItsSceneNavigatorAndNotAOneRowBinder() async throws {
        let store = try await project(of: .screenplay)
        let script = FountainTokenizer().parse(
            "INT. KITCHEN - DAY\n\nLarry sits.\n\nEXT. ROOF - NIGHT\n\nHe climbs.\n")
        XCTAssertEqual(script.sceneSummaries().count, 2, "fixture precondition")

        let (window, probe) = try await host(store: store, script: script,
                                             segment: .tree, persona: .plan)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(table.numberOfRows, 4,
                       "project + script + two sluglines. A `BinderView` here "
                       + "would show two rows and no scenes at all — the "
                       + "2026-07-02 one-row-binder defect, on the new segment")

        await select(row: 0, in: table)
        XCTAssertEqual(probe.subject, .project)
    }

    /// A Collection's tree at `.tree` is its Pieces pane — asserted by the pane
    /// that is mounted rather than by the routing table, because
    /// `CollectionBinderPaneToggle` is a second toggle with a `.tree` arm of its
    /// own and two toggles answering one question their own way is how the
    /// 2026-07-02 bug shipped.
    func test_aCollectionsTreeIsItsPiecesPane() async throws {
        let store = try await project(of: .collection)
        _ = try await store.addLoosePiece(title: "Piece One", mode: .prose)
        let (window, probe) = try await host(store: store, script: nil,
                                             segment: .tree, persona: .plan)
        let table = try XCTUnwrap(firstTableView(in: window))
        XCTAssertEqual(table.numberOfRows, 2, "the project row and the one piece")

        await select(row: 0, in: table)
        XCTAssertEqual(probe.subject, .project)
    }

    // MARK: - Fixtures

    private func project(of type: ProjectType) async throws -> ProjectStore {
        let name = "\(type.rawValue)-\(UUID().uuidString.prefix(6))"
        let url: URL
        switch type {
        case .shortStory:
            url = try await ProjectFactory.createShortStoryProject(named: name, in: temp.url)
        case .novel:
            url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        case .screenplay:
            url = try await ProjectFactory.createScreenplayProject(named: name, in: temp.url)
        case .collection:
            url = try await ProjectFactory.createCollectionProject(named: name, in: temp.url)
        case .unknown:
            throw XCTSkip("`.unknown` is excluded from allCases and cannot be created")
        }
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    // MARK: - Hosting and driving

    /// Mounts the binder shell production mounts for this store's type, at the
    /// segment production lands it on. The two `switch`es below are the whole
    /// point of the file: they are exhaustive, so a new shell or a new project
    /// type cannot be added without answering this question for it.
    private func host(store: ProjectStore,
                      script: FountainScript?,
                      segment: BinderSegment? = nil,
                      persona: Persona = .author)
    async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let hosting = NSHostingView(
            rootView: AnyView(
                BinderShellProbeView(store: store, probe: probe, script: script,
                                     segment: segment, persona: persona)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        return (window, probe)
    }

    private func select(row: Int, in table: NSTableView) async {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitOut(0.4)
    }

    private func waitOut(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
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

    private func pumpUntil(deadline: TimeInterval, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return }
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
        _ = condition()
    }

    private func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

/// The left column as `ProjectWindow.binderColumn` builds it — the same shell
/// rule, the same document-home rule, with a handle on the subject it writes.
@MainActor
private struct BinderShellProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let script: FountainScript?
    let persona: Persona
    /// Seeded in `init`, not in `.onAppear`: a screenplay mounted on
    /// `.manuscript` for one frame puts `BinderView`'s table in the hierarchy,
    /// and a test that waits for "a table" would latch onto the wrong surface
    /// and pass while the Scenes navigator had no row at all.
    @State private var segment: BinderSegment
    @State private var researchId: String?
    @State private var paletteCardId: String?
    @State private var findActive = false
    @State private var renamingItemId: String?

    /// - Parameter segment: which binder segment to mount. Defaults to the
    ///   type's document home, which is where Author lands; slice 2's `.tree`
    ///   tests pass `.tree` and `persona: .plan`.
    init(store: ProjectStore, probe: BinderSubjectProbe, script: FountainScript?,
         segment: BinderSegment? = nil, persona: Persona = .author) {
        self.store = store
        self.probe = probe
        self.script = script
        self.persona = persona
        _segment = State(initialValue: segment ?? .documentHome(for: store.manifest.type))
    }

    private var subject: Binding<BinderSubject?> {
        Binding(get: { probe.subject }, set: { probe.subject = $0 })
    }

    var body: some View {
        Group {
            switch ProjectWindow.BinderShell.shell(for: store.manifest.type) {
            case .standard:
                BinderPaneToggle(
                    store: store,
                    segment: $segment,
                    selectedSubject: subject,
                    selectedResearchId: $researchId,
                    selectedPaletteCardId: $paletteCardId,
                    projectType: store.manifest.type,
                    lastParsedScript: script,
                    findActive: $findActive,
                    persona: persona)
            case .collection:
                CollectionBinderPaneToggle(
                    store: store,
                    segment: $segment,
                    selectedSubject: subject,
                    selectedResearchId: $researchId,
                    selectedPaletteCardId: $paletteCardId,
                    findActive: $findActive,
                    renamingItemId: $renamingItemId,
                    activePiece: nil,
                    onAddSharedNote: {},
                    onAddPieceNote: {},
                    persona: persona)
            }
        }
    }
}
