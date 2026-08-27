import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **"Link Research…" returns** (shell-finish stage-3b Task 9).
///
/// Stage 3a's fix wave deleted `ResearchLinkPickerSheet` along with
/// `LinkedResearchPane`, its only host — leaving the tree DRAG as the sole
/// in-app route to `ProjectStore.linkResearch`/`unlinkResearch`, a modality
/// narrowing for a writer working by keyboard or VoiceOver. This task brings
/// the verb back as a document row's context menu item, and the sheet as its
/// picker, mounted from `BinderTreeSectionsPresentations` (never from a row —
/// `BinderTreeSections`' own reason for splitting the two).
///
/// A `.contextMenu`'s `NSMenu` is built on right-click and is not reachable
/// from a headless test (`PlanTreeStructureCreationTests`'s own note on this
/// SDK), so the boundary — which rows offer the verb — is asked of
/// `BinderView.linkResearchVerb(for:)` directly rather than by trying to open
/// a menu that a real click alone would build. What a mounted window CAN
/// drive is the sheet itself, once it is open, and the fold it feeds.
@MainActor
final class ResearchLinkPickerTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
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

    // MARK: - The boundary: which rows offer the verb

    /// The positive control. Without this, every "offers no verb" test below
    /// could pass because the predicate refuses everything.
    func test_aNovelChaptersRowOffersTheVerb() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let state = BinderTreeSectionsState()
        let view = BinderView(store: store, selectedSubject: .constant(nil), treeState: state)

        let openPicker = try XCTUnwrap(
            view.linkResearchVerb(for: chapter),
            "a novel chapter routes .sharedPlusLink and must offer \"Link Research…\"")
        openPicker()

        XCTAssertEqual(state.linkPickerDocumentId, chapter.id,
                       "pressing the verb opens the picker on this document — "
                       + "the row's whole job")
    }

    func test_aGroupRowOffersNoVerb() async throws {
        let store = try await novel()
        let group = try await store.addStructureItem(
            parentId: nil, title: "Part One", kind: .group)
        let view = BinderView(store: store, selectedSubject: .constant(nil),
                              treeState: BinderTreeSectionsState())

        XCTAssertNil(view.linkResearchVerb(for: group),
                     "research links to a DOCUMENT — a group offers no verb")
    }

    func test_aCollectionPieceRowOffersNoVerb() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        let view = BinderView(store: store, selectedSubject: .constant(nil),
                              treeState: BinderTreeSectionsState())

        XCTAssertNil(view.linkResearchVerb(for: piece),
                     "a Collection loose piece routes .pieceFolder — its "
                     + "research is CONTAINED in the piece's own folder, "
                     + "never linked")
    }

    /// `BinderView` is never actually mounted for a screenplay project in
    /// production (`SceneNavigatorPane` is) — this asks the predicate itself,
    /// off-label, to prove the routing boundary holds independent of which
    /// host happens to call it, the same guarantee `TreeDropIntent`'s drag
    /// boundary rests on.
    func test_aScreenplaysScriptRowOffersNoVerb() async throws {
        let store = try await screenplay()
        let script = try XCTUnwrap(TreeWalk.first(
            in: store.manifest.structure, where: { $0.type == .document }))
        let view = BinderView(store: store, selectedSubject: .constant(nil),
                              treeState: BinderTreeSectionsState())

        XCTAssertNil(view.linkResearchVerb(for: script),
                     "a screenplay's single file routes .sharedOnly — "
                     + "everything in Research is already the document's")
    }

    // MARK: - Toggling, live off the manifest

    func test_togglingOnLinksTheItem() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        let state = BinderTreeSectionsState()
        let sheet = ResearchLinkPickerSheet(
            store: store, documentId: chapter.id,
            perform: BinderTreeVerbs(store: store, state: state,
                                     selectedSubject: .constant(nil)).perform)

        sheet.toggleLink(note.id, link: true)
        await pumpUntil(deadline: 5) {
            store.linkedResearchIds(forDocumentId: chapter.id).contains(note.id)
        }

        XCTAssertTrue(store.linkedResearchIds(forDocumentId: chapter.id).contains(note.id))
        XCTAssertNil(state.pendingError, "the store's own error: \(state.pendingError ?? "none")")
    }

    func test_togglingOffUnlinksTheItem() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)
        let state = BinderTreeSectionsState()
        let sheet = ResearchLinkPickerSheet(
            store: store, documentId: chapter.id,
            perform: BinderTreeVerbs(store: store, state: state,
                                     selectedSubject: .constant(nil)).perform)

        sheet.toggleLink(note.id, link: false)
        await pumpUntil(deadline: 5) {
            !store.linkedResearchIds(forDocumentId: chapter.id).contains(note.id)
        }

        XCTAssertFalse(store.linkedResearchIds(forDocumentId: chapter.id).contains(note.id))
        XCTAssertNil(state.pendingError)
    }

    /// **The deleted original's defect, reintroduced as a plant and refused.**
    /// It swallowed `linkResearch`/`unlinkResearch` with `try?` — a toggle
    /// that silently did nothing on a genuine store failure, which is the
    /// exact silent-no-op class CLAUDE.md's publishing-namespace finding says
    /// to fail loudly on. Planted by making the project's own directory
    /// unwritable, so `saveManifest`'s disk write genuinely throws rather
    /// than a mocked double standing in for one.
    func test_aStoreThrowSurfacesInThePendingErrorRatherThanBeingSwallowed() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        let state = BinderTreeSectionsState()
        let sheet = ResearchLinkPickerSheet(
            store: store, documentId: chapter.id,
            perform: BinderTreeVerbs(store: store, state: state,
                                     selectedSubject: .constant(nil)).perform)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: store.url.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: store.url.path)
        }

        sheet.toggleLink(note.id, link: true)
        await pumpUntil(deadline: 5) { state.pendingError != nil }

        XCTAssertNotNil(
            state.pendingError,
            "the deleted sheet's `try?` swallowed a store failure outright — "
            + "`perform` must surface it in the shared alert like every other "
            + "tree verb")
    }

    // MARK: - The search field

    func test_theFilterMatchesTitleCaseInsensitively() {
        let items = [
            ResearchItem(id: "a", title: "Harbour Map", type: .asset, kind: .document),
            ResearchItem(id: "b", title: "Tide Tables", type: .asset, kind: .document),
        ]

        XCTAssertEqual(ResearchLinkPickerSheet.filter(items, query: "harbour").map(\.id), ["a"])
        XCTAssertEqual(ResearchLinkPickerSheet.filter(items, query: "TIDE").map(\.id), ["b"])
        XCTAssertTrue(ResearchLinkPickerSheet.filter(items, query: "no such thing").isEmpty)
    }

    func test_anEmptyQueryReturnsEveryItemUnfiltered() {
        let items = [
            ResearchItem(id: "a", title: "Harbour Map", type: .asset, kind: .document),
            ResearchItem(id: "b", title: "Tide Tables", type: .asset, kind: .document),
        ]

        XCTAssertEqual(ResearchLinkPickerSheet.filter(items, query: "").map(\.id), ["a", "b"])
    }

    // MARK: - The fold reflects a fresh link without relaunch

    /// **The same mounted tree, before and after** — no remount, no second
    /// window. `TreeSectionDerivation.pieceFold` is a per-render read off
    /// `store.manifest`, never a cache, so a link made through the sheet has
    /// to show up in the very tree the writer already has open.
    func test_theFoldPicksUpAFreshLinkInTheSameMountedTree() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        let state = BinderTreeSectionsState()

        let (window, _) = try await hostBinder(store: store, state: state)
        let outline = try XCTUnwrap(outlineView(in: window))
        XCTAssertFalse(try isExpandable(row: 1, in: outline),
                       "precondition: nothing is linked yet, so the chapter "
                       + "has no chevron")

        let sheet = ResearchLinkPickerSheet(
            store: store, documentId: chapter.id,
            perform: BinderTreeVerbs(store: store, state: state,
                                     selectedSubject: .constant(nil)).perform)
        sheet.toggleLink(note.id, link: true)

        await pumpUntil(deadline: 5) { (try? self.isExpandable(row: 1, in: outline)) == true }

        XCTAssertTrue(try isExpandable(row: 1, in: outline),
                      "the fold picked up the fresh link in the SAME mounted "
                      + "tree — no relaunch required")
    }

    // MARK: - Mounting only from the presentations (no local host)

    func test_theSheetMountsOnlyFromThePresentationsNeverFromARow() throws {
        let binderSource = try CanvasSourceCensus.source(at: "Maugham/Views/BinderView.swift")
        XCTAssertFalse(binderSource.contains("ResearchLinkPickerSheet("),
                       "the row's whole job is setting linkPickerDocumentId — "
                       + "a sheet inside a lazy List is presented from a view "
                       + "the list may unmount")

        let sectionsSource = try CanvasSourceCensus.source(
            at: "Maugham/Views/BinderTreeSections.swift")
        XCTAssertTrue(sectionsSource.contains("ResearchLinkPickerSheet("),
                      "the presentations modifier is where it must mount")
    }

    /// The deleted original's whole defect in one line — planted here as a
    /// direct source check beside the behavioural proof above, so a future
    /// edit that reintroduces `try?` fails immediately rather than only when
    /// someone happens to break disk permissions in a test.
    func test_noTryQuestionMarkSurvivesInTheRestoredSheet() throws {
        let source = try CanvasSourceCensus.source(
            at: "Maugham/Views/ResearchLinkPickerSheet.swift")
        // Comments stripped: the type's own doc comment discusses the
        // deleted `try?` by name, and a naive scan over raw text would trip
        // on its own explanation rather than on code.
        let code = CanvasSourceCensus.commentsStripped(source)
        XCTAssertFalse(code.contains("try?"),
                       "the deleted sheet swallowed linkResearch/unlinkResearch "
                       + "with try? — this file must route through `perform` "
                       + "instead")
    }

    // MARK: - Fixtures

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    private func collection() async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    private func screenplay() async throws -> ProjectStore {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "Screenplay-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    /// Every fixture opens a `DocumentStore`: the research creators write
    /// through the typed mover and refuse outright without one.
    private func furnish(_ store: ProjectStore) async throws -> ProjectStore {
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return store
    }

    // MARK: - Hosting and driving (BinderView only — the one host this task touches)

    private func hostBinder(
        store: ProjectStore, state: BinderTreeSectionsState
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            LinkPickerBinderProbeView(store: store, probe: probe, treeState: state)))
        return (window, probe)
    }

    private func mount(_ root: AnyView) async throws -> NSWindow {
        let window = TestWindow.mount(root, size: CGSize(width: 320, height: 800),
                                      as: SilentTestWindow.self)
        windows.append(window)
        await pumpUntil(deadline: 5) { self.outlineView(in: window) != nil }
        pump(0.2)
        return window
    }

    private func outlineView(in window: NSWindow) -> NSOutlineView? {
        guard let root = window.contentView else { return nil }
        var found: [NSOutlineView] = []
        collect(NSOutlineView.self, in: root, into: &found)
        return found.first
    }

    private func isExpandable(row: Int, in outline: NSOutlineView) throws -> Bool {
        let item = try XCTUnwrap(outline.item(atRow: row),
                                 "no row \(row) in a list of \(outline.numberOfRows)")
        return outline.isExpandable(item)
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}

// MARK: - Probe

@MainActor
private struct LinkPickerBinderProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let treeState: BinderTreeSectionsState

    var body: some View {
        BinderView(store: store,
                   selectedSubject: Binding(get: { probe.subject },
                                            set: { probe.subject = $0 }),
                   treeState: treeState)
    }
}
