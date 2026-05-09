import SwiftUI

struct BinderView: View {
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?
    @State private var renamingItemId: String?
    @State private var pendingError: String?
    @State private var pendingTidyParentId: String?
    @State private var showingTidyConfirmation: Bool = false

    var body: some View {
        List(selection: $selectedItemId) {
            outline(items: store.manifest.structure)
        }
        .listStyle(.sidebar)
        .alert("Couldn't update project",
               isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } }
               )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pendingError ?? "")
        }
        .alert("Renumber filenames?",
               isPresented: $showingTidyConfirmation,
               presenting: pendingTidyParentId
        ) { _ in
            Button("Renumber", role: .destructive) {
                if let parentId = pendingTidyParentId {
                    Task { await runTidy(parentId: parentId) }
                } else {
                    Task { await runTidy(parentId: nil) }
                }
                pendingTidyParentId = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTidyParentId = nil
            }
        } message: { _ in
            Text("Existing files will be moved to fix gaps in numbering. This change is visible to other apps that read this folder.")
        }
    }

    private func outline(items: [StructureItem]) -> some View {
        ForEach(items) { item in
            if item.type == .group, let children = item.children {
                DisclosureGroup {
                    AnyView(outline(items: children))
                } label: {
                    row(for: item)
                }
                .tag(item.id)
            } else {
                row(for: item)
                    .tag(item.id)
            }
        }
    }

    private func row(for item: StructureItem) -> some View {
        BinderRow(
            item: item,
            renamingItemId: $renamingItemId,
            onRename: { id, newTitle in
                Task { await rename(id: id, to: newTitle) }
            },
            onDrop: { draggedId, position in
                Task { await handleDrop(draggedId: draggedId,
                                        position: position,
                                        target: item) }
            }
        )
        .contextMenu {
            Button("New Document") {
                let ext = store.manifest.type == .screenplay ? "fountain" : "md"
                Task { await addItem(parent: item, kind: .document(extension: ext)) }
            }
            Button("New Group") {
                Task { await addItem(parent: item, kind: .group) }
            }
            Divider()
            Button("Duplicate") {
                Task { await duplicate(id: item.id) }
            }
            Button("Rename") { renamingItemId = item.id }
            Button("Delete", role: .destructive) {
                Task { await deleteItem(id: item.id) }
            }
            if item.type == .group {
                Divider()
                Button("Tidy Filenames") {
                    pendingTidyParentId = item.id
                    showingTidyConfirmation = true
                }
            }
        }
    }

    // MARK: - Actions

    private func addItem(parent: StructureItem, kind: StructureItemKind) async {
        let parentId: String? = parent.type == .group ? parent.id : findParentId(of: parent.id)
        let title: String
        switch kind {
        case .document: title = "New Document"
        case .group:    title = "New Group"
        }
        do {
            let item = try await store.addStructureItem(
                parentId: parentId, title: title, kind: kind)
            renamingItemId = item.id  // immediately go to rename mode
            selectedItemId = item.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func rename(id: String, to newTitle: String) async {
        do {
            try await store.renameStructureItem(id: id, newTitle: newTitle)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func deleteItem(id: String) async {
        do {
            try await store.deleteStructureItem(id: id)
            if selectedItemId == id { selectedItemId = nil }
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func handleDrop(
        draggedId: String,
        position: DropIntent.Position,
        target: StructureItem
    ) async {
        guard draggedId != target.id else { return }
        let intent = DropIntent.classify(position: position, target: target)
        let toParentId: String?
        let destIndex: Int
        switch intent {
        case .insertAbove(let targetId):
            toParentId = findParentId(of: targetId)
            destIndex = currentIndex(of: targetId, in: toParentId)
        case .insertBelow(let targetId):
            toParentId = findParentId(of: targetId)
            destIndex = currentIndex(of: targetId, in: toParentId) + 1
        case .insertChild(let parentId):
            toParentId = parentId
            destIndex = 0
        }
        do {
            try await store.moveStructureItem(
                id: draggedId, toParentId: toParentId, atIndex: destIndex)
        } catch ProjectStoreError.cycle {
            pendingError = "Can't move a group into one of its own descendants."
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func duplicate(id: String) async {
        do {
            let copy = try await store.duplicateStructureItem(id: id)
            renamingItemId = copy.id  // immediately offer rename
            selectedItemId = copy.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func runTidy(parentId: String?) async {
        do {
            try await store.tidyFilenames(parentId: parentId)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func currentIndex(of id: String, in parentId: String?) -> Int {
        let siblings: [StructureItem]
        if let parentId,
           let parent = findItem(id: parentId, in: store.manifest.structure) {
            siblings = parent.children ?? []
        } else {
            siblings = store.manifest.structure
        }
        return siblings.firstIndex(where: { $0.id == id }) ?? 0
    }

    private func findItem(
        id: String, in items: [StructureItem]
    ) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let nested = findItem(id: id, in: children) {
                return nested
            }
        }
        return nil
    }

    /// Find the parent id of an item by id, or nil if at root.
    private func findParentId(of childId: String) -> String? {
        Self.findParent(childId: childId, in: store.manifest.structure, parent: nil)
    }

    private static func findParent(
        childId: String, in items: [StructureItem], parent: String?
    ) -> String? {
        for item in items {
            if item.id == childId { return parent }
            if let children = item.children {
                if let found = findParent(
                    childId: childId, in: children, parent: item.id) {
                    return found
                }
            }
        }
        return nil
    }
}
