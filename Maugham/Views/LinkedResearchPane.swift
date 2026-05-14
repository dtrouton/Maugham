import SwiftUI

struct LinkedResearchPane: View {
    @Bindable var store: ProjectStore
    let activeDocumentId: String?
    @State private var showingLinkPicker: Bool = false
    @State private var viewedItemId: String?

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
        .onChange(of: activeDocumentId) { _, _ in
            // Different manuscript doc selected → reset viewer to list
            viewedItemId = nil
        }
    }

    private var header: some View {
        HStack {
            if viewedItemId != nil {
                Button {
                    viewedItemId = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("Back to linked list")
            }
            Text(headerTitle).font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if viewedItemId == nil {
                Button {
                    showingLinkPicker = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .disabled(activeDocumentId == nil)
                .help("Link research…")
            }
        }
        .padding(8)
    }

    private var headerTitle: String {
        if let id = viewedItemId,
           let item = store.resolveResearchLinks([id]).first {
            return item.title
        }
        return "Linked Research"
    }

    @ViewBuilder
    private var content: some View {
        if let id = viewedItemId,
           let item = store.resolveResearchLinks([id]).first {
            viewer(for: item)
        } else if let docId = activeDocumentId {
            list(for: docId)
        } else {
            ContentUnavailableView {
                Label("No document selected", systemImage: "doc.text")
            } description: {
                Text("Select a chapter or scene to see its linked research")
            }
        }
    }

    private func viewer(for item: ResearchItem) -> some View {
        // Always use ResearchPreview here — its TextPreview branch handles
        // .document read-only without going through DocumentStore. Using
        // ResearchNoteEditor would hijack DocumentStore's active document
        // and evict the manuscript doc from the editor pane.
        ResearchPreview(projectURL: store.url, item: item)
    }

    @ViewBuilder
    private func list(for docId: String) -> some View {
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
                        Button {
                            viewedItemId = item.id
                        } label: {
                            LinkedResearchRow(item: item) {
                                Task {
                                    try? await store.unlinkResearch(
                                        researchId: item.id,
                                        fromDocumentId: docId)
                                }
                            }
                        }
                        .buttonStyle(.plain)
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
    }

    private func linkedItems(for docId: String) -> [ResearchItem] {
        let ids = store.linkedResearchIds(forDocumentId: docId)
        return store.resolveResearchLinks(ids)
    }
}
