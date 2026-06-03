import SwiftUI
import MaughamCore
import AppKit

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
    @State private var showingDiffSheet: Bool = false
    @State private var sessionLog: SessionLog = .empty
    @State private var lastParsedScript: FountainScript? = nil
    @State private var showingSyntaxHelp: Bool = false
    @State private var researchPreviewVisible: Bool = false
    @State private var findActive: Bool = false
    @State private var pendingPieceRenameId: String?
    @State private var detailSegment: DetailSegment = .inspector
    @State private var outlineLayout: OutlineLayout = .table
    @State private var mcpBannerTitle: String?
    @State private var mcpBannerCount: Int = 0
    @State private var mcpBannerLatestId: String?
    @State private var mcpBannerDismissTask: Task<Void, Never>?
    @State private var showingCheckpointLabelSheet: Bool = false
    @State private var showingBootstrapNotice: Bool = false
    @State private var currentElement: String? = nil
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
                    if let title = mcpBannerTitle {
                        MCPNoteBanner(
                            title: title,
                            count: mcpBannerCount,
                            onShow: { handleShowLatestMCPNote() },
                            onDismiss: { handleDismissMCPBanner() }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: mcpBannerTitle)
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
                .sheet(isPresented: $showingDiffSheet) {
                    if let conflict = activeDocument(in: store, documentStore: documentStore)?.pendingConflict {
                        ConflictDiffSheet(
                            conflict: conflict,
                            onKeepMine: {
                                Task {
                                    try? await activeDocument(in: store, documentStore: documentStore)?
                                        .resolveConflictKeepMine()
                                    showingDiffSheet = false
                                }
                            },
                            onUseCloud: {
                                Task {
                                    try? await activeDocument(in: store, documentStore: documentStore)?
                                        .resolveConflictUseExternal()
                                    showingDiffSheet = false
                                }
                            },
                            onClose: { showingDiffSheet = false }
                        )
                    }
                }
                .sheet(isPresented: $showingCheckpointLabelSheet) {
                    let projectURL = store.url
                    let activeDocId = selectedItemId ?? "__no-selection__"
                    let allDocIds: [String] = {
                        func collect(_ items: [StructureItem]) -> [String] {
                            var ids: [String] = []
                            for item in items {
                                if item.type == .document { ids.append(item.id) }
                                if let ch = item.children { ids.append(contentsOf: collect(ch)) }
                            }
                            return ids
                        }
                        return collect(store.manifest.structure)
                    }()
                    CheckpointLabelPromptSheet(
                        onConfirm: { label in
                            showingCheckpointLabelSheet = false
                            Task { @MainActor in
                                try? await activeDocument(in: store, documentStore: documentStore)?
                                    .flushBurstNow()
                                _ = try? await CheckpointCapture.run(
                                    projectURL: projectURL,
                                    activeDocId: activeDocId,
                                    allDocIds: allDocIds,
                                    device: _checkpointDeviceId,
                                    session: _checkpointSessionId,
                                    label: label)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            UpdateBannerView()
        }
        .background(WindowAccessor(window: $window))
        .task(id: url) { await load() }
        .onDisappear {
            mcpRegistry.unregister(url: url)
            Task { await documentStore?.close() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleNoChrome)) { _ in
            isNoChromeOn.toggle()
            applyNoChrome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleFullScreen)) { _ in
            toggleFullScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamDummySave)) { _ in
            Task {
                try? await documentStore?.flushPendingSave()
                showSaveFlash()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamShowProjectSettings)) { _ in
            activeSheet = .projectSettings
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamShowClaudeDesktopHelp)) { _ in
            activeSheet = .claudeDesktop
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleInspector)) { _ in
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
            openWindow(id: "project-stats", value: url)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .maughamScriptDidUpdate)) { note in
            if let script = note.object as? FountainScript {
                self.lastParsedScript = script
            }
        }
        .onChange(of: isNoChromeOn) { _, newValue in
            applyNoChrome()
            documentStore?.updateUIState { $0.isNoChromeOn = newValue }
        }
        .onChange(of: selectedItemId) { _, newValue in
            documentStore?.updateUIState { $0.selectedItemId = newValue }
        }
        .onChange(of: binderSegment) { _, newValue in
            documentStore?.updateUIState { $0.binderSegment = newValue }
        }
        .modifier(SessionAndNavigationModifier(
            documentStore: documentStore,
            store: store,
            url: url,
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
            mcpBannerTitle: $mcpBannerTitle,
            mcpBannerCount: $mcpBannerCount,
            mcpBannerLatestId: $mcpBannerLatestId,
            mcpBannerDismissTask: $mcpBannerDismissTask))
        .modifier(CheckpointModifier(
            documentStore: documentStore,
            store: store,
            selectedItemId: selectedItemId,
            showingCheckpointLabelSheet: $showingCheckpointLabelSheet,
            onSaveFlash: { showSaveFlash() }))
        .modifier(ParagraphNavModifier(binderSegment: $binderSegment))
        .sheet(isPresented: $showingSyntaxHelp) {
            SyntaxHelpSheet(mode: currentSyntaxHelpMode)
        }
        .preferredColorScheme(preferredColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        switch userPreferences.theme {
        case .followSystem: return nil
        case .dark:         return .dark
        case .light, .sepia: return .light
        }
    }

    private struct SessionAndNavigationModifier: ViewModifier {
        let documentStore: DocumentStore?
        let store: ProjectStore?
        let url: URL
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
        @Binding var mcpBannerTitle: String?
        @Binding var mcpBannerCount: Int
        @Binding var mcpBannerLatestId: String?
        @Binding var mcpBannerDismissTask: Task<Void, Never>?

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
                    if let id = note.userInfo?["id"] as? String {
                        binderSegment = .manuscript
                        selectedItemId = id
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamAddResearchFile)) { _ in
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
                        if let item = findStructureItemByPath(
                            match.documentPath, in: store.manifest.structure) {
                            selectedItemId = item.id
                        }
                    case .research:
                        if let item = findResearchItemByPath(
                            match.documentPath, in: store.manifest.research) {
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
                        mcpBannerTitle = title
                        mcpBannerCount += 1
                        mcpBannerLatestId = researchId
                        mcpBannerDismissTask?.cancel()
                        mcpBannerDismissTask = Task {
                            try? await Task.sleep(for: .seconds(8))
                            if !Task.isCancelled {
                                await MainActor.run {
                                    mcpBannerTitle = nil
                                    mcpBannerCount = 0
                                    mcpBannerLatestId = nil
                                    mcpBannerDismissTask?.cancel()
                                    mcpBannerDismissTask = nil
                                }
                            }
                        }
                    }
                }
                .modifier(CollectionPieceModifier(
                    store: store,
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

        private func findStructureItemByPath(
            _ path: String, in items: [StructureItem]
        ) -> StructureItem? {
            for item in items {
                if item.path == path { return item }
                if let children = item.children,
                   let nested = findStructureItemByPath(path, in: children) {
                    return nested
                }
            }
            return nil
        }

        private func findResearchItemByPath(
            _ path: String, in items: [ResearchItem]
        ) -> ResearchItem? {
            for item in items {
                if item.path == path { return item }
                if let children = item.children,
                   let nested = findResearchItemByPath(path, in: children) {
                    return nested
                }
            }
            return nil
        }
    }

    /// Handles the three collection-piece notifications in a separate modifier
    /// so that SessionAndNavigationModifier.body stays within the type-checker limit.
    private struct CollectionPieceModifier: ViewModifier {
        let store: ProjectStore?
        @Binding var selectedItemId: String?
        @Binding var pendingPieceRenameId: String?

        func body(content: Content) -> some View {
            content
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamAddLoosePiece)) { _ in
                    guard let store, store.manifest.type == .collection else { return }
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
                    guard let store, store.manifest.type == .collection else { return }
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
                                print("Promote failed: \(error)")
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
                if PublishStarter.isInitialized(in: store.url) {
                    PublishStatusPill(
                        projectID: ProjectIdentifier.id(for: store.url),
                        projectURL: store.url)
                        .padding(.top, 8)
                        .padding(.trailing, 12)
                }
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
                conflictBanner(documentStore: documentStore)
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
                onTextChange: { text in updateMetrics(for: text) },
                onElementChanged: { currentElement = $0 },
                wikiLinkResolver: { title in
                    store.resolveDocumentId(forTitle: title) != nil
                },
                wikiLinkClickResolver: { title in
                    store.resolveDocumentId(forTitle: title)
                }
            )
        case .research:
            if let id = selectedResearchId,
               let item = findResearchItem(
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

    @ViewBuilder
    private func conflictBanner(documentStore: DocumentStore) -> some View {
        if let store, let conflict = activeDocument(in: store, documentStore: documentStore)?.pendingConflict {
            ConflictBanner(
                conflict: conflict,
                onKeepMine: {
                    Task {
                        try? await activeDocument(in: store, documentStore: documentStore)?
                            .resolveConflictKeepMine()
                    }
                },
                onUseCloud: {
                    Task {
                        try? await activeDocument(in: store, documentStore: documentStore)?
                            .resolveConflictUseExternal()
                    }
                },
                onShowDiff: isDocumentConflict(conflict) ? {
                    showingDiffSheet = true
                } : nil
            )
        }
    }

    /// Helper: the currently-selected manuscript Document, if one is open
    /// in the editor registry. Used by conflict banner + diff sheet binding
    /// post the document-first-class refactor (T11).
    private func activeDocument(in store: ProjectStore, documentStore: DocumentStore) -> Document? {
        guard let id = selectedItemId,
              let item = findItem(id: id, in: store.manifest.structure),
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
            allDocIds: collectAllDocIds(in: store.manifest.structure),
            device: _checkpointDeviceId,
            session: _checkpointSessionId,
            docPaths: collectDocPaths(in: store.manifest.structure),
            documentStore: documentStore
        ) {
            if store.manifest.type == .collection {
                collectionInspector(store: store)
            } else {
                existingInspectorSwitch(store: store)
            }
        }
    }

    private func collectAllDocIds(in items: [StructureItem]) -> [String] {
        var ids: [String] = []
        for item in items {
            if item.type == .document { ids.append(item.id) }
            if let children = item.children { ids.append(contentsOf: collectAllDocIds(in: children)) }
        }
        return ids
    }

    private func collectDocPaths(in items: [StructureItem]) -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            if item.type == .document, let path = item.path { result[item.id] = path }
            if let children = item.children {
                for (k, v) in collectDocPaths(in: children) { result[k] = v }
            }
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
                    ScreenplayPieceInspector(store: store, pieceId: id)
                } else {
                    ProsePieceInspector(store: store, pieceId: id)
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
               let item = findResearchItem(
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

    private func updateMetrics(for text: String) {
        guard let store, let id = selectedItemId,
              let item = findItem(id: id, in: store.manifest.structure),
              item.type == .document, let path = item.path else {
            metrics = EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0)
            return
        }
        metrics = WritingModeFactory.mode(for: path).metrics(text)
    }

    private func findItem(id: String, in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let n = findItem(id: id, in: children) { return n }
        }
        return nil
    }

    private var goalIndicatorState: GoalIndicatorState {
        guard let store else { return .empty }
        let currentDoc = selectedItemId.flatMap {
            findItem(id: $0, in: store.manifest.structure)
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

    private func findResearchItem(
        id: String, in items: [ResearchItem]
    ) -> ResearchItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let nested = findResearchItem(id: id, in: children) {
                return nested
            }
        }
        return nil
    }

    private func findStructureItemByPath(
        _ path: String, in items: [StructureItem]
    ) -> StructureItem? {
        for item in items {
            if item.path == path { return item }
            if let children = item.children,
               let nested = findStructureItemByPath(path, in: children) {
                return nested
            }
        }
        return nil
    }

    private func findResearchItemByPath(
        _ path: String, in items: [ResearchItem]
    ) -> ResearchItem? {
        for item in items {
            if item.path == path { return item }
            if let children = item.children,
               let nested = findResearchItemByPath(path, in: children) {
                return nested
            }
        }
        return nil
    }

    private func isDocumentConflict(_ conflict: ConflictState) -> Bool {
        // Manifest conflict path is ProjectManifest.fileName; everything else
        // is a document.
        !conflict.path.hasSuffix(ProjectManifest.fileName)
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

    private func handleMCPNoteAdded(researchId: String, title: String) {
        mcpBannerTitle = title
        mcpBannerCount += 1
        mcpBannerLatestId = researchId
        mcpBannerDismissTask?.cancel()
        mcpBannerDismissTask = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled {
                await MainActor.run { handleDismissMCPBanner() }
            }
        }
    }

    private func handleShowLatestMCPNote() {
        guard let id = mcpBannerLatestId else { return }
        binderSegment = .research
        selectedResearchId = id
        handleDismissMCPBanner()
    }

    private func handleDismissMCPBanner() {
        mcpBannerTitle = nil
        mcpBannerCount = 0
        mcpBannerLatestId = nil
        mcpBannerDismissTask?.cancel()
        mcpBannerDismissTask = nil
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
                ? findItem(id: savedSelection!, in: s.manifest.structure) != nil
                : false
            if isValid {
                self.selectedItemId = savedSelection
            } else if let first = firstDocument(in: s.manifest.structure) {
                self.selectedItemId = first.id
            }
            self.isNoChromeOn = ds.uiState.isNoChromeOn
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
        } catch ProjectStoreError.manuscriptUnreadable(let msg) {
            loadError = "Manuscript file couldn't be read: \(msg)"
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func firstDocument(in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.type == .document { return item }
            if let children = item.children,
               let nested = firstDocument(in: children) { return nested }
        }
        return nil
    }
}

// MARK: - CheckpointModifier

/// Breaks the ⌘S / Shift-⌘S checkpoint notification handlers out of the
/// main body chain so Swift's type-checker doesn't time out.
private struct CheckpointModifier: ViewModifier {
    let documentStore: DocumentStore?
    let store: ProjectStore?
    let selectedItemId: String?
    @Binding var showingCheckpointLabelSheet: Bool
    let onSaveFlash: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(
                for: .maughamSaveCheckpoint)) { _ in
                guard let store, let documentStore else { return }
                let activeDocId = selectedItemId ?? "__no-selection__"
                let allDocIds = collectDocIds(in: store.manifest.structure)
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
                        label: nil)
                    onSaveFlash()
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .maughamNamedCheckpoint)) { _ in
                guard store != nil else { return }
                showingCheckpointLabelSheet = true
            }
            .modifier(RewindModifier(
                documentStore: documentStore,
                store: store,
                selectedItemId: selectedItemId))
    }

    private func collectDocIds(in items: [StructureItem]) -> [String] {
        var ids: [String] = []
        for item in items {
            if item.type == .document { ids.append(item.id) }
            if let children = item.children {
                ids.append(contentsOf: collectDocIds(in: children))
            }
        }
        return ids
    }

    private func activeDocument(
        selectedItemId: String?,
        structure: [StructureItem],
        documentStore: DocumentStore
    ) -> Document? {
        guard let id = selectedItemId else { return nil }
        func find(_ items: [StructureItem]) -> StructureItem? {
            for item in items {
                if item.id == id { return item }
                if let children = item.children, let n = find(children) { return n }
            }
            return nil
        }
        guard let item = find(structure), let path = item.path else { return nil }
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
            let allIds = collectDocIds(in: store.manifest.structure)
            let paths = collectDocPaths(in: store.manifest.structure)
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

    private func collectDocIds(in items: [StructureItem]) -> [String] {
        var ids: [String] = []
        for item in items {
            if item.type == .document { ids.append(item.id) }
            if let ch = item.children { ids.append(contentsOf: collectDocIds(in: ch)) }
        }
        return ids
    }

    private func collectDocPaths(in items: [StructureItem]) -> [String: String] {
        var m: [String: String] = [:]
        for item in items {
            if item.type == .document, let path = item.path { m[item.id] = path }
            if let ch = item.children {
                m.merge(collectDocPaths(in: ch)) { a, _ in a }
            }
        }
        return m
    }
}

// MARK: - ParagraphNavModifier

/// Handles .maughamNavigateToParagraph in its own modifier to stay within
/// Swift's type-checker expression limit in SessionAndNavigationModifier.
private struct ParagraphNavModifier: ViewModifier {
    @Binding var binderSegment: BinderSegment

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(
                for: .maughamNavigateToParagraph)) { note in
                // v1: just ensure the manuscript pane is focused.
                // Anchored scroll-to-paragraph is a follow-up.
                _ = note.userInfo?["paragraph_id"] as? String
                binderSegment = .manuscript
            }
    }
}

/// An editor surface for a research note (.document kind). Research notes
/// are not `Document` actors (no op-log, no paragraph IDs); they autosave via
/// `DocumentStore.scheduleFileSave` on the same 750ms cadence. Selecting a
/// different research item simply unmounts this view and remounts with the
/// new path, flushing the pending save.
private struct ResearchNoteEditor: View {
    @Bindable var store: ProjectStore
    @Bindable var documentStore: DocumentStore
    let path: String
    let itemId: String
    let previewVisible: Bool
    @Environment(UserPreferences.self) private var userPreferences

    @State private var documentText: String = ""
    @State private var loadedPath: String?
    @State private var researchCursor: Int? = nil

    var body: some View {
        HSplitView {
            editorContent
            if previewVisible {
                ResearchNotePreviewPane(
                    notePath: path,
                    projectURL: store.url,
                    noteText: documentText)
            }
        }
        .task(id: path) { await loadDocument() }
    }

    @ViewBuilder
    private var editorContent: some View {
        Group {
            if loadedPath == path {
                EditorSurface(
                    text: Binding(
                        get: { documentText },
                        set: { newValue in
                            documentText = newValue
                            documentStore.scheduleFileSave(for: path, text: newValue)
                        }
                    ),
                    theme: userPreferences.theme,
                    typography: ProjectStore.effectiveTypography(
                        override: store.manifest.typography,
                        userDefault: userPreferences.typography),
                    mode: WritingModeFactory.mode(for: path),
                    typewriterScroll: userPreferences.typewriterScroll,
                    sentenceFocus: userPreferences.sentenceFocus,
                    paragraphFocus: userPreferences.paragraphFocus,
                    initialCursorLocation: researchCursor,
                    onCursorChanged: { position in
                        researchCursor = position
                    },
                    showElementGutter: false,
                    imagePasteHandler: makeImagePasteHandler()
                )
                .id(path)
            } else {
                VStack {
                    Text("Loading…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func makeImagePasteHandler() -> ((NSImage) -> String?) {
        let projectURL = store.url
        let notePath = path
        return { image in
            do {
                return try ImagePasteHandler.saveAndReference(
                    image: image,
                    forNoteAt: notePath,
                    in: projectURL)
            } catch {
                print("Image paste failed:", error)
                return nil
            }
        }
    }

    private func loadDocument() async {
        guard loadedPath != path else { return }
        // Flush any pending file save before switching research notes.
        try? await documentStore.flushPendingSave()
        let url = store.url.appendingPathComponent(path)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        documentText = text
        researchCursor = nil
        loadedPath = path
    }
}

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.window = view.window }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if self.window == nil { self.window = nsView.window }
        }
    }
}
