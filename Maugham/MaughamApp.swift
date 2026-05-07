import SwiftUI
import AppKit

extension Notification.Name {
    static let maughamNewProject = Notification.Name("maugham.newProject")
    static let maughamOpenProject = Notification.Name("maugham.openProject")
}

@main
struct MaughamApp: App {
    @State private var themeManager = ThemeManager()

    var body: some Scene {
        Window("Maugham — Welcome", id: "welcome") {
            WelcomeHost()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") {
                    NotificationCenter.default.post(name: .maughamNewProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Project…") {
                    NotificationCenter.default.post(name: .maughamOpenProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }

        WindowGroup(id: "project", for: URL.self) { $url in
            if let url {
                ProjectWindow(url: url)
                    .navigationTitle(url.lastPathComponent)
                    .environment(themeManager)
            } else {
                Text("No project URL").foregroundStyle(.secondary)
            }
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(themeManager)
        }
    }
}

private struct WelcomeHost: View {
    @Environment(\.openWindow) private var openWindow
    @State private var recents = RecentsStore()
    @State private var showingNewProject = false

    var body: some View {
        WelcomeView(
            recents: recents.recents,
            onNewProject: { showingNewProject = true },
            onOpenProject: openViaPanel,
            onOpenRecent: open,
            onForgetRecent: { recents.remove($0) }
        )
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet(onCreated: open)
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamNewProject)) { _ in
            showingNewProject = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .maughamOpenProject)) { _ in
            openViaPanel()
        }
    }

    @MainActor
    private func open(_ url: URL) {
        recents.record(url)
        openWindow(id: "project", value: url)
    }

    @MainActor
    private func openViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose a Maugham project folder."
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }
}
