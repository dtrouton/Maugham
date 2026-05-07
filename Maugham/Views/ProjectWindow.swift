import SwiftUI
import AppKit

enum ProjectActiveSheet: Identifiable {
    case projectSettings
    case claudeDesktop
    var id: Int { hashValue }
}

struct ProjectWindow: View {
    @State private var store: ProjectStore?
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
            if let store {
                NavigationSplitView {
                    BinderView(store: store, selectedItemId: $selectedItemId)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                } content: {
                    ZStack(alignment: .bottomTrailing) {
                        EditorHost(
                            store: store,
                            selectedItemId: selectedItemId,
                            onTextChange: { text in updateMetrics(for: text) }
                        )
                        .onChange(of: selectedItemId) { _, _ in
                            // Selection change reloads document inside EditorHost
                            // which fires onTextChange — no manual refresh needed.
                        }
                        if userPreferences.goalIndicatorsVisible {
                            GoalIndicatorView(metrics: metrics)
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
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleNoChrome)) { _ in
            isNoChromeOn.toggle()
            applyNoChrome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleFullScreen)) { _ in
            toggleFullScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamDummySave)) { _ in
            showSaveFlash()
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
        .onChange(of: isNoChromeOn) { _, _ in applyNoChrome() }
    }

    // MARK: - Helpers

    /// Recompute metrics from live editor text. Called by EditorHost on every
    /// keystroke, paste, and document load — so the inspector and goal
    /// indicator stay in sync without re-reading from disk.
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
            store = try await ProjectStore.load(from: url)
            // Auto-select the first document for usability. EditorHost will
            // load the document and call back via onTextChange so metrics
            // populate automatically.
            if let first = firstDocument(in: store?.manifest.structure ?? []) {
                selectedItemId = first.id
            }
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
