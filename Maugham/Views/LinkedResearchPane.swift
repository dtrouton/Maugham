import SwiftUI
import AppKit
import MaughamCore

struct LinkedResearchPane: View {
    @Bindable var store: ProjectStore
    let activeDocumentId: String?
    @State private var showingLinkPicker: Bool = false
    @State private var showingNewNote: Bool = false
    @State private var showingAddLink: Bool = false
    @State private var actionError: String?
    @State private var viewedItemId: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showingLinkPicker) {
            if let docId = activeDocumentId {
                ResearchLinkPickerSheet(store: store, documentId: docId)
            }
        }
        .sheet(isPresented: $showingNewNote) {
            if let docId = activeDocumentId {
                NewResearchNoteSheet { title in
                    Task {
                        do {
                            _ = try await store.createResearchNote(
                                scope: .document(docId), title: title)
                        } catch { actionError = error.localizedDescription }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddLink) {
            AddResearchLinkSheet(
                onAdd: { title, url in
                    if let docId = activeDocumentId {
                        Task {
                            do {
                                _ = try await store.createResearchLink(
                                    scope: .document(docId), title: title, url: url)
                            } catch { actionError = error.localizedDescription }
                        }
                    }
                    showingAddLink = false
                },
                onCancel: { showingAddLink = false })
        }
        .alert("Couldn’t add research", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
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
                .help("Back to research list")
            }
            Text(headerTitle).font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if viewedItemId == nil {
                Menu {
                    Button("Link Research…") { showingLinkPicker = true }
                    Divider()
                    Button("New Note…") { showingNewNote = true }
                    Button("Add File…") { Task { await runAddFile() } }
                    Button("Add Link…") { showingAddLink = true }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!canCreate)
                .help("Add or link research for this document")
            }
        }
        .padding(8)
    }

    private var canCreate: Bool {
        guard let docId = activeDocumentId else { return false }
        return store.isResearchScopeTarget(docId)
    }

    private var headerTitle: String {
        if let id = viewedItemId,
           let item = store.resolveResearchLinks([id]).first {
            return item.title
        }
        return "Research"
    }

    private var derivedSectionTitle: String {
        store.manifest.type == .collection ? "Piece Research" : "Project Research"
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
                Text("Select a chapter or scene to see its research")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let derived = store.derivedResearchItems(forDocumentId: docId)
        let derivedIds = Set(derived.map(\.id))
        let linked = linkedItems(for: docId).filter { !derivedIds.contains($0.id) }
        Group {
            if derived.isEmpty && linked.isEmpty {
                ContentUnavailableView {
                    Label("No research yet", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Create research from the + menu, or drag research items here to link them.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !derived.isEmpty {
                        Section(derivedSectionTitle) {
                            ForEach(derived) { item in
                                Button {
                                    viewedItemId = item.id
                                } label: {
                                    LinkedResearchRow(item: item, onUnlink: nil)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !linked.isEmpty {
                        Section("Linked") {
                            ForEach(linked) { item in
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
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            // Ignore drags of items already structurally associated — a link
            // would be redundant and double-display the item.
            for id in ids where !derivedIds.contains(id) {
                Task {
                    try? await store.linkResearch(
                        researchId: id, toDocumentId: docId)
                }
            }
            return true
        }
    }

    private func runAddFile() async {
        guard let docId = activeDocumentId else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                _ = try await store.createResearchAsset(
                    scope: .document(docId), fromURL: url)
            } catch { actionError = error.localizedDescription }
        }
    }

    private func linkedItems(for docId: String) -> [ResearchItem] {
        let ids = store.linkedResearchIds(forDocumentId: docId)
        return store.resolveResearchLinks(ids)
    }
}
