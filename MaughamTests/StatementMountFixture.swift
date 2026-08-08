import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// Flips the statement pane out of the two-editor probe. Top-level and
/// `@Observable` so `TwoEditorProbeView` re-renders when the test drops the
/// pane, the way switching the right pane to another segment does.
@Observable
@MainActor
final class StatementProbeModel {
    var showsStatementPane = true
    /// The window's subject as the pane sees it. Settable so a test can drive a
    /// SCOPE CHANGE on one live pane — the case that must close the outgoing
    /// `Document` before the incoming one loads.
    var subject: BinderSubject?
    /// Which right-hand pane the toggle is showing. Settable so a test can drive
    /// `⌘⌥N`/`⌘⌥V` — the route that TEARS THE HOST DOWN rather than reconciling
    /// it (`segmentContent` gives `.intent` and `.visualLanguage` separate `case`
    /// arms), which is the other half of what `hostTheBinderBesideThePane`
    /// exists to exercise.
    var detailSegment: DetailSegment = .intent
    init() {}
}

/// A real novel project on disk, hosted in a real window, so a test can type
/// into the `StatementPane` the writer meets rather than into one it built
/// itself. Shared by `StatementEditorMountTests` and `StatementPaneTests`.
///
/// The shape is `CanvasViewMountingTests`': an `NSHostingView` in an
/// ordered-front window, a `pump` that turns the runloop, and a teardown that
/// drops the hosted view so `.onDisappear` runs. Nothing here reaches inside the
/// pane — the only handle it takes is the `MaughamTextView` SwiftUI's own
/// mounting produced.
@MainActor
final class StatementMountFixture: RunLoopPumping {

    let projectURL: URL
    let store: ProjectStore
    let documentStore: DocumentStore
    let preferences: UserPreferences
    /// The manifest's first manuscript document — the "selected document" a
    /// document-scoped intent is about.
    let documentItemId: String
    let probe = StatementProbeModel()
    /// The window's subject, held outside the views — written by the real binder
    /// and read by the real right column. See `hostTheBinderBesideThePane`.
    let subjectProbe = BinderSubjectProbe()

    private let temp: TempDirectory
    private var windows: [NSWindow] = []
    private let defaultsSuite: String

    private init(projectURL: URL, store: ProjectStore, documentStore: DocumentStore,
                 preferences: UserPreferences, documentItemId: String,
                 temp: TempDirectory, defaultsSuite: String) {
        self.projectURL = projectURL
        self.store = store
        self.documentStore = documentStore
        self.preferences = preferences
        self.documentItemId = documentItemId
        self.temp = temp
        self.defaultsSuite = defaultsSuite
    }

    static func novel(named name: String) async throws -> StatementMountFixture {
        let temp = TempDirectory()
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "\(name)-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: projectURL)
        await store.wordCountPopulationTask?.value
        let documentStore = try await DocumentStore.open(url: projectURL)
        store.documentStore = documentStore

        guard let item = store.manifest.structure.first(where: { $0.type == .document }) else {
            throw NSError(domain: "StatementMountFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "the factory novel has no document item"])
        }

        let suite = "statement-mount-\(UUID().uuidString)"
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)

        return StatementMountFixture(
            projectURL: projectURL, store: store, documentStore: documentStore,
            preferences: preferences, documentItemId: item.id,
            temp: temp, defaultsSuite: suite)
    }

    func tearDown() {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        temp.cleanup()
    }

    // MARK: - Hosting

    /// The pane alone, as the right column shows it.
    @discardableResult
    func host(kind: Statement.Kind, subject: BinderSubject?) async -> NSWindow {
        await mount(
            AnyView(
                StatementPane(
                    store: store, documentStore: documentStore,
                    kind: kind, subject: subject)
                .environment(preferences)))
    }

    /// The pane with a SETTABLE selection, so a test can change its scope on one
    /// live pane rather than by hosting a second one.
    @discardableResult
    func hostWithASettableSelection(kind: Statement.Kind,
                                    subject: BinderSubject?) async -> NSWindow {
        probe.subject = subject
        return await mount(
            AnyView(
                RebindableStatementPaneView(
                    store: store, documentStore: documentStore,
                    kind: kind, probe: probe)
                .environment(preferences)))
    }

    /// Wait for the caller's own condition if it can name one, and fall back to a
    /// fixed window if it cannot.
    ///
    /// Every "…and let it settle" below used to be a flat `waitOut`, which costs
    /// its worst case on every test even when the work finished in milliseconds.
    /// The fixture cannot name the condition — only the caller knows what it is
    /// about to assert — so the caller passes it. `nil` keeps the old fixed
    /// window, which is the honest answer for a test proving that something does
    /// NOT happen: an absence needs a span of wall clock to mean anything.
    private func settleWaiting(_ condition: (() -> Bool)?,
                               otherwise fallback: TimeInterval) async {
        if let condition {
            await pumpUntil(deadline: 5, condition)
        } else {
            await waitOut(fallback)
        }
    }

    /// Change the selection the hosted pane sees, and let the change settle.
    func selectDocument(_ id: String?, until condition: (() -> Bool)? = nil) async {
        probe.subject = id.map(BinderSubject.item)
        await settleWaiting(condition, otherwise: 0.3)
    }

    /// **The whole delivery path: the real binder writes the window's subject
    /// and the real right column reads it** (slice 1, task 6).
    ///
    /// Every other mount here hands `StatementPane` a value the test chose, so
    /// nothing in the suite has ever exercised `detailSegment`, the selection
    /// binding and the pane's own state together — which is precisely what
    /// `ProjectWindow.openPromotedArtifact`'s comment records as the reason
    /// `Open`-sets-scope failed three fix rounds and was reverted: *"no test
    /// drives a press through the binding and back through this view's state"*.
    ///
    /// What is production here: `BinderView`'s `List(selection:)` and its row
    /// tags, the `Binding` between the two columns, `DetailPaneToggle`'s picker
    /// and its `segmentContent` routing, and `StatementPane`'s own resolution.
    /// The only thing this view supplies is `ProjectWindow`'s boundary
    /// conversion, and it CALLS that rather than re-spelling it
    /// (`BinderSubject.itemID` / `BinderSubject.activeDocId(for:)`), so a change
    /// to the rule reaches this test.
    ///
    /// Drive it with `selectBinderRow(_:in:)` and read the answer off
    /// `firstTextView(in:)` — the pane's resolved scope observed as the words it
    /// put on screen, which is the only reading of it available from outside.
    @discardableResult
    func hostTheBinderBesideThePane(subject: BinderSubject?) async -> NSWindow {
        subjectProbe.subject = subject
        return await mount(
            AnyView(
                BinderBesideThePaneProbeView(
                    store: store, documentStore: documentStore,
                    subjectProbe: subjectProbe, paneProbe: probe)
                .environment(preferences)))
    }

    /// Move the binder's selection the way a click does — `selectRowIndexes`
    /// runs the delegate's proposed-selection filter and SwiftUI's list
    /// coordinator writes the matched `.tag` back through the binding
    /// (`BinderProjectRowTests`).
    func selectBinderRow(_ row: Int, in window: NSWindow,
                         until condition: (() -> Bool)? = nil) async {
        guard let table = firstTableView(in: window) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await settleWaiting(condition, otherwise: 0.4)
    }

    /// Show another right-hand pane, as `⌘⌥N`/`⌘⌥V` does.
    func showSegment(_ segment: DetailSegment, until condition: (() -> Bool)? = nil) async {
        probe.detailSegment = segment
        await settleWaiting(condition, otherwise: 0.4)
    }

    func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.first
    }

    /// The pane beside the manuscript editor — the arrangement the writer gets,
    /// and the first time two `EditorSurface`s have been alive at once.
    ///
    /// `key: true` hosts it in an `AlwaysKeyWindow` — see that type for why the
    /// one OS fact this harness cannot produce is forced rather than skipped.
    @discardableResult
    func hostBesideAManuscriptEditor(kind: Statement.Kind, key: Bool = false) async -> NSWindow {
        let window = await mount(
            AnyView(
                TwoEditorProbeView(
                    store: store, documentStore: documentStore,
                    itemId: documentItemId, kind: kind, probe: probe)
                .environment(preferences)),
            key: key)
        // The manuscript editor loads its Document asynchronously; wait for both
        // surfaces rather than racing the mount.
        await pumpUntil(deadline: 5) { self.allTextViews(in: window).count >= 2 }
        return window
    }

    private func mount(_ view: AnyView, key: Bool = false) async -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 700, height: 700)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = frame
        let windowType = key ? AlwaysKeyWindow.self : NSWindow.self
        let window = windowType.init(contentRect: frame, styleMask: [.titled],
                                     backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump()
        await pumpUntil(deadline: 5) { self.firstTextView(in: window) != nil }
        return window
    }

    /// Take the statement pane out of the two-editor probe.
    func dropStatementPane(in window: NSWindow, until condition: (() -> Bool)? = nil) async {
        probe.showsStatementPane = false
        await pumpUntil(deadline: 5) { self.allTextViews(in: window).count <= 1 }
        await settleWaiting(condition, otherwise: 0.3)
    }

    // MARK: - Finding the mounted editor

    func textView(in window: NSWindow) throws -> MaughamTextView {
        try XCTUnwrap(firstTextView(in: window),
                      "the mounted editor never reached the hosted hierarchy, so "
                      + "nothing on this pane can be typed into")
    }

    func firstTextView(in window: NSWindow) -> MaughamTextView? {
        allTextViews(in: window).first
    }

    func allTextViews(in window: NSWindow) -> [MaughamTextView] {
        guard let root = window.contentView else { return [] }
        var found: [MaughamTextView] = []
        collect(MaughamTextView.self, in: root, into: &found)
        return found
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    // MARK: - Input

    /// Type `text` one character at a time through AppKit's own
    /// `shouldChangeText` → `didChangeText` sequence, which is what fires the
    /// coordinator's delegate methods and, through them, the binding.
    func type(_ text: String, into textView: NSTextView,
              until condition: (() -> Bool)? = nil) async {
        for character in text {
            let s = String(character)
            let range = textView.selectedRange()
            guard textView.shouldChangeText(in: range, replacementString: s) else { continue }
            textView.textStorage?.replaceCharacters(in: range, with: s)
            textView.setSelectedRange(
                NSRange(location: range.location + (s as NSString).length, length: 0))
            textView.didChangeText()
        }
        await settleWaiting(condition, otherwise: 0.2)
    }

    // MARK: - Settling

    /// Take the window's content down so the pane's `.onDisappear` closes its
    /// `Document` — which flushes the pending typing burst to the op log — then
    /// wait for the bytes to land.
    ///
    /// `expectingOpsFor` is a wait, not an assertion: it bounds how long we turn
    /// the runloop, and the caller's own assertion is what fails (with its own
    /// message) if nothing arrives. A test expecting an EMPTY log passes nil.
    /// `until` is the caller's own settled-state condition — typically the very
    /// thing its next assertion reads. Given one, the close is waited out only as
    /// long as it actually takes; without one the fixed window stands, which is
    /// what a test expecting an empty log needs.
    func settle(_ window: NSWindow, expectingOpsFor docId: String? = nil,
                until condition: (() -> Bool)? = nil) async throws {
        window.contentView = NSView(frame: .zero)
        if let docId {
            await pumpUntil(deadline: 5) { !self.ops(forDocId: docId).isEmpty }
        }
        await settleWaiting(condition, otherwise: 0.6)
    }

    // MARK: - Reading the op log

    func ops(forDocId docId: String) -> [Op] {
        OpLogStore.loadSyncMerged(forDocId: docId, in: projectURL)
    }

    /// The document text the op log derives to — the authoritative reading of
    /// what a statement now says (ADR 0018: the `.md` is derived, never truth).
    func derivedText(forDocId docId: String) -> String {
        let state = Deriver.deriveWithSequenceFallback(ops: ops(forDocId: docId))
        return state.sequence
            .compactMap { state.paragraphs[$0] }
            .joined(separator: "\n\n")
    }
}

/// A manuscript editor and a statement pane in one window, with the pane
/// removable — what
/// `test_closingTheStatementPaneLeavesTheManuscriptUndoStackAlone` needs.
@MainActor
private struct TwoEditorProbeView: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let itemId: String
    let kind: Statement.Kind
    let probe: StatementProbeModel

    @State private var control = EditorControl()

    var body: some View {
        HStack(spacing: 0) {
            EditorHost(
                store: store, documentStore: documentStore,
                selectedItemId: itemId, control: control)
            if probe.showsStatementPane {
                StatementPane(
                    store: store, documentStore: documentStore,
                    kind: kind, subject: .item(itemId))
                .frame(width: 260)
            }
        }
    }
}

/// A window that reports itself key.
///
/// **The one OS fact this harness cannot produce.** `MaughamEvent.shouldDeliver`
/// gates every `.keyWindow`-scoped post on `context.isWindowKey`, which
/// `EventReceiverContext.forWindow` reads straight off `NSWindow.isKeyWindow` —
/// and a window hosted by `xcodebuild`'s test host never becomes key, even after
/// `NSApplication.activate` + `makeKeyAndOrderFront` (measured 2026-08-01). So a
/// `.keyWindow` post reaches NOTHING in a unit test, and a delivery test written
/// against a real window either skips or passes vacuously.
///
/// Overriding this one property leaves the whole rest of the path production:
/// the real `MaughamEvent.post`, the real `NotificationCenter`, the real
/// `shouldDeliver` filter, the real `receiverContext`, and the coordinator's own
/// registered closure. Nothing about the assertion is stubbed — only the
/// window's answer to "are you key".
private final class AlwaysKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// The two columns that share the window's subject, with the subject held
/// outside both of them.
///
/// **`ProjectWindow`'s boundary, called rather than copied.** The window
/// converts its typed subject exactly twice on the way to the right column —
/// `activeItemID` is `selectedSubject?.itemID` (`ProjectWindow.swift:1511`) and
/// `activeDocId` is `BinderSubject.activeDocId(for:)` (`:1516-1518`) — and both
/// of those are the type's own accessors. Re-spelling either here would be a
/// second answer to the question the type exists to have one answer to, and a
/// test built on a copy of a rule cannot fail when the rule changes.
///
/// `EmptyView` for the inspector arm: this probe is about the statement panes,
/// and mounting the real inspector would drag the whole binder-segment routing
/// in behind it.
@MainActor
private struct BinderBesideThePaneProbeView: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let subjectProbe: BinderSubjectProbe
    let paneProbe: StatementProbeModel

    @State private var outlineLayout: OutlineLayout = .table

    private var subject: Binding<BinderSubject?> {
        Binding(get: { subjectProbe.subject }, set: { subjectProbe.subject = $0 })
    }

    private var segment: Binding<DetailSegment> {
        Binding(get: { paneProbe.detailSegment }, set: { paneProbe.detailSegment = $0 })
    }

    var body: some View {
        HStack(spacing: 0) {
            BinderView(store: store, selectedSubject: subject)
                .frame(width: 260)
            DetailPaneToggle(
                store: store,
                segment: segment,
                outlineLayout: $outlineLayout,
                selectedSubject: subject,
                activeManuscriptItemId: subjectProbe.subject?.itemID,
                // Plan registers BOTH statement panes, so neither `.intent` nor
                // `.visualLanguage` is an out-of-persona selection here and
                // `snapSegmentIntoPicker` has nothing to move. (Author registers
                // `.intent` only — `.visualLanguage` is `—` for Author.)
                persona: .plan,
                projectURL: store.url,
                activeDocId: BinderSubject.activeDocId(for: subjectProbe.subject),
                documentStore: documentStore
            ) {
                EmptyView()
            }
        }
    }
}

/// `StatementPane` with the binder selection driven by the probe, so a scope
/// change happens on ONE live pane.
@MainActor
private struct RebindableStatementPaneView: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let kind: Statement.Kind
    let probe: StatementProbeModel

    var body: some View {
        StatementPane(
            store: store, documentStore: documentStore,
            kind: kind, subject: probe.subject)
    }
}
