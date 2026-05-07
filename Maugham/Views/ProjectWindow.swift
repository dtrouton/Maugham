import SwiftUI
import AppKit

struct ProjectWindow: View {
    @State private var store: ProjectStore?
    @State private var loadError: String?
    @State private var isNoChromeOn: Bool = false
    @State private var window: NSWindow?
    @State private var metrics: EditorMetrics =
        EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0)
    @Environment(ThemeManager.self) private var themeManager

    let url: URL

    var body: some View {
        Group {
            if let store {
                ZStack(alignment: .bottomTrailing) {
                    EditorSurface(
                        text: Binding(
                            get: { store.manuscriptText },
                            set: { newValue in
                                store.manuscriptText = newValue
                                metrics = ProseMode().metrics(newValue)
                                Task { try? await store.save() }
                            }
                        ),
                        theme: themeManager.theme,
                        typography: themeManager.typography,
                        mode: ProseMode(),
                        typewriterScroll: themeManager.typewriterScroll,
                        sentenceFocus: themeManager.sentenceFocus,
                        paragraphFocus: themeManager.paragraphFocus
                    )
                    if themeManager.goalIndicatorsVisible {
                        GoalIndicatorView(metrics: metrics)
                    }
                }
                .navigationTitle(store.manifest.title)
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Couldn't open project")
                        .font(.headline)
                    Text(loadError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(48)
            } else {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(WindowAccessor(window: $window))
        .task(id: url) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleNoChrome)) { _ in
            isNoChromeOn.toggle()
            applyNoChrome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleFullScreen)) { _ in
            toggleFullScreen()
        }
        .onChange(of: isNoChromeOn) { _, _ in
            applyNoChrome()
        }
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
    private func load() async {
        do {
            store = try await ProjectStore.load(from: url)
            if let store {
                metrics = ProseMode().metrics(store.manuscriptText)
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
}

extension Notification.Name {
    static let maughamToggleNoChrome =
        Notification.Name("maugham.toggleNoChrome")
    static let maughamToggleFullScreen =
        Notification.Name("maugham.toggleFullScreen")
    static let maughamDummySave =
        Notification.Name("maugham.dummySave")
}

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if self.window == nil {
                self.window = nsView.window
            }
        }
    }
}
