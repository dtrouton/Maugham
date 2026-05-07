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
    @State private var activeSheet: ProjectActiveSheet?
    @State private var showInspector: Bool = true
    @Environment(UserPreferences.self) private var userPreferences

    let url: URL

    var body: some View {
        Group {
            if let store, let documentStore {
                NavigationSplitView {
                    BinderView(store: store, selectedItemId: $selectedItemId)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                } content: {
                    ZStack(alignment: .bottomTrailing) {
                        EditorHost(
                            store: store,
                            documentStore: documentStore,
                            selectedItemId: selectedItemId,
                            onTextChange: { text in updateMetrics(for: text) }
                        )
                        if userPreferences.goalIndicatorsVisible {
                            GoalIndicatorView(metrics: metrics)
                        }
                    }
                    .safeAreaInset(edge: .top) {
                        if let conflict = documentStore.pendingConflict {
                            ConflictBanner(
                                conflict: conflict,
                                onKeepMine: {
                                    Task { try? await documentStore.resolveConflictKeepMine() }
                                },
                                onUseCloud: {
                                    Task { try? await documentStore.resolveConflictUseCloud() }
                                }
                            )
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 480, ideal: 720)
                } detail: {
                    if showInspector && store.manifest.type != .collection {
                        InspectorView(
                            store: store,
                            selectedItemId: selectedItemId,
                            metrics: metrics,
                            onOpenProjectSettings: { activeSheet = .projectSettings }
                        )
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
                    }
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
        .onChange(of: isNoChromeOn) { _, newValue in
            applyNoChrome()
            documentStore?.updateUIState { $0.isNoChromeOn = newValue }
        }
        .onChange(of: selectedItemId) { _, newValue in
            documentStore?.updateUIState { $0.selectedItemId = newValue }
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
