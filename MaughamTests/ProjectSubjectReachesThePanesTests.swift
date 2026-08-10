import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **What the project row makes newly possible**, asked as its own step rather
/// than as part of *"does the row work"*.
///
/// `BinderSubject.project` became representable one commit ago and nothing
/// constructed it; the row is the first thing that does, so from here it flows
/// into every surface that takes the window's selection. At the boundary it is
/// indistinguishable from no selection — `itemID` is `nil` and `activeDocId` is
/// the sentinel, both pinned in `BinderSubjectTests` — and *no selection* is a
/// state those panes already reach whenever the selected document is deleted.
///
/// So the panes that only READ are covered by that equivalence. What it does not
/// cover is a pane that **writes back**, because a control whose own selection
/// cannot represent the project can quietly answer the question by clearing it.
/// There is exactly one of those in a non-collection project: `OutlineTable`,
/// whose `Table(selection:)` is hard-bound to `StructureItem.ID` and so hangs off
/// a `String?` projection of the typed binding.
@MainActor
final class ProjectSubjectReachesThePanesTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp.cleanup()
        temp = nil
    }

    /// Opening the Outline pane (⌘⌥O) while the subject is the project must not
    /// cost the writer that subject. The pane's projection reads `nil` out of a
    /// project subject — correctly, the project is not one of its rows — and the
    /// question is whether the `Table` then writes that `nil` back.
    func test_theOutlinePaneDoesNotClearTheProjectSubjectJustByOpening() async throws {
        let store = try await novel(named: "Outline")
        let probe = BinderSubjectProbe(.project)
        _ = try await hostOutline(store: store, probe: probe, layout: .table)

        // Fixed window: asserting nothing happens. The subject already holds the
        // asserted value, so the window IS the test.
        await waitOut(0.6)
        XCTAssertEqual(probe.subject, .project,
                       "the Outline pane must not answer \"which of my rows is "
                       + "that?\" by clearing the window's subject")
    }

    /// The corkboard layout, same question. It writes only from its own button.
    func test_theCorkboardDoesNotClearTheProjectSubjectJustByOpening() async throws {
        let store = try await novel(named: "Corkboard")
        let probe = BinderSubjectProbe(.project)
        _ = try await hostOutline(store: store, probe: probe, layout: .cards)

        // Fixed window: asserting nothing happens.
        await waitOut(0.6)
        XCTAssertEqual(probe.subject, .project)
    }

    /// And the way out still works: selecting a row in the outline replaces the
    /// project subject with that document, through the projection's setter.
    func test_selectingInTheOutlineTakesTheSubjectOffTheProject() async throws {
        let store = try await novel(named: "OutlinePick")
        let probe = BinderSubjectProbe(.project)
        let window = try await hostOutline(store: store, probe: probe, layout: .table)
        let table = try XCTUnwrap(firstTableView(in: window))
        let firstDoc = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }))

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await pumpUntil(deadline: 5) { probe.subject == .item(firstDoc.id) }

        XCTAssertEqual(probe.subject, .item(firstDoc.id))
    }

    // MARK: - Fixtures and hosting

    private func novel(named name: String) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "\(name)-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    private func hostOutline(store: ProjectStore,
                             probe: BinderSubjectProbe,
                             layout: OutlineLayout) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 520, height: 600)
        let hosting = NSHostingView(
            rootView: AnyView(OutlineProbeView(store: store, probe: probe,
                                               layout: layout)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump()
        return window
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

}

/// `ProjectAltitudePane` with the window's subject held outside it.
@MainActor
private struct OutlineProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    @State var layout: OutlineLayout

    var body: some View {
        ProjectAltitudePane(
            store: store,
            layout: $layout,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
            title: store.manifest.title)
    }
}
