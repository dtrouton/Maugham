import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// `CollectionPiecesPane` with its selection bound to a probe — the pane as
/// `CollectionBinderPaneToggle` mounts it, with a handle on what it writes.
@MainActor
private struct CollectionPiecesProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    @State private var renaming: String?
    let treeState = BinderTreeSectionsState()

    var body: some View {
        CollectionPiecesPane(
            store: store,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
            renamingItemId: $renaming,
            treeState: treeState)
    }
}

/// **The project row in a Collection** (plan task 2b).
///
/// `ProjectWindow.binderColumn` mounts `BinderView` only for non-collection
/// projects; a Collection's manuscript segment is `CollectionPiecesPane`, which
/// carries its own `List(selection:)`. Without a project row here,
/// `BinderSubject.project` is **unconstructible in a Collection** — which was
/// harmless only while `StatementPane` carried its `[Chapter | Project]` picker.
/// **Task 7 has now deleted that picker**, so this row is the only route a
/// Collection has to project-scoped intent, and the case
/// `craftIntentItem(forPieceId:)` was originally built for reaches nothing
/// without it. It stopped being a precaution the moment the picker went.
///
/// **Mounted, not reasoned about**, for the same reason `BinderProjectRowTests`
/// is: the row's whole implementation is a label and a `.tag`, so the only thing
/// that can be wrong is whether `List(selection:)` matches that tag — which a
/// test built out of the view's own data cannot see.
///
/// **What was measured here on 2026-08-01 (macOS 26.5), rather than inherited
/// from `BinderView`:** whether a `ContentUnavailableView` used as an *overlay*
/// swallows clicks on the row underneath it. `BinderView`'s empty state is a
/// hand-built `VStack` of glyphs and buttons and its comment says nothing gives
/// it a background; `ContentUnavailableView` is a system view chained to a full
/// frame, and that is a different question.
/// `test_theEmptyStateOverlayDoesNotSwallowAnyRowBeneathIt` is the answer, and it
/// hit-tests rather than asserting a shape.
@MainActor
final class CollectionProjectRowTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    /// Rows the Research and Palette sections contribute at the foot of the
    /// tree when a Collection has neither yet (stage-2a Task 4): a header and
    /// one placeholder row each.
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
        let store = try await collection(named: "Row", pieces: ["One", "Two"])
        let (window, _) = try await host(store: store)
        let table = try XCTUnwrap(firstTableView(in: window),
                                  "the pieces List never reached the hierarchy")

        XCTAssertEqual(table.numberOfRows,
                       1 + store.manifest.structure.count + emptySectionRows,
                       "the project row should be one row, at the head, and "
                       + "should not have displaced a piece — with the two "
                       + "sections' furniture below all of it")
    }

    // MARK: - Selecting it, through the list

    func test_selectingTheHeadRowMakesTheSubjectTheProject() async throws {
        let store = try await collection(named: "Select", pieces: ["One"])
        let (window, probe) = try await host(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertNil(probe.subject)
        await select(row: 0, in: table, until: { probe.subject == .project })

        XCTAssertEqual(probe.subject, .project,
                       "selecting the head row must produce BinderSubject.project "
                       + "— in a Collection this is the ONLY thing that does")
    }

    /// And back off it — which is also where the head row proves it is the head:
    /// the piece still selects itself, from row one.
    func test_theSubjectGoesProjectThenPieceThenProjectAgain() async throws {
        let store = try await collection(named: "RoundTrip", pieces: ["One", "Two"])
        let (window, probe) = try await host(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))
        let firstPiece = try XCTUnwrap(store.manifest.structure.first)

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project)

        await select(row: 1, in: table,
                     until: { probe.subject == .item(firstPiece.id) })
        XCTAssertEqual(probe.subject, .item(firstPiece.id),
                       "the piece below the project row must still select itself "
                       + "— the head row must not have shifted the tags")

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project)
    }

    /// The row is a row, not one of `CollectionPiecesPane`'s own idioms.
    /// `PieceRow` mounts a drag source and a drop destination and carries an
    /// inline-rename `TextField` and a context menu; the project row is none of
    /// those.
    func test_theProjectRowIsNeitherDraggableNorADropTarget() async throws {
        let store = try await collection(named: "Drag", pieces: ["One"])
        let (window, _) = try await host(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertFalse(hasDraggingDestination(row: 0, in: table),
                       "the project row must not accept a drop — there is "
                       + "nothing for a piece dragged onto it to mean")
        XCTAssertTrue(hasDraggingDestination(row: 1, in: table),
                      "control: a piece row does mount one, so the assertion "
                      + "above is reading something real")
    }

    // MARK: - The empty Collection

    /// **A fresh Collection has no pieces at all** — `createCollectionProject`
    /// writes an empty structure — so in a Collection the empty binder is not
    /// the deleted-the-last-one edge case it is in a novel: it is what every new
    /// Collection opens on. The empty state therefore cannot REPLACE the list,
    /// or the project row would be missing exactly when the writer most needs a
    /// subject to point the intent pane at.
    func test_theEmptyCollectionHasNoRowForItsMessageAndTheProjectIsStillTheHead() async throws {
        let store = try await collection(named: "Empty", pieces: [])
        XCTAssertTrue(store.manifest.structure.isEmpty, "fixture precondition")

        let (window, probe) = try await host(store: store)
        let table = try XCTUnwrap(
            firstTableView(in: window),
            "the empty Pieces pane must still be a List — the project row lives in it")

        XCTAssertEqual(table.numberOfRows, 1 + emptySectionRows,
                       "the 'No pieces yet' message must not be a row — an "
                       + "untagged row writes nil through the selection binding "
                       + "when it is clicked (measured on the novel binder). "
                       + "The rest is the two sections' furniture (Task 4)")
        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project)
    }

    /// **The measurement the plan asked for.** An overlay that covers the list
    /// is only safe if it does not take the clicks. `select(row:)` above drives
    /// `selectRowIndexes` and so proves nothing about hit-testing; this asks
    /// AppKit directly, at the middle of row zero.
    /// **Widened to every row** (stage-2a Task 4): the sections now live under
    /// the same overlay, and a Collection with no pieces is exactly where a
    /// writer reaches for research first.
    func test_theEmptyStateOverlayDoesNotSwallowAnyRowBeneathIt() async throws {
        let store = try await collection(named: "Hit", pieces: [])
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

    // MARK: - Fixtures

    private func collection(named name: String,
                            pieces: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "\(name)-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        for title in pieces {
            _ = try await store.addLoosePiece(title: title, mode: .prose)
        }
        await store.wordCountPopulationTask?.value
        return store
    }

    // MARK: - Hosting and driving

    private func host(store: ProjectStore) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = TestWindow.mount(
            AnyView(CollectionPiecesProbeView(store: store, probe: probe)),
            size: CGSize(width: 320, height: 600))
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        return (window, probe)
    }

    /// Move the table's selection and let SwiftUI's list coordinator write it back
    /// through the binding.
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

    /// What AppKit says is at the centre of `row`, asked of the window's whole
    /// content view so anything layered above the table gets its chance first.
    private func hitTestCentre(ofRow row: Int, in table: NSTableView,
                               window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        let rect = table.rect(ofRow: row)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return content.hitTest(content.convert(centre, from: table))
    }

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.first
    }

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
