import Foundation
import MaughamCore

/// **The production wiring: one project window's stores, as the closures the
/// orchestrator runs on.**
///
/// Separate from `CompilerOrchestrator.swift` so that file names no store. The
/// `Environment` seam exists to keep the run logic testable without a project
/// on disk, and a factory sitting beside it that reaches for `ProjectStore`
/// would quietly re-couple the two.
///
/// **Every capture is weak.** `ProjectWindow.onDisappear` calls `detach()`,
/// which drops these closures — but SwiftUI never dismantles a closed window's
/// view graph, and an orchestrator that outlived one teardown path while
/// holding a strong `ProjectStore` would keep the whole project in memory with
/// nothing on screen. The weak captures make that impossible rather than
/// merely unlikely; `detach()` is still what stops the *session*, which no
/// capture policy can do.
extension CompilerOrchestrator.Environment {

    @MainActor
    static func production(
        store: ProjectStore,
        documentStore: DocumentStore,
        projectURL: URL,
        preferences: UserPreferences,
        model: String = CompilerOrchestrator.defaultModel,
        onRunAcknowledged: @escaping @MainActor () -> Void
    ) -> CompilerOrchestrator.Environment {
        CompilerOrchestrator.Environment(
            projectId: ProjectIdentifier.id(for: projectURL),
            // The Diagnostics pane's gear menu (Task 8) — read once here at
            // `configure()` and kept current afterward by
            // `CompilerOrchestrator.updateModel(_:)`, which the gear menu calls
            // directly rather than re-running `production`.
            model: model,
            reading: { [weak documentStore] docId in
                // The OPEN document, by id — the live paragraphs, which lead
                // the derived `.md` by up to one debounce window (ADR 0018/0019,
                // tripwire 20). A doc that is not open has no unsaved delta to
                // check and no `Document` to read.
                guard let document = documentStore?.document(forDocId: docId) else {
                    return nil
                }
                return CompilerOrchestrator.DocumentReading(
                    ops: document.opLogSnapshot,
                    paragraphs: document.paragraphs,
                    sequence: document.sequence)
            },
            liveParagraphText: { [weak documentStore] docId, paragraphId in
                documentStore?.document(forDocId: docId)?.paragraph(id: paragraphId)
            },
            intent: { [weak store] docId in
                guard let store else { return (nil, projectScopeLabel) }
                if let piece = store.statement(kind: .intent, scope: .document(docId)) {
                    return (store.statementText(of: piece),
                            documentScopeLabel(forDocId: docId, in: store))
                }
                if let project = store.statement(kind: .intent, scope: .project) {
                    return (store.statementText(of: project), projectScopeLabel)
                }
                // Absence is valid and mints nothing (M1A's rule). The prompt
                // simply carries no intent section.
                return (nil, projectScopeLabel)
            },
            writeMCPConfig: {
                try ClaudeCLISession.writeMCPConfig(
                    bridgeBinary: bridgeBinary,
                    socketPath: BuildVariant.current.mcpSocketPath,
                    to: sessionConfigDirectory)
            },
            makeRunner: { configURL, model in
                ClaudeCLISession(
                    model: model,
                    mcpConfigPath: configURL,
                    cliOverride: nil,
                    // Read at every spawn, never captured as a value: a session
                    // already warm when the writer turns Claude off must not
                    // answer one more run. `nil` preferences means refuse,
                    // which is the safe direction.
                    isEnabled: { [weak preferences] in preferences?.mcpEnabled ?? false })
            },
            onRunAcknowledged: onRunAcknowledged)
    }

    // MARK: - What the prompt calls the intent's scope

    /// The project scope's name, in the prompt's voice.
    private static let projectScopeLabel = "the project"

    /// A document-scope intent is named by the document, because "this chapter"
    /// is a novel's word and this window may be showing a screenplay or a piece
    /// of a collection. The title is what the writer sees in the binder, so it
    /// is what the note reads back to them.
    @MainActor
    private static func documentScopeLabel(
        forDocId docId: String, in store: ProjectStore
    ) -> String {
        TreeWalk.find(id: docId, in: store.manifest.structure)?.title ?? "this document"
    }

    // MARK: - The session's bridge config

    /// The same binary the setup sheet points Claude Desktop at
    /// (`HelpClaudeDesktopSheet.binaryPath`) — the compiler reaches Maugham
    /// through the identical bridge, so there is nothing variant-specific here
    /// beyond `BuildVariant`'s own socket (tripwire 13).
    private static var bridgeBinary: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/maugham-mcp")
    }

    /// One directory for every session config this machine writes, so a config
    /// orphaned by a crash is findable rather than scattered through the temp
    /// root. The orchestrator deletes its own on shutdown.
    private static var sessionConfigDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("maugham-compiler", isDirectory: true)
    }
}
