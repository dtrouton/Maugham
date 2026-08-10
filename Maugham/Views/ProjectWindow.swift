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
    @State private var selectedPaletteCardId: String?
    /// The palette wall's door (shell-finish stage 2b Task 5) — the Palette
    /// tree section's own "Open Wall" affordance writes this, which is what
    /// carried the wall across Task 7's deletion of the binder strip it used to
    /// be reached through. `showsPaletteWallCentre` is what turns this (plus
    /// the persona) into a routing decision; `PaletteWallModifier` is what
    /// turns it into the inspector stash/restore the old `.palette` segment
    /// used to own.
    @State private var showsPaletteWall: Bool = false
    /// The inspector's visibility captured on entry to the palette wall, so
    /// leaving restores it exactly (spec: no stuck-hidden inspector). `nil`
    /// when the wall is closed. Owned by `PaletteWallModifier`.
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
    /// **Find in Project, as an overlay of the left column** (shell-finish
    /// stage 2b Task 1). Window state rather than segment state: ⌘⌥F writes
    /// this and nothing else, so the overlay rides through a persona switch
    /// untouched and closing it reveals whatever column was underneath instead
    /// of navigating anyone anywhere.
    ///
    /// It replaces `findActive`, which had zero true-writers — both of its
    /// writers wrote `false` — and whose gates in the picker and both toggles
    /// were dead code when they were deleted.
    @State private var treeFindActive: Bool = false
    /// **The tree's own state, owned by the window** (stage-3a Task 4): its
    /// `List` selection, its inline-rename request, its loaded palette cards
    /// and — new in this task — which of its sections and research groups are
    /// open.
    ///
    /// It was `@State` inside each of the three tree hosts until the sections
    /// learned to close. `openResearchItem` and `handleShowLatestMCPNote` name
    /// an item the writer may not be looking at, and making that item's row
    /// visible means opening the section it lives in — which a flag held
    /// privately by whichever host is mounted is not reachable to do. One
    /// window, one tree, one state; the hosts take it and none of them owns it.
    ///
    /// It also outlives the host now, which the find overlay makes visible:
    /// ⌘⌥F replaces the whole left column, so the tree used to come back with
    /// its multi-selection and its open groups reset.
    @State private var treeState = BinderTreeSectionsState()
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
    /// What ⌘⌥Z has to say: the reason it refused a deletion it could not
    /// return whole (RULING-40), or what a restore could not give back
    /// (RULING-42). A refusal the writer never sees is the same as a silence.
    @State private var restoreOutcome: String?
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
        .modifier(SubjectValidationModifier(store: store,
                                            selectedSubject: $selectedSubject))
        .modifier(SessionAndNavigationModifier(
            documentStore: documentStore,
            store: store,
            url: url,
            window: window,
            sessionLog: $sessionLog,
            selectedSubject: $selectedSubject,
            treeFindActive: $treeFindActive,
            pendingPieceRenameId: $pendingPieceRenameId,
            showingTidyAllConfirmation: $showingTidyAllConfirmation,
            showingSyntaxHelp: $showingSyntaxHelp,
            researchPreviewVisible: $researchPreviewVisible,
            showInspector: $showInspector,
            detailSegment: $detailSegment,
            persona: $persona,
            restoreOutcome: $restoreOutcome,
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
                                       persona: $persona,
                                       detailSegment: $detailSegment,
                                       documentStore: documentStore))
        .modifier(FocusPostureModifier(
            window: window,
            documentStore: documentStore,
            isNoChromeOn: $isNoChromeOn,
            isReviewModeOn: $isReviewModeOn,
            applyNoChrome: { applyNoChrome() }))
        .modifier(PersonaModifier(persona: $persona,
                                  detailSegment: $detailSegment,
                                  showInspector: $showInspector,
                                  inspectorWasVisibleBeforeCanvasCollapse:
                                    $inspectorWasVisibleBeforeCanvasCollapse,
                                  columnVisibility: $columnVisibility,
                                  window: window,
                                  documentStore: documentStore))
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
        .modifier(PaletteWallModifier(
            showsPaletteWall: $showsPaletteWall,
            showInspector: $showInspector,
            inspectorWasVisibleBeforePalette: $inspectorWasVisibleBeforePalette,
            selectedPaletteCardId: $selectedPaletteCardId,
            selectedSubject: $selectedSubject,
            persona: persona))
        // A research subject arriving while the canvas holds the centre reveals
        // the column that previews it — one line, because this body has no
        // expression budget (the Release type-check ceiling), and the whole of
        // the rule is in the modifier. Delete this line and every token in that
        // file is still present, every decision test still green, and a research
        // row in Plan's tree puts nothing anywhere.
        .modifier(ResearchRevealModifier(persona: persona,
                                         selectedSubject: $selectedSubject,
                                         showInspector: $showInspector,
                                         detailSegment: $detailSegment))
        .modifier(CanvasPromotionModifier(window: window, store: store,
                                          model: canvasModel, persona: persona))
        // The writer's notice that Claude added cards to their canvas, and the way
        // to go and look. One line, because this body has no expression budget
        // (the Release type-check ceiling); the whole of the behaviour is in the
        // modifier, and THIS LINE is what makes it reachable — deleting it leaves
        // every token in that file present and every test green.
        .modifier(CanvasClaudeArrivalModifier(url: url, window: window,
                                              model: canvasModel,
                                              persona: $persona,
                                              showInspector: $showInspector,
                                              documentStore: documentStore))
        // ⌘\ on the canvas collapses both side columns (spec §8A.3). One line,
        // because this body has no expression budget (the Release type-check
        // ceiling); the whole of the behaviour is in the modifier, and THIS LINE
        // is what makes it reachable — delete it and every token in the modifier
        // is still present, every decision test still green, and ⌘\ on the
        // canvas moves nothing.
        .modifier(CanvasCollapseModifier(
            persona: persona,
            projectType: store?.manifest.type ?? .novel,
            isNoChromeOn: isNoChromeOn,
            columnVisibility: $columnVisibility,
            showInspector: $showInspector,
            inspectorWasVisibleBeforeCanvasCollapse:
                $inspectorWasVisibleBeforeCanvasCollapse))
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

    /// Opening the palette wall hides the right pane so it gets width; closing
    /// restores the pane's prior visibility exactly (spec: no stuck-hidden
    /// inspector). Kept out of ProjectWindow.body for the type-checker budget.
    /// A ⌘⌥N that sets `showInspector = true` while the wall is open wins —
    /// the user explicitly asked for the pane; we don't fight it.
    ///
    /// **Re-keyed on `showsPaletteWall` since stage 2b Task 5** — see
    /// `applyPaletteWallChange`'s doc comment for what changed and why.
    ///
    /// **The subject-change close lives here too**, rather than as a second
    /// modifier: "Esc or any subject change closes it" is the door's own
    /// contract (its Esc half is `PaletteWallCentre.onClose`), and a subject
    /// change that closes the wall must run through the SAME
    /// `applyPaletteWallChange` the door's other exits do, or the inspector
    /// stash restores twice or not at all depending on which `onChange` wins
    /// the pass.
    /// **Internal rather than private because `PaletteWallDoorTests` mounts
    /// this exact modifier** (the `ContainerWidthReporter` precedent). The
    /// persona-change close is a SwiftUI `onChange` and the thing that can fail
    /// about it is whether it fires at all, so a test that re-created the
    /// observer would be testing its own copy.
    struct PaletteWallModifier: ViewModifier {
        @Binding var showsPaletteWall: Bool
        @Binding var showInspector: Bool
        @Binding var inspectorWasVisibleBeforePalette: Bool?
        @Binding var selectedPaletteCardId: String?
        @Binding var selectedSubject: BinderSubject?
        /// The window's working mode — watched, never written. See
        /// `ProjectWindow.closePaletteWallOnPersonaChange`.
        let persona: Persona

        func body(content: Content) -> some View {
            content
                .onChange(of: showsPaletteWall) { old, new in
                    ProjectWindow.applyPaletteWallChange(
                        from: old, to: new,
                        showInspector: &showInspector,
                        stash: &inspectorWasVisibleBeforePalette,
                        selectedPaletteCardId: &selectedPaletteCardId)
                }
                .onChange(of: selectedSubject) { _, _ in
                    if showsPaletteWall { showsPaletteWall = false }
                }
                // **The wall belongs to the persona it was opened in** (final
                // review's I3). Here rather than at the three sites that write
                // `persona`, two of which never touch `PersonaModifier` at all.
                .onChange(of: persona) { _, _ in
                    ProjectWindow.closePaletteWallOnPersonaChange(
                        showsPaletteWall: &showsPaletteWall,
                        stash: &inspectorWasVisibleBeforePalette)
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
        @Binding var treeFindActive: Bool
        @Binding var pendingPieceRenameId: String?
        @Binding var showingTidyAllConfirmation: Bool
        @Binding var showingSyntaxHelp: Bool
        @Binding var researchPreviewVisible: Bool
        @Binding var showInspector: Bool
        @Binding var detailSegment: DetailSegment
        /// Written by `.maughamNavigateToDocument` alone, through
        /// `ManuscriptNavigation` — a navigation to a manuscript document moves
        /// the writer to Author when the persona they are in would not show it
        /// (Denver, 2026-08-02). `.maughamCloseFind` used to read it too, to
        /// send the writer to this persona's binder home; since stage 2b Task 1
        /// closing find moves nobody, so it no longer does.
        @Binding var persona: Persona
        /// What ⌘⌥Z has to say when it cannot restore a deletion whole, or
        /// when a restore gave back less than was deleted (RULING-40/42).
        @Binding var restoreOutcome: String?
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
                // own centre column is the board, which is exactly the state
                // Denver ruled out. Two windows open on ONE project both move,
                // which is the breadth `selectedSubject` has always had here;
                // `persona` is per-project state in `UIState` beside
                // `personaMemory`, shared last-writer-wins by two windows by
                // the same design.
                .onProjectEvent(.maughamNavigateToDocument, url: url, window: window) { note in
                    // `store != nil` rather than a binding: the navigation moves
                    // window state and reads none of the store's, and an unused
                    // `let store` has warned since Task 7 took its last reader.
                    if let id = note.userInfo?["id"] as? String, store != nil {
                        // Whether this persona shows a document at all is
                        // `ManuscriptNavigation`'s to answer.
                        ManuscriptNavigation.go(
                            to: ManuscriptNavigation.destination(
                                from: persona,
                                currentDetailSegment: detailSegment,
                                memory: documentStore?.uiState.personaMemory ?? .empty),
                            persona: $persona,
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
                        do {
                            // Nil report = nothing was armed: a silent no-op,
                            // as it has always been.
                            if let report = try await store?.restoreLastDeletion(),
                               let message = report.message {
                                restoreOutcome = message
                            }
                        } catch {
                            restoreOutcome = error.localizedDescription
                        }
                    }
                }
                .onKeyWindowCommand(.maughamToggleResearchPreview, window: window) { _ in
                    researchPreviewVisible.toggle()
                    documentStore?.updateUIState {
                        $0.researchPreviewVisible = researchPreviewVisible
                    }
                }
                // **⌘⌥F opens the overlay and moves nothing else.** It used to
                // write a `.find` binder segment, which is how find came to be
                // a segment at all — a state wearing a surface's clothes. The
                // overlay is the left column while it is up, in every persona,
                // and the strip never mediated it even when there was one: this
                // handler never consulted the picker's visible list, and there
                // is no longer a picker to consult.
                //
                // Touching nothing but this flag is also what keeps Denver's
                // 2026-08-02 footer ruling true: the footer follows the
                // DOCUMENT in the centre column, opening find does not touch
                // the centre column, so a writer who had the footer still has
                // it.
                .onKeyWindowCommand(.maughamFindInProject, window: window) { _ in
                    treeFindActive = true
                }
                // **The one way down**, reached by both the ✕ and Escape —
                // `ProjectSearchView.close()` is their single call site and this
                // is its only receiver, so the two cannot come to disagree the
                // way the flag-plus-post pair before it could.
                //
                // **Closing find no longer moves the binder**, and that is the
                // whole shape of the change: there is nowhere to send anyone.
                // The overlay was covering a column that is still there, so
                // dismissing it reveals that column. The old handler forced the
                // persona's binder home because it had to undo its own `.find`
                // write, and before slice 2 forced the manuscript segment,
                // which put a writer who pressed ⌘⌥F in Plan and changed their
                // mind into a text editor.
                .onKeyWindowCommand(.maughamCloseFind, window: window) { _ in
                    ProjectWindow.applyCloseFind(treeFindActive: &treeFindActive,
                                                 store: store)
                }
                // **A match click writes the SUBJECT** — the recorded gap that
                // sat here for two slices, closed by stage 2b Task 1.
                //
                // A research match used to write the old research pane's own
                // `selectedResearchId` alone, and while the binder was on
                // `.find` the centre column was `EditorHost` regardless, so
                // clicking a research result showed the writer their
                // manuscript. The fix was never a line in this handler — it
                // needed find to stop taking the centre column hostage, which
                // is what the overlay does: the column underneath is untouched,
                // so `researchSubjectPlacement` routes the subject the way
                // stage 2a routes every other research selection (the centre in
                // Author/Review/Publish, beside the canvas in Plan). The second
                // write went with those panes in the kill task; the subject is
                // now the only thing a match click moves.
                .onKeyWindowCommand(.maughamFindMatchSelected, window: window) { note in
                    guard let store,
                          let match = note.userInfo?["match"] as? SearchMatch,
                          let subject = ProjectWindow.matchSubject(match, in: store)
                    else { return }
                    selectedSubject = subject
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
                .alert("Restore",
                       isPresented: Binding(get: { restoreOutcome != nil },
                                            set: { if !$0 { restoreOutcome = nil } })) {
                    Button("OK", role: .cancel) { restoreOutcome = nil }
                } message: {
                    Text(restoreOutcome ?? "")
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
    // callers, and its body was a second spelling of the binder's document-home
    // rule — the re-derivation that shipped the 2026-07-02 screenplay navigate
    // bug. A dead copy of a load-bearing rule is a copy waiting to be called.
    // Both it and the rule it copied are gone now; `TreePane` is the surviving
    // half of that question.

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
    /// The shell is only half the address: which TREE it puts up is
    /// `TreePane(for:)`, and that is where a screenplay diverges — its tree is
    /// the Scenes navigator, not `BinderView`.
    enum BinderShell {
        /// `BinderPaneToggle` — every non-collection type. Its tree is
        /// `BinderView`; a screenplay puts up `SceneNavigatorPane` instead.
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
    /// **Keyed on the predicate.** The task re-runs when the answer changes,
    /// which is exactly "a surface that lists sluglines just appeared with
    /// nothing to list"; once a script exists the key is `false` and stays
    /// there. The `nil` re-check inside is not redundant with the key — the
    /// derive is a suspension point, and an editor that mounted and posted
    /// across it must not be overwritten by the older op-log parse.
    @ViewBuilder
    private func binderColumn(store: ProjectStore) -> some View {
        binderShell(store: store)
            .task(id: ScreenplayScriptSource.needsDerivation(
                persona: persona,
                projectType: store.manifest.type,
                existing: lastParsedScript)
            ) {
                guard ScreenplayScriptSource.needsDerivation(
                    persona: persona,
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
                selectedSubject: $selectedSubject,
                treeFindActive: $treeFindActive,
                renamingItemId: $pendingPieceRenameId,
                treeState: treeState,
                persona: persona,
                onOpenPaletteWall: { showsPaletteWall = true },
                onRestoreOutcome: { restoreOutcome = $0 }
            )
        case .standard:
            BinderPaneToggle(
                store: store,
                selectedSubject: $selectedSubject,
                projectType: store.manifest.type,
                lastParsedScript: lastParsedScript,
                treeState: treeState,
                treeFindActive: $treeFindActive,
                persona: persona,
                onOpenPaletteWall: { showsPaletteWall = true },
                // **One sink for both restore paths** (final review's I1). ⌘⌥Z
                // and the disclosure's own Restore say the same kind of thing —
                // RULING-40's refusal, RULING-42's shortfall — and only this
                // alert is mounted unconditionally, so only it can be shown by a
                // restore that empties the trash and takes the rows with it.
                onRestoreOutcome: { restoreOutcome = $0 })
        }
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
        // The gate is a named pure function, not the two segment equalities
        // that used to be written out here. Plan is deliberately absent — the
        // footer reports manuscript metrics, and readiness stays silent about
        // the canvas (umbrella §7, §9).
        //
        // **Denver's 2026-08-02 find ruling holds by construction and no input
        // carries it** — find is an overlay of the left column, so this gate
        // sees whatever the overlay is covering: opening find does not touch the
        // centre column, so it cannot take the footer away. Task 1 asserted that
        // (`test_openingTheOverlayCannotTakeTheStatusFooterAway`) rather than
        // adding a parameter that could not change an answer, and the re-base
        // onto the persona inherits the same shape.
        guard Self.showsStatusFooter(
            persona: persona,
            subject: selectedSubject,
            showsPaletteWall: showsPaletteWall,
            structure: store?.manifest.structure ?? []) else { return false }
        if isNoChromeOn { return false }
        return true
    }

    /// **Does the centre column hold a manuscript document?** — asked of the
    /// persona, and then of what the writer has actually put in there.
    ///
    /// The footer follows the DOCUMENT in the centre and never the shape of the
    /// left column, which is the whole of Denver's 2026-08-02 ruling. Until
    /// stage 2b Task 6 that was spelled as a switch over the binder segment
    /// (`BinderSegment.showsManuscriptStatusFooter`); the persona is the durable
    /// basis, because Plan is the persona whose centre is the board and the
    /// other three are where the editor lives. Task 7 deleted the interim
    /// narrowing that stood beside it — old panes could hold Author's centre
    /// while the strip existed, and none of them exists now.
    ///
    /// `Persona.showsManuscriptDocuments` rather than `!centresTheCanvas` at
    /// this call site: they are the same value by construction, and this is the
    /// question being asked.
    ///
    /// One narrowing sits under it, and it is about what the centre column
    /// actually holds rather than what the persona usually puts there: a
    /// research subject can take the centre in any persona that hands it over
    /// (stage-2a Task 5), and the footer's four readings are all about a
    /// manuscript document — a goal capsule, the live session words, the `¶id`
    /// under the cursor and the current element. Over a research note the first
    /// is about a different thing and the last two are blank, so the strip is a
    /// row of claims the centre column cannot support.
    ///
    /// **The palette wall since Task 8.** Since stage 2b Task 5 the wall can
    /// take the centre column in Author, Review and Publish
    /// (`showsPaletteWallCentre`) — layered on top of `editorPane`'s other
    /// arms, `researchSubjectPlacement` included, so a wall open over a
    /// research subject still hides the footer. Tasks 6 and 7 each recorded
    /// this as a live gap rather than closing it, because a re-base is bound to
    /// answer exactly what it answered before and this is a behaviour change.
    /// The `.find` overlay took no third parameter for the same-shaped
    /// question and does not get one here either — opening it writes neither
    /// `persona` nor `subject` nor `showsPaletteWall`
    /// (`TreeFindOverlayTests.test_openingTheOverlayCannotTakeTheStatusFooterAway`),
    /// so Denver's 2026-08-02 find ruling holds unchanged by construction.
    /// **The altitude term, since stage 3a Task 2.** The clause below it asks
    /// only whether a RESEARCH item took the centre, so it answered TRUE for the
    /// project, a group and a dangling id — every subject that now draws the
    /// altitude view — and the word count floated over a corkboard. The
    /// argument is the one this comment already makes: a goal capsule, the live
    /// session words, the `¶id` under the cursor and the current element are
    /// four readings about a document, and at altitude there is no document for
    /// them to be about.
    ///
    /// It is asked LAST of the four deliberately. Each clause above it decides
    /// some input alone — the research clause still owns the research subject,
    /// which this one would otherwise answer for on its way past — so no clause
    /// here is a restatement of another.
    static func showsStatusFooter(persona: Persona,
                                  subject: BinderSubject?,
                                  showsPaletteWall: Bool,
                                  structure: [StructureItem]) -> Bool {
        guard persona.showsManuscriptDocuments else { return false }
        guard !showsPaletteWallCentre(showsPaletteWall: showsPaletteWall,
                                      persona: persona) else { return false }
        guard researchSubjectPlacement(persona: persona,
                                       subject: subject).centreItemID == nil
        else { return false }
        return !subjectShowsAltitude(persona: persona, subject: subject,
                                     structure: structure)
    }

    /// **Does the centre column show the project at altitude rather than a
    /// document?** (shell-finish stage 3a Task 2.)
    ///
    /// Four subject shapes resolve to no single document — no subject at all,
    /// the project itself, a group, and an `.item` that names nothing in the
    /// manifest (or a document with no path). Every one of them used to leave
    /// the centre column showing `EditorHost`'s *"Select a document."*, which is
    /// the degrade this replaces: the writer who clicks the project's own head
    /// row now gets the corkboard or the table.
    ///
    /// **Written as the complement of `selectionIsDocument` rather than as a
    /// switch of its own**, because that is already the window's one question
    /// about whether a subject resolves to a manuscript document — the question
    /// the `EditorCoordinator`'s metrics turn on. Two switches over the same
    /// four cases are two answers free to disagree about what a document is.
    ///
    /// `persona.showsManuscriptDocuments` first: Plan's centre column is the
    /// board, and altitude is what the manuscript personas show INSTEAD of a
    /// document, never a fifth surface competing for the centre.
    ///
    /// **`.research` is not this function's question, and it deliberately does
    /// not re-guard it.** `editorPane` asks `researchSubjectPlacement` above the
    /// editor arm, so in every persona that reaches here the research item has
    /// already taken the centre; in the one that does not (Plan) this function
    /// has already refused on the persona. `ProjectAltitudeCentreTests` asserts
    /// that pair over `Persona.allCases` — a guard written here would be a
    /// second place the research routing is decided, and the one that never runs
    /// is the one that goes quietly wrong.
    static func subjectShowsAltitude(persona: Persona,
                                     subject: BinderSubject?,
                                     structure: [StructureItem]) -> Bool {
        guard persona.showsManuscriptDocuments else { return false }
        return !selectionIsDocument(subject, in: structure)
    }

    /// **What the window is about after a search match is clicked**, as a pure
    /// function, so the routing is drivable without a mounted window — the two
    /// arms differ only in which tree the match's path is looked up in, and
    /// that symmetry is exactly what was missing while the research arm wrote a
    /// pane's private selection and the manuscript arm wrote the subject.
    ///
    /// `nil` when the match names a path no longer in the manifest (renamed or
    /// deleted between the search and the click), which is a stale result rather
    /// than a place to send anyone.
    static func matchSubject(_ match: SearchMatch,
                             in store: ProjectStore) -> BinderSubject? {
        switch match.documentSource {
        case .manuscript:
            return TreeWalk.first(in: store.manifest.structure) {
                $0.path == match.documentPath
            }.map { .item($0.id) }
        case .research:
            return TreeWalk.first(in: store.manifest.research) {
                $0.path == match.documentPath
            }.map { .research($0.id) }
        }
    }

    /// **Closing the find overlay, whole**, so the handler above is a call
    /// rather than a rule and a test can drive the real thing.
    ///
    /// Two writes, and they belong together: the flag that says the overlay is
    /// up, and the results it was showing. Clearing one without the other is
    /// what leaves a reopened find sitting on the previous search — the ✕ used
    /// to own the `clearSearch()` half while this handler owned the flag half,
    /// and Escape would have had to remember both.
    ///
    /// It deliberately moves the binder nowhere: see the handler.
    static func applyCloseFind(treeFindActive: inout Bool, store: ProjectStore?) {
        treeFindActive = false
        store?.clearSearch()
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

    /// **The canvas is ONE branch here, and every other branch is written so as
    /// not to become a second one.**
    ///
    /// `CanvasView`'s camera, scrap layouts, thumbnail cache, in-progress scrap
    /// edit and accessibility elements are all `@State` on the view —
    /// `CanvasModel`'s own doc comment says so from the other side ("what
    /// deliberately does not live here: camera, layouts…"). Two branches of a
    /// ViewBuilder conditional are two distinct `_ConditionalContent` arms, so a
    /// second arm that also mounts the board gives it a second identity and
    /// SwiftUI tears the first one down whenever the condition moves: camera
    /// back to origin at zoom 1, every layout re-measured, thumbnails emptied,
    /// `.onAppear` re-reading `canvas.md` and the sidecar.
    ///
    /// **Measured, not deduced** (macOS 26.5, 2026-08-02, on the `.canvas` ↔
    /// `.tree` segment flip that made the point before the strip died): with an
    /// arm apiece a camera at pan (−680, −420) / zoom 1.5 came back at pan
    /// `.zero` / zoom 1, the `CanvasEventNSView` was a different object and
    /// `load()` had run twice. That flip no longer exists — Plan has one left
    /// column — but the shape it taught is why the research arm above answers
    /// `.besideTheCanvas` in Plan rather than taking the centre, and why the
    /// mount is censused in `RegionBindingTests` rather than trusted.
    @ViewBuilder
    private func editorPane(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        let route = Self.editorRoute(
            persona: persona,
            projectType: store.manifest.type,
            selectedPieceIsReference: selectedPieceIsReference(in: store))
        // **Above everything else, including `researchSubjectPlacement`**
        // (stage 2b Task 5). The wall is a deliberately-entered posture like
        // the canvas is, and it is layered on TOP of the tree — every tree
        // writes the subject, so a research row selected while the wall is open
        // could otherwise claim the centre out from under it.
        // `PaletteWallModifier` closes the wall on any subject change, so in
        // practice the two rarely coincide; this is the belt to that
        // modifier's braces; the guard on persona is the same belt-and-braces
        // the door's own disabled state already keeps.
        if Self.showsPaletteWallCentre(showsPaletteWall: showsPaletteWall, persona: persona) {
            PaletteWallCentre(store: store, selectedPaletteCardId: $selectedPaletteCardId,
                              onClose: { showsPaletteWall = false })
        // **Above `editorRoute` and never inside it**, because the canvas
        // branch below must stay the one the canvas is mounted from: a
        // `.research` subject in Plan resolves to `.besideTheCanvas` and never
        // reaches here, so the board keeps its identity and the RIGHT column
        // takes the item (`researchSubjectPlacement`).
        } else if let id = Self.researchSubjectPlacement(
            persona: persona, subject: selectedSubject).centreItemID {
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: id, previewVisible: researchPreviewVisible)
        } else if route == .canvas {
            canvasCentre(store: store, documentStore: documentStore)
        } else if route == .collectionReference,
                  let id = activeItemID,
                  let piece = store.manifest.structure.first(where: { $0.id == id }) {
            ReferencePlaceholderCard(piece: piece) {
                openReferenceInWindow(piece: piece, store: store)
            }
        } else {
            manuscriptEditor(store: store, documentStore: documentStore)
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

    /// **The manuscript editor, and the centre column's last resort.**
    ///
    /// It was `existingEditorSwitch` — a `switch` over `BinderSegment` with six
    /// arms, four of them either unreachable or an old pane — until shell-finish
    /// stage 2b Task 7 took the enum. What is left is what every arm that could
    /// still be reached did: mount the editor on whatever document the tree
    /// names. A screenplay reaches it too; its tree is the slugline navigator,
    /// and the underlying `.fountain` is the same file.
    ///
    /// **And the project at altitude, as of stage 3a Task 2 — layered INSIDE
    /// this arm rather than beside it.** When the tree names no single document
    /// the host has nothing to open and shows *"Select a document."*; that
    /// placeholder is what the altitude view covers. A sixth arm in `editorPane`
    /// would have been the obvious spelling and is the wrong one: two ViewBuilder
    /// branches are two view identities, so every project ↔ chapter hop — the
    /// gesture this task exists to create — would unmount `EditorHost`, and its
    /// `.onDisappear` is `doc.close()` + `documentStore.unregister(path:)` +
    /// `loads.abandon()`, not a cleanup. Layered, the host keeps its identity
    /// and its Document across the hop and the overlay is the only thing that
    /// comes and goes. `ProjectAltitudeCentreTests` counts the host's lifetimes
    /// over the round trip, and drives the rejected shape as its control.
    ///
    /// The overlay is opaque and fills the column on purpose: the placeholder is
    /// still mounted underneath it.
    private func manuscriptEditor(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        ZStack {
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
            if Self.subjectShowsAltitude(persona: persona,
                                         subject: selectedSubject,
                                         structure: store.manifest.structure) {
                ProjectAltitudePane(
                    store: store,
                    layout: $outlineLayout,
                    selectedSubject: $selectedSubject,
                    title: store.manifest.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    /// **The one place the canvas is mounted in production.**
    ///
    /// Named and extracted so that every route to the board reaches the SAME
    /// view identity through `editorRoute` (see `editorPane`) rather than an arm
    /// apiece. A second mount would give some other condition a canvas of its
    /// own, and the cost of that is the writer's camera, layouts and thumbnails
    /// with nothing red anywhere — so the mount count is censused in
    /// `RegionBindingTests`, beside the inspector arm's. The token that census
    /// counts is deliberately not spelled in this comment.
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

    /// Records the measured container width, but **only when it changes what
    /// the window can afford**. A window drag-resize is 60 frames a second and
    /// this view's `body` is not something to re-evaluate at that rate; the
    /// affordable ceiling is unchanged across almost all of that range, so
    /// almost all of those frames write nothing.
    ///
    /// **Keyed on the CEILING, and deliberately blind to the persisted width.**
    /// The stored container has two consumers — `effectiveDetailColumnWidth`,
    /// which reads it at the *current* width, and `draggableDetailCeiling`,
    /// which reads it at the range's *upper bound* — and a memo is only sound
    /// when it is keyed on something that determines every consumer. This was
    /// keyed on the effective width at the current persisted value, which is
    /// the first consumer and not the second, and the consequence was total:
    /// for any persisted width the window could already afford (the 280 default,
    /// and every value a drag could produce, since the drag is capped by the
    /// very ceiling being starved) the guard compared a value to itself, never
    /// recorded, and left `containerWidth` nil for the life of every window. The
    /// drag ceiling was then permanently the nil fallback — narrower than the
    /// range the column replaced, on a display of any size, self-sealing across
    /// relaunches because drag-end persisted the starved value. Found by
    /// whole-branch review, 2026-08-08, in the seam between two of this task's
    /// own fix rounds; `test_aFreshProjectCanDragPastTheUnmeasuredFallback` is
    /// the regression, and it goes through this guard rather than around it —
    /// on a window merely wider than the floor, since asserting the ceiling was
    /// the range's own 480 made it a claim about the developer's monitor.
    ///
    /// The persisted width is not a parameter any more, so the shape that caused
    /// this cannot be spelled here again.
    static func recordsContainerWidth(_ width: Double, over current: Double?) -> Bool {
        draggableDetailCeiling(containerWidth: width)
            != draggableDetailCeiling(containerWidth: current)
    }

    private func noteContainerWidth(_ width: Double) {
        guard Self.recordsContainerWidth(width, over: containerWidth) else { return }
        containerWidth = width
    }

    /// **The width actually handed to the split view: the writer's wish, reduced
    /// only as far as this window can afford it.**
    ///
    /// The three columns' floors out-arithmetic the window's own: at the window
    /// floor the binder and the prose between them want more than the window has
    /// to give, and what is left is less than the 480 a writer is allowed to
    /// wish for. **The number is not written here** — the code above computes it
    /// from the constants and `test_theAffordabilitySumGivesTheWindowWhatItNeedsAndTheWriterTheRest`
    /// asserts it the same way; a worked example in prose is the
    /// unmaintainable-count defect wearing arithmetic, and this one shipped
    /// wrong (it said 300 against a true 292, having dropped the sidebar inset
    /// it is standing next to). AppKit does not resolve the shortfall
    /// that by squeezing anything; it silently GROWS the window past its
    /// declared minimum, which is the same "the app moved something under me"
    /// complaint this task exists to kill, relocated from the divider to the
    /// window edge. Found by review, 2026-08-08; the shipped test had asserted a
    /// 980pt window while measuring a 1169pt one.
    ///
    /// **The asymmetry is deliberate and is the point.** This reduces what is
    /// DISPLAYED; it never touches what is STORED. A writer who dragged to 480
    /// on a large display and then opens the project on a laptop gets what that
    /// laptop affords, and their 480 back the moment the window can afford it —
    /// their wish is not edited by the furniture it happened to be opened in
    /// front of.
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

    /// **Where a drag of the right column's handle lands.**
    ///
    /// Pure, and holding all three of the rules the gesture used to hold inline,
    /// because a `DragGesture` body is not something a test can drive without
    /// building gesture-driving machinery for one assertion (re-review, 2026-08-08:
    /// the window-aware ceiling shipped with zero coverage precisely because it
    /// lived in there):
    ///
    /// 1. **The sign.** The handle is on the column's LEADING edge, so a
    ///    leftward drag — a negative translation — makes the column WIDER. The
    ///    subtraction is the whole of that, and it was previously verifiable
    ///    only by reading it.
    /// 2. **The column's own range** (`UIState.clampedDetailColumnWidth`).
    /// 3. **What this window can afford** — a writer may only wish for a width
    ///    they can be shown, so on a narrow window the gesture stops where the
    ///    column stops moving instead of silently banking a wider number that
    ///    would reappear on a bigger display.
    ///
    /// Kept as a static here rather than in a type of its own: its three
    /// siblings above are statics on this view for the same reason, and one more
    /// namespace would be one more place to look for the same arithmetic.
    static func draggedDetailColumnWidth(startWidth: Double,
                                         translation: Double,
                                         containerWidth: Double?) -> Double {
        min(UIState.clampedDetailColumnWidth(startWidth - translation),
            draggableDetailCeiling(containerWidth: containerWidth))
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
                        // Every rule this drag obeys — the leading edge's sign,
                        // the column's range, and what this window can afford —
                        // lives in the pure function, where a test can reach it.
                        detailColumnWidth = Self.draggedDetailColumnWidth(
                            startWidth: start,
                            translation: value.translation.width,
                            containerWidth: containerWidth)
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
    /// can be exhaustive over (persona × type) instead of over the one path a
    /// plan happened to name. `CanvasRouteTests` is that test.
    enum InspectorRoute: Equatable {
        case canvas
        /// A Collection's per-piece inspector, which never consults the persona.
        case collectionPiece
        /// `InspectorView` — the selected manuscript document's own inspector.
        ///
        /// It was called `.segment` while `existingInspectorSwitch` dispatched
        /// on `BinderSegment`; both the switch and the enum died in shell-finish
        /// stage 2b Task 7, and a case named after a type that no longer exists
        /// is the stale second spelling this milestone is about.
        case document
    }

    static func inspectorRoute(persona: Persona,
                               projectType: ProjectType) -> InspectorRoute {
        // The predicate, not `== .plan`: the board is Plan's centre column
        // today, and a persona NAME here says the region inspector belongs to a
        // persona rather than to the column that draws the board. Spelled as an
        // equality in three places with no compiler help, it cost the region
        // inspector its reachability from Plan's tree — the exact defect the doc
        // comment above records.
        if persona.centresTheCanvas { return .canvas }
        return projectType == .collection ? .collectionPiece : .document
    }

    /// The palette wall's own inspector rule, as a fold rather than a closure
    /// body — behaviour unchanged in shape, extracted so a test can drive it.
    ///
    /// **Re-keyed on `showsPaletteWall` in stage 2b Task 5**, rather than on a
    /// `.palette` binder segment. The old key shared an update pass with
    /// `CanvasCollapseModifier`, which watched the same segment — Plan's binder
    /// offered Palette and Canvas side by side, so a one-click palette → canvas
    /// move in focus mode ran both folds in the same pass, in an order neither
    /// could depend on. The wall's door touches no shared key, and Task 7 took
    /// the strip that was the other half of the race: the wall cannot be open in
    /// Plan at all (`showsPaletteWallCentre` refuses to draw it there, and
    /// `closePaletteWallOnPersonaChange` closes it on any persona change), so
    /// the two folds can no longer meet.
    /// **A persona change closes the wall — ANY persona change** (stage 2b
    /// final review's I3).
    ///
    /// The rule used to live in `PersonaModifier`, keyed on the destination
    /// being Plan, and it was reachable only from the ⌘1–⌘4 handler. Two other
    /// writers move the persona: `CanvasClaudeArrivalModifier.show` writes
    /// `persona = .plan` directly (deliberately — its own doc comment argues
    /// down going through the notification), and `ManuscriptNavigation.go`
    /// writes it for a wiki-link jump. So a wall open over Author's centre
    /// survived a Show, hid itself in Plan (`showsPaletteWallCentre` refuses
    /// there), and was back over the manuscript the moment the writer pressed
    /// ⌘2 — with a visibility stash still armed to close their inspector on the
    /// way out.
    ///
    /// **An observer of the persona rather than a call at each writer.** A
    /// census of three call sites is one refactor away from being a census of
    /// two; the wall is window state and the question is about the state.
    ///
    /// **It drops the stash rather than restoring it**, which is what makes the
    /// order-independence argument hold: a persona switch opens the right column
    /// (`PersonaModifier` writes `showInspector = true`), and
    /// `applyPaletteWallChange`'s exit arm — which runs a pass later — would
    /// restore the pre-wall visibility over it and land a writer who had closed
    /// their inspector in the new persona with it closed, unlike every other
    /// switch. A `nil` stash makes that restore a no-op in either order, which
    /// is tripwire 2's whole lesson.
    static func closePaletteWallOnPersonaChange(showsPaletteWall: inout Bool,
                                                stash: inout Bool?) {
        guard showsPaletteWall else { return }
        stash = nil
        showsPaletteWall = false
    }

    static func applyPaletteWallChange(from old: Bool,
                                       to new: Bool,
                                       showInspector: inout Bool,
                                       stash: inout Bool?,
                                       selectedPaletteCardId: inout String?) {
        if new && !old {
            stash = showInspector
            showInspector = false
        } else if old && !new {
            // A `nil` stash is a real state and means "someone else has already
            // taken this memory over" — see `canvasCollapse`'s takeover. It has
            // always been written as a conditional restore; that is now
            // load-bearing rather than merely defensive.
            if let prior = stash { showInspector = prior }
            stash = nil
            selectedPaletteCardId = nil
        }
    }

    /// Whether the palette wall takes the centre column — `showsPaletteWall`
    /// AND the persona is not Plan, whose centre is the canvas (stage 2b Task
    /// 5's contract). Pure and named so `editorPane`'s guard and a test can
    /// share one answer rather than two copies of `persona != .plan` drifting.
    static func showsPaletteWallCentre(showsPaletteWall: Bool, persona: Persona) -> Bool {
        showsPaletteWall && persona != .plan
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
                      stash: Bool)
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
    /// **It used to TAKE OVER the palette wall's stash, and Task 7 deleted that
    /// branch with the strip that made it reachable.** Plan's binder offered
    /// Palette and Canvas side by side, so palette → canvas in focus mode was
    /// **one click** needing no persona switch — and it ran the wall's exit arm
    /// and this collapse **in the same update pass**, in whichever order SwiftUI
    /// picked. Collapse-first remembered the wall's *forced* `false`, and the
    /// exit arm then reopened the inspector against the collapse, leaving the
    /// writer a collapsed canvas with the pane still in it and a memory that
    /// closed the pane for good on the way out — tripwire 2 wearing a segment
    /// picker. The fix was for the collapse to take the wall's memory when one
    /// was live and say so, which made the exit arm's conditional restore a
    /// no-op in either order.
    ///
    /// **The two folds can no longer meet.** The wall is `showsPaletteWall`
    /// since Task 5, its door is disabled in Plan, and a persona change closes
    /// it — every persona change, from every writer of `persona`, since the
    /// final review's I3 (`closePaletteWallOnPersonaChange`; the arm that used
    /// to make this sentence true covered the ⌘1–⌘4 handler alone, so a Claude
    /// arrival or a wiki-link jump carried the wall across). A collapse needs
    /// `route == .canvas`, which is Plan. Task 5 left the branch dormant rather
    /// than dead because the picker was still there; Task 7 removed the picker,
    /// so the branch and the parameter that fed it go together rather than
    /// standing as machinery for a state the window cannot enter. What survives
    /// is the wall's own conditional restore, which is what makes the sequence
    /// *wall in Author → ⌘1 → ⌘\* end where the writer left it.
    static func canvasCollapse(route: InspectorRoute,
                               isNoChromeOn: Bool,
                               showInspector: Bool,
                               stash: Bool?) -> CanvasCollapse {
        let wantsTheWholeWindow = route == .canvas && isNoChromeOn
        switch (wantsTheWholeWindow, stash) {
        case (true, .none):
            return .collapse(columnVisibility: .doubleColumn,
                             showInspector: false,
                             stash: showInspector)
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
                                    stash: inout Bool?) {
        switch decision {
        case .collapse(let visibility, let inspector, let stashed):
            stash = stashed
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
        /// `canvasCentre` — the planning canvas, mounted ONCE, in a branch of
        /// its own so nothing else can give the board a second view identity.
        ///
        /// **It became a case of its own in slice 2**, when the canvas stopped
        /// being one segment's arm inside a switch; `editorPane` records what an
        /// arm apiece cost and what was measured.
        case canvas
        /// A Collection's placeholder for a linked-project reference piece.
        case collectionReference
        /// `manuscriptEditor` — the editor on whatever document the tree names.
        /// It was `.segment` until Task 7, when the switch it named went with
        /// `BinderSegment`.
        case editor
    }

    static func editorRoute(persona: Persona,
                            projectType: ProjectType,
                            selectedPieceIsReference: Bool) -> EditorRoute {
        // The canvas draws whatever else is selected. A reference piece chosen
        // in a Collection's tree stays selected across a persona switch —
        // nothing clears the subject but a delete — so without this the centre
        // column shows the placeholder and the canvas never appears at all.
        if persona.centresTheCanvas { return .canvas }
        return projectType == .collection && selectedPieceIsReference
            ? .collectionReference : .editor
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
            researchOrSubject(store: store)
        }
        // Entering translation review surfaces the Translation segment so the
        // source text + translator queries are one glance away. Exiting leaves
        // the segment in place (it shows a "not in review" empty state) rather
        // than yanking the pane out from under the writer.
        .onChange(of: editorControl.translationLanguage) { _, lang in
            if lang != nil { detailSegment = .translation }
        }
    }

    /// **The right column's outermost question: is the window about a research
    /// item?**
    ///
    /// It sits ABOVE `inspectorRoute` — including above the canvas — because
    /// that is the whole of Plan's half of the contract: the canvas keeps the
    /// centre, so a research click that did not reach this column would change
    /// nothing anywhere and the tree's Research section would be a list that
    /// does not do anything. `inspectorRoute` and `canvasCollapse` are
    /// deliberately left alone: the ⌘\ collapse is a question about the SEGMENT
    /// and must not start answering differently because a row is selected.
    ///
    /// **Being the column's outermost question is not the same as being on
    /// screen, and that gap was the stage 2b final review's Critical.** This
    /// closure is `DetailPaneToggle`'s `inspectorContent`, which its `.inspector`
    /// arm alone renders — and Plan opens on `.inbox`. So the reveal is a rule of
    /// its own (`ResearchRevealModifier` /
    /// `ProjectWindow.revealResearchColumn`), and this method deliberately does
    /// not try to be it: a `@ViewBuilder` cannot move the segment it is being
    /// rendered under.
    ///
    /// A method rather than more `ProjectWindow.body`: the inspector closure is
    /// inside `DetailPaneToggle`'s trailing builder, which is already the
    /// heaviest expression in this file.
    @ViewBuilder
    private func researchOrSubject(store: ProjectStore) -> some View {
        let placement = Self.researchSubjectPlacement(
            persona: persona, subject: selectedSubject)
        if let id = placement.inspectedItemID {
            ResearchSubjectInspector(
                store: store, itemID: id,
                showsPreview: placement.previewsInTheRightColumn)
        } else {
            switch Self.inspectorRoute(persona: persona,
                                       projectType: store.manifest.type) {
            case .canvas:
                canvasInspector(store: store)
            case .collectionPiece:
                collectionInspector(store: store)
            case .document:
                InspectorView(
                    store: store,
                    selectedItemId: activeItemID,
                    metrics: metrics,
                    onOpenProjectSettings: { activeSheet = .projectSettings })
            }
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

    /// **Navigate to a research item: make it the window's SUBJECT** — which is
    /// what every other way of selecting a research row in this app now does.
    ///
    /// It used to force the binder onto a `.research` segment and write that
    /// pane's own private selection, and both halves died with the strip in
    /// stage 2b Task 7. What replaces them is one write, and it is strictly more
    /// than the two it replaces: `researchSubjectPlacement` routes a research
    /// subject to the centre column in Author, Review and Publish and beside the
    /// board in Plan, so **Open** now works from Plan — where the old pair could
    /// only work by dragging the writer's left column out from under them.
    ///
    /// **And the tree opens far enough to show the row** (stage-3a Task 4).
    /// This was the one thing the old segment force did that the subject write
    /// did not, and it was recorded here as a gap for a slice: the item lived
    /// inside a `Section` — and possibly inside a research group — whose
    /// open/closed flag SwiftUI held privately, so the window could point every
    /// column at a note and still leave its row undrawn. The flags are
    /// `BinderTreeSectionsState`'s now (the window owns the object and the trees
    /// take it), and `reveal` opens the section plus every group between the item
    /// and the root. It only ever opens, so a writer's other groups are left
    /// alone; an id the manifest does not hold opens nothing at all.
    ///
    /// Reached from a promoted card's **Open** button (1C-c2), through
    /// `openPromotedArtifact`. The craft-intent inspector affordance was the
    /// other caller until M1A Task 8 replaced it with a pane switch.
    /// **And the reveal, explicitly** (final review's Critical). The subject
    /// observer covers a subject that CHANGES; **Open** pressed on a card whose
    /// item is already the window's subject changes nothing, so no observer
    /// fires and a writer who had the pane on Inbox would press Open and watch
    /// the window sit still. The two writes are idempotent together — the
    /// observer's reveal and this one ask the same function the same question.
    private func openResearchItem(_ itemId: String) {
        selectedSubject = .research(itemId)
        treeState.reveal(itemId, research: store?.manifest.research ?? [])
        Self.revealResearchColumn(persona: persona, subject: selectedSubject,
                                  showInspector: &showInspector,
                                  detailSegment: &detailSegment)
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

    /// What is already in a promotion destination — the read behind the sheet's
    /// `linkAlreadyPresent`, and the one thing the sheet cannot answer from the
    /// plain values it is handed.
    ///
    /// **`PromotionPerformer.writableDestination`'s order, one surface earlier,
    /// and it is one surface rather than two by the same argument the performer
    /// makes.** Research first, then a statement. Resolving `manifest.research`
    /// alone — which is what shipped — answers nil for a line drawn from an
    /// intent-marked card, so `linkAlreadyPresent` stayed false, the sheet
    /// enabled Commit, and the performer's own dedupe threw the refusal into an
    /// alert a second later. A preview that cannot see the destination is not a
    /// preview.
    ///
    /// The statement arm reads `statementText(of:)` rather than the file beside
    /// it: a statement is a `Document` with an op log and its `.md` is derived
    /// output (tripwire 20), and it is the same reader the performer dedupes
    /// against, so the sheet's promise and the write cannot disagree.
    ///
    /// Static and store-taking, like `artifactTitle` and `statementPane` above,
    /// so the resolution is reachable from a test that hosts no window.
    static func promotionDestinationBody(of itemID: String,
                                         in store: ProjectStore) -> String? {
        if let item = TreeWalk.find(id: itemID, in: store.manifest.research),
           let path = item.path {
            // The annotation sits ON the read's own line: the ADR 0018 grep
            // matches per line and a marker one line above is not seen.
            return try? String(contentsOf: // adr-0018-ok: a research note is not manuscript
                                store.url.appendingPathComponent(path), encoding: .utf8)
        }
        // RULING-54 lenient, reason recorded: this feeds a marker-position
        // heuristic; an unreadable statement yields nil (no marker) and the
        // statement pane itself refuses loudly on open.
        return store.manifest.statements.first { $0.id == itemID }
            .flatMap { try? store.statementText(of: $0) }
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
                             in structure: [StructureItem],
                             research: [ResearchItem]) -> BinderSubject {
        switch subject {
        case .project:
            return .project
        case .item(let id) where TreeWalk.contains(id: id, in: structure):
            return .item(id)
        case .item, nil:
            return .project
        case .research(let id) where TreeWalk.contains(id: id, in: research):
            return .research(id)
        case .research:
            return .project
        }
    }

    /// Whether the window's subject resolves to a manuscript document (the
    /// only selection kind for which the EditorCoordinator delivers metrics).
    /// The rule itself is the static in `ResearchSubjectColumns.swift`, where a
    /// test can reach it without a mounted window.
    private func selectionIsDocument(_ subject: BinderSubject?) -> Bool {
        guard let store else { return false }
        return Self.selectionIsDocument(subject, in: store.manifest.structure)
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

    /// **Show**, on the banner that says Claude added a research note.
    ///
    /// One write since stage 2b Task 7, for `openResearchItem`'s reason and with
    /// the same gain: the note becomes the window's subject, so the banner works
    /// in Plan — the persona a writer is most likely to be in when Claude is
    /// adding research — instead of forcing a segment Plan's picker offered and
    /// the other three did not.
    /// **Show reveals the column too** — `openResearchItem`'s reason exactly: a
    /// second note arriving while the writer is already looking at the first
    /// leaves the subject unchanged, and a banner whose button does nothing is
    /// worse than no banner.
    private func handleShowLatestMCPNote() {
        guard let id = mcpBanner.latestId else { return }
        selectedSubject = .research(id)
        // The tree opens far enough to draw the note's row — `openResearchItem`
        // carries why this is a call here and not an observer of the subject.
        treeState.reveal(id, research: store?.manifest.research ?? [])
        Self.revealResearchColumn(persona: persona, subject: selectedSubject,
                                  showInspector: &showInspector,
                                  detailSegment: &detailSegment)
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
                ds.uiState.selectedSubject, in: s.manifest.structure,
                research: s.manifest.research)
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
    /// The post-restore report (RULING-28's after half) — rendered from
    /// `RewindImpact.toast(for:)`, auto-dismissing; carries Revert when the
    /// restore resolved a vanished moment to the nearest surviving one
    /// (RULING-27's notice).
    @State private var restoreToast: String?
    @State private var restoreToastOffersRevert: Bool = false
    @State private var restoreToastUndoManager: UndoManager?
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = restoreToast {
                    HStack(spacing: 12) {
                        Text(toast).font(.callout)
                        if restoreToastOffersRevert {
                            Button("Revert") {
                                restoreToastUndoManager?.undo()
                                restoreToast = nil
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                        Button {
                            restoreToast = nil
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast) {
                        // A notice with an action lingers; a plain report
                        // dismisses itself.
                        try? await Task.sleep(nanoseconds: restoreToastOffersRevert
                                              ? 12_000_000_000 : 6_000_000_000)
                        restoreToast = nil
                    }
                }
            }
            .onProjectEvent(.maughamDocumentNotice,
                            url: store?.url ?? url, window: window) { note in
                // The Document's one writer-facing channel (RULING-7,
                // RULING-22, RULING-32) rendered in the toast this modifier
                // already owns, rather than a second overlay that could stack
                // with a restore report. The message is composed at the post
                // site; the view only shows it. No Revert — none of these
                // notices has an action, and a stale manager from an earlier
                // restore must not be left armed behind one.
                guard let message =
                    note.userInfo?[MaughamEvent.noticeMessageKey] as? String,
                      !message.isEmpty else { return }
                restoreToastOffersRevert = false
                restoreToastUndoManager = nil
                restoreToast = message
            }
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
                            // The result is RENDERED, not discarded (RULING-28's
                            // after half — this `_ =` discard was the defect the
                            // type's own doc comment described): the toast
                            // reports what the restore actually did, and a
                            // `.nearest` resolution carries Revert right in the
                            // notice (RULING-27, the clause Denver added).
                            guard let result = try? await documentStore
                                .document(forDocId: docId)?
                                .restoreToOpUndoable(opId: opId, undoManager: um)
                            else { return }
                            restoreToast = RewindImpact.toast(for: result)
                            // Revert is the surfaced undo — offered only when
                            // the restore actually registered one. A .nearest
                            // resolution that changed nothing has no undo, and
                            // a Revert that pops the writer's own typing stack
                            // would be silent prose loss (branch review).
                            if case .nearest = result.targetResolution,
                               result.restoreOp != nil {
                                restoreToastOffersRevert = true
                            } else {
                                restoreToastOffersRevert = false
                            }
                            restoreToastUndoManager = um
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
private struct CanvasCollapseModifier: ViewModifier {
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
    @Binding var showInspector: Bool
    // **No wall bindings here since the final review's I3 fix.** They were
    // written by one arm of the ⌘1–⌘4 handler and nothing else; leaving them
    // threaded in would invite a second wall rule beside the one observer that
    // now owns the question (`ProjectWindow.closePaletteWallOnPersonaChange`).
    /// `CanvasCollapseModifier`'s pre-collapse visibility stash. Written here
    /// only to DROP it — see `releasesCanvasCollapse(from:to:stash:)`.
    @Binding var inspectorWasVisibleBeforeCanvasCollapse: Bool?
    /// The split view's column visibility, handed back here in the SAME pass as
    /// the stash is dropped. Dropping the stash alone would leave the sidebar
    /// hidden in a persona that has no canvas to justify it.
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let window: NSWindow?
    let documentStore: DocumentStore?

    struct Change: Equatable {
        let persona: Persona
        let segment: DetailSegment
        /// The memory to persist, with the departing persona's position
        /// already recorded. Returned rather than mutated in place so the
        /// whole rule stays one pure function.
        let memory: PersonaMemory
    }

    /// Pure core, so the whole workspace switch is testable without SwiftUI.
    /// This is the ONE place a persona change moves the right column.
    ///
    /// A persona switch is a WORKSPACE switch: the departing persona's pane
    /// selection is snapshotted, and the destination's is restored (its own
    /// default the first time). The earlier rule — keep whatever segment the
    /// destination also offers — is what stranded the binder on Research after
    /// ⌘1 then ⌘2 (2026-07-25 smoke, defect B): Author offered Research, so
    /// nothing ever moved it back.
    ///
    /// **It carried the LEFT column too, until shell-finish stage 2b Task 7.**
    /// There is nothing left to carry: every persona's left column is the
    /// project's own tree, so a switch cannot move it and cannot strand anyone
    /// on it. The transient exception went with it — `.find` and `.trash` were
    /// segments a writer had to be allowed to ride through a switch, and both
    /// are window state now (the find overlay, the trash foot disclosure) which
    /// no persona change touches at all.
    static func applyPersonaChange(to persona: Persona,
                                   from currentPersona: Persona,
                                   currentSegment: DetailSegment,
                                   memory: PersonaMemory) -> Change {
        var memory = memory
        memory.record(persona: currentPersona, detailSegment: currentSegment)
        return Change(persona: persona,
                      segment: memory.restoredDetailSegment(for: persona),
                      memory: memory)
    }

    static func persona(fromPayload raw: String?) -> Persona? {
        guard let raw else { return nil }
        return Persona(rawValue: raw)
    }

    // **The wall's own arm left this handler in the final review's I3 fix.**
    // `clearsPaletteWallStash` asked whether a persona change was entering Plan
    // with the wall open, and it could only ever be asked HERE — of the ⌘1–⌘4
    // handler — while two other writers move the persona without passing
    // through it (`CanvasClaudeArrivalModifier.show`,
    // `ManuscriptNavigation.go`). Its successor is
    // `ProjectWindow.closePaletteWallOnPersonaChange`, observed on the persona
    // itself in `PaletteWallModifier`, which covers all three by construction
    // and every destination rather than Plan alone. It drops the stash for the
    // same ordering reason this one did — see its doc comment.

    /// True when a persona change moves the binder OFF the canvas *while a
    /// `⌘\` collapse is in force* — the case where `CanvasCollapseModifier`'s
    /// stash must be dropped and the sidebar handed back, here, synchronously.
    ///
    /// **The same ordering hazard as the palette's, one surface over.** That
    /// modifier's own `.onChange` fires in a LATER update pass than this
    /// handler, so its release arm would restore the stashed visibility *over*
    /// the `showInspector = true` below — a writer who had closed the inspector
    /// before collapsing would land in the new persona with it closed, unlike
    /// every other persona-switch path. Doing both halves here rather than
    /// deferring the force-open by a pass is what makes that arm a no-op instead
    /// of a race, which is the fragility tripwire 2 is about.
    ///
    /// **The predicate rather than `== .plan`, since slice 2, and asked of the
    /// PERSONA since stage 2b Task 6.** The board is Plan's centre column, so
    /// what "leaving the canvas" means is leaving Plan — and a rule that named
    /// the persona would be claiming the collapse belongs to a mode rather than
    /// to the column that draws the board. Task 7 dropped the two segment
    /// arguments that stood beside these: while the strip existed, Plan's
    /// Palette tab was Plan with no board in front of the writer, and there is
    /// no such state now.
    ///
    /// **Guarded on the stash rather than on the personas alone**, so a persona
    /// switch off an *uncollapsed* canvas reopens nothing: the writer may have
    /// dragged the sidebar shut themselves, and this is not the code that gets
    /// to undo that.
    static func releasesCanvasCollapse(fromPersona: Persona,
                                       toPersona: Persona,
                                       stash: Bool?) -> Bool {
        guard stash != nil else { return false }
        return fromPersona.centresTheCanvas && !toPersona.centresTheCanvas
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
                    memory: documentStore?.uiState.personaMemory ?? .empty)
                if Self.releasesCanvasCollapse(
                    fromPersona: persona, toPersona: change.persona,
                    stash: inspectorWasVisibleBeforeCanvasCollapse) {
                    inspectorWasVisibleBeforeCanvasCollapse = nil
                    columnVisibility = .all
                }
                persona = change.persona
                detailSegment = change.segment
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
    /// Moved to Author by a navigation from a persona that would not show the
    /// document — **and left alone in Review, which is the case this rule is
    /// written around.** An annotation row and a history row both post this
    /// notification; a reviewer taken to Author would lose the notes they were
    /// adjudicating against. See `Persona.showsManuscriptDocuments(for:)`.
    @Binding var persona: Persona
    @Binding var detailSegment: DetailSegment
    let documentStore: DocumentStore?
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
                        currentDetailSegment: detailSegment,
                        memory: documentStore?.uiState.personaMemory ?? .empty),
                    persona: $persona,
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
                        currentDetailSegment: detailSegment,
                        memory: documentStore?.uiState.personaMemory ?? .empty),
                    persona: $persona,
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
    /// The window's working mode — the basis of `isPromotable` since stage 2b
    /// Task 6, because the board is Plan's centre column.
    let persona: Persona

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
    static func isPromotable(persona: Persona,
                             selection: CanvasSelection?,
                             nodeKind: CanvasNodeKind?) -> Bool {
        // **The predicate, and this was the FOURTH site that spelled the canvas
        // check as an equality** — not one of the three the slice-2 plan named,
        // found by grepping the comparison rather than reading the list. The
        // canvas was on screen under Plan's structure tab with a live selection
        // in it, so an equality here greyed `Promote…` out and dropped ⌘⇧↩ over
        // a card the writer could see and had selected. Re-based on the persona
        // in stage 2b Task 6, which is where it stays: the board is Plan's
        // centre column, and that is the fact enablement turns on.
        guard persona.centresTheCanvas else { return false }
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
            // canvas (persona plus selection) that a test can drive, while
            // presentation state stays where presentation lives. Without it the
            // File item is still enabled while the sheet is up — selection and
            // persona have not moved — and a ⌘⇧↩ there is dropped by the very
            // rule the inspector buttons' comments cite, because the sheet's own
            // window holds key status. An enabled command that does nothing is
            // the condition `.disabled(promotable != true)` exists to prevent.
            .focusedSceneValue(\.canvasPromotable,
                               sheet == nil
                               && Self.isPromotable(persona: persona,
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
              Self.isPromotable(persona: persona, selection: selection,
                                nodeKind: selectedNodeKind) else { return }
        let source: PromotionSource
        switch selection {
        case .node(let id): source = .scrap(id)
        case .region(let id): source = .region(id)
        case .line(let id): source = .line(id)
        }
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
            // **The store rather than the captured manifest**, and it is the one
            // value here that is read late by design: `readBody` is called from
            // `select(_:)`, and a statement's text comes from `statementText(of:)`
            // — the pane's live `Document` when there is one, which no snapshot
            // taken at `begin()` can hold. The plain-values discipline above is
            // about what the sheet is HANDED; this is a reader it calls.
            readBody: { ProjectWindow.promotionDestinationBody(of: $0, in: store) })
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
