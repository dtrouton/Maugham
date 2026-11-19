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
/// **It does not lock the manuscript text.** `EditorControl.isManualReviewMode`
/// (⌘⌥⇧R) is a separate control and Lock does not reach it.
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

    /// What a press does — the tooltip and the accessibility label alike.
    static func help(isLocked: Bool) -> String {
        isLocked ? "Unlock research and figures" : "Lock research and figures"
    }

    var body: some View {
        Button {
            isLocked.toggle()
        } label: {
            Image(systemName: Self.symbol(isLocked: isLocked))
        }
        .help(Self.help(isLocked: isLocked))
        .accessibilityLabel(Self.help(isLocked: isLocked))
        .accessibilityValue(isLocked ? "Locked" : "Unlocked")
        .accessibilityIdentifier("windowLock")
    }
}
