import SwiftUI
import MaughamCore

struct ResearchLinkPickerSheet: View {
    @Bindable var store: ProjectStore
    let documentId: String
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Search research…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List {
                    ForEach(filteredItems()) { item in
                        row(for: item)
                    }
                }
                .listStyle(.sidebar)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .navigationTitle("Link Research")
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private func row(for item: ResearchItem) -> some View {
        HStack {
            Image(systemName: iconName(for: item))
                .foregroundStyle(.secondary)
            Text(item.title)
            Spacer()
            Toggle("", isOn: Binding(
                get: { isLinked(item.id) },
                set: { newValue in toggleLink(item.id, link: newValue) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func iconName(for item: ResearchItem) -> String {
        switch item.kind {
        case .document: return "doc.text"
        case .image:    return "photo"
        case .pdf:      return "doc.richtext"
        case .audio:    return "waveform"
        case .link:     return "link"
        case .none:     return "folder"
        }
    }

    private func isLinked(_ id: String) -> Bool {
        store.linkedResearchIds(forDocumentId: documentId).contains(id)
    }

    private func toggleLink(_ id: String, link: Bool) {
        Task {
            if link {
                try? await store.linkResearch(researchId: id, toDocumentId: documentId)
            } else {
                try? await store.unlinkResearch(researchId: id, fromDocumentId: documentId)
            }
        }
    }

    private func filteredItems() -> [ResearchItem] {
        let all = flatten(store.manifest.research)
        if query.isEmpty { return all }
        let lower = query.lowercased()
        return all.filter { $0.title.lowercased().contains(lower) }
    }

    private func flatten(_ items: [ResearchItem]) -> [ResearchItem] {
        var out: [ResearchItem] = []
        for item in items {
            out.append(item)
            if let children = item.children {
                out.append(contentsOf: flatten(children))
            }
        }
        return out
    }
}
