import SwiftUI
import MaughamCore

struct ProjectAltitudePane: View {
    @Bindable var store: ProjectStore
    @Binding var layout: OutlineLayout
    @Binding var selectedSubject: BinderSubject?
    let title: String

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if layout == .table {
                OutlineTable(
                    items: TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document }),
                    store: store,
                    selectedSubject: $selectedSubject)
            } else {
                CorkboardGrid(
                    items: TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document }),
                    store: store,
                    selectedSubject: $selectedSubject)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack {
            Text(title).font(.headline)
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

}
