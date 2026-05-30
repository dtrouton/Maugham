import SwiftUI
import MaughamCore

/// One project's binder: the manuscript structure (hierarchical) plus a
/// read-only research section. Tapping a readable document or research file
/// pushes a `DocumentReaderView`. Standalone-constructible.
struct BinderView: View {
    let project: BrowsedProject
    let downloads: DownloadCoordinator
    let recents: RecentsTracker

    /// Research items that the reader can actually open (text documents with a
    /// path). Computed once — not in a row body (tripwire 4).
    private var readableResearch: [ResearchItem] {
        flattenResearch(project.manifest.research).filter(ReadIcons.isReadableResearch)
    }

    var body: some View {
        Group {
            if project.manifest.structure.isEmpty && project.manifest.research.isEmpty {
                ContentUnavailableView {
                    Label("Empty project", systemImage: "doc.questionmark")
                } description: {
                    Text("This project has no documents yet.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                binderList
            }
        }
        .navigationTitle(project.manifest.title)
        .navigationBarTitleDisplayMode(.inline)
        // Opening the binder counts as opening the project — keeps recents warm
        // for the cold-launch prefetch budget.
        .onAppear { recents.recordOpen(project.id) }
    }

    private var binderList: some View {
        List {
            if !project.manifest.structure.isEmpty {
                Section("Manuscript") {
                    ForEach(project.manifest.structure) { item in
                        StructureNode(
                            item: item,
                            projectRoot: project.url,
                            downloads: downloads,
                            recents: recents,
                            projectId: project.id)
                    }
                }
            }
            if !readableResearch.isEmpty {
                Section("Research") {
                    ForEach(readableResearch) { item in
                        ResearchRow(
                            item: item,
                            projectRoot: project.url,
                            downloads: downloads,
                            recents: recents,
                            projectId: project.id)
                    }
                }
            }
        }
    }

    /// Flatten the research tree to its leaf assets (group nodes hold children).
    private func flattenResearch(_ items: [ResearchItem]) -> [ResearchItem] {
        items.flatMap { item -> [ResearchItem] in
            if let children = item.children, !children.isEmpty {
                return flattenResearch(children)
            }
            return [item]
        }
    }
}

/// One node of the manuscript structure. Recurses for groups (DisclosureGroup
/// over children); a readable document is a `NavigationLink` to the reader; an
/// unreadable/path-less document is a disabled plain row. Row content is only a
/// title + icon — no parsing (tripwire 4).
private struct StructureNode: View {
    let item: StructureItem
    let projectRoot: URL
    let downloads: DownloadCoordinator
    let recents: RecentsTracker
    let projectId: ProjectId

    var body: some View {
        switch item.type {
        case .group:
            DisclosureGroup {
                ForEach(item.children ?? []) { child in
                    StructureNode(
                        item: child,
                        projectRoot: projectRoot,
                        downloads: downloads,
                        recents: recents,
                        projectId: projectId)
                }
            } label: {
                rowLabel
            }
        case .document:
            if let url = BinderRouting.documentURL(for: item, projectRoot: projectRoot) {
                NavigationLink {
                    DocumentReaderView(
                        docURL: url,
                        title: item.title,
                        projectId: projectId,
                        downloads: downloads,
                        recents: recents)
                } label: {
                    rowLabel
                }
            } else {
                // Path-less document — nothing to open. Show it dimmed so the
                // structure still reads completely.
                rowLabel
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rowLabel: some View {
        Label(item.title, systemImage: ReadIcons.structureSymbol(item))
    }
}

/// A readable research file row → reader. Resolves the asset's project-relative
/// `path` against the project root.
private struct ResearchRow: View {
    let item: ResearchItem
    let projectRoot: URL
    let downloads: DownloadCoordinator
    let recents: RecentsTracker
    let projectId: ProjectId

    var body: some View {
        if let path = item.path, !path.isEmpty {
            let url = projectRoot.appendingPathComponent(path)
            NavigationLink {
                DocumentReaderView(
                    docURL: url,
                    title: item.title,
                    projectId: projectId,
                    downloads: downloads,
                    recents: recents)
            } label: {
                Label(item.title, systemImage: ReadIcons.researchSymbol(item.kind))
            }
        } else {
            Label(item.title, systemImage: ReadIcons.researchSymbol(item.kind))
                .foregroundStyle(.secondary)
        }
    }
}
