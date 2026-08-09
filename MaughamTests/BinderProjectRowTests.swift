import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// Holds the binder's selection outside the view, so a test can watch what a
/// real selection on a real row writes through the real binding.
@Observable
@MainActor
final class BinderSubjectProbe {
    var subject: BinderSubject?
    init(_ subject: BinderSubject? = nil) { self.subject = subject }
}

/// `BinderView` with its selection bound to a probe — the binder as
/// `BinderPaneToggle` mounts it, with a handle on the value it writes.
@MainActor
private struct BinderProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe

    var body: some View {
        BinderView(
            store: store,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }))
    }
}

/// The project row at the head of the binder (spec §3.3).
///
/// **Mounted, not reasoned about.** The row's entire implementation is a label
/// and a `.tag`, so the only thing that can be wrong is whether
/// `List(selection:)` matches that tag — which is exactly what a test built out
/// of the view's own data cannot see. M1A's lesson: 22 green undo tests once sat
/// on a ⌘Z that could not reach the stack. So these drive the `NSTableView`
/// SwiftUI's own mounting produced and read the binding on the other side.
///
/// **What a mounted SwiftUI row will not tell you, measured here on 2026-08-01
/// (macOS 26.5) so the next person does not spend the afternoon on it:** the
/// string a `Text` draws is not readable from outside. A row's subtree is
/// `ListTableRowView → ListTableCellView → CellHostingView` and contains no
/// `NSTextField` at all, and the accessibility tree is not built in this test
/// host — every `accessibilityLabel()` / `accessibilityChildren()` over the whole
/// subtree came back nil or empty. So *"the row names the project"* is pinned
/// structurally — it is row zero, and row zero selects the project — rather than
/// by its glyphs.
@MainActor
final class BinderProjectRowTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    /// Rows the Research and Palette sections contribute at the foot of the
    /// tree when a project has neither yet (stage-2a Task 4): a header and one
    /// placeholder row each. Every fixture in this suite is a bare factory
    /// novel, so every count below is "what the binder had, plus the furniture".
    private let emptySectionRows = (1 + 1) + (1 + 1)

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

    // MARK: - The row exists, and it is at the head

    func test_theProjectRowAddsExactlyOneRowAndDisplacesNothing() async throws {
        let store = try await novel(named: "Row")
        let (window, _) = try await host(store: store)
        let table = try XCTUnwrap(firstTableView(in: window),
                                  "the binder's List never reached the hierarchy")

        XCTAssertEqual(table.numberOfRows,
                       1 + flatStructureRowCount(store) + emptySectionRows,
                       "the project row should be one row, at the head, and "
                       + "should not have displaced a chapter — with the two "
                       + "sections' furniture below all of it")
    }

    // MARK: - Selecting it, through the list

    /// The delivery path: a selection change on the real table, the real `.tag`
    /// match, the real binding.
    func test_selectingTheHeadRowMakesTheSubjectTheProject() async throws {
        let store = try await novel(named: "Select")
        let (window, probe) = try await host(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertNil(probe.subject)
        await select(row: 0, in: table, until: { probe.subject == .project })

        XCTAssertEqual(probe.subject, .project,
                       "selecting the head row must produce BinderSubject.project "
                       + "— nothing else in production constructs that case")
    }

    /// And back off it. This is also where the head row proves it is the HEAD:
    /// the chapter still selects itself, from row one.
    ///
    /// Tripwire 3's symptom in test form — the round trip is two selection writes
    /// and nothing else, so there is no work in the setter for a cursor to lose a
    /// race with.
    func test_theSubjectGoesProjectThenChapterThenProjectAgain() async throws {
        let store = try await novel(named: "RoundTrip")
        let (window, probe) = try await host(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))
        let firstDoc = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }))

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project)

        await select(row: 1, in: table,
                     until: { probe.subject == .item(firstDoc.id) })
        XCTAssertEqual(probe.subject, .item(firstDoc.id),
                       "the chapter below the project row must still select "
                       + "itself — the head row must not have shifted the tags")

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project)
    }

    /// **The row is a row, not a control.** Tripwire 9 forbids `.onTapGesture`
    /// for a clickable row inside `List(.sidebar)`, and a `Button` bolted on top
    /// is the other way this gets written — either would leave the selection
    /// binding untouched, so the two tests above are what enforce it.
    ///
    /// This pins the rest of the row's contract: no drag source and no drop
    /// destination, where a chapter row mounts the platform view that
    /// `.draggable` / `.dropDestination` install.
    func test_theProjectRowIsNeitherDraggableNorADropTarget() async throws {
        let store = try await novel(named: "Drag")
        let (window, _) = try await host(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertFalse(hasDraggingDestination(row: 0, in: table),
                       "the project row must not accept a drop — there is "
                       + "nothing for a chapter dragged onto it to mean")
        XCTAssertTrue(hasDraggingDestination(row: 1, in: table),
                      "control: a chapter row does mount one, so the assertion "
                      + "above is reading something real")
    }

    /// The row is selectable when the binder has nothing else in it. Before it,
    /// the empty state REPLACED the list; leaving it that way would make "delete
    /// the last document" a window with no subject it can ever be given again.
    func test_theProjectRowIsStillThereWhenTheStructureIsEmpty() async throws {
        let store = try await novelWithNothingLeftInIt(named: "Empty")
        XCTAssertTrue(store.manifest.structure.isEmpty, "fixture precondition")

        let (window, probe) = try await host(store: store)
        let table = try XCTUnwrap(
            firstTableView(in: window),
            "the empty binder must still be a List — the project row lives in it")

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project,
                       "an empty structure must still leave the project "
                       + "selectable, or deleting the last document strands the window")
    }

    /// **And the empty state is not a row.** This is the assertion that pins the
    /// design, and it was written because the first two attempts failed it:
    ///
    /// - the message as a `selectionDisabled` row got selected anyway, and with
    ///   no `.tag` the List wrote `nil` — clicking "No documents yet" silently
    ///   deselected the project (`table.selectedRow` was 1, measured);
    /// - the message as a `Section` footer cost a leading row, so the project row
    ///   stopped being row zero.
    ///
    /// One row means neither can come back without this going red.
    ///
    /// **The count is now the project row plus the sections' furniture**
    /// (stage-2a Task 4) — and the assertion is unchanged in what it protects:
    /// the "No documents yet" message must contribute NO row of its own. The
    /// sections' placeholder rows are untagged too, which is exactly why the
    /// trees' selection binding refuses a `nil` write; that is measured in
    /// `BinderTreeSectionsTests`.
    func test_theEmptyBinderHasNoRowForItsMessageAndTheProjectIsStillTheHead() async throws {
        let store = try await novelWithNothingLeftInIt(named: "EmptyRow")
        let (window, probe) = try await host(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(table.numberOfRows, 1 + emptySectionRows,
                       "the message must not be a row — an untagged row writes "
                       + "nil through the selection binding when it is clicked")
        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project)
    }

    /// **The overlay grew something to cover** (stage-2a Task 4). It is sized to
    /// the whole list, and the Research and Palette sections now live inside
    /// that list — so an empty binder, which is the state a writer gathers
    /// research in before there is a chapter to put it near, is exactly where an
    /// overlay that took the clicks would cost the most. Asked of every row, of
    /// AppKit, rather than reasoned about: `select(row:)` drives the table
    /// directly and proves nothing about hit-testing.
    func test_theEmptyStateOverlayDoesNotSwallowAnyRowBeneathIt() async throws {
        let store = try await novelWithNothingLeftInIt(named: "EmptyHit")
        let (window, _) = try await host(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))
        XCTAssertEqual(table.numberOfRows, 1 + emptySectionRows, "precondition")

        for row in 0..<table.numberOfRows {
            let hit = try XCTUnwrap(hitTestCentre(ofRow: row, in: table, window: window),
                                    "nothing at all was hit at row \(row)'s centre")
            XCTAssertTrue(hit.isDescendant(of: table),
                          "the empty-state overlay must not intercept row "
                          + "\(row)'s clicks — hit \(type(of: hit)) instead of "
                          + "the table")
        }
    }

    // MARK: - The delete path

    // `BinderView` no longer holds a rule for what the subject becomes after a
    // delete — it held one that answered "is the subject the row I deleted?",
    // which is a different question from "is the subject still there?" the
    // moment the deleted row is a group. The rule and its tests moved whole to
    // `SubjectValidationTests`, including the two this section used to carry:
    // the project subject surviving somebody else's delete, and the selected
    // item's own delete moving the window off it.

    // MARK: - Fixtures

    private func novel(named name: String) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "\(name)-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    /// A novel with its structure emptied through the real delete — what the
    /// binder looks like the moment the last document goes.
    private func novelWithNothingLeftInIt(named name: String) async throws -> ProjectStore {
        let store = try await novel(named: name)
        for item in store.manifest.structure {
            try await store.deleteStructureItem(id: item.id)
        }
        return store
    }

    /// Rows the outline contributes. The factory novel is flat — asserted rather
    /// than assumed, because a nested fixture would make the count a guess.
    private func flatStructureRowCount(_ store: ProjectStore) -> Int {
        XCTAssertTrue(store.manifest.structure.allSatisfy { $0.type == .document },
                      "fixture assumption: the factory novel's structure is flat")
        return store.manifest.structure.count
    }

    // MARK: - Hosting and driving

    private func host(store: ProjectStore) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let hosting = NSHostingView(
            rootView: AnyView(BinderProbeView(store: store, probe: probe)))
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

    /// Move the table's selection and let SwiftUI's list coordinator write it
    /// back through the binding. `selectRowIndexes` runs the delegate's
    /// proposed-selection filter first, which is how a `selectionDisabled` row
    /// refuses — the control for that is
    /// `test_theEmptyStateRowCannotBecomeTheSubject`.
    ///
    /// `until` is the thing the caller's next assertion checks, so the wait costs
    /// what the write-back really takes rather than its worst case. A caller with
    /// no condition to name — a NEGATIVE assertion, where the window of wall clock
    /// *is* the test — passes nothing and gets the fixed wait.
    private func select(row: Int, in table: NSTableView,
                        until settled: (() -> Bool)? = nil) async {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let settled {
            await pumpUntil(deadline: 5, settled)
        } else {
            // fixed window: no condition named — the caller is asserting an absence
            await waitOut(0.4)
        }
    }

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.first
    }

    /// What AppKit says is at the centre of `row`, asked of the window's whole
    /// content view so anything layered above the table gets its chance first.
    private func hitTestCentre(ofRow row: Int, in table: NSTableView,
                               window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        let rect = table.rect(ofRow: row)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return content.hitTest(content.convert(centre, from: table))
    }

    /// Whether the row mounts the AppKit view SwiftUI installs for
    /// `.draggable` / `.dropDestination`. Matched by class NAME because the type
    /// is SwiftUI-internal; if Apple renames it this test fails loudly rather
    /// than passing vacuously, which is why the assertion carries a control.
    private func hasDraggingDestination(row: Int, in table: NSTableView) -> Bool {
        guard let view = table.rowView(atRow: row, makeIfNecessary: true)
        else { return false }
        var found = false
        walk(view) { if "\(type(of: $0))".contains("DraggingDestination") { found = true } }
        return found
    }

    private func walk(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        for sub in view.subviews { walk(sub, visit) }
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}
