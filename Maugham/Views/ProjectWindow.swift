import SwiftUI
import AppKit

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
    @Environment(UserPreferences.self) private var userPreferences
    @Environment(\.openWindow) private var openWindow

    let url: URL

    var body: some View {
        Group {
            if let store, let documentStore {
                NavigationSplitView {
                    BinderPaneToggle(
                        store: store,
                        segment: $binderSegment,
                        selectedItemId: $selectedItemId,
                        selectedResearchId: $selectedResearchId,
                        projectType: store.manifest.type,
                        lastParsedScript: lastParsedScript)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                } content: {
                    contentColumn(store: store, documentStore: documentStore)
                } detail: {
                    detailColumn(store: store)
                }
                .overlay(alignment: .top) {
                    SaveFlashOverlay(isShowing: $showingSaveFlash)
                }
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
                    if let conflict = documentStore.pendingConflict {
                        ConflictDiffSheet(
                            conflict: conflict,
                            onKeepMine: {
                                Task {
                                    try? await documentStore.resolveConflictKeepMine()
                                    showingDiffSheet = false
                                }
                            },
                            onUseCloud: {
                                Task {
                                    try? await documentStore.resolveConflictUseCloud()
                                    showingDiffSheet = false
                                }
                            },
                            onClose: { showingDiffSheet = false }
                        )
                    }
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
        .background(WindowAccessor(window: $window))
        .task(id: url) { await load() }
        .onDisappear { Task { await documentStore?.close() } }
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
            sessionLog: $sessionLog,
            selectedItemId: $selectedItemId,
            binderSegment: $binderSegment,
            showingTidyAllConfirmation: $showingTidyAllConfirmation,
            showingSyntaxHelp: $showingSyntaxHelp))
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
        @Binding var sessionLog: SessionLog
        @Binding var selectedItemId: String?
        @Binding var binderSegment: BinderSegment
        @Binding var showingTidyAllConfirmation: Bool
        @Binding var showingSyntaxHelp: Bool

        func body(content: Content) -> some View {
            content
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
    private func contentColumn(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        ZStack(alignment: .bottomTrailing) {
            editorPane(store: store, documentStore: documentStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if userPreferences.goalIndicatorsVisible
               && (binderSegment == .manuscript || binderSegment == .scenes) {
                GoalIndicatorView(state: goalIndicatorState)
            }
        }
        .safeAreaInset(edge: .top) {
            conflictBanner(documentStore: documentStore)
        }
        .navigationSplitViewColumnWidth(min: 480, ideal: 720)
    }

    @ViewBuilder
    private func editorPane(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        switch binderSegment {
        case .manuscript, .scenes:
            // Both segments show the editor — .scenes is just an alternate
            // sidebar navigator; the underlying screenplay file is the same.
            EditorHost(
                store: store,
                documentStore: documentStore,
                selectedItemId: selectedItemId,
                onTextChange: { text in updateMetrics(for: text) },
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
                        itemId: item.id)
                } else {
                    ResearchPreview(projectURL: store.url, item: item)
                }
            } else {
                ContentUnavailableView(
                    "Select an item to preview",
                    systemImage: "doc.text.magnifyingglass")
            }
        case .trash:
            ContentUnavailableView(
                "Trash",
                systemImage: "trash")
        }
    }

    @ViewBuilder
    private func conflictBanner(documentStore: DocumentStore) -> some View {
        if let conflict = documentStore.pendingConflict {
            ConflictBanner(
                conflict: conflict,
                onKeepMine: {
                    Task { try? await documentStore.resolveConflictKeepMine() }
                },
                onUseCloud: {
                    Task { try? await documentStore.resolveConflictUseCloud() }
                },
                onShowDiff: isDocumentConflict(conflict) ? {
                    showingDiffSheet = true
                } : nil
            )
        }
    }

    @ViewBuilder
    private func detailColumn(store: ProjectStore) -> some View {
        if showInspector && store.manifest.type != .collection {
            inspectorPane(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        }
    }

    @ViewBuilder
    private func inspectorPane(store: ProjectStore) -> some View {
        switch binderSegment {
        case .manuscript, .scenes:
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
            }
        case .trash:
            ContentUnavailableView(
                "No selection",
                systemImage: "trash")
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
        let isScreenplay = store.manifest.type == .screenplay
        return GoalIndicatorState(
            docWordCount: metrics.wordCount,
            docWordTarget: currentDoc?.wordTarget,
            projectWordCount: store.projectWordCount,
            projectWordTarget: store.manifest.targets?.totalWords,
            wordsToday: sessionLog.wordsToday(),
            readingMinutes: metrics.readingMinutes,
            pageCount: metrics.pageCount,
            pageTarget: store.manifest.targets?.pageTarget,
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

    private func isDocumentConflict(_ conflict: ConflictState) -> Bool {
        // Manifest conflict path is "project.maugham.json"; everything else
        // is a document.
        !conflict.path.hasSuffix("project.maugham.json")
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

    @MainActor
    private func load() async {
        do {
            let s = try await ProjectStore.load(from: url)
            let ds = try await DocumentStore.open(url: url)
            s.documentStore = ds
            self.store = s
            self.documentStore = ds
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

/// An editor surface for a research note (.document kind). Calls
/// DocumentStore.openDocument(at:) on appearance and whenever the selected
/// path changes, so the existing 750ms autosave writes back to the correct
/// research/<note>.md file. Selecting a different research item or switching
/// to the manuscript tab simply unmounts this view and remounts with the
/// new path, triggering a flush of the pending save.
private struct ResearchNoteEditor: View {
    @Bindable var store: ProjectStore
    @Bindable var documentStore: DocumentStore
    let path: String
    let itemId: String
    @Environment(UserPreferences.self) private var userPreferences

    @State private var documentText: String = ""
    @State private var loadedPath: String?

    var body: some View {
        Group {
            if loadedPath == path {
                EditorSurface(
                    text: Binding(
                        get: { documentText },
                        set: { newValue in
                            documentText = newValue
                            documentStore.currentDocumentText = newValue
                            documentStore.scheduleSave(for: path, text: newValue)
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
                    initialCursorLocation: documentStore.cursor(for: path),
                    onCursorChanged: { position in
                        documentStore.setCursor(position, for: path)
                    },
                    showElementGutter: false
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
        .task(id: path) { await loadDocument() }
    }

    private func loadDocument() async {
        guard loadedPath != path else { return }
        do {
            let text = try await documentStore.openDocument(at: path)
            documentText = text
            documentStore.currentDocumentText = text
            loadedPath = path
        } catch {
            documentText = ""
            documentStore.currentDocumentText = ""
            loadedPath = path
        }
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
