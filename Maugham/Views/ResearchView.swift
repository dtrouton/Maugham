import SwiftUI
import AppKit

struct ResearchView: View {
    @Bindable var store: ProjectStore
    @Binding var selectedResearchId: String?

    @State private var renamingItemId: String?
    @State private var pendingError: String?
    @State private var showingAddLinkSheet: Bool = false
    @State private var addLinkParentId: String?

    var body: some View {
        List(selection: $selectedResearchId) {
            ForEach(store.manifest.research) { item in
                node(for: item)
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("New Group") {
                Task { await addGroup(parentId: nil) }
            }
            Button("Add File…") {
                Task { await runAddFile(parentId: nil) }
            }
            Button("Add Link…") {
                addLinkParentId = nil
                showingAddLinkSheet = true
            }
        }
        .sheet(isPresented: $showingAddLinkSheet) {
            AddResearchLinkSheet(
                onAdd: { title, url in
                    Task { await addLink(parentId: addLinkParentId, title: title, url: url) }
                    showingAddLinkSheet = false
                },
                onCancel: { showingAddLinkSheet = false })
        }
        .alert(pendingError ?? "",
               isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await runImport(urls, toParentId: nil) }
            return true
        }
    }

    @ViewBuilder
    private func node(for item: ResearchItem) -> some View {
        if item.type == .group {
            DisclosureGroup {
                AnyView(childNodes(for: item))
            } label: {
                row(for: item)
            }
        } else {
            row(for: item)
        }
    }

    private func childNodes(for item: ResearchItem) -> some View {
        ForEach(item.children ?? []) { child in
            AnyView(node(for: child))
        }
    }

    private func row(for item: ResearchItem) -> some View {
        ResearchRow(
            item: item,
            renamingItemId: $renamingItemId,
            onRename: { id, newTitle in
                Task { await rename(id: id, to: newTitle) }
            },
            onDrop: { draggedId, position in
                Task { await handleInternalDrop(
                    draggedId: draggedId, position: position, target: item) }
            },
            onExternalDrop: { urls, position in
                let parent = position == .middle && item.type == .group
                    ? item.id
                    : findParentId(of: item.id)
                Task { await runImport(urls, toParentId: parent) }
            }
        )
        .contextMenu {
            if item.type == .group {
                Button("New Group") {
                    Task { await addGroup(parentId: item.id) }
                }
                Button("Add File…") {
                    Task { await runAddFile(parentId: item.id) }
                }
                Button("Add Link…") {
                    addLinkParentId = item.id
                    showingAddLinkSheet = true
                }
                Divider()
            }
            Button("Duplicate") {
                Task { await duplicate(id: item.id) }
            }
            Button("Rename") { renamingItemId = item.id }
            Button("Delete", role: .destructive) {
                Task { await delete(id: item.id) }
            }
        }
    }

    private func handleInternalDrop(
        draggedId: String, position: DropIntent.Position, target: ResearchItem
    ) async {
        guard draggedId != target.id else { return }
        let toParentId: String?
        let destIndex: Int
        switch position {
        case .top:
            toParentId = findParentId(of: target.id)
            destIndex = currentIndex(of: target.id, in: toParentId)
        case .bottom:
            toParentId = findParentId(of: target.id)
            destIndex = currentIndex(of: target.id, in: toParentId) + 1
        case .middle where target.type == .group:
            toParentId = target.id
            destIndex = 0
        case .middle:
            toParentId = findParentId(of: target.id)
            destIndex = currentIndex(of: target.id, in: toParentId) + 1
        }
        do {
            try await store.moveResearchItem(
                id: draggedId, toParentId: toParentId, atIndex: destIndex)
        } catch ProjectStoreError.cycle {
            pendingError = "Can't move a group into one of its own descendants."
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func addGroup(parentId: String?) async {
        do {
            let g = try await store.addResearchItem(
                parentId: parentId, title: "Untitled Group", kind: nil)
            renamingItemId = g.id
            selectedResearchId = g.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func addLink(parentId: String?, title: String, url: String) async {
        do {
            let l = try await store.addResearchLink(
                parentId: parentId, title: title, url: url)
            selectedResearchId = l.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func runAddFile(parentId: String?) async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        await runImport(panel.urls, toParentId: parentId)
    }

    private func runImport(_ urls: [URL], toParentId: String?) async {
        do {
            _ = try await store.importResearchFiles(urls, toParentId: toParentId)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func rename(id: String, to newTitle: String) async {
        do {
            try await store.updateResearchItem(id: id, title: newTitle)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func duplicate(id: String) async {
        do {
            let copy = try await store.duplicateResearchItem(id: id)
            renamingItemId = copy.id
            selectedResearchId = copy.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func delete(id: String) async {
        do {
            try await store.deleteResearchItem(id: id)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    // MARK: - Tree helpers

    private func findItem(
        id: String, in items: [ResearchItem]
    ) -> ResearchItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let nested = findItem(id: id, in: children) {
                return nested
            }
        }
        return nil
    }

    private func findParentId(of childId: String) -> String? {
        findParentIdHelper(of: childId, in: store.manifest.research, parent: nil)
    }

    private func findParentIdHelper(
        of childId: String, in items: [ResearchItem], parent: String?
    ) -> String? {
        for item in items {
            if item.id == childId { return parent }
            if let children = item.children,
               let nested = findParentIdHelper(
                    of: childId, in: children, parent: item.id) {
                return nested
            }
        }
        return nil
    }

    private func currentIndex(of id: String, in parentId: String?) -> Int {
        let siblings: [ResearchItem]
        if let parentId,
           let parent = findItem(id: parentId, in: store.manifest.research) {
            siblings = parent.children ?? []
        } else {
            siblings = store.manifest.research
        }
        return siblings.firstIndex(where: { $0.id == id }) ?? 0
    }
}
