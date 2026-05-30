import SwiftUI
import MaughamCore

/// MaughamPhone — the iOS companion to the Mac writing app.
///
/// Four tabs: Capture (out-and-about text/photo/voice into the project inbox),
/// Read (browse manuscripts + research — Phase E), Annotations (triage Claude's
/// open annotations — Phase F), Settings. Capture + Read + Settings are live;
/// Annotations is a placeholder until Phase F lands.
///
/// This App owns the shared stores and runs the cold-launch download sequence
/// (spec §3.13): resolve the projects-root bookmark, refresh manifests (the
/// "always download" tier), then best-effort prefetch recent projects' op logs
/// within the 50 MB budget so the Annotations tab finds local JSONL.
@main
struct MaughamPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

private struct RootTabView: View {
    enum Tab: Hashable { case capture, read, annotations, settings }
    @State private var selection: Tab = .capture

    // MARK: - Shared stores (single source of truth for the whole app)

    @State private var projectsRoot = ProjectsRoot()
    @State private var recents = RecentsTracker()
    @State private var authGate = LaunchAuthGate()

    // Drives the Annotations-tab re-lock: backgrounding clears the gate's
    // last-unlock so returning to the app re-prompts (spec §3.14).
    @Environment(\.scenePhase) private var scenePhase

    // The DownloadCoordinator is constructed ONCE and shared: the browser faults
    // manifests in through it, and the cold-launch prefetch charges the same
    // 50 MB budget through it. Two coordinators would mean two budgets and no
    // download dedup between the manifest refresh and the op-log prefetch.
    @State private var downloads: DownloadCoordinator
    @State private var projectsBrowser: ProjectsBrowser

    init() {
        let coordinator = DownloadCoordinator(downloader: CoordinatedFileIO.live)
        _downloads = State(initialValue: coordinator)
        _projectsBrowser = State(initialValue: ProjectsBrowser(downloads: coordinator))
    }

    var body: some View {
        TabView(selection: $selection) {
            CaptureView(projectsBrowser: projectsBrowser, recents: recents)
                .tabItem { Label("Capture", systemImage: "plus.circle") }
                .tag(Tab.capture)

            ProjectsListView(
                projectsBrowser: projectsBrowser,
                projectsRoot: projectsRoot,
                downloads: downloads,
                recents: recents)
                .tabItem { Label("Read", systemImage: "book") }
                .tag(Tab.read)

            AnnotationsListView(
                projectsBrowser: projectsBrowser,
                downloads: downloads,
                recents: recents,
                authGate: authGate)
                .tabItem { Label("Annotations", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.annotations)

            SettingsView(projectsRoot: projectsRoot)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // Cold-launch sequence, once per process. `.task` runs on the main actor;
        // the prefetch reads @MainActor snapshots here, then hands plain values
        // to the actor/sync work.
        .task {
            await runLaunchSequence()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { authGate.onBackground() }
        }
    }

    /// Spec §3.13 cold-launch: resolve root → refresh manifests → prefetch recent
    /// op logs. Steps 2/3 are best-effort and must never abort launch.
    private func runLaunchSequence() async {
        projectsRoot.resolveOnLaunch()

        guard let root = projectsRoot.rootURL else { return }

        // Step 1+2: always-download tier — refresh faults + decodes each manifest
        // through the shared coordinator.
        await projectsBrowser.refresh(root: root)

        // Step 3: best-effort op-log prefetch for recent projects. Snapshot the
        // @MainActor state (recents set + project list) on the main actor first,
        // THEN do the per-file size + budgeted-download work (fileSize is sync;
        // the coordinator is an actor we await). Failures never propagate.
        let recentIds = recents.recents
        let recentProjects = projectsBrowser.projects.filter { recentIds.contains($0.id) }
        guard !recentProjects.isEmpty else { return }

        let coldLaunch = ColdLaunchDownloader(downloads: downloads, io: .live)
        await coldLaunch.prefetch(recentProjects: recentProjects)
    }
}
