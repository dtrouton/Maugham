import SwiftUI
import MaughamCore

/// The two computed sections the project picker renders. `recent` is a
/// *highlight* subset (projects the writer has captured into / opened lately)
/// shown above the full list; `all` is the complete matching list. A project in
/// `recent` ALSO appears in `all` — recent is an additional surface, not a
/// removal — so the writer can always find any project alphabetically.
struct ProjectPickerSections: Equatable {
    let recent: [BrowsedProject]
    let all: [BrowsedProject]
}

/// Pure filtering + sectioning for the picker — the one genuinely testable bit
/// of this otherwise-interactive surface.
///
/// - `recent`: projects whose id ∈ `recents`, in the input order (`projects` is
///   already title-sorted by `ProjectsBrowser`), filtered by `query`.
/// - `all`: every project matching `query`, in the input (alpha-by-title) order.
/// - Empty/whitespace `query` → no title filter (everything matches).
///
/// Matching is case-insensitive substring on `manifest.title`. A `recents` id
/// with no corresponding project is simply absent from `recent` (no crash).
func projectPickerSections(
    projects: [BrowsedProject],
    recents: Set<ProjectId>,
    query: String
) -> ProjectPickerSections {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    let matches: (BrowsedProject) -> Bool = { project in
        // Empty query matches everything; otherwise case-insensitive substring.
        trimmed.isEmpty
            || project.manifest.title.range(of: trimmed, options: .caseInsensitive) != nil
    }

    let all = projects.filter(matches)
    // `recent` is a highlight subset of the SAME matched set, so a project never
    // appears in `recent` but absent from `all`.
    let recent = all.filter { recents.contains($0.id) }
    return ProjectPickerSections(recent: recent, all: all)
}

/// Sheet for choosing the capture-target project. Presented (not pushed) so the
/// capture context behind it is preserved. Selecting a row writes
/// `currentProjectId` and dismisses.
struct ProjectPickerSheet: View {
    let projectsBrowser: ProjectsBrowser
    let recents: RecentsTracker

    /// Same key as `CaptureView` — keyed by `ProjectManifest.id` so the choice
    /// survives folder rename/move (recents survive the same way).
    @AppStorage("currentProjectId") private var currentProjectId: String = ""

    @State private var query: String = ""
    @Environment(\.dismiss) private var dismiss

    private var sections: ProjectPickerSections {
        projectPickerSections(
            projects: projectsBrowser.projects,
            recents: recents.recents,
            query: query)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Choose Project")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .searchable(text: $query, prompt: "Search projects")
    }

    @ViewBuilder
    private var content: some View {
        if projectsBrowser.projects.isEmpty {
            // Tripwire 15: empty-state needs both frames so the toolbar doesn't
            // float to the vertical centre.
            ContentUnavailableView(
                "No Projects",
                systemImage: "folder",
                description: Text("Choose your projects folder in Settings — projects in it appear here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            List {
                if !sections.recent.isEmpty {
                    Section("Recent") {
                        ForEach(sections.recent) { row(for: $0) }
                    }
                }
                Section("All Projects") {
                    ForEach(sections.all) { row(for: $0) }
                }
            }
        }
    }

    private func row(for project: BrowsedProject) -> some View {
        Button {
            currentProjectId = project.id
            dismiss()
        } label: {
            HStack {
                Text(project.manifest.title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: project.manifest.type.symbolName)
                    .foregroundStyle(.secondary)
                if project.id == currentProjectId {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

extension ProjectType {
    /// SF Symbol shown dimmed next to a project title in the picker.
    var symbolName: String {
        switch self {
        case .shortStory: return "doc.text"
        case .novel: return "book.closed"
        case .screenplay: return "film"
        case .collection: return "books.vertical"
        }
    }
}
