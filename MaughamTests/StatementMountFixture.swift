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
    /// The binder selection the pane sees. Settable so a test can drive a SCOPE
    /// CHANGE on one live pane — the case that must close the outgoing
    /// `Document` before the incoming one loads.
    var activeDocumentId: String?
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
final class StatementMountFixture {

    let projectURL: URL
    let store: ProjectStore
    let documentStore: DocumentStore
    let preferences: UserPreferences
    /// The manifest's first manuscript document — the "selected document" a
    /// document-scoped intent is about.
    let documentItemId: String
    let probe = StatementProbeModel()

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
    func host(kind: Statement.Kind, activeDocumentId: String?) async -> NSWindow {
        await mount(
            AnyView(
                StatementPane(
                    store: store, documentStore: documentStore,
                    kind: kind, activeDocumentId: activeDocumentId,
                    onScopeSwitchTouched: {})
                .environment(preferences)))
    }

    /// The pane mounted with a REQUESTED scope — what `ProjectWindow` hands it
    /// when the writer presses **Open** on a card promoted to craft intent
    /// (M1A Task 7). The pane is what decides whether to honour it, so a test
    /// that built the scope itself would prove nothing.
    @discardableResult
    func host(kind: Statement.Kind, activeDocumentId: String?,
              requesting request: Statement.Scope) async -> NSWindow {
        await mount(
            AnyView(
                StatementPane(
                    store: store, documentStore: documentStore,
                    kind: kind, activeDocumentId: activeDocumentId,
                    scopeRequest: request,
                    onScopeSwitchTouched: {})
                .environment(preferences)))
    }

    /// The pane with a SETTABLE selection, so a test can change its scope on one
    /// live pane rather than by hosting a second one.
    @discardableResult
    func hostWithASettableSelection(kind: Statement.Kind,
                                    activeDocumentId: String?) async -> NSWindow {
        probe.activeDocumentId = activeDocumentId
        return await mount(
            AnyView(
                RebindableStatementPaneView(
                    store: store, documentStore: documentStore,
                    kind: kind, probe: probe)
                .environment(preferences)))
    }

    /// Change the selection the hosted pane sees, and let the change settle.
    func selectDocument(_ id: String?) async {
        probe.activeDocumentId = id
        await waitOut(0.3)
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
    func dropStatementPane(in window: NSWindow) async {
        probe.showsStatementPane = false
        await pumpUntil(deadline: 5) { self.allTextViews(in: window).count <= 1 }
        await waitOut(0.3)
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
    func type(_ text: String, into textView: NSTextView) async {
        for character in text {
            let s = String(character)
            let range = textView.selectedRange()
            guard textView.shouldChangeText(in: range, replacementString: s) else { continue }
            textView.textStorage?.replaceCharacters(in: range, with: s)
            textView.setSelectedRange(
                NSRange(location: range.location + (s as NSString).length, length: 0))
            textView.didChangeText()
        }
        await waitOut(0.2)
    }

    // MARK: - Settling

    /// Take the window's content down so the pane's `.onDisappear` closes its
    /// `Document` — which flushes the pending typing burst to the op log — then
    /// wait for the bytes to land.
    ///
    /// `expectingOpsFor` is a wait, not an assertion: it bounds how long we turn
    /// the runloop, and the caller's own assertion is what fails (with its own
    /// message) if nothing arrives. A test expecting an EMPTY log passes nil.
    func settle(_ window: NSWindow, expectingOpsFor docId: String? = nil) async throws {
        window.contentView = NSView(frame: .zero)
        if let docId {
            await pumpUntil(deadline: 5) { !self.ops(forDocId: docId).isEmpty }
        }
        await waitOut(0.6)
    }

    /// Turn the runloop until `condition` holds or `deadline` seconds pass.
    ///
    /// **Both a runloop turn and a suspension, on purpose.** SwiftUI needs the
    /// runloop; the pane's own work — `createStatement`, `Document.load`,
    /// `Document.close` — is `await`ed on the MainActor, and a test that only
    /// spins `RunLoop.run(until:)` never lets those jobs start. Measured while
    /// writing these tests: with runloop turns alone the first keystroke's mint
    /// did not complete inside five seconds of pumping, and landed the moment the
    /// test's own `await` gave the main actor up.
    func pumpUntil(deadline: TimeInterval, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return }
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
        _ = condition()
    }

    /// Wait out at least `seconds` of WALL CLOCK, turning the runloop and
    /// yielding the main actor throughout — `RunLoop.run(until:)` returns as soon
    /// as it has nothing left to service, so a single call is not a wait.
    func waitOut(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// SwiftUI mounts representables and applies state changes on the main
    /// runloop, so nothing is observable until the loop has turned.
    func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
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
                    kind: kind, activeDocumentId: itemId,
                    onScopeSwitchTouched: {})
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
            kind: kind, activeDocumentId: probe.activeDocumentId,
            onScopeSwitchTouched: {})
    }
}
