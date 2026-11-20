import SwiftUI
import MaughamCore

/// **The add-link search** — a document title filter over every other
/// document not already linked; a pick hands the id back. Moved out of
/// `InspectorLinksSection`'s popover (shell p3 Task 8) so the tree's "Add
/// Link…" sheet opens this search and not a second one.
struct PieceLinkSearch: View {
    @Bindable var store: ProjectStore
    let currentItemId: String
    let existing: [String]
    let onPick: (String) -> Void

    @State private var search: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search documents…", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.candidates(
                        in: store.manifest.structure, currentItemId: currentItemId,
                        existing: existing, query: search), id: \.id) { item in
                        Button {
                            onPick(item.id)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(width: 260)
    }

    /// Every document but this one and those already linked, filtered by a
    /// case-insensitive title match.
    static func candidates(in structure: [StructureItem], currentItemId: String,
                           existing: [String], query: String) -> [StructureItem] {
        let all = TreeWalk.collect(in: structure, where: { _ in true })
            .filter { $0.type == .document && $0.id != currentItemId }
            .filter { !existing.contains($0.id) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(q) }
    }
}
