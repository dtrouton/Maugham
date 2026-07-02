import SwiftUI
import MaughamCore

/// Drill-down middle level: a project's chapters/pieces with notes, as a flat
/// list in binder order, sectioned under each chapter's parent-group title.
/// `project.chapters` is already filtered to the current mode by the caller.
/// Row taps push `ChapterAnnotationsView`. No parsing in a row body (tripwire 4).
@MainActor
struct ProjectChaptersView: View {
    let project: ProjectAnnotations
    /// The shared store, so this middle level re-slices its project live on
    /// reload — mid-stack counts refresh after a resolve instead of going stale
    /// until you pop to root. `@Observable`, so reading `store.projects` in the
    /// body re-renders on reload.
    let store: AnnotationsStore
    let recents: RecentsTracker
    let mode: AnnotationsMode
    var onResolved: () -> Void = {}

    /// Re-slice this project from the store and re-apply the mode filter, so mid-
    /// stack counts refresh after a resolve; falls back to the pushed seed.
    private var liveProject: ProjectAnnotations {
        guard let raw = store.projects.first(where: { $0.id == project.id }) else { return project }
        return ProjectAnnotations(
            id: raw.id, projectName: raw.projectName, projectURL: raw.projectURL,
            chapters: AnnotationLoading.visibleChapters(raw.chapters, mode: mode))
    }

    /// Chapters grouped into ordered (header, chapters) sections, preserving
    /// binder order. Computed once, not per row.
    private var sections: [(header: String?, chapters: [ChapterAnnotations])] {
        var out: [(String?, [ChapterAnnotations])] = []
        for chapter in liveProject.chapters {
            if let last = out.last, last.0 == chapter.groupTitle {
                out[out.count - 1].1.append(chapter)
            } else {
                out.append((chapter.groupTitle, [chapter]))
            }
        }
        return out.map { (header: $0.0, chapters: $0.1) }
    }

    var body: some View {
        List {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Section(header: section.header.map(Text.init)) {
                    ForEach(section.chapters) { chapter in
                        NavigationLink {
                            ChapterAnnotationsView(
                                chapter: chapter,
                                store: store,
                                projectId: liveProject.id,
                                projectURL: liveProject.projectURL,
                                recents: recents,
                                mode: mode,
                                onResolved: onResolved)
                        } label: {
                            ChapterRow(chapter: chapter, mode: mode)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(liveProject.projectName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One chapter row: title + open count, plus a muted "+N resolved" in All mode.
private struct ChapterRow: View {
    let chapter: ChapterAnnotations
    let mode: AnnotationsMode

    var body: some View {
        HStack {
            Text(chapter.chapterTitle)
            Spacer()
            Text("\(chapter.openCount)")
                .foregroundStyle(.secondary)
            if mode == .all && chapter.resolvedCount > 0 {
                Text("+\(chapter.resolvedCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
