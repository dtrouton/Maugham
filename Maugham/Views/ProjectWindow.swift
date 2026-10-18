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
let _checkpointSessionId: String = UUID().uuidString
/// This device's own id for checkpoint attribution — the prefix of its key
/// fingerprint (`DeviceIdentity`), read once per process.
let _checkpointDeviceId: String = DeviceIdentity.author.deviceId

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
    /// **The window's flashes and its banner** — ⌘S's capsule, ⌘R's capsule
    /// (its word and its generation) and the MCP note banner — as ONE value.
    /// See `WindowFlashes`.
    @State private var flashes = WindowFlashes()
    /// The Diagnostics pane's gear menu, seeded from `UIState.compilerModel` at
    /// `load()` and written back through `updateUIState` on change.
    @State private var compilerModel: CompilerModelChoice = .standard
    /// **How wide the annotations queue is looking.** Window state because the
    /// board's open-notes column sets it from the CENTRE column. Deliberately
    /// NOT persisted to `UIState`: a scope is a glance, not a home.
    @State private var annotationScopeRequest: AnnotationScope = .document
    /// What this window's tree names — the window's single subject (spec §3).
    /// Typed rather than a `String?` so no site can answer "is this a manuscript
    /// document?" by accident; see `BinderSubject`.
    @State private var selectedSubject: BinderSubject?
    @State private var selectedPaletteCardId: String?
    /// **The palette wall's window state** — its open flag, the door-in-Plan
    /// travel token and the inspector stash — as ONE value. See
    /// `PaletteWallState`; `PaletteWallModifier` takes a binding to the whole,
    /// `CentreColumn` a binding to `showsWall`.
    @State private var paletteWall = PaletteWallState()
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
    /// **A Describe… press in Project Settings, waiting for the sheet to close.**
    ///
    /// `MaughamEvent.postDetailSegment` is scoped `.keyWindow`, and the sheet's
    /// window is key while it is up, so the request is recorded and acted on
    /// from the `.sheet`'s `onDismiss`. **The hand-off WRITES the segment
    /// through `selectDetailSegment`; it does not post it** — `onDismiss` runs
    /// before key status returns, so a `.keyWindow` post would be dropped.
    ///
    /// **Guarded twice**: `describeFirstReader`'s two awaits leave a window in
    /// which the writer can Escape before the request is recorded, and the
    /// request then stands over a sheet that is already gone — so every
    /// presentation clears it (`activeSheet`'s `onChange`, which also mirrors
    /// what is up into `presentedSheet`), and the dismissal that acts on it
    /// must be Project Settings' own (`opensFirstReader`) — otherwise closing
    /// any other sheet would jump the right column to her statement.
    @State private var describeFirstReaderRequested = false
    /// **Which sheet is up** — `onDismiss` is told nothing about what closed,
    /// and the decision above turns on it. Mirrored from `activeSheet` rather
    /// than read from it, because by the time `onDismiss` runs `activeSheet`
    /// is already nil.
    @State private var presentedSheet: ProjectActiveSheet?
    @State private var showInspector: Bool = true
    /// The right column's one width. Restored from `UIState` in `load()`;
    /// written back by the column's own drag handle and by nothing else — see
    /// `RightColumn`, which takes it as a binding.
    @State private var detailColumnWidth: Double = UIState.defaultDetailColumnWidth
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
    /// **Find in Project, as an overlay of the left column.** Window state
    /// rather than segment state: ⌘⌥F writes this and nothing else, so the
    /// overlay rides through a persona switch untouched and closing it reveals
    /// whatever column was underneath instead of navigating anywhere.
    @State private var treeFindActive: Bool = false
    /// **The tree's own state, owned by the window**: its `List` selection, its
    /// inline-rename request, its loaded palette cards and which of its
    /// sections and research groups are open. One window, one tree, one state;
    /// the three tree hosts take it and none of them owns it — so
    /// `openResearchItem`/`handleShowLatestMCPNote` can open the section a row
    /// lives in, and the tree survives the find overlay replacing the column.
    @State private var treeState = BinderTreeSectionsState()
    @State private var pendingPieceRenameId: String?
    @State private var detailSegment: DetailSegment = .inspector
    @State private var persona: Persona = .default
    @State private var outlineLayout: OutlineLayout = .table
    /// **What the Publish persona's centre column is showing** — the compiled
    /// books, the header's pick, and the desk's two Shows — and the rules for
    /// changing it. Window-transient: see `PublishCentreModel`.
    /// `PublishPreviewModifier` keeps its books current; `CentreRoute` decides
    /// which surface draws from its values.
    @State private var publishCentre = PublishCentreModel()
    @State private var showingCheckpointLabelSheet: Bool = false
    @State private var currentElement: String? = nil
    /// Control-plane model for the editor (ADR 0017). ProjectWindow is its sole
    /// posture/appearance writer; EditorHost writes the annotation set.
    /// Threaded down to the coordinator, which observes it.
    @State private var editorControl = EditorControl()
    /// The canvas's scene, scraps, selection, sidecar store and undo recorder.
    /// Owned HERE rather than inside `CanvasView` because the region inspector in
    /// the right-hand column reads and mutates the same scene the centre column
    /// draws — and region labels do not live in the manifest, so a `ProjectStore`
    /// could not carry them.
    @State private var canvasModel = CanvasModel()
    /// **The window's ONE borrow of its project's session**, which owns the
    /// window's `claude` services (compiler, translator, designer, cold-call
    /// runner, pipeline, translation run log) — owned at window level because
    /// a run is started from one column and read in another. The window attaches on `load()`
    /// (`ProjectSession.attachWindow`) and gives the borrow back in
    /// `.onDisappear` (`ProjectSession.detachWindow`); `CompilerRunModifier`
    /// runs `roster.shutdownAll()`, pipeline first. A session merely released
    /// is a live, billing process — `AgentRoster`'s own contract. The session
    /// is read through the lease, so there is no second state to disagree.
    @State private var lease: ProjectSessionRegistry.Lease?
    private var session: ProjectSession? { lease?.session }
    /// The session's roster once the project is open; before that (and after
    /// the close) an unconfigured placeholder, so every caller always has a
    /// roster to name. Every verb on an unconfigured service is a no-op.
    private var roster: AgentRoster { session?.roster ?? Self.unloadedRoster }
    private static let unloadedRoster = AgentRoster()
    /// The two members this file's own body still reaches by name. The right
    /// column reads the rest off the roster in its environment (`RightColumn`).
    private var compiler: CompilerOrchestrator { roster.compiler }
    private var designer: DesignerOrchestrator { roster.designer }
    /// The Intent pane's two lower strata: Claude's bible of what the
    /// manuscript has established, and the per-scope cache of its readings of
    /// the writer's statements. Window mirrors of the session's stores, because
    /// the RIGHT column's pane reads them and its ruling verbs invalidate the
    /// cache — a store built inside the pane would be a second cache the run
    /// never hits. Both materialize a sidecar in `init`, so they are built in
    /// `ProjectSession.open` and never from a view body.
    @State private var bible: BibleStore?
    @State private var declaredWorld: DeclaredWorldStore?

    /// **What pin is being studied** (M2 §6.2). Owned by the window because the
    /// References pane writes it and `RightColumn`'s study arm — which stands
    /// *in place of* that pane — is a function of it. It has no width; a
    /// studied reference takes `detailColumnWidth` (spec §3.2).
    @State private var assistant = AssistantColumnModel()
    /// This project's iCloud share snapshot, read on open and on a share-change,
    /// then cached — an INDICATOR, never a role. It drives the sharing pill, the
    /// share sheet's eligibility, and the read-only-share lock
    /// (`shareIsReadOnly`); the editor's review posture is the permit's
    /// (`editorMembrane`). `nil` until the first read completes.
    @State private var shareSnapshot: ShareMetadata?
    /// What ⌘⌥Z has to say: the reason it refused a deletion it could not
    /// return whole (RULING-40), or what a restore could not give back
    /// (RULING-42). A refusal the writer never sees is the same as a silence.
    @State private var restoreOutcome: String?
    /// What a translator's note has to say when it could not be written. A
    /// SIBLING of `restoreOutcome`, not a reuse: that alert is titled "Restore",
    /// and a directive refusal under that heading would read as a deletion.
    @State private var noteOutcome: String?
    /// Injected reader for the share metadata (real OS-backed Mac reader in
    /// production; substitutable in tests/previews).
    private let shareReader: ShareMetadataReading = ICloudShareMetadataReader()
    @Environment(UserPreferences.self) private var userPreferences
    /// The app's one session per project: this window BORROWS its project's
    /// session — `load()` acquires, the window-ending `.onDisappear` releases —
    /// so a second window never runs `DocumentStore.open` twice. It is a WINDOW
    /// borrow, so the registry announces the project to MCP while a window is
    /// open on it.
    @Environment(ProjectSessionRegistry.self) private var sessions
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
                    SaveFlashOverlay(isShowing: $flashes.showingSave)
                }
                .overlay(alignment: .top) {
                    SaveFlashOverlay(isShowing: $flashes.showingCompiler,
                                     label: flashes.compilerLabel,
                                     systemImage: "text.magnifyingglass")
                }
                .overlay(alignment: .top) {
                    if let title = flashes.mcpBanner.title {
                        MCPNoteBanner(
                            title: title,
                            count: flashes.mcpBanner.count,
                            onShow: { handleShowLatestMCPNote() },
                            onDismiss: { flashes.mcpBanner.dismiss() }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: flashes.mcpBanner.title)
                .navigationTitle(store.manifest.title)
                .onChange(of: activeSheet) { _, presented in
                    // A presentation is the one moment every sheet has in
                    // common, so it is where a stale hand-off dies.
                    if presented != nil {
                        describeFirstReaderRequested = false
                        presentedSheet = presented
                    }
                }
                .sheet(item: $activeSheet, onDismiss: openFirstReaderIfRequested) { sheet in
                    switch sheet {
                    case .projectSettings:
                        ProjectSettingsSheet(
                            store: store,
                            onDescribeFirstReader: { describeFirstReaderRequested = true })
                    case .claudeDesktop:
                        HelpClaudeDesktopSheet()
                    case .translatorsNote(let target):
                        TranslatorsNoteSheet(
                            target: target,
                            onCommit: { instruction, home in
                                activeSheet = nil
                                Task { @MainActor in
                                    if let refusal = await TranslatorsNote.commit(
                                        instruction, target: target, home: home,
                                        store: store, world: declaredWorld) {
                                        noteOutcome = refusal
                                    }
                                }
                            },
                            onCancel: { activeSheet = nil })
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
                                await CheckpointFlashDecision.labelled(
                                    label, projectURL: projectURL,
                                    activeDocId: activeDocId, allDocIds: allDocIds,
                                    device: _checkpointDeviceId,
                                    session: _checkpointSessionId,
                                    activeDocument: activeDoc,
                                    posture: { await documentStore.settledPosture(forDocId: $0) },
                                    flash: { showSaveFlash() })
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
        .frame(minWidth: ProjectWindow.windowFloor,
               minHeight: ProjectWindow.windowHeightFloor)
        .modifier(ContainerWidthReporter(onWidth: noteContainerWidth))
        .modifier(TopChromeModifier(
            projectURL: url,
            persona: persona,
            isNoChromeOn: isNoChromeOn,
            onSelectPersona: Self.postPersona))
        .background(WindowAccessor(window: $window))
        // Signed op log P2b: a device asking to be let into this book. Mounted on
        // the whole window, because the question is the PROJECT's and arrives in
        // any persona, loaded or not — the modifier's own guards decide.
        .modifier(AdmissionModifier(
            projectURL: url,
            projectTitle: store?.manifest.title ?? url.lastPathComponent,
            documentStore: documentStore,
            projectStore: store,
            window: $window))
        // **The load's other question** (spec §4.5): somebody who may write some
        // of this book has started a piece in nobody's scope. Its own modifier
        // beside admission's — one subject, one queue — and the two cannot
        // collide: a stranger has no permit to widen.
        .modifier(NewPieceModifier(
            projectURL: url,
            documentStore: documentStore,
            projectStore: store,
            window: $window))
        .task(id: url) { await load() }
        .onDisappear {
            // Scorch the heavy @State on window close. SwiftUI never dismantles a
            // closed `WindowGroup` scene's view graph, but `.onDisappear` DOES fire
            // on close, so we empty the zombie ourselves (see the scene-storage spike
            // note).
            //
            // GUARD on the window actually being gone (ADR 0021 liveness helper): a
            // spurious `.onDisappear` on a still-live window must NOT blank the
            // @State — `body` renders "Loading…" when `store == nil` and
            // `.task(id: url)` won't re-fire for the same url.
            if !MaughamEvent.isLive(window) {
                // The services hold closures over both stores, so a configured session
                // would keep the project graph — and its `claude` subprocess — alive in
                // the husk. The window gives its WINDOW borrow back rather than closing
                // anything: the registry detaches this window
                // (`ProjectSession.detachWindow`, pipeline first) and forgets the project
                // in MCP when no window is left; the LAST release runs the session's
                // close. Nil-ing `lease` here keeps a later `.onDisappear` or `load()`
                // from giving the same borrow back twice.
                if let lease {
                    let sessions = self.sessions
                    Task { await sessions.release(lease) }
                }
                lease = nil
                store = nil
                documentStore = nil
                lastParsedScript = nil
            }
        }
        .modifier(CompilerRunModifier(roster: roster,
                                      persona: persona,
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
            openProjectSettings()
        }
        // **Translator's note** (⌘⌥C): opens on the paragraph under the caret of
        // the ACTIVE manuscript document; with no document it is a quiet no-op.
        .onKeyWindowCommand(.maughamTranslatorsNote, window: window) { _ in
            guard let store, let documentStore,
                  let document = activeDocument(in: store, documentStore: documentStore),
                  let target = TranslatorsNote.target(
                      for: document, docId: activeDocId,
                      manifest: store.manifest, projectURL: store.url)
            else { return }
            activeSheet = .translatorsNote(target)
        }
        .modifier(NoteOutcomeAlert(outcome: $noteOutcome))
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
        // ⌘⌥O: the same write Escape and the canvas's own `selectTheProjectRow`
        // closure make (spec §4.1) — a second door onto it, not a second write.
        .onKeyWindowCommand(.maughamSelectProjectRow, window: window) { _ in
            selectedSubject = .project
        }
        // ⌘⌥R's new meaning: open the tree's own Research section if the
        // writer had closed it. Refused while the find overlay covers the
        // column — the overlay is the tree's replacement, not its sibling,
        // and `BinderTreeSections` isn't even mounted underneath it.
        .onKeyWindowCommand(.maughamRevealResearchSection, window: window) { _ in
            guard !treeFindActive else { return }
            treeState.researchSectionExpanded = true
            // The header lands on screen too — expanding a section scrolled far
            // off-screen makes it TRUE without making it VISIBLE.
            treeState.scrollRequest = .researchHeader
        }
        // ⌘⌥P's twin, for the Palette section.
        .onKeyWindowCommand(.maughamRevealPaletteSection, window: window) { _ in
            guard !treeFindActive else { return }
            treeState.paletteSectionExpanded = true
            treeState.scrollRequest = .paletteHeader
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
            // document: the EditorCoordinator only delivers `onMetricsChanged` while
            // a document is bound, so it can't clear them on deselection.
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
            assistant: assistant,
            mcpBanner: flashes.mcpBanner,
            treeState: treeState))
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
        // Denver's travel rule: a double-click on any tree row in Plan takes the
        // writer to Author, on that row's subject. The rule is in
        // `TreeTravel.swift`; THIS LINE is what makes it reachable (this body has
        // no expression budget — the Release type-check ceiling).
        .modifier(TreeTravelModifier(window: window,
                                     persona: $persona,
                                     detailSegment: $detailSegment,
                                     selectedSubject: $selectedSubject,
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
            SyntaxHelpSheet(format: currentSyntaxHelpFormat)
        }
        // Read the iCloud share snapshot once per project URL and again on app
        // re-activation, off the main actor's critical path; cached in @State and
        // threaded one-way to the editor and the pill. Never polled / per-render.
        .task(id: url) { await readShareSnapshot() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await readShareSnapshot() }
        }
        // Mirror posture + appearance into the EditorControl model (ADR 0017).
        .modifier(EditorControlMirrorModifier(
            membrane: editorMembrane,
            posture: editorPosture,
            effectiveTypography: effectiveTypography,
            editorControl: $editorControl))
        .modifier(TranslationReviewModifier(
            window: window,
            projectURL: url,
            activeDocId: activeDocId,
            selectedSubject: $selectedSubject,
            documentStore: documentStore,
            editorControl: $editorControl))
        .modifier(PaletteWallModifier(
            paletteWall: $paletteWall,
            showInspector: $showInspector,
            selectedPaletteCardId: $selectedPaletteCardId,
            selectedSubject: $selectedSubject,
            persona: persona))
        // A research subject arriving while the canvas holds the centre reveals
        // the column that previews it. Load-bearing line: deleting it leaves every
        // token in the modifier present and every decision test green, while a
        // research row in Plan's tree puts nothing anywhere.
        .modifier(ResearchRevealModifier(persona: persona,
                                         selectedSubject: $selectedSubject,
                                         showInspector: $showInspector,
                                         detailSegment: $detailSegment))
        // The compiled book the Publish centre draws, kept current by a compile
        // finishing, a window opening and an arrival into Publish. Load-bearing
        // line: deleting it leaves every decision test green, while a compile
        // never reaches the centre column.
        .modifier(PublishPreviewModifier(
            projectURL: url, window: window, persona: persona,
            centre: publishCentre))
        .modifier(CanvasPromotionModifier(window: window, store: store,
                                          model: canvasModel, persona: persona))
        // The writer's notice that Claude added cards to their canvas, and the
        // way to go and look. Load-bearing line: deleting it leaves every token in
        // the modifier present and every test green.
        .modifier(CanvasClaudeArrivalModifier(url: url, window: window,
                                              model: canvasModel,
                                              persona: $persona,
                                              showInspector: $showInspector,
                                              detailSegment: $detailSegment,
                                              documentStore: documentStore))
        // ⌘\ on the canvas collapses both side columns (spec §8A.3). Load-bearing
        // line: deleting it leaves every decision test green, while ⌘\ on the
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
    /// A named `static func` rather than an inline closure: `body` is at the
    /// type-checker ceiling, and `static` keeps it from capturing `self`.
    private static func postPersona(_ next: Persona) {
        MaughamEvent.post(.maughamSetPersona,
                          to: .keyWindow,
                          payload: [MaughamEvent.personaKey: next.rawValue])
    }

    /// Reads the share metadata for this project off the main actor and caches
    /// it. Idempotent; safe to call repeatedly.
    private func readShareSnapshot() async {
        let target = url
        let reader = shareReader
        let meta = await Task.detached(priority: .utility) {
            reader.read(for: target)
        }.value
        shareSnapshot = meta
    }

    /// The manuscript document the tree names, when it names one — the
    /// document the editor is FOR. `nil` for the project, a group, research, or
    /// nothing, none of which has text to lock.
    private var selectedManuscriptDocId: String? {
        guard let store, let id = activeItemID,
              let item = TreeWalk.find(id: id, in: store.manifest.structure),
              item.type == .document else { return nil }
        return id
    }

    /// **The editor's membrane, asked of the posture.** The DRAWING accessor
    /// (controller ruling I): reading it observes `postureEpoch`, so a demotion or a promotion
    /// arriving mid-session re-mirrors with no reopen. The rule itself is
    /// `EditorControlMirror.membrane`, pinned without a window.
    private var editorMembrane: EditorControlMirror.Membrane {
        EditorControlMirror.membrane(
            posture: editorPosture,
            manualReview: isReviewModeOn,
            shareIsReadOnly: Self.shareIsReadOnly(shareSnapshot))
    }

    /// The drawing posture of the manuscript document in the editor, nil where
    /// none is — the membrane's input and the margin card's, mirrored to
    /// `EditorControl.posture`.
    private var editorPosture: Posture? {
        selectedManuscriptDocId.flatMap { id in documentStore?.posture(forDocId: id) }
    }

    /// **The drawing posture of any document this window names** — for a
    /// surface about a piece other than the editor's (the inspectors' pass
    /// ladders, the board's chips). Observes `postureEpoch`. `settling` — the
    /// reviewer row alone — where there is no store or no document: nothing is
    /// offered that must not be.
    private func postureDrawn(forDocId docId: String?) -> Posture {
        guard let docId, let documentStore else { return .settling }
        return documentStore.posture(forDocId: docId)
    }

    /// The standing line over the editor, when there is a reason to name
    /// (`PostureStandingLine.line`), for the document the centre column is
    /// actually showing — never over the canvas, the altitude view, a research
    /// subject or the palette wall.
    private var postureStandingLine: PostureStandingLine.Line? {
        guard let store, let documentStore, let id = selectedManuscriptDocId,
              Self.showsStatusFooter(
                persona: persona, subject: selectedSubject,
                showsPaletteWall: paletteWall.showsWall,
                structure: store.manifest.structure),
              let item = TreeWalk.find(id: id, in: store.manifest.structure)
        else { return nil }
        return PostureStandingLine.line(
            for: documentStore.posture(forDocId: id), title: item.title, docId: id,
            ownLinesKeptInHistory:
                documentStore.document(forDocId: id)?.ownLinesKeptInHistory ?? 0)
    }

    /// The typography the editor actually uses — manifest override else user
    /// default. Mirrors the value EditorHost passes to EditorSurface, so the
    /// control model and the prop path agree.
    private var effectiveTypography: TypographySettings {
        guard let store else { return userPreferences.typography }
        return ProjectStore.effectiveTypography(
            override: store.manifest.typography,
            userDefault: userPreferences.typography)
    }

    /// **True when iCloud grants this user READ-ONLY access to the share** —
    /// an OS-level lock that claims no role. Such a user cannot write into the
    /// folder at all, not even an annotation op, so the editor locks and
    /// `ViewOnlyShareNotice` asks for edit access rather than letting a comment
    /// fail silently. Only an explicit `canWrite == false` locks: an unresolved
    /// grant (`nil`) or an unshared project never does.
    nonisolated static func shareIsReadOnly(_ snapshot: ShareMetadata?) -> Bool {
        snapshot?.isShared == true && snapshot?.canWrite == false
    }

    private var preferredColorScheme: ColorScheme? {
        switch userPreferences.theme {
        case .followSystem: return nil
        case .dark:         return .dark
        case .light, .sepia: return .light
        }
    }

    /// The persona bar, the top banners (software-update + backups-paused), and
    /// the focused project URL, pulled off `body` for the Release type-check
    /// ceiling.
    ///
    /// The persona bar is a WINDOW TOOLBAR item, not part of the safe-area
    /// strip: a permanently non-zero top safe-area inset outside a
    /// `NavigationSplitView` occludes the top of every column (2026-07-25
    /// smoke, defect A). The two banners keep the inset because they are
    /// zero-height except in the rare states that raise them.
    ///
    /// `⌘\` focus mode hides the whole window toolbar rather than swapping the
    /// item for an empty one: an empty `ToolbarItem` keeps the taller unified
    /// titlebar, the exact chrome `⌘\` exists to remove. `PersonaBar.isVisible`
    /// stays the single predicate.
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
    /// restores the pane's prior visibility exactly (no stuck-hidden
    /// inspector). A ⌘⌥N that sets `showInspector = true` while the wall is
    /// open wins. Keyed on the wall's own flag — see
    /// `PaletteWallState.applyPaletteWallChange`.
    ///
    /// **The subject-change close lives here too**: "Esc or any subject change
    /// closes it" is the door's own contract (Esc is `PaletteWallCentre.onClose`),
    /// and every close must run through the SAME `applyPaletteWallChange`, or the
    /// inspector stash restores twice or not at all depending on which
    /// `onChange` wins.
    ///
    /// **Internal because `PaletteWallDoorTests` mounts this exact modifier**:
    /// what can fail about an `onChange` is whether it fires at all, so a test
    /// re-creating the observer would test its own copy.
    struct PaletteWallModifier: ViewModifier {
        /// The wall's whole window state (`PaletteWallState`). The travel token is
        /// consumed below, in the same handler that closes the wall and after it,
        /// so nothing depends on which modifier SwiftUI runs first.
        @Binding var paletteWall: PaletteWallState
        @Binding var showInspector: Bool
        @Binding var selectedPaletteCardId: String?
        @Binding var selectedSubject: BinderSubject?
        /// The window's working mode — watched, never written. See
        /// `PaletteWallState.closePaletteWallOnPersonaChange`.
        let persona: Persona

        func body(content: Content) -> some View {
            content
                .onChange(of: paletteWall.showsWall) { old, new in
                    paletteWall.applyPaletteWallChange(
                        from: old, to: new,
                        showInspector: &showInspector,
                        selectedPaletteCardId: &selectedPaletteCardId)
                }
                .onChange(of: selectedSubject) { _, _ in
                    if paletteWall.showsWall { paletteWall.showsWall = false }
                }
                // **The wall belongs to the persona it was opened in** — here rather than
                // at the three sites that write `persona`. **The travel arrives second**:
                // the close is unconditional and the travel asks for a wall on the far
                // side of it. Swap them and the wall opens and is immediately shut.
                .onChange(of: persona) { _, _ in
                    paletteWall.closePaletteWallOnPersonaChange()
                    paletteWall.applyWallTravelOnPersonaChange()
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
        /// `ManuscriptNavigation` — a navigation to a manuscript document moves the
        /// writer to Author when the persona they are in would not show it
        /// (Denver, 2026-08-02). Closing find moves nobody.
        @Binding var persona: Persona
        /// What ⌘⌥Z has to say when it cannot restore a deletion whole
        /// (RULING-40), or when a restore gave back less than was deleted
        /// (RULING-42).
        @Binding var restoreOutcome: String?
        /// **The studied pin**, for the ⌘⌥-letter handler alone: a keystroke
        /// naming a pane is an act, and an act ends a study even when the pane
        /// it names is the one already selected.
        let assistant: AssistantColumnModel
        let mcpBanner: MCPBannerModel
        /// The tree's disclosure/selection state, for the find-match handler's
        /// scroll request. An `@Observable` reference type, so a plain `let`
        /// reaches the same object `ProjectWindow` owns.
        let treeState: BinderTreeSectionsState

        func body(content: Content) -> some View {
            content
                .onKeyWindowCommand(.maughamSetDetailSegment, window: window) { note in
                    guard let raw = note.userInfo?[MaughamEvent.detailSegmentKey] as? String,
                          let seg = DetailSegment(rawValue: raw) else { return }
                    ProjectWindow.selectDetailSegment(
                        seg,
                        showInspector: $showInspector,
                        detailSegment: $detailSegment,
                        assistant: assistant)
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
                // intended.** The stats window is key and this window must move; taking
                // it to the document while leaving its persona on Plan would draw a
                // manuscript editor under a persona whose centre is the board — the
                // state Denver ruled out. Two windows on ONE project both move;
                // `persona` is per-project `UIState`, shared last-writer-wins by design.
                .onProjectEvent(.maughamNavigateToDocument, url: url, window: window) { note in
                    // `store != nil` rather than a binding: the navigation moves window
                    // state and reads none of the store's.
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
                // **⌘⌥F opens the overlay and moves nothing else.** The overlay is the
                // left column while it is up, in every persona. Touching nothing but
                // this flag is what keeps Denver's 2026-08-02 footer ruling true: the
                // footer follows the DOCUMENT in the centre column, and opening find
                // does not touch the centre column.
                .onKeyWindowCommand(.maughamFindInProject, window: window) { _ in
                    treeFindActive = true
                }
                // **The one way down**, reached by both the ✕ and Escape —
                // `ProjectSearchView.close()` is their single call site and this is its
                // only receiver, so the two cannot disagree. **Closing find moves
                // nothing**: the overlay was covering a column that is still there, so
                // dismissing it reveals that column.
                .onKeyWindowCommand(.maughamCloseFind, window: window) { _ in
                    ProjectWindow.applyCloseFind(treeFindActive: &treeFindActive,
                                                 store: store)
                }
                // **A match click writes the SUBJECT**, and nothing else: find does not
                // take the centre column, so `researchSubjectPlacement` routes a research
                // subject the way every research selection is routed.
                // **The full arrival posture, both arms.** A research match gets
                // `openResearchItem`'s shape — `reveal`, then the scroll request from what
                // it returned; the tree's own mount consumes the pending scroll once
                // Escape hands the column back. A manuscript match scrolls straight to its
                // own tag. The overlay stays up either way — no `applyCloseFind` here —
                // and the editor's text scroll is `EditorCoordinator`'s independent
                // observer, not this handler's.
                .onKeyWindowCommand(.maughamFindMatchSelected, window: window) { note in
                    guard let store,
                          let match = note.userInfo?["match"] as? SearchMatch,
                          let subject = ProjectWindow.matchSubject(match, in: store)
                    else { return }
                    selectedSubject = subject
                    treeState.scrollRequest = ProjectWindow.findMatchScrollTarget(
                        for: subject, store: store, treeState: treeState)
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
                // The File menu's enabled state (ruling X), published by the modifier
                // that receives the three items — and only where the project shows the
                // pieces pane.
                .focusedSceneValue(\.mayStartAPiece, StartAPieceDoor.published(store: store))
                .onKeyWindowCommand(.maughamAddLoosePiece, window: window) { _ in
                    guard let store, store.manifest.type.holdsPieces else { return }
                    Task {
                        guard await StartAPieceDoor.admits(store: store) else { return }
                        let piece = try? await store.addLoosePiece(
                            title: "Untitled Piece", format: .markdown)
                        if let piece {
                            selectedSubject = .item(piece.id)
                            pendingPieceRenameId = piece.id
                        }
                    }
                }
                .onKeyWindowCommand(.maughamAddScreenplayPiece, window: window) { _ in
                    guard let store, store.manifest.type.holdsPieces else { return }
                    Task {
                        guard await StartAPieceDoor.admits(store: store) else { return }
                        let piece = try? await store.addLoosePiece(
                            title: "Untitled Screenplay", format: .fountain)
                        if let piece {
                            selectedSubject = .item(piece.id)
                            pendingPieceRenameId = piece.id
                        }
                    }
                }
                .onKeyWindowCommand(.maughamLinkProject, window: window) { _ in
                    guard let store, store.manifest.type.holdsPieces else { return }
                    Task {
                        guard await StartAPieceDoor.admits(store: store) else { return }
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
                }
                .onKeyWindowCommand(.maughamPromotePiece, window: window) { note in
                    guard let store, store.manifest.type.holdsPieces,
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

    // `TreePane` is the one home of the binder's document-home rule; do not
    // add a second spelling here — a dead copy of a load-bearing rule is a
    // copy waiting to be called (the 2026-07-02 screenplay navigate bug).

    /// The help the sheet opens on: the open document's format, so a
    /// screenplay piece in a Collection opens on Fountain.
    private var currentSyntaxHelpFormat: DocumentFormat {
        guard let store else { return .markdown }
        let activePath = activeItemID
            .flatMap { TreeWalk.find(id: $0, in: store.manifest.structure) }?
            .path
        return Self.syntaxHelpFormat(type: store.manifest.type, activePath: activePath)
    }

    /// The format of the document at `activePath`; with nothing open, the
    /// project kind's primary format.
    static func syntaxHelpFormat(type: ProjectType, activePath: String?) -> DocumentFormat {
        guard let activePath else { return type.primaryFormat }
        return DocumentFormat.ofManuscript(path: activePath)
    }

    // MARK: - Column builders

    /// Which binder shell the left column mounts.
    ///
    /// **One rule, named, because it decides which surfaces a project type has
    /// at all.** `ProjectSubjectReachabilityTests` reaches the same surface
    /// production reaches through it, so the census cannot drift from what it
    /// audits; a third shell is a third case, and the census's `switch` stops
    /// compiling until it is enumerated there too.
    ///
    /// The shell is only half the address: which TREE it puts up is
    /// `TreePane(for:)`, where a screenplay diverges to the Scenes navigator.
    enum BinderShell {
        /// `BinderPaneToggle` — every non-collection type. Its tree is
        /// `BinderView`; a screenplay puts up `SceneNavigatorPane` instead.
        case standard
        /// `CollectionBinderPaneToggle` — pieces are flat and have their own
        /// pane, `CollectionPiecesPane`.
        case collection

        static func shell(for type: ProjectType) -> BinderShell {
            type.holdsPieces ? .collection : .standard
        }
    }

    /// The left column, plus **the second producer of `lastParsedScript`**.
    ///
    /// `.maughamScriptDidUpdate` — the only other producer — comes from a
    /// mounted `EditorCoordinator`, and Plan mounts none, so a screenplay's
    /// navigator would be told its script had no scenes. `ScreenplayScriptSource`
    /// derives it from the op log, and its `needsDerivation` orders the two
    /// producers — see that type for why this is a producer rather than a
    /// second value (tripwire 6) and how it satisfies tripwires 4 and 20.
    ///
    /// **Keyed on the predicate**, so the task re-runs exactly when a surface
    /// that lists sluglines appears with nothing to list. The `nil` re-check
    /// inside is not redundant: the derive is a suspension point, and an editor
    /// that mounted and posted across it must not be overwritten by the older
    /// op-log parse.
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
                onOpenPaletteWall: { openPaletteWall() },
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
                onOpenPaletteWall: { openPaletteWall() },
                // **One sink for both restore paths.** ⌘⌥Z and the
                // disclosure's own Restore say the same kind of thing
                // (RULING-40's refusal, RULING-42's shortfall), and only this
                // alert is mounted unconditionally, so only it can be shown by
                // a restore that empties the trash and takes the rows with it.
                onRestoreOutcome: { restoreOutcome = $0 })
        }
    }

    /// The Palette section's "Open Wall" door, from either tree shell. The
    /// decision and every state write are `pressPaletteWallDoor`'s (so a test
    /// drives production's own function rather than a copy of it); what stays
    /// here is the `UIState` write, which needs the document store this view
    /// owns.
    private func openPaletteWall() {
        guard let change = Self.pressPaletteWallDoor(
            persona: &persona,
            detailSegment: &detailSegment,
            paletteWall: &paletteWall,
            memory: documentStore?.uiState.personaMemory ?? .empty)
        else { return }
        documentStore?.updateUIState {
            $0.persona = change.persona
            $0.personaMemory = change.memory
        }
    }

    @ViewBuilder
    private func contentColumn(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        // **The centre column, mounted ONCE, here** — the content column's root,
        // so the route switch beneath it (and with it `EditorHost` and the
        // canvas) keeps its identity. See `CentreColumn`.
        CentreColumn(
            store: store, documentStore: documentStore,
            canvasModel: canvasModel, editorControl: editorControl,
            publishCentre: publishCentre, designer: designer,
            declaredWorld: declaredWorld, window: window,
            persona: persona, researchPreviewVisible: researchPreviewVisible,
            selectedSubject: $selectedSubject,
            showsPaletteWall: $paletteWall.showsWall,
            selectedPaletteCardId: $selectedPaletteCardId,
            outlineLayout: $outlineLayout,
            showInspector: $showInspector,
            detailSegment: $detailSegment,
            annotationScopeRequest: $annotationScopeRequest,
            metrics: $metrics,
            currentElement: $currentElement,
            recordActivePass: { recordActivePass(forPiece: $0, passId: $1) },
            runRoundWhenPieceOpens: { runRoundWhenPieceOpens(pieceId: $0) },
            posture: { postureDrawn(forDocId: $0) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 6) {
                    if PublishStarter.isInitialized(in: store.url) {
                        PublishStatusPill(
                            projectID: ProjectIdentifier.id(for: store.url),
                            projectURL: store.url)
                    }
                    SharingStatusPill(snapshot: shareSnapshot)
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
                // **Applied FIRST of the three top insets, which puts it nearest the
                // prose**: each `safeAreaInset` sits outside what it wraps. So the
                // read-only trap is outermost, the review banner under it, and the
                // strip — a running head belonging to the page — directly over the
                // writing; the two banners are notices about the WINDOW's posture.
                if let line = intentStripLine {
                    IntentStrip(line: line, mayTrailDraft: intentStripMayTrailDraft)
                }
            }
            .safeAreaInset(edge: .top) {
                // **Why the words are not hers** — the posture's own reason, one
                // sentence, over the editor. The manual ⌘⌥⇧R review keeps its own pill,
                // which names no role: a role is the permit's, said in the standing line.
                VStack(spacing: 0) {
                    if let line = postureStandingLine {
                        PostureStandingLineView(
                            line: line, documentStore: documentStore)
                    }
                    if isReviewModeOn {
                        ReviewModeIndicator(
                            collaboratorName: userPreferences.collaboratorDisplayName)
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                // Read-only trap: a user on a VIEW-ONLY iCloud share cannot
                // append annotation ops at all. Surface that loudly rather than
                // letting a comment attempt fail silently.
                if Self.shareIsReadOnly(shareSnapshot) {
                    ViewOnlyShareNotice()
                }
            }
            // The studied reference's BEHAVIOUR — Escape, the reveal, and the three
            // dismisses. It inserts no view: the column itself is `RightColumn`'s
            // study arm (spec §3.2). It rides the centre column because that lives
            // as long as the window does — the right column is behind
            // `showInspector` and would take Escape's arbiter registration down
            // every time the writer hid it.
            .modifier(AssistantColumnModifier(
                window: window, isNoChromeOn: isNoChromeOn, persona: persona,
                activeDocId: activeDocId, detailSegment: detailSegment,
                selectedSubject: selectedSubject, showInspector: $showInspector,
                assistant: assistant))
            .navigationSplitViewColumnWidth(
                min: ProjectWindow.centreColumnFloor, ideal: 720)
    }

    /// The intent strip's line, or nil for no strip (M2 §6.1).
    ///
    /// **`EditorStatusFooter`'s twin, and gated the same way**: Author only,
    /// gone under ⌘\. The decision is
    /// `IntentStrip.line(store:docId:persona:isNoChromeOn:)` so a test can ask
    /// it over the product of its inputs.
    ///
    /// Freshness: while the statement is open in a pane, its live `Document`
    /// makes a change invalidate this body with no event and no poll; a CLOSED
    /// statement's text comes from `@ObservationIgnored` `derivedCache` and
    /// lands on the next body pass. See `IntentStrip.line` for the boundary.
    ///
    /// **`activeDocId`'s no-selection sentinel is correct here** — no document
    /// means no document-scope intent, so the resolution falls to the project's.
    ///
    /// **One divergence is known and accepted**: clicking the strip posts a bare
    /// `postDetailSegment(.intent)`, and `StatementPane.effectiveScope` never
    /// falls back — so a chapter with no intent shows the *project's* line and
    /// opens the *chapter's* empty editor. Fixing it needs Open-sets-scope
    /// machinery (the reverted M1A work, `docs/history/canvas.md`).
    /// `IntentStripTests` pins the divergence.
    private var intentStripLine: String? {
        guard let store else { return nil }
        return IntentStrip.line(
            store: store, docId: activeDocId,
            persona: persona, isNoChromeOn: isNoChromeOn)
    }

    /// Whether the strip carries its quiet mark (M3-P3 §7).
    ///
    /// **Read beside the line and only where the line is** — inside the
    /// `if let line` that mounts the strip, so a persona with no strip reads no
    /// run record. The decision is `IntentDrift.mayTrailDraft`, testable over
    /// its inputs; the words are the view's own constant (ADR 0027 §1).
    ///
    /// Freshness is `DiagnosticsStore`'s observation: `lastRun(docId:)` reads
    /// an observed property, so a finished or cancelled run invalidates this
    /// body with no event and no poll. The statement half inherits
    /// `intentStripLine`'s boundary exactly.
    private var intentStripMayTrailDraft: Bool {
        guard let store else { return false }
        return IntentDrift.mayTrailDraft(
            store: store, docId: activeDocId,
            lastRun: compiler.diagnostics?.lastRun(docId: activeDocId))
    }

    private var shouldShowStatusFooter: Bool {
        guard userPreferences.goalIndicatorsVisible else { return false }
        // Plan is deliberately absent — the footer reports manuscript metrics,
        // and readiness stays silent about the canvas (umbrella §7, §9).
        // **Denver's 2026-08-02 find ruling holds by construction**: find is an
        // overlay of the left column and does not touch the centre, so it
        // cannot take the footer away
        // (`test_openingTheOverlayCannotTakeTheStatusFooterAway`).
        guard Self.showsStatusFooter(
            persona: persona,
            subject: selectedSubject,
            showsPaletteWall: paletteWall.showsWall,
            structure: store?.manifest.structure ?? []) else { return false }
        if isNoChromeOn { return false }
        return true
    }

    /// **Does the centre column hold a manuscript document?** — asked of the
    /// persona, and then of what the writer has actually put in there. The
    /// footer follows the DOCUMENT in the centre and never the shape of the left
    /// column (Denver's 2026-08-02 ruling). `Persona.showsManuscriptDocuments`
    /// rather than `!centresTheCanvas`: the same value, and this is the
    /// question being asked.
    ///
    /// The footer's four readings — a goal capsule, the live session words,
    /// the `¶id` under the cursor and the current element — are all about a
    /// manuscript document, so each clause refuses where the centre holds none:
    /// - the palette wall (`showsPaletteWallCentre`), layered over every other
    ///   arm, so a wall over a research subject still hides the footer;
    /// - a research subject that takes the centre;
    /// - altitude (the project, a group, a dangling id), asked LAST so the
    ///   research clause keeps owning the research subject — no clause here
    ///   restates another.
    ///
    /// The find overlay takes no parameter: opening it writes neither `persona`
    /// nor `subject` nor `showsPaletteWall`
    /// (`TreeFindOverlayTests.test_openingTheOverlayCannotTakeTheStatusFooterAway`).
    /// The published book needs no clause either: `publishCentre` covers only
    /// where `subjectShowsAltitude` already refused, so a clause would be a
    /// parameter that cannot move the result —
    /// `PublishPreviewCentreTests.test_theBookOnlyEverCoversAltitudeSoTheFooterNeedsNoClauseOfItsOwn`
    /// asserts the implication over the whole product.
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

    /// **What Publish puts over the manuscript stack — a round, the design
    /// gate, the book, a notice, or nothing at all**, in that order.
    ///
    /// One function answering both *"does anything cover the centre?"* and
    /// *"what covers it?"*, for `ResearchSubjectPlacement.centreItemID`'s
    /// reason: two gates over one column are two answers free to disagree —
    /// a "nothing published yet" notice over a compiled book, or a book over
    /// the proposal the writer pressed Show on.
    ///
    /// **The book and the gate are PROJECT-level** (Denver, 2026-08-12):
    /// *"a chapter/piece subject in Publish ALWAYS opens the editor — I might
    /// tweak something for layout"*. That is exactly `subjectShowsAltitude`,
    /// composed rather than restated, so no second document-resolution rule
    /// can put a PDF over the chapter a writer is fixing. A research subject in
    /// Publish is `.nothingMoves` and resolves to no document, so it gets the
    /// book (spec §4's "project altitude shown").
    ///
    /// **The round is NOT project-level** (Denver, 2026-09-02): a round is about
    /// one chapter, so it is answered BEFORE the altitude guard and draws over
    /// whatever the centre holds, the editor included (`EditorHost` stays
    /// mounted beneath it); Back or a click-through clears it. The desk's two
    /// Shows clear each other, but the *order* is still stated here so which
    /// surface draws never rests on that invariant alone. The persona guard
    /// applies to every arm.
    static func publishCentre(persona: Persona,
                              subject: BinderSubject?,
                              structure: [StructureItem],
                              preview: PublishPreviewResolution,
                              proposal: DesignProposalStore.Proposal? = nil,
                              round: TranslationRound? = nil)
    -> PublishCentre? {
        guard persona.previewsThePublishedBook else { return nil }
        if let round { return .translationRound(round) }
        guard subjectShowsAltitude(persona: persona, subject: subject,
                                   structure: structure) else { return nil }
        if let proposal { return .designProposal(proposal) }
        switch preview {
        case .ready(let publications):
            // `.ready` is non-empty by construction (the resolver answers
            // `.nothingCompiled` when it finds nothing readable); the ternary makes
            // this switch total without an unreachable arm. `PublishPreviewCentreTests`
            // pins the resolver's half of that invariant.
            return publications.isEmpty
                ? .notice(.neverCompiled)
                : .books(publications)
        case .nothingCompiled:
            return .notice(.neverCompiled)
        case .unreadableCatalog(let reason):
            return .notice(.unreadableCatalog(reason: reason))
        }
    }

    /// **Does Review's centre column show the passes board?** (spec §4 — the
    /// board is Review's project altitude.) Two independent facts, composed
    /// here so no caller can hold one without the other:
    ///
    /// - **Which persona.** `Persona.showsTheReviewBoard`, asked rather than
    ///   spelled — a `== .review` is the equality shape `centresTheCanvas`
    ///   was written to close off.
    /// - **Which subject.** `subjectShowsAltitude`, composed for
    ///   `publishCentre`'s reason: the board is PROJECT-level, and a chapter
    ///   subject in Review opens the chapter. A research subject resolves to no
    ///   document, so it gets the board.
    ///
    /// **`showsStatusFooter` needs no clause for this**: the board only shows
    /// where the footer's altitude clause has already refused.
    /// `ReviewBoardRoutingTests.test_theBoardOnlyEverCoversAltitudeSoTheFooterNeedsNoClauseOfItsOwn`
    /// asserts that implication over the whole product.
    static func reviewCentreShowsBoard(persona: Persona,
                                       subject: BinderSubject?,
                                       structure: [StructureItem]) -> Bool {
        guard persona.showsTheReviewBoard else { return false }
        return subjectShowsAltitude(persona: persona, subject: subject,
                                    structure: structure)
    }

    /// **Does the centre column show the project at altitude rather than a
    /// document?** True for every subject that resolves to no single document —
    /// no subject, the project, a group, and an `.item` that names nothing in
    /// the manifest (or a document with no path) — in a manuscript persona.
    ///
    /// **The complement of `selectionIsDocument`**, the window's one question
    /// about whether a subject is a manuscript document (the one the
    /// `EditorCoordinator`'s metrics turn on); two switches over the same cases
    /// are two answers free to disagree. `persona.showsManuscriptDocuments`
    /// first: altitude is what the manuscript personas show INSTEAD of a
    /// document, never a surface competing with Plan's board.
    ///
    /// **`.research` is deliberately not re-guarded.** `centreRoute` asks
    /// `researchSubjectPlacement` before the editor arm, so wherever this is
    /// reached the research item has already taken the centre, and in Plan this
    /// has already refused on the persona. `ProjectAltitudeCentreTests` asserts
    /// that pair over `Persona.allCases` — a guard here would be a second place
    /// research routing is decided, and the one that never runs goes quietly
    /// wrong.
    static func subjectShowsAltitude(persona: Persona,
                                     subject: BinderSubject?,
                                     structure: [StructureItem]) -> Bool {
        guard persona.showsManuscriptDocuments else { return false }
        return !selectionIsDocument(subject, in: structure)
    }

    /// **What the window is about after a search match is clicked**, as a pure
    /// function, so the routing is drivable without a mounted window; the two
    /// arms differ only in which tree the match's path is looked up in.
    ///
    /// `nil` when the match names a path no longer in the manifest (renamed or
    /// deleted between the search and the click) — a stale result, not a place
    /// to send anyone.
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

    /// **What a find match's subject earns as a scroll target** — pure and
    /// static for `matchSubject`'s reason. A research match reveals whatever
    /// section or fold holds it and scrolls to what `reveal` says is now on
    /// screen (`openResearchItem`'s shape; `nil` for a stale match). A
    /// manuscript or project match's row is never behind anything closable —
    /// `reveal` only opens research furniture — so it scrolls to its own tag.
    static func findMatchScrollTarget(
        for subject: BinderSubject, store: ProjectStore,
        treeState: BinderTreeSectionsState
    ) -> TreeScrollTarget? {
        switch subject {
        case .research(let id):
            return treeState.reveal(id, structure: store.manifest.structure,
                                    research: store.manifest.research,
                                    projectType: store.manifest.type)
                .map(TreeScrollTarget.row)
        case .item, .project:
            return .row(subject)
        }
    }

    /// **Closing the find overlay, whole**, so the handler is a call rather
    /// than a rule and a test can drive the real thing. Two writes that belong
    /// together — the overlay flag and the results it showed; clearing one
    /// without the other leaves a reopened find on the previous search. It
    /// deliberately moves the binder nowhere.
    static func applyCloseFind(treeFindActive: inout Bool, store: ProjectStore?) {
        treeFindActive = false
        store?.clearSearch()
    }

    private var sessionWordsForFooter: Int {
        // Net words added in the currently-active session. `sessionLog` only
        // captures ENDED sessions (30-min idle or quit), so the live delta comes
        // from DocumentStore, which ticks as the user types.
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
    /// sum below. Two spellings of one number let the sum disagree with layout.
    static let binderColumnFloor: CGFloat = 200

    /// What macOS draws AROUND the sidebar: a 200pt sidebar occupies 208 in the
    /// split view (measured — see `DetailColumnWidthTests`). Eight points is the
    /// difference between "the window holds" and "the window silently grows",
    /// so it is part of the sum, not a rounding error to trim.
    static let sidebarInset: CGFloat = 8

    /// The writing column's declared floor, same rule as the binder's.
    static let centreColumnFloor: CGFloat = 480

    /// The window's own declared minimum (`body`'s `.frame(minWidth:)`), and the
    /// container width assumed before anything has been measured.
    static let windowFloor: CGFloat = 980

    /// **The window's declared minimum HEIGHT, and the only thing entitled to
    /// set it.** `body`'s `.frame(minHeight:)`.
    ///
    /// A pane's content growing is a reason to compress or scroll that pane,
    /// never to move this number: `NSHostingView` stamps
    /// `window.contentMinSize`, and a layout minimum rising past it afterwards
    /// makes SwiftUI CENTRE what it cannot compress, pushing the binder tree out
    /// of the top of its column (`TreeScrollStabilityTests`). Named so the
    /// census can cite it (`test_theWindowsMinimumHeightIsProjectWindowsOwnFloor`).
    static let windowHeightFloor: CGFloat = 540

    /// Records the measured container width, but **only when it changes what
    /// the window can afford** — a drag-resize is 60 frames a second, and
    /// almost none of them move the ceiling.
    ///
    /// **Keyed on the CEILING, and deliberately blind to the persisted width.**
    /// A memo is only sound when keyed on something that determines every
    /// consumer, and the stored container has two: `effectiveDetailColumnWidth`
    /// (at the current width) and `draggableDetailCeiling` (at the range's upper
    /// bound). Keyed on the first alone, it never recorded for an affordable
    /// width and starved the drag ceiling for the life of every window.
    /// `test_aFreshProjectCanDragPastTheUnmeasuredFallback` is the regression,
    /// and goes through this guard. The persisted width is not a parameter, so
    /// that shape cannot be spelled here again.
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
    /// floor, what is left for the right column is less than the most a writer
    /// may wish for. **The number is not written here** — the code computes it
    /// from the constants and
    /// `test_theAffordabilitySumGivesTheWindowWhatItNeedsAndTheWriterTheRest`
    /// asserts it the same way (a worked example in prose is the unmaintainable
    /// count). AppKit does not squeeze anything over a shortfall; it silently
    /// GROWS the window past its declared minimum.
    ///
    /// **The asymmetry is the point.** This reduces what is DISPLAYED and never
    /// touches what is STORED: a wish made on a large display comes back the
    /// moment the window can afford it.
    ///
    /// `containerWidth` is nil until measured, and the answer for nil is
    /// deliberately the CONSERVATIVE one (the window's own floor): a generous
    /// first guess would grow the window, and a grown window does not shrink
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

    /// **Where a drag of the right column's handle lands.** Pure, so a test can
    /// drive it without gesture machinery, and holding all three rules:
    ///
    /// 1. **The sign.** The handle is on the column's LEADING edge, so a
    ///    leftward drag — a negative translation — makes the column WIDER.
    /// 2. **The column's own range** (`UIState.clampedDetailColumnWidth`).
    /// 3. **What this window can afford** — on a narrow window the gesture
    ///    stops where the column stops moving instead of banking a wider number
    ///    that would reappear on a bigger display.
    static func draggedDetailColumnWidth(startWidth: Double,
                                         translation: Double,
                                         containerWidth: Double?) -> Double {
        min(UIState.clampedDetailColumnWidth(startWidth - translation),
            draggableDetailCeiling(containerWidth: containerWidth))
    }

    /// **The right column, mounted ONCE, here** — the detail column's root. See
    /// `RightColumn` for the resize handle, the study arm, the inspector arm,
    /// and the one width applied to both the content's frame and the split item.
    ///
    /// **The width is bound HERE, once, and handed down as a value** — the
    /// EFFECTIVE width (`effectiveDetailColumnWidth`), which the column applies
    /// twice. `DetailColumnWidthTests` counts this binding and expects exactly
    /// one; the column writes only the persisted wish, through its binding.
    @ViewBuilder
    private func detailColumn(store: ProjectStore, documentStore: DocumentStore) -> some View {
        let width = Self.effectiveDetailColumnWidth(persisted: detailColumnWidth,
                                                    containerWidth: containerWidth)
        RightColumn(
            store: store, documentStore: documentStore, projectRoot: url,
            canvasModel: canvasModel, editorControl: editorControl,
            publishCentre: publishCentre, assistant: assistant,
            roster: roster, bible: bible, declaredWorld: declaredWorld,
            persona: persona, isNoChromeOn: isNoChromeOn,
            showInspector: showInspector, metrics: metrics,
            width: width, containerWidth: containerWidth,
            detailColumnWidth: $detailColumnWidth,
            selectedSubject: $selectedSubject,
            detailSegment: $detailSegment,
            annotationScopeRequest: $annotationScopeRequest,
            compilerModel: $compilerModel,
            recordActivePass: { recordActivePass(forPiece: $0, passId: $1) },
            openProjectSettings: openProjectSettings,
            openPromotedArtifact: openPromotedArtifact,
            posture: { postureDrawn(forDocId: $0) })
    }

    /// **The right column when there is nothing in it** — and it has to SAY so.
    ///
    /// In a three-column `NavigationSplitView` the DETAIL column is the flexible
    /// trailing one: a column that renders no view does not take no room —
    /// AppKit resolves the CONTENT column on its `ideal` (720) and hands the
    /// remainder to an empty column (Denver's "blank and roughly doubled"
    /// report, in every persona; see the CLAUDE.md Canvas row). Hence a hidden
    /// ARM declaring zero width, rather than anything in `canvasCollapse`.
    ///
    /// **One static, shared with the harness.** `DetailColumnWidthTests` mounts
    /// its own three-column split and calls this, so the two cannot drift.
    static var hiddenDetailColumn: some View {
        Color.clear.navigationSplitViewColumnWidth(0)
    }

    // MARK: - Which column shows what

    /// **The canvas check sits ABOVE the project-type split, in both columns.**
    /// There is ONE canvas per project regardless of type (spec §2); deciding
    /// below the split let the two paths disagree — a Collection writer
    /// selecting a region got the piece inspector (smoke, 2026-07-28).
    ///
    /// Pure and named so a test can be exhaustive over (persona × type).
    /// `CanvasRouteTests` is that test.
    enum InspectorRoute: Equatable {
        case canvas
        /// A Collection's per-piece inspector, which never consults the persona.
        case collectionPiece
        /// `InspectorView` — the selected manuscript document's own inspector.
        case document
    }

    static func inspectorRoute(persona: Persona,
                               projectType: ProjectType) -> InspectorRoute {
        // The predicate, not `== .plan`: a persona NAME here says the region
        // inspector belongs to a persona rather than to the column that draws the
        // board — the equality cost the inspector its reachability from Plan's tree.
        if persona.centresTheCanvas { return .canvas }
        return projectType.holdsPieces ? .collectionPiece : .document
    }

    /// Whether the Palette section's "Open Wall" door travels from this persona
    /// rather than opening the wall where the writer already is.
    ///
    /// **`TreeTravel.treeTravelDestination`, not a second predicate**: the door
    /// is a tree affordance, and "there is somewhere to travel to" has one
    /// answer. Two spellings let the door's tooltip and action disagree;
    /// `PaletteWallDoorTests` pins them to this one.
    static func paletteWallDoorTravels(persona: Persona) -> Bool {
        TreeTravel.treeTravelDestination(persona: persona) != nil
    }

    /// **Pressing the wall's door.** Either the wall opens here, or the writer
    /// travels to where it opens — Denver, 2026-08-12.
    ///
    /// Returns the persona change to persist, or `nil` when nobody moved. The
    /// writes are inout because the two arms write different things; the window
    /// keeps only the `UIState` write.
    ///
    /// **It does NOT open the wall on the travelling arm**, and it writes no
    /// subject: a persona change and a subject change each close the wall, so
    /// either would undo the press. What crosses the switch is the token.
    ///
    /// **A `ProjectWindow` static rather than a `PaletteWallState` method**: it
    /// also writes the PERSONA, and the window is one of the closed set of
    /// persona decision sites (`TripwireGrepTests.personaDecisionSites`).
    @discardableResult
    static func pressPaletteWallDoor(
        persona: inout Persona,
        detailSegment: inout DetailSegment,
        paletteWall: inout PaletteWallState,
        memory: PersonaMemory
    ) -> PersonaModifier.Change? {
        guard let destination = TreeTravel.treeTravelDestination(persona: persona)
        else {
            paletteWall.showsWall = true
            return nil
        }
        paletteWall.travelPending = true
        // The departing position is recorded (as `TreeTravelModifier` and
        // `ManuscriptNavigation.go` do), so ⌘1 brings the writer back to the board.
        let change = PersonaModifier.applyPersonaChange(
            to: destination, from: persona,
            currentSegment: detailSegment, memory: memory)
        persona = change.persona
        detailSegment = change.segment
        return change
    }

    /// Whether the palette wall takes the centre column — `showsPaletteWall`
    /// AND a persona the wall may cover (`Persona.showsPaletteWall`: not Plan,
    /// whose centre is the canvas). Pure and named so `centreRoute` and a test
    /// share one answer.
    static func showsPaletteWallCentre(showsPaletteWall: Bool, persona: Persona) -> Bool {
        showsPaletteWall && persona.showsPaletteWall
    }

    // MARK: - ⌘\ collapses to the canvas (spec §8A.3)

    /// What `⌘\` must do to the two side columns, as a value.
    ///
    /// **`.doubleColumn`, and the case that looks right is the one that breaks
    /// it.** The canvas is the CONTENT (middle) column, so `.detailOnly` hides
    /// the canvas itself. `.doubleColumn` hides the SIDEBAR, and with
    /// `showInspector` false the right column holds zero width, so the pair
    /// leaves the canvas the whole window. The visibility travels in the payload
    /// so a test has to name the case it expects — "not `.all`" is satisfied by
    /// the trap.
    ///
    /// **`.unchanged` is a real answer**: `⌘\` in the editor must move no column
    /// at all — not even `.all` over a sidebar the writer dragged shut.
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
    /// its inputs (see `inspectorRoute`). **`route` rather than a second "is the
    /// canvas showing" test** — the canvas check lives in one place.
    ///
    /// The stash is both the memory and the "am I already collapsed" flag: an
    /// already-collapsed canvas answers `.unchanged`, or a second apply in the
    /// same pass would stash the `false` the first one wrote and leave the
    /// inspector hidden for good.
    ///
    /// **It never touches the palette wall's stash**: the two folds cannot meet,
    /// because the wall never covers Plan and every persona change closes it
    /// (`closePaletteWallOnPersonaChange`), while a collapse needs
    /// `route == .canvas`. The wall's own conditional restore is what makes
    /// *wall in Author → ⌘1 → ⌘\* end where the writer left it. Tripwire 2
    /// records what the two folds racing in one pass cost.
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
    /// Static and `inout` so the sequence test — collapse, persona switch, come
    /// back, three SwiftUI passes — drives the SAME fold the window does. A test
    /// mirroring the fold would have gone green over the palette-stash bug.
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
        /// The planning canvas, mounted ONCE, in a branch of its own so nothing
        /// else can give the board a second view identity (tripwires 27/30).
        case canvas
        /// A Collection's placeholder for a linked-project reference piece.
        case collectionReference
        /// `manuscriptEditor` — the editor on whatever document the tree names.
        case editor
    }

    static func editorRoute(persona: Persona,
                            projectType: ProjectType,
                            selectedPieceIsReference: Bool) -> EditorRoute {
        // The canvas draws whatever else is selected: a reference piece stays
        // selected across a persona switch, so without this the centre shows the
        // placeholder and the canvas never appears.
        if persona.centresTheCanvas { return .canvas }
        return projectType.holdsPieces && selectedPieceIsReference
            ? .collectionReference : .editor
    }

    /// Pre-order ids of every `.document` node in the structure tree. Single
    /// source of truth shared by ProjectWindow, CheckpointModifier and
    /// RewindModifier.
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

    /// The pieces both canvas pickers offer — the region's and the card's. Ids,
    /// so an association survives a rename (tripwire 22's rule applied to a
    /// reference).
    ///
    /// **Only the pieces a promotion can be ROUTED to**
    /// (`ProjectStore.researchScopeTargets()`), never every `.document`: a
    /// Collection reference piece makes `researchRouting` throw, and this
    /// surface's promise is predictability (spec §6.2).
    ///
    /// **Eager, evaluated by the column body that hands it over — never a
    /// deferred closure.** The `Picker` that consumes it lives in
    /// `RegionInspector.body`, which reads `model.scene` and re-evaluates on
    /// every drag frame; deferring would put an O(documents²) routing walk on
    /// the drag loop (tripwire 30's shape). Eager, it costs one walk per
    /// manifest change.
    static func pieceChoices(in store: ProjectStore) -> [RegionInspector.PieceChoice] {
        store.researchScopeTargets()
            .map { RegionInspector.PieceChoice(id: $0.id, title: $0.title) }
    }

    /// What every item node on the canvas resolves its title, kind glyph and
    /// thumbnail path through (spec §8A.1).
    ///
    /// **Built on `pieceChoices`' terms**: called from a column body that reads
    /// `store.manifest` and does **not** read `canvasModel.scene`, so it is off
    /// the canvas's drag loop. Building it inside `CanvasView` would put a walk
    /// of the research tree on every drag, coast and straighten frame
    /// (tripwire 4). `CanvasItemIndex`'s own doc says why it is not
    /// `ArtifactIndex`.
    static func canvasItemIndex(in store: ProjectStore) -> CanvasItemIndex {
        CanvasItemIndex.over(research: store.manifest.research)
    }

    /// What a dimmed region on the canvas says it already belongs to (§4.2), and
    /// what the region inspector resolves an unofferable binding through.
    ///
    /// **Built on `pieceChoices`' terms** — from a body that reads
    /// `store.manifest` and not `canvasModel.scene`, so off the drag loop
    /// (tripwire 4). `CanvasPieceTitles` carries why it is the whole structure
    /// and not `pieceChoices`' routable subset.
    static func canvasPieceTitles(in store: ProjectStore) -> CanvasPieceTitles {
        CanvasPieceTitles.over(structure: store.manifest.structure)
    }

    /// **Navigate to a research item: make it the window's SUBJECT** — what
    /// every other way of selecting a research row does. `researchSubjectPlacement`
    /// routes it to the centre in Author and Review and beside the board in
    /// Plan; in Publish it is `.nothingMoves`, so the subject falls through to
    /// project level.
    ///
    /// **The tree opens far enough to show the row**: `reveal` opens the
    /// section or piece FOLD that holds the item, plus every group between. It
    /// only ever opens; an id no tree draws opens nothing.
    ///
    /// Reached from a promoted card's **Open**, through `openPromotedArtifact`.
    /// **The reveal is explicit here**: the subject observer covers a subject
    /// that CHANGES, and Open on a card whose item is already the subject
    /// changes nothing, so no observer fires. The two reveals are idempotent
    /// together — same function, same question.
    private func openResearchItem(_ itemId: String) {
        selectedSubject = .research(itemId)
        if let store,
           let revealed = treeState.reveal(itemId, structure: store.manifest.structure,
                                            research: store.manifest.research,
                                            projectType: store.manifest.type) {
            // Arrival is visible, not just true: opening the section/fold makes the
            // row EXIST; scrolling to what `reveal` returned puts it on screen.
            treeState.scrollRequest = .row(revealed)
        }
        Self.revealResearchColumn(persona: persona, subject: selectedSubject,
                                  showInspector: &showInspector,
                                  detailSegment: &detailSegment)
    }

    /// **Open** on a promoted card, region or picture — which can name an
    /// artifact that is not in `research/` at all. A `Statement` id sent to
    /// `openResearchItem` would select a research id no tree holds, so a
    /// statement routes to its pane instead.
    ///
    /// **It does not choose the pane's SCOPE.** `StatementPane` resolves that
    /// from the window's subject, so a document-scoped intent opened here may
    /// land on a different scope's. Driving the subject from Open would move the
    /// writer's open document as a side effect of a button about an artifact;
    /// whether Open may move the subject is an open design question. A
    /// request-the-pane-honours attempt was built and reverted (M1A);
    /// `StatementPaneSelectionDeliveryTests` is the fixture the next attempt
    /// starts from.
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
    /// inputs, and a `switch` over the kind rather than a test for `.intent`: a
    /// fall-through would send the writer to a Research pane that shows them
    /// nothing. Every kind with a pane of its own opens it.
    static func statementPane(forMark itemId: String,
                              in store: ProjectStore) -> DetailSegment? {
        guard let statement = store.manifest.statements.first(where: { $0.id == itemId })
        else { return nil }
        switch statement.kind {
        case .intent: return .intent
        case .visualLanguage: return .visualLanguage
        // Neither has a pane here — same as `.unknown` below.
        case .editionBrief: return nil
        // The ledger has a pane of its own.
        case .lessons: return .lessons
        // She has a pane of her own.
        case .firstReader: return .firstReader
        // A kind a newer build wrote, retained and ignored everywhere else
        // (`Statement.Kind`). There is no pane for it here either.
        case .unknown: return nil
        }
    }

    /// The name a mark shows — a research item's title, or an intent
    /// statement's composed name.
    ///
    /// **One rule, two readers.** The promotion sheet reads `ArtifactIndex`,
    /// built once when it opens; this is the inspector's deferred lookup, so
    /// selecting an unpromoted card walks nothing. They must answer identically
    /// for a statement, so the composing is `ArtifactIndex.statementTitle`'s in
    /// both — pinned by `PromotionStatementMarkTests`.
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
    /// `linkAlreadyPresent`.
    ///
    /// **`PromotionPerformer.writableDestination`'s order, one surface
    /// earlier**: research first, then a statement. Resolving research alone
    /// let the sheet enable Commit for an intent-marked card and the performer
    /// refuse a second later; a preview that cannot see the destination is not
    /// a preview.
    ///
    /// The statement arm reads `statementText(of:)`, never the `.md` (derived
    /// output, tripwire 20) — the same reader the performer dedupes against, so
    /// the sheet's promise and the write cannot disagree. Static and
    /// store-taking so a test can reach it without a window.
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

    // MARK: - The subject boundary

    // **Two properties, one rule.** Everything below that wants a bare
    // `String` takes one of these; nothing else in the window unwraps a
    // `BinderSubject`, so which pane you look at cannot decide what "no
    // document" means.

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

    /// Remember that `piece` was last looked at through `passId` —
    /// `UIState.activePassMemory`'s write half, persisted through
    /// `updateUIState` on the same debounce as every other UI-state write.
    ///
    /// **One copy on purpose**: readers read `documentStore.uiState
    /// .activePassMemory` directly (the store is `@Observable`); a per-window
    /// mirror could only ever disagree with it.
    private func recordActivePass(forPiece piece: String, passId: String) {
        documentStore?.updateUIState { $0.activePassMemory.record(piece: piece, passId: passId) }
    }

    /// Ask for `piece`'s round as soon as the editor has it open — the far
    /// side of `runRequested`'s silent refusal.
    ///
    /// **A deferred delivery site for ⌘R**: the call is the identical one the
    /// key, the cockpit's Run and the cold-start offer make; what this adds is
    /// the wait, because the piece a board chip names has usually never been on
    /// screen. `RunWhenDocumentOpens` owns the bound and its expiry; this says
    /// what "open" means and what a run is. The task is deliberately discarded
    /// — a closed window takes the reason for the round with it.
    ///
    /// **The expiry flashes** (Denver, 2026-08-18) through `showCompilerFlash`,
    /// ⌘R's own capsule, because it is the same keystroke's answer arriving late
    /// and negative.
    private func runRoundWhenPieceOpens(pieceId: String) {
        guard let documentStore else { return }
        RunWhenDocumentOpens.start(
            docId: pieceId,
            isOpen: { [weak documentStore] docId in
                documentStore?.document(forDocId: docId) != nil
            },
            // **A round, said literally** — the board chip arriving late belongs to
            // the round loop by construction, so it names the verb rather than
            // re-deriving it from a persona the writer may have left.
            run: { [compiler] docId in
                compiler.runRequested(docId: docId, kind: .round)
            },
            // `[flash]`, not a bare `showCompilerFlash(…)`: this closure is held for
            // the deferral's whole bound, and capturing `self` would hold the window's
            // stores with it. See `compilerFlash`.
            onTimedOut: { [flash = compilerFlash] in flash.show(.pieceWouldNotOpen) })
    }

    /// Whether the window's subject still names something, and what it becomes
    /// when it does not.
    ///
    /// **One containment question, asked at two moments**: where a freshly
    /// opened window lands given `ui-state.json`, and on every structure change
    /// (`SubjectValidationModifier`). A second spelling would be free to
    /// disagree about the two easy-to-get-wrong cases — `.project`, and a group
    /// taking its children with it ("is the subject still in the structure?",
    /// not "is it the row I deleted?").
    ///
    /// **`.project` is valid precisely because it is in no structure.** A bare
    /// `TreeWalk.contains` fails it and lands the window somewhere *plausible* —
    /// the failure mode nobody reports.
    ///
    /// The four answers are the whole contract:
    ///
    /// | on disk | answer |
    /// |---|---|
    /// | the project flag | `.project` |
    /// | a bare id still in the structure | that item, unchanged |
    /// | a bare id naming a deleted item | `.project` |
    /// | nothing at all | `.project` |
    ///
    /// **Never "the first document"** — Denver's ruling: *the dim must only ever
    /// be entered by a click*. A document subject FILTERS the canvas, so a
    /// restored chapter nobody chose would open Plan onto a dimmed board and
    /// the next sweep would bind a region to it. The accepted trade: a fresh
    /// window in Author opens with no document in the editor.
    ///
    /// Never absent: `.project` is available even for a structure with no
    /// document. A pure function because this is a silent routing decision and
    /// `load()` is unreachable from a test.
    ///
    /// **The `nil` row is the restore's answer, not the sweep's.** The sweep
    /// REPAIRS a subject and does not choose one, so a writer who deselected is
    /// left alone; that guard lives at the sweep's call site
    /// (`SubjectValidationModifier`).
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

        // A project that `holdsPieces` derives isScreenplay from the active
        // piece, not the project. Reference pieces hide the goal indicator.
        let isScreenplay: Bool
        let docWordTarget: Int?
        let docPageTarget: Int?
        if store.manifest.type.holdsPieces {
            if let piece = currentDoc, piece.pieceKind == .reference {
                return .empty  // hidden for references
            }
            (isScreenplay, docWordTarget, docPageTarget) =
                GoalIndicatorState.collectionGoalMeasure(for: currentDoc)
        } else {
            isScreenplay = store.manifest.type.primaryFormat.isScreenplay
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
            pageTarget: store.manifest.type.holdsPieces
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
        flashes.showingSave = true
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            await MainActor.run { flashes.showingSave = false }
        }
    }

    /// ⌘R's acknowledgment — "Checking…" for a press that started a run, "Still
    /// checking…" for one that found a run under way. The pane says the rest.
    /// Through `compilerFlash`, whose generation keeps a double-press honest.
    @MainActor
    private func showCompilerFlash(_ acknowledgment: CompilerOrchestrator.Acknowledgment) {
        compilerFlash.show(acknowledgment)
    }

    /// One finished design round, as a sentence for the log.
    ///
    /// `static` and pure so the `onRunEnded` closure holds nothing: a method
    /// reference would capture `self`, and with it `store`, `documentStore` and
    /// every orchestrator. A staged round says both what it produced and
    /// whether its sample pages compiled, because a sample failure ends the
    /// round CLEAN (spec §6).
    static func designRunRecord(_ summary: DesignerOrchestrator.RunSummary) -> String {
        switch summary.outcome {
        case .staged(let staged):
            if let rejection = staged.rejection {
                return "nothing staged — \(rejection)"
            }
            let proposal = staged.proposalId ?? "(none)"
            let sample: String
            switch staged.sample {
            case .pages(let path, _, _): sample = "sample pages at \(path)"
            case .failed(let error): sample = "sample did not compile: \(error)"
            case nil: sample = "no sample recorded"
            }
            return "proposal \(proposal), \(staged.filesStaged) file(s), \(sample)"
        case .cancelled:
            return "cancelled"
        case .failed(let failure):
            return "failed — \(failure)"
        }
    }

    /// **The flash's own capture surface**, so a caller holding the flash
    /// across a suspension holds THREE bindings rather than the window: a bare
    /// `{ showCompilerFlash(…) }` captures `self`, and with it every store and
    /// orchestrator. `@State` boxes outlive any closure, so this costs nothing
    /// and keeps the flash ONE spelling.
    private var compilerFlash: CompilerFlashSink {
        CompilerFlashSink(
            label: $flashes.compilerLabel,
            generation: $flashes.compilerGeneration,
            showing: $flashes.showingCompiler)
    }

    /// **The one place the Project Settings sheet is opened.** Three controls
    /// ask for it — the ⌘⇧, command, the Inspector's row and the Diagnostics
    /// header's *Define a first reader…*. The stale-request clear lives on the
    /// `activeSheet` change, because two other sheets never come through here.
    private func openProjectSettings() {
        activeSheet = .projectSettings
    }

    /// **Whether a dismissal hands the writer to the first reader's
    /// statement** — pure, so the rule is assertable with no window
    /// (tripwire 33). It takes the sheet that CLOSED, not just the standing
    /// request: `.sheet(item:onDismiss:)` fires for all three of this window's
    /// sheets, and a guard on the request alone sent a translator's-note
    /// dismissal to her statement.
    static func opensFirstReader(
        requested: Bool, dismissed: ProjectActiveSheet?
    ) -> Bool {
        requested && dismissed == .projectSettings
    }

    /// **The right column arriving at a pane** — the one spelling of the three
    /// acts a pane selection performs, called by the `.keyWindow` receiver in
    /// `SessionAndNavigationModifier` and by the Describe… hand-off below.
    ///
    /// **The keystroke ends a study, even when it names the pane already
    /// selected** (Denver's ruling): a studied reference stands IN PLACE OF the
    /// pane picker, so ⌘⌥E is what a writer presses to get the shelf back. The
    /// picker's own no-op snap is NOT a keystroke and keeps the study
    /// (`AssistantColumnModifier.paneChangeEndsTheStudy`).
    static func selectDetailSegment(
        _ seg: DetailSegment,
        showInspector: Binding<Bool>,
        detailSegment: Binding<DetailSegment>,
        assistant: AssistantColumnModel
    ) {
        showInspector.wrappedValue = true     // ensure pane is visible
        assistant.dismiss()
        detailSegment.wrappedValue = seg
    }

    /// Hand the writer to the first reader's statement, once Project Settings
    /// has actually closed — see `describeFirstReaderRequested` for why the
    /// act cannot happen while the sheet is up, and why it is a direct write
    /// rather than a post.
    private func openFirstReaderIfRequested() {
        let dismissed = presentedSheet
        let opens = Self.opensFirstReader(
            requested: describeFirstReaderRequested, dismissed: dismissed)
        describeFirstReaderRequested = false
        presentedSheet = nil
        guard opens else { return }
        Self.selectDetailSegment(
            .firstReader,
            showInspector: $showInspector,
            detailSegment: $detailSegment,
            assistant: assistant)
    }

    /// **Show**, on the banner that says Claude added a research note: the
    /// note becomes the window's subject, so the banner works in every
    /// persona, Plan included. **It reveals the column too**, for
    /// `openResearchItem`'s reason: a second note arriving while the writer
    /// looks at the first leaves the subject unchanged, and a banner whose
    /// button does nothing is worse than no banner.
    private func handleShowLatestMCPNote() {
        guard let id = flashes.mcpBanner.latestId else { return }
        selectedSubject = .research(id)
        // The tree opens far enough to draw the note's row — `openResearchItem`
        // carries why this is a call here and not an observer of the subject.
        if let store,
           let revealed = treeState.reveal(id, structure: store.manifest.structure,
                                            research: store.manifest.research,
                                            projectType: store.manifest.type) {
            // And it scrolls onto screen, `openResearchItem`'s twin write.
            treeState.scrollRequest = .row(revealed)
        }
        Self.revealResearchColumn(persona: persona, subject: selectedSubject,
                                  showInspector: &showInspector,
                                  detailSegment: &detailSegment)
        flashes.mcpBanner.dismiss()
    }

    @MainActor
    private func load() async {
        do {
            // **A re-run for the same project reuses the live session.** A spurious
            // `.onDisappear` keeps its session (the liveness guard), and a
            // re-appear restarts this task: opening again would install a second
            // presenter and run the open-time seal/rotate sweep — rotation DELETES
            // — while Documents are registered and the editor bound to them.
            //
            // **The window holds at most ONE borrow, and it is `lease`.**
            // `.reuseLive` acquires nothing; a different project's borrow is given
            // back (and `lease` cleared, so nothing gives it back twice) BEFORE the
            // new acquire.
            switch ProjectSession.loadStep(live: session?.url, requested: url) {
            case .reuseLive:
                return
            case .closeLiveThenOpen:
                if let previous = lease {
                    self.lease = nil
                    await sessions.release(previous)
                }
            case .open:
                break
            }
            // The stores and services are the session's, and the session is the
            // project's: the registry opens it once (`ProjectSession.open`) and every
            // window borrows it. Borrowing AS A WINDOW attaches this one — its canvas
            // model becomes the store's live canvas, its flash the compiler's — and
            // announces the project to MCP. What stays here is the window's own: its
            // UI state, the stores and the session log.
            let lease = try await sessions.acquire(url, as: .window(attach: { session in
                session.attachWindow(
                    canvas: canvasModel,
                    flash: { showCompilerFlash($0) },
                    preferences: userPreferences)
            }, isLive: {
                // Read at the registry's reattach, from the window's state THEN. No
                // window in hand yet counts as live: a window still appearing must not
                // be dropped.
                window.map { MaughamEvent.isLive($0) } ?? true
            })) {
                try await ProjectSession.open(url: url)
            }
            // **A borrow this window will not keep goes straight back**: another
            // `load()` already holds one, or this load was cancelled AND the window
            // is gone. Keeping either would leave the project open after its last
            // window. A cancelled task on a still-live window KEEPS its borrow, or
            // it would sit on "Loading…" for good. No suspension point between this
            // check and `self.lease = lease` below.
            if self.lease != nil
                || (Task.isCancelled && window != nil && !MaughamEvent.isLive(window)) {
                await sessions.release(lease)
                return
            }
            let session = lease.session
            let s = session.projectStore
            let ds = session.documentStore

            // **Every `ds.uiState` seed is read BEFORE the stores are published, and
            // the order is the contract.** `showInspector`/`detailSegment` default to
            // `true`/`.inspector`, and a body pass with a store in hand and these
            // still at their defaults mounts `DetailPaneToggle` on `.inspector`,
            // whose `.onAppear` PERSISTS that segment — resetting every writer's
            // remembered pane on launch. With the stores still nil no body pass can
            // observe the defaults.
            //
            // The subject goes through the one rule that decides where a freshly
            // opened window lands; `.project` always answers, so no `if let`.
            self.selectedSubject = Self.validSubject(
                ds.uiState.selectedSubject, in: s.manifest.structure,
                research: s.manifest.research)
            self.isNoChromeOn = ds.uiState.isNoChromeOn
            self.isReviewModeOn = ds.uiState.isReviewModeOn
            self.researchPreviewVisible = ds.uiState.researchPreviewVisible
            self.compilerModel = ds.uiState.compilerModel
            // **Nothing about the study column is restored**: nothing is studied
            // when a window opens, or a reference would cover the right column
            // before the writer asked for anything.
            self.detailColumnWidth = ds.uiState.detailColumnWidth
            // Restored VERBATIM. Coercing to the restored persona's registry would
            // eat the writer's last explicit pane choice; `DetailPaneToggle` appends
            // an out-of-persona selection and renders it highlighted
            // (`visibleSegments`). A retired segment fails `UIState`'s tolerant
            // decode and falls back to `.inspector` before this line runs.
            self.detailSegment = ds.uiState.detailSegment
            self.persona = ds.uiState.persona
            self.outlineLayout = ds.uiState.outlineLayout
            applyNoChrome()

            self.lease = lease
            self.store = s
            self.documentStore = ds
            self.bible = session.bible
            self.declaredWorld = session.declaredWorld
            self.sessionLog = (try? await ds.loadSessionLog()) ?? .empty
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
