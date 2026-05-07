import SwiftUI

struct BinderView: View {
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?
    @State private var renamingItemId: String?
    @State private var pendingError: String?

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
            }
        )
        .contextMenu {
            Button("New Document") {
                Task { await addItem(parent: item, kind: .document(extension: "md")) }
            }
            Button("New Group") {
                Task { await addItem(parent: item, kind: .group) }
            }
            Divider()
            Button("Rename") { renamingItemId = item.id }
            Button("Delete", role: .destructive) {
                Task { await deleteItem(id: item.id) }
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
