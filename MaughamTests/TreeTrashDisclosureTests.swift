import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// **Trash becomes a disclosure at the tree's foot** (shell-finish stage 2b
/// Task 2) — the segment strip's Trash entry is gone (nothing offers it, and
/// after this task nothing selects it either); a writer browses and restores
/// what they deleted from a `DisclosureGroup` mounted below the tree in every
/// persona instead, present only while there is something in it.
///
/// **The first mounted trash coverage in the suite** — the pre-task census
/// found none. Two mounts do the work: `TrashDisclosure` on its own, with the
/// expand flag hoisted into a `Binding` so a test can drive it directly
/// instead of pressing a `DisclosureGroup`'s AX triangle (an interaction this
/// codebase has no proven idiom for); and the real `BinderPaneToggle`/
/// `CollectionBinderPaneToggle` production wiring, for the contracts that are
/// about the WHOLE toggle rather than the disclosure alone (the segment truly
/// unreachable, the subject untouched, ⌘⌥Z with the disclosure in the tree).
@MainActor
final class TreeTrashDisclosureTests: XCTestCase {

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

    // MARK: - The disclosure's own content: row-count deltas

    /// **Reuse, not a fork.** `TrashDisclosure` wraps `TrashView` verbatim for
    /// its rows; this is the mounted proof that one trashed entry produces
    /// exactly one row through that wrapping.
    func test_theDisclosureShowsOneRowPerTrashedEntryOnceExpanded() async throws {
        let store = try await novelWithOneTrashedChapter().store
        let box = TrashDisclosureBox(isExpanded: true)
        let window = mountDisclosure(store: store, box: box)

        let table = try await waitForTable(in: window)
        XCTAssertEqual(table.numberOfRows, 1,
                       "one trashed entry, expanded, must show exactly one row")
    }

    /// **The contract's own wording**: "assert row-count deltas only" — not
    /// scroll position, which a `List` inside a `DisclosureGroup` gives no
    /// stable handle on anyway. Restoring the only entry must drop the count
    /// by exactly one, whichever of the three ways (restore-all, sweep, Empty
    /// Trash) got there.
    func test_restoringTheOnlyEntryDropsTheRowCountByOne() async throws {
        let (store, _) = try await novelWithOneTrashedChapter()
        let box = TrashDisclosureBox(isExpanded: true)
        let window = mountDisclosure(store: store, box: box)
        let table = try await waitForTable(in: window)
        let before = table.numberOfRows
        XCTAssertEqual(before, 1, "premise: one trashed entry")

        let id = try XCTUnwrap(store.trashEntries.first?.id)
        try await store.restoreTrashEntry(id: id)
        await pumpUntil(deadline: 5) { table.numberOfRows == before - 1 }

        XCTAssertEqual(table.numberOfRows, before - 1,
                       "restoring the only entry must drop the row count by exactly one")
    }

    /// The sweep's other exit: Permanently Delete, driven the same way.
    func test_permanentlyDeletingTheOnlyEntryDropsTheRowCountByOne() async throws {
        let (store, _) = try await novelWithOneTrashedChapter()
        let box = TrashDisclosureBox(isExpanded: true)
        let window = mountDisclosure(store: store, box: box)
        let table = try await waitForTable(in: window)
        let before = table.numberOfRows
        XCTAssertEqual(before, 1, "premise: one trashed entry")

        let id = try XCTUnwrap(store.trashEntries.first?.id)
        try await store.permanentlyDeleteTrashEntry(id: id)
        await pumpUntil(deadline: 5) { table.numberOfRows == before - 1 }

        XCTAssertEqual(table.numberOfRows, before - 1,
                       "permanently deleting the only entry must drop the row "
                       + "count by exactly one")
    }

    // MARK: - The disclosure itself: present only when there is something in it

    /// **The gate.** `!store.trashEntries.isEmpty` — the same expression the
    /// picker's dead `hasTrash` gate used — mounts and un-mounts the whole
    /// disclosure, not just its rows. Driven on the real toggle, both project
    /// shells: an empty trash must not even offer "Empty Trash".
    func test_theDisclosureMountsOnlyWhenTheTrashIsNotEmpty() async throws {
        for factory in [Self.standardToggle, Self.collectionToggle] {
            let store = try await factory.emptyProject(temp.url)
            let box = ToggleProbeBox()
            let window = mountToggle(store: store, box: box, shell: factory.shell)
            XCTAssertNil(try findButton(labeled: "Empty Trash", in: window),
                        "\(factory.shell): premise — nothing trashed yet, so no "
                        + "disclosure")

            let chapter = try XCTUnwrap(store.manifest.structure.first)
            try await store.deleteStructureItem(id: chapter.id)
            await waitOut(0.3)

            XCTAssertNotNil(try findButton(labeled: "Empty Trash", in: window),
                            "\(factory.shell): the disclosure must appear the "
                            + "moment something lands in the trash")
        }
    }

    /// The converse, and the actual "leaves no dead surface" protection that
    /// used to belong to the toggles' now-deleted `.onChange` arm
    /// (`TransientSegmentReturnTests`, before shell-finish stage 2b Task 2):
    /// emptying the trash removes the disclosure entirely rather than leaving
    /// an empty shell behind.
    func test_emptyingTheTrashRemovesTheDisclosureEntirely() async throws {
        let (store, _) = try await novelWithOneTrashedChapter()
        let box = ToggleProbeBox()
        let window = mountToggle(store: store, box: box, shell: .standard)
        XCTAssertNotNil(try findButton(labeled: "Empty Trash", in: window),
                        "premise: the disclosure is mounted")

        try await store.emptyTrash()
        await pumpUntil(deadline: 5) {
            (try? self.findButton(labeled: "Empty Trash", in: window, attempts: 1)) == nil
        }

        XCTAssertNil(try findButton(labeled: "Empty Trash", in: window),
                     "emptying the trash must remove the disclosure, not just its rows")
    }

    // MARK: - Trash rows write no subject

    /// **Browsing the trash never changes the centre.** Nothing in
    /// `TrashDisclosure`/`TrashView` touches `selectedSubject`; this is the
    /// mounted proof, driven through a real restore while the toggle (and the
    /// disclosure it grew) is on screen.
    func test_theSubjectHoldsWhileTheDisclosureIsOpenAndAnEntryIsRestored() async throws {
        let (store, _) = try await novelWithOneTrashedChapter()
        let box = ToggleProbeBox()
        box.subject = .item("sentinel-subject")
        let window = mountToggle(store: store, box: box, shell: .standard)
        XCTAssertNotNil(try findButton(labeled: "Empty Trash", in: window),
                        "premise: the disclosure is mounted and browsable")

        let id = try XCTUnwrap(store.trashEntries.first?.id)
        try await store.restoreTrashEntry(id: id)
        await pumpUntil(deadline: 5) { store.trashEntries.isEmpty }

        XCTAssertEqual(box.subject, .item("sentinel-subject"),
                       "browsing or restoring from the trash must never write "
                       + "the window's subject")
    }

    // MARK: - A restore's report reaches the writer (final review's I1)

    /// **The exposure, mounted.** RULING-42 says a restore that gives back less
    /// than was deleted must name the shortfall *at the moment of the restore* —
    /// and the restore most in need of saying it is the one that empties the
    /// trash, because `restoreTrashEntry` re-lists before it returns and both
    /// toggles mount the disclosure only while `!trashEntries.isEmpty`. So the
    /// row's own host is gone in the same pass, and an alert attached to it
    /// never presents.
    ///
    /// This is the falsifier for routing the message upwards: it asserts the
    /// disclosure is unmounted after the restore, which is what makes any alert
    /// hosted down here unshowable rather than merely inelegant.
    func test_restoringTheLastEntryTakesTheRowsHostDownWithIt() async throws {
        let (store, _) = try await novelWithOneTrashedChapter()
        let box = ToggleProbeBox()
        let window = mountToggle(store: store, box: box, shell: .standard)
        XCTAssertNotNil(try findButton(labeled: "Empty Trash", in: window),
                        "premise: the disclosure — and the rows inside it — are mounted")

        let id = try XCTUnwrap(store.trashEntries.first?.id)
        try await store.restoreTrashEntry(id: id)
        await pumpUntil(deadline: 5) {
            (try? self.findButton(labeled: "Empty Trash", in: window, attempts: 1)) == nil
        }

        XCTAssertNil(try findButton(labeled: "Empty Trash", in: window),
                     "restoring the last entry unmounts the disclosure, so nothing "
                     + "hosted inside it can present a shortfall message — which is "
                     + "why the report has to travel to the window's own sink")
    }

    /// **The row's Restore reports upwards**, driven through the exact function
    /// its button calls (`TrashView.restore` is a `static` for that reason — a
    /// `contextMenu` button is not reachable headlessly).
    ///
    /// The shortfall is real rather than stubbed: the trashed note's own path is
    /// taken by a new note of the same name before the restore, so it comes back
    /// renamed and `TrashRestoreReport.message` says so (RULING-38's relocation).
    /// And it is the trash's LAST entry, so this is the exposure above.
    func test_theRowsRestoreReportsItsShortfallToTheCaller() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Ships")
        try await store.deleteResearchItem(id: note.id)
        // Something else takes the file's place while it is in the trash.
        _ = try await store.addResearchTextNote(parentId: nil, title: "Ships")
        let entry = try XCTUnwrap(store.trashEntries.first,
                                  "premise: exactly one thing in the trash")

        var reported: [String] = []
        await TrashView.restore(entry: entry, store: store,
                                report: { reported.append($0) })

        XCTAssertTrue(store.trashEntries.isEmpty,
                      "premise: this restore emptied the trash, so the row that "
                      + "started it is gone")
        XCTAssertEqual(reported.count, 1,
                       "the restore came back with a shortfall and said it exactly "
                       + "once — got \(reported)")
        XCTAssertTrue(reported.first?.contains("Ships") == true,
                      "and the message names what could not come back as it was: "
                      + "\(reported)")
    }

    /// **One sink, both restore paths.** The window's `restoreOutcome` alert is
    /// mounted unconditionally, so it is the only place either restore can say
    /// anything from — asserted at the wiring, because the alternative (a second
    /// alert somewhere down the column) is exactly what this fix removed.
    func test_bothTogglesRouteTheRestoreReportToTheWindowsOwnSink() throws {
        for path in ["Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("onRestoreOutcome: onRestoreOutcome"),
                          "\(path): the disclosure must be handed the window's "
                          + "reporter, or a shortfall has nowhere to go")
        }
        let window = try source("Maugham/Views/ProjectWindow.swift")
        XCTAssertEqual(
            window.components(separatedBy: "onRestoreOutcome: { restoreOutcome = $0 }")
                .count - 1, 2,
            "both binder shells must point at `restoreOutcome` — the ⌘⌥Z sink, "
            + "which is the alert mounted whatever the trash contains")
        let trash = try source("Maugham/Views/TrashView.swift")
        XCTAssertFalse(trash.contains("restoreShortfall"),
                       "the row-local shortfall alert is back — it cannot present "
                       + "for the restore that empties the trash")
    }

    // MARK: - ⌘⌥Z restore-last-deleted, with the disclosure mounted

    /// The `.maughamRestoreLastDeleted` handler in
    /// `ProjectWindow.SessionAndNavigationModifier`, untouched by this task —
    /// this is the regression net proving it still reaches the store with the
    /// foot disclosure in the tree instead of the old picker segment.
    func test_cmdOptZRestoresTheLastDeletedWithTheDisclosureMounted() async throws {
        let (store, chapterId) = try await novelWithOneTrashedChapter()
        let box = ToggleProbeBox()
        _ = mountToggle(store: store, box: box, shell: .standard, keyed: true)
        XCTAssertEqual(store.trashEntries.count, 1, "premise: one trashed chapter")

        MaughamEvent.post(.maughamRestoreLastDeleted, to: .keyWindow)
        await pumpUntil(deadline: 5) { store.trashEntries.isEmpty }

        XCTAssertTrue(store.trashEntries.isEmpty,
                      "⌘⌥Z did not reach restoreLastDeletion with the disclosure mounted")
        XCTAssertEqual(store.manifest.structure.count, 1,
                       "the restored chapter did not come back into the manifest")
        XCTAssertEqual(store.manifest.structure.first?.id, chapterId)
    }

    // MARK: - Census: the dead arms are gone

    // **The spelling census that stood here died with the strip it guarded**
    // (stage 2b Task 7). It asked, with a planted offender, that nothing wrote
    // `binderSegment = .trash` across three files. `BinderSegment` and the
    // window's `binderSegment` state were deleted together, so the offender
    // cannot be spelled and the compiler is the enforcement. What survives is
    // the half a spelling check never covered — the ARMS below, each of which
    // could be deleted or resurrected without leaving a wrong spelling behind.

    /// The dead transient-exit arm, by name rather than by pattern: deleting
    /// it outright leaves no wrong spelling behind for the census above to
    /// find, so each toggle is asked whether the `.onChange` it used to carry
    /// is still there.
    func test_theTrashEmptiedOnChangeArmIsGoneFromBothToggles() throws {
        for path in ["Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.contains(".onChange(of: store.trashEntries.count)"),
                           "\(path): the trash-emptied .onChange arm should have "
                           + "died with shell-finish stage 2b Task 2 — nothing "
                           + "selects `.trash` any more, so there is nothing left "
                           + "to eject anyone from")
        }
    }

    /// The other dead arm: neither toggle may put a `TrashView` in the column
    /// itself. That was the segment arm's job, and rendering it there beside the
    /// foot disclosure is the duplicate that fix round 1 caught. The disclosure
    /// is Trash's whole home now.
    ///
    /// **This replaces the picker's own half** (`hasTrash: false`, asked of both
    /// call sites), which went with `BinderSegmentPicker` in Task 7.
    func test_neitherToggleMountsTrashInTheColumnItself() throws {
        for path in ["Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.contains("TrashView("),
                           "\(path): the column mounts TrashView directly again "
                           + "— that is the duplicate main-area list fix round 1 "
                           + "removed, beside the correct foot disclosure")
            XCTAssertTrue(text.contains("TrashDisclosure("),
                          "\(path): the foot disclosure is gone, so a writer "
                          + "cannot reach their trash at all")
        }
    }

    /// **The relocation, named.** `TrashView` no longer carries a window
    /// toolbar at all — "Empty Trash" lives only in `TrashDisclosure`'s header
    /// row now, which has no toolbar to put it on.
    func test_theWindowToolbarNoLongerOffersEmptyTrash() throws {
        let text = try source("Maugham/Views/TrashView.swift")
        XCTAssertFalse(text.contains(".toolbar"),
                       "TrashView must not carry a toolbar any more — Empty "
                       + "Trash moved into TrashDisclosure's header row")
        let trashViewBody = try XCTUnwrap(
            text.range(of: "struct TrashView"), "TrashView type not found").lowerBound
        let trashViewText = text[trashViewBody...]
        XCTAssertFalse(trashViewText.contains("ToolbarItem"),
                       "a ToolbarItem survives inside TrashView")
    }

    // MARK: - Fix round 1's two restore tests, and where the guarantee went

    // **Both died with `ProjectWindow.binderSegment(restoring:)`** (stage 2b
    // Task 7). The Critical they pinned was a relaunch: a writer who last quit
    // with Trash selected had `.trash` in persisted `UIState`, the picker's
    // append-if-selected fallback re-admitted a phantom Trash tab even with
    // `hasTrash: false`, and the `.trash` switch arm rendered the same rows a
    // SECOND time in the main area beside the correct foot disclosure. One test
    // asked the coercion over every persona × project type; the other mounted
    // the restored toggle against a control and compared table counts.
    //
    // There is no persisted left-column choice left to restore, no picker to
    // re-admit a tab into, and no switch arm to render a second list — the
    // duplicate is not expressible. `UIStateTests`
    // `.test_everyLegacyBinderSegmentValueDecodesAwayWithoutCost` is where the
    // legacy value's fate is pinned now, and
    // `test_neitherToggleMountsTrashInTheColumnItself` above is what stops the
    // second list coming back by another route.

    // MARK: - Fixtures

    private func novelWithOneTrashedChapter() async throws -> (store: ProjectStore, chapterId: String) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let chapter = try XCTUnwrap(store.manifest.structure.first,
                                    "premise: a fresh novel project ships one chapter")
        try await store.deleteStructureItem(id: chapter.id)
        return (store, chapter.id)
    }

    /// Which `BinderPaneToggle`/`CollectionBinderPaneToggle` shell a project
    /// type routes through, and how to build an empty (nothing trashed yet)
    /// fixture of it — the two shells the toggles fan out over.
    private struct ToggleFactory {
        let shell: ProjectWindow.BinderShell
        let emptyProject: (URL) async throws -> ProjectStore
    }

    private static let standardToggle = ToggleFactory(shell: .standard) { root in
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: root)
        return try await ProjectStore.load(from: url)
    }

    private static let collectionToggle = ToggleFactory(shell: .collection) { root in
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: root)
        let store = try await ProjectStore.load(from: url)
        _ = try await store.addLoosePiece(title: "Piece", mode: .prose)
        return store
    }

    // MARK: - Mounting

    private func mountDisclosure(store: ProjectStore, box: TrashDisclosureBox) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(TrashDisclosureProbeView(store: store, box: box)),
            size: CGSize(width: 320, height: 400),
            as: SilentTestWindow.self)
        windows.append(window)
        pump(0.15)
        return window
    }

    private func mountToggle(store: ProjectStore, box: ToggleProbeBox,
                             shell: ProjectWindow.BinderShell,
                             persona: Persona = .author,
                             keyed: Bool = false) -> NSWindow {
        let view = AnyView(
            BinderToggleTrashProbeView(store: store, box: box, shell: shell,
                                       persona: persona))
        let size = CGSize(width: 320, height: 700)
        // `keyed` mounts in a `KeyTestWindow`, which reports itself key, for the
        // ⌘⌥Z test: `.maughamRestoreLastDeleted` is key-window scoped and a
        // window hosted by `xcodebuild`'s test host never becomes key on its own
        // — `TreeFindOverlayTests.host`'s reason exactly.
        let window: NSWindow = keyed
            ? TestWindow.mount(view, size: size, as: KeyTestWindow.self)
            : TestWindow.mount(view, size: size, as: SilentTestWindow.self)
        windows.append(window)
        // Set BEFORE the settling pump, not after: `.onKeyWindowCommand`'s
        // closure captures whatever `box.window` was at the body evaluation it
        // was attached from, so a caller setting it only after this returns
        // races the re-render that would pick it up — `TreeFindOverlayTests
        // .host`'s exact reason for doing the same.
        box.window = window
        pump(0.2)
        return window
    }

    private func waitForTable(in window: NSWindow) async throws -> NSTableView {
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        return try XCTUnwrap(firstTableView(in: window),
                             "the disclosure's row list never mounted")
    }

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.first
    }

    /// The duplicate-detector for fix round 1's Critical: a relaunch-restored
    /// `.trash` that leaked back into `segment` would mount a SECOND
    /// `NSTableView` (the `.trash` switch arm's own `TrashView`) alongside the
    /// tree's own — a count comparison against a control mount catches that
    /// without caring which table is which.
    private func tableViewCount(in window: NSWindow) -> Int {
        guard let root = window.contentView else { return 0 }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.count
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    // MARK: - Reading the accessibility tree

    /// `TreeFindOverlayTests.closeButton`'s shape, generalized to any label:
    /// skips (rather than fails) when no assistive client can attach to this
    /// process at all, and retries because SwiftUI builds its accessibility
    /// tree lazily. Returns `nil` — a real, asserted absence — when a client
    /// IS attached and the button genuinely is not there.
    private func findButton(labeled label: String, in window: NSWindow,
                            attempts: Int = 10) throws -> NSObject? {
        for _ in 0..<attempts {
            let tree = try axTree(in: window)
            if let hit = tree.first(where: {
                (axAttribute($0, "accessibilityRole") as? String) == "AXButton"
                    && ((axAttribute($0, "accessibilityLabel") as? String) ?? "")
                        .contains(label)
            }) as? NSObject {
                return hit
            }
            pump(0.1)
        }
        return nil
    }

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so "
                + "SwiftUI builds no accessibility tree to find a button in")
        }
        guard let root = window.contentView else { return [] }
        return axElements(under: root)
    }

    // MARK: - Source

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }
}

// MARK: - Boxes and probes

/// The disclosure's expand/collapse flag, outside the view — `TrashDisclosure`
/// takes it as a `Binding` precisely so a test can drive it directly instead
/// of pressing a `DisclosureGroup`'s AX triangle. At file scope because
/// `@Observable` cannot expand inside a `private` nested type.
@Observable
@MainActor
final class TrashDisclosureBox {
    var isExpanded: Bool
    init(isExpanded: Bool) { self.isExpanded = isExpanded }
}

@MainActor
private struct TrashDisclosureProbeView: View {
    let store: ProjectStore
    let box: TrashDisclosureBox

    var body: some View {
        TrashDisclosure(store: store, isExpanded: Binding(
            get: { box.isExpanded }, set: { box.isExpanded = $0 }))
    }
}

/// The window facts the full-toggle probes need to read back — the subject a
/// row interaction may or may not have written, and (for the ⌘⌥Z test) the
/// real hosting window `.keyWindow`-scoped posts are filtered against.
@Observable
@MainActor
final class ToggleProbeBox {
    var subject: BinderSubject?
    var window: NSWindow?
}

/// The left column as `ProjectWindow.binderShell` builds it, for either
/// project shell, plus the one receiver `⌘⌥Z` needs — the same
/// `store.restoreLastDeletion()` call the window's
/// `.maughamRestoreLastDeleted` handler makes.
@MainActor
private struct BinderToggleTrashProbeView: View {
    let store: ProjectStore
    let box: ToggleProbeBox
    let shell: ProjectWindow.BinderShell
    let persona: Persona
    @State private var renamingItemId: String?

    private var subject: Binding<BinderSubject?> {
        Binding(get: { box.subject }, set: { box.subject = $0 })
    }

    let treeState = BinderTreeSectionsState()

    var body: some View {
        Group {
            switch shell {
            case .standard:
                BinderPaneToggle(
                    store: store,
                    selectedSubject: subject,
                    projectType: store.manifest.type,
                    lastParsedScript: nil,
                    treeState: treeState,
                    treeFindActive: .constant(false),
                    persona: persona)
            case .collection:
                CollectionBinderPaneToggle(
                    store: store,
                    selectedSubject: subject,
                    treeFindActive: .constant(false),
                    renamingItemId: $renamingItemId,
                    treeState: treeState,
                    persona: persona)
            }
        }
        .onKeyWindowCommand(.maughamRestoreLastDeleted, window: box.window) { _ in
            Task {
                // Mirrors production's handler (ProjectWindow's
                // .maughamRestoreLastDeleted arm) post-merge: the store verb is
                // restoreLastDeletion() -> TrashRestoreReport?; the fixture
                // discards the report because this suite asserts tree/row
                // state, not the RULING-40/42 surfacing (production's toast).
                _ = try? await store.restoreLastDeletion()
            }
        }
    }
}
