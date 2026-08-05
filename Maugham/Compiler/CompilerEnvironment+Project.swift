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
            pinnedListing: { [weak store] docId in
                guard let store else { return [] }
                // The SAME attached-or-sidecar discriminator `list_canvas`
                // reads through — a compiler run must not disagree with
                // Claude's own `list_canvas` call about which canvas is real
                // (`CanvasTools.swift`'s doc comment on `ListCanvasTool`).
                let read = CanvasClaudeWrite.readScene(store: store, projectRoot: projectURL)
                let items = CanvasItemIndex.over(research: store.manifest.research)
                // `linkedResearchIds`, not `StructureItem.links` — the latter
                // is `InspectorLinksSection`'s unrelated document-to-document
                // backlink field (`draftLinks`); `ProjectStore.linkResearch`
                // (the writer's actual "link research to this document"
                // action) writes `linkedResearchIds`, and only that field
                // resolves against a research id.
                let links = store.linkedResearchIds(forDocumentId: docId)
                return PinnedReferences.pinned(
                    forDocId: docId, links: links, scene: read.scene,
                    scraps: read.scraps, items: items
                ).map(Self.pinnedListingLine)
            },
            paletteListing: { [weak store] in
                guard let store else { return [] }
                // `PaletteLookup.paletteCards(in:)` reads the manifest only —
                // no file parse — which is what makes this cheap enough to
                // resolve on every run rather than `ProjectStore.loadPalette
                // Cards()` (`list_palette_cards`'s own path), which parses
                // each card's markdown file for fields this listing does not
                // need (kind, swatches, notes).
                return PaletteLookup.paletteCards(in: store.manifest.research)
                    .map { "\($0.title) (\($0.id))" }
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

    // MARK: - Pinned-reference formatting

    /// One pinned reference as the run's context listing shows it — title,
    /// id, and the tool that fetches its full contents.
    ///
    /// `CompilerPrompt`'s section header already says "fetch full contents
    /// with read_document" for the whole pinned section, which predates the
    /// palette/photo/scrap kinds landing in the same union (Task 2). A kind
    /// whose real tool differs from the header's blanket claim says so on its
    /// own line rather than leave the header's claim uncorrected — a
    /// `.photo` pin has no read tool at all yet (Task 2's noted gap: Claude
    /// cannot see an owned picture's pixels), and a `.scrap`'s words are
    /// already inside `list_canvas`'s own response, not `read_document`'s.
    private static func pinnedListingLine(_ pin: PinnedReference) -> String {
        let base = "\(pin.title) (\(pin.id))"
        switch pin.kind {
        case .research: return "\(base) — read_document"
        case .palette: return "\(base) — read_palette_card"
        case .scrap: return "\(base) — list_canvas"
        case .photo: return "\(base) — no read tool yet, title only"
        }
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
