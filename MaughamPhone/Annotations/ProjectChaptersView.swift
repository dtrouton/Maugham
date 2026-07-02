import SwiftUI
import MaughamCore

/// Drill-down middle level: a project's chapters/pieces with notes, as a flat
/// list in binder order, sectioned under each chapter's parent-group title.
/// `project.chapters` is already filtered to the current mode by the caller.
/// Row taps push `ChapterAnnotationsView`. No parsing in a row body (tripwire 4).
@MainActor
struct ProjectChaptersView: View {
    let project: ProjectAnnotations
    let recents: RecentsTracker
    let mode: AnnotationsMode
    var onResolved: () -> Void = {}

    /// Chapters grouped into ordered (header, chapters) sections, preserving
    /// binder order. Computed once, not per row.
    private var sections: [(header: String?, chapters: [ChapterAnnotations])] {
        var out: [(String?, [ChapterAnnotations])] = []
        for chapter in project.chapters {
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
                                projectId: project.id,
                                projectURL: project.projectURL,
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
        .navigationTitle(project.projectName)
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
