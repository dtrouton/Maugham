import SwiftUI
import MaughamCore

/// Drill-down leaf: one chapter's notes. `Open` mode shows just the open notes;
/// `All` mode adds a dimmed RESOLVED section with status chips. Every row pushes
/// the unchanged `AnnotationDetailView`; resolved rows are read-only there (its
/// action buttons already hide for non-open annotations). Rows render only
/// pre-derived values (tripwire 4).
@MainActor
struct ChapterAnnotationsView: View {
    let chapter: ChapterAnnotations
    let projectId: ProjectId
    let projectURL: URL
    let recents: RecentsTracker
    let mode: AnnotationsMode
    var onResolved: () -> Void = {}

    var body: some View {
        List {
            Section(header: Text("Open")) {
                if chapter.open.isEmpty {
                    Text("No open notes").foregroundStyle(.secondary)
                } else {
                    ForEach(chapter.open) { loaded in
                        noteLink(loaded, resolved: false)
                    }
                }
            }
            if mode == .all && !chapter.resolved.isEmpty {
                Section(header: Text("Resolved")) {
                    ForEach(chapter.resolved) { loaded in
                        noteLink(loaded, resolved: true)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(chapter.chapterTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func noteLink(_ loaded: LoadedAnnotation, resolved: Bool) -> some View {
        NavigationLink {
            AnnotationDetailView(
                annotation: loaded.annotation,
                projectId: projectId,
                projectURL: projectURL,
                docId: loaded.docId,
                recents: recents,
                onResolved: onResolved)
        } label: {
            NoteRow(annotation: loaded.annotation, dimmed: resolved)
        }
    }
}

/// One note row: kind icon + body preview + (for a resolved row) a status chip.
/// Drops the project name the old cross-project list carried — we're already
/// inside a project→chapter.
private struct NoteRow: View {
    let annotation: Annotation
    let dimmed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: AnnotationsIcons.kindSymbol(annotation.kind))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(annotation.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let label = AnnotationStatusChip.label(annotation.status),
                       let symbol = AnnotationStatusChip.symbol(annotation.status) {
                        Label(label, systemImage: symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
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
        .opacity(dimmed ? 0.6 : 1)
    }
}
