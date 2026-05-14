import SwiftUI

struct OutlinePane: View {
    @Bindable var store: ProjectStore
    @Binding var layout: OutlineLayout
    @Binding var selectedItemId: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.manifest.structure.isEmpty {
                ContentUnavailableView {
                    Label("No items yet", systemImage: "list.bullet.indent")
                } description: {
                    Text("Add chapters or scenes from the Manuscript binder")
                }
            } else if layout == .table {
                OutlineTable(
                    items: flattenDocs(store.manifest.structure),
                    store: store,
                    selectedItemId: $selectedItemId)
            } else {
                CorkboardGrid(
                    items: flattenDocs(store.manifest.structure),
                    store: store,
                    selectedItemId: $selectedItemId)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Outline").font(.headline)
            Spacer()
            Picker("Layout", selection: $layout) {
                Image(systemName: "list.bullet").tag(OutlineLayout.table)
                Image(systemName: "rectangle.grid.2x2").tag(OutlineLayout.cards)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(8)
        .onChange(of: layout) { _, newValue in
            store.documentStore?.updateUIState { $0.outlineLayout = newValue }
        }
    }

    /// Flatten manifest.structure to document items only, recursing through groups.
    private func flattenDocs(_ items: [StructureItem]) -> [StructureItem] {
        var out: [StructureItem] = []
        for item in items {
            switch item.type {
            case .document: out.append(item)
            case .group:
                if let children = item.children {
                    out.append(contentsOf: flattenDocs(children))
                }
            }
        }
        return out
    }
}

// Temporary stub — T10 replaces with real implementation in its own file.
// Keep this inline so OutlinePane compiles standalone.
struct CorkboardGrid: View {
    let items: [StructureItem]
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?
    var body: some View { Text("Cards (T10)") }
}
