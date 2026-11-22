import SwiftUI
import MaughamCore
import AppKit

@main
struct MaughamApp: App {
    /// Answers `applicationShouldTerminate`: ⌘Q waits for the stores to
    /// close (`QuitCoordinator`).
    @NSApplicationDelegateAdaptor(MaughamAppDelegate.self) private var appDelegate
    @State private var userPreferences = UserPreferences()
    @State private var backupCoordinator = BackupCoordinator()
    @State private var recents = RecentsStore()
    @State private var mcpRouter = MCPRouter()
    @State private var mcpRegistry: ProjectRegistry
    /// One `ProjectSession` per open project, borrowed by every window on it
    /// (foundations plan 3, Task 3). It announces a project to MCP while a
    /// window is open on it (Task 3b), so it is built on the same registry.
    @State private var projectSessions: ProjectSessionRegistry
    @State private var mcpServer: MCPServer?
    @State private var onboarding = OnboardingModel()

    /// The socket this process binds — the variant's for a writer's launch,
    /// a per-process temp path for a test host. See `TestHost.mcpSocketPath`
    /// for why a gate must never touch the writer's own (2026-09-06).
    private var mcpSocketPath: String {
        TestHost.mcpSocketPath
    }

    init() {
        let mcp = ProjectRegistry()
        _mcpRegistry = State(initialValue: mcp)
        let sessions = ProjectSessionRegistry(mcp: mcp)
        _projectSessions = State(initialValue: sessions)

        // Fail-fast guardrail: if the compile flag and bundle id drift apart
        // (e.g. CI config error), this fires immediately in Debug.
        #if MAUGHAM_DEV_BUILD
        assert(Bundle.main.bundleIdentifier == "com.maugham.Maugham.dev",
               "MAUGHAM_DEV_BUILD set but bundle id is \(Bundle.main.bundleIdentifier ?? "nil")")
        #else
        assert(Bundle.main.bundleIdentifier == "com.maugham.Maugham",
               "MAUGHAM_DEV_BUILD not set but bundle id is \(Bundle.main.bundleIdentifier ?? "nil")")
        #endif

        // A test host keeps out of the Dock and off ⌘-tab — see `TestHost`.
        // Before any window exists, so the policy is in force for the first one.
        TestHost.applyActivationPolicyIfHosting()

        // ⌘Q waits for every open project's stores to close, bounded
        // (`QuitCoordinator`, asked by the delegate before `willTerminate`).
        MaughamAppDelegate.quit = QuitCoordinator(closers: { sessions.quitClosers() })

        // On app termination, tell every window (the services' quit arms,
        // the MCP server's stop). The stores were closed before this, by the
        // quit coordinator.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { _ in
            MaughamEvent.post(.maughamAppWillTerminate, to: .allWindows)
            // Every open project's warm `claude` sessions end here, not only
            // those a mounted window's quit arm reaches: a project a reader
            // (the Statistics window) or a leaked borrow kept open has a
            // roster too, and a session merely released is a live, billing
            // process. willTerminate runs on the main thread.
            MainActor.assumeIsolated {
                sessions.shutdownAll()
            }
            // Synchronously remove the MCP socket file. The async server stop()
            // (via .maughamAppWillTerminate → WelcomeHost) often does NOT run
            // before macOS kills the process on quit, which leaves a stale
            // socket that makes the next launch look "not running" until its
            // own unlink-before-bind clears it (and confuses a reconnecting
            // bridge). unlink() is a fast syscall and willTerminate is on the
            // main thread, so do it here, guaranteed, before we die.
            // The EFFECTIVE path, never the variant's: seven parallel test
            // hosts running this observer against the production path is what
            // deleted the open dev app's socket (TestHost.mcpSocketPath).
            unlink(TestHost.mcpSocketPath)
            // If a verified update was staged and the user dismissed the toast,
            // apply it silently now (no relaunch). willTerminate runs on the main
            // thread, so assumeIsolated is safe.
            MainActor.assumeIsolated {
                if let pending = UpdateChecker.shared.pendingQuitInstall,
                   pending.bundleURL.pathExtension == "app" {
                    let launched = UpdateInstaller.launchSwapHelper(
                        stagedBundle: pending.bundleURL, version: pending.version,
                        updatesDirectory: UpdateChecker.updatesDirectory, relaunch: false)
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
                    // swap helper (install location went unwritable, the swap
                    // tool went missing, etc.) — the app was already tearing down, so
                    // the Finder-reveal fallback was deferred to this launch.
                    if !TestHost.isActive, let pendingReveal = PendingUpdateReveal.consumePending() {
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
                    // Never in a test host: a test that reaches `installNow`
                    // would quit the worker, or show its temp folder in Finder
                    // and take the writer's focus on every gate.
                    if !TestHost.isActive { UpdateChecker.performInstall = { bundleURL, version, relaunch in
                        if bundleURL.pathExtension == "app",
                           UpdateInstaller.launchSwapHelper(
                               stagedBundle: bundleURL, version: version,
                               updatesDirectory: UpdateChecker.updatesDirectory, relaunch: relaunch) {
                            MaughamAppDelegate.requestQuit()  // never terminate from this task; the quit coordinator closes the stores, the helper waits for exit, then swaps
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
                        }
                    } }
                    // The last install's helper may have left a line saying it
                    // was refused or failed (#67 Task 5): read and remove it, and
                    // let the update banner say so once. Before the poll starts,
                    // so a refused version's files are gone before any check. A
                    // test host never touches a real Updates folder.
                    if BuildVariant.current.updaterEnabled, !TestHost.isActive {
                        UpdateChecker.shared.reportInstallStatus(in: UpdateChecker.updatesDirectory)
                        // Then the sweep of old downloads (#67 Task 6), off the
                        // main thread and AFTER the refused-deletion above, so
                        // the two never race.
                        let running = UpdateChecker.shared.runningVersionString
                        let updates = UpdateChecker.updatesDirectory
                        UpdateChecker.shared.sweepAfterStage = { keep in
                            DispatchQueue.global(qos: .utility).async {
                                UpdateSweep.sweep(in: updates, keeping: keep, runningVersion: running,
                                                  includingDownloads: false)
                            }
                        }
                        DispatchQueue.global(qos: .utility).async {
                            UpdateSweep.sweep(in: updates, keeping: nil, runningVersion: running,
                                              includingDownloads: true)
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
                // The compiler's four commands (spec §3.1; shell p1 Task 5).
                // Plain ⌘R, verified unbound 2026-08-04: the two other "r"
                // bindings carry ⌘⌥⇧ (read-through) and ⌘⌥ (Research
                // pane). ⌘⇧R for the cold read, verified unbound 2026-08-15
                // against the same three. ⌃⌘R and ⌃⇧⌘R for the round's two,
                // verified unbound 2026-11-17 across `Maugham/` (no other
                // `.control` "r" chord; the figure grid's own ⌘R key handler
                // matches plain ⌘ only). Beside Save because a run
                // acknowledges in Save's register — a sub-second flash and
                // nothing else.
                //
                // **Four commands, each naming its kind** (`RunCommand`): what
                // Run means is the command's, never the window's. ⌘R is a check
                // wherever the writer stands; a round is asked for by name.
                RunButtons()
                Divider()
                FocusedRestoreButton()
                Divider()
                Button("Tidy All Filenames") {
                    MaughamEvent.post(.maughamTidyAllFilenames, to: .keyWindow)
                }
                Button("Add Research File…") {
                    MaughamEvent.post(.maughamAddResearchFile, to: .keyWindow)
                }
                // File ▸ Add Language… (shell p4 Task 7 fix round, I1): the
                // Editions `+`'s keyboard path, and the way to a first edition
                // in any book. Plan 5's menu review may move it.
                FocusedAddLanguageButton()
                // File ▸ Remove Edition… (closing round): the selected
                // translated edition, asked first. Plan 5's menu review too.
                FocusedRemoveEditionButton()
                FocusedPromoteButton()
                Divider()
                Button("Show Project Statistics") {
                    MaughamEvent.post(.maughamShowProjectStatistics, to: .keyWindow)
                }
                Divider()
                FocusedStartAPieceButtons()
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
                // The window's toggles first; then the right column's
                // positions, grouped by where each lands; then the tree's
                // places.
                Button("Toggle Focus Mode") {
                    MaughamEvent.post(.maughamToggleNoChrome, to: .keyWindow)
                }
                .keyboardShortcut("\\", modifiers: .command)
                Button("Toggle Full-Screen Focus") {
                    MaughamEvent.post(.maughamToggleFullScreen, to: .keyWindow)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                // ⌘⌥⇧R: the open piece's read-through, titled by its offer.
                FocusedReadThroughItem()
                // A piece read in a language (shell p4 Task 8): View ▸ Read
                // In ▸ …, Read In Next Language (⌃⌘L), Show Source Under
                // Translation — the toolbar switch's other two routes.
                FocusedReadingItems()
                // View ▸ Margin ▸ Off / My Notes / Everything Flagged (shell
                // p5 Task 2): three checked items, no key.
                FocusedMarginItems()
                // ⌘⌥0 shows or hides the right column, titled for the
                // focused window's state (`WindowChrome`).
                FocusedRightColumnToggle()
                Button("Toggle Research Preview") {
                    MaughamEvent.post(.maughamToggleResearchPreview, to: .keyWindow)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()

                // **The right column's keys, declared here and nowhere else**
                // (`RightColumnControl` holds none), so every one reveals a
                // hidden column through the window's one receiver. Grouped by
                // where each lands (appraisal 5): To resolve, Brief, Pull Up,
                // each led by its position's ⌘1/⌘2/⌘3. **The old pane keys
                // keep their letters** (owner, 2026-11-18); each item is
                // titled for what its key does.
                Button("To Resolve") { MaughamEvent.postPosition(.resolve) }
                    .keyboardShortcut("1", modifiers: .command)
                // ⌘⌥D, ⌘⌥A and ⌘⌥T keep their keys (shell plan 2 Task 7):
                // the three panes they opened are To resolve now, so each
                // opens it on the filter that pane was — the check's
                // findings, the rounds' notes, the writer's own to-dos.
                Button("To Resolve: Checks") { MaughamEvent.postResolve(.checks) }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                Button("To Resolve: Rounds") { MaughamEvent.postResolve(.rounds) }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Button("To Resolve: Mine") { MaughamEvent.postResolve(.mine) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                // ⌘⌥L (it was the translation pane's key): To resolve on
                // Questions — a translator's questions, wherever the faces
                // are (shell p4 Task 7, call 8).
                Button("To Resolve: Questions") { MaughamEvent.postResolve(.questions) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                // ⌘⌥K (it was the Department desk's key): the To resolve of
                // the edition the window reads in, else the Source's, its
                // title naming which (`EditionWiring.editionForTheKey`);
                // disabled in a book with no editions. Plan 5's menu review
                // may revisit both.
                FocusedEditionResolveButton()
                Divider()
                Button("Brief") { MaughamEvent.postPosition(.brief) }
                    .keyboardShortcut("2", modifiers: .command)
                // ⌘⌥I (the Inspector's): Brief, with the keys in the line.
                Button("Brief: the Line") { MaughamEvent.postBriefField(.line) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                // ⌘⌥N: Brief, with the keys in Going for. (⌘⌥I was the
                // Inspector's, so Intent took the next letter in its name.)
                Button("Brief: Going For") { MaughamEvent.postBriefField(.goingFor) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Divider()
                Button("Pulled Up") { MaughamEvent.postPosition(.pulledUp) }
                    .keyboardShortcut("3", modifiers: .command)
                // **⌘⌥G, and no letter of "What I've Learned" was available**:
                // L is Translation, E References, A Annotations, N Intent, D
                // Diagnostics, R Research, T Tasks, H History, W and (with ⌥)
                // M are macOS's own Close All and Minimize All. So the letter
                // comes from the writer's word for what it HOLDS, the way
                // ⌘⌥K's came from the department *desk*: the rows are a
                // led**g**er (`RulingsStratumView.title(for:)`). ⌘G and ⌘⇧G
                // are Find Next/Previous and neither takes ⌥.
                Button("Pull Up What I've Learned") { MaughamEvent.postPullUp(.lessons) }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                // **⌘⌥Y**: every letter of "first reader" is bound except S,
                // and S is one ⌥ slip from ⌘S, the checkpoint reflex this app
                // goes out of its way to keep. Y is free across the whole ⌘⌥
                // keyspace (verified 2026-09-05) and takes nothing.
                Button("Pull Up First Reader") { MaughamEvent.postPullUp(.firstReader) }
                    .keyboardShortcut("y", modifiers: [.command, .option])
                Button("Pull Up Visual Language") { MaughamEvent.postPullUp(.visualLanguage) }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                // ⌘⌥H: the faces' piece's History, pulled up — the project's,
                // with no piece faced or open.
                Button("Pull Up History") { MaughamEvent.postPullUp(.historyOfTheFaces) }
                    .keyboardShortcut("h", modifiers: [.command, .option])
                // ⌘[: the system's own Back, free across the app — what was
                // pulled up before goes up again (the pulled-up header's Back).
                FocusedPullUpPreviousButton()
                Divider()
                // The tree's places: the piece's fold, its sections, the Book's
                // view, the Inbox.
                // ⌘⌥E (§6.3 of the redesign: "E references"): what a piece is
                // pinned to is its fold in the tree, so the key opens the
                // faces' piece's fold and scrolls to it.
                FocusedPieceFoldButton()
                // ⌘⌥R re-pointed (shell-finish stage-3a Task 5): Research
                // stopped being a right-pane segment when every tree grew its
                // own Research section (stage 2a) — the shortcut now opens
                // that section rather than a pane.
                Button("Research") {
                    MaughamEvent.post(.maughamRevealResearchSection, to: .keyWindow)
                }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                // ⌘⌥P re-pointed (stage-3a Task 5): same story as Research,
                // for the tree's Palette section.
                Button("Palette") {
                    MaughamEvent.post(.maughamRevealPaletteSection, to: .keyWindow)
                }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                // ⌘⌥O re-pointed (stage-3a Task 5): the outline is now the
                // project row's altitude view (Tasks 1–3) — the shortcut
                // selects that row instead of opening a pane.
                Button("Outline") {
                    MaughamEvent.post(.maughamSelectProjectRow, to: .keyWindow)
                }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                // ⌘⌥B opens the Inbox in the centre, as a click on its tree
                // row does (shell p1 Task 6) — the Inbox is a place, not a pane.
                Button("Inbox") {
                    MaughamEvent.post(.maughamOpenInbox, to: .keyWindow)
                }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Divider()
                // ⌃⌘1/2/3: the centre's view switch (the toolbar's), from
                // the keyboard — disabled where the centre has no views.
                FocusedCentreViewItems()
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
                // **⌘⌥C, for *direCtive*** — every letter of "translator's
                // note" the ⌘⌥ family could use is spoken for (T Tasks, N
                // Intent, R Research, A Annotations, L Translation, O Outline,
                // E References), and C is the first free letter in the word
                // for what the note IS on disk (spec §3).
                Button("Translator\u{2019}s Note\u{2026}") {
                    MaughamEvent.post(.maughamTranslatorsNote, to: .keyWindow)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                // Scoped to the delete ACTION, not to one item (RULING-40), and
                // the label says so.
                Button("Restore Last Deletion") {
                    MaughamEvent.post(.maughamRestoreLastDeleted, to: .keyWindow)
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
            }
            // The app's first `CommandMenu` (plan 3a R-3a-2): report elements
            // written into the manuscript at the caret.
            CommandMenu("Insert") {
                InsertMenuButtons()
            }
            // The expanded table grid's commands (report plan 7c Task 9,
            // R7c-10), in `FigureTableMenu.sections`' order.
            CommandMenu("Format") {
                Menu("Table") {
                    FigureTableMenuButtons()
                }
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
                    .environment(projectSessions)
            } else {
                Text("No project URL").foregroundStyle(.secondary)
            }
        }
        .windowResizability(.contentMinSize)

        WindowGroup("Project Statistics", id: "project-stats", for: URL.self) { $url in
            if let url {
                ProjectStatisticsWindow(projectURL: url)
                    .environment(projectSessions)
            }
        }

        // A table popped out of its card (report plan 7d). Never restored: a
        // relaunch must not bring back a figure window without its project,
        // which it closes with (`FigureWindows`).
        WindowGroup(id: FigureWindowKey.sceneID, for: FigureWindowKey.self) { $key in
            if let key {
                FigureWindow(key: key)
                    .environment(projectSessions)
            }
        }
        .restorationBehavior(.disabled)

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

/// Whether the focused window's posture may start a piece (`.startAPiece`,
/// P3c Task 8 / ruling X). Published by `ProjectWindow.CollectionPieceModifier`
/// — the receiver of the three items it enables; read only by
/// `FocusedStartAPieceButtons`.
struct FocusedMayStartAPieceKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var mayStartAPiece: Bool? {
        get { self[FocusedMayStartAPieceKey.self] }
        set { self[FocusedMayStartAPieceKey.self] = newValue }
    }
}

/// Whether the focused window has a piece whose fold ⌘⌥E can open — the
/// faces' piece, else the open one (`ProjectWindow.foldPiece`). Published by
/// `ResearchRevealModifier`; read only by `FocusedPieceFoldButton`, so the
/// item is disabled, not inert, with no piece.
struct FocusedPieceFoldKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var pieceFoldIsOffered: Bool? {
        get { self[FocusedPieceFoldKey.self] }
        set { self[FocusedPieceFoldKey.self] = newValue }
    }
}

/// Whether the focused window has something pulled up before that still
/// resolves (`PulledUpHistory.offersBack`). Published by
/// `PulledUpHistoryWiring`; read only by View ▸ Back.
struct FocusedPulledUpBackKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var pulledUpBackIsOffered: Bool? {
        get { self[FocusedPulledUpBackKey.self] }
        set { self[FocusedPulledUpBackKey.self] = newValue }
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

/// Whether the focused window's editor may take an inserted report element
/// (`InsertMenuGate`, plan 3a Task 4). Published by
/// `EditorControlMirrorModifier`; read only by `InsertMenuButtons`.
struct FocusedMayInsertReportElementKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var mayInsertReportElement: Bool? {
        get { self[FocusedMayInsertReportElementKey.self] }
        set { self[FocusedMayInsertReportElementKey.self] = newValue }
    }
}

/// What the focused window's expanded table grid may do (`FigureGridPresence`,
/// report plan 7c Task 9); nil with no grid expanded. Published by
/// `FigureTableMenuModifier`; read only by `FigureTableMenuButtons`.
struct FocusedFigureTableMenuKey: FocusedValueKey { typealias Value = FigureTableMenuState }
extension FocusedValues {
    var figureTableMenu: FigureTableMenuState? {
        get { self[FocusedFigureTableMenuKey.self] }
        set { self[FocusedFigureTableMenuKey.self] = newValue }
    }
}

/// Publishes the window's grid presence to the menu bar — its own view, so
/// a change of the menu's state re-evaluates this body and not the window's
/// (`CanvasPromotionModifier`'s measured reason).
struct FigureTableMenuModifier: ViewModifier {
    let presence: FigureGridPresence
    func body(content: Content) -> some View {
        content.focusedSceneValue(\.figureTableMenu, presence.menu)
    }
}

/// Format ▸ Table: the expanded grid's commands, built from
/// `FigureTableMenu.sections` (the right-click menu's order too), each
/// enabled by the focused window's `FigureTableMenuState` and posted to the
/// key window (`MaughamEvent.postFigureTableCommand`). ⌘⌥↑↓←→ insert a row
/// or column and ⌘D fills down — bound here only (R7c-10: the grid's
/// `keyDown` leaves them to these items, one delivery path). Fill Right has
/// no glyph: ⌘R is File's (Check Writing), and the grid claims it while it
/// has the keys (R7d-1, `FigureGridView.performKeyEquivalent`).
private struct FigureTableMenuButtons: View {
    @FocusedValue(\.figureTableMenu) private var menu
    var body: some View {
        ForEach(Array(FigureTableMenu.sections.enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            ForEach(section, id: \.self) { entry in
                switch entry {
                case .numberFormats:
                    Menu(FigureTableMenu.numberFormatTitle) {
                        ForEach(FigureGridFormatChoice.allCases, id: \.self) { choice in
                            toggle(.format(choice))
                        }
                    }
                    .disabled(menu?.isEnabled(.format(.general)) != true)
                case .sendToResearch:
                    Menu(FigureTableMenu.sendToResearchTitle) {
                        ForEach(FigureTableMenu.sendToResearchCommands, id: \.self) { command in
                            button(command)
                        }
                    }
                    .disabled(menu.map { m in FigureTableMenu.sendToResearchCommands.contains(where: m.isEnabled) } != true)
                case .command(let command):
                    item(command)
                }
            }
        }
    }

    @ViewBuilder
    private func item(_ command: FigureTableCommand) -> some View {
        switch command {
        case .insertRowAbove:
            button(command).keyboardShortcut(.upArrow, modifiers: [.command, .option])
        case .insertRowBelow:
            button(command).keyboardShortcut(.downArrow, modifiers: [.command, .option])
        case .insertColumnLeft:
            button(command).keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        case .insertColumnRight:
            button(command).keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        case .fillDown:
            button(command).keyboardShortcut("d", modifiers: .command)
        case .headerRow, .totalRow:
            toggle(command)
        default:
            button(command)
        }
    }

    private func button(_ command: FigureTableCommand) -> some View {
        Button(command.title) { MaughamEvent.postFigureTableCommand(command) }
            .disabled(menu?.isEnabled(command) != true)
    }

    /// A ticked item: Header Row, Total Row, the active cell's format.
    private func toggle(_ command: FigureTableCommand) -> some View {
        Toggle(command.title, isOn: Binding(
            get: { menu?.isOn(command) == true },
            set: { _ in MaughamEvent.postFigureTableCommand(command) }))
            .disabled(menu?.isEnabled(command) != true)
    }
}

/// Insert → Table, Convert to Table Figure, Footnote, Figure…, Existing Figure…, Citation…,
/// Cross-Reference…
/// (plan 3a R-3a-1, R-3a-2; plan 3b). Each posts a key-window command the
/// manuscript editor answers through Route A, one undo step each. Disabled where the focused window
/// says no (`InsertMenuGate`) — a read-only posture, review mode, translation
/// review, no manuscript in the editor — and with no project window in front.
/// The editor's membrane refuses on its own as well.
private struct InsertMenuButtons: View {
    @FocusedValue(\.mayInsertReportElement) private var mayInsert
    var body: some View {
        let enabled = mayInsert == true
        Button("Table") {
            MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(!enabled)
        // The caret's pipe table becomes a table figure (report plan 7b
        // Task 5); outside a table it does nothing. The editor's right-click
        // menu offers it inside a pipe table too.
        Button("Convert to Table Figure") {
            MaughamEvent.post(.maughamConvertTable, to: .keyWindow)
        }
        .keyboardShortcut("t", modifiers: [.command, .option, .shift])
        .disabled(!enabled)
        Button("Footnote") {
            MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(!enabled)
        // An open panel for images; the picture is copied into the
        // document's research and written as a figure (plan 3a Task 6).
        Button("Figure\u{2026}") {
            MaughamEvent.post(.maughamInsertFigure, to: .keyWindow)
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .disabled(!enabled)
        // A figure the book already has, from a picker (report plan 8b Task
        // 3, D8b-1): an unused one's line placed at the caret; a placed one
        // referred to (`@tbl:…`), never placed twice. No shortcut.
        Button("Existing Figure\u{2026}") {
            MaughamEvent.post(.maughamInsertExistingFigure, to: .keyWindow)
        }
        .disabled(!enabled)
        Divider()
        // References from the project (plan 3b): each writes its trigger at
        // the caret and opens the editor's picker on it.
        Button("Citation\u{2026}") {
            MaughamEvent.post(.maughamInsertCitation, to: .keyWindow)
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(!enabled)
        Button("Cross-Reference\u{2026}") {
            MaughamEvent.post(.maughamInsertCrossReference, to: .keyWindow)
        }
        .keyboardShortcut("x", modifiers: [.command, .shift])
        .disabled(!enabled)
    }
}

/// File → the compiler's four commands (`RunCommand`), each posting its own
/// kind. Fixed titles: nothing here reads the focused window. Deliberately NOT
/// `.disabled`: a run with no project window in front is already a no-op at
/// the receiver, and greying the items out would make the writer's own muscle
/// memory look broken while a sheet or the Welcome window held focus.
private struct RunButtons: View {
    var body: some View {
        Button(RunCommand.checkWriting.title) {
            MaughamEvent.postRun(.checkWriting)
        }
        .keyboardShortcut("r", modifiers: .command)
        Button(RunCommand.reread.title) {
            MaughamEvent.postRun(.reread)
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        Button(RunCommand.runRound.title) {
            MaughamEvent.postRun(.runRound)
        }
        .keyboardShortcut("r", modifiers: [.command, .control])
        Button(RunCommand.freshEyes.title) {
            MaughamEvent.postRun(.freshEyes)
        }
        .keyboardShortcut("r", modifiers: [.command, .control, .shift])
    }
}

/// File → New Prose Story / New Screenplay / Link Existing Project — each adds a
/// piece, so each is DISABLED (the menu bar's convention; the tree's own + is
/// hidden) where the focused window's posture refuses `.startAPiece` (P3c Task
/// 8, controller ruling X). The receiver refuses with a notice if a post
/// arrives anyway (`StartAPieceDoor.admits`).
private struct FocusedStartAPieceButtons: View {
    @FocusedValue(\.mayStartAPiece) private var mayStartAPiece
    var body: some View {
        let enabled = StartAPieceDoor.menuIsEnabled(mayStartAPiece: mayStartAPiece)
        Button("New Prose Story") {
            MaughamEvent.post(.maughamAddLoosePiece, to: .keyWindow)
        }
        .disabled(!enabled)
        Button("New Screenplay (Collection)") {
            MaughamEvent.post(.maughamAddScreenplayPiece, to: .keyWindow)
        }
        .disabled(!enabled)
        Button("Link Existing Project…") {
            MaughamEvent.post(.maughamLinkProject, to: .keyWindow)
        }
        .disabled(!enabled)
    }
}

/// **View ▸ Start Read-through / Resume Writing (⌘⌥⇧R)**, titled by the key
/// window's offer and disabled without an enabled one — so the key stays
/// discoverable where no piece is open, and never posts what the offer
/// refuses (a piece read in a translation, a posture that may not write).
struct FocusedReadThroughItem: View {
    @FocusedValue(\.readThroughOffer) private var offer

    var body: some View {
        Button(offer?.menuTitle ?? ReadThroughOffer.startTitle) {
            if let request = offer?.toggleRequest { ReadThrough.post(request) }
        }
        .keyboardShortcut("r", modifiers: [.command, .option, .shift])
        .disabled(offer?.toggleRequest == nil)
        .help(offer?.reason ?? "")
    }
}


/// **What the View menu titles its window toggle by** (appraisal 5):
/// whether the focused window's right column is shown. Published by
/// `ProjectWindow.TopChromeModifier`; read only by `FocusedRightColumnToggle`.
struct WindowChrome: Equatable {
    let rightColumnShown: Bool
}

struct FocusedWindowChromeKey: FocusedValueKey { typealias Value = WindowChrome }
extension FocusedValues {
    var windowChrome: WindowChrome? {
        get { self[FocusedWindowChromeKey.self] }
        set { self[FocusedWindowChromeKey.self] = newValue }
    }
}

/// View → "Hide Right Column" / "Show Right Column" (⌘⌥0): the column To
/// resolve, Brief and the pulled-up thing share (it was "Toggle Inspector",
/// for a panel that no longer exists). Titled for what a press does.
private struct FocusedRightColumnToggle: View {
    @FocusedValue(\.windowChrome) private var chrome
    var body: some View {
        Button(RightColumn.toggleTitle(shown: chrome?.rightColumnShown ?? true)) {
            MaughamEvent.post(.maughamToggleInspector, to: .keyWindow)
        }
        .keyboardShortcut("0", modifiers: [.command, .option])
    }
}

/// View → "Open the Piece's Fold" (⌘⌥E): what a piece is pinned to is its
/// fold in the tree. DISABLED (the menu bar's convention) where the focused
/// window has no piece in its faces or its centre.
/// View ▸ Back (⌘[): disabled with nothing to go back to.
private struct FocusedPullUpPreviousButton: View {
    @FocusedValue(\.pulledUpBackIsOffered) private var offered
    var body: some View {
        Button(BesideHeader.backMenuTitle) { MaughamEvent.postPullUpPrevious() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(offered != true)
    }
}

/// File ▸ Add Language…: enabled where the focused window may add one
/// (`EditionWiring` publishes `EditionCastVerbs.mayAddLanguage`).
private struct FocusedAddLanguageButton: View {
    @FocusedValue(\.mayAddLanguage) private var mayAdd
    var body: some View {
        Button(EditionCastVerbs.addLanguageTitle) { MaughamEvent.postAddLanguage() }
            .disabled(mayAdd != true)
    }
}

/// File ▸ Remove Edition…: enabled where the focused window has a translated
/// edition selected and may add one (`EditionWiring.editionToRemove`).
private struct FocusedRemoveEditionButton: View {
    @FocusedValue(\.removableEdition) private var language
    var body: some View {
        Button(EditionCastVerbs.removeEditionTitle) {
            if let language { MaughamEvent.postRemoveEdition(language) }
        }
        .disabled(language == nil)
    }
}

/// View ▸ ⌘⌥K: titled for the edition it shows, disabled with none.
private struct FocusedEditionResolveButton: View {
    @FocusedValue(\.editionKeyTitle) private var title
    var body: some View {
        Button(title ?? EditionWiring.keyTitleWithNoEdition) { MaughamEvent.postShowEditionResolve() }
            .keyboardShortcut("k", modifiers: [.command, .option])
            .disabled(title == nil)
    }
}

private struct FocusedPieceFoldButton: View {
    @FocusedValue(\.pieceFoldIsOffered) private var offered
    var body: some View {
        Button("Open the Piece's Fold") { MaughamEvent.postShowPieceFold() }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(offered != true)
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

/// File → "Share Project via iCloud…". Disabled when no project window is focused.
/// The focused `ProjectWindow` handles the actual presentation (iCloud
/// Collaborate share sheet, or the move-to-iCloud explanation) so it can anchor
/// the sheet to its own window and reuse its already-resolved share snapshot.
private struct FocusedShareForReviewButton: View {
    @FocusedValue(\.projectURL) private var projectURL
    var body: some View {
        Button("Share Project via iCloud…") {
            MaughamEvent.post(.maughamShareForReview, to: .keyWindow)
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
                Button(ProjectKindName.of(ProjectType.novel)) {
                    onboarding.sampleRequested = .novel
                    openWindow(id: "welcome")
                }
                Button(ProjectKindName.of(ProjectType.screenplay)) {
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
