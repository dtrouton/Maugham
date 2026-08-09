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

    // MARK: - ⌘⌥Z restore-last-deleted, with the disclosure mounted

    /// `ProjectWindow.swift:679-683`'s handler, untouched by this task —
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
                      "⌘⌥Z did not reach restoreLastDeleted with the disclosure mounted")
        XCTAssertEqual(store.manifest.structure.count, 1,
                       "the restored chapter did not come back into the manifest")
        XCTAssertEqual(store.manifest.structure.first?.id, chapterId)
    }

    // MARK: - Census: nothing selects `.trash`, and the dead arms are gone

    /// **The half a mounted probe cannot see.** `TreeFindOverlayTests`'
    /// `test_nothingInTheWindowSelectsTheFindSegment` is the pattern: the
    /// offending spelling is asked for by name, with a planted offender
    /// proving the pattern still matches something.
    func test_nothingWritesTheTrashSegment() throws {
        let pattern = #"(?:binderSegment|segment) = \.trash\b"#
        XCTAssertNotNil(
            "                    binderSegment = .trash"
                .range(of: pattern, options: .regularExpression),
            "the pattern no longer matches its own planted offender, so the "
            + "census below is vacuous")

        for path in ["Maugham/Views/ProjectWindow.swift",
                     "Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.isEmpty, "\(path): read nothing")
            let hits = text.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && $0.range(of: pattern, options: .regularExpression) != nil
            }
            XCTAssertTrue(hits.isEmpty,
                          "\(path): something still selects the trash segment — "
                          + "\(hits). Trash is a foot disclosure; nothing writes "
                          + "`.trash` any more.")
        }
    }

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

    /// The picker's own half: it must never offer Trash again, in either
    /// toggle — the disclosure is Trash's whole home now.
    func test_thePickerNeverOffersTrash() throws {
        for path in ["Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("hasTrash: false"),
                          "\(path): the picker must be handed a constant `false` "
                          + "for `hasTrash` — it never offers Trash any more")
            XCTAssertFalse(text.contains("hasTrash: !store.trashEntries.isEmpty"),
                           "\(path): the old live trash gate must not survive "
                           + "alongside the constant one")
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
        let frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        let hosting = NSHostingView(rootView: AnyView(
            TrashDisclosureProbeView(store: store, box: box)))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.15)
        return window
    }

    private func mountToggle(store: ProjectStore, box: ToggleProbeBox,
                             shell: ProjectWindow.BinderShell,
                             keyed: Bool = false) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        let hosting = NSHostingView(rootView: AnyView(
            BinderToggleTrashProbeView(store: store, box: box, shell: shell)))
        hosting.frame = frame
        let window: NSWindow = keyed
            ? KeyTestWindow(contentRect: frame, styleMask: [.titled],
                            backing: .buffered, defer: false)
            : SilentTestWindow(contentRect: frame, styleMask: [.titled],
                               backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
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

    /// A window that reports itself key, for the ⌘⌥Z test —
    /// `TreeFindOverlayTests.KeyTestWindow`'s twin, needed for the same
    /// reason: `.maughamRestoreLastDeleted` is key-window scoped and a window
    /// hosted by `xcodebuild`'s test host never becomes key on its own.
    private final class KeyTestWindow: SilentTestWindow {
        override var isKeyWindow: Bool { true }
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

/// The left column as `ProjectWindow.binderColumn` builds it, for either
/// project shell, plus the one receiver `⌘⌥Z` needs — the same
/// `store.restoreLastDeleted()` call `ProjectWindow.swift:689-692` makes.
@MainActor
private struct BinderToggleTrashProbeView: View {
    let store: ProjectStore
    let box: ToggleProbeBox
    let shell: ProjectWindow.BinderShell
    @State private var segment: BinderSegment = .manuscript
    @State private var researchId: String?
    @State private var paletteCardId: String?
    @State private var renamingItemId: String?

    private var subject: Binding<BinderSubject?> {
        Binding(get: { box.subject }, set: { box.subject = $0 })
    }

    var body: some View {
        Group {
            switch shell {
            case .standard:
                BinderPaneToggle(
                    store: store,
                    segment: $segment,
                    selectedSubject: subject,
                    selectedResearchId: $researchId,
                    selectedPaletteCardId: $paletteCardId,
                    projectType: store.manifest.type,
                    lastParsedScript: nil,
                    treeFindActive: .constant(false),
                    persona: .author)
            case .collection:
                CollectionBinderPaneToggle(
                    store: store,
                    segment: $segment,
                    selectedSubject: subject,
                    selectedResearchId: $researchId,
                    selectedPaletteCardId: $paletteCardId,
                    treeFindActive: .constant(false),
                    renamingItemId: $renamingItemId,
                    activePiece: nil,
                    onAddSharedNote: {},
                    onAddPieceNote: {},
                    persona: .author)
            }
        }
        .onKeyWindowCommand(.maughamRestoreLastDeleted, window: box.window) { _ in
            Task {
                try? await store.restoreLastDeleted()
            }
        }
    }
}
