import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The tree's scroll position is nobody else's business** — and in
/// particular it is not the review pass's.
///
/// Denver's 2026-08-18 smoke: swapping the pass from the round cockpit's lane
/// picker (Review, some window sizes) left the binder tree scrolled down, with
/// the project row and the first chapters off the top. Nothing about a pass
/// concerns the tree, so the contract is simply that the offset does not move.
///
/// **The positive control is what makes the negative assertions worth
/// anything.** A test that watches a number stay still passes just as happily
/// on a harness that could never have seen it move —
/// `test_control_aRevealRequestDoesMoveTheTree` fires the one mechanism in the
/// app that CAN scroll this list (`BinderTreeSectionsState.consumePendingScroll`,
/// the only production `scrollTo` the tree has) and measures a real jump to the
/// foot of the tree, which is the shape the smoke reported: 0 → the research
/// header, project row and first pieces gone. The reveal's own suites
/// (`FindMatchScrollTests`, `AltitudeKeyspaceTests`) own its behaviour; what is
/// asserted here is only that this harness can tell a scrolled tree from a
/// still one.
///
/// **Two hosts, deliberately.** The probe view is the production shape in
/// miniature (a `NavigationSplitView` whose sidebar is the real
/// `BinderPaneToggle`, with an ancestor reading `uiState` so a write really does
/// re-render the subtree); the second mounts the REAL `ProjectWindow` on a real
/// project, so nothing about the window's own modifiers is modelled rather than
/// run. The write in both is production's own — `updateUIState { … }`, the one
/// line `ProjectWindow.recordActivePass` is.
@MainActor
final class TreeScrollStabilityTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The contract

    /// A pass swap over a tree taller than its column, with a chapter selected
    /// well below the fold — the smoke's own posture.
    func test_aPassSwapDoesNotMoveTheTree() async throws {
        let store = try await novel(chapters: 40)
        let documentStore = try XCTUnwrap(store.documentStore)
        let treeState = BinderTreeSectionsState()
        let probe = BinderSubjectProbe(.project)
        let chapters = store.manifest.structure

        let window = try await mount(store: store, documentStore: documentStore,
                                     treeState: treeState, probe: probe)
        let table = try XCTUnwrap(firstTableView(in: window))
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertGreaterThan(
            table.frame.height, scrollView.contentView.bounds.height,
            "premise: the tree must overflow its column, or there is no scroll "
            + "position for a pass to move")

        // The writer clicks a chapter well down the tree, then scrolls back up.
        table.selectRowIndexes(IndexSet(integer: 26), byExtendingSelection: false)
        _ = await pumpUntil(deadline: 5) { probe.subject != .project }
        scrollToTop(scrollView)
        let before = scrollView.contentView.bounds.origin.y

        // The pass swap: `ProjectWindow.recordActivePass`'s one line.
        documentStore.updateUIState {
            $0.activePassMemory.record(piece: chapters[26].id, passId: "line")
        }
        pump(0.6)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, before, accuracy: 0.5,
                       "the tree scrolled on a pass swap — the pass is a fact "
                       + "about a piece, not about where the writer is looking "
                       + "in their own binder")
    }

    /// The same write in the REAL window, so the negative covers every modifier
    /// `ProjectWindow` hangs off itself rather than the handful a probe models.
    func test_aPassSwapDoesNotMoveTheRealWindowsTree() async throws {
        let store = try await novel(chapters: 40)
        let chapters = store.manifest.structure
        let url = store.url
        // Open in Review, on a chapter, with the annotations queue up — where
        // the cockpit's lane picker lives.
        try XCTUnwrap(store.documentStore).updateUIState {
            $0.persona = .review
            $0.selectedSubject = .item(chapters[25].id)
            $0.detailSegment = .annotations
        }
        await waitOut(1.2)   // the 500ms UI-state debounce reaches disk

        let registry = ProjectRegistry()
        let window = try await mountProjectWindow(url: url, registry: registry)
        let table = try XCTUnwrap(firstTableView(in: window))
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertGreaterThan(
            table.frame.height, scrollView.contentView.bounds.height,
            "premise: the tree overflows its column")

        let liveStore = try XCTUnwrap(
            registry.lookup(id: ProjectIdentifier.id(for: url))?.store,
            "the window registers its own store — without it this test would "
            + "be writing to a second `DocumentStore` the window never reads")
        let liveDocumentStore = try XCTUnwrap(liveStore.documentStore)

        table.selectRowIndexes(IndexSet(integer: 26), byExtendingSelection: false)
        pump(0.5)
        scrollToTop(scrollView)
        let before = scrollView.contentView.bounds.origin.y
        let frameBefore = window.frame

        liveDocumentStore.updateUIState {
            $0.activePassMemory.record(piece: chapters[25].id, passId: "line")
        }
        pump(0.8)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, before, accuracy: 0.5,
                       "the real window's tree scrolled on a pass swap")
        XCTAssertEqual(window.frame, frameBefore,
                       "…and the window did not resize under it either — a "
                       + "grown window is the other way a writer loses the top "
                       + "of a column")
    }

    // MARK: - The control

    /// **The harness can see a scroll when there is one.** This fires the tree's
    /// only production scroll — a reveal request — and measures the jump the
    /// smoke describes: the tree ends at its foot with row zero off the top.
    func test_control_aRevealRequestDoesMoveTheTree() async throws {
        let store = try await novel(chapters: 40)
        let documentStore = try XCTUnwrap(store.documentStore)
        let treeState = BinderTreeSectionsState()
        let probe = BinderSubjectProbe(.project)

        let window = try await mount(store: store, documentStore: documentStore,
                                     treeState: treeState, probe: probe)
        let table = try XCTUnwrap(firstTableView(in: window))
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        scrollToTop(scrollView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.5)

        treeState.scrollRequest = .researchHeader
        _ = await pumpUntil(deadline: 5) { treeState.scrollRequest == nil }
        pump(0.6)

        XCTAssertGreaterThan(
            scrollView.contentView.bounds.origin.y, 100,
            "a reveal request must scroll this list, or every negative in this "
            + "suite is measuring a harness that cannot move")
        XCTAssertNil(treeState.scrollRequest, "the one-shot is consumed")
    }

    // MARK: - Fixtures

    private func novel(chapters: Int) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        while store.manifest.structure.count < chapters {
            _ = try await store.addStructureItem(
                parentId: nil,
                title: "Chapter \(store.manifest.structure.count + 1)",
                kind: .document(extension: "md"))
        }
        await store.wordCountPopulationTask?.value
        return store
    }

    private func scrollToTop(_ scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        pump(0.3)
    }

    private func mount(store: ProjectStore,
                       documentStore: DocumentStore,
                       treeState: BinderTreeSectionsState,
                       probe: BinderSubjectProbe) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 1100, height: 420)
        let hosting = NSHostingView(rootView: AnyView(TreeScrollProbeView(
            store: store, documentStore: documentStore,
            treeState: treeState, probe: probe)))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        _ = await pumpUntil(deadline: 10) { self.firstTableView(in: window) != nil }
        pump(0.4)
        return window
    }

    private func mountProjectWindow(
        url: URL, registry: ProjectRegistry
    ) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 500)
        let hosting = NSHostingView(rootView: AnyView(
            ProjectWindow(url: url)
                .environment(UserPreferences())
                .environment(registry)
                .environment(BackupCoordinator())))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        _ = await pumpUntil(deadline: 20) {
            (self.firstTableView(in: window)?.numberOfRows ?? 0) > 30
        }
        pump(0.6)
        return window
    }

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        return firstSubview(of: NSTableView.self, in: root)
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = firstSubview(of: type, in: sub) { return hit }
        }
        return nil
    }
}

/// The production shape in miniature: a split view whose sidebar is the real
/// tree shell, under an ancestor that READS `uiState` — which is what makes an
/// unrelated write re-render the subtree, exactly as the window's own readers do.
@MainActor
private struct TreeScrollProbeView: View {
    @Bindable var store: ProjectStore
    @Bindable var documentStore: DocumentStore
    let treeState: BinderTreeSectionsState
    @Bindable var probe: BinderSubjectProbe

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var findActive = false

    var body: some View {
        // Read the subject HERE so the body has an observation dependency on it
        // — the window holds it in `@State`, and a binding whose `get` is only
        // ever called from inside `List` does not re-render on a write.
        let current = probe.subject
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            BinderPaneToggle(
                store: store,
                selectedSubject: Binding(get: { current },
                                         set: { probe.subject = $0 }),
                projectType: store.manifest.type,
                lastParsedScript: nil,
                treeState: treeState,
                treeFindActive: $findActive,
                persona: .review)
            .navigationSplitViewColumnWidth(
                min: ProjectWindow.binderColumnFloor, ideal: 240)
        } content: {
            Text("centre").frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: {
            // Reads `uiState` the way the cockpit's own lane line does.
            Text(documentStore.uiState.activePassMemory
                    .activePass(forPiece: "x") ?? "-")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
