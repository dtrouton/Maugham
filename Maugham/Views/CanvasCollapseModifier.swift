import SwiftUI
import MaughamCore
import AppKit

/// `⌘\` on the canvas additionally collapses both side columns (spec §8A.3),
/// leaving the writer the canvas and nothing else.
///
/// **No second subscription.** `⌘\` posts `.maughamToggleNoChrome` once, to
/// `.keyWindow`, and `FocusPostureModifier` above already receives it; a second
/// `.onKeyWindowCommand` for the same name in the same window is tripwire 21's
/// territory. This modifier watches the *flag* that handler flips, so there is
/// still exactly one receiver.
///
/// **`⌘⇧F` is the second entry, and it is INTENDED.** `toggleFullScreen` sets
/// `isNoChromeOn = true`, so full-screen focus — the *stronger* gesture —
/// collapses the canvas exactly as `⌘\` does. Watching the flag rather than
/// the keystroke makes both entries one behaviour, and both exits work: the
/// flag goes off and the release arm runs.
///
/// **Never automatic on entering the persona.** The collapse is (the canvas
/// is the centre column) AND (the writer asked for focus mode): the binder
/// is needed to drag research and captures onto the canvas. The palette
/// wall auto-hides on entry; §8A.3 says the canvas does not follow it.
///
/// **One interaction worth knowing**: `CanvasClaudeArrivalModifier
/// .Destination` force-opens the inspector so *Show* names what arrived. For
/// a writer in focus mode arriving from another persona, `persona` changes
/// and this modifier collapses one pass later, closing that pane again (the
/// cards are still revealed; `⌘\` brings the naming back). Already on the
/// collapsed canvas, neither trigger fires and Show works as written.
struct CanvasCollapseModifier: ViewModifier {
    /// The window's working mode — `inspectorRoute`'s basis, and therefore one
    /// of this modifier's two triggers.
    let persona: Persona
    let projectType: ProjectType
    let isNoChromeOn: Bool
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var showInspector: Bool
    @Binding var inspectorWasVisibleBeforeCanvasCollapse: Bool?

    func body(content: Content) -> some View {
        content
            .onChange(of: isNoChromeOn) { _, _ in apply() }
            // **The other input of the route.** The decision reads the persona
            // and the project type, and the project type cannot change under a
            // live window — so these two triggers are the whole of what can move
            // the answer. A trigger that watches less than its rule reads lags it.
            .onChange(of: persona) { _, _ in apply() }
    }

    /// Both triggers fold the same decision, and the decision is idempotent —
    /// they fire together on a project reopen that restores focus mode *and*
    /// Plan from `UIState`, and the second one must not stash over the first.
    private func apply() {
        let route = ProjectWindow.inspectorRoute(persona: persona,
                                                 projectType: projectType)
        ProjectWindow.applyCanvasCollapse(
            ProjectWindow.canvasCollapse(
                route: route,
                isNoChromeOn: isNoChromeOn,
                showInspector: showInspector,
                stash: inspectorWasVisibleBeforeCanvasCollapse),
            columnVisibility: &columnVisibility,
            showInspector: &showInspector,
            stash: &inspectorWasVisibleBeforeCanvasCollapse)
    }
}
