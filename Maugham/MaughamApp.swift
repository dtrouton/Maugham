import SwiftUI
import MaughamCore
import AppKit

@main
struct MaughamApp: App {
    @State private var userPreferences = UserPreferences()
    @State private var backupCoordinator = BackupCoordinator()
    @State private var recents = RecentsStore()
    @State private var mcpRouter = MCPRouter()
    @State private var mcpRegistry = ProjectRegistry()
    @State private var mcpServer: MCPServer?
    @State private var onboarding = OnboardingModel()

    private var mcpSocketPath: String {
        BuildVariant.current.mcpSocketPath
    }

    init() {
        // Fail-fast guardrail: if the compile flag and bundle id drift apart
        // (e.g. CI config error), this fires immediately in Debug.
        #if MAUGHAM_DEV_BUILD
        assert(Bundle.main.bundleIdentifier == "com.maugham.Maugham.dev",
               "MAUGHAM_DEV_BUILD set but bundle id is \(Bundle.main.bundleIdentifier ?? "nil")")
        #else
        assert(Bundle.main.bundleIdentifier == "com.maugham.Maugham",
               "MAUGHAM_DEV_BUILD not set but bundle id is \(Bundle.main.bundleIdentifier ?? "nil")")
        #endif

        // Best-effort: post a notification on app termination so any open
        // ProjectWindow can synchronously flush its DocumentStore. This is
        // belt-and-suspenders alongside .onDisappear.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { _ in
            NotificationCenter.default.post(
                name: .maughamAppWillTerminate, object: nil)
            // If a verified update was staged and the user dismissed the toast,
            // apply it silently now (no relaunch). willTerminate runs on the main
            // thread, so assumeIsolated is safe.
            MainActor.assumeIsolated {
                if let pending = UpdateChecker.shared.pendingQuitInstall,
                   pending.bundleURL.pathExtension == "app" {
                    UpdateInstaller.launchSwapHelper(stagedBundle: pending.bundleURL, relaunch: false)
                }
            }
        }
    }

    var body: some Scene {
        Window("Maugham — Welcome", id: "welcome") {
            WelcomeHost()
                .environment(recents)
                .environment(userPreferences)
                .environment(onboarding)
                .task {
                    Self.registerTools(router: mcpRouter, registry: mcpRegistry)
                    let server = MCPServer(
                        socketPath: mcpSocketPath,
                        router: mcpRouter,
                        preferences: userPreferences)
                    do {
                        try await server.start()
                        mcpServer = server
                    } catch {
                        print("MCPServer failed to start: \(error)")
                    }
                    // Wire the real install side-effect: swap the running bundle
                    // via the detached helper and quit (relaunch reopens it); fall
                    // back to revealing the download in Finder if not writable.
                    UpdateChecker.performInstall = { bundleURL, relaunch in
                        if bundleURL.pathExtension == "app",
                           UpdateInstaller.launchSwapHelper(stagedBundle: bundleURL, relaunch: relaunch) {
                            NSApp.terminate(nil)  // willTerminate flushes autosave; helper waits for exit then swaps
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
                        }
                    }
                    // Updater is independent of MCP — start it regardless of whether
                    // the MCP socket bound successfully.
                    UpdateChecker.shared.startBackgroundLoop()

                    // Resolve persisted backup destinations into runnable
                    // security-scoped URLs at launch.
                    backupCoordinator.destinations =
                        BackupCoordinator.resolveDestinations(
                            userPreferences.backupDestinations)
                }
                .onChange(of: userPreferences.backupDestinations) { _, new in
                    backupCoordinator.destinations =
                        BackupCoordinator.resolveDestinations(new)
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .maughamAppWillTerminate)) { _ in
                    Task { await mcpServer?.stop() }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            UpdateMenuCommand()
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
                    NotificationCenter.default.post(
                        name: .maughamSaveCheckpoint, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                Button("Save Checkpoint As…") {
                    NotificationCenter.default.post(
                        name: .maughamNamedCheckpoint, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                FocusedRestoreButton()
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
                Button("New Prose Story") {
                    NotificationCenter.default.post(
                        name: .maughamAddLoosePiece, object: nil)
                }
                Button("New Screenplay (Collection)") {
                    NotificationCenter.default.post(
                        name: .maughamAddScreenplayPiece, object: nil)
                }
                Button("Link Existing Project…") {
                    NotificationCenter.default.post(
                        name: .maughamLinkProject, object: nil)
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
                Button("Annotations") {
                    NotificationCenter.default.post(
                        name: .maughamSetDetailSegment,
                        object: nil,
                        userInfo: ["segment": "annotations"])
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
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
            HelpCommands(onboarding: onboarding)
        }

        WindowGroup(id: "project", for: URL.self) { $url in
            if let url {
                ProjectWindow(url: url)
                    .navigationTitle(url.lastPathComponent)
                    .environment(userPreferences)
                    .environment(backupCoordinator)
                    .environment(recents)
                    .environment(mcpRegistry)
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

        WindowGroup("Restore Backup", id: "backup-restore", for: URL.self) { $projectURL in
            if let projectURL {
                RestoreWindow(projectURL: projectURL)
                    .environment(backupCoordinator)
            } else {
                Text("No project").foregroundStyle(.secondary)
            }
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(userPreferences)
        }

        // "Check for Updates…" surface. Hosted as its own Window because a
        // `.sheet(isPresented:)` attached to a Button inside a `Commands` body
        // has no view-hierarchy host and silently no-ops.
        Window("Check for Updates", id: updateWindowID) {
            UpdateWindowContent()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Maugham Help", id: "help") {
            HelpWindow()
        }
        .windowResizability(.contentMinSize)
    }

    @MainActor
    private static func registerTools(router: MCPRouter, registry: ProjectRegistry) {
        // Tool catalog — derived from MCPToolCatalog.all (single source of truth).
        // Adding a tool: implement MCPTool on it and add to MCPToolCatalog.all.
        MCPToolCatalog.register(router: router, registry: registry)

        // MCP protocol layer — Claude Desktop and other MCP clients require these.
        router.register(method: MCPInitializeHandler.method) { params in
            try await MCPInitializeHandler.handle(paramsJSON: params)
        }
        router.register(method: MCPToolsListHandler.method) { params in
            try await MCPToolsListHandler.handle(paramsJSON: params)
        }
        router.register(method: MCPToolsCallHandler.method) { params in
            try await MCPToolsCallHandler.handle(paramsJSON: params, router: router)
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

/// Focused-value key carrying the URL of the project owning the currently
/// focused window, so window-scoped commands (e.g. File → Restore from Backup…)
/// can target it.
struct FocusedProjectURLKey: FocusedValueKey { typealias Value = URL }
extension FocusedValues {
    var projectURL: URL? {
        get { self[FocusedProjectURLKey.self] }
        set { self[FocusedProjectURLKey.self] = newValue }
    }
}

private struct FocusedRestoreButton: View {
    @FocusedValue(\.projectURL) private var projectURL
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Restore from Backup…") {
            if let projectURL { openWindow(id: "backup-restore", value: projectURL) }
        }
        .disabled(projectURL == nil)
    }
}

/// Help menu. Extracted into a `Commands` type (mirroring `UpdateMenuCommand`)
/// so it can use `@Environment(\.openWindow)` — inline `.commands { }` closures
/// cannot. The Welcome / Sample-Projects items write a shared intent on
/// `OnboardingModel` and then open the singleton Welcome window, so `WelcomeHost`
/// exists to consume the intent even when that window was previously closed.
private struct HelpCommands: Commands {
    let onboarding: OnboardingModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Maugham Help") {
                NotificationCenter.default.post(name: .maughamShowHelp, object: nil)
            }
            .keyboardShortcut("?", modifiers: .command)
            Button("Welcome to Maugham") {
                onboarding.carouselRequested = true
                openWindow(id: "welcome")
            }
            Menu("Sample Projects") {
                Button("Novel") {
                    onboarding.sampleRequested = .novel
                    openWindow(id: "welcome")
                }
                Button("Screenplay") {
                    onboarding.sampleRequested = .screenplay
                    openWindow(id: "welcome")
                }
            }
            Divider()
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
}

private struct WelcomeHost: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(RecentsStore.self) private var recents
    @Environment(UserPreferences.self) private var prefs
    @Environment(OnboardingModel.self) private var onboarding
    @State private var showingNewProject = false
    @State private var showingWelcome = false
    @State private var pendingSampleError: String?

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
        .sheet(isPresented: $showingWelcome) {
            WelcomeCarousel(
                onSampleNovel:      { completeWelcome(); openSample(.novel) },
                onSampleScreenplay: { completeWelcome(); openSample(.screenplay) },
                onNewProject:       { completeWelcome(); showingNewProject = true },
                onSkip:             { completeWelcome() }
            )
        }
        .alert("Couldn’t create sample project",
               isPresented: Binding(
                   get: { pendingSampleError != nil },
                   set: { if !$0 { pendingSampleError = nil } })) {
            Button("OK", role: .cancel) { pendingSampleError = nil }
        } message: {
            Text(pendingSampleError ?? "")
        }
        .onAppear {
            if !prefs.hasCompletedWelcome { showingWelcome = true }
            consumeOnboardingIntent()
        }
        .onChange(of: onboarding.carouselRequested) { _, v in
            if v { consumeOnboardingIntent() }
        }
        .onChange(of: onboarding.sampleRequested) { _, v in
            if v != nil { consumeOnboardingIntent() }
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
        .onReceive(NotificationCenter.default.publisher(for: .maughamShowHelp)) { _ in
            openWindow(id: "help")
        }
    }

    @MainActor private func consumeOnboardingIntent() {
        if onboarding.carouselRequested {
            onboarding.carouselRequested = false
            showingWelcome = true
        }
        if let kind = onboarding.sampleRequested {
            onboarding.sampleRequested = nil
            openSample(kind)
        }
    }

    @MainActor private func completeWelcome() {
        prefs.hasCompletedWelcome = true
        showingWelcome = false
    }

    @MainActor private func openSample(_ kind: SampleProjectBuilder.Kind) {
        Task {
            do {
                let url = try await SampleProjectBuilder.buildInDocuments(kind)
                open(url)   // records in Recents + opens the project window
            } catch {
                pendingSampleError = error.localizedDescription
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
