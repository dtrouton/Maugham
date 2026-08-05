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
            MaughamEvent.post(.maughamAppWillTerminate, to: .allWindows)
            // Synchronously remove the MCP socket file. The async server stop()
            // (via .maughamAppWillTerminate → WelcomeHost) often does NOT run
            // before macOS kills the process on quit, which leaves a stale
            // socket that makes the next launch look "not running" until its
            // own unlink-before-bind clears it (and confuses a reconnecting
            // bridge). unlink() is a fast syscall and willTerminate is on the
            // main thread, so do it here, guaranteed, before we die.
            unlink(BuildVariant.current.mcpSocketPath)
            // If a verified update was staged and the user dismissed the toast,
            // apply it silently now (no relaunch). willTerminate runs on the main
            // thread, so assumeIsolated is safe.
            MainActor.assumeIsolated {
                if let pending = UpdateChecker.shared.pendingQuitInstall,
                   pending.bundleURL.pathExtension == "app" {
                    let launched = UpdateInstaller.launchSwapHelper(
                        stagedBundle: pending.bundleURL, relaunch: false)
                    if !launched {
                        // Mirror installNow's live Finder-fallback: the app is
                        // already quitting, so defer the reveal to next launch
                        // rather than dropping the failure silently.
                        PendingUpdateReveal.markPending(bundleURL: pending.bundleURL)
                    }
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
                    // A prior quit staged an update but couldn't launch the
                    // swap helper (install location went unwritable, python3
                    // vanished, etc.) — the app was already tearing down, so
                    // the Finder-reveal fallback was deferred to this launch.
                    if let pendingReveal = PendingUpdateReveal.consumePending() {
                        NSWorkspace.shared.activateFileViewerSelecting([pendingReveal])
                    }
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
                .onGlobalEvent(.maughamAppWillTerminate) { _ in
                    Task { await mcpServer?.stop() }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            UpdateMenuCommand()
            CommandGroup(replacing: .newItem) {
                Button("New Project…") {
                    MaughamEvent.post(.maughamNewProject, to: .allWindows)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Project…") {
                    MaughamEvent.post(.maughamOpenProject, to: .allWindows)
                }
                .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    OpenRecentSubmenu(recents: recents)
                }
                Divider()
                Button("Save") {
                    MaughamEvent.post(.maughamDummySave, to: .keyWindow)
                    MaughamEvent.post(.maughamSaveCheckpoint, to: .keyWindow)
                }
                .keyboardShortcut("s", modifiers: .command)
                Button("Save Checkpoint As…") {
                    MaughamEvent.post(.maughamNamedCheckpoint, to: .keyWindow)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                // The compiler's one trigger (spec §3.1). Plain ⌘R, verified
                // unbound 2026-08-04: the two other "r" bindings carry ⌘⌥⇧
                // (Toggle Review Mode) and ⌘⌥ (Research pane). Beside Save
                // because it acknowledges in Save's register — a sub-second
                // flash and nothing else.
                Button("Check Writing") {
                    MaughamEvent.postCompilerRun()
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                FocusedRestoreButton()
                Divider()
                Button("Tidy All Filenames") {
                    MaughamEvent.post(.maughamTidyAllFilenames, to: .keyWindow)
                }
                Button("Add Research File…") {
                    MaughamEvent.post(.maughamAddResearchFile, to: .keyWindow)
                }
                FocusedPromoteButton()
                Divider()
                Button("Show Project Statistics") {
                    MaughamEvent.post(.maughamShowProjectStatistics, to: .keyWindow)
                }
                Divider()
                Button("New Prose Story") {
                    MaughamEvent.post(.maughamAddLoosePiece, to: .keyWindow)
                }
                Button("New Screenplay (Collection)") {
                    MaughamEvent.post(.maughamAddScreenplayPiece, to: .keyWindow)
                }
                Button("Link Existing Project…") {
                    MaughamEvent.post(.maughamLinkProject, to: .keyWindow)
                }
                Divider()
                FocusedShareForReviewButton()
                Button("Project Settings…") {
                    MaughamEvent.post(.maughamShowProjectSettings, to: .keyWindow)
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            }
            // Augment the existing View menu (which AppKit auto-creates when
            // NavigationSplitView is in use) rather than creating a second one
            // via CommandMenu("View").
            CommandGroup(after: .toolbar) {
                Button("Plan") { postPersona(.plan) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Author") { postPersona(.author) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Review") { postPersona(.review) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Publish") { postPersona(.publish) }
                    .keyboardShortcut("4", modifiers: .command)

                Divider()
                Button("Toggle Focus Mode") {
                    MaughamEvent.post(.maughamToggleNoChrome, to: .keyWindow)
                }
                .keyboardShortcut("\\", modifiers: .command)
                Button("Toggle Review Mode") {
                    MaughamEvent.post(.maughamToggleReviewMode, to: .keyWindow)
                }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
                FocusedTranslationReviewButton()
                Button("Toggle Full-Screen Focus") {
                    MaughamEvent.post(.maughamToggleFullScreen, to: .keyWindow)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Toggle Inspector") {
                    MaughamEvent.post(.maughamToggleInspector, to: .keyWindow)
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                Button("Toggle Research Preview") {
                    MaughamEvent.post(.maughamToggleResearchPreview, to: .keyWindow)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()

                // Right-pane segments — one button per `DetailSegment` case,
                // declared here rather than on the Picker in DetailPaneToggle
                // so every one reveals a hidden inspector column
                // (SessionAndNavigationModifier sets showInspector = true).
                // Splitting these across two dispatch paths meant ⌘⌥4–8
                // silently no-opped with the column closed.
                Button("Inspector") { postSegment(.inspector) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Research") { postSegment(.research) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Outline") { postSegment(.outline) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Annotations") { postSegment(.annotations) }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Button("History") { postSegment(.history) }
                    .keyboardShortcut("h", modifiers: [.command, .option])
                Button("Tasks") { postSegment(.tasks) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Inbox") { postSegment(.inbox) }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Button("Palette") { postSegment(.palette) }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Translation") { postSegment(.translation) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                // ⌘⌥I is the Inspector's, so Intent takes the next letter in
                // its own name — the same stretch ⌘⌥B (inBox) and ⌘⌥L
                // (transLation) already make.
                Button("Intent") { postSegment(.intent) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Visual Language") { postSegment(.visualLanguage) }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                Button("Diagnostics") { postSegment(.diagnostics) }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                #if MAUGHAM_DEV_BUILD
                // Scene-storage spike instrument (ADR 0021): logs how many
                // EditorCoordinators are still alive. Close a project window,
                // then click this — live→0 means SwiftUI released the scene
                // graph; live staying >0 is the documented framework retention.
                // See docs/superpowers/notes/2026-07-02-scene-storage-spike.md.
                Divider()
                Button("Dump Coordinator Leak Probe (dev)") {
                    CoordinatorLeakProbe.dump()
                }
                #endif
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
                    MaughamEvent.post(.maughamFindInProject, to: .keyWindow)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Restore Last Deleted Item") {
                    MaughamEvent.post(.maughamRestoreLastDeleted, to: .keyWindow)
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

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsWindow()
        }
        .windowResizability(.contentMinSize)
    }

    /// The View menu's way of asking for a segment, so its items can't drift
    /// apart — and, since M1A gave the inspector one too, a thin call onto
    /// `MaughamEvent.postDetailSegment(_:)`, which is where the payload and the
    /// `.keyWindow` scope are spelled. Kept as a local name because
    /// `PersonaKeyspaceTests` reads `postSegment(.<segment>)` out of this file
    /// to prove every segment has a menu item.
    private func postSegment(_ segment: DetailSegment) {
        MaughamEvent.postDetailSegment(segment)
    }

    /// Mirrors `postSegment(_:)`. `.keyWindow` scope: only the focused
    /// project window switches, so two windows keep independent personas.
    private func postPersona(_ persona: Persona) {
        MaughamEvent.post(.maughamSetPersona,
                          to: .keyWindow,
                          payload: [MaughamEvent.personaKey: persona.rawValue])
    }

    @MainActor
    private static func registerTools(router: MCPRouter, registry: ProjectRegistry) {
        // Tool catalog — derived from MCPToolCatalog.all (single source of truth).
        // Adding a tool: implement MCPTool on it and add to MCPToolCatalog.all.
        MCPToolCatalog.register(router: router, registry: registry)

        #if MAUGHAM_DEV_BUILD
        // Dev-only privileged test tools for Claude Code (absent from stable).
        TestMCPToolCatalog.register(router: router, registry: registry)
        #endif

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

        // SEP-2640 skills extension — protocol methods (not tools; the tool
        // count is unaffected). Method names contain `/`, so they can't
        // collide with tool names. See Maugham/MCP/SkillsExtension.swift.
        router.register(method: SkillsExtension.listMethod) { params in
            try SkillsExtension.handleList(paramsJSON: params, index: try SkillIndex.bundled())
        }
        router.register(method: SkillsExtension.getMethod) { params in
            try SkillsExtension.handleGet(paramsJSON: params, index: try SkillIndex.bundled())
        }
        router.register(method: SkillsExtension.readMethod) { params in
            try SkillsExtension.handleRead(paramsJSON: params, index: try SkillIndex.bundled())
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

/// Whether the focused window's canvas has something to promote. Published by
/// `CanvasPromotionModifier`; read only by the File-menu item, so a `Promote…`
/// that could do nothing is disabled rather than silently no-op.
struct FocusedCanvasPromotionKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var canvasPromotable: Bool? {
        get { self[FocusedCanvasPromotionKey.self] }
        set { self[FocusedCanvasPromotionKey.self] = newValue }
    }
}

/// File → "Promote…". Acts on the canvas's current selection; the focused
/// window resolves what that is, exactly as the Share and Translation items do.
private struct FocusedPromoteButton: View {
    @FocusedValue(\.canvasPromotable) private var promotable
    var body: some View {
        Button("Promote…") {
            MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
        }
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .disabled(promotable != true)
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

/// File → "Share for Review…". Disabled when no project window is focused.
/// The focused `ProjectWindow` handles the actual presentation (iCloud
/// Collaborate share sheet, or the move-to-iCloud explanation) so it can anchor
/// the sheet to its own window and reuse its already-resolved share snapshot.
private struct FocusedShareForReviewButton: View {
    @FocusedValue(\.projectURL) private var projectURL
    var body: some View {
        Button("Share for Review…") {
            MaughamEvent.post(.maughamShareForReview, to: .keyWindow)
        }
        .disabled(projectURL == nil)
    }
}

/// View → "Translation Review…". Disabled when no project window is focused.
/// The app-global menu can't reach the focused window's active-doc selection,
/// so the command just asks the key window to resolve that doc's available
/// languages and present the picker (`TranslationReviewModifier` does the rest).
private struct FocusedTranslationReviewButton: View {
    @FocusedValue(\.projectURL) private var projectURL
    var body: some View {
        Button("Translation Review…") {
            MaughamEvent.post(.maughamShowTranslationPicker, to: .keyWindow)
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
                MaughamEvent.post(.maughamShowHelp, to: .allWindows)
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
                MaughamEvent.post(.maughamShowSyntaxHelp, to: .keyWindow)
            }
            .keyboardShortcut("/", modifiers: .command)
            Button("Set up Claude Desktop…") {
                MaughamEvent.post(.maughamShowClaudeDesktopHelp, to: .keyWindow)
            }
            Divider()
            Button("Acknowledgements") { openWindow(id: "acknowledgements") }
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
        .onGlobalEvent(.maughamNewProject) { _ in
            showingNewProject = true
        }
        .onGlobalEvent(.maughamOpenProject) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                open(url)
            } else {
                openViaPanel()
            }
        }
        .onGlobalEvent(.maughamShowHelp) { _ in
            openWindow(id: "help")
        }
        #if MAUGHAM_DEV_BUILD
        // Dev-only: the test-MCP drive tools post this; reuse the existing
        // open(_:) helper (records in Recents + opens the project window).
        .onGlobalEvent(.maughamTestOpenProject) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            open(url)
        }
        #endif
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
                        MaughamEvent.post(.maughamOpenProject, to: .allWindows, payload: ["url": url])
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
