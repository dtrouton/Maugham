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
    /// path), with palette-group descendants and the craft-intent doc removed —
    /// those get their own Palette section, so leaving them here would duplicate
    /// them. Computed once — not in a row body (tripwire 4).
    private var readableResearch: [ResearchItem] {
        let leaves = TreeWalk.leaves(in: project.manifest.research).filter(ReadIcons.isReadableResearch)
        return PaletteLoading.excludingPalette(leaves, research: project.manifest.research)
    }

    /// The palette group's cards, in wall order. Empty when there's no palette.
    private var paletteCards: [ResearchItem] {
        PaletteLoading.paletteCards(in: project.manifest.research)
    }

    /// The project-scope craft-intent doc, if present (per spec: project scope only).
    private var craftIntent: ResearchItem? {
        PaletteLookup.craftIntentItem(in: project.manifest.research, researchPrefix: "research")
    }

    /// The Palette section shows only when there's something in it — an empty
    /// palette stays quiet (no section).
    private var hasPalette: Bool { !paletteCards.isEmpty || craftIntent != nil }

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
            Section {
                SharingRoleBanner(projectURL: project.url)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
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
            if hasPalette {
                Section("Palette") {
                    // Each row uses a generic palette icon — a card's kind lives
                    // inside the file, not the manifest, so a per-row kind icon
                    // would force a per-row parse (tripwire 4). Kind shows in the
                    // card detail, where the file is already parsed.
                    ForEach(paletteCards) { card in
                        NavigationLink {
                            PaletteCardView(
                                project: project,
                                item: card,
                                downloads: downloads,
                                recents: recents)
                        } label: {
                            Label(card.title, systemImage: ReadIcons.paletteRowSymbol)
                        }
                    }
                    if let intent = craftIntent {
                        // Craft Intent is a plain-markdown doc — the existing
                        // document reader renders it directly.
                        NavigationLink {
                            DocumentReaderView(
                                docURL: project.url.appendingPathComponent(intent.path ?? ""),
                                title: intent.title,
                                projectId: project.id,
                                downloads: downloads,
                                recents: recents)
                        } label: {
                            Label(intent.title, systemImage: "scope")
                        }
                    }
                }
            }
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
