import AppKit
import SwiftUI
import MaughamCore

/// **Escape puts the pulled-up thing away** (shell plan 3 Task 9), as the
/// highest-priority consumer of the window's one `WindowEscapeArbiter` — the
/// same instance the centre item's cover and the canvas's dim register with.
///
/// It claims the key **only while the pulled-up thing is on screen**
/// (`PulledUpEscapeModifier.claims`): something is pulled up, the column is
/// shown on the pulled-up position, and ⌘\ has not taken the chrome. An
/// invisible claim would spend the writer's Escape on nothing they can see.
///
/// Not a `.keyboardShortcut(.cancelAction)` on the close button: a key
/// equivalent is consulted before the responder chain, so Escape would stop
/// cancelling the tree's inline rename (tripwire 16) and the find bar. The
/// arbiter applies `CanvasEscapeMonitor.disposition`'s refusals once — among
/// them, a text view with the caret keeps its Escape, so a pulled-up note
/// being typed in is not closed under the writer.
@MainActor
final class PulledUpEscape {
    /// Read at EVENT time, refreshed by every `sync`.
    private var isPresented = false
    private var close: () -> Void = {}
    /// The arbiter this consumer is registered with. Held weakly: the table
    /// in `WindowEscapeArbiter` owns them, keyed by window.
    private weak var arbiter: WindowEscapeArbiter?

    /// Registered, on a window whose monitor is armed.
    var isInstalled: Bool {
        guard let arbiter else { return false }
        return arbiter.isRegistered(.pulledUp) && arbiter.isArmed
    }

    /// Register or resign to match the pulled-up thing's presentation.
    /// Idempotent in both directions.
    func sync(isPresented: Bool, window: NSWindow?, close: @escaping () -> Void) {
        self.isPresented = isPresented
        self.close = close
        guard isPresented, let window else {
            stop()
            return
        }
        let target = WindowEscapeArbiter.arbiter(for: window)
        if let previous = arbiter, previous !== target {
            previous.resign(.pulledUp)
        }
        target.register(.pulledUp, claim: { [weak self] in
            self?.performEscape() ?? false
        })
        arbiter = target
    }

    func stop() {
        arbiter?.resign(.pulledUp)
        arbiter = nil
    }

    /// What the arbiter's offer does: close and claim the key, or decline so
    /// the offer passes down. Internal so the decision is assertable without
    /// an `NSEvent`.
    @discardableResult
    func performEscape() -> Bool {
        guard isPresented else { return false }
        close()
        return true
    }
}

/// The mount: every input the claim reads is watched, and each change syncs.
/// It inserts no view. It rides the window's body rather than the right
/// column, which is behind `showInspector` and would take the registration
/// down every time the writer hid it.
struct PulledUpEscapeModifier: ViewModifier {
    let window: NSWindow?
    let isNoChromeOn: Bool
    let showInspector: Bool
    let position: RightColumnPosition
    @Binding var subject: WindowSubject

    @State private var escape = PulledUpEscape()

    /// **Whether Escape is the pulled-up thing's**: one is pulled up and it
    /// is what the right column is showing. Pure.
    static func claims(pulledUp: PulledUp?, position: RightColumnPosition,
                       showInspector: Bool, isNoChromeOn: Bool) -> Bool {
        pulledUp != nil && position == .pulledUp && showInspector && !isNoChromeOn
    }

    private var presented: Bool {
        Self.claims(pulledUp: subject.beside, position: position,
                    showInspector: showInspector, isNoChromeOn: isNoChromeOn)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: presented, initial: true) { _, _ in sync() }
            // The arbiter is keyed by window, and `WindowAccessor` reports
            // one asynchronously after mount.
            .onChange(of: window) { _, _ in sync() }
            .onDisappear { escape.stop() }
    }

    private func sync() {
        escape.sync(isPresented: presented, window: window, close: {
            subject = ProjectWindow.closingBeside(subject)
        })
    }
}
