import SwiftUI
import MaughamCore

/// Searchable list of manuscript documents (chapters / loose pieces) that can
/// receive scoped research — drives the inbox "Promote to Research for…" action.
struct PromoteTargetPickerSheet: View {
    @Bindable var store: ProjectStore
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Search documents…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(filteredTargets()) { item in
                    Button {
                        onPick(item.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(item.title)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationTitle("Promote to Research for…")
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func filteredTargets() -> [StructureItem] {
        let all = store.researchScopeTargets()
        if query.isEmpty { return all }
        let lower = query.lowercased()
        return all.filter { $0.title.lowercased().contains(lower) }
    }
}
