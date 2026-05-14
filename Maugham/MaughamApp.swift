import SwiftUI
import AppKit

@main
struct MaughamApp: App {
    @State private var userPreferences = UserPreferences()
    @State private var recents = RecentsStore()

    init() {
        // Best-effort: post a notification on app termination so any open
        // ProjectWindow can synchronously flush its DocumentStore. This is
        // belt-and-suspenders alongside .onDisappear.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { _ in
            NotificationCenter.default.post(
                name: .maughamAppWillTerminate, object: nil)
        }
    }

    var body: some Scene {
        Window("Maugham — Welcome", id: "welcome") {
            WelcomeHost()
                .environment(recents)
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
                Menu("Open Recent") {
                    OpenRecentSubmenu(recents: recents)
                }
                Divider()
                Button("Save") {
                    NotificationCenter.default.post(
                        name: .maughamDummySave, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                Divider()
                Button("Tidy All Filenames") {
                    NotificationCenter.default.post(
                        name: .maughamTidyAllFilenames, object: nil)
                }
                Button("Add Research File…") {
                    NotificationCenter.default.post(
                        name: .maughamAddResearchFile, object: nil)
                }
                Divider()
                Button("Show Project Statistics") {
                    NotificationCenter.default.post(
                        name: .maughamShowProjectStatistics, object: nil)
                }
                Divider()
                Button("Project Settings…") {
                    NotificationCenter.default.post(
                        name: .maughamShowProjectSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            }
            // Augment the existing View menu (which AppKit auto-creates when
            // NavigationSplitView is in use) rather than creating a second one
            // via CommandMenu("View").
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Toggle Focus Mode") {
                    NotificationCenter.default.post(
                        name: .maughamToggleNoChrome, object: nil)
                }
                .keyboardShortcut("\\", modifiers: .command)
                Button("Toggle Full-Screen Focus") {
                    NotificationCenter.default.post(
                        name: .maughamToggleFullScreen, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Toggle Inspector") {
                    NotificationCenter.default.post(
                        name: .maughamToggleInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Toggle Research Preview") {
                    NotificationCenter.default.post(
                        name: .maughamToggleResearchPreview, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Inspector") {
                    NotificationCenter.default.post(
                        name: .maughamSetDetailSegment,
                        object: nil,
                        userInfo: ["segment": "inspector"])
                }
                .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Linked Research") {
                    NotificationCenter.default.post(
                        name: .maughamSetDetailSegment,
                        object: nil,
                        userInfo: ["segment": "research"])
                }
                .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Outline") {
                    NotificationCenter.default.post(
                        name: .maughamSetDetailSegment,
                        object: nil,
                        userInfo: ["segment": "outline"])
                }
                .keyboardShortcut("3", modifiers: [.command, .option])
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find\u{2026}") {
                    Self.dispatchFindAction(tag: 1)  // NSFindPanelActionShowFindPanel
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") {
                    Self.dispatchFindAction(tag: 2)  // NSFindPanelActionNext
                }
                .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") {
                    Self.dispatchFindAction(tag: 3)  // NSFindPanelActionPrevious
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button("Find in Project…") {
                    NotificationCenter.default.post(
                        name: .maughamFindInProject, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Restore Last Deleted Item") {
                    NotificationCenter.default.post(
                        name: .maughamRestoreLastDeleted, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .help) {
                Button("Syntax Reference") {
                    NotificationCenter.default.post(
                        name: .maughamShowSyntaxHelp, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
                Button("Set up Claude Desktop…") {
                    NotificationCenter.default.post(
                        name: .maughamShowClaudeDesktopHelp, object: nil)
                }
            }
        }

        WindowGroup(id: "project", for: URL.self) { $url in
            if let url {
                ProjectWindow(url: url)
                    .navigationTitle(url.lastPathComponent)
                    .environment(userPreferences)
                    .environment(recents)
            } else {
                Text("No project URL").foregroundStyle(.secondary)
            }
        }
        .windowResizability(.contentMinSize)

        WindowGroup("Project Statistics", id: "project-stats", for: URL.self) { $url in
            if let url {
                ProjectStatisticsWindow(projectURL: url)
            }
        }

        Settings {
            SettingsView()
                .environment(userPreferences)
        }
    }

    private static func dispatchFindAction(tag: Int) {
        guard let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder else { return }
        let item = NSMenuItem()
        item.tag = tag
        _ = firstResponder.tryToPerform(
            #selector(NSResponder.performTextFinderAction(_:)),
            with: item)
    }
}

private struct WelcomeHost: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(RecentsStore.self) private var recents
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
        .onReceive(NotificationCenter.default.publisher(for: .maughamOpenProject)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                open(url)
            } else {
                openViaPanel()
            }
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

private struct OpenRecentSubmenu: View {
    @Bindable var recents: RecentsStore

    var body: some View {
        Group {
            if recents.recents.isEmpty {
                Text("(No recent projects)")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recents.recents, id: \.path) { url in
                    Button(url.lastPathComponent) {
                        NotificationCenter.default.post(
                            name: .maughamOpenProject,
                            object: nil,
                            userInfo: ["url": url])
                    }
                }
                Divider()
                Button("Clear Recent Projects") {
                    for url in recents.recents { recents.remove(url) }
                }
            }
        }
    }
}
