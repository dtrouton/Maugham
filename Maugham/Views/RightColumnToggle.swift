import SwiftUI

/// **The toolbar's right-column button** (owner, 2026-11-21: the column could
/// be hidden only from View ▸ Hide Right Column, which was not found).
/// The trailing edge's mirror of the sidebar's own toggle, `sidebar.right`,
/// drawn whether the column shows or not.
///
/// **One write, the menu's.** A press flips the window's `showInspector`,
/// exactly as ⌘⌥0's receiver (`ProjectWindow`'s `.maughamToggleInspector`)
/// does. So it behaves as the menu item
/// does everywhere: with the palette wall holding the column hidden, a press
/// shows it (the wall's stash is written only by the wall's own open and
/// close). The canvas's `⌘\` collapse happens only in focus mode, where this
/// button is hidden with the toolbar; ⌘⌥0 still shows the column there, and
/// `canvasCollapse` answers `.unchanged` rather than hiding it again. The column's
/// width (`detailColumnWidth`) and position (`rightColumnPosition`) are window
/// state the flip does not touch, so a hide and show brings back the same
/// column at the same width on the same position.
///
/// It rides the window toolbar, so `⌘\` focus mode hides it with the rest
/// (`ProjectWindow.windowToolbarIsVisible`).
struct RightColumnToggle: View {
    @Binding var showInspector: Bool

    static let symbol = "sidebar.right"

    /// The tooltip: what a press does, and its key.
    static func tooltip(shown: Bool) -> String {
        "\(RightColumn.toggleTitle(shown: shown)) (\u{2318}\u{2325}0)"
    }

    var body: some View {
        Button {
            showInspector.toggle()
        } label: {
            Image(systemName: Self.symbol)
        }
        .help(Self.tooltip(shown: showInspector))
        .accessibilityLabel(RightColumn.toggleTitle(shown: showInspector))
        .accessibilityIdentifier("rightColumnToggle")
    }
}
