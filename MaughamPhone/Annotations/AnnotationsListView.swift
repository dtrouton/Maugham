import SwiftUI
import MaughamCore

/// Annotations-tab root: the Projects level of a project → chapter → notes
/// drill-down, behind the optional Face ID gate. Heavy work lives in
/// `AnnotationsStore` (load + group once); this view renders mode-filtered
/// projects only. A global Open/All control reveals resolved notes for review.
/// Tapping a project pushes its chapters, or — when a project has exactly one
/// chapter visible in the current mode — skips straight to that chapter's notes.
@MainActor
struct AnnotationsListView: View {
    let projectsBrowser: ProjectsBrowser
    let downloads: DownloadCoordinator
    let recents: RecentsTracker
    let authGate: LaunchAuthGate

    @State private var store: AnnotationsStore
    @State private var mode: AnnotationsMode = .open
    /// Bumped by a detail view after it resolves an annotation, so the store
    /// reloads and counts recompute at every level.
    @State private var resolveTick = 0

    init(projectsBrowser: ProjectsBrowser, downloads: DownloadCoordinator, recents: RecentsTracker, authGate: LaunchAuthGate) {
        self.projectsBrowser = projectsBrowser
        self.downloads = downloads
        self.recents = recents
        self.authGate = authGate
        _store = State(initialValue: AnnotationsStore(
            projectsBrowser: projectsBrowser, downloads: downloads, recents: recents))
    }

    /// Projects visible in the current mode, chapters pre-filtered.
    private var visibleProjects: [ProjectAnnotations] {
        AnnotationLoading.visibleProjects(store.projects, mode: mode)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Annotations")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Scope", selection: $mode) {
                            ForEach(AnnotationsMode.allCases, id: \.self) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                    }
                }
                .onChange(of: resolveTick) { _, _ in
                    Task { if authGate.isUnlocked { await store.reload() } }
                }
                .task {
                    await authGate.evaluate()
                    if authGate.isUnlocked { await store.loadIfNeeded() }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !authGate.isUnlocked {
            unlockScreen
        } else if store.isLoading && !store.didLoad {
            ProgressView("Loading annotations…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleProjects.isEmpty {
            emptyState
        } else {
            projectList
        }
    }

    // MARK: - Unlock gate

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
                        if authGate.isUnlocked { await store.loadIfNeeded() }
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
            mode == .open ? "No open annotations" : "No annotations",
            systemImage: "checkmark.bubble",
            description: Text(mode == .open
                ? "Claude hasn’t left any open notes, or they’re all resolved."
                : "Claude hasn’t left any notes in your projects yet."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - The project list

    private var projectList: some View {
        List {
            if store.banner != .none {
                Section { bannerRow }
            }
            ForEach(recentSection) { project in
                projectRow(project)
            }
            .modifier(SectionHeaderIfPresent(title: recentSection.isEmpty ? nil : "Recent"))
            ForEach(otherSection) { project in
                projectRow(project)
            }
            .modifier(SectionHeaderIfPresent(title: otherSection.isEmpty ? nil : "Other projects"))
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.reload() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A project row whose destination skips the chapters level when only one
    /// chapter is visible in the current mode.
    @ViewBuilder
    private func projectRow(_ project: ProjectAnnotations) -> some View {
        NavigationLink {
            destination(for: project)
        } label: {
            ProjectSummaryRow(project: project, mode: mode)
        }
    }

    @ViewBuilder
    private func destination(for project: ProjectAnnotations) -> some View {
        if project.chapters.count == 1, let only = project.chapters.first {
            ChapterAnnotationsView(
                chapter: only,
                projectId: project.id,
                projectURL: project.projectURL,
                recents: recents,
                mode: mode,
                onResolved: { resolveTick &+= 1 })
        } else {
            ProjectChaptersView(
                project: project,
                recents: recents,
                mode: mode,
                onResolved: { resolveTick &+= 1 })
        }
    }

    @ViewBuilder
    private var bannerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: bannerIcon)
                .foregroundStyle(.secondary)
            Text(store.banner.text)
                .font(.callout)
            Spacer()
            switch store.banner {
            case .needsDownload:
                Button("Sync now") { Task { await store.reload() } }
                    .font(.callout)
            case .failed:
                Button("Retry") { Task { await store.reload() } }
                    .font(.callout)
            case .syncing, .none:
                EmptyView()
            }
        }
    }

    private var bannerIcon: String {
        switch store.banner {
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .needsDownload: return "icloud.and.arrow.down"
        case .failed: return "exclamationmark.icloud"
        case .none: return "icloud"
        }
    }

    // MARK: - Sectioning (Recent vs Other), preserved from the flat list

    private var recentSection: [ProjectAnnotations] {
        let recentIds = recents.recents
        return visibleProjects.filter { recentIds.contains($0.id) }
    }

    private var otherSection: [ProjectAnnotations] {
        let recentIds = recents.recents
        return visibleProjects.filter { !recentIds.contains($0.id) }
    }
}

/// Applies a `Section` header to a `ForEach` only when a title is present, so an
/// empty Recent/Other bucket contributes no stray header.
private struct SectionHeaderIfPresent: ViewModifier {
    let title: String?
    func body(content: Content) -> some View {
        if let title {
            Section(header: Text(title)) { content }
        } else {
            content
        }
    }
}

/// One project row: name + open count, plus a muted "+N resolved" in All mode.
private struct ProjectSummaryRow: View {
    let project: ProjectAnnotations
    let mode: AnnotationsMode

    var body: some View {
        HStack {
            Text(project.projectName)
            Spacer()
            Text("\(project.openCount)")
                .foregroundStyle(.secondary)
            if mode == .all && project.resolvedCount > 0 {
                Text("+\(project.resolvedCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Pure SF-Symbol mapping for annotation kinds — shared by the drill-down rows.
/// Delegates to `AnnotationKind.systemImageName` (MaughamCore), the single source
/// of truth shared with the Mac surface.
enum AnnotationsIcons {
    static func kindSymbol(_ kind: AnnotationKind) -> String {
        kind.systemImageName
    }
}
