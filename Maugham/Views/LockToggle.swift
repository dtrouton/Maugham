import SwiftUI

/// **The window's Lock** (shell p1 Task 5): what the old Review mode's
/// read-only research, palette and figure surfaces became once no window mode
/// decided them.
///
/// Per window, never stored: every window opens unlocked (`atOpen`), and
/// nothing in `UIState` carries it. **Lock only adds refusals.** Every site
/// that asks it asks the window's posture and share beside it, in the same
/// position, unchanged — a read-only share, a narrowed book or a piece owned
/// by someone else refuses with Lock off, and Lock off never answers for them.
///
/// **It does not lock the manuscript text.** A piece's read-through (⌘⌥⇧R)
/// is a separate control and Lock does not reach it.
///
/// `refusesEdits(isLocked:)` is the ONE answer; every lock site reads it
/// (`LockTests.test_everyLockSiteAsksTheOneAnswer` names them), so making
/// Lock refuse nothing is a one-line change and the disable experiment.
enum WindowLock {
    /// What a window opens with: unlocked.
    static let atOpen = false

    /// Does this window's Lock refuse an edit to research, a palette card, a
    /// figure, or a New Table? Asked beside the posture, never in its place.
    static func refusesEdits(isLocked: Bool) -> Bool { isLocked }
}

extension PulledUp {
    /// **Lock's half of "may this be edited beside?"**, asked beside the
    /// posture and never in its place (`WindowLock`). A statement's posture is
    /// asked of `statement` through `StatementEditorHost.postureDocId`.
    func refusesEdits(isLocked: Bool) -> Bool {
        !isEditableBeside || (lockApplies && WindowLock.refusesEdits(isLocked: isLocked))
    }
}

/// The toolbar's Lock: `lock` when locked, `lock.open` when not. It rides the
/// window toolbar, so `⌘\` focus mode hides it with the
/// toolbar (`ProjectWindow.TopChromeModifier`).
struct LockToggle: View {
    @Binding var isLocked: Bool

    static func symbol(isLocked: Bool) -> String { isLocked ? "lock" : "lock.open" }

    /// What a press does — the accessibility label, and the View menu's
    /// item (⌘⌥⇧L) in its own capitals (`menuTitle`). Named for what it
    /// locks: research and figures, never the manuscript.
    static func help(isLocked: Bool) -> String {
        isLocked ? "Unlock research and figures" : "Lock research and figures"
    }

    /// View ▸ Lock Research and Figures, titled for what a press does.
    static func menuTitle(isLocked: Bool) -> String {
        isLocked ? "Unlock Research and Figures" : "Lock Research and Figures"
    }

    /// The padlock's tooltip: what a press does, that the manuscript is not
    /// what it locks (a padlock otherwise reads as "lock my book"), and its
    /// key.
    static func tooltip(isLocked: Bool) -> String {
        isLocked
            ? "Unlock research and figures (\u{2318}\u{2325}\u{21E7}L)"
            : "Lock research and figures so they can be read but not changed. "
                + "Your manuscript stays editable. (\u{2318}\u{2325}\u{21E7}L)"
    }

    var body: some View {
        Button {
            isLocked.toggle()
        } label: {
            Image(systemName: Self.symbol(isLocked: isLocked))
        }
        .help(Self.tooltip(isLocked: isLocked))
        .accessibilityLabel(Self.help(isLocked: isLocked))
        .accessibilityValue(isLocked ? "Locked" : "Unlocked")
        .accessibilityIdentifier("windowLock")
    }
}
