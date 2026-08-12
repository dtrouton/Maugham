import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// **Find's full arrival posture — both of `matchSubject`'s arms scroll**
/// (shell-finish stage-3b Task 8, spec's design call 5).
///
/// `TreeFindOverlayTests` already pins that a match click writes the window's
/// SUBJECT and that the overlay stays up across the click; this suite is the
/// scroll half beside it, both the pure routing (`ProjectWindow
/// .findMatchScrollTarget`, `matchSubject`'s own twin) and the mounted,
/// end-to-end case: a request queued while the overlay covers the tree, then
/// consumed once the tree remounts underneath it.
@MainActor
final class FindMatchScrollTests: XCTestCase {

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

    // MARK: - The pure routing, both arms

    /// **The research arm gets `openResearchItem`'s own shape**: `reveal`
    /// opens whatever holds the item, and the scroll target is what it
    /// returned.
    func test_aResearchMatchRevealsAndScrollsToItsOwnRow() async throws {
        let store = try await novel(notes: [])
        let outer = try await store.addResearchItem(
            parentId: nil, title: "World", kind: nil)
        let note = try await store.addResearchTextNote(
            parentId: outer.id, title: "Harbour")
        let state = BinderTreeSectionsState()
        state.researchSectionExpanded = false

        let target = ProjectWindow.findMatchScrollTarget(
            for: .research(note.id), store: store, treeState: state)

        XCTAssertEqual(target, .row(.research(note.id)))
        XCTAssertTrue(state.researchSectionExpanded,
                      "the research arm reveals the section the item lives in")
        XCTAssertTrue(state.expandedResearchGroups.contains(outer.id),
                      "and every group between the item and the root")
    }

    /// **A manuscript match's row is never behind anything closable** —
    /// `reveal` only opens research furniture, never a structural group — so
    /// it scrolls straight to its own tag with no reveal at all.
    func test_aManuscriptMatchScrollsStraightToItsOwnRowWithNoReveal() async throws {
        let store = try await novel(notes: [])
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let state = BinderTreeSectionsState()

        let target = ProjectWindow.findMatchScrollTarget(
            for: .item(chapter.id), store: store, treeState: state)

        XCTAssertEqual(target, .row(.item(chapter.id)))
        XCTAssertTrue(state.expandedResearchGroups.isEmpty,
                      "a structure row has nothing for `reveal` to open")
        XCTAssertTrue(state.researchSectionExpanded,
                      "premise unchanged: nothing here touches research state")
    }

    /// A stale research match — the id left the manifest between the search
    /// and the click — reveals nothing and scrolls nowhere, `matchSubject`'s
    /// own `nil` carried one step further.
    func test_aStaleResearchMatchScrollsNowhere() async throws {
        let store = try await novel(notes: [])
        let state = BinderTreeSectionsState()

        let target = ProjectWindow.findMatchScrollTarget(
            for: .research("no-such-item"), store: store, treeState: state)

        XCTAssertNil(target, "an id no tree holds names no row to scroll to")
    }

    // MARK: - Mounted: the overlay stays up, the scroll lands after it closes

    /// **The full delivery path** — the real `.maughamFindMatchSelected`
    /// receiver, mirrored with the scroll write it gains in this task, over a
    /// tree pushed tall enough that the target row starts off-screen. The
    /// overlay REPLACES the column while it is up (`BinderPaneToggle`), so
    /// the request sits queued until Escape hands the tree back — the mount
    /// trigger (`.task`) is what consumes it, not `.onChange`.
    func test_aResearchMatchClickScrollsTheRowOnScreenOnceTheOverlayCloses() async throws {
        let store = try await novel(notes: [], extraChapters: 60)
        let note = try await store.addResearchTextNote(
            parentId: nil, title: "Harbour")
        let path = try XCTUnwrap(note.path)

        let box = FindMatchScrollBox(treeFindActive: true)
        let window = host(box, FindMatchScrollProbeView(store: store, box: box))
        await pumpUntil(deadline: 5) { self.queryField(in: window) != nil }
        XCTAssertNil(firstTableView(in: window),
                     "premise: the overlay replaces the tree, so there is no "
                     + "mounted List to scroll yet")

        MaughamEvent.post(.maughamFindMatchSelected, to: .keyWindow,
                          payload: ["match": Self.match(at: path, source: .research)])
        await pumpUntil(deadline: 5) { box.subject == .research(note.id) }

        XCTAssertEqual(box.subject, .research(note.id),
                       "the click wrote the window's subject")
        XCTAssertTrue(box.treeFindActive,
                      "the overlay stays up across a match click — no "
                      + "`applyCloseFind` in this handler")
        XCTAssertEqual(box.treeState.scrollRequest, .row(.research(note.id)),
                       "the scroll request is queued while the overlay "
                       + "covers the tree, with nothing mounted to consume it")

        ProjectSearchView.close()
        await pumpUntil(deadline: 5) { !box.treeFindActive }
        let remounted = await eventualTableView(in: window)
        let table = try XCTUnwrap(remounted,
                                  "the tree did not remount once the overlay closed")

        await pumpUntil(deadline: 5) { box.treeState.scrollRequest == nil }
        XCTAssertNil(box.treeState.scrollRequest,
                     "the tree's own mount signal must consume a request that "
                     + "was queued while it was not on screen")
        // project row, sixty-one chapters, then the Research header and note.
        let noteRow = 1 + store.manifest.structure.count + 1
        await pumpUntil(deadline: 5) { self.isRowVisible(noteRow, in: table) }
        XCTAssertTrue(isRowVisible(noteRow, in: table),
                      "the queued request must land once the tree is back")
    }

    /// **The manuscript arm's twin** — its row scrolls too, and the overlay
    /// still stays up. The editor's own text scroll is a separate observer
    /// (`EditorCoordinator`'s) and is not this suite's concern.
    func test_aManuscriptMatchClickScrollsItsRowAndLeavesTheOverlayUp() async throws {
        let store = try await novel(notes: [], extraChapters: 60)
        let chapter = try XCTUnwrap(store.manifest.structure.last)

        let box = FindMatchScrollBox(treeFindActive: true)
        let window = host(box, FindMatchScrollProbeView(store: store, box: box))
        await pumpUntil(deadline: 5) { self.queryField(in: window) != nil }

        MaughamEvent.post(.maughamFindMatchSelected, to: .keyWindow,
                          payload: ["match": Self.match(at: chapter.path ?? "",
                                                        source: .manuscript)])
        await pumpUntil(deadline: 5) { box.subject == .item(chapter.id) }

        XCTAssertEqual(box.subject, .item(chapter.id))
        XCTAssertTrue(box.treeFindActive, "the overlay stays up here too")
        XCTAssertEqual(box.treeState.scrollRequest, .row(.item(chapter.id)))

        ProjectSearchView.close()
        await pumpUntil(deadline: 5) { !box.treeFindActive }
        let remounted = await eventualTableView(in: window)
        let table = try XCTUnwrap(remounted)

        let chapterRow = 1 + store.manifest.structure.count - 1
        await pumpUntil(deadline: 5) { self.isRowVisible(chapterRow, in: table) }
        XCTAssertTrue(isRowVisible(chapterRow, in: table),
                      "the manuscript match's row must land too, not just "
                      + "the research arm's")
    }

    // MARK: - Fixtures

    private func novel(notes: [String], extraChapters: Int = 0) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        for i in 0..<extraChapters {
            _ = try await store.addStructureItem(
                parentId: nil, title: "Chapter \(i + 2)",
                kind: .document(extension: "md"))
        }
        for title in notes {
            _ = try await store.addResearchTextNote(parentId: nil, title: title)
        }
        await store.wordCountPopulationTask?.value
        return store
    }

    private static func match(at path: String,
                              source: SearchDocumentSource) -> SearchMatch {
        SearchMatch(documentPath: path, documentTitle: "Found",
                    documentSource: source, lineNumber: 1,
                    charRangeInDocument: NSRange(location: 0, length: 4),
                    linePreview: "loud", matchRangeInLine: NSRange(location: 0, length: 4))
    }

    // MARK: - Hosting

    /// A window that reports itself key — `TreeFindOverlayTests.KeyTestWindow`'s
    /// twin, needed for the same reason: `.maughamFindMatchSelected` and
    /// `.maughamCloseFind` are both key-window scoped.
    private final class KeyTestWindow: SilentTestWindow {
        override var isKeyWindow: Bool { true }
    }

    private func host(_ box: FindMatchScrollBox, _ view: some View) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = frame
        let window = KeyTestWindow(contentRect: frame, styleMask: [.titled],
                                   backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        box.window = window
        pump(0.15)
        return window
    }

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.first
    }

    /// The tree's table only exists once the overlay has actually been
    /// replaced by it — a turn or two after `treeFindActive` flips.
    private func eventualTableView(in window: NSWindow) async -> NSTableView? {
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        return firstTableView(in: window)
    }

    private func queryField(in window: NSWindow) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        var found: [NSTextField] = []
        collect(NSTextField.self, in: root, into: &found)
        return found.first { $0.placeholderString == "Find in project" }
    }

    /// **Whether `row` is actually on screen** — `documentVisibleRect` is the
    /// scroll view's own answer, distinct from `numberOfRows`'s "the row
    /// exists".
    private func isRowVisible(_ row: Int, in table: NSTableView) -> Bool {
        guard row >= 0, row < table.numberOfRows,
              let scrollView = table.enclosingScrollView else { return false }
        return scrollView.documentVisibleRect.intersects(table.rect(ofRow: row))
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}

/// The window state this suite drives and reads — `FindOverlayBox`'s twin in
/// `TreeFindOverlayTests`, widened with `treeState` so the mirrored handler
/// below can write the scroll request the real one does.
@Observable
@MainActor
private final class FindMatchScrollBox {
    var treeFindActive: Bool
    var subject: BinderSubject?
    let treeState = BinderTreeSectionsState()
    var window: NSWindow?
    init(treeFindActive: Bool) { self.treeFindActive = treeFindActive }
}

/// The left column, plus the find-close receiver and a MIRROR of
/// `.maughamFindMatchSelected` carrying this task's scroll write — spelled
/// exactly as `ProjectWindow`'s own handler, so the rule under test is
/// production's rule rather than a copy that could drift from it.
@MainActor
private struct FindMatchScrollProbeView: View {
    let store: ProjectStore
    let box: FindMatchScrollBox

    private var treeFindActive: Binding<Bool> {
        Binding(get: { box.treeFindActive }, set: { box.treeFindActive = $0 })
    }

    private var subject: Binding<BinderSubject?> {
        Binding(get: { box.subject }, set: { box.subject = $0 })
    }

    var body: some View {
        BinderPaneToggle(
            store: store,
            selectedSubject: subject,
            projectType: store.manifest.type,
            lastParsedScript: nil,
            treeState: box.treeState,
            treeFindActive: treeFindActive,
            persona: .author)
        .onKeyWindowCommand(.maughamCloseFind, window: box.window) { _ in
            ProjectWindow.applyCloseFind(treeFindActive: &box.treeFindActive,
                                         store: store)
        }
        .onKeyWindowCommand(.maughamFindMatchSelected, window: box.window) { note in
            guard let match = note.userInfo?["match"] as? SearchMatch,
                  let subject = ProjectWindow.matchSubject(match, in: store)
            else { return }
            box.subject = subject
            box.treeState.scrollRequest = ProjectWindow.findMatchScrollTarget(
                for: subject, store: store, treeState: box.treeState)
        }
    }
}
