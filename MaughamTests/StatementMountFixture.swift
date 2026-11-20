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
    init() {}
}

/// A real novel project on disk, hosted in a real window, so a test can type
/// into the `StatementPane` the writer meets rather than into one it built
/// itself. Shared by `StatementEditorMountTests` and `StatementPaneTests`.
///
/// The shape is `CanvasViewMountingCase`': an `NSHostingView` in an
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
    /// The right column's position and subject. It opens on Brief — where a
    /// subject's intent is — and a test moves it with `showVisualLanguage` /
    /// `showBrief`: the route that TEARS THE INTENT HOST DOWN rather than
    /// reconciling it (Brief and the pulled-up thing are separate arms of
    /// `RightColumn`'s one `switch`).
    let columnProbe = RightColumnFixture.Probe(position: .brief)

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
        documentStore.projectStore = store   // both ways, as ProjectSession.open: the note door finds notes through it

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

    /// Take the windows down, CLOSE the `DocumentStore`, then remove the
    /// folder — in that order. A store left open keeps its file presenter
    /// registered over a folder that is being deleted, and its registry
    /// callbacks then read `.maugham/people/…` as it vanishes (the
    /// intermittent "The file “events” couldn’t be opened", shell p3 Task 9).
    func closeAndTearDown() async {
        takeTheWindowsDown()
        await documentStore.close()
        temp.cleanup()
    }

    /// The synchronous form, for a `defer`: the close and the folder's
    /// removal follow in order on the main actor, after the test body.
    func tearDown() {
        takeTheWindowsDown()
        let documentStore = documentStore
        let temp = temp
        Task { @MainActor in
            await documentStore.close()
            temp.cleanup()
        }
    }

    private func takeTheWindowsDown() {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
    }

    // MARK: - Hosting

    /// The pane alone, as the right column shows it.
    ///
    /// `bible`/`world` default to nil — the two lower strata are absent, which
    /// is what every pre-Task-6 mount in this suite is asserting about. Pass
    /// them to get the three-stratum pane `ProjectWindow` builds.
    @discardableResult
    func host(kind: Statement.Kind, subject: BinderSubject?,
              bible: BibleStore? = nil,
              world: DeclaredWorldStore? = nil) async -> NSWindow {
        await mount(
            AnyView(
                StatementPane(
                    store: store, documentStore: documentStore,
                    kind: kind, subject: subject, bible: bible, world: world)
                .environment(preferences)))
    }

    // MARK: - Reading what the pane put on screen

    /// Every accessibility value or label in the window containing `substring`.
    ///
    /// `DiagnosticsPaneTests`' reader, on the shared harness because two suites
    /// now want it. SwiftUI draws `Text` rather than mounting an `NSTextField`,
    /// so the accessibility tree is the only reading of a rendered row
    /// available from outside — and it is production's own tree, not a probe.
    ///
    /// **The priming call is load-bearing, not ceremony.** SwiftUI builds no
    /// accessibility tree until an assistive client attaches, so a reader that
    /// walks `accessibilityChildren` without asking the process for its own role
    /// first returns an empty array for a window full of rows — which reads
    /// exactly like a pane that rendered nothing. Cost an hour here before the
    /// dump said every label in the window was missing, not only the new ones.
    func staticTexts(in window: NSWindow, containing substring: String) throws -> [String] {
        try axTree(in: window)
            .compactMap { axAttribute($0, "accessibilityValue") as? String
                ?? axAttribute($0, "accessibilityLabel") as? String }
            .filter { $0.contains(substring) }
    }

    /// Any view, in a window the column's width, with the fixture's
    /// preferences — for a surface that may mount no editor at all (Brief's
    /// reading face), so nothing here waits for one.
    @discardableResult
    func hostView(_ view: AnyView, width: CGFloat = 320) -> NSWindow {
        let window = TestWindow.mount(AnyView(view.environment(preferences)),
                                      size: CGSize(width: width, height: 900))
        windows.append(window)
        pump()
        return window
    }

    /// Every accessibility value or label in the window, in tree order.
    func allStaticTexts(in window: NSWindow) throws -> [String] {
        try axTree(in: window)
            .compactMap { axAttribute($0, "accessibilityValue") as? String
                ?? axAttribute($0, "accessibilityLabel") as? String }
    }

    /// `staticTexts` as a predicate, for polling. Swallows the unavailable-tree
    /// skip on purpose — a `pumpUntil` condition cannot throw, and the
    /// assertion after the wait is what reports the skip.
    func shows(_ substring: String, in window: NSWindow) -> Bool {
        !(((try? staticTexts(in: window, containing: substring)) ?? []).isEmpty)
    }

    /// Press the real control the writer presses, through production's own
    /// accessibility tree (`DiagnosticsPaneTests`' shape).
    ///
    /// A press rather than a call of the action: what a delivery-path test is
    /// for is everything between the two — that the `Button` exists, that it is
    /// reachable, and that the closure it carries closes over the environment
    /// the mounted view actually got.
    @discardableResult
    func pressButton(labelled label: String, in window: NSWindow) throws -> Bool {
        var lastLabels: [String] = []
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let buttons = try axTree(in: window)
                .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            lastLabels = buttons.map { axAttribute($0, "accessibilityLabel") as? String ?? "nil" }
            if let match = buttons.first(
                where: { (axAttribute($0, "accessibilityLabel") as? String) == label })
                as? NSObject {
                _ = match.perform(NSSelectorFromString("accessibilityPerformPress"))
                return true
            }
            pump(0.05)
        }
        XCTFail("no button labelled \u{201C}\(label)\u{201D} reached the hosted pane. "
                + "Buttons found on the last attempt: \(lastLabels)")
        return false
    }

    /// The window's accessibility subtree, with the process primed — see
    /// `staticTexts` for why the priming call is load-bearing.
    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so SwiftUI "
                + "never built the tree this test presses through")
        }
        guard let root = window.contentView else { return [] }
        return axElements(under: root)
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
    /// tags, the `Binding` between the two columns, `RightColumn`'s control
    /// and its one `switch` over `RightColumnContent`, Brief's scope
    /// (`BriefScope.of` the faces) and its Going for. The only thing this view
    /// supplies is the window's subject for a tree selection — the row opened
    /// and faced, nothing selected being the Book.
    ///
    /// Drive it with `selectBinderRow(_:in:)` and read the answer off
    /// `firstTextView(in:)` — the pane's resolved scope observed as the words it
    /// put on screen, which is the only reading of it available from outside.
    @discardableResult
    func hostTheBinderBesideThePane(subject: BinderSubject?) async -> NSWindow {
        subjectProbe.subject = subject
        columnProbe.selection = subject
        return await mount(
            AnyView(
                BinderBesideThePaneProbeView(
                    store: store, documentStore: documentStore,
                    subjectProbe: subjectProbe, columnProbe: columnProbe)
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

    /// Pull Visual Language up, as `⌘⌥V` does (`ProjectWindow.pullUp`): the
    /// column leaves Brief, so the intent's host is torn down.
    func showVisualLanguage(until condition: (() -> Bool)? = nil) async {
        pullUpVisualLanguage()
        await settleWaiting(condition, otherwise: 0.4)
    }

    /// The same write with no wait, for a test that must act in the same turn.
    func pullUpVisualLanguage() {
        columnProbe.subject = ClickRule.pullUp(.visualLanguage, current: columnProbe.subject)
        columnProbe.position = .pulledUp
    }

    /// Back to Brief, as `⌘⌥N` does.
    func showBrief(until condition: (() -> Bool)? = nil) async {
        columnProbe.position = .brief
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
    /// `key: true` hosts it in a `KeyTestWindow` — see `mount(_:key:)` for why
    /// the one OS fact this harness cannot produce is forced rather than skipped.
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

    /// `key: true` mounts in a `KeyTestWindow`, which reports itself key.
    ///
    /// **The one OS fact this harness cannot produce.** `MaughamEvent.shouldDeliver`
    /// gates every `.keyWindow`-scoped post on `context.isWindowKey`, which
    /// `EventReceiverContext.forWindow` reads straight off `NSWindow.isKeyWindow` —
    /// and a window hosted by `xcodebuild`'s test host never becomes key, even after
    /// `NSApplication.activate` + `makeKeyAndOrderFront` (measured 2026-08-01). So a
    /// `.keyWindow` post reaches NOTHING in a unit test, and a delivery test written
    /// against a real window either skips or passes vacuously.
    ///
    /// Overriding that one property leaves the whole rest of the path production:
    /// the real `MaughamEvent.post`, the real `NotificationCenter`, the real
    /// `shouldDeliver` filter, the real `receiverContext`, and the coordinator's own
    /// registered closure. Nothing about the assertion is stubbed — only the
    /// window's answer to "are you key".
    private func mount(_ view: AnyView, key: Bool = false) async -> NSWindow {
        let size = CGSize(width: 700, height: 700)
        let window: NSWindow = key
            ? TestWindow.mount(view, size: size, as: KeyTestWindow.self)
            : TestWindow.mount(view, size: size)
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
        // Test fixture absorbs RULING-54's strict throw: an unreadable file
        // reads as [] here, and the exact-match assertions fail loudly anyway.
        (try? OpLogStore.loadSyncMerged(forDocId: docId, in: projectURL)) ?? []
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
    @State private var referenceIndex = ReferenceIndexHost()

    var body: some View {
        HStack(spacing: 0) {
            EditorHost(
                store: store, documentStore: documentStore,
                selectedItemId: itemId, control: control, referenceIndex: referenceIndex)
            if probe.showsStatementPane {
                StatementPane(
                    store: store, documentStore: documentStore,
                    kind: kind, subject: .item(itemId))
                .frame(width: 260)
            }
        }
    }
}

/// The two columns that share the window's subject, with the subject held
/// outside both of them.
///
/// **The right column is `RightColumn` itself** (`RightColumnFixture`), on the
/// position and the subject the probe holds. The binder writes its selection
/// to `subjectProbe` (what the tests read) and through it to the column's
/// subject — the row opened and faced, as a click in the tree does.
@MainActor
private struct BinderBesideThePaneProbeView: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let subjectProbe: BinderSubjectProbe
    let columnProbe: RightColumnFixture.Probe
    let treeState = BinderTreeSectionsState()

    private var subject: Binding<BinderSubject?> {
        Binding(get: { subjectProbe.subject },
                set: {
                    subjectProbe.subject = $0
                    columnProbe.selection = $0
                })
    }

    var body: some View {
        HStack(spacing: 0) {
            BinderView(store: store, subject: .tree(subject),
                       treeState: treeState)
                .frame(width: 260)
            RightColumnFixture.pane(store: store, documentStore: documentStore,
                                    probe: columnProbe, width: 440)
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
