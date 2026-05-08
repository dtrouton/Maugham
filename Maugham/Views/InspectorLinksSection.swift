import SwiftUI

struct InspectorLinksSection: View {
    @Bindable var store: ProjectStore
    let currentItemId: String
    @Binding var draftLinks: [String]
    let onCommit: () -> Void
    let onNavigate: (String) -> Void

    @State private var showingAddPopover: Bool = false
    @State private var addSearch: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Links")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addSearch = ""
                        showingAddPopover = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showingAddPopover) {
                        addLinkPopover
                    }
                }
                if draftLinks.isEmpty {
                    Text("No links")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(draftLinks, id: \.self) { id in
                        linkRow(id: id)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Linked from")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if backlinks.isEmpty {
                    Text("No backlinks")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(backlinks, id: \.id) { item in
                        Button {
                            onNavigate(item.id)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.uturn.backward.circle")
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func linkRow(id: String) -> some View {
        HStack {
            Button {
                onNavigate(id)
            } label: {
                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    Text(linkedTitle(id: id))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            Button {
                draftLinks.removeAll { $0 == id }
                onCommit()
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
        }
    }

    private var addLinkPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search documents…", text: $addSearch)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(linkableDocuments, id: \.id) { item in
                        Button {
                            if !draftLinks.contains(item.id) {
                                draftLinks.append(item.id)
                                onCommit()
                            }
                            showingAddPopover = false
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

    private var linkableDocuments: [StructureItem] {
        let all = collectAll(in: store.manifest.structure)
            .filter { $0.type == .document && $0.id != currentItemId }
            .filter { !draftLinks.contains($0.id) }
        let q = addSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(q) }
    }

    private var backlinks: [StructureItem] {
        collectAll(in: store.manifest.structure)
            .filter { ($0.links ?? []).contains(currentItemId) }
    }

    private func linkedTitle(id: String) -> String {
        collectAll(in: store.manifest.structure)
            .first(where: { $0.id == id })?.title
            ?? "(missing)"
    }

    private func collectAll(in items: [StructureItem]) -> [StructureItem] {
        var result: [StructureItem] = []
        for item in items {
            result.append(item)
            if let children = item.children {
                result.append(contentsOf: collectAll(in: children))
            }
        }
        return result
    }
}
