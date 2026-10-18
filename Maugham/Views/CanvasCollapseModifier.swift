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
/// `isNoChromeOn = true` on the way into full screen, so full-screen focus
/// collapses the canvas exactly as `⌘\` does. That is the right answer rather
/// than an accident to guard: full-screen focus is the *stronger* of the two
/// gestures — it already takes the whole screen — and a version of it that left
/// the binder and the inspector standing would be the weaker one. Watching the
/// flag rather than the keystroke is what makes both entries one behaviour; a
/// guard would have to name `⌘\` specifically and would then need a second
/// exit rule for the leaving-full-screen path. Both exits already work: the
/// flag goes off, and the release arm runs.
///
/// **Never automatic on entering the persona.** The collapse is a function of
/// (the canvas is the centre column) AND (the writer asked for focus mode), so
/// arriving on the canvas with focus mode off does nothing at all — you need the
/// binder open to drag research and captures onto the canvas, and only *then* do
/// you want it gone. The palette wall's `PaletteWallModifier` does auto-hide
/// on entry; §8A.3 says in those words that the canvas does not follow it.
///
/// **The interaction worth knowing about, and it is true of ONE of the two
/// cases.** `CanvasClaudeArrivalModifier.Destination` force-opens the inspector
/// so *Show* names what arrived. For a writer in focus mode:
///
/// - **arriving from another persona** — `persona` changes, so this modifier
///   collapses one pass later and that force-open closes again. The cards are
///   still revealed and selected by the camera move; `⌘\` brings the naming
///   back.
/// - **already on the collapsed canvas** — the persona does not change, neither
///   trigger fires, and the pane stays open beside the collapse. Show works as
///   written.
///
/// So the case that loses the naming pane is the *jump*, not the local reveal.
struct CanvasCollapseModifier: ViewModifier {
    /// The window's working mode — `inspectorRoute`'s basis since stage 2b
    /// Task 6, and therefore one of this modifier's two triggers.
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
            // the answer. It joined in stage 2b Task 6, beside the binder
            // segment the route read then; Task 7 took that half, and watching
            // only what used to be the whole answer is exactly how a trigger
            // comes to lag its own rule.
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
