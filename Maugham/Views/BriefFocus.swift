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
/// asked (`wanted`), and reports when it did. The statement editor binds its
/// `Document` a beat after it mounts, so the probe looks again on a short
/// step a bounded number of times, then gives up quietly. It finds the
/// editor as the centre's cover finds its own: a `MaughamTextView` whose
/// visible frame lies within this one (`CentreKeysView.coverEditor`).
struct EditorFocusProbe: NSViewRepresentable {
    let wanted: Bool
    let onFocused: () -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onFocused = onFocused
        if wanted { view.claim() }
    }

    final class ProbeView: NSView {
        var onFocused: () -> Void = {}
        private var generation = 0
        static let step: TimeInterval = 0.05
        static let attempts = 20

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func claim() {
            generation += 1
            attempt(generation, remaining: Self.attempts)
        }

        private func attempt(_ generation: Int, remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.step) { [weak self] in
                guard let self, generation == self.generation else { return }
                if let window = self.window, let editor = self.editor(in: window),
                   window.makeFirstResponder(editor) {
                    self.onFocused()
                    return
                }
                if remaining > 0 { self.attempt(generation, remaining: remaining - 1) }
            }
        }

        private func editor(in window: NSWindow) -> MaughamTextView? {
            guard let root = window.contentView else { return nil }
            let mine = convert(bounds, to: nil)
            return CentreKeysView.all(MaughamTextView.self, in: root).first { editor in
                !CentreKeys.isManuscriptEditor(editor)
                    && CentreKeys.lies(CentreKeysView.visibleFrame(of: editor), within: mine)
            }
        }
    }
}
