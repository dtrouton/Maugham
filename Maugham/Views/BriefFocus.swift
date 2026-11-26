import SwiftUI
import AppKit

/// **A Brief field a key puts the keys in** (appraisal 5): ⌘⌥I is the line,
/// ⌘⌥N Going for's editor. The window holds the request
/// (`ProjectWindow.briefFocus`); the right column hands it to Brief through
/// the environment (`EnvironmentValues.briefFocus`), and the field that owns
/// it consumes it — sets it back to nil — whether or not it could take the
/// keys, so a request never fires on a later mount.
enum BriefField: String, Equatable, Sendable {
    case line
    case goingFor

    /// Whether `scope`'s Brief draws this field at all: a piece has a line and
    /// Going for, the Book only Going for. Anything else draws neither, so the
    /// receiver never leaves a request standing over it. Pure.
    func isOffered(in scope: BriefScope) -> Bool {
        switch (self, scope) {
        case (.line, .piece), (.goingFor, .piece), (.goingFor, .book): return true
        case (.line, _), (.goingFor, _): return false
        }
    }
}

private struct BriefFocusKey: EnvironmentKey {
    static let defaultValue: Binding<BriefField?> = .constant(nil)
}

extension EnvironmentValues {
    /// The window's standing Brief-field request (`BriefField`).
    var briefFocus: Binding<BriefField?> {
        get { self[BriefFocusKey.self] }
        set { self[BriefFocusKey.self] = newValue }
    }
}

/// **Puts the keys in the text editor drawn over this view's frame**, once
/// asked (`wanted`), and reports how it ended. The statement editor binds its
/// `Document` a beat after it mounts, so the probe looks again on a short
/// step a bounded number of times. It finds the editor as the centre's cover
/// finds its own: a `MaughamTextView` whose visible frame lies within this
/// one (`CentreKeysView.coverEditor`).
///
/// **A request claims once and always ends** (review I2): a claim starts
/// only on the request's false→true edge, never again on a re-render while
/// it stands, and the host hears `onFocused` or `onGaveUp` — so it lets the
/// request go either way, and a request that found no editor never takes the
/// keys out of the manuscript minutes later.
struct EditorFocusProbe: NSViewRepresentable {
    let wanted: Bool
    let onFocused: () -> Void
    let onGaveUp: () -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onFocused = onFocused
        view.onGaveUp = onGaveUp
        view.update(wanted: wanted)
    }

    /// Whether an update starts a claim: only on the request's rising edge. Pure.
    static func claims(wanted: Bool, wasWanted: Bool) -> Bool { wanted && !wasWanted }

    final class ProbeView: NSView {
        var onFocused: () -> Void = {}
        var onGaveUp: () -> Void = {}
        /// The steps a claim takes before it gives up.
        var stepsAllowed = ProbeView.attempts
        /// The claims started, so a newer one supersedes an older one's steps.
        private(set) var generation = 0
        private var wasWanted = false
        static let step: TimeInterval = 0.05
        static let attempts = 20

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The host's request, as of this update.
        func update(wanted: Bool) {
            if EditorFocusProbe.claims(wanted: wanted, wasWanted: wasWanted) { claim() }
            wasWanted = wanted
        }

        private func claim() {
            generation += 1
            attempt(generation, remaining: stepsAllowed)
        }

        private func attempt(_ generation: Int, remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.step) { [weak self] in
                guard let self, generation == self.generation else { return }
                if let window = self.window, let editor = self.editor(in: window),
                   window.makeFirstResponder(editor) {
                    self.onFocused()
                    return
                }
                if remaining > 0 {
                    self.attempt(generation, remaining: remaining - 1)
                } else {
                    self.onGaveUp()
                }
            }
        }

        private func editor(in window: NSWindow) -> MaughamTextView? {
            EditorFocusProbe.editor(over: self, in: window)
        }
    }

    /// The second editor drawn over `probe`'s frame — never the manuscript's.
    @MainActor
    static func editor(over probe: NSView, in window: NSWindow) -> MaughamTextView? {
        guard let root = window.contentView else { return nil }
        let mine = probe.convert(probe.bounds, to: nil)
        return CentreKeysView.all(MaughamTextView.self, in: root).first { editor in
            !CentreKeys.isManuscriptEditor(editor)
                && CentreKeys.lies(CentreKeysView.visibleFrame(of: editor), within: mine)
        }
    }
}

/// **Reports the height the text in the editor over this view's frame
/// needs** (appraisal 11), so Going for grows with its intent and the column,
/// not the editor, scrolls. It finds the editor as `EditorFocusProbe` does,
/// then measures its laid-out text (TextKit 1's used rect, plus the text
/// view's own top and bottom inset) after each edit and each frame change.
///
/// **It reads the editor and writes nothing to it**: no state on the host, no
/// writer of its text (tripwires 2, 3, 6, 7). The height lands on the
/// caller's own `@State`, and only when it moved by a point or more, so the
/// frame change it causes measures the same and stops there.
struct EditorHeightProbe: NSViewRepresentable {
    let onHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onHeight = onHeight
        view.find()
    }

    /// The height a text view's text needs: its used rect, below the
    /// container's origin, plus the bottom inset. Pure.
    static func neededHeight(usedHeight: CGFloat, originY: CGFloat, insetHeight: CGFloat) -> CGFloat {
        (usedHeight + originY + insetHeight).rounded(.up)
    }

    final class ProbeView: NSView {
        var onHeight: (CGFloat) -> Void = { _ in }
        private weak var watched: MaughamTextView?
        private var observers: [NSObjectProtocol] = []
        private var searching = false
        private var reported: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            find()
        }

        /// Look for the editor on a short step, a bounded number of times
        /// (it binds a beat after it mounts); nothing while one is watched.
        func find() {
            guard watched == nil, !searching, window != nil else { return }
            searching = true
            attempt(remaining: EditorFocusProbe.ProbeView.attempts)
        }

        private func attempt(remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + EditorFocusProbe.ProbeView.step) { [weak self] in
                guard let self else { return }
                if let window = self.window, let editor = EditorFocusProbe.editor(over: self, in: window) {
                    self.searching = false
                    self.watch(editor)
                    return
                }
                if remaining > 0 { self.attempt(remaining: remaining - 1) } else { self.searching = false }
            }
        }

        private func watch(_ editor: MaughamTextView) {
            stopWatching()
            watched = editor
            let centre = NotificationCenter.default
            let remeasure: @Sendable (Notification) -> Void = { [weak self] _ in
                DispatchQueue.main.async { self?.measure() }
            }
            observers.append(centre.addObserver(forName: NSText.didChangeNotification,
                                                object: editor, queue: .main, using: remeasure))
            observers.append(centre.addObserver(forName: NSView.frameDidChangeNotification,
                                                object: editor, queue: .main, using: remeasure))
            if let storage = editor.textStorage {
                // The text set from outside (a load, another host's write).
                observers.append(centre.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                    object: storage, queue: .main, using: remeasure))
            }
            measure()
        }

        private func stopWatching() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        private func measure() {
            guard let editor = watched, let layout = editor.layoutManager,
                  let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = EditorHeightProbe.neededHeight(
                usedHeight: layout.usedRect(for: container).height,
                originY: editor.textContainerOrigin.y,
                insetHeight: editor.textContainerInset.height)
            guard abs(height - reported) >= 1 else { return }
            reported = height
            onHeight(height)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
