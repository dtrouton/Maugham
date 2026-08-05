import SwiftUI
import AppKit

/// **⌘R's delivery path, and every way the session has to die.**
///
/// Extracted from `ProjectWindow.body` for that file's standing reason (the
/// SwiftUI type-checker ceiling), but the grouping is real: the four things
/// below are one subject — the run key, and the three moments at which the
/// `claude` subprocess must stop existing. `ClaudeCLISession` cannot defend
/// itself (its `deinit` is nonisolated and cannot reach its own child), so a
/// missed teardown here is a live, billing process outliving the window that
/// started it.
///
/// The fourth moment — the window closing — is `ProjectWindow`'s own
/// `.onDisappear`, because it also has to drop the orchestrator's hold on the
/// project's stores (`detach()`), and that scorch already lives there.
struct CompilerRunModifier: ViewModifier {
    let orchestrator: CompilerOrchestrator
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
            .onGlobalEvent(.maughamAppWillTerminate) { _ in
                orchestrator.shutdown()
            }
            .onChange(of: mcpEnabled) { _, enabled in
                if !enabled { orchestrator.shutdown() }
            }
    }
}
