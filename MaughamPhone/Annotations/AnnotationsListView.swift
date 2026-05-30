import SwiftUI
import MaughamCore

/// Annotations-tab root (Task F.4): lists Claude's still-open annotations across
/// every bookmarked project, recents first, behind the optional Face ID gate.
///
/// Heavy work — enumerate each project's `.maugham/ops/`, fault its op logs in,
/// load + derive — happens once in `.task` and lands in `@State`. The list body
/// only renders already-derived `Annotation` values (tripwire 4: never derive in
/// a row body). Tapping a row pushes a detail placeholder until F.5 supplies the
/// real `AnnotationDetailView`.
@MainActor
struct AnnotationsListView: View {
    let projectsBrowser: ProjectsBrowser
    let downloads: DownloadCoordinator
    let recents: RecentsTracker
    let authGate: LaunchAuthGate

    /// One open annotation plus the docId it came from. The detail view (F.5)
    /// needs the docId to build its `AnnotationWriter` and to re-derive status —
    /// the concatenation in `openAnnotations(for:)` would otherwise lose which
    /// doc each annotation belongs to.
    struct LoadedAnnotation: Identifiable {
        let annotation: Annotation
        let docId: String
        var id: String { annotation.id }
    }

    /// One project's open annotations (each tagged with its docId) plus the
    /// display name and folder URL, for sectioning and for the detail view.
    struct ProjectAnnotations: Identifiable {
        let id: ProjectId
        let projectName: String
        let projectURL: URL
        let annotations: [LoadedAnnotation]
    }

    @State private var loaded: [ProjectAnnotations] = []
    @State private var banner: AnnotationsBanner.Banner = .none
    @State private var isLoading = false
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Annotations")
                // Resolve the gate first; only load the (potentially large) list
                // once we're past it. `evaluate()` is a no-op when Face ID is off.
                .task {
                    await authGate.evaluate()
                    if authGate.isUnlocked { await loadIfNeeded() }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !authGate.isUnlocked {
            unlockScreen
        } else if isLoading && !didLoad {
            ProgressView("Loading annotations…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if totalCount == 0 {
            emptyState
        } else {
            annotationList
        }
    }

    // MARK: - Unlock gate

    /// Shown when the gate is `.locked`/`.evaluating`. A Face ID button re-runs
    /// `evaluate()`; a spinner replaces it while evaluating.
    @ViewBuilder
    private var unlockScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Unlock to triage annotations")
                .font(.headline)
            if authGate.state == .evaluating {
                ProgressView()
            } else {
                Button {
                    Task {
                        await authGate.evaluate()
                        if authGate.isUnlocked { await loadIfNeeded() }
                    }
                } label: {
                    Label("Unlock with Face ID", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state (tripwire 15: both frames)

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            "No open annotations",
            systemImage: "checkmark.bubble",
            description: Text("Claude hasn’t left any open notes, or they’re all resolved."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - The list

    private var annotationList: some View {
        List {
            if banner != .none {
                Section { bannerRow }
            }
            ForEach(recentSection) { section in
                projectSection(section, header: "Recent")
            }
            ForEach(otherSection) { section in
                projectSection(section, header: "Other projects")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await reload() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func projectSection(_ section: ProjectAnnotations, header: String) -> some View {
        Section(header: Text(header)) {
            ForEach(section.annotations) { loaded in
                NavigationLink {
                    AnnotationDetailView(
                        annotation: loaded.annotation,
                        projectId: section.id,
                        projectURL: section.projectURL,
                        docId: loaded.docId,
                        recents: recents)
                } label: {
                    AnnotationRow(annotation: loaded.annotation, projectName: section.projectName)
                }
            }
        }
    }

    /// The §3.13 sync/needs-download/failed banner with its inline action.
    @ViewBuilder
    private var bannerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: bannerIcon)
                .foregroundStyle(.secondary)
            Text(banner.text)
                .font(.callout)
            Spacer()
            switch banner {
            case .needsDownload:
                Button("Sync now") { Task { await reload() } }
                    .font(.callout)
            case .failed:
                Button("Retry") { Task { await reload() } }
                    .font(.callout)
            case .syncing, .none:
                EmptyView()
            }
        }
    }

    private var bannerIcon: String {
        switch banner {
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .needsDownload: return "icloud.and.arrow.down"
        case .failed: return "exclamationmark.icloud"
        case .none: return "icloud"
        }
    }

    // MARK: - Sectioning

    private var totalCount: Int { loaded.reduce(0) { $0 + $1.annotations.count } }

    /// Projects whose id is in the recents set, in load order.
    private var recentSection: [ProjectAnnotations] {
        let recentIds = recents.recents
        return loaded.filter { recentIds.contains($0.id) }
    }

    /// Projects not in recents.
    private var otherSection: [ProjectAnnotations] {
        let recentIds = recents.recents
        return loaded.filter { !recentIds.contains($0.id) }
    }

    // MARK: - Loading

    private func loadIfNeeded() async {
        guard !didLoad, !isLoading else { return }
        await reload()
    }

    /// Full reload: walk every project, load its open annotations, and recompute
    /// the recents' download banner. Off the render path — invoked from `.task`,
    /// the unlock button, or pull-to-refresh only.
    private func reload() async {
        isLoading = true
        defer { isLoading = false; didLoad = true }

        var results: [ProjectAnnotations] = []
        for project in projectsBrowser.projects {
            let anns = await openAnnotations(for: project)
            if !anns.isEmpty {
                results.append(ProjectAnnotations(
                    id: project.id,
                    projectName: project.manifest.title,
                    projectURL: project.url,
                    annotations: anns))
            }
        }
        loaded = results
        await refreshBanner()
    }

    /// Open annotations for one project: enumerate its `.maugham/ops/` filenames,
    /// resolve the distinct doc ids, fault each doc's op-log files in
    /// (best-effort), load + derive, and concatenate.
    private func openAnnotations(for project: BrowsedProject) async -> [LoadedAnnotation] {
        let opsDir = project.url.appendingPathComponent(".maugham/ops", isDirectory: true)
        let filenames = (try? FileManager.default.contentsOfDirectory(atPath: opsDir.path)) ?? []
        let docIds = AnnotationLoading.docIds(inOpsDirectoryFilenames: filenames)
        guard !docIds.isEmpty else { return [] }

        let store = OpLogStore(projectURL: project.url)
        var all: [LoadedAnnotation] = []
        for docId in docIds {
            // Fault each per-device op-log file in before reading: an evicted
            // iCloud file reads as empty bytes with NO error, silently rendering
            // as "no annotations". Best-effort — a failed download just yields
            // whatever bytes are local.
            for url in OpLogStore.opLogFileURLs(forDocId: docId, in: project.url) {
                try? await downloads.ensureDownloaded(url)
            }
            guard let ops = try? await store.load(docId: docId) else { continue }
            // Tag each annotation with its docId so the detail view can build a
            // writer for the right op-log stream.
            all.append(contentsOf: AnnotationLoading.openAnnotations(ops: ops)
                .map { LoadedAnnotation(annotation: $0, docId: docId) })
        }
        return all
    }

    /// Recompute the header banner from the recents' op-log download states.
    /// One representative op-log URL per recent project drives the state (the
    /// project as a whole is "syncing" if any of its logs are).
    private func refreshBanner() async {
        let recentIds = recents.recents
        let recentProjects = projectsBrowser.projects.filter { recentIds.contains($0.id) }
        var states: [DownloadStateLite] = []
        for project in recentProjects {
            states.append(await projectDownloadState(project))
        }
        banner = AnnotationsBanner.banner(forRecentStates: states)
    }

    /// Collapse one project's op-log download states into a single lite state:
    /// downloading if any is in flight, failed if all failed, notDownloaded if
    /// any is still evicted, else downloaded.
    private func projectDownloadState(_ project: BrowsedProject) async -> DownloadStateLite {
        let opsDir = project.url.appendingPathComponent(".maugham/ops", isDirectory: true)
        let filenames = (try? FileManager.default.contentsOfDirectory(atPath: opsDir.path)) ?? []
        let docIds = AnnotationLoading.docIds(inOpsDirectoryFilenames: filenames)

        var urls: [URL] = []
        for docId in docIds {
            urls.append(contentsOf: OpLogStore.opLogFileURLs(forDocId: docId, in: project.url))
        }
        guard !urls.isEmpty else { return .downloaded }  // nothing to sync

        var lites: [DownloadStateLite] = []
        for url in urls {
            // `observe` replays the current state immediately; take that one value.
            for await state in await downloads.observe(url) {
                lites.append(Self.lite(state))
                break
            }
        }
        if lites.contains(.downloading) { return .downloading }
        if lites.allSatisfy({ $0 == .failed }) && !lites.isEmpty { return .failed }
        if lites.contains(.notDownloaded) { return .notDownloaded }
        return .downloaded
    }

    private static func lite(_ state: DownloadCoordinator.DownloadState) -> DownloadStateLite {
        switch state {
        case .notDownloaded: return .notDownloaded
        case .downloading: return .downloading
        case .downloaded: return .downloaded
        case .failed: return .failed
        }
    }
}

/// One annotation row: kind icon + body preview + project name, plus a "stale"
/// chip when the underlying paragraph changed since Claude captured it. Renders
/// only pre-derived values (tripwire 4).
private struct AnnotationRow: View {
    let annotation: Annotation
    let projectName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: AnnotationsIcons.kindSymbol(annotation.kind))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(annotation.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if annotation.isStale {
                        Text("stale")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.yellow.opacity(0.25), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Pure SF-Symbol mapping for annotation kinds — out of the row body so it's
/// trivially testable and the icon vocabulary lives in one place.
enum AnnotationsIcons {
    static func kindSymbol(_ kind: AnnotationKind) -> String {
        switch kind {
        case .comment: return "bubble.left"
        case .suggestedChange: return "pencil.line"
        case .query: return "questionmark.circle"
        case .craftNote: return "lightbulb"
        }
    }
}
