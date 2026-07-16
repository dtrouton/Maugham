import SwiftUI
import MaughamCore
import AppKit
import UniformTypeIdentifiers

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
        case group(String)
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
                    ResearchTreeNode(
                        item: item,
                        renamingItemId: $renamingItemId,
                        findParentId: { findParentId(of: $0) },
                        actions: treeActions(scope: .shared))
                }
            }
        } header: {
            HStack {
                Text("Shared")
                Spacer()
                sharedHeaderMenu
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            Task { await importExternal(providers, scope: .shared) }
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
                    ResearchTreeNode(
                        item: item,
                        renamingItemId: $renamingItemId,
                        findParentId: { findParentId(of: $0) },
                        actions: treeActions(scope: .piece(piece.id)))
                }
            }
        } header: {
            HStack {
                Text(piece.title)
                Spacer()
                pieceHeaderMenu(pieceId: piece.id)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            Task { await importExternal(providers, scope: .piece(piece.id)) }
            return true
        }
    }

    // MARK: - Header menus

    private var sharedHeaderMenu: some View {
        Menu {
            Button("New Note") { Task { await addNote(scope: .shared) } }
            Button("New Group") { Task { await addGroup(parentId: nil) } }
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
            Button("New Group") { Task { await addGroupInPiece(pieceId: pieceId) } }
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

    // MARK: - Scope

    private enum Scope: Equatable {
        case shared
        case piece(String)
    }

    // MARK: - Tree actions

    private func treeActions(scope: Scope) -> ResearchTreeActions {
        ResearchTreeActions(
            rename: { id, newTitle in Task { await rename(id: id, to: newTitle) } },
            internalDrop: { draggedId, position, target in
                Task { await handleInternalDrop(
                    draggedId: draggedId, position: position,
                    target: target, scope: scope) }
            },
            externalDrop: { providers, position, target in
                if position == .middle && target.type == .group {
                    Task { await importExternalIntoGroup(providers, parentId: target.id) }
                } else {
                    Task { await importExternal(providers, scope: scope) }
                }
            },
            newNote: { parentId in
                if let parentId {
                    Task { await addNoteInGroup(parentId: parentId) }
                } else {
                    Task { await addNote(scope: scope) }
                }
            },
            newGroup: { parentId in Task { await addGroup(parentId: parentId) } },
            addFile: { parentId in
                if let parentId {
                    Task { await runAddFileInGroup(parentId: parentId) }
                } else {
                    Task { await runAddFile(scope: scope) }
                }
            },
            addLink: { parentId in
                if let parentId {
                    addLinkScope = .group(parentId)
                } else {
                    switch scope {
                    case .shared: addLinkScope = .shared
                    case .piece(let id): addLinkScope = .piece(id)
                    }
                }
                showingAddLinkSheet = true
            },
            duplicate: { id in Task { await duplicate(id: id) } },
            delete: { id in Task { await delete(id: id) } })
    }

    // MARK: - Filtered item lists

    private func sharedItems() -> [ResearchItem] {
        store.manifest.research.filter { item in
            guard let path = item.path else { return true }
            return !path.hasPrefix("pieces/")
        }
    }

    private func pieceItems(piece: StructureItem) -> [ResearchItem] {
        store.derivedResearchItems(forDocumentId: piece.id)
    }

    // MARK: - Actions

    private func tryCommitPendingRename() {
        guard let id = pendingRenameId,
              TreeWalk.contains(id: id, in: store.manifest.research) else { return }
        renamingItemId = id
        pendingRenameId = nil
    }

    private func addNote(scope: Scope) async {
        do {
            let item: ResearchItem
            switch scope {
            case .shared:
                item = try await store.createResearchNote(scope: .shared)
            case .piece(let pieceId):
                item = try await store.createResearchNote(scope: .document(pieceId))
            }
            selectedResearchId = item.id
            pendingRenameId = item.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func addNoteInGroup(parentId: String) async {
        do {
            let note = try await store.addResearchTextNote(
                parentId: parentId, title: "Untitled Note")
            selectedResearchId = note.id
            pendingRenameId = note.id
        } catch { pendingError = error.localizedDescription }
    }

    private func addGroup(parentId: String?) async {
        do {
            let g = try await store.addResearchItem(
                parentId: parentId, title: "Untitled Group", kind: nil)
            selectedResearchId = g.id
            pendingRenameId = g.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// A group created "in" a piece is a top-level manifest node whose FOLDER
    /// lives under the piece's research/ — create then move (one visible item
    /// either way; the move is cheap and reuses the validated path).
    private func addGroupInPiece(pieceId: String) async {
        do {
            let g = try await store.addResearchItem(
                parentId: nil, title: "Untitled Group", kind: nil)
            try await store.moveResearchItems(ids: [g.id], to: .piece(pieceId))
            selectedResearchId = g.id
            pendingRenameId = g.id
        } catch { pendingError = error.localizedDescription }
    }

    private func addLinkForScope(title: String, url: String) async {
        do {
            let link: ResearchItem
            switch addLinkScope {
            case .shared:
                link = try await store.createResearchLink(
                    scope: .shared, title: title, url: url)
            case .piece(let pieceId):
                link = try await store.createResearchLink(
                    scope: .document(pieceId), title: title, url: url)
            case .group(let parentId):
                link = try await store.addResearchLink(
                    parentId: parentId, title: title, url: url)
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

    private func runAddFileInGroup(parentId: String) async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        do {
            _ = try await store.importResearchFiles(panel.urls, toParentId: parentId)
        } catch { pendingError = error.localizedDescription }
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

    /// Import a drop of raw providers (Finder files and/or browser image bitmaps)
    /// into `scope`. Browser drags carry rendered image data rather than a file URL,
    /// so `DropClassification` renders those to a temp PNG and everything imports
    /// through the same scope-respecting path. See `DropClassification`.
    private func importExternal(_ providers: [NSItemProvider], scope: Scope) async {
        let urls = await DropClassification.fileURLs(from: providers)
        guard !urls.isEmpty else { return }
        await runImport(urls: urls, scope: scope)
    }

    private func importExternalIntoGroup(
        _ providers: [NSItemProvider], parentId: String
    ) async {
        let urls = await DropClassification.fileURLs(from: providers)
        guard !urls.isEmpty else { return }
        do {
            _ = try await store.importResearchFiles(urls, toParentId: parentId)
        } catch { pendingError = error.localizedDescription }
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

    // MARK: - Internal drop (reorder + drop-into-group, within-section only)

    /// Within-section research drop: reorder against the target's sibling list,
    /// or (`.middle` on a group) move into that group. Cross-*section* drags are
    /// silently ignored — Task 7 adds them.
    ///
    /// Section membership is resolved via the item's ROOT ancestor path
    /// (`sectionScope(ofItemId:)`), NOT `scopeFor(item:)` on the item itself:
    /// a link dropped into a group carries a nil path, so a direct path check
    /// would misread it as `.shared` and either block a legitimate in-section
    /// reorder or (with a bare `findParentId != nil` escape hatch) leak a
    /// cross-section move. Roots always carry a reliable path, so classifying by
    /// root both admits every within-section drop and blocks every cross-section
    /// one. This is the intended guard; see the task report for the deviation
    /// from the brief's literal expression.
    private func handleInternalDrop(
        draggedId: String, position: DropIntent.Position,
        target: ResearchItem, scope: Scope
    ) async {
        guard draggedId != target.id else { return }
        guard TreeWalk.find(id: draggedId, in: store.manifest.research) != nil,
              sectionScope(ofItemId: draggedId) == scope,
              sectionScope(ofItemId: target.id) == scope else {
            return  // cross-section drop — Task 7
        }
        do {
            if position == .middle && target.type == .group {
                try await store.moveResearchItem(
                    id: draggedId, toParentId: target.id, atIndex: 0)
                return
            }
            let toParentId = findParentId(of: target.id)
            let siblings: [ResearchItem]
            if let toParentId,
               let parent = TreeWalk.find(id: toParentId, in: store.manifest.research) {
                siblings = parent.children ?? []
            } else {
                siblings = store.manifest.research
            }
            guard let targetIdx = siblings.firstIndex(where: { $0.id == target.id }) else { return }
            var destIdx = position == .top ? targetIdx : targetIdx + 1
            if let sourceIdx = siblings.firstIndex(where: { $0.id == draggedId }),
               sourceIdx < destIdx { destIdx -= 1 }
            try await store.moveResearchItem(
                id: draggedId, toParentId: toParentId, atIndex: destIdx)
        } catch ProjectStoreError.cycle {
            pendingError = "Can't move a group into one of its own descendants."
        } catch {
            pendingError = error.localizedDescription
        }
    }

    // MARK: - Tree helpers

    private func findParentId(of childId: String) -> String? {
        store.findResearchParentId(of: childId, in: store.manifest.research, parent: nil)
    }

    /// The visible section a research item belongs to, resolved via its ROOT
    /// ancestor's path. Nested items — especially pathless links — can't be
    /// classified directly (`scopeFor` reads a nil path as `.shared`), but the
    /// root always carries a reliable path.
    private func sectionScope(ofItemId id: String) -> Scope {
        var rootId = id
        while let parent = findParentId(of: rootId) { rootId = parent }
        guard let root = TreeWalk.find(id: rootId, in: store.manifest.research) else {
            return .shared
        }
        return scopeFor(item: root)
    }

    /// Which section a given research item belongs to, based on its path.
    /// Reliable for root items (they always carry a path); nested/pathless
    /// items must be resolved via `sectionScope(ofItemId:)`.
    private func scopeFor(item: ResearchItem) -> Scope {
        guard let path = item.path, path.hasPrefix("pieces/") else {
            return .shared
        }
        for piece in store.manifest.structure where piece.pieceKind == .loose {
            if let prefix = ProjectStore.pieceResearchPrefix(for: piece),
               path.hasPrefix(prefix) {
                return .piece(piece.id)
            }
        }
        return .shared
    }
}
