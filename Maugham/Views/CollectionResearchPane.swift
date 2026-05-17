import SwiftUI
import AppKit

struct CollectionResearchPane: View {
    @Bindable var store: ProjectStore
    @Binding var selectedResearchId: String?
    let activePiece: StructureItem?

    /// Kept for API compatibility with call sites in CollectionBinderPaneToggle
    /// and ProjectWindow. The new implementation manages its own add actions.
    let onAddSharedNote: () -> Void
    let onAddPieceNote: () -> Void

    @State private var renamingItemId: String?
    @State private var pendingRenameId: String?
    @State private var pendingError: String?
    @State private var showingAddLinkSheet: Bool = false
    @State private var addLinkScope: AddLinkScope = .shared

    private enum AddLinkScope: Equatable {
        case shared
        case piece(String)
    }

    var body: some View {
        List(selection: $selectedResearchId) {
            sharedSection
            if let piece = activePiece, piece.pieceKind == .loose {
                pieceSection(for: piece)
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $showingAddLinkSheet) {
            AddResearchLinkSheet(
                onAdd: { title, url in
                    Task { await addLinkForScope(title: title, url: url) }
                    showingAddLinkSheet = false
                },
                onCancel: { showingAddLinkSheet = false })
        }
        .alert(pendingError ?? "",
               isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: store.manifest.research) { _, _ in
            tryCommitPendingRename()
        }
        .onChange(of: pendingRenameId) { _, _ in
            tryCommitPendingRename()
        }
    }

    // MARK: - Sections

    private var sharedSection: some View {
        Section {
            let items = sharedItems()
            if items.isEmpty {
                Text("No shared research yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    row(for: item, scope: .shared)
                }
            }
        } header: {
            HStack {
                Text("Shared")
                Spacer()
                sharedHeaderMenu
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await runImport(urls: urls, scope: .shared) }
            return true
        }
    }

    private func pieceSection(for piece: StructureItem) -> some View {
        Section {
            let items = pieceItems(piece: piece)
            if items.isEmpty {
                Text("No research yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    row(for: item, scope: .piece(piece.id))
                }
            }
        } header: {
            HStack {
                Text(piece.title)
                Spacer()
                pieceHeaderMenu(pieceId: piece.id)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await runImport(urls: urls, scope: .piece(piece.id)) }
            return true
        }
    }

    // MARK: - Header menus

    private var sharedHeaderMenu: some View {
        Menu {
            Button("New Note") { Task { await addNote(scope: .shared) } }
            Button("New Group") { Task { await addGroup() } }
            Button("Add File…") { Task { await runAddFile(scope: .shared) } }
            Button("Add Link…") {
                addLinkScope = .shared
                showingAddLinkSheet = true
            }
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func pieceHeaderMenu(pieceId: String) -> some View {
        Menu {
            Button("New Note") { Task { await addNote(scope: .piece(pieceId)) } }
            Button("Add File…") { Task { await runAddFile(scope: .piece(pieceId)) } }
            Button("Add Link…") {
                addLinkScope = .piece(pieceId)
                showingAddLinkSheet = true
            }
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Row

    private enum Scope: Equatable {
        case shared
        case piece(String)
    }

    @ViewBuilder
    private func row(for item: ResearchItem, scope: Scope) -> some View {
        ResearchRow(
            item: item,
            renamingItemId: $renamingItemId,
            onRename: { id, newTitle in
                Task { await rename(id: id, to: newTitle) }
            },
            onDrop: { draggedId, position in
                Task { await handleResearchReorder(
                    draggedId: draggedId,
                    targetItem: item,
                    position: position,
                    scope: scope) }
            },
            onExternalDrop: { urls, _ in
                Task { await runImport(urls: urls, scope: scope) }
            })
            .tag(item.id as String?)
            .contextMenu {
                Button("Rename") { renamingItemId = item.id }
                Button("Duplicate") {
                    Task { await duplicate(id: item.id) }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    Task { await delete(id: item.id) }
                }
            }
    }

    // MARK: - Filtered item lists

    private func sharedItems() -> [ResearchItem] {
        store.manifest.research.filter { item in
            guard let path = item.path else { return true }
            return !path.hasPrefix("pieces/")
        }
    }

    private func pieceItems(piece: StructureItem) -> [ResearchItem] {
        guard let piecePath = piece.path else { return [] }
        let pieceFolder = (piecePath as NSString).deletingLastPathComponent
        let prefix = "\(pieceFolder)/research/"
        return store.manifest.research.filter { item in
            item.path?.hasPrefix(prefix) == true
        }
    }

    // MARK: - Actions

    private func tryCommitPendingRename() {
        guard let id = pendingRenameId,
              store.manifest.research.contains(where: { $0.id == id }) else { return }
        renamingItemId = id
        pendingRenameId = nil
    }

    private func addNote(scope: Scope) async {
        do {
            let item: ResearchItem
            switch scope {
            case .shared:
                item = try await store.addResearchTextNote(parentId: nil)
            case .piece(let pieceId):
                item = try await store.addPieceResearchNote(
                    pieceId: pieceId, title: "Untitled Note")
            }
            selectedResearchId = item.id
            pendingRenameId = item.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func addGroup() async {
        do {
            let g = try await store.addResearchItem(
                parentId: nil, title: "Untitled Group", kind: nil)
            selectedResearchId = g.id
            pendingRenameId = g.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func addLinkForScope(title: String, url: String) async {
        do {
            let link: ResearchItem
            switch addLinkScope {
            case .shared:
                link = try await store.addResearchLink(
                    parentId: nil, title: title, url: url)
            case .piece(let pieceId):
                link = try await store.addPieceResearchLink(
                    pieceId: pieceId, title: title, url: url)
            }
            selectedResearchId = link.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func runAddFile(scope: Scope) async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        await runImport(urls: panel.urls, scope: scope)
    }

    private func runImport(urls: [URL], scope: Scope) async {
        do {
            switch scope {
            case .shared:
                _ = try await store.importResearchFiles(urls, toParentId: nil)
            case .piece(let pieceId):
                _ = try await store.importPieceResearchFiles(
                    pieceId: pieceId, urls: urls)
            }
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func rename(id: String, to newTitle: String) async {
        do {
            try await store.updateResearchItem(id: id, title: newTitle)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func duplicate(id: String) async {
        do {
            let copy = try await store.duplicateResearchItem(id: id)
            renamingItemId = copy.id
            selectedResearchId = copy.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func delete(id: String) async {
        do {
            try await store.deleteResearchItem(id: id)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// Within-section research reorder. Cross-section drags (Shared → per-piece
    /// or between different pieces) are ignored — those are out of scope per
    /// the milestone spec. Within-section, we compute the destination index in
    /// the flat manifest.research array such that the section-filtered view
    /// reflects the drop position. moveResearchItem preserves the relative
    /// order of items in other sections.
    private func handleResearchReorder(
        draggedId: String,
        targetItem: ResearchItem,
        position: DropIntent.Position,
        scope: Scope
    ) async {
        guard draggedId != targetItem.id else { return }
        // Both items must belong to the same section. If the dragged item
        // came from a different section, silently ignore the drop.
        guard let dragged = store.manifest.research.first(where: { $0.id == draggedId }),
              scopeFor(item: dragged) == scope,
              scopeFor(item: targetItem) == scope else {
            return
        }
        guard let sourceFullIdx = store.manifest.research.firstIndex(where: { $0.id == draggedId }),
              let targetFullIdx = store.manifest.research.firstIndex(where: { $0.id == targetItem.id }) else {
            return
        }
        var destIdx = position == .top ? targetFullIdx : targetFullIdx + 1
        if sourceFullIdx < destIdx { destIdx -= 1 }
        do {
            try await store.moveResearchItem(
                id: draggedId, toParentId: nil, atIndex: destIdx)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// Which section a given research item belongs to, based on its path.
    private func scopeFor(item: ResearchItem) -> Scope {
        guard let path = item.path, path.hasPrefix("pieces/") else {
            return .shared
        }
        for piece in store.manifest.structure where piece.pieceKind == .loose {
            guard let piecePath = piece.path else { continue }
            let pieceFolder = (piecePath as NSString).deletingLastPathComponent
            if path.hasPrefix("\(pieceFolder)/research/") {
                return .piece(piece.id)
            }
        }
        return .shared
    }
}
