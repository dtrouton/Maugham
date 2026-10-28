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
/// orchestrator's (`runRequested(docId:kind:freshEyes:)`) and not a fourth
/// arm here. `ClaudeCLISession` cannot defend
/// itself (its `deinit` is nonisolated and cannot reach its own child), so a
/// missed teardown here is a live, billing process outliving the window that
/// started it.
///
/// The fourth moment — the window closing — is `ProjectWindow`'s own
/// `.onDisappear`, which gives its lease back (`sessions.release`). The
/// registry re-attaches the newest other live window on the project first,
/// then calls `ProjectSession.detachWindow`, which runs `roster.detachAll()`
/// only if the closing window was still the attached one
/// (`Maugham/Compiler/AREA.md`, Rules → "The session's lifetime").
///
/// **The services that die here are the roster's** (foundations plan 3,
/// Task 1). The compiler, the translator's and the designer's loops each own a
/// long-lived `claude`; `ColdCall` owns no warm session but can have a reader
/// or collator process in flight; and `TranslationPipeline` owns the WAITING
/// LEG — a round suspended on a continuation the translator's own summary
/// resumes. Every arm below used to spell all five out by name, so a sixth
/// service had to be remembered into each. Now each arm makes one call,
/// `roster.shutdownAll()`, and the roster owns the list and the order (the
/// pipeline first, so a parked leg answers cancelled before the translator it
/// waits on is gone). `TranslatorEnvironmentTests`' census checks that every
/// production class holding a session runner is a roster member, and that
/// both arms here make that call.
struct CompilerRunModifier: ViewModifier {
    /// The window's `claude` services. The run keys reach the compiler
    /// through it; the teardown arms reach all of them.
    let roster: AgentRoster
    /// **The window's persona — the loop the writer is standing in.**
    ///
    /// The one thing here that is not a session or a subject, and it is here
    /// because this is the one place a run key is pressed: `RunKind.of` is
    /// asked exactly once per keystroke, and every other caller of
    /// `runRequested` belongs to one loop by construction and says so
    /// literally. `TripwireGrepTests`' census pins that this file is the only
    /// production site that mints a kind from a persona — a second one would
    /// be a second answer to which verb a keystroke is.
    let persona: Persona
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

    /// **What a run key asks the compiler for** — pure, so which verb a
    /// keystroke is can be asserted with no window (tripwire 33). Both keys
    /// mint their kind from the persona here: a cold read in Review is a cold
    /// ROUND, not an ordinary check.
    struct RunKeyRequest: Equatable {
        let docId: String
        let kind: RunKind
        let freshEyes: Bool
    }

    static func request(freshEyes: Bool, persona: Persona, docId: String) -> RunKeyRequest {
        RunKeyRequest(docId: docId, kind: RunKind.of(persona: persona), freshEyes: freshEyes)
    }

    private func send(_ request: RunKeyRequest) {
        roster.compiler.runRequested(
            docId: request.docId, kind: request.kind, freshEyes: request.freshEyes)
    }

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamRunCompiler, window: window) { _ in
                send(Self.request(freshEyes: false, persona: persona, docId: activeDocId))
            }
            // The cold read (⌘⇧R). A second arm rather than a branch inside
            // the first: the two keystrokes are two promises, and the
            // orchestrator is the one place that knows what the difference
            // costs.
            .onKeyWindowCommand(.maughamFreshEyesCompiler, window: window) { _ in
                send(Self.request(freshEyes: true, persona: persona, docId: activeDocId))
            }
            .onGlobalEvent(.maughamAppWillTerminate) { _ in
                roster.shutdownAll()
            }
            .onChange(of: mcpEnabled) { _, enabled in
                guard !enabled else { return }
                roster.shutdownAll()
            }
    }
}
