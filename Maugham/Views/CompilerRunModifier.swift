import SwiftUI
import AppKit

/// **The run keys' delivery path, and every way the session has to die.**
///
/// Extracted from `ProjectWindow.body` for that file's standing reason (the
/// SwiftUI type-checker ceiling), but the grouping is real: the things below
/// are one subject — the two run keys (⌘R's delta and ⌘⇧R's cold read of the
/// whole piece), and the three moments at which the `claude` subprocess must
/// stop existing. Fresh eyes retires the session too, but from the inside:
/// it is a run rather than a teardown, so the retirement is the
/// orchestrator's (`runRequested(docId:freshEyes:)`) and not a fourth arm
/// here. `ClaudeCLISession` cannot defend
/// itself (its `deinit` is nonisolated and cannot reach its own child), so a
/// missed teardown here is a live, billing process outliving the window that
/// started it.
///
/// The fourth moment — the window closing — is `ProjectWindow`'s own
/// `.onDisappear`, because it also has to drop the orchestrator's hold on the
/// project's stores (`detach()`), and that scorch already lives there.
///
/// **There are THREE session owners now** (publish department P2 and P3): the
/// translator's loop and the designer's each spawn their own long-lived
/// `claude` and inherit the same contract whole, so every teardown arm below
/// carries two sibling calls. `TranslatorEnvironmentTests`' census is what keeps
/// them paired — a run verb for either is P4's, so nothing else here would
/// notice one's absence.
struct CompilerRunModifier: ViewModifier {
    let orchestrator: CompilerOrchestrator
    /// The translator's session, torn down beside the compiler's. No run keys
    /// of its own yet — a translation is started from the desk (P4), not from
    /// the keyboard.
    let translator: TranslatorOrchestrator
    /// The designer's session, torn down beside the other two. Headless for the
    /// same reason: a design round is started from the desk (P4).
    let designer: DesignerOrchestrator
    let window: NSWindow?
    /// The window's subject as a document id, or the no-document sentinel.
    /// Resolved by the window, not here: this modifier has no opinion about
    /// what the tree is naming.
    let activeDocId: String
    /// `UserPreferences.mcpEnabled` — the one toggle that governs outbound as
    /// well as inbound (spec §3.5). Passed as a value so `.onChange` sees it;
    /// the session enforces the toggle again on every send, and this is what
    /// kills a session already warm when the writer turns Claude off.
    let mcpEnabled: Bool

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamRunCompiler, window: window) { _ in
                orchestrator.runRequested(docId: activeDocId)
            }
            // The cold read (⌘⇧R). A second arm rather than a branch inside
            // the first: the two keystrokes are two promises, and the
            // orchestrator is the one place that knows what the difference
            // costs.
            .onKeyWindowCommand(.maughamFreshEyesCompiler, window: window) { _ in
                orchestrator.runRequested(docId: activeDocId, freshEyes: true)
            }
            .onGlobalEvent(.maughamAppWillTerminate) { _ in
                orchestrator.shutdown()
                translator.shutdown()
                designer.shutdown()
            }
            .onChange(of: mcpEnabled) { _, enabled in
                guard !enabled else { return }
                orchestrator.shutdown()
                translator.shutdown()
                designer.shutdown()
            }
    }
}
