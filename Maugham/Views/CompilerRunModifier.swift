import SwiftUI
import AppKit
import MaughamCore

/// **The run keys' delivery path, and every way the session has to die.**
///
/// Extracted from `ProjectWindow.body` for that file's standing reason (the
/// SwiftUI type-checker ceiling), but the grouping is real: the things below
/// are one subject — the four run commands (`RunCommand`: a check or a round,
/// each warm or read cold), and the three moments at which the `claude` subprocess must
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
    let window: NSWindow?
    /// The window's subject: what a run reads is `request`'s answer from it,
    /// not this modifier's.
    let subject: WindowSubject
    /// The book's structure, so a Part on the faces is not taken for a piece.
    let structure: [StructureItem]
    /// `UserPreferences.mcpEnabled` — the one toggle that governs outbound as
    /// well as inbound (spec §3.5). Passed as a value so `.onChange` sees it;
    /// the session enforces the toggle again on every send, and this is what
    /// kills a session already warm when the writer turns Claude off.
    let mcpEnabled: Bool

    /// **What a run command asks the compiler for** — pure, so which verb a
    /// keystroke is and which piece it reads can be asserted with no window
    /// (tripwire 33). The COMMAND names the kind (`RunCommand.kind`): ⌘R is a
    /// check wherever the writer stands, and a round is asked for by name.
    struct RunKeyRequest: Equatable {
        let docId: String
        let kind: RunKind
        let freshEyes: Bool
    }

    /// **The piece a run reads**: the faces' piece when they name one, else the
    /// open piece, else none — and with none the run is a no-op, as it is with
    /// no window in front. So a run with the Canvas, an edition or the Inbox
    /// open reads the piece the right column faces, and never the open thing.
    /// A Part is not a piece (`ClickRule.isPiece`): a Part on the faces falls
    /// through to the open piece.
    static func runDocId(for subject: WindowSubject, structure: [StructureItem]) -> String? {
        func piece(_ s: BinderSubject) -> String? {
            guard let id = s.itemID, ClickRule.isPiece(id, in: structure) else { return nil }
            return id
        }
        return piece(subject.faces) ?? piece(subject.open)
    }

    static func request(_ command: RunCommand, subject: WindowSubject,
                        structure: [StructureItem]) -> RunKeyRequest? {
        guard let docId = runDocId(for: subject, structure: structure) else { return nil }
        return RunKeyRequest(docId: docId, kind: command.kind, freshEyes: command.isFreshEyes)
    }

    private func send(_ command: RunCommand) {
        guard let request = Self.request(command, subject: subject, structure: structure) else { return }
        roster.compiler.runRequested(
            docId: request.docId, kind: request.kind, freshEyes: request.freshEyes)
    }

    func body(content: Content) -> some View {
        content
            // Four arms, one per command, rather than a branch inside one: the
            // four keystrokes are four promises (a delta or the piece whole, a
            // check or a round), and the orchestrator is the one place that
            // knows what each costs.
            .onKeyWindowCommand(.maughamRunCompiler, window: window) { _ in send(.checkWriting) }
            .onKeyWindowCommand(.maughamFreshEyesCompiler, window: window) { _ in send(.reread) }
            .onKeyWindowCommand(.maughamRunRound, window: window) { _ in send(.runRound) }
            .onKeyWindowCommand(.maughamFreshEyesRound, window: window) { _ in send(.freshEyes) }
            .onGlobalEvent(.maughamAppWillTerminate) { _ in
                roster.shutdownAll()
            }
            .onChange(of: mcpEnabled) { _, enabled in
                guard !enabled else { return }
                roster.shutdownAll()
            }
    }
}
