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
    @State private var selectedItemId: String?
    @State private var selectedResearchId: String?
    @State private var binderSegment: BinderSegment = .manuscript
    @State private var activeSheet: ProjectActiveSheet?
    @State private var showInspector: Bool = true
    @State private var showingTidyAllConfirmation: Bool = false
    @State private var sessionLog: SessionLog = .empty
    @State private var lastParsedScript: FountainScript? = nil
    @State private var showingSyntaxHelp: Bool = false
    @State private var researchPreviewVisible: Bool = false
    @State private var findActive: Bool = false
    @State private var pendingPieceRenameId: String?
    @State private var detailSegment: DetailSegment = .inspector
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
                NavigationSplitView {
                    binderColumn(store: store)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                } content: {
                    contentColumn(store: store, documentStore: documentStore)
                } detail: {
                    detailColumn(store: store, documentStore: documentStore)
                }
                .overlay(alignment: .top) {
                    SaveFlashOverlay(isShowing: $showingSaveFlash)
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
                        HelpClaudeDesktopSheet(
                            projectURL: store.url,
                            projectTitle: store.manifest.title)
                    }
                }
                .sheet(isPresented: $showingCheckpointLabelSheet) {
                    let projectURL = store.url
                    let activeDocId = selectedItemId ?? "__no-selection__"
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
        .frame(minWidth: 980, minHeight: 540)
        .modifier(TopChromeModifier(projectURL: url))
        .background(WindowAccessor(window: $window))
        .task(id: url) { await load() }
        .onDisappear {
            mcpRegistry.unregister(url: url)
            Task { await documentStore?.close() }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .maughamShowClaudeDesktopHelp)) { _ in
            activeSheet = .claudeDesktop
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamShareForReview)) { _ in
            // Broadcast command — only the focused project window acts, anchoring
            // the share sheet to its own NSWindow and reusing its resolved snapshot.
            guard window?.isKeyWindow == true, let store else { return }
            ProjectShareSheetPresenter.present(
                projectURL: store.url, snapshot: shareSnapshot, in: window)
        }
        .onKeyWindowCommand(.maughamToggleInspector, window: window) { _ in
            showInspector.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamAppWillTerminate)) { _ in
            // Best-effort flush. Task is fire-and-forget; NSApplication may
            // give us only ~100ms before terminating us.
            if let ds = documentStore {
                Task { await ds.close() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .maughamShowProjectStatistics)) { _ in
            guard window?.isKeyWindow == true else { return }
            openWindow(id: "project-stats", value: url)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .maughamScriptDidUpdate)) { note in
            // Scope to this window's project (Channel A): adopt the script only
            // when it originated here. A foreign post (another window flipping to
            // a screenplay piece) must not relayout this editor or clobber this
            // window's scene-navigator payload. NOT a key-window guard — a
            // background window's own MCP-driven re-parse still updates it.
            if let script = ScriptUpdateRouting.acceptedScript(
                from: note, forProjectId: ProjectIdentifier.id(for: url)) {
                self.lastParsedScript = script
            }
        }
        .onChange(of: selectedItemId) { _, newValue in
            documentStore?.updateUIState { $0.selectedItemId = newValue }
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
        .modifier(SessionAndNavigationModifier(
            documentStore: documentStore,
            store: store,
            url: url,
            window: window,
            sessionLog: $sessionLog,
            selectedItemId: $selectedItemId,
            selectedResearchId: $selectedResearchId,
            binderSegment: $binderSegment,
            findActive: $findActive,
            pendingPieceRenameId: $pendingPieceRenameId,
            showingTidyAllConfirmation: $showingTidyAllConfirmation,
            showingSyntaxHelp: $showingSyntaxHelp,
            researchPreviewVisible: $researchPreviewVisible,
            showInspector: $showInspector,
            detailSegment: $detailSegment,
            mcpBanner: mcpBanner))
        .modifier(CheckpointModifier(
            documentStore: documentStore,
            store: store,
            window: window,
            selectedItemId: selectedItemId,
            showingCheckpointLabelSheet: $showingCheckpointLabelSheet,
            onSaveFlash: { showSaveFlash() }))
        .modifier(ParagraphNavModifier(window: window, binderSegment: $binderSegment))
        .modifier(FocusPostureModifier(
            window: window,
            documentStore: documentStore,
            isNoChromeOn: $isNoChromeOn,
            isReviewModeOn: $isReviewModeOn,
            applyNoChrome: { applyNoChrome() }))
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
        .preferredColorScheme(preferredColorScheme)
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
    /// ⌘⌥R toggle. `lockEditing` is the hard floor — a reviewer/unknown is locked
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

    /// The top banners (software-update + backups-paused) and the focused project
    /// URL, pulled off `body` into a modifier so `ProjectWindow.body` stays under
    /// the SwiftUI type-checker's ceiling — the Release optimizer is stricter than
    /// Debug, so adding these inline built locally but failed the Release CI build.
    private struct TopChromeModifier: ViewModifier {
        let projectURL: URL
        func body(content: Content) -> some View {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        UpdateBannerView()
                        BackupRecoveryBanner(projectURL: projectURL)
                    }
                }
                .focusedSceneValue(\.projectURL, projectURL)
        }
    }

    private struct SessionAndNavigationModifier: ViewModifier {
        let documentStore: DocumentStore?
        let store: ProjectStore?
        let url: URL
        let window: NSWindow?
        @Binding var sessionLog: SessionLog
        @Binding var selectedItemId: String?
        @Binding var selectedResearchId: String?
        @Binding var binderSegment: BinderSegment
        @Binding var findActive: Bool
        @Binding var pendingPieceRenameId: String?
        @Binding var showingTidyAllConfirmation: Bool
        @Binding var showingSyntaxHelp: Bool
        @Binding var researchPreviewVisible: Bool
        @Binding var showInspector: Bool
        @Binding var detailSegment: DetailSegment
        let mcpBanner: MCPBannerModel

        func body(content: Content) -> some View {
            content
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamSetDetailSegment)) { note in
                    guard let raw = note.userInfo?["segment"] as? String,
                          let seg = DetailSegment(rawValue: raw) else { return }
                    showInspector = true     // ensure pane is visible
                    detailSegment = seg
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamTidyAllFilenames)) { _ in
                    guard window?.isKeyWindow == true else { return }
                    showingTidyAllConfirmation = true
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamSessionLogChanged)) { _ in
                    Task {
                        sessionLog = (try? await documentStore?.loadSessionLog()) ?? .empty
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamNavigateToDocument)) { note in
                    guard window?.isKeyWindow == true else { return }
                    if let id = note.userInfo?["id"] as? String {
                        binderSegment = .manuscript
                        selectedItemId = id
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamAddResearchFile)) { _ in
                    guard window?.isKeyWindow == true else { return }
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
                .onReceive(NotificationCenter.default.publisher(for: .maughamShowSyntaxHelp)) { _ in
                    showingSyntaxHelp = true
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamRestoreLastDeleted)) { _ in
                    guard window?.isKeyWindow == true else { return }
                    Task {
                        try? await store?.restoreLastDeleted()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamToggleResearchPreview)) { _ in
                    researchPreviewVisible.toggle()
                    documentStore?.updateUIState {
                        $0.researchPreviewVisible = researchPreviewVisible
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamFindInProject)) { _ in
                    binderSegment = .find
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamCloseFind)) { _ in
                    findActive = false
                    binderSegment = store?.manifest.type == .screenplay ? .scenes : .manuscript
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamFindMatchSelected)) { note in
                    guard let store,
                          let match = note.userInfo?["match"] as? SearchMatch else { return }
                    switch match.documentSource {
                    case .manuscript:
                        if let item = TreeWalk.first(
                            in: store.manifest.structure) { $0.path == match.documentPath } {
                            selectedItemId = item.id
                        }
                    case .research:
                        if let item = TreeWalk.first(
                            in: store.manifest.research) { $0.path == match.documentPath } {
                            selectedResearchId = item.id
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamMCPNoteAdded)) { note in
                    guard let info = note.userInfo,
                          let projectId = info["project_id"] as? String,
                          let researchId = info["research_id"] as? String,
                          let title = info["title"] as? String,
                          ProjectIdentifier.id(for: url) == projectId else { return }
                    DispatchQueue.main.async {
                        mcpBanner.bump(title: title, latestId: researchId)
                    }
                }
                .modifier(CollectionPieceModifier(
                    store: store,
                    window: window,
                    selectedItemId: $selectedItemId,
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
        /// The owning project window. The add-piece notifications are posted with
        /// `object: nil` (from the binder buttons + the menu command), so EVERY open
        /// collection window receives them. We act only when this window is key, so
        /// "add a screenplay" adds it to the front project, not all of them.
        let window: NSWindow?
        @Binding var selectedItemId: String?
        @Binding var pendingPieceRenameId: String?

        func body(content: Content) -> some View {
            content
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamAddLoosePiece)) { _ in
                    guard window?.isKeyWindow == true,
                          let store, store.manifest.type == .collection else { return }
                    Task {
                        let piece = try? await store.addLoosePiece(
                            title: "Untitled Piece", mode: .prose)
                        if let piece {
                            selectedItemId = piece.id
                            pendingPieceRenameId = piece.id
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamAddScreenplayPiece)) { _ in
                    guard window?.isKeyWindow == true,
                          let store, store.manifest.type == .collection else { return }
                    Task {
                        let piece = try? await store.addLoosePiece(
                            title: "Untitled Screenplay", mode: .screenplay)
                        if let piece {
                            selectedItemId = piece.id
                            pendingPieceRenameId = piece.id
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamLinkProject)) { _ in
                    guard window?.isKeyWindow == true,
                          let store, store.manifest.type == .collection else { return }
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Pick a Maugham project folder to link"
                    panel.begin { response in
                        guard response == .OK, let target = panel.url else { return }
                        Task {
                            let piece = try? await store.addProjectReference(targetURL: target)
                            if let piece { selectedItemId = piece.id }
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamPromotePiece)) { note in
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
                                NotificationCenter.default.post(
                                    name: .maughamOpenProject, object: nil,
                                    userInfo: ["url": newProjectURL])
                            } catch {
                                _projectWindowLog.error("Promote failed: \(error, privacy: .public)")
                            }
                        }
                    }
                }
        }
    }

    // MARK: - Helpers

    private static func defaultSegment(for type: ProjectType) -> BinderSegment {
        type == .screenplay ? .scenes : .manuscript
    }

    private var currentSyntaxHelpMode: SyntaxHelpMode {
        guard let store else { return .prose }
        return store.manifest.type == .screenplay ? .screenplay : .prose
    }

    // MARK: - Column builders

    @ViewBuilder
    private func binderColumn(store: ProjectStore) -> some View {
        if store.manifest.type == .collection {
            CollectionBinderPaneToggle(
                store: store,
                segment: $binderSegment,
                selectedItemId: $selectedItemId,
                selectedResearchId: $selectedResearchId,
                findActive: $findActive,
                renamingItemId: $pendingPieceRenameId,
                activePiece: activePiece(in: store),
                onAddPiece: {
                    NotificationCenter.default.post(name: .maughamAddLoosePiece, object: nil)
                },
                onAddSharedNote: { Task { try? await addSharedNoteAction(store: store) } },
                onAddPieceNote: { Task { try? await addPieceNoteAction(store: store) } }
            )
        } else {
            BinderPaneToggle(
                store: store,
                segment: $binderSegment,
                selectedItemId: $selectedItemId,
                selectedResearchId: $selectedResearchId,
                projectType: store.manifest.type,
                lastParsedScript: lastParsedScript,
                findActive: $findActive)
        }
    }

    private func activePiece(in store: ProjectStore) -> StructureItem? {
        guard store.manifest.type == .collection,
              let id = selectedItemId else { return nil }
        return store.manifest.structure.first(where: { $0.id == id })
    }

    @MainActor
    private func addSharedNoteAction(store: ProjectStore) async throws {
        let item = try await store.addResearchTextNote(parentId: nil)
        selectedResearchId = item.id
    }

    @MainActor
    private func addPieceNoteAction(store: ProjectStore) async throws {
        guard let pieceId = selectedItemId else { return }
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
            .navigationSplitViewColumnWidth(min: 480, ideal: 720)
    }

    private var shouldShowStatusFooter: Bool {
        guard userPreferences.goalIndicatorsVisible else { return false }
        guard binderSegment == .manuscript || binderSegment == .scenes else {
            return false
        }
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

    @ViewBuilder
    private func editorPane(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        if store.manifest.type == .collection,
           let id = selectedItemId,
           let piece = store.manifest.structure.first(where: { $0.id == id }),
           piece.pieceKind == .reference {
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
        NotificationCenter.default.post(
            name: .maughamOpenProject, object: nil, userInfo: ["url": url])
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
                selectedItemId: selectedItemId,
                onMetricsChanged: { metrics = $0 },
                onElementChanged: { currentElement = $0 },
                wikiLinkResolver: { title in
                    store.resolveDocumentId(forTitle: title) != nil
                },
                wikiLinkClickResolver: { title in
                    store.resolveDocumentId(forTitle: title)
                },
                // Role-driven posture flows entirely through the EditorControl
                // model (ADR 0017): an author's manual ⌘⌥R drives the render; a
                // reviewer/unknown is FORCED into review render AND hard-locked
                // (lockEditing) via `effectivePosture` mirrored into the control.
                control: editorControl
            )
        case .research:
            if let id = selectedResearchId,
               let item = TreeWalk.find(
                    id: id, in: store.manifest.research) {
                if item.kind == .document, let path = item.path {
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
        case .trash:
            ContentUnavailableView(
                "Trash",
                systemImage: "trash")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Helper: the currently-selected manuscript Document, if one is open
    /// in the editor registry.
    private func activeDocument(in store: ProjectStore, documentStore: DocumentStore) -> Document? {
        guard let id = selectedItemId,
              let item = TreeWalk.find(id: id, in: store.manifest.structure),
              let path = item.path else { return nil }
        return documentStore.document(for: path)
    }

    @ViewBuilder
    private func detailColumn(store: ProjectStore, documentStore: DocumentStore) -> some View {
        if showInspector {
            inspectorPane(store: store, documentStore: documentStore)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        }
    }

    @ViewBuilder
    private func inspectorPane(store: ProjectStore, documentStore: DocumentStore) -> some View {
        DetailPaneToggle(
            store: store,
            segment: $detailSegment,
            outlineLayout: $outlineLayout,
            selectedItemId: $selectedItemId,
            activeManuscriptItemId: selectedItemId,
            hideOutline: store.manifest.type == .collection,
            projectURL: store.url,
            activeDocId: selectedItemId ?? "__no-selection__",
            allDocIds: Self.documentIds(in: store.manifest.structure),
            device: _checkpointDeviceId,
            session: _checkpointSessionId,
            docPaths: Self.documentPaths(in: store.manifest.structure),
            documentStore: documentStore
        ) {
            if store.manifest.type == .collection {
                collectionInspector(store: store)
            } else {
                existingInspectorSwitch(store: store)
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
        if let id = selectedItemId,
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
                selectedItemId: selectedItemId,
                metrics: metrics,
                onOpenProjectSettings: { activeSheet = .projectSettings }
            )
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
        case .trash:
            ContentUnavailableView(
                "No selection",
                systemImage: "trash")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    /// Whether the given selection id resolves to a manuscript document (the
    /// only selection kind for which the EditorCoordinator delivers metrics).
    private func selectionIsDocument(_ id: String?) -> Bool {
        guard let store, let id,
              let item = TreeWalk.find(id: id, in: store.manifest.structure)
        else { return false }
        return item.type == .document && item.path != nil
    }

    private var goalIndicatorState: GoalIndicatorState {
        guard let store else { return .empty }
        let currentDoc = selectedItemId.flatMap {
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
            self.store = s
            self.documentStore = ds
            mcpRegistry.register(url: url, store: s)
            self.sessionLog = (try? await ds.loadSessionLog()) ?? .empty

            // Seed UI state from disk (or defaults). Validate selectedItemId
            // against current structure — if the saved selection refers to a
            // deleted item, fall back to first document.
            let savedSelection = ds.uiState.selectedItemId
            let isValid = savedSelection != nil
                ? TreeWalk.contains(id: savedSelection!, in: s.manifest.structure)
                : false
            if isValid {
                self.selectedItemId = savedSelection
            } else if let first = TreeWalk.first(in: s.manifest.structure, where: { $0.type == .document }) {
                self.selectedItemId = first.id
            }
            self.isNoChromeOn = ds.uiState.isNoChromeOn
            self.isReviewModeOn = ds.uiState.isReviewModeOn
            self.researchPreviewVisible = ds.uiState.researchPreviewVisible
            self.detailSegment = ds.uiState.detailSegment
            self.outlineLayout = ds.uiState.outlineLayout

            // Restore binderSegment from saved state, or use default based on project type.
            let savedSegment = ds.uiState.binderSegment
            // If screenplay project doesn't have manuscript segment, use scenes instead.
            if s.manifest.type == .screenplay && savedSegment == .manuscript {
                self.binderSegment = .scenes
            } else {
                self.binderSegment = savedSegment
            }
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
    /// The owning project window. ⌘S / Shift-⌘S are posted with `object: nil`
    /// (menu commands), so every open window receives them. We act only when
    /// this window is key, so ⌘S checkpoints + backs up the front project only.
    let window: NSWindow?
    let selectedItemId: String?
    @Binding var showingCheckpointLabelSheet: Bool
    let onSaveFlash: () -> Void
    @Environment(BackupCoordinator.self) private var backupCoordinator

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(
                for: .maughamSaveCheckpoint)) { _ in
                guard window?.isKeyWindow == true,
                      let store, let documentStore else { return }
                let activeDocId = selectedItemId ?? "__no-selection__"
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
            .onReceive(NotificationCenter.default.publisher(
                for: .maughamNamedCheckpoint)) { _ in
                guard window?.isKeyWindow == true, store != nil else { return }
                showingCheckpointLabelSheet = true
            }
            .modifier(RewindModifier(
                documentStore: documentStore,
                store: store,
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
    let selectedItemId: String?
    @State private var showingRewindModal: Bool = false
    @State private var rewindInitialCursor: RewindCursor = .now

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(
                for: .maughamOpenRewind)) { note in
                // Scope to the originating window: HistoryPane posts the
                // notification with `object: projectURL`. With multiple
                // ProjectWindows open, this prevents every window's modal
                // from opening on a single click — only the window whose
                // projectURL matches the originator presents.
                guard let originator = note.object as? URL,
                      originator == store?.url,
                      selectedItemId != nil else { return }
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
                        NotificationCenter.default.post(
                            name: .maughamCheckpointAdded, object: nil)
                    case .restoreHere(let opId):
                        Task { @MainActor in
                            _ = try? await documentStore.document(forDocId: docId)?
                                .restoreToOp(opId: opId)
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
/// `Maugham/Views/AREA.md`). Handles ⌘\ no-chrome and ⌘⌥R review (key-window
/// only) and persists both flags to UIState.
private struct FocusPostureModifier: ViewModifier {
    let window: NSWindow?
    let documentStore: DocumentStore?
    @Binding var isNoChromeOn: Bool
    @Binding var isReviewModeOn: Bool
    let applyNoChrome: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(
                for: .maughamToggleNoChrome)) { _ in
                isNoChromeOn.toggle()
                applyNoChrome()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .maughamToggleReviewMode)) { _ in
                guard window?.isKeyWindow == true else { return }
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

private struct ParagraphNavModifier: ViewModifier {
    /// The owning project window. `.maughamNavigateToParagraph` is posted with
    /// `object: nil`, so every open window receives it; we act only when key.
    let window: NSWindow?
    @Binding var binderSegment: BinderSegment
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(
                for: .maughamNavigateToParagraph)) { note in
                guard window?.isKeyWindow == true else { return }
                // v1: just ensure the manuscript pane is focused.
                // Anchored scroll-to-paragraph is a follow-up.
                _ = note.userInfo?["paragraph_id"] as? String
                binderSegment = .manuscript
            }
            // `.maughamShowHelp` is posted with `object: nil`, so every window
            // receives it; `openWindow(id:)` for a singleton Window is idempotent
            // (it brings the one Help window forward), so no key-window guard.
            .onReceive(NotificationCenter.default.publisher(for: .maughamShowHelp)) { _ in
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

