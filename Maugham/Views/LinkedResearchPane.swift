import SwiftUI

struct LinkedResearchPane: View {
    @Bindable var store: ProjectStore
    let activeDocumentId: String?
    @State private var showingLinkPicker: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showingLinkPicker) {
            if let docId = activeDocumentId {
                ResearchLinkPickerSheet(store: store, documentId: docId)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Linked Research").font(.headline)
            Spacer()
            Button {
                showingLinkPicker = true
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .disabled(activeDocumentId == nil)
            .help("Link research…")
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if let docId = activeDocumentId {
            let items = linkedItems(for: docId)
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("No linked research", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Drag research items here, or use the + button.")
                    }
                } else {
                    List {
                        ForEach(items) { item in
                            LinkedResearchRow(store: store, item: item) {
                                Task {
                                    try? await store.unlinkResearch(
                                        researchId: item.id,
                                        fromDocumentId: docId)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .dropDestination(for: String.self) { ids, _ in
                for id in ids {
                    Task {
                        try? await store.linkResearch(
                            researchId: id, toDocumentId: docId)
                    }
                }
                return true
            }
        } else {
            ContentUnavailableView {
                Label("No document selected", systemImage: "doc.text")
            } description: {
                Text("Select a chapter or scene to see its linked research")
            }
        }
    }

    private func linkedItems(for docId: String) -> [ResearchItem] {
        let ids = store.linkedResearchIds(forDocumentId: docId)
        return store.resolveResearchLinks(ids)
    }
}
