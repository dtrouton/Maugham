import SwiftUI
import MaughamCore
import AppKit
import os

/// Subsystem from the running bundle id so dev/stable logs separate without
/// hardcoding "com.maugham" (tripwire 13 spirit).
private let _projectWindowLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "ProjectWindow")

/// Stable-per-launch session ID shared by all checkpoint captures in this process.
private let _checkpointSessionId: String = UUID().uuidString
/// Best-effort stable per-machine device ID for checkpoint attribution.
private let _checkpointDeviceId: String = MacDeviceID.current

enum ProjectActiveSheet: Identifiable {
    case projectSettings
    case claudeDesktop
    var id: Int { hashValue }
}

struct ProjectWindow: View {
    @State private var store: ProjectStore?
    @State private var documentStore: DocumentStore?
    @State private var loadError: String?
    @State private var isNoChromeOn: Bool = false
    /// Review posture (WF1): per-window annotate-only manuscript with focus +
    /// typewriter off. Owned here (tripwire 6: not on EditorHost) and threaded
    /// ONE-WAY down through EditorHost → EditorSurface → coordinator.
    @State private var isReviewModeOn: Bool = false
    @State private var window: NSWindow?
    @State private var metrics: EditorMetrics =
        EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0)
    @State private var showingSaveFlash: Bool = false
    /// The run key's own acknowledgment (M2 §3.1) — the same overlay, its own
    /// binding, because ⌘S and ⌘R can be pressed a second apart and one flash
    /// showing the other's word is worse than two.
    @State private var showingCompilerFlash: Bool = false
    /// What that capsule says — the acknowledgment's own word, not a constant,
    /// because the second ⌘R of a double-press says something different
    /// (`CompilerOrchestrator.Acknowledgment`).
    @State private var compilerFlashLabel: String =
        CompilerOrchestrator.Acknowledgment.started.flashLabel
    /// Which flash the pending hide belongs to — see `showCompilerFlash`.
    @State private var compilerFlashGeneration: Int = 0
    /// The Diagnostics pane's gear menu (M2 Task 8), seeded from
    /// `UIState.compilerModel` at `load()` and written back through
    /// `updateUIState` on change — the `outlineLayout` pattern.
    @State private var compilerModel: CompilerModelChoice = .standard
    /// What this window's tree names — the window's single subject (spec §3).
    /// Typed rather than a `String?` so no site can answer "is this a manuscript
    /// document?" by accident; see `BinderSubject`.
    @State private var selectedSubject: BinderSubject?
    @State private var selectedResearchId: String?
    @State private var selectedPaletteCardId: String?
    /// The inspector's visibility captured on entry to the palette segment, so
    /// leaving restores it exactly (spec: no stuck-hidden inspector). `nil` when
    /// not in palette. Owned by `PaletteSegmentModifier`.
    @State private var inspectorWasVisibleBeforePalette: Bool?
    /// The inspector's visibility captured when `⌘\` gave the canvas the whole
    /// window (spec §8A.3), so leaving restores it exactly. `nil` when the
    /// canvas is not collapsed — which is also how `canvasCollapse` knows a
    /// collapse is already in force. Owned by `CanvasCollapseModifier`, dropped
    /// by `PersonaModifier`.
    @State private var inspectorWasVisibleBeforeCanvasCollapse: Bool?
    /// The split view's own column visibility. `.automatic` until something
    /// collapses to the canvas, so a window that never uses `⌘\` on the canvas
    /// behaves exactly as it did before there was a binding here.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var binderSegment: BinderSegment = .manuscript
    @State private var activeSheet: ProjectActiveSheet?
    @State private var showInspector: Bool = true
    /// The right column's one width (shell-finish stage 1). Restored from
    /// `UIState` in `load()`; written back by the column's own drag handle and
    /// by nothing else — see `detailColumn`.
    @State private var detailColumnWidth: Double = UIState.defaultDetailColumnWidth
    /// The drag's starting width, so the gesture reads its own translation
    /// rather than accumulating. Mirrors `AssistantColumnModifier`.
    @State private var detailDragStartWidth: Double?
    /// The window content's measured width, and the ONLY reason it is measured:
    /// the three columns' floors can out-arithmetic the window's own, and the
    /// right column is the one that has to give. `nil` until the first
    /// measurement arrives — see `effectiveDetailColumnWidth`, whose answer for
    /// `nil` is deliberately the conservative one.
    @State private var containerWidth: Double?
    @State private var showingTidyAllConfirmation: Bool = false
    @State private var sessionLog: SessionLog = .empty
    @State private var lastParsedScript: FountainScript? = nil
    @State private var showingSyntaxHelp: Bool = false
    @State private var researchPreviewVisible: Bool = false
    @State private var findActive: Bool = false
    @State private var pendingPieceRenameId: String?
    @State private var detailSegment: DetailSegment = .inspector
    @State private var persona: Persona = .default
    @State private var outlineLayout: OutlineLayout = .table
    @State private var mcpBanner = MCPBannerModel()
    @State private var showingCheckpointLabelSheet: Bool = false
    @State private var showingBootstrapNotice: Bool = false
    @State private var currentElement: String? = nil
    /// Resolved iCloud collaboration identity for THIS project, resolved once on
    /// open and again on a share-change (app re-activation), then cached. Drives
    /// both the sharing pill and — via `ReviewPosturePolicy` — the editor review
    /// posture. `nil` until the first resolve completes (treated as `.unknown`).
    /// Single resolve, threaded down; the pill no longer reads on its own
    /// (consolidation, per the WF1 task).
    @State private var collaborator: Collaborator?
    /// Control-plane model for the editor (ADR 0017). ProjectWindow is its sole
    /// posture/appearance writer; EditorHost writes the annotation set (Task 5).
    /// Threaded down to the coordinator, which observes it.
    @State private var editorControl = EditorControl()
    /// The canvas's scene, scraps, selection, sidecar store and undo recorder.
    /// Owned HERE rather than inside `CanvasView` because the region inspector in
    /// the right-hand column reads and mutates the same scene the centre column
    /// draws — and region labels do not live in the manifest, so a `ProjectStore`
    /// could not carry them.
    @State private var canvasModel = CanvasModel()
    /// The compiler's run state and its warm `claude` session (M2). Owned here
    /// for the canvas model's reason: the Diagnostics pane in the right-hand
    /// column reads the run the centre column's ⌘R started. Wired in `load()`,
    /// where the stores exist; torn down in `.onDisappear`.
    @State private var compiler = CompilerOrchestrator()
    /// The Intent pane's two lower strata (declared-world Task 6): Claude's
    /// bible of what the manuscript has established, and the per-scope cache of
    /// its readings of the writer's statements.
    ///
    /// Owned here for the canvas model's and the compiler's reason — the pane
    /// that reads them is in the RIGHT column and the ruling verbs that
    /// invalidate the cache are reached from it, so a store constructed inside
    /// the pane would be a second cache the run never hits. Both are
    /// project-scoped and per-device, and both materialize their sidecar in
    /// `init`, so they are built in `load()` where the project URL exists and
    /// never from a view body.
    @State private var bible: BibleStore?
    @State private var declaredWorld: DeclaredWorldStore?

    /// The assistant column's subject and width (M2 §6.2). Owned here rather
    /// than in either column because the References pane that fills it is in the
    /// window's RIGHT column and the column itself is in the CENTRE.
    @State private var assistant = AssistantColumnModel()
    /// Raw share snapshot kept alongside `collaborator` for the pill's hover
    /// diagnostics (the `.help()` tooltip), so the resolver stays the single
    /// read path.
    @State private var shareSnapshot: ShareMetadata?
    /// Injected reader for the share metadata (real OS-backed Mac reader in
    /// production; substitutable in tests/previews).
    private let shareReader: ShareMetadataReading = ICloudShareMetadataReader()
    @Environment(UserPreferences.self) private var userPreferences
    @Environment(ProjectRegistry.self) private var mcpRegistry
    @Environment(\.openWindow) private var openWindow

    let url: URL

    var body: some View {
        Group {
            if let store, let documentStore {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    binderColumn(store: store)
                        .navigationSplitViewColumnWidth(
                            min: ProjectWindow.binderColumnFloor, ideal: 240)
                } content: {
                    contentColumn(store: store, documentStore: documentStore)
                } detail: {
                    detailColumn(store: store, documentStore: documentStore)
                }
                .overlay(alignment: .top) {
                    SaveFlashOverlay(isShowing: $showingSaveFlash)
                }
                .overlay(alignment: .top) {
                    SaveFlashOverlay(isShowing: $showingCompilerFlash,
                                     label: compilerFlashLabel,
                                     systemImage: "text.magnifyingglass")
                }
                .overlay(alignment: .top) {
                    if let title = mcpBanner.title {
                        MCPNoteBanner(
                            title: title,
                            count: mcpBanner.count,
                            onShow: { handleShowLatestMCPNote() },
                            onDismiss: { mcpBanner.dismiss() }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: mcpBanner.title)
                .navigationTitle(store.manifest.title)
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .projectSettings:
                        ProjectSettingsSheet(store: store)
                    case .claudeDesktop:
                        HelpClaudeDesktopSheet()
                    }
                }
                .sheet(isPresented: $showingCheckpointLabelSheet) {
                    let projectURL = store.url
                    let allDocIds: [String] = Self.documentIds(in: store.manifest.structure)
                    CheckpointLabelPromptSheet(
                        onConfirm: { label in
                            showingCheckpointLabelSheet = false
                            Task { @MainActor in
                                let activeDoc = activeDocument(in: store, documentStore: documentStore)
                                try? await activeDoc?.flushBurstNow()
                                _ = try? await CheckpointCapture.run(
                                    projectURL: projectURL,
                                    activeDocId: activeDocId,
                                    allDocIds: allDocIds,
                                    device: _checkpointDeviceId,
                                    session: _checkpointSessionId,
                                    label: label,
                                    activeDocument: activeDoc)
                            }
                        },
                        onCancel: { showingCheckpointLabelSheet = false }
                    )
                }
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Couldn't open project").font(.headline)
                    Text(loadError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(48)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: ProjectWindow.windowFloor, minHeight: 540)
        .modifier(ContainerWidthReporter(onWidth: noteContainerWidth))
        .modifier(TopChromeModifier(
            projectURL: url,
            persona: persona,
            isNoChromeOn: isNoChromeOn,
            onSelectPersona: Self.postPersona))
        .background(WindowAccessor(window: $window))
        .task(id: url) { await load() }
        .onDisappear {
            mcpRegistry.unregister(url: url)
            // `Task { … }` captures `documentStore` by value, so nil-ing the
            // @State immediately after is safe — the close still runs on the
            // captured reference.
            Task { await documentStore?.close() }
            // Scorch the heavy @State on window close. SwiftUI never dismantles
            // a closed `WindowGroup` scene's view graph (`GraphHost.sharedGraph`
            // retains it — see the scene-storage spike note), but `.onDisappear`
            // DOES fire on close, so we empty the zombie ourselves: the Document
            // (paragraphs + op-log mirror), the derived-cache-bearing ProjectStore,
            // the DocumentStore, and the parsed FountainScript AST all drop here,
            // leaving only SwiftUI's AttributeGraph husk.
            //
            // GUARD on the window actually being gone (ADR 0021 liveness helper):
            // a spurious `.onDisappear` on a still-live window must NOT blank the
            // @State — `body` renders "Loading…" when `store == nil` and
            // `.task(id: url)` won't re-fire for the same url, so a live blank
            // would stick.
            if !MaughamEvent.isLive(window) {
                // Before the stores drop: the orchestrator's environment holds
                // closures over both of them, so a session left configured here
                // would keep the whole project graph alive in the husk — and
                // its `claude` subprocess alive with it.
                compiler.detach()
                store = nil
                documentStore = nil
                lastParsedScript = nil
            }
        }
        .modifier(CompilerRunModifier(orchestrator: compiler,
                                      window: window,
                                      activeDocId: activeDocId,
                                      mcpEnabled: userPreferences.mcpEnabled))
        .onKeyWindowCommand(.maughamToggleFullScreen, window: window) { _ in
            toggleFullScreen()
        }
        .onKeyWindowCommand(.maughamDummySave, window: window) { _ in
            Task {
                try? await documentStore?.flushPendingSave()
                showSaveFlash()
            }
        }
        .onKeyWindowCommand(.maughamShowProjectSettings, window: window) { _ in
            activeSheet = .projectSettings
        }
        .onKeyWindowCommand(.maughamShowClaudeDesktopHelp, window: window) { _ in
            activeSheet = .claudeDesktop
        }
        .onKeyWindowCommand(.maughamShareForReview, window: window) { _ in
            // Scoped command — only the focused project window acts, anchoring
            // the share sheet to its own NSWindow and reusing its resolved snapshot.
            guard let store else { return }
            ProjectShareSheetPresenter.present(
                projectURL: store.url, snapshot: shareSnapshot, in: window)
        }
        .onKeyWindowCommand(.maughamToggleInspector, window: window) { _ in
            showInspector.toggle()
        }
        .onGlobalEvent(.maughamAppWillTerminate) { _ in
            // Best-effort flush. Task is fire-and-forget; NSApplication may
            // give us only ~100ms before terminating us.
            if let ds = documentStore {
                Task { await ds.close() }
            }
        }
        .onKeyWindowCommand(.maughamShowProjectStatistics, window: window) { _ in
            openWindow(id: "project-stats", value: url)
        }
        .onProjectEvent(.maughamScriptDidUpdate, url: url, window: window) { note in
            // Scope to this window's project (Channel A, ADR 0021): the helper
            // delivers only own-project posts, so a foreign post (another window
            // flipping to a screenplay piece) never relayouts this editor or
            // clobbers this window's scene-navigator payload. NOT a key-window
            // guard — a background window's own MCP-driven re-parse still lands
            // here (it's live and on this project) and updates the navigator.
            if let script = note.object as? FountainScript {
                self.lastParsedScript = script
            }
        }
        .onChange(of: selectedSubject) { _, newValue in
            documentStore?.updateUIState { $0.selectedSubject = newValue }
            // Zero the inspector/footer metrics when the new selection is not a
            // document (group, no selection). The EditorCoordinator only
            // delivers `onMetricsChanged` while a document is bound, so it can't
            // clear them on deselection — this preserves the zeroing the old
            // `updateMetrics(for:)` guard performed.
            if !selectionIsDocument(newValue) {
                metrics = EditorMetrics(
                    wordCount: 0, characterCount: 0, readingMinutes: 0)
            }
        }
        .onChange(of: binderSegment) { _, newValue in
            documentStore?.updateUIState { $0.binderSegment = newValue }
        }
        .modifier(SubjectValidationModifier(store: store,
                                            selectedSubject: $selectedSubject))
        .modifier(SessionAndNavigationModifier(
            documentStore: documentStore,
            store: store,
            url: url,
            window: window,
            sessionLog: $sessionLog,
            selectedSubject: $selectedSubject,
            selectedResearchId: $selectedResearchId,
            binderSegment: $binderSegment,
            findActive: $findActive,
            pendingPieceRenameId: $pendingPieceRenameId,
            showingTidyAllConfirmation: $showingTidyAllConfirmation,
            showingSyntaxHelp: $showingSyntaxHelp,
            researchPreviewVisible: $researchPreviewVisible,
            showInspector: $showInspector,
            detailSegment: $detailSegment,
            persona: $persona,
            mcpBanner: mcpBanner))
        .modifier(CheckpointModifier(
            documentStore: documentStore,
            store: store,
            window: window,
            url: url,
            selectedItemId: activeItemID,
            activeDocId: activeDocId,
            showingCheckpointLabelSheet: $showingCheckpointLabelSheet,
            onSaveFlash: { showSaveFlash() }))
        .modifier(ParagraphNavModifier(window: window,
                                       binderSegment: $binderSegment,
                                       persona: $persona,
                                       detailSegment: $detailSegment,
                                       documentStore: documentStore,
                                       projectType: store?.manifest.type ?? .novel))
        .modifier(FocusPostureModifier(
            window: window,
            documentStore: documentStore,
            isNoChromeOn: $isNoChromeOn,
            isReviewModeOn: $isReviewModeOn,
            applyNoChrome: { applyNoChrome() }))
        .modifier(PersonaModifier(persona: $persona,
                                  detailSegment: $detailSegment,
                                  binderSegment: $binderSegment,
                                  showInspector: $showInspector,
                                  inspectorWasVisibleBeforePalette: $inspectorWasVisibleBeforePalette,
                                  inspectorWasVisibleBeforeCanvasCollapse:
                                    $inspectorWasVisibleBeforeCanvasCollapse,
                                  columnVisibility: $columnVisibility,
                                  window: window,
                                  documentStore: documentStore,
                                  projectType: store?.manifest.type ?? .novel))
        .sheet(isPresented: $showingSyntaxHelp) {
            SyntaxHelpSheet(mode: currentSyntaxHelpMode)
        }
        // Resolve the iCloud collaboration role ONCE per project URL (and again
        // on app re-activation — a pragmatic "the user may have just accepted a
        // share in Finder" trigger). Reads off the main actor's critical path;
        // the result is cached in @State and threaded one-way to the editor and
        // the pill. Never polled / per-render.
        .task(id: url) { await resolveCollaborator() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await resolveCollaborator() }
        }
        // Mirror posture + appearance into the EditorControl model (ADR 0017).
        // Extracted into a ViewModifier to stay under ProjectWindow.body's
        // SwiftUI type-checker ceiling (the extracted-ViewModifier pattern).
        .modifier(EditorControlMirrorModifier(
            effectivePosture: effectivePosture,
            effectiveTypography: effectiveTypography,
            editorControl: $editorControl))
        .modifier(TranslationReviewModifier(
            window: window,
            projectURL: url,
            activeDocId: activeDocId,
            editorControl: $editorControl))
        .modifier(PaletteSegmentModifier(
            binderSegment: binderSegment,
            showInspector: $showInspector,
            inspectorWasVisibleBeforePalette: $inspectorWasVisibleBeforePalette,
            selectedPaletteCardId: $selectedPaletteCardId))
        .modifier(CanvasPromotionModifier(window: window, store: store,
                                          model: canvasModel, binderSegment: binderSegment))
        // The writer's notice that Claude added cards to their canvas, and the way
        // to go and look. One line, because this body has no expression budget
        // (the Release type-check ceiling); the whole of the behaviour is in the
        // modifier, and THIS LINE is what makes it reachable — deleting it leaves
        // every token in that file present and every test green.
        .modifier(CanvasClaudeArrivalModifier(url: url, window: window,
                                              model: canvasModel,
                                              persona: $persona,
                                              binderSegment: $binderSegment,
                                              showInspector: $showInspector,
                                              documentStore: documentStore))
        // ⌘\ on the canvas collapses both side columns (spec §8A.3). One line,
        // because this body has no expression budget (the Release type-check
        // ceiling); the whole of the behaviour is in the modifier, and THIS LINE
        // is what makes it reachable — delete it and every token in the modifier
        // is still present, every decision test still green, and ⌘\ on the
        // canvas moves nothing.
        .modifier(CanvasCollapseModifier(
            binderSegment: binderSegment,
            projectType: store?.manifest.type ?? .novel,
            isNoChromeOn: isNoChromeOn,
            columnVisibility: $columnVisibility,
            showInspector: $showInspector,
            inspectorWasVisibleBeforeCanvasCollapse:
                $inspectorWasVisibleBeforeCanvasCollapse,
            inspectorWasVisibleBeforePalette: $inspectorWasVisibleBeforePalette))
        .preferredColorScheme(preferredColorScheme)
    }

    /// The persona bar's post. Mirrors `MaughamApp.postPersona(_:)` — the ⌘1–⌘4
    /// View-menu spelling — and shares its payload key via
    /// `MaughamEvent.personaKey` so the two cannot drift. `.keyWindow` scope:
    /// only the focused project window switches.
    ///
    /// A named `static func` rather than an inline closure in the modifier
    /// chain: `ProjectWindow.body` is at SwiftUI's type-checker ceiling (see
    /// `Maugham/Views/AREA.md`), and `static` keeps it from capturing `self`.
    private static func postPersona(_ next: Persona) {
        MaughamEvent.post(.maughamSetPersona,
                          to: .keyWindow,
                          payload: [MaughamEvent.personaKey: next.rawValue])
    }

    /// Reads the share metadata for this project off the main actor and folds it
    /// into a cached `Collaborator`. Idempotent; safe to call repeatedly.
    private func resolveCollaborator() async {
        let target = url
        let reader = shareReader
        let meta = await Task.detached(priority: .utility) {
            reader.read(for: target)
        }.value
        shareSnapshot = meta
        collaborator = ShareIdentityMapper.resolve(meta)
    }

    /// The resolved role, defaulting to `.unknown` until the first resolve lands.
    private var resolvedRole: CollaborationRole { collaborator?.role ?? .unknown }

    /// Effective review posture: combines the resolved role with the manual
    /// ⌘⌥⇧R toggle. `lockEditing` is the hard floor — a reviewer/unknown is locked
    /// regardless of the toggle, so the manual flag can never unlock the text.
    private var effectivePosture: ReviewPosturePolicy.Effective {
        ReviewPosturePolicy.effective(
            role: resolvedRole, manualReview: isReviewModeOn)
    }

    /// The typography the editor actually uses — manifest override else user
    /// default. Mirrors the value EditorHost passes to EditorSurface, so the
    /// control model and the (still-active) prop path agree during migration.
    private var effectiveTypography: TypographySettings {
        guard let store else { return userPreferences.typography }
        return ProjectStore.effectiveTypography(
            override: store.manifest.typography,
            userDefault: userPreferences.typography)
    }

    /// True when the resolved identity is a reviewer on a READ-ONLY iCloud
    /// share: they cannot append annotation ops, so the editor surfaces a clear
    /// "ask the owner for edit access" notice rather than failing silently.
    private var isViewOnlyReviewer: Bool {
        guard let c = collaborator else { return false }
        return c.role == .reviewer && c.canWrite == false
    }

    private var preferredColorScheme: ColorScheme? {
        switch userPreferences.theme {
        case .followSystem: return nil
        case .dark:         return .dark
        case .light, .sepia: return .light
        }
    }

    /// The persona bar, the top banners (software-update + backups-paused), and
    /// the focused project URL, pulled off `body` into a modifier so
    /// `ProjectWindow.body` stays under the SwiftUI type-checker's ceiling — the
    /// Release optimizer is stricter than Debug, so adding these inline built
    /// locally but failed the Release CI build.
    ///
    /// The persona bar is a WINDOW TOOLBAR item, not part of the safe-area
    /// strip below. A permanently non-zero top safe-area inset applied outside
    /// a `NavigationSplitView` occludes the top of every column — it cost the
    /// binder's `Pieces | Research | Trash` picker and the right pane's segment
    /// row (2026-07-25 smoke, defect A). The two banners keep the inset because
    /// they are zero-height except in the rare states that raise them, and they
    /// are deliberately *below* the toolbar in the reading order.
    ///
    /// `⌘\` focus mode hides the whole window toolbar rather than swapping the
    /// item for an empty one: a conditional inside `ToolbarItem` leaves a live
    /// (if empty) item and macOS keeps the taller unified titlebar, which is
    /// exactly the chrome `⌘\` exists to remove. `PersonaBar.isVisible` stays
    /// the single predicate.
    private struct TopChromeModifier: ViewModifier {
        let projectURL: URL
        let persona: Persona
        let isNoChromeOn: Bool
        let onSelectPersona: (Persona) -> Void

        private var toolbarVisibility: Visibility {
            PersonaBar.isVisible(isNoChromeOn: isNoChromeOn) ? .visible : .hidden
        }

        func body(content: Content) -> some View {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        UpdateBannerView()
                        BackupRecoveryBanner(projectURL: projectURL)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        PersonaBar(persona: persona, onSelect: onSelectPersona)
                    }
                }
                .toolbar(toolbarVisibility, for: .windowToolbar)
                .focusedSceneValue(\.projectURL, projectURL)
        }
    }

    /// Entering the palette segment hides the right pane so the wall gets width;
    /// leaving restores the pane's prior visibility exactly (spec: no stuck-hidden
    /// inspector). Kept out of ProjectWindow.body for the type-checker budget.
    /// A ⌘⌥N that sets `showInspector = true` while in palette wins — the user
    /// explicitly asked for the pane; we don't fight it.
    private struct PaletteSegmentModifier: ViewModifier {
        let binderSegment: BinderSegment
        @Binding var showInspector: Bool
        @Binding var inspectorWasVisibleBeforePalette: Bool?
        @Binding var selectedPaletteCardId: String?

        func body(content: Content) -> some View {
            content.onChange(of: binderSegment) { old, new in
                ProjectWindow.applyPaletteSegmentChange(
                    from: old, to: new,
                    showInspector: &showInspector,
                    stash: &inspectorWasVisibleBeforePalette,
                    selectedPaletteCardId: &selectedPaletteCardId)
            }
        }
    }

    private struct SessionAndNavigationModifier: ViewModifier {
        let documentStore: DocumentStore?
        let store: ProjectStore?
        let url: URL
        let window: NSWindow?
        @Binding var sessionLog: SessionLog
        @Binding var selectedSubject: BinderSubject?
        @Binding var selectedResearchId: String?
        @Binding var binderSegment: BinderSegment
        @Binding var findActive: Bool
        @Binding var pendingPieceRenameId: String?
        @Binding var showingTidyAllConfirmation: Bool
        @Binding var showingSyntaxHelp: Bool
        @Binding var researchPreviewVisible: Bool
        @Binding var showInspector: Bool
        @Binding var detailSegment: DetailSegment
        /// Written by `.maughamNavigateToDocument` alone, through
        /// `ManuscriptNavigation` — a navigation to a manuscript document moves
        /// the writer to Author when the persona they are in would not show it
        /// (Denver, 2026-08-02). Read by `.maughamCloseFind`, which returns the
        /// binder to THIS persona's home rather than to the document's.
        @Binding var persona: Persona
        let mcpBanner: MCPBannerModel

        func body(content: Content) -> some View {
            content
                .onKeyWindowCommand(.maughamSetDetailSegment, window: window) { note in
                    guard let raw = note.userInfo?[MaughamEvent.detailSegmentKey] as? String,
                          let seg = DetailSegment(rawValue: raw) else { return }
                    showInspector = true     // ensure pane is visible
                    detailSegment = seg
                }
                .onKeyWindowCommand(.maughamTidyAllFilenames, window: window) { _ in
                    showingTidyAllConfirmation = true
                }
                .onProjectEvent(.maughamSessionLogChanged, url: url, window: window) { _ in
                    Task {
                        sessionLog = (try? await documentStore?.loadSessionLog()) ?? .empty
                    }
                }
                // Project-scoped (ADR 0021), NOT key-window: a wiki-link click
                // OR a click in the separate stats-window scene must navigate
                // this project's window even when it isn't key.
                //
                // **The persona write on this path is cross-window, and that is
                // intended.** The scope is what makes the stats window work at
                // all — it is key, this window is not, and this window is the
                // one that must move. Taking it to the document while leaving
                // its persona bar on Plan would be half a navigation: the
                // window would draw a manuscript editor under a persona whose
                // own column does not offer one, which is exactly the state
                // Denver ruled out. Two windows open on ONE project both move,
                // which is the breadth `selectedSubject` and `binderSegment`
                // have always had here; `persona` is per-project state in
                // `UIState` beside `personaMemory`, shared last-writer-wins by
                // two windows by the same design.
                .onProjectEvent(.maughamNavigateToDocument, url: url, window: window) { note in
                    if let id = note.userInfo?["id"] as? String, let store {
                        // Screenplays have no Manuscript segment — their
                        // document home is the Scenes navigator. That, and
                        // whether this persona shows a document at all, are
                        // both `ManuscriptNavigation`'s to answer.
                        ManuscriptNavigation.go(
                            to: ManuscriptNavigation.destination(
                                from: persona,
                                currentBinderSegment: binderSegment,
                                currentDetailSegment: detailSegment,
                                projectType: store.manifest.type,
                                memory: documentStore?.uiState.personaMemory ?? .empty),
                            persona: $persona,
                            binderSegment: $binderSegment,
                            detailSegment: $detailSegment,
                            documentStore: documentStore)
                        selectedSubject = .item(id)
                    }
                }
                .onKeyWindowCommand(.maughamAddResearchFile, window: window) { _ in
                    Task {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = true
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = true
                        guard panel.runModal() == .OK else { return }
                        if let store {
                            do {
                                _ = try await store.importResearchFiles(
                                    panel.urls, toParentId: nil)
                            } catch {
                                // Non-fatal; user sees nothing happen
                            }
                        }
                    }
                }
                .onKeyWindowCommand(.maughamShowSyntaxHelp, window: window) { _ in
                    showingSyntaxHelp = true
                }
                .onKeyWindowCommand(.maughamRestoreLastDeleted, window: window) { _ in
                    Task {
                        try? await store?.restoreLastDeleted()
                    }
                }
                .onKeyWindowCommand(.maughamToggleResearchPreview, window: window) { _ in
                    researchPreviewVisible.toggle()
                    documentStore?.updateUIState {
                        $0.researchPreviewVisible = researchPreviewVisible
                    }
                }
                .onKeyWindowCommand(.maughamFindInProject, window: window) { _ in
                    binderSegment = .find
                }
                // **Closing Find returns the writer to THIS persona's home, not
                // to the manuscript's.** Identical in Author, Review and
                // Publish, whose binder home IS the document home; in Plan it
                // is the canvas.
                //
                // **It is deliberately not a `ManuscriptNavigation`.** Closing
                // find names no document — it fires with no match ever clicked —
                // so moving the writer to Author here would eject anyone who
                // opened `⌘⌥F` in Plan and changed their mind. What it DID do
                // was force `.manuscript` in Plan, which is the state Denver
                // ruled out, so the fix is to stop forcing the manuscript
                // rather than to follow it with a persona switch.
                //
                // `BinderPaneToggle` carries the same rule on
                // `.onChange(of: findActive)` — this post and that flag are two
                // routes out of one state and they must agree.
                .onKeyWindowCommand(.maughamCloseFind, window: window) { _ in
                    findActive = false
                    binderSegment = persona.binderHome(
                        for: store?.manifest.type ?? .novel)
                }
                // **A KNOWN GAP, recorded here so it stops being rediscovered.**
                // Found during slice 2 task 6 and again during task 5; it
                // predates the persona shell entirely.
                //
                // A RESEARCH match sets `selectedResearchId` and nothing else —
                // and while the binder is on `.find` the centre column is
                // `EditorHost` regardless (`existingEditorSwitch`'s
                // `case .manuscript, .scenes, .find`), so clicking a research
                // result shows the writer their manuscript. The selection only
                // becomes visible if they switch to `.research` by hand.
                //
                // **Deliberately not fixed here.** Making it right means giving
                // `.find` a centre column that follows the match's source, which
                // is a redesign of find's routing rather than a line in this
                // handler. And the obvious half-fix — landing on `.research`
                // when find closes — would add a THIRD event route forcing
                // `.research` in Author one commit after task 6 took research
                // out of Author's registry on purpose (`Persona.swift`'s
                // `.author` case names the other two).
                //
                // What task 5 DID remove is the way this compounded: closing
                // find used to slam the binder onto the manuscript, so a writer
                // in Plan who clicked a research result was left in a text
                // editor. Closing find now returns to the persona's own home.
                .onKeyWindowCommand(.maughamFindMatchSelected, window: window) { note in
                    guard let store,
                          let match = note.userInfo?["match"] as? SearchMatch else { return }
                    switch match.documentSource {
                    case .manuscript:
                        if let item = TreeWalk.first(
                            in: store.manifest.structure) { $0.path == match.documentPath } {
                            selectedSubject = .item(item.id)
                        }
                    case .research:
                        if let item = TreeWalk.first(
                            in: store.manifest.research) { $0.path == match.documentPath } {
                            selectedResearchId = item.id
                        }
                    }
                }
                .onProjectEvent(.maughamMCPNoteAdded, url: url, window: window) { note in
                    guard let info = note.userInfo,
                          let researchId = info["research_id"] as? String,
                          let title = info["title"] as? String else { return }
                    DispatchQueue.main.async {
                        mcpBanner.bump(title: title, latestId: researchId)
                    }
                }
                .modifier(CollectionPieceModifier(
                    store: store,
                    window: window,
                    selectedSubject: $selectedSubject,
                    pendingPieceRenameId: $pendingPieceRenameId))
                .alert("Renumber every chapter and scene?",
                       isPresented: $showingTidyAllConfirmation
                ) {
                    Button("Renumber", role: .destructive) {
                        Task {
                            do {
                                try await store?.tidyAllFilenames()
                            } catch {
                                // Best-effort; surfacing project-wide tidy errors
                                // is a future enhancement.
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Filenames in every group will be renumbered to fix gaps. This change is visible to other apps that read this folder.")
                }
        }

    }

    /// Handles the three collection-piece notifications in a separate modifier
    /// so that SessionAndNavigationModifier.body stays within the type-checker limit.
    private struct CollectionPieceModifier: ViewModifier {
        let store: ProjectStore?
        /// The owning project window. Key-window commands (ADR 0021):
        /// `.onKeyWindowCommand` scopes delivery to the key window, so "add a
        /// screenplay" adds it to the front project only. The collection-type
        /// and membership checks below are action preconditions, not scope guards.
        let window: NSWindow?
        @Binding var selectedSubject: BinderSubject?
        @Binding var pendingPieceRenameId: String?

        func body(content: Content) -> some View {
            content
                .onKeyWindowCommand(.maughamAddLoosePiece, window: window) { _ in
                    guard let store, store.manifest.type == .collection else { return }
                    Task {
                        let piece = try? await store.addLoosePiece(
                            title: "Untitled Piece", mode: .prose)
                        if let piece {
                            selectedSubject = .item(piece.id)
                            pendingPieceRenameId = piece.id
                        }
                    }
                }
                .onKeyWindowCommand(.maughamAddScreenplayPiece, window: window) { _ in
                    guard let store, store.manifest.type == .collection else { return }
                    Task {
                        let piece = try? await store.addLoosePiece(
                            title: "Untitled Screenplay", mode: .screenplay)
                        if let piece {
                            selectedSubject = .item(piece.id)
                            pendingPieceRenameId = piece.id
                        }
                    }
                }
                .onKeyWindowCommand(.maughamLinkProject, window: window) { _ in
                    guard let store, store.manifest.type == .collection else { return }
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Pick a Maugham project folder to link"
                    panel.begin { response in
                        guard response == .OK, let target = panel.url else { return }
                        Task {
                            let piece = try? await store.addProjectReference(targetURL: target)
                            if let piece { selectedSubject = .item(piece.id) }
                        }
                    }
                }
                .onKeyWindowCommand(.maughamPromotePiece, window: window) { note in
                    guard let store, store.manifest.type == .collection,
                          let info = note.userInfo,
                          let pieceId = info["piece_id"] as? String,
                          let piece = store.manifest.structure.first(where: { $0.id == pieceId }) else { return }
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = piece.title
                    panel.directoryURL = store.url.deletingLastPathComponent()
                    panel.message = "Promote \"\(piece.title)\" to a standalone Maugham project"
                    panel.prompt = "Promote"
                    panel.begin { response in
                        guard response == .OK, let destination = panel.url else { return }
                        Task {
                            do {
                                let newProjectURL = try await store.promotePieceToProject(
                                    pieceId: pieceId, destination: destination)
                                MaughamEvent.post(
                                    .maughamOpenProject, to: .allWindows,
                                    payload: ["url": newProjectURL])
                            } catch {
                                _projectWindowLog.error("Promote failed: \(error, privacy: .public)")
                            }
                        }
                    }
                }
        }
    }

    // MARK: - Helpers

    // `defaultSegment(for:)` lived here and was deleted 2026-08-02: zero
    // callers, and its body was a second spelling of
    // `BinderSegment.documentHome(for:)` — the rule `Persona.swift` warns
    // against re-deriving inline, because doing so shipped the 2026-07-02
    // screenplay navigate bug. A dead copy of a load-bearing rule is a copy
    // waiting to be called.

    private var currentSyntaxHelpMode: SyntaxHelpMode {
        guard let store else { return .prose }
        return store.manifest.type == .screenplay ? .screenplay : .prose
    }

    // MARK: - Column builders

    /// Which binder shell the left column mounts.
    ///
    /// **One rule, named, because it decides which surfaces a project type has
    /// at all.** It was an inline `type == .collection` here; the census that
    /// asks *"can the writer name the project in every project type?"*
    /// (`ProjectSubjectReachabilityTests`) has to reach the same surface
    /// production reaches, and a copy of the check in the test is a copy that can
    /// drift away from the thing it is meant to be auditing. A third shell is a
    /// third case, and the census's `switch` stops compiling until it is
    /// enumerated there too.
    ///
    /// The shell is only half the address: which pane *inside* it a writer lands
    /// on is `BinderSegment.documentHome(for:)`, and that is where a screenplay
    /// diverges — its manuscript home is the Scenes navigator, not `BinderView`.
    enum BinderShell {
        /// `BinderPaneToggle` — every non-collection type. Its manuscript
        /// segment is `BinderView`; a screenplay lands on `SceneNavigatorPane`
        /// instead.
        case standard
        /// `CollectionBinderPaneToggle` — pieces are flat and have their own
        /// pane, `CollectionPiecesPane`.
        case collection

        static func shell(for type: ProjectType) -> BinderShell {
            type == .collection ? .collection : .standard
        }
    }

    /// The left column, plus **the second producer of `lastParsedScript`**.
    ///
    /// `.maughamScriptDidUpdate` — the only other producer — comes from a mounted
    /// `EditorCoordinator`, and Plan mounts none: on Plan's Structure tab a
    /// screenplay's navigator was handed `nil` and told the writer their script
    /// had no scenes (slice 2 review, F1). `ScreenplayScriptSource` derives it
    /// from the op log instead, and its `needsDerivation` is what orders the two
    /// producers — see that type for why this is a producer rather than a second
    /// value (tripwire 6) and how it satisfies tripwires 4 and 20.
    ///
    /// **Keyed on the predicate, not on the segment.** The task re-runs when the
    /// answer changes, which is exactly "a surface that lists sluglines just
    /// appeared with nothing to list"; once a script exists the key is `false`
    /// and stays there. The `nil` re-check inside is not redundant with the key
    /// — the derive is a suspension point, and an editor that mounted and posted
    /// across it must not be overwritten by the older op-log parse.
    @ViewBuilder
    private func binderColumn(store: ProjectStore) -> some View {
        binderShell(store: store)
            .task(id: ScreenplayScriptSource.needsDerivation(
                binderSegment: binderSegment,
                projectType: store.manifest.type,
                existing: lastParsedScript)
            ) {
                guard ScreenplayScriptSource.needsDerivation(
                    binderSegment: binderSegment,
                    projectType: store.manifest.type,
                    existing: lastParsedScript) else { return }
                let derived = ScreenplayScriptSource.derive(store: store)
                if lastParsedScript == nil { lastParsedScript = derived }
            }
    }

    @ViewBuilder
    private func binderShell(store: ProjectStore) -> some View {
        switch BinderShell.shell(for: store.manifest.type) {
        case .collection:
            CollectionBinderPaneToggle(
                store: store,
                segment: $binderSegment,
                selectedSubject: $selectedSubject,
                selectedResearchId: $selectedResearchId,
                selectedPaletteCardId: $selectedPaletteCardId,
                findActive: $findActive,
                renamingItemId: $pendingPieceRenameId,
                activePiece: activePiece(in: store),
                onAddSharedNote: { Task { try? await addSharedNoteAction(store: store) } },
                onAddPieceNote: { Task { try? await addPieceNoteAction(store: store) } },
                persona: persona
            )
        case .standard:
            BinderPaneToggle(
                store: store,
                segment: $binderSegment,
                selectedSubject: $selectedSubject,
                selectedResearchId: $selectedResearchId,
                selectedPaletteCardId: $selectedPaletteCardId,
                projectType: store.manifest.type,
                lastParsedScript: lastParsedScript,
                findActive: $findActive,
                persona: persona)
        }
    }

    private func activePiece(in store: ProjectStore) -> StructureItem? {
        guard store.manifest.type == .collection,
              let id = activeItemID else { return nil }
        return store.manifest.structure.first(where: { $0.id == id })
    }

    @MainActor
    private func addSharedNoteAction(store: ProjectStore) async throws {
        let item = try await store.addResearchTextNote(parentId: nil)
        selectedResearchId = item.id
    }

    @MainActor
    private func addPieceNoteAction(store: ProjectStore) async throws {
        guard let pieceId = activeItemID else { return }
        let item = try await store.addPieceResearchNote(
            pieceId: pieceId, title: "Untitled Note")
        selectedResearchId = item.id
    }

    @ViewBuilder
    private func contentColumn(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        editorPane(store: store, documentStore: documentStore)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 6) {
                    if PublishStarter.isInitialized(in: store.url) {
                        PublishStatusPill(
                            projectID: ProjectIdentifier.id(for: store.url),
                            projectURL: store.url)
                    }
                    SharingStatusPill(
                        collaborator: collaborator, snapshot: shareSnapshot)
                }
                .padding(.top, 8)
                .padding(.trailing, 12)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if shouldShowStatusFooter {
                    EditorStatusFooter(
                        goalState: goalIndicatorState,
                        sessionWords: sessionWordsForFooter,
                        sessionStart: sessionStartForFooter,
                        paragraphId: paragraphIdForFooter,
                        elementLabel: elementLabelForFooter)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // **Applied FIRST of the three top insets, which is what puts it
                // nearest the prose.** `safeAreaInset` places each inset outside
                // the content it wraps, so the last one applied ends up furthest
                // from the editor: the read-only trap is the outermost line, the
                // review banner sits under it, and the strip is directly over
                // the writing. That is the order the surfaces want — the two
                // banners are notices about the WINDOW's posture and belong with
                // the chrome, and the strip is a running head belonging to the
                // page.
                if let line = intentStripLine {
                    IntentStrip(line: line)
                }
            }
            .safeAreaInset(edge: .top) {
                // Reflect the EFFECTIVE posture, not just the manual toggle: a
                // reviewer (or still-resolving unknown) always shows REVIEWING;
                // an author shows it only when they manually entered review.
                if effectivePosture.isReviewMode {
                    ReviewModeIndicator(
                        collaboratorName: userPreferences.collaboratorDisplayName)
                }
            }
            .safeAreaInset(edge: .top) {
                // Read-only trap: an iCloud reviewer on a VIEW-ONLY share cannot
                // append annotation ops at all. Surface that loudly rather than
                // letting a comment attempt fail silently.
                if isViewOnlyReviewer {
                    ViewOnlyShareNotice()
                }
            }
            // The studied reference, between the binder and the prose (M2 §6.2).
            // Applied OUTSIDE the three top insets on purpose: the strip and the
            // two banners belong to the page, and the column stands beside the
            // whole of it. One line, because this body has no expression budget
            // under the Release type-checker — delete it and every token in
            // `AssistantColumn.swift` is still present, every test still green,
            // and clicking a pin does nothing visible.
            .modifier(AssistantColumnModifier(
                store: store, projectURL: url, documentStore: documentStore,
                window: window, isNoChromeOn: isNoChromeOn, persona: persona,
                activeDocId: activeDocId, assistant: assistant))
            // Unchanged, and deliberately: the column SQUEEZES the centred
            // writing column while it exists (spec §6.2) rather than widening
            // the window's content column, which would push the binder shut
            // instead. The clamp on `assistant.width` is what keeps the prose a
            // column rather than a margin.
            .navigationSplitViewColumnWidth(
                min: ProjectWindow.centreColumnFloor, ideal: 720)
    }

    /// The intent strip's line, or nil for no strip (M2 §6.1).
    ///
    /// **`EditorStatusFooter`'s twin, and gated the same way**: Author only, and
    /// gone with the chrome under ⌘\. The decision itself is
    /// `IntentStrip.line(store:docId:persona:isNoChromeOn:)` rather than a
    /// condition written out here, so it can be asked over the product of its
    /// inputs by a test instead of only down the path this property takes.
    ///
    /// The freshness is SwiftUI's own observation **while the statement is open
    /// in a pane**: the resolver prefers the statement's live `Document` through
    /// `ProjectStore.statementText(of:)`, so a change made in the Intent pane
    /// invalidates this body with no event and no poll. A CLOSED statement's
    /// text comes from `derivedCache`, which is `@ObservationIgnored` — an
    /// append to one lands on the next body pass instead. See
    /// `IntentStrip.line(store:docId:persona:isNoChromeOn:)` for the boundary and
    /// the one visible case.
    ///
    /// **`activeDocId` carries the no-selection sentinel and that is correct
    /// here** — no manuscript document means no document-scope intent to find,
    /// so the resolution falls to the project's, which is the right answer for a
    /// window whose subject is the project.
    ///
    /// **One divergence is known and accepted rather than fixed.** Clicking the
    /// strip posts a bare `postDetailSegment(.intent)`, and the Intent pane
    /// resolves its own scope from the binder selection
    /// (`StatementPane.effectiveScope`), which never falls back — so a chapter
    /// with no intent of its own shows the *project's* line in the strip and
    /// opens the *chapter's* empty editor on click. Landing on the fallback
    /// scope instead would need Open-sets-scope machinery, which is the reverted
    /// three-round M1A work (`openPromotedArtifact`, `Maugham/Canvas/AREA.md`)
    /// and not a ride-along. The click is still the right one — the writer who
    /// pressed a project-scope line while a chapter is selected is one keystroke
    /// from writing that chapter's own intent, which is the thing they would
    /// want to do next. `IntentStripTests` pins the divergence so it is a
    /// recorded position rather than a surprise.
    private var intentStripLine: String? {
        guard let store else { return nil }
        return IntentStrip.line(
            store: store, docId: activeDocId,
            persona: persona, isNoChromeOn: isNoChromeOn)
    }

    private var shouldShowStatusFooter: Bool {
        guard userPreferences.goalIndicatorsVisible else { return false }
        // `BinderSegment.showsManuscriptStatusFooter`, not the two equalities
        // that used to be written out here. The canvas and Plan's tree are both
        // deliberately absent — the footer reports manuscript metrics, and
        // readiness stays silent about the canvas (umbrella §7, §9) — and the
        // predicate's own doc comment records why `.find` is absent too, which
        // is the case that stops this being "the centre column is a document".
        guard binderSegment.showsManuscriptStatusFooter else { return false }
        if isNoChromeOn { return false }
        return true
    }

    private var sessionWordsForFooter: Int {
        // Net words added in the currently-active session. `sessionLog` only
        // captures sessions that have ENDED (30-min idle timeout or app quit),
        // so during an active session it's stale; pull the live delta from
        // DocumentStore (which observes `lastKnownProjectWordCount` and so
        // ticks as the user types).
        documentStore?.liveSessionWordsNet ?? 0
    }

    private var sessionStartForFooter: Date? {
        documentStore?.currentSessionStart
    }

    private var paragraphIdForFooter: String? {
        guard let store, let documentStore else { return nil }
        return activeDocument(in: store, documentStore: documentStore)
            .flatMap { $0.paragraphId(at: $0.cursorLocation) }
    }

    private var elementLabelForFooter: String? {
        currentElement
    }

    /// Whether the selected item is a Collection reference piece.
    private func selectedPieceIsReference(in store: ProjectStore) -> Bool {
        guard let id = activeItemID,
              let piece = store.manifest.structure.first(where: { $0.id == id })
        else { return false }
        return piece.pieceKind == .reference
    }

    /// **The canvas is ONE branch here, above the segment switch, and that is
    /// what keeps it mounted across a `.canvas` ↔ `.tree` flip.**
    ///
    /// `CanvasView`'s camera, scrap layouts, thumbnail cache, in-progress scrap
    /// edit and accessibility elements are all `@State` on the view —
    /// `CanvasModel`'s own doc comment says so from the other side ("what
    /// deliberately does not live here: camera, layouts…"). Two `case` clauses in
    /// a ViewBuilder `switch` are two distinct `_ConditionalContent` branches, so
    /// a `case .tree:` arm of its own would give the canvas a second identity and
    /// SwiftUI would tear the first one down on every flip: camera back to origin
    /// at zoom 1, every layout re-measured, thumbnails emptied, `.onAppear`
    /// re-reading `canvas.md` and the sidecar.
    ///
    /// **Measured, not cited** (`CanvasTreeSegmentMountTests`, macOS 26.5): with
    /// two arms a camera at pan (−680, −420) / zoom 1.5 came back at pan `.zero`
    /// / zoom 1, the `CanvasEventNSView` was a different object and `load()` had
    /// run twice; routed through `editorRoute` the camera survives, the object
    /// is the same one, and `load()` has still run once.
    @ViewBuilder
    private func editorPane(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        let route = Self.editorRoute(
            binderSegment: binderSegment,
            projectType: store.manifest.type,
            selectedPieceIsReference: selectedPieceIsReference(in: store))
        if route == .canvas {
            canvasCentre(store: store, documentStore: documentStore)
        } else if route == .collectionReference,
                  let id = activeItemID,
                  let piece = store.manifest.structure.first(where: { $0.id == id }) {
            ReferencePlaceholderCard(piece: piece) {
                openReferenceInWindow(piece: piece, store: store)
            }
        } else {
            existingEditorSwitch(store: store, documentStore: documentStore)
        }
    }

    private func openReferenceInWindow(piece: StructureItem, store: ProjectStore) {
        let resolution = store.resolveReference(piece)
        let url: URL
        switch resolution {
        case .resolved(let u): url = u
        case .resolvedViaPathFallback(let u): url = u
        case .unresolved: return
        }
        MaughamEvent.post(.maughamOpenProject, to: .allWindows, payload: ["url": url])
    }

    @ViewBuilder
    private func existingEditorSwitch(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        switch binderSegment {
        case .manuscript, .scenes, .find:
            // Both .manuscript and .scenes show the editor — .scenes is just an
            // alternate sidebar navigator; the underlying screenplay file is the same.
            // .find also shows the active document, as search results update
            // selectedItemId when clicked.
            EditorHost(
                store: store,
                documentStore: documentStore,
                selectedItemId: activeItemID,
                onMetricsChanged: { metrics = $0 },
                onElementChanged: { currentElement = $0 },
                wikiLinkResolver: { title in
                    store.resolveDocumentId(forTitle: title) != nil
                },
                wikiLinkClickResolver: { title in
                    store.resolveDocumentId(forTitle: title)
                },
                // Role-driven posture flows entirely through the EditorControl
                // model (ADR 0017): an author's manual ⌘⌥⇧R drives the render; a
                // reviewer/unknown is FORCED into review render AND hard-locked
                // (lockEditing) via `effectivePosture` mirrored into the control.
                control: editorControl
            )
        case .canvas, .tree:
            // **Unreachable** — `editorRoute` takes the canvas above this switch
            // (see `editorPane`), in one branch that serves both segments. Kept
            // because the switch is exhaustive over `BinderSegment` and the
            // compiler requires an answer, and routed to the same helper so the
            // two cannot drift. `existingInspectorSwitch`'s `.canvas` arm is the
            // same shape, one column over.
            canvasCentre(store: store, documentStore: documentStore)
        case .research:
            if let id = selectedResearchId,
               let item = TreeWalk.find(
                    id: id, in: store.manifest.research) {
                if item.kind == .document,
                   item.path?.hasPrefix(ProjectStore.paletteFolderPath + "/") == true {
                    // A palette card selected in the research tree edits through the
                    // visual editor — never ResearchNoteEditor, whose stale open text
                    // would clobber the model on the next re-render (lost update).
                    PaletteCardEditor(store: store, cardId: item.id)
                } else if item.kind == .document, let path = item.path {
                    ResearchNoteEditor(
                        store: store,
                        documentStore: documentStore,
                        path: path,
                        itemId: item.id,
                        previewVisible: researchPreviewVisible)
                } else {
                    ResearchPreview(projectURL: store.url, item: item)
                }
            } else {
                ContentUnavailableView(
                    "Select an item to preview",
                    systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .palette:
            if let cardId = selectedPaletteCardId,
               store.paletteCardItems().contains(where: { $0.id == cardId }) {
                VStack(spacing: 0) {
                    HStack {
                        Button { selectedPaletteCardId = nil } label: {
                            Label("Wall", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    Divider()
                    PaletteCardEditor(store: store, cardId: cardId)
                }
            } else {
                PaletteWallView(store: store, selectedCardId: $selectedPaletteCardId)
            }
        case .trash:
            ContentUnavailableView(
                "Trash",
                systemImage: "trash")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// **The one place the canvas is mounted in production.**
    ///
    /// Named and extracted so that `.canvas` and `.tree` reach the SAME view
    /// identity through `editorRoute` (see `editorPane`) rather than an arm
    /// apiece. A second mount here would give the tree a canvas of its own, and
    /// the cost of that is the writer's camera, layouts and thumbnails on every
    /// flip with nothing red anywhere — so the mount count is censused in
    /// `RegionBindingTests`, beside the inspector arm's, and what it costs is
    /// measured in `CanvasTreeSegmentMountTests`. The token that census counts
    /// is deliberately not spelled in this comment.
    private func canvasCentre(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        CanvasView(model: canvasModel, projectRoot: store.url,
                   paletteSwatchHexes: { store.paletteSwatchHexes() },
                   // Spec §4: selecting in the tree changes what the canvas
                   // shows. Resolved HERE because telling a chapter from a
                   // group needs `manifest.structure`, which the canvas does
                   // not hold and should not start holding — the same reason
                   // `itemIndex` below is built on this body path rather than
                   // on the canvas's, which re-evaluates per drag frame.
                   subject: CanvasSubject.resolve(selectedSubject,
                                                  in: store.manifest.structure),
                   // Spec §4.1: Escape is the keyboard spelling of the project
                   // row, so it writes the value that row's own `.tag` carries
                   // (`BinderView.projectRow`) into the same `@State` on the
                   // same synchronous path. Not a state that resembles the
                   // row's — the same one, which is what makes the persisted UI
                   // state, the tree's highlight and the canvas's subject agree
                   // by construction. The canvas is handed this ask rather than
                   // a binding: it gets the ANSWER (`CanvasSubject`) and never
                   // the question.
                   selectTheProjectRow: { selectedSubject = .project },
                   itemIndex: Self.canvasItemIndex(in: store),
                   // Spec §4.2: on a dimmed board a region bound to another
                   // document draws that document's name, so the writer can tell
                   // the rectangle a sweep will bind from the one where it will
                   // silently do nothing. Resolved HERE for `itemIndex`'s reason
                   // — the walk belongs on this body, which re-evaluates per
                   // manifest change, not on the canvas's, which re-evaluates per
                   // drag frame — and the canvas gets the ANSWER, never the
                   // manifest.
                   pieceTitles: Self.canvasPieceTitles(in: store),
                   // The canvas's asset well (1C-d Task 11): a photograph
                   // dropped from the Finder or a browser is ingested into
                   // `canvas_assets/` here and nowhere else, so every route
                   // is a caller of the one pair rather than a storage
                   // decision of its own.
                   assetIngest: CanvasAssetIngest(
                    file: { try await store.ingestCanvasAsset(fileURL: $0) },
                    image: { try await store.ingestCanvasAsset(image: $0) }),
                   // An inbox row dragged onto the canvas (1C-d Task 12, spec
                   // §8A.4). The whole act is the store's third promote
                   // sibling; this is the only production site that hands the
                   // canvas a way to reach it, so its absence would be a drag
                   // that springs back with nothing said.
                   captureDrop: CanvasCaptureDrop(send: { entryID, point in
                       try await documentStore.inboxStore.sendToCanvas(
                           entryID: entryID, projectStore: store,
                           placement: .dropped(at: point))
                   }))
    }

    /// Helper: the currently-selected manuscript Document, if one is open
    /// in the editor registry.
    private func activeDocument(in store: ProjectStore, documentStore: DocumentStore) -> Document? {
        guard let id = activeItemID,
              let item = TreeWalk.find(id: id, in: store.manifest.structure),
              let path = item.path else { return nil }
        return documentStore.document(for: path)
    }

    // MARK: - The three columns' arithmetic

    /// The binder column's declared floor — **the one source**, read by its own
    /// `navigationSplitViewColumnWidth` and by the right column's affordability
    /// sum below. Two spellings of one number is how the sum comes to disagree
    /// with the layout it is reasoning about.
    static let binderColumnFloor: CGFloat = 200

    /// What macOS 26 draws AROUND the sidebar: a 200pt sidebar occupies 208 in
    /// the split view (measured — see `DetailColumnWidthTests`). Eight points is
    /// the whole of the difference between "the window holds" and "the window
    /// silently grows by 8", so it is part of the sum rather than a rounding
    /// error somebody later trims.
    static let sidebarInset: CGFloat = 8

    /// The writing column's declared floor, same rule as the binder's.
    static let centreColumnFloor: CGFloat = 480

    /// The window's own declared minimum (`body`'s `.frame(minWidth:)`), and the
    /// container width assumed before anything has been measured.
    static let windowFloor: CGFloat = 980

    /// Records the measured container width, but **only when it changes the
    /// answer**. A window drag-resize is 60 frames a second and this view's
    /// `body` is not something to re-evaluate at that rate; the effective width
    /// is unchanged across almost all of that range, so almost all of those
    /// frames write nothing.
    ///
    /// Not storing a width that leaves the answer alone is safe rather than
    /// merely cheap: the sum is monotonic in the container, so the value kept
    /// here always yields the effective width currently on screen, which is
    /// exactly what the next comparison needs.
    static func recordsContainerWidth(_ width: Double,
                                      over current: Double?,
                                      persisted: Double) -> Bool {
        effectiveDetailColumnWidth(persisted: persisted, containerWidth: width)
            != effectiveDetailColumnWidth(persisted: persisted, containerWidth: current)
    }

    private func noteContainerWidth(_ width: Double) {
        guard Self.recordsContainerWidth(width, over: containerWidth,
                                         persisted: detailColumnWidth) else { return }
        containerWidth = width
    }

    /// **The width actually handed to the split view: the writer's wish, reduced
    /// only as far as this window can afford it.**
    ///
    /// The three columns' floors out-arithmetic the window's own: at 980 the
    /// binder wants 208 and the prose wants 480, which leaves **300** — less
    /// than the 480 a writer is allowed to wish for. AppKit does not resolve
    /// that by squeezing anything; it silently GROWS the window past its
    /// declared minimum, which is the same "the app moved something under me"
    /// complaint this task exists to kill, relocated from the divider to the
    /// window edge. Found by review, 2026-08-08; the shipped test had asserted a
    /// 980pt window while measuring a 1169pt one.
    ///
    /// **The asymmetry is deliberate and is the point.** This reduces what is
    /// DISPLAYED; it never touches what is STORED. A writer who dragged to 480
    /// on a large display and then opens the project on a laptop gets 300 there
    /// and their 480 back the moment the window can afford it — their wish is
    /// not edited by the furniture it happened to be opened in front of.
    ///
    /// `containerWidth` is nil until the window has been measured, and the
    /// answer for nil is deliberately the CONSERVATIVE one (the window's own
    /// floor): a first pass that guessed generously would grow the window
    /// before the measurement could arrive, and a grown window does not shrink
    /// back on its own.
    static func effectiveDetailColumnWidth(persisted: Double,
                                           containerWidth: Double?) -> Double {
        let container = containerWidth ?? Double(windowFloor)
        let affordable = container
            - Double(binderColumnFloor + sidebarInset)
            - Double(centreColumnFloor)
        return UIState.clampedDetailColumnWidth(min(persisted, affordable))
    }

    /// The same sum, as the ceiling a drag may reach: the writer can only wish
    /// for a width they can be shown. A wish wider than this survives only by
    /// having been made in a window that could afford it.
    static func draggableDetailCeiling(containerWidth: Double?) -> Double {
        effectiveDetailColumnWidth(
            persisted: UIState.detailColumnWidthRange.upperBound,
            containerWidth: containerWidth)
    }

    /// **One width, held.** The right column is pinned to the writer's own
    /// `detailColumnWidth` and resized by the handle below — it does NOT declare
    /// a range, and the difference is the whole of Task 1.
    ///
    /// `navigationSplitViewColumnWidth(min:ideal:max:)` does not hold a width;
    /// it declares a range, and AppKit re-resolves a position inside that range
    /// whenever something re-proposes. Two things do, both measured in
    /// `DetailColumnWidthTests` against a real mounted `NavigationSplitView`:
    ///
    /// - **a pane whose content wants to be wider** pushes the column out to the
    ///   range's `max` — so every ⌘⌥-letter switch between panes of different
    ///   intrinsic width moved the divider under the writer;
    /// - **a `columnVisibility` transition** (`⌘\` on the canvas sets
    ///   `.doubleColumn`, `PersonaModifier` hands back `.all`) drops the column
    ///   on the range's `min` — 240 out of a dragged 329, measured.
    ///
    /// The single-argument spelling holds through both — **measured, and worth
    /// stating no more strongly than that.** It is tempting to say a range with
    /// one value in it has nothing left to re-resolve; that overclaims. A pane
    /// whose content is genuinely unbreakable still raises a real Auto Layout
    /// conflict against the fixed column, which AppKit resolves by breaking its
    /// `NSSplitViewItem.MaxSize` constraint rather than the content's
    /// intrinsic-width demand — undocumented tie-breaking we do not control, and
    /// the reason the width comes out right today. It logs a
    /// `Conflicting constraints detected` line when it happens.
    /// `test_theFixedColumnWinsAgainstAnUnbreakablePane` is the canary on that
    /// tie-break, not a proof of it. Real Inspector and Outline content wraps or
    /// scrolls, so the conflict wants a `.fixedSize()` to provoke it.
    ///
    /// The cost of the fixed column is that the split view's own divider goes
    /// inert — a fixed column is not draggable — so the column brings its own
    /// handle, exactly as the assistant column does one directory over
    /// (`AssistantColumnModifier.resizeHandle`).
    ///
    /// What is applied is the **effective** width, not the stored one; see
    /// `effectiveDetailColumnWidth` for the window-affordability sum and why the
    /// reduction never reaches the stored value.
    @ViewBuilder
    private func detailColumn(store: ProjectStore, documentStore: DocumentStore) -> some View {
        if showInspector {
            HStack(spacing: 0) {
                detailResizeHandle(documentStore: documentStore)
                inspectorPane(store: store, documentStore: documentStore)
            }
            .navigationSplitViewColumnWidth(
                Self.effectiveDetailColumnWidth(persisted: detailColumnWidth,
                                                containerWidth: containerWidth))
        }
    }

    /// The right column's own resize affordance, on its leading edge.
    ///
    /// **A gutter in the layout rather than an overlay over the pane**, which is
    /// the same shape `AssistantColumnModifier.resizeHandle` ships and the same
    /// reason: a `contentShape`d strip laid *over* the pane swallows every click
    /// in the leftmost 8pt of every row, list and control in the column, for the
    /// whole height of the window, and it does it silently. Eight points of
    /// layout is the cheaper mistake. It is deliberately not drawn — the split
    /// view's own divider is still there and is still the seam a writer aims at;
    /// this sits just inside it, and the resize cursor on hover is what says so.
    ///
    /// Live during the gesture and persisted only at its end — a `UIState` write
    /// per drag frame is 60 a second through the manuscript's own debounce, and
    /// the assistant column already settled that question.
    ///
    /// **Nothing else writes this width.** There is no geometry observation
    /// feeding the COLUMN's width back, because a fixed column has no geometry
    /// of its own to report — it is exactly as wide as it was asked to be. (The
    /// window's width is measured, but that is the container's geometry and it
    /// is never persisted.) That is what makes
    /// `test_aPersonaSwitchDoesNotWriteTheWidth` structurally true rather than a
    /// debounce racing a persona change.
    private func detailResizeHandle(documentStore: DocumentStore) -> some View {
        Color.clear
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = detailDragStartWidth ?? detailColumnWidth
                        detailDragStartWidth = start
                        // Leading edge: dragging LEFT widens the column. The
                        // ceiling is what THIS window can afford rather than the
                        // stored range's 480 — a writer may only wish for a
                        // width they can be shown, so the gesture stops where
                        // the column stops moving instead of silently banking a
                        // wider number.
                        detailColumnWidth = min(
                            UIState.clampedDetailColumnWidth(
                                start - value.translation.width),
                            Self.draggableDetailCeiling(containerWidth: containerWidth))
                    }
                    .onEnded { _ in
                        detailDragStartWidth = nil
                        let width = detailColumnWidth
                        documentStore.updateUIState { $0.detailColumnWidth = width }
                    })
    }

    // MARK: - Which column shows what

    /// **The canvas check sits ABOVE the project-type split, in both columns.**
    ///
    /// That is the more correct shape rather than merely the shorter one: there
    /// is ONE canvas per project regardless of type (spec §2), and which view the
    /// canvas segment wants has nothing to do with whether the project is a
    /// collection or which piece happened to be selected in some other segment.
    /// Leaving the decision *below* the split is what let the two paths disagree
    /// — the region inspector shipped built, reviewed and reachable on only one
    /// of them, and a Collection writer selecting a region got the piece
    /// inspector for whatever manuscript item was last selected. Found by smoke,
    /// 2026-07-28; the editor column had the same defect and it was found by
    /// asking the same question of every sibling split.
    ///
    /// Pure and named rather than nested `if`s inside a `@ViewBuilder`, so a test
    /// can be exhaustive over (segment × type) instead of over the one path a
    /// plan happened to name. `CanvasPersonaTests` is that test.
    enum InspectorRoute: Equatable {
        case canvas
        /// A Collection's per-piece inspector, which never consults the segment.
        case collectionPiece
        /// `existingInspectorSwitch`, which dispatches on the segment.
        case segment
    }

    static func inspectorRoute(binderSegment: BinderSegment,
                               projectType: ProjectType) -> InspectorRoute {
        // `centresTheCanvas`, not `== .canvas`: since slice 2 the canvas is the
        // centre column under `.tree` as well, and this equality spelled in three
        // places with no compiler help is what the predicate replaces. Miss it
        // here and the region inspector is unreachable from Plan's tree — the
        // exact defect the doc comment above records.
        if binderSegment.centresTheCanvas { return .canvas }
        return projectType == .collection ? .collectionPiece : .segment
    }

    /// The palette wall's own inspector rule, as a fold rather than a closure
    /// body — behaviour unchanged, extracted so a test can drive it.
    ///
    /// **Extracted because it shares an update pass with the canvas collapse.**
    /// `PaletteSegmentModifier` and `CanvasCollapseModifier` both watch
    /// `binderSegment`, and Plan's binder offers Palette and Canvas side by side
    /// (`Persona.plan.binderSegments`), so a **one-click** palette → canvas move
    /// in focus mode runs both of these in the same pass in an order SwiftUI
    /// picks. Neither may depend on being first, and the only way to know that
    /// is to run the pair both ways round — which needs both halves callable.
    static func applyPaletteSegmentChange(from old: BinderSegment,
                                          to new: BinderSegment,
                                          showInspector: inout Bool,
                                          stash: inout Bool?,
                                          selectedPaletteCardId: inout String?) {
        if new == .palette && old != .palette {
            stash = showInspector
            showInspector = false
        } else if old == .palette && new != .palette {
            // A `nil` stash is a real state and means "someone else has already
            // taken this memory over" — see `canvasCollapse`'s takeover. It has
            // always been written as a conditional restore; that is now
            // load-bearing rather than merely defensive.
            if let prior = stash { showInspector = prior }
            stash = nil
            selectedPaletteCardId = nil
        }
    }

    // MARK: - ⌘\ collapses to the canvas (spec §8A.3)

    /// What `⌘\` must do to the two side columns, as a value.
    ///
    /// **`.doubleColumn`, and the case that looks right is the one that breaks
    /// it.** The canvas is the CONTENT (middle) column — `CanvasView` is inside
    /// `contentColumn` — so `.detailOnly`, which reads as "everything else
    /// away", hides the canvas itself: a focus key that blanks the thing it is
    /// focusing. `.doubleColumn` hides the SIDEBAR and keeps content + detail,
    /// and `detailColumn` already renders nothing when `showInspector` is false,
    /// so the pair is what leaves the canvas the whole window. The visibility
    /// travels in the payload rather than being implied by the case name
    /// precisely so a test has to name the enum case it expects — "not `.all`"
    /// is satisfied by the trap.
    ///
    /// **`.unchanged` is a real answer, and the one the control rests on.** `⌘\`
    /// in the editor must move no column at all, so the off-canvas arm writes
    /// nothing whatever — not even `.all` over a sidebar the writer dragged shut
    /// by hand.
    enum CanvasCollapse: Equatable {
        /// Give the canvas the window, remembering the inspector's visibility so
        /// leaving can put it back exactly.
        case collapse(columnVisibility: NavigationSplitViewVisibility,
                      showInspector: Bool,
                      stash: Bool,
                      /// True when the memory being stashed is the PALETTE's,
                      /// taken over rather than left for its exit arm to
                      /// restore. See the takeover note on `canvasCollapse`.
                      takesOverPaletteStash: Bool)
        /// Hand the columns back, restoring the remembered inspector.
        case release(columnVisibility: NavigationSplitViewVisibility,
                     showInspector: Bool)
        /// Touch nothing.
        case unchanged
    }

    /// Pure and named, so the decision can be asked over the whole product of
    /// its inputs rather than the one path a plan happened to name — the shape
    /// that found both of this window's routing bugs (see `inspectorRoute`).
    ///
    /// **`route` rather than a second "is the canvas showing" test.** The canvas
    /// check already lives above the project-type split, in one place, and
    /// spelling it again here is how two paths came to disagree once already.
    ///
    /// The stash is both the memory and the "am I already collapsed" flag: an
    /// already-collapsed canvas answers `.unchanged`, or a second apply in the
    /// same pass would stash the `false` the first one wrote and leave the
    /// inspector hidden for good.
    ///
    /// **`paletteStash`, and why a collapse TAKES IT OVER.** Plan's binder
    /// offers Palette and Canvas side by side, so palette → canvas in focus mode
    /// is **one click** and needs no persona switch — and it runs
    /// `PaletteSegmentModifier`'s exit arm and `CanvasCollapseModifier`'s
    /// collapse **in the same update pass**, in whichever order SwiftUI picks.
    /// Left alone the two orders disagree, which is tripwire 2 whichever one
    /// happens to win today:
    ///
    /// - palette first — it restores the pre-palette visibility and clears its
    ///   stash, then the collapse remembers that value. Right.
    /// - collapse first — it would remember the palette's *forced* `false`, and
    ///   the exit arm would then reopen the inspector against the collapse,
    ///   leaving the writer a collapsed canvas with the pane still in it and a
    ///   memory that closes the pane for good on the way out.
    ///
    /// So the collapse takes the palette's memory when one is live —
    /// `paletteStash ?? showInspector` — and says so, which makes the exit arm's
    /// conditional restore a no-op. **Both orders now end in the same state**,
    /// so nothing here depends on which runs first.
    static func canvasCollapse(route: InspectorRoute,
                               isNoChromeOn: Bool,
                               showInspector: Bool,
                               stash: Bool?,
                               paletteStash: Bool?) -> CanvasCollapse {
        let wantsTheWholeWindow = route == .canvas && isNoChromeOn
        switch (wantsTheWholeWindow, stash) {
        case (true, .none):
            return .collapse(columnVisibility: .doubleColumn,
                             showInspector: false,
                             stash: paletteStash ?? showInspector,
                             takesOverPaletteStash: paletteStash != nil)
        case (false, .some(let prior)):
            return .release(columnVisibility: .all, showInspector: prior)
        default:
            return .unchanged
        }
    }

    /// Folding the decision into the window's state.
    ///
    /// Static and `inout` rather than inline in the modifier so the sequence
    /// test — collapse, persona switch, come back, which is three SwiftUI passes
    /// — drives the SAME fold the window does. A test that mirrored the fold
    /// would have gone green over the palette bug this whole shape exists to
    /// avoid.
    static func applyCanvasCollapse(_ decision: CanvasCollapse,
                                    columnVisibility: inout NavigationSplitViewVisibility,
                                    showInspector: inout Bool,
                                    stash: inout Bool?,
                                    paletteStash: inout Bool?) {
        switch decision {
        case .collapse(let visibility, let inspector, let stashed, let takesOver):
            stash = stashed
            if takesOver { paletteStash = nil }
            showInspector = inspector
            columnVisibility = visibility
        case .release(let visibility, let inspector):
            stash = nil
            showInspector = inspector
            columnVisibility = visibility
        case .unchanged:
            break
        }
    }

    enum EditorRoute: Equatable {
        /// `canvasCentre` — the planning canvas, mounted ONCE and above the
        /// segment switch, so `.canvas` and `.tree` share one view identity.
        ///
        /// **It became a case of its own in slice 2.** It used to answer
        /// `.segment` and let `existingEditorSwitch`'s `case .canvas:` arm do the
        /// mounting, which was correct while exactly one segment centred the
        /// canvas. With two, an arm apiece is two `_ConditionalContent` branches
        /// and the canvas is rebuilt from scratch on every flip — see
        /// `editorPane` for what that costs and what was measured.
        case canvas
        /// A Collection's placeholder for a linked-project reference piece.
        case collectionReference
        /// `existingEditorSwitch`.
        case segment
    }

    static func editorRoute(binderSegment: BinderSegment,
                            projectType: ProjectType,
                            selectedPieceIsReference: Bool) -> EditorRoute {
        // The canvas draws whatever else is selected. A reference piece chosen in
        // the Pieces segment stays selected across a persona switch — nothing
        // clears `selectedItemId` but a delete — so without this the centre
        // column shows the placeholder and the canvas never appears at all.
        if binderSegment.centresTheCanvas { return .canvas }
        return projectType == .collection && selectedPieceIsReference
            ? .collectionReference : .segment
    }

    @ViewBuilder
    private func inspectorPane(store: ProjectStore, documentStore: DocumentStore) -> some View {
        DetailPaneToggle(
            store: store,
            segment: $detailSegment,
            outlineLayout: $outlineLayout,
            selectedSubject: $selectedSubject,
            activeManuscriptItemId: activeItemID,
            persona: persona,
            hideOutline: store.manifest.type == .collection,
            projectURL: store.url,
            activeDocId: activeDocId,
            allDocIds: Self.documentIds(in: store.manifest.structure),
            device: _checkpointDeviceId,
            session: _checkpointSessionId,
            docPaths: Self.documentPaths(in: store.manifest.structure),
            documentStore: documentStore,
            editorControl: editorControl,
            compilerOrchestrator: compiler,
            diagnosticsStore: compiler.diagnostics,
            bibleStore: bible,
            declaredWorldStore: declaredWorld,
            compilerModel: compilerModel,
            onCompilerModelChange: { newValue in
                compilerModel = newValue
                compiler.updateModel(newValue.claudeModel)
                documentStore.updateUIState { $0.compilerModel = newValue }
            },
            assistant: assistant
        ) {
            switch Self.inspectorRoute(binderSegment: binderSegment,
                                       projectType: store.manifest.type) {
            case .canvas:
                canvasInspector(store: store)
            case .collectionPiece:
                collectionInspector(store: store)
            case .segment:
                existingInspectorSwitch(store: store)
            }
        }
        // Entering translation review surfaces the Translation segment so the
        // source text + translator queries are one glance away. Exiting leaves
        // the segment in place (it shows a "not in review" empty state) rather
        // than yanking the pane out from under the writer.
        .onChange(of: editorControl.translationLanguage) { _, lang in
            if lang != nil { detailSegment = .translation }
        }
    }

    /// Pre-order ids of every `.document` node in the structure tree.
    /// Single source of truth shared by ProjectWindow, CheckpointModifier, and
    /// RewindModifier (each had its own copy before the TreeWalk migration).
    static func documentIds(in items: [StructureItem]) -> [String] {
        TreeWalk.collect(in: items, where: { $0.type == .document }).map(\.id)
    }

    /// `[documentId: path]` over every path-bearing `.document` node.
    static func documentPaths(in items: [StructureItem]) -> [String: String] {
        var result: [String: String] = [:]
        for item in TreeWalk.collect(in: items, where: { $0.type == .document }) {
            if let path = item.path { result[item.id] = path }
        }
        return result
    }

    @ViewBuilder
    private func collectionInspector(store: ProjectStore) -> some View {
        if let id = activeItemID,
           let piece = store.manifest.structure.first(where: { $0.id == id }) {
            switch piece.pieceKind {
            case .reference:
                ReferencePieceInspector(store: store, pieceId: id)
            case .loose, .none:
                if let path = piece.path, path.hasSuffix(".fountain") {
                    PieceInspector(store: store, pieceId: id, kind: .screenplay)
                } else {
                    PieceInspector(store: store, pieceId: id, kind: .prose)
                }
            }
        } else {
            ContentUnavailableView("Select a piece", systemImage: "doc.text")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func existingInspectorSwitch(store: ProjectStore) -> some View {
        switch binderSegment {
        case .manuscript, .scenes, .find:
            InspectorView(
                store: store,
                selectedItemId: activeItemID,
                metrics: metrics,
                onOpenProjectSettings: { activeSheet = .projectSettings }
            )
        case .canvas, .tree:
            // Unreachable — `inspectorRoute` takes the canvas above the
            // project-type split, so this arm never runs. Kept because the switch
            // is exhaustive over `BinderSegment` and the compiler requires it;
            // it routes to the same place so the two cannot drift.
            canvasInspector(store: store)
        case .research:
            if let id = selectedResearchId,
               let item = TreeWalk.find(
                    id: id, in: store.manifest.research) {
                InspectorResearchPanel(store: store, item: item)
            } else {
                ContentUnavailableView(
                    "Select an item",
                    systemImage: "info.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .palette:
            ContentUnavailableView("Palette", systemImage: "paintpalette")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .trash:
            ContentUnavailableView(
                "No selection",
                systemImage: "trash")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The canvas's inspector arm — the selected region, or an empty state.
    ///
    /// **One expression, and it reads NOTHING off `canvasModel`.** Both halves
    /// matter. `ProjectWindow.body` has a zero expression budget (the Release
    /// type-check ceiling), so the arm above is a call and not a body. And
    /// `CanvasModel` is `@Observable` with the whole scene in one stored
    /// property, which every drag frame and every coast frame writes — so
    /// resolving `selectedRegion` *here* would register this window's body as a
    /// dependency of the drag loop and re-evaluate all of it at 60–120 Hz.
    /// `RegionInspectorPane` does the resolving, one leaf down.
    private func canvasInspector(store: ProjectStore) -> some View {
        RegionInspectorPane(
            model: canvasModel,
            pieces: Self.pieceChoices(in: store),
            // Deferred — walked only when a promoted card is selected.
            artifactTitle: { Self.artifactTitle($0, in: store) },
            // Only asked when an association names a piece `pieceChoices` does
            // not hold. **The whole structure, not the routable subset** — this is
            // what tells an association whose piece is GONE from one whose piece
            // is in the writer's binder and simply keeps no research of its own,
            // which the inspectors called "Missing piece · ref-1" while the
            // refusal named it.
            //
            // **It reads the canvas's own table since §4.2, and that is the
            // point.** This was a `TreeWalk.collect` of its own; the canvas now
            // needs the same lookup to draw a dimmed region's borrowed name, and
            // two walks of one tree are two answers to "does this piece still
            // exist" with nothing keeping them together. `ScrapInspector
            // .unoffered` is a function of exactly this lookup, so sharing the
            // table is sharing the resolution — which is the only half worth
            // sharing: `PieceAssociation.label` is a Form row's voice and says
            // things about promotion ROUTING that are true in the pane and
            // false-by-irrelevance on a chrome bar (see `CanvasPieceTitles`).
            //
            // Still deferred, and it costs what it always cost: `TreeWalk.collect`
            // walks the whole structure whether it filters to one id or to all of
            // them, so this is the same walk with a dictionary built on the end of
            // it, asked only on the miss. What changed is that there is one
            // SPELLING of "which pieces exist and what are they called" rather
            // than two.
            pieceTitle: { Self.canvasPieceTitles(in: store).title(of: $0) },
            onOpenResearchItem: openPromotedArtifact,
            // A region's member list names item nodes too — a Claude region holds
            // the page its scraps were read off — so the pane resolves a title
            // through the same index the canvas draws from (1C-d).
            itemIndex: Self.canvasItemIndex(in: store))
    }

    /// The pieces both canvas pickers offer — the region's and, since 1C-c2a, the
    /// card's. Ids, so an association survives a rename (tripwire 22's rule
    /// applied to a reference).
    ///
    /// **Only the pieces a promotion can be ROUTED to.**
    /// `ProjectStore.researchScopeTargets()` exists for precisely this — its own
    /// doc comment says it "drives the promote-target picker" — and this walked
    /// every `.document` instead, including the Collection reference pieces
    /// `researchRouting` throws on. So a writer could choose a piece that made
    /// the promotion fail, on a surface whose whole promise is predictability
    /// (spec §6.2).
    ///
    /// **Eager, and read on the body path — and that is the cheaper of the two
    /// mistakes available here.** A deferred closure is this file's rule for
    /// anything that walks the manifest (`artifactTitle` is one), but the pieces
    /// are consumed by a `Picker` inside `RegionInspector.body` — a body that
    /// reads `model.scene` and so re-evaluates on every drag and coast frame.
    /// Deferring would move an O(documents²) routing walk from "once per window
    /// body pass" onto the drag loop, which is tripwire 30's own shape. Kept here
    /// it costs one walk per manifest change, which is what it cost before.
    static func pieceChoices(in store: ProjectStore) -> [RegionInspector.PieceChoice] {
        store.researchScopeTargets()
            .map { RegionInspector.PieceChoice(id: $0.id, title: $0.title) }
    }

    /// What every item node on the canvas resolves its title, kind glyph and
    /// thumbnail path through (1C-d, spec §8A.1).
    ///
    /// **Built HERE, beside `pieceChoices`, and on exactly its terms.** This body
    /// reads `store.manifest`, so it re-evaluates when the manifest changes and
    /// not otherwise; it does **not** read `canvasModel.scene`, so it is not on
    /// the canvas's drag loop. Building it inside `CanvasView` instead would put
    /// one walk of the whole research tree on a body that re-evaluates every drag,
    /// coast and straighten frame — tripwire 4's per-row manifest walk arriving on
    /// the frame path, which is what made a binder click O(N²) in 3d.
    ///
    /// The second index over one manifest, the first being `ArtifactIndex`; the
    /// two are not one because they answer different questions, and
    /// `CanvasItemIndex`'s own doc comment carries why.
    static func canvasItemIndex(in store: ProjectStore) -> CanvasItemIndex {
        CanvasItemIndex.over(research: store.manifest.research)
    }

    /// What a dimmed region on the canvas says it already belongs to (§4.2), and
    /// what the region inspector resolves an unofferable binding through.
    ///
    /// **Built HERE, beside `pieceChoices` and `canvasItemIndex`, on exactly
    /// their terms** — this body reads `store.manifest` and so re-evaluates when
    /// the manifest changes, and it does not read `canvasModel.scene`, so it is
    /// not on the canvas's drag loop. Building it inside `CanvasView` would put a
    /// walk of the whole structure on a body that re-evaluates every drag, coast
    /// and straighten frame (tripwire 4).
    ///
    /// The third index over one manifest, and the first over `structure` rather
    /// than `research`; `CanvasPieceTitles` carries why it is the whole tree and
    /// not `pieceChoices`' routable subset.
    static func canvasPieceTitles(in store: ProjectStore) -> CanvasPieceTitles {
        CanvasPieceTitles.over(structure: store.manifest.structure)
    }

    /// Navigate to a research item in the right pane: switch to Research and
    /// select it, which the existing click-to-edit flow opens.
    ///
    /// Reached from a promoted card's **Open** button (1C-c2), through
    /// `openPromotedArtifact`. The craft-intent inspector affordance was the
    /// other caller until M1A Task 8 replaced it with a pane switch.
    private func openResearchItem(_ itemId: String) {
        binderSegment = .research
        selectedResearchId = itemId
    }

    /// **Open** on a promoted card, region or picture — which since M1A can name
    /// an artifact that is not in `research/` at all.
    ///
    /// A card promoted to craft intent carries a `Statement` id, and sending that
    /// to `openResearchItem` selects a research id no research tree holds: the
    /// pane says "Select an item" and the writer's intent is nowhere. So a
    /// statement routes to the Intent pane instead.
    ///
    /// **What it does not do is choose the pane's SCOPE.** `StatementPane`
    /// resolves that from the window's subject and has no say in it, so a
    /// document-scoped intent opened from here may land on a different scope's.
    /// Driving the subject from Open would move the writer's open document as a
    /// side effect of pressing a button about an artifact — which is the whole
    /// of what is left to decide, and slice 4's to decide.
    ///
    /// **A request the pane honours was built for that gap and reverted**
    /// (M1A Task 7, fix rounds 1–3, 2026-08-01). Three rounds each closed their
    /// finding and each opened a new one in a cell the last had right, because
    /// the pane's scope switch, the request and `prefersProjectScope` interacted
    /// and no test drove a press through the binding and back through this
    /// view's state.
    ///
    /// **Two of those three parts no longer exist.** Slice 1 gave the tree a
    /// project row, and the pane's `[<chapter> | Project]` switch and its
    /// `prefersProjectScope` state went with it (task 7) — the switch was only
    /// ever a workaround for the tree being unable to say "the project". And the
    /// missing test now exists: `StatementPaneSelectionDeliveryTests` drives a
    /// real selection through `BinderView`'s `List(selection:)`, the shared
    /// binding, this view's boundary conversion and `DetailPaneToggle`, and
    /// reads the resolved scope off the words in the mounted editor. It was
    /// written deliberately against the SELECTION rather than the switch, so it
    /// survived the deletion and is the fixture the next attempt starts from.
    ///
    /// So what remains here is not the three-way interaction — it is one design
    /// question: **may pressing Open move the window's subject?** See the task-7
    /// report for what the three rounds established.
    private func openPromotedArtifact(_ itemId: String) {
        guard let store else { return }
        if let pane = Self.statementPane(forMark: itemId, in: store) {
            detailSegment = pane
            return
        }
        openResearchItem(itemId)
    }

    /// The right-pane segment **Open** goes to for a mark, or nil for one that
    /// means the Research pane.
    ///
    /// Pure and static so the routing is asked over the whole product of its
    /// inputs rather than through a window's state, and a `switch` over the kind
    /// rather than a test for `.intent`: a fall-through is how a selected page
    /// card came to be told to select something (`RegionInspectorPane`), and here
    /// it would send the writer to a Research pane that shows them nothing. Only
    /// `.intent` is reachable today — it is the one kind a promotion produces.
    static func statementPane(forMark itemId: String,
                              in store: ProjectStore) -> DetailSegment? {
        guard let statement = store.manifest.statements.first(where: { $0.id == itemId })
        else { return nil }
        switch statement.kind {
        case .intent: return .intent
        case .visualLanguage: return .visualLanguage
        // A kind a newer build wrote, retained and ignored everywhere else
        // (`Statement.Kind`). There is no pane for it here either.
        case .unknown: return nil
        }
    }

    /// The name a mark shows — a research item's title, or, since M1A, an intent
    /// statement's composed name.
    ///
    /// **One rule, two readers.** The promotion sheet reads `ArtifactIndex`,
    /// built once when it opens; this is the inspector's deferred lookup, which
    /// exists so that selecting an unpromoted card walks nothing. They must
    /// answer identically for a statement or one card says two different things
    /// about what it became, so the composing is `ArtifactIndex.statementTitle`'s
    /// in both — pinned by `PromotionStatementMarkTests`.
    static func artifactTitle(_ itemID: String, in store: ProjectStore) -> String? {
        if let item = TreeWalk.find(id: itemID, in: store.manifest.research) {
            return item.title
        }
        guard let statement = store.manifest.statements.first(where: { $0.id == itemID }),
              case .intent = statement.kind else { return nil }
        return ArtifactIndex.statementTitle(statement, documentTitle: { id in
            TreeWalk.collect(in: store.manifest.structure, where: { $0.id == id })
                .first?.title
        })
    }

    // MARK: - Helpers

    // MARK: - The subject boundary

    // **Two properties, one rule.** Everything below this line that wants a bare
    // `String` takes one of these; nothing else in the window unwraps a
    // `BinderSubject`. Before the type there were three spellings of the same
    // defaulting rule at three call sites — one raw, two `??`-substituted, and a
    // fourth re-substitution inside `DetailPaneToggle` on a value already
    // substituted here — so which pane you were looking at decided what "no
    // document" meant.

    /// The structure item the tree names, when it names one. `nil` for the
    /// project and for no selection alike: neither is an item, and every
    /// consumer of this already had to handle a `nil`.
    private var activeItemID: String? { selectedSubject?.itemID }

    /// The same answer for the panes that require a non-optional document id
    /// (History, Tasks, the annotations arm, the translation arm). They test it
    /// against `BinderSubject.noDocumentSubject`; nothing re-substitutes.
    private var activeDocId: String {
        BinderSubject.activeDocId(for: selectedSubject)
    }

    /// Whether the window's subject still names something, and what it becomes
    /// when it does not.
    ///
    /// **One containment question, asked at two moments.** It was written for
    /// the first — where a freshly opened window lands, given what
    /// `ui-state.json` held and the structure that file's ids are supposed to
    /// name — and `SubjectValidationModifier` asks it again on every structure
    /// change, because a subject can stop naming a row long after the window
    /// opened. A second spelling of the rule for the runtime moment would be
    /// free to disagree with this one about the two cases below that are easy to
    /// get wrong (`.project`, and a group taking its children with it), which is
    /// exactly how it would go wrong: `BinderView` used to hold one, and it
    /// answered *"is the subject the row I deleted?"* rather than *"is the
    /// subject still in the structure?"* — the same question for a document and
    /// a different one for a group.
    ///
    /// **`.project` is valid precisely because it is in no structure.** The
    /// validation this replaces was a bare `TreeWalk.contains` over the subject's
    /// item id, and the project subject has none — so it failed the check and the
    /// window silently landed on the first document instead. A restore that lands
    /// somewhere *plausible* is the failure mode nobody reports: the writer
    /// selects the project, quits, reopens, and sees chapter one with no error
    /// anywhere.
    ///
    /// Four shapes reach here, and the four answers are the whole contract:
    ///
    /// | on disk | answer |
    /// |---|---|
    /// | the project flag | `.project` |
    /// | a bare id still in the structure | that item, unchanged |
    /// | a bare id naming a deleted item | `.project` |
    /// | nothing at all | `.project` |
    ///
    /// **The last two answered "the first document" until slice 3's review, and
    /// that was wrong** — Denver's ruling: *the dim must only ever be entered by
    /// a click*. It was inert for as long as the restored subject only decided
    /// what the editor opened; slice 3 hands the same value to the canvas, where
    /// a document subject FILTERS the board. A window restoring a chapter nobody
    /// chose therefore opened in Plan onto a fully dimmed canvas, with a standing
    /// offer naming a document that appears nowhere on screen and no subject
    /// picker in the `.canvas` binder segment to climb back out of — and the next
    /// sweep silently bound a region to that chapter.
    ///
    /// The accepted trade, stated rather than worked around: a fresh window in
    /// Author opens with **no document in the editor**. `.project` was not
    /// expressible before the binder grew a project row; now that it is, it is
    /// the honest answer to "the writer has not chosen anything".
    ///
    /// The answer is never absent, which is why this returns a subject rather
    /// than an optional one: `.project` is in no structure and so is available
    /// even for a structure with no document in it — the one shape that used to
    /// have no answer at all.
    ///
    /// A pure function rather than four lines inside `load()`: this is a routing
    /// decision, the failure is silent, and `load()` is unreachable from a test.
    ///
    /// **The `nil` row is the restore's answer, not the sweep's.** A window
    /// nobody has clicked in gets `.project` on open; a window whose writer has
    /// deselected is left alone, because the sweep REPAIRS a subject and does
    /// not choose one. That guard lives at the sweep's call site rather than
    /// here — see `SubjectValidationModifier`, where it is also what keeps the
    /// sweep out of `load()`'s own window.
    static func validSubject(_ subject: BinderSubject?,
                             in structure: [StructureItem]) -> BinderSubject {
        switch subject {
        case .project:
            return .project
        case .item(let id) where TreeWalk.contains(id: id, in: structure):
            return .item(id)
        case .item, nil:
            return .project
        }
    }

    /// Whether the window's subject resolves to a manuscript document (the
    /// only selection kind for which the EditorCoordinator delivers metrics).
    private func selectionIsDocument(_ subject: BinderSubject?) -> Bool {
        guard let store, let id = subject?.itemID,
              let item = TreeWalk.find(id: id, in: store.manifest.structure)
        else { return false }
        return item.type == .document && item.path != nil
    }

    private var goalIndicatorState: GoalIndicatorState {
        guard let store else { return .empty }
        let currentDoc = activeItemID.flatMap {
            TreeWalk.find(id: $0, in: store.manifest.structure)
        }

        // For a Collection, derive isScreenplay from the active piece, not the
        // project. Reference pieces hide the goal indicator entirely.
        let isScreenplay: Bool
        let docWordTarget: Int?
        let docPageTarget: Int?
        if store.manifest.type == .collection {
            if let piece = currentDoc, piece.pieceKind == .reference {
                return .empty  // hidden for references
            }
            if let path = currentDoc?.path, path.hasSuffix(".fountain") {
                isScreenplay = true
                docWordTarget = nil
                docPageTarget = currentDoc?.pageTarget
            } else {
                isScreenplay = false
                docWordTarget = currentDoc?.wordTarget
                docPageTarget = nil
            }
        } else {
            isScreenplay = store.manifest.type == .screenplay
            docWordTarget = currentDoc?.wordTarget
            docPageTarget = nil
        }

        return GoalIndicatorState(
            docWordCount: metrics.wordCount,
            docWordTarget: docWordTarget,
            projectWordCount: store.projectWordCount,
            projectWordTarget: store.manifest.targets?.totalWords,
            wordsToday: sessionLog.wordsToday()
                + (documentStore?.liveSessionWordsNet ?? 0),
            readingMinutes: metrics.readingMinutes,
            pageCount: metrics.pageCount,
            pageTarget: store.manifest.type == .collection
                ? docPageTarget
                : store.manifest.targets?.pageTarget,
            isScreenplay: isScreenplay)
    }

    private func applyNoChrome() {
        guard let window else { return }
        window.titlebarAppearsTransparent = isNoChromeOn
        window.titleVisibility = isNoChromeOn ? .hidden : .visible
        window.standardWindowButton(.closeButton)?.isHidden = isNoChromeOn
        window.standardWindowButton(.miniaturizeButton)?.isHidden = isNoChromeOn
        window.standardWindowButton(.zoomButton)?.isHidden = isNoChromeOn
    }

    private func toggleFullScreen() {
        guard let window else { return }
        let wasFullScreen = window.styleMask.contains(.fullScreen)
        if !wasFullScreen && !isNoChromeOn {
            isNoChromeOn = true
            applyNoChrome()
        }
        window.toggleFullScreen(nil)
    }

    @MainActor
    private func showSaveFlash() {
        showingSaveFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            await MainActor.run { showingSaveFlash = false }
        }
    }

    /// ⌘R's acknowledgment. Shorter than ⌘S's: this one says the key was heard,
    /// and the pane says the rest. The word is the acknowledgment's own —
    /// "Checking…" for a press that started a run, "Still checking…" for one
    /// that found a run already under way.
    ///
    /// The generation is what keeps a double-press honest: the first press's
    /// hide is still pending when the second arrives, and without it the
    /// "Still checking…" capsule would be taken off screen by a timer belonging
    /// to a flash the writer has already stopped reading.
    @MainActor
    private func showCompilerFlash(_ acknowledgment: CompilerOrchestrator.Acknowledgment) {
        compilerFlashLabel = acknowledgment.flashLabel
        compilerFlashGeneration &+= 1
        let generation = compilerFlashGeneration
        showingCompilerFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            await MainActor.run {
                guard compilerFlashGeneration == generation else { return }
                showingCompilerFlash = false
            }
        }
    }

    private func handleShowLatestMCPNote() {
        guard let id = mcpBanner.latestId else { return }
        binderSegment = .research
        selectedResearchId = id
        mcpBanner.dismiss()
    }

    @MainActor
    private func load() async {
        do {
            let s = try await ProjectStore.load(from: url)
            let ds = try await DocumentStore.open(url: url)
            s.documentStore = ds
            // The canvas's equivalent, and set here for the same reason: the
            // model is `@State` on this view, so nothing an MCP tool is handed
            // can reach it otherwise. In `load()` and never in `body` — a store
            // is not read from a view body or anything a body calls.
            s.liveCanvas = canvasModel
            self.store = s
            self.documentStore = ds
            // The compiler, wired here for the canvas model's reason: the
            // stores exist at this point and a view body may not read one.
            self.compilerModel = ds.uiState.compilerModel
            // The width only; nothing is studied when a window opens, and
            // restoring a subject would put a reference column over the prose
            // before the writer had asked for anything.
            self.assistant.width = ds.uiState.assistantColumnWidth
            // The right column's width, restored for the assistant column's
            // reason and by the same read. A window that opened before this
            // line existed opened at the range's `max` or its `min` depending
            // on what the last visibility transition had left behind.
            self.detailColumnWidth = ds.uiState.detailColumnWidth
            // The Intent pane's strata, on the same device slug and the same
            // rule as every other derived sidecar (tripwire 24 at the filename
            // point, which both stores take care of themselves).
            //
            // **Built BEFORE the compiler, because the run reads both.** The
            // declared world is what ⌘R briefs its clauses from and the bible
            // is the ledger a run slices and then feeds; a compiler configured
            // against stores that did not exist yet would be a run with no
            // clauses and facts that go nowhere, all of it silent.
            let device = DeviceSlug.make(from: MacDeviceID.current)
            let bibleStore = BibleStore(projectRoot: url, device: device)
            let worldStore = DeclaredWorldStore(projectRoot: url, device: device)
            self.bible = bibleStore
            self.declaredWorld = worldStore
            compiler.configure(
                environment: .production(
                    store: s, documentStore: ds, projectURL: url,
                    declaredWorld: worldStore, bible: bibleStore,
                    preferences: userPreferences,
                    model: ds.uiState.compilerModel.claudeModel,
                    onRunAcknowledged: { showCompilerFlash($0) }),
                diagnostics: DiagnosticsStore(
                    projectRoot: url,
                    device: DeviceSlug.make(from: MacDeviceID.current)))
            mcpRegistry.register(url: url, store: s)
            self.sessionLog = (try? await ds.loadSessionLog()) ?? .empty

            // Seed UI state from disk (or defaults), through the one rule that
            // decides where a freshly opened window lands. There is always an
            // answer — `.project` needs no document to exist — so there is
            // nothing to leave alone and no `if let` here.
            self.selectedSubject = Self.validSubject(
                ds.uiState.selectedSubject, in: s.manifest.structure)
            self.isNoChromeOn = ds.uiState.isNoChromeOn
            self.isReviewModeOn = ds.uiState.isReviewModeOn
            self.researchPreviewVisible = ds.uiState.researchPreviewVisible
            // Restored VERBATIM, exactly as the binder below is. Coercing to
            // the restored persona's registry here silently ate the writer's
            // last explicit pane choice (⌘⌥O in any persona, quit, reopen →
            // Outline gone), and would have moved every pre-persona project off
            // Annotations/History/Inbox/Translation on upgrade. It protects
            // nothing: `DetailPaneToggle` appends an out-of-persona selection
            // and renders it highlighted — `visibleSegments`' own doc comment
            // names a restored `UIState` as a path that append exists to
            // honour — and the one genuinely un-appendable value (`.outline`
            // on a collection) is handled by the snap on mount.
            self.detailSegment = ds.uiState.detailSegment
            self.persona = ds.uiState.persona
            self.outlineLayout = ds.uiState.outlineLayout

            // Restore binderSegment from saved state. A screenplay has no
            // Manuscript segment (Scenes IS its slugline navigator), so route
            // through the typed `documentHome(for:)` rather than re-deriving
            // the check inline — `Persona.swift` warns against exactly that,
            // and it shipped a real bug on 2026-07-02.
            let savedSegment = ds.uiState.binderSegment
            self.binderSegment = savedSegment == .manuscript
                ? .documentHome(for: s.manifest.type)
                : savedSegment
            applyNoChrome()
            loadError = nil
        } catch ProjectStoreError.manifestNotFound {
            loadError = "No project.maugham.json was found in this folder."
        } catch ProjectStoreError.manifestUnreadable(let msg) {
            loadError = "Manifest is corrupt or unreadable: \(msg)"
        } catch ProjectStoreError.manifestSchemaTooNew {
            loadError = "This project was created by a newer version of "
                + "Maugham. Update Maugham to open it."
        } catch {
            loadError = error.localizedDescription
        }
    }

}

// MARK: - CheckpointModifier

/// Breaks the ⌘S / Shift-⌘S checkpoint notification handlers out of the
/// main body chain so Swift's type-checker doesn't time out.
private struct CheckpointModifier: ViewModifier {
    let documentStore: DocumentStore?
    let store: ProjectStore?
    /// The owning project window. Key-window commands (ADR 0021):
    /// `.onKeyWindowCommand` scopes ⌘S / Shift-⌘S delivery to the key window,
    /// so ⌘S checkpoints + backs up the front project only. The store /
    /// documentStore checks below are action preconditions, not scope guards.
    let window: NSWindow?
    /// Fallback project URL, threaded to RewindModifier for its project scope
    /// when `store` hasn't loaded yet (ADR 0021).
    let url: URL
    /// The item the tree names, already converted at `ProjectWindow`'s
    /// boundary — `nil` for the project and for no selection alike.
    let selectedItemId: String?
    /// The breadcrumb's stream id, from the same boundary. Taken rather than
    /// re-derived: this modifier used to spell the `?? "__no-selection__"` rule
    /// a second time, three hops from the two other spellings of it.
    let activeDocId: String
    @Binding var showingCheckpointLabelSheet: Bool
    let onSaveFlash: () -> Void
    @Environment(BackupCoordinator.self) private var backupCoordinator

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamSaveCheckpoint, window: window) { _ in
                guard let store, let documentStore else { return }
                let allDocIds = ProjectWindow.documentIds(in: store.manifest.structure)
                let activeDoc = activeDocument(
                    selectedItemId: selectedItemId,
                    structure: store.manifest.structure,
                    documentStore: documentStore)
                Task { @MainActor in
                    try? await activeDoc?.flushBurstNow()
                    _ = try? await CheckpointCapture.run(
                        projectURL: store.url,
                        activeDocId: activeDocId,
                        allDocIds: allDocIds,
                        device: _checkpointDeviceId,
                        session: _checkpointSessionId,
                        label: nil,
                        activeDocument: activeDoc)
                    onSaveFlash()
                    // Back up after the checkpoint is durable. The coordinator
                    // hops off-main internally and records status.
                    await backupCoordinator.backupNow(
                        projectURL: store.url,
                        generationId: ULID.generate(),
                        at: Date())
                }
            }
            .onKeyWindowCommand(.maughamNamedCheckpoint, window: window) { _ in
                guard store != nil else { return }
                showingCheckpointLabelSheet = true
            }
            .modifier(RewindModifier(
                documentStore: documentStore,
                store: store,
                window: window,
                url: url,
                selectedItemId: selectedItemId))
    }

    private func activeDocument(
        selectedItemId: String?,
        structure: [StructureItem],
        documentStore: DocumentStore
    ) -> Document? {
        guard let id = selectedItemId,
              let item = TreeWalk.find(id: id, in: structure),
              let path = item.path else { return nil }
        return documentStore.document(for: path)
    }
}

// MARK: - RewindModifier

/// Owns the .maughamOpenRewind notification listener and the RewindWindow
/// sheet. Extracted into its own modifier to stay within Swift's type-checker
/// expression limit in ProjectWindow.body.
private struct RewindModifier: ViewModifier {
    let documentStore: DocumentStore?
    let store: ProjectStore?
    /// The owning project window, for the ADR 0021 `.onProjectEvent`
    /// liveness guard on `.maughamOpenRewind`.
    let window: NSWindow?
    /// Fallback project URL naming this window's project scope while `store`
    /// hasn't loaded yet (threaded from CheckpointModifier, ADR 0021).
    let url: URL
    let selectedItemId: String?
    @State private var showingRewindModal: Bool = false
    @State private var rewindInitialCursor: RewindCursor = .now
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .onProjectEvent(.maughamOpenRewind,
                            url: store?.url ?? url, window: window) { note in
                // Project-scoped (ADR 0021): HistoryPane posts to
                // `.project(for: projectURL)`, so with multiple ProjectWindows
                // open only the window on the originating project — and only
                // while live — presents the modal. `selectedItemId != nil` is
                // an action precondition (need a doc to rewind), not a scope.
                guard selectedItemId != nil else { return }
                if let opId = note.userInfo?["scrub_op_id"] as? String,
                   let at = note.userInfo?["scrub_op_at"] as? Date {
                    rewindInitialCursor = .atOp(opId: opId, at: at)
                } else {
                    rewindInitialCursor = .now
                }
                showingRewindModal = true
            }
            .sheet(isPresented: $showingRewindModal) {
                rewindSheet
            }
    }

    @ViewBuilder
    private var rewindSheet: some View {
        if let store, let documentStore, let docId = selectedItemId {
            // Snapshot the window's undo manager before the escaping onComplete
            // closure so the restore registers a ⌘Z action (EditorHost's idiom).
            let um = undoManager
            let allIds = ProjectWindow.documentIds(in: store.manifest.structure)
            let paths = ProjectWindow.documentPaths(in: store.manifest.structure)
            let title = paths[docId]?.components(separatedBy: "/").last ?? docId
            RewindWindow(
                projectURL: store.url,
                activeDocId: docId,
                allDocIds: allIds,
                device: _checkpointDeviceId,
                session: _checkpointSessionId,
                docPaths: paths,
                documentStore: documentStore,
                docTitle: title,
                initialCursor: rewindInitialCursor,
                scope: .thisDoc,
                onComplete: { action in
                    showingRewindModal = false
                    switch action {
                    case .cancel:
                        break
                    case .snapshotHere:
                        MaughamEvent.post(
                            .maughamCheckpointAdded, to: .project(for: store.url))
                    case .restoreHere(let opId):
                        Task { @MainActor in
                            _ = try? await documentStore.document(forDocId: docId)?
                                .restoreToOpUndoable(opId: opId, undoManager: um)
                        }
                    }
                })
        }
    }

}

// MARK: - ParagraphNavModifier

/// Handles .maughamNavigateToParagraph in its own modifier to stay within
/// Swift's type-checker expression limit in SessionAndNavigationModifier.
/// Focus-posture wiring (distraction-free chrome + WF1 review posture), pulled
/// off `ProjectWindow.body` to keep the inline modifier chain under SwiftUI's
/// body type-check ceiling (the extracted-ViewModifier pattern; see
/// `Maugham/Views/AREA.md`). Handles ⌘\ no-chrome and ⌘⌥⇧R review (key-window
/// only) and persists both flags to UIState.
private struct FocusPostureModifier: ViewModifier {
    let window: NSWindow?
    let documentStore: DocumentStore?
    @Binding var isNoChromeOn: Bool
    @Binding var isReviewModeOn: Bool
    let applyNoChrome: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamToggleNoChrome, window: window) { _ in
                isNoChromeOn.toggle()
                applyNoChrome()
            }
            .onKeyWindowCommand(.maughamToggleReviewMode, window: window) { _ in
                isReviewModeOn.toggle()
            }
            .onChange(of: isNoChromeOn) { _, newValue in
                applyNoChrome()
                documentStore?.updateUIState { $0.isNoChromeOn = newValue }
            }
            .onChange(of: isReviewModeOn) { _, newValue in
                documentStore?.updateUIState { $0.isReviewModeOn = newValue }
            }
    }
}

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
/// you want it gone. The palette wall's `PaletteSegmentModifier` does auto-hide
/// on entry; §8A.3 says in those words that the canvas does not follow it.
///
/// **The interaction worth knowing about, and it is true of ONE of the two
/// cases.** `CanvasClaudeArrivalModifier.Destination` force-opens the inspector
/// so *Show* names what arrived. For a writer in focus mode:
///
/// - **arriving from another segment** — `binderSegment` changes, so this
///   modifier collapses one pass later and that force-open closes again. The
///   cards are still revealed and selected by the camera move; `⌘\` brings the
///   naming back.
/// - **already on the collapsed canvas** — the segment does not change, neither
///   trigger fires, and the pane stays open beside the collapse. Show works as
///   written.
///
/// So the case that loses the naming pane is the *jump*, not the local reveal.
private struct CanvasCollapseModifier: ViewModifier {
    let binderSegment: BinderSegment
    let projectType: ProjectType
    let isNoChromeOn: Bool
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var showInspector: Bool
    @Binding var inspectorWasVisibleBeforeCanvasCollapse: Bool?
    /// The palette wall's stash, read and cleared on a collapse that arrives in
    /// the same pass as the wall's own exit — see `canvasCollapse`'s takeover.
    @Binding var inspectorWasVisibleBeforePalette: Bool?

    func body(content: Content) -> some View {
        content
            .onChange(of: isNoChromeOn) { _, _ in apply() }
            .onChange(of: binderSegment) { _, _ in apply() }
    }

    /// Both triggers fold the same decision, and the decision is idempotent —
    /// they fire together on a project reopen that restores focus mode *and* the
    /// canvas from `UIState`, and the second one must not stash over the first.
    private func apply() {
        let route = ProjectWindow.inspectorRoute(binderSegment: binderSegment,
                                                 projectType: projectType)
        ProjectWindow.applyCanvasCollapse(
            ProjectWindow.canvasCollapse(
                route: route,
                isNoChromeOn: isNoChromeOn,
                showInspector: showInspector,
                stash: inspectorWasVisibleBeforeCanvasCollapse,
                paletteStash: inspectorWasVisibleBeforePalette),
            columnVisibility: &columnVisibility,
            showInspector: &showInspector,
            stash: &inspectorWasVisibleBeforeCanvasCollapse,
            paletteStash: &inspectorWasVisibleBeforePalette)
    }
}

/// Reports the width of whatever it is applied to — once at mount, and again
/// whenever that width changes.
///
/// A `Color.clear` in a `.background` measures without proposing anything back,
/// which is the whole difference between reading the CONTAINER's geometry and
/// the feedback loop tripwire 3 is about. Nothing it reports is ever persisted.
///
/// **Internal rather than private because `DetailColumnWidthTests` mounts this
/// exact modifier.** The right column's affordability sum is only as good as the
/// number it is fed, and a harness that measured the window its own way would be
/// testing the harness.
struct ContainerWidthReporter: ViewModifier {
    let onWidth: (Double) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, width in
                        onWidth(Double(width))
                    }
            })
    }
}

/// Persona switching. Extracted so ProjectWindow.body's modifier chain gains
/// exactly one expression — the chain is at the SwiftUI type-checker ceiling
/// and three sibling modifiers exist because inlining broke the Release build.
struct PersonaModifier: ViewModifier {
    @Binding var persona: Persona
    @Binding var detailSegment: DetailSegment
    @Binding var binderSegment: BinderSegment
    @Binding var showInspector: Bool
    /// `PaletteSegmentModifier`'s pre-palette visibility stash. Written here
    /// only to DROP it — see `clearsPaletteStash(from:to:)`.
    @Binding var inspectorWasVisibleBeforePalette: Bool?
    /// `CanvasCollapseModifier`'s pre-collapse visibility stash. Written here
    /// only to DROP it — see `releasesCanvasCollapse(from:to:stash:)`.
    @Binding var inspectorWasVisibleBeforeCanvasCollapse: Bool?
    /// The split view's column visibility, handed back here in the SAME pass as
    /// the stash is dropped. Dropping the stash alone would leave the sidebar
    /// hidden in a persona that has no canvas to justify it.
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let window: NSWindow?
    let documentStore: DocumentStore?
    /// Decides the binder's document home — a screenplay has no Manuscript
    /// segment. Read from the manifest at the call site; `.novel` while the
    /// project is still loading, when there is no binder to coerce anyway.
    let projectType: ProjectType

    struct Change: Equatable {
        let persona: Persona
        let segment: DetailSegment
        let binderSegment: BinderSegment
        /// The memory to persist, with the departing persona's position
        /// already recorded. Returned rather than mutated in place so the
        /// whole rule stays one pure function.
        let memory: PersonaMemory
    }

    /// Pure core, so the whole workspace switch is testable without SwiftUI.
    /// This is the ONE place a persona change moves either column — the binder
    /// toggles only render.
    ///
    /// A persona switch is a WORKSPACE switch: the departing persona's two
    /// column selections are snapshotted, and the destination's are restored
    /// (its own home the first time). The earlier rule — keep whatever segment
    /// the destination also offers — is what stranded the binder on Research
    /// after ⌘1 then ⌘2 (2026-07-25 smoke, defect B): Author offers Research,
    /// so nothing ever moved it back.
    ///
    /// The one exception is a transient binder segment. `.find` and `.trash`
    /// (`BinderSegment.isTransient`, the single source shared with
    /// `BinderSegmentPicker.visibleSegments`) are states rather than surfaces,
    /// so they ride through a persona switch untouched — a writer mid-search is
    /// not ejected — and are not recorded as anyone's remembered position.
    static func applyPersonaChange(to persona: Persona,
                                   from currentPersona: Persona,
                                   currentSegment: DetailSegment,
                                   currentBinderSegment: BinderSegment,
                                   projectType: ProjectType,
                                   memory: PersonaMemory) -> Change {
        var memory = memory
        memory.record(persona: currentPersona,
                      binderSegment: currentBinderSegment,
                      detailSegment: currentSegment)
        let binderSegment = currentBinderSegment.isTransient
            ? currentBinderSegment
            : memory.restoredBinderSegment(for: persona, projectType: projectType)
        return Change(persona: persona,
                      segment: memory.restoredDetailSegment(for: persona),
                      binderSegment: binderSegment,
                      memory: memory)
    }

    static func persona(fromPayload raw: String?) -> Persona? {
        guard let raw else { return nil }
        return Persona(rawValue: raw)
    }

    /// True when a persona change moves the binder OFF the palette — the case
    /// where `PaletteSegmentModifier`'s pre-palette visibility stash must be
    /// dropped rather than restored.
    ///
    /// That modifier's `.onChange(of: binderSegment)` fires in a LATER update
    /// pass than this handler, so its exit arm would restore the stashed
    /// visibility *over* the `showInspector = true` below and land the writer
    /// in the new persona with a closed inspector column — unlike every other
    /// persona-switch path. Clearing the stash here (rather than deferring the
    /// force-open by a pass) makes that arm a no-op restore without depending
    /// on SwiftUI pass ordering, which is the fragility tripwire 2 is about.
    static func clearsPaletteStash(from current: BinderSegment,
                                   to next: BinderSegment) -> Bool {
        leaves({ $0 == .palette }, from: current, to: next)
    }

    /// True when a persona change moves the binder OFF the canvas *while a
    /// `⌘\` collapse is in force* — the case where `CanvasCollapseModifier`'s
    /// stash must be dropped and the sidebar handed back, here, synchronously.
    ///
    /// **The same ordering hazard as the palette's, one surface over.** That
    /// modifier's `.onChange(of: binderSegment)` fires in a LATER update pass
    /// than this handler, so its release arm would restore the stashed
    /// visibility *over* the `showInspector = true` below — a writer who had
    /// closed the inspector before collapsing would land in the new persona with
    /// it closed, unlike every other persona-switch path. Doing both halves here
    /// rather than deferring the force-open by a pass is what makes that arm a
    /// no-op instead of a race, which is the fragility tripwire 2 is about.
    ///
    /// **Guarded on the stash rather than on the segment alone**, so a persona
    /// switch off an *uncollapsed* canvas reopens nothing: the writer may have
    /// dragged the sidebar shut themselves, and this is not the code that gets to
    /// undo that.
    ///
    /// **`centresTheCanvas` rather than `== .canvas`, since slice 2.** The
    /// canvas is also the centre column under `.tree`, so Plan-on-the-tree →
    /// Author is a switch OFF the canvas and must hand the sidebar back, while
    /// `.canvas` → `.tree` is not a switch off it at all and must move nothing.
    static func releasesCanvasCollapse(from current: BinderSegment,
                                       to next: BinderSegment,
                                       stash: Bool?) -> Bool {
        stash != nil && leaves(\.centresTheCanvas, from: current, to: next)
    }

    /// The shape both stashes share: a segment change that LEAVES a surface
    /// which had temporarily taken the inspector's column. One spelling, because
    /// two spellings of one rule is how the second one comes to differ.
    ///
    /// **A predicate rather than a segment, since slice 2.** The palette wall is
    /// one segment; the canvas CENTRE is two (`.canvas` and `.tree` both draw
    /// it), so "leaves the canvas" stopped being an equality. Taking the test as
    /// a parameter is what kept that from becoming a second copy of this line.
    private static func leaves(_ isTheSurface: (BinderSegment) -> Bool,
                               from current: BinderSegment,
                               to next: BinderSegment) -> Bool {
        isTheSurface(current) && !isTheSurface(next)
    }

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamSetPersona, window: window) { note in
                guard let next = Self.persona(
                    fromPayload: note.userInfo?[MaughamEvent.personaKey] as? String)
                else { return }
                // The memory is read from (and written back to) `UIState`
                // rather than kept in a parallel `@State` — it is per-project
                // state that sits beside `persona`, and `updateUIState`
                // mutates its in-memory copy synchronously, so the read here
                // always sees the last switch.
                let change = Self.applyPersonaChange(
                    to: next,
                    from: persona,
                    currentSegment: detailSegment,
                    currentBinderSegment: binderSegment,
                    projectType: projectType,
                    memory: documentStore?.uiState.personaMemory ?? .empty)
                if Self.clearsPaletteStash(from: binderSegment, to: change.binderSegment) {
                    inspectorWasVisibleBeforePalette = nil
                }
                if Self.releasesCanvasCollapse(
                    from: binderSegment, to: change.binderSegment,
                    stash: inspectorWasVisibleBeforeCanvasCollapse) {
                    inspectorWasVisibleBeforeCanvasCollapse = nil
                    columnVisibility = .all
                }
                persona = change.persona
                detailSegment = change.segment
                binderSegment = change.binderSegment
                showInspector = true
                documentStore?.updateUIState {
                    $0.persona = change.persona
                    $0.personaMemory = change.memory
                }
            }
    }
}

private struct ParagraphNavModifier: ViewModifier {
    /// The owning project window. `.maughamNavigateToParagraph` and
    /// `.maughamNavigateToScene` are both key-window scoped (ADR 0021), so only
    /// the key window acts.
    let window: NSWindow?
    @Binding var binderSegment: BinderSegment
    /// Moved to Author by a navigation from a persona that would not show the
    /// document — **and left alone in Review, which is the case this rule is
    /// written around.** An annotation row and a history row both post this
    /// notification; a reviewer taken to Author would lose the notes they were
    /// adjudicating against. See `Persona.showsManuscriptDocuments(for:)`.
    @Binding var persona: Persona
    @Binding var detailSegment: DetailSegment
    let documentStore: DocumentStore?
    /// Decides the binder's document home. A screenplay has NO Manuscript
    /// segment — Scenes is the slugline navigator inside the single
    /// `.fountain` — so naming `.manuscript` raw drops the writer into a
    /// one-row `BinderView` (2026-07-02 smoke) and, since
    /// `BinderSegmentPicker.visibleSegments` appends the active selection,
    /// renders a labelled Manuscript tab the persona registry promises never
    /// to offer (`test_screenplayPersonasNeverOfferManuscript`).
    let projectType: ProjectType
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamNavigateToParagraph, window: window) { note in
                // v1: just ensure the manuscript pane is focused.
                // Anchored scroll-to-paragraph is a follow-up.
                _ = note.userInfo?["paragraph_id"] as? String
                ManuscriptNavigation.go(
                    to: ManuscriptNavigation.destination(
                        from: persona,
                        currentBinderSegment: binderSegment,
                        currentDetailSegment: detailSegment,
                        projectType: projectType,
                        memory: documentStore?.uiState.personaMemory ?? .empty),
                    persona: $persona,
                    binderSegment: $binderSegment,
                    detailSegment: $detailSegment,
                    documentStore: documentStore)
            }
            // **The screenplay's own navigation, and the third to route here.**
            //
            // A slugline click posts this from `SceneNavigatorPane`'s `onSelect`
            // (via `BinderPaneToggle`) and `EditorCoordinator` receives it to
            // scroll. Slice 2 gave Plan's Structure tab that same navigator, and
            // in Plan the coordinator does not exist — so the click set the
            // subject and then nothing happened at all: no movement, no error,
            // no greyed-out affordance (slice 2 review, F2). Denver's ruling
            // covers it exactly as it covers the other two: *"if I'm moving to
            // the manuscript I'm moving to Author."*
            //
            // **Two receivers, one poster, and they do different jobs**: this one
            // moves the window to where the script can be read, the coordinator's
            // scrolls to the slugline. Deliberately NOT a re-post once the editor
            // mounts — see `SceneNavigatorPane.subject(_:whenNavigatingTo:)` for
            // the already-recorded first-click edge and why a delayed re-post
            // would be worse than a first click that under-delivers. From Plan
            // that edge is now reachable one more way: the click that moves the
            // window to Author lands in the script rather than on that slugline,
            // and the next one scrolls.
            .onKeyWindowCommand(.maughamNavigateToScene, window: window) { _ in
                ManuscriptNavigation.go(
                    to: ManuscriptNavigation.destination(
                        from: persona,
                        currentBinderSegment: binderSegment,
                        currentDetailSegment: detailSegment,
                        projectType: projectType,
                        memory: documentStore?.uiState.personaMemory ?? .empty),
                    persona: $persona,
                    binderSegment: $binderSegment,
                    detailSegment: $detailSegment,
                    documentStore: documentStore)
            }
            // `.maughamShowHelp` is `.allWindows` scoped, so every live-or-zombie
            // window receives it; `openWindow(id:)` for a singleton Window is
            // idempotent (it brings the one Help window forward), so no
            // key-window guard.
            .onGlobalEvent(.maughamShowHelp) { _ in
                openWindow(id: "help")
            }
    }
}

/// Mirrors posture + appearance changes from ProjectWindow-owned sources into
/// the `EditorControl` model (ADR 0017). Extracted into a ViewModifier to stay
/// under ProjectWindow.body's SwiftUI type-checker ceiling.
private struct EditorControlMirrorModifier: ViewModifier {
    let effectivePosture: ReviewPosturePolicy.Effective
    let effectiveTypography: TypographySettings
    @Binding var editorControl: EditorControl
    @Environment(UserPreferences.self) private var userPreferences

    func body(content: Content) -> some View {
        content
            .onChange(of: effectivePosture) { _, posture in
                editorControl.isReviewMode = posture.isReviewMode
                editorControl.lockEditing = posture.lockEditing
            }
            .onChange(of: userPreferences.theme) { _, t in editorControl.theme = t }
            .onChange(of: effectiveTypography) { _, t in editorControl.typography = t }
            .onChange(of: userPreferences.typewriterScroll) { _, v in
                editorControl.typewriterScroll = v
            }
            .onChange(of: userPreferences.sentenceFocus) { _, v in
                editorControl.sentenceFocus = v
            }
            .onChange(of: userPreferences.paragraphFocus) { _, v in
                editorControl.paragraphFocus = v
            }
            .onAppear {
                // Seed the model from current sources (onChange only fires on
                // transitions, not on first render).
                editorControl.isReviewMode = effectivePosture.isReviewMode
                editorControl.lockEditing = effectivePosture.lockEditing
                editorControl.theme = userPreferences.theme
                editorControl.typography = effectiveTypography
                editorControl.typewriterScroll = userPreferences.typewriterScroll
                editorControl.sentenceFocus = userPreferences.sentenceFocus
                editorControl.paragraphFocus = userPreferences.paragraphFocus
            }
    }
}

/// Owns this window's translation-review selection (Task 13): receives the
/// key-window picker / enter / exit commands (ADR 0021), resolves the active
/// doc's available languages for the picker, mirrors the chosen language
/// ONE-WAY into `editorControl.translationLanguage` (EditorHost swaps in the
/// derived surface and the coordinator flips its membrane from there — Tasks
/// 11/12), and renders the top indicator pill next to `ReviewModeIndicator`.
///
/// Menu-shape note: the app-global menu can't reach `activeDocId`/`projectURL`
/// (per-window state), so the menu posts a generic "show picker" command and
/// THIS window presents the picker — resolving languages is a direct local call
/// here, and the filesystem scan happens only on demand rather than on every
/// body render (as a focused-value publish of the list would). Extracted into a
/// ViewModifier to stay under ProjectWindow.body's type-checker ceiling.
private struct TranslationReviewModifier: ViewModifier {
    let window: NSWindow?
    let projectURL: URL
    /// From `ProjectWindow`'s boundary, so this modifier sees the same value the
    /// right-hand panes do. It used to be handed the RAW selection under this
    /// name — the one consumer of `activeDocId` with no sentinel substitution at
    /// all, and a third spelling of the rule.
    let activeDocId: String
    @Binding var editorControl: EditorControl

    @State private var translationLanguage: String?
    @State private var pickerLanguages: [String] = []
    @State private var showingPicker = false

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamShowTranslationPicker, window: window) { _ in
                // The sentinel names no document, so the store finds no
                // translations for it and the picker says so — the same empty
                // list the `nil` arm produced before.
                pickerLanguages = activeDocId == BinderSubject.noDocumentSubject
                    ? []
                    : TranslationStore.languages(
                        forDocId: activeDocId, in: projectURL).sorted()
                showingPicker = true
            }
            .onKeyWindowCommand(.maughamEnterTranslationReview, window: window) { note in
                guard let lang = note.userInfo?["language"] as? String else { return }
                translationLanguage = lang
                editorControl.translationLanguage = lang
            }
            .onKeyWindowCommand(.maughamExitTranslationReview, window: window) { _ in
                translationLanguage = nil
                editorControl.translationLanguage = nil
            }
            // The chosen language belongs to the doc that was active when it was
            // picked; a doc switch must drop the posture back to the source.
            .onChange(of: activeDocId) { _, _ in
                guard translationLanguage != nil else { return }
                translationLanguage = nil
                editorControl.translationLanguage = nil
            }
            .confirmationDialog(
                "Translation Review",
                isPresented: $showingPicker,
                titleVisibility: .visible
            ) {
                // Mutate directly — do NOT post .keyWindow events from these
                // buttons. The confirmationDialog's own window holds key status
                // while its action runs, so a synchronous .keyWindow post from
                // here is dropped by shouldDeliver's isWindowKey check (the
                // v0.24.0 enter-does-nothing bug). The onKeyWindowCommand
                // receivers above remain for genuine out-of-window posters.
                ForEach(pickerLanguages, id: \.self) { tag in
                    Button(TranslationReviewIndicator.displayLabel(forLanguageTag: tag)) {
                        translationLanguage = tag
                        editorControl.translationLanguage = tag
                    }
                }
                if translationLanguage != nil {
                    Button("Show Source (Off)") {
                        translationLanguage = nil
                        editorControl.translationLanguage = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(pickerLanguages.isEmpty
                     ? "No translations are available for this document yet."
                     : "Choose a translation to review in read-only mode.")
            }
            .safeAreaInset(edge: .top) {
                if let lang = translationLanguage {
                    TranslationReviewIndicator(
                        languageTag: lang,
                        staleCount: TranslationReviewIndicator.staleCount(
                            in: editorControl.translationBadges.entries),
                        onExit: {
                            MaughamEvent.post(.maughamExitTranslationReview, to: .keyWindow)
                        })
                }
            }
    }
}

/// The canvas's `Promote…` command: enablement, presentation and performance,
/// all in one place so `ProjectWindow.body` gains a single line.
///
/// **`internal`, not `private`, and that is required rather than a style
/// choice**: `@testable import` reaches `internal` and cannot see `private`, and
/// `isPromotable` below is the enablement rule a test drives. `PersonaModifier`
/// in this same file is non-private for exactly that reason; the ones that are
/// private have nothing a test needs.
///
/// **It reads `model.selection` and must NEVER read `model.scene`.**
/// `CanvasModel` is `@Observable` with the whole scene in one stored property,
/// and every drag frame and every coast frame writes it — a read here would put
/// the window's body on the drag loop at 60–120 Hz. `selection` moves on a
/// click. The same rule keeps `store` off this path except inside the two
/// actions below, which run from a user gesture: `begin()` snapshots the
/// manifest once, and `commit(_:)` performs.
///
/// **Measured 2026-07-28** (Debug, macOS 26.5), through a real `CanvasView` in a
/// real `NSHostingView` with the drag driven through the production
/// `CanvasEventNSView` seam: **120 drag frames evaluated this modifier's body
/// once** — the one selection change the opening mouse-down makes — and
/// evaluated the enclosing `ProjectWindow`-shaped body **zero** times. The
/// instrument was calibrated rather than trusted: ten writes to `model.selection`
/// produced exactly ten evaluations, so a result of 1 is a real 1 and not a
/// blind counter. The read is safe because a `ViewModifier`'s body is its own
/// view — SwiftUI's tracking records `selection`, not the window that built it.
struct CanvasPromotionModifier: ViewModifier {
    let window: NSWindow?
    let store: ProjectStore?
    let model: CanvasModel
    let binderSegment: BinderSegment

    @State private var sheet: PromotionSheetModel?
    @State private var failure: String?
    /// What was just produced, in one sentence. Nil when there is nothing to
    /// confirm — see the overlay in `body`.
    @State private var confirmation: String?
    /// The selected node's kind, resolved OUTSIDE `body`.
    ///
    /// **The read has to happen somewhere that is not the view-update path.** A
    /// `model.scene` read in `body` puts the window on the drag loop (see this
    /// type's own doc comment), and the kind is a fact about the scene. The
    /// `.onChange` below runs on a selection change rather than on a body pass,
    /// so it may read the scene freely; `body` then reads a plain `@State`
    /// value that moves only when the selection does.
    @State private var selectedNodeKind: CanvasNodeKind?

    /// Pure and static so the enablement rule is reachable from a test that
    /// hosts no SwiftUI — and so adding a `CanvasSelection` case makes the
    /// compiler enumerate this decision with everything else.
    ///
    /// **`nodeKind` is the item-node guard, and since 1C-d it reads the
    /// PROVENANCE rather than the kind.** A *referenced* item node already
    /// exists as itself, so `Promotion.targets` offers it nothing — and this
    /// said yes for every `.node`, so `Promote…` was enabled and ⌘⇧↩ opened a
    /// sheet that could never commit. An *owned* one is the case that refusal
    /// was never about (spec §6, 2026-07-30): it exists nowhere but the canvas,
    /// and refusing it strands the photograph the writer just sent there. It
    /// takes the kind rather than the scene on purpose: the whole scene is what
    /// this modifier must never read.
    ///
    /// **This and `Promotion.targets` must agree**, or the two halves of one
    /// decision drift: enabled here and empty there is the dead sheet above,
    /// disabled here and offered there is a command greyed out over a promotion
    /// that would work. `PromotionCommandTests` drives both from one table.
    static func isPromotable(binderSegment: BinderSegment,
                             selection: CanvasSelection?,
                             nodeKind: CanvasNodeKind?) -> Bool {
        // **`centresTheCanvas`, and this is the FOURTH site that spelled the
        // canvas check as an equality** — not one of the three the slice-2 plan
        // named, found by grepping the comparison rather than reading the list.
        // The canvas is on screen under `.tree` with a live selection in it, so
        // an equality here would grey `Promote…` out and drop ⌘⇧↩ over a card
        // the writer can see and has selected.
        guard binderSegment.centresTheCanvas else { return false }
        switch selection {
        case .node:
            switch nodeKind {
            case .scrap: return true
            case .item(let reference):
                if case .owned = reference { return true }
                return false
            case nil: return false
            }
        case .region, .line: return true
        case nil: return false
        }
    }

    func body(content: Content) -> some View {
        content
            // `sheet == nil` is joined HERE rather than inside `isPromotable`,
            // and that is deliberate: the pure function stays a fact about the
            // canvas (segment plus selection) that a test can drive, while
            // presentation state stays where presentation lives. Without it the
            // File item is still enabled while the sheet is up — selection and
            // segment have not moved — and a ⌘⇧↩ there is dropped by the very
            // rule the inspector buttons' comments cite, because the sheet's own
            // window holds key status. An enabled command that does nothing is
            // the condition `.disabled(promotable != true)` exists to prevent.
            .focusedSceneValue(\.canvasPromotable,
                               sheet == nil
                               && Self.isPromotable(binderSegment: binderSegment,
                                                    selection: model.selection,
                                                    nodeKind: selectedNodeKind))
            // Reading `model.scene` HERE is safe and in `body` is not: an action
            // closure runs on a change rather than inside a view update, so the
            // scene never becomes a dependency of this modifier's body.
            .onChange(of: model.selection, initial: true) { _, selection in
                guard case .node(let id) = selection else { selectedNodeKind = nil; return }
                selectedNodeKind = model.scene.node(id)?.kind
            }
            .onKeyWindowCommand(.maughamPromoteCanvasSelection, window: window) { _ in begin() }
            .sheet(item: $sheet) { model in
                PromotionSheet(model: model,
                               onCommit: { commit($0) },
                               onCancel: { sheet = nil })
            }
            // **The result reaches the writer.** Every field of
            // `PromotionResult` used to be built and discarded here, and a line
            // promotion sets no mark by design — so the sheet closed and
            // nothing observable changed anywhere, on a surface whose whole
            // promise is that you can see what a command will do. The banner is
            // `MCPNoteBanner`, the house pattern for exactly this, rather than a
            // second one.
            .overlay(alignment: .top) {
                if let confirmation {
                    MCPNoteBanner(message: confirmation,
                                  onDismiss: { self.confirmation = nil })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: confirmation)
            .task(id: confirmation) {
                guard confirmation != nil else { return }
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                confirmation = nil
            }
            .alert("Promotion failed",
                   isPresented: Binding(get: { failure != nil },
                                        set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
    }

    /// The manifest is read ONCE, here, and handed to the sheet as plain values.
    private func begin() {
        guard let store, let selection = model.selection,
              Self.isPromotable(binderSegment: binderSegment, selection: selection,
                                nodeKind: selectedNodeKind) else { return }
        let source: PromotionSource
        switch selection {
        case .node(let id): source = .scrap(id)
        case .region(let id): source = .region(id)
        case .line(let id): source = .line(id)
        }
        let root = store.url
        let research = store.manifest.research
        sheet = PromotionSheetModel(
            source: source, scene: model.scene, scraps: model.scraps,
            // **Both registries**: since M1A a mark can name a `Statement`, and
            // an index built over research alone answers nil for one — see
            // `ArtifactIndex.over` for the readers that then say something
            // false, and what each of them says.
            artifacts: ArtifactIndex.over(research: research,
                                          statements: store.manifest.statements,
                                          structure: store.manifest.structure),
            // **The canvas's own index, and the SAME builder the canvas is
            // handed above** (1C-d Task 12a). A region's palette promotion
            // carries the pictures in it, and a referenced one's file is the
            // manifest's to know — `ArtifactIndex` deliberately holds no paths.
            // One walk more, at the site that already walks this manifest twice
            // for this gesture, rather than a second path index of its own.
            items: ProjectWindow.canvasItemIndex(in: store),
            // Resolved here with the manifest, once, like the index beside it —
            // the sheet is pure values, and this is the one place the routing
            // table is read for it. The performer resolves it again at Commit,
            // because the plan is a snapshot and the manifest can move under it.
            piece: PromotionPiece.resolve(for: source, in: model.scene, store: store),
            readBody: { itemID in
                guard let item = TreeWalk.find(id: itemID, in: research),
                      let path = item.path else { return nil }
                // The annotation sits ON the read's own line: the ADR 0018 grep
                // matches per line and a marker one line above is not seen.
                return try? String(contentsOf: // adr-0018-ok: a research note is not manuscript
                                    root.appendingPathComponent(path), encoding: .utf8)
            })
    }

    private func commit(_ plan: PromotionPlan) {
        guard let store else { return }
        sheet = nil
        Task { @MainActor in
            do {
                let result = try await PromotionPerformer(store: store, model: model)
                    .perform(plan)
                confirmation = result.confirmation(for: plan)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
