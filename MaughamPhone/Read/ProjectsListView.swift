import SwiftUI
import MaughamCore

/// Read-tab root: a `NavigationStack` listing every discovered project, each
/// pushing its `BinderView`. Standalone-constructible (E.4 wires it into the
/// app TabView); this view does not own the TabView itself.
struct ProjectsListView: View {
    let projectsBrowser: ProjectsBrowser
    let projectsRoot: ProjectsRoot
    let downloads: DownloadCoordinator
    let recents: RecentsTracker

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Projects")
                // Refresh-on-appear (carry-forward fix): a project added on the
                // Mac since cold-launch won't be in the listing yet. Re-enumerate
                // whenever we have a working root.
                .task { await refresh() }
                .refreshable { await refresh() }
        }
    }

    private func refresh() async {
        guard let root = projectsRoot.rootURL else { return }
        await projectsBrowser.refresh(root: root)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError = projectsBrowser.loadError {
            // The root itself couldn't be enumerated (bad bookmark / evicted).
            ContentUnavailableView {
                Label("Couldn’t read your projects folder", systemImage: "folder.badge.questionmark")
            } description: {
                Text(loadError)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if projectsBrowser.projects.isEmpty {
            emptyState
        } else {
            projectList
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if projectsRoot.rootURL == nil {
            // No folder chosen yet — point the writer at Settings.
            ContentUnavailableView {
                Label("No projects folder", systemImage: "folder.badge.plus")
            } description: {
                Text("Choose a projects folder in Settings to start reading.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Root is set but holds no projects.
            ContentUnavailableView {
                Label("No projects found", systemImage: "tray")
            } description: {
                Text("Nothing in your projects folder yet. Pull down to refresh.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var projectList: some View {
        List(projectsBrowser.projects) { project in
            NavigationLink {
                BinderView(project: project, downloads: downloads, recents: recents)
            } label: {
                ProjectRow(
                    project: project,
                    failure: projectsBrowser.failures[project.url])
            }
        }
        // Empty-state framing is on the branches above; the populated list fills
        // naturally.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One project row: form icon + title, with a best-effort "couldn't load"
/// caption if its manifest partially failed on the last refresh.
private struct ProjectRow: View {
    let project: BrowsedProject
    let failure: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ReadIcons.projectSymbol(project.manifest.type))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.manifest.title)
                if let failure {
                    Text("Couldn’t fully load: \(failure)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}
