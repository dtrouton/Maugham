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
    @State private var selection = Set<String>()

    private enum AddLinkScope: Equatable {
        case shared
        case piece(String)
        case group(String)
    }

    var body: some View {
        List(selection: $selection) {
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
        .onChange(of: selection) { _, newValue in
            selectedResearchId = ResearchSelectionSync.previewId(for: newValue)
        }
        .onChange(of: selectedResearchId) { _, newValue in
            if let id = newValue, !selection.contains(id) {
                selection = [id]
            }
        }
        .onAppear {
            if let id = selectedResearchId { selection = [id] }
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
        .dropDestination(for: String.self) { ids, _ in
            guard !ids.isEmpty else { return false }
            Task { await moveToSection(ids: ids, scope: .shared) }
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
        .dropDestination(for: String.self) { ids, _ in
            guard !ids.isEmpty else { return false }
            Task { await moveToSection(ids: ids, scope: .piece(piece.id)) }
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
            delete: { id in Task { await delete(id: id) } },
            selectionForRow: { rowId in
                ResearchSelectionSync.expandedDragIds(
                    draggedId: rowId, selection: selection,
                    in: store.manifest.research)
            },
            moveTargets: { ids in
                ResearchSelectionSync.moveTargets(forIds: ids, manifest: store.manifest)
            },
            move: { ids, target in
                Task {
                    do { try await store.moveResearchItems(ids: ids, to: target) }
                    catch { pendingError = error.localizedDescription }
                }
            },
            deleteMany: { ids in
                Task {
                    do { try await store.deleteResearchItems(ids: ids) }
                    catch { pendingError = error.localizedDescription }
                }
            })
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

    /// Research drop. Within a section it reorders against the target's
    /// sibling list, or (`.middle` on a group) moves into that group. Across
    /// sections (Shared ↔ piece, piece ↔ piece) it becomes a scope move via the
    /// batch mover, which relocates the file and rewrites the manifest path
    /// (Task 3 also cleans up any now-orphaned links); role-bearing items refuse
    /// the cross-scope move with a thrown error, surfaced via `pendingError`.
    ///
    /// Section membership is resolved via the item's ROOT ancestor path
    /// (`sectionScope(ofItemId:)`), NOT a direct path check on the item
    /// itself: a link dropped into a group carries a nil path, so a direct
    /// check would misread it as `.shared`. Roots always carry a reliable path, so
    /// classifying by root correctly separates within-section drops from
    /// cross-section ones. The `scope` parameter (the section the target row is
    /// rendered in) is unused for internal drops — target membership is derived
    /// from the tree — but is retained for external drops.
    private func handleInternalDrop(
        draggedId: String, position: DropIntent.Position,
        target: ResearchItem, scope: Scope
    ) async {
        guard draggedId != target.id else { return }
        guard TreeWalk.find(id: draggedId, in: store.manifest.research) != nil else { return }
        let draggedSection = sectionScope(ofItemId: draggedId)
        let targetSection = sectionScope(ofItemId: target.id)

        // Whole-selection drag: dragging a row inside a multi-selection carries
        // the entire selection (expanded to visual order). Route every such
        // drop through the batch mover, which tolerates mixed source sections.
        let movingIds = ResearchSelectionSync.expandedDragIds(
            draggedId: draggedId, selection: selection, in: store.manifest.research)
        // Dropping onto a row that is itself part of the moved batch is a
        // no-op (simplest safe choice: there is no meaningful anchor when the
        // anchor row is leaving its slot).
        guard !movingIds.contains(target.id) else { return }
        if movingIds.count > 1 {
            await handleMultiDrop(
                movingIds: movingIds, position: position,
                target: target, targetSection: targetSection)
            return
        }

        do {
            if draggedSection != targetSection {
                try await handleCrossSectionDrop(
                    draggedId: draggedId, position: position,
                    target: target, targetSection: targetSection)
                return
            }
            // Same-section: reorder, or move into a group.
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

    /// A cross-section drag = scope move. Dropping `.middle` on a group in the
    /// other section moves into that group; a row drop targets the section's
    /// root at an index derived from the target's top-level position (append
    /// when the target is nested). Throws propagate to `handleInternalDrop`'s
    /// catch, which surfaces them via `pendingError`.
    private func handleCrossSectionDrop(
        draggedId: String, position: DropIntent.Position,
        target: ResearchItem, targetSection: Scope
    ) async throws {
        if position == .middle && target.type == .group {
            try await store.moveResearchItems(
                ids: [draggedId], to: .group(target.id), atIndex: 0)
            return
        }
        let sectionTarget: ResearchMoveTarget
        if case .piece(let pieceId) = targetSection {
            sectionTarget = .piece(pieceId)
        } else {
            sectionTarget = .sharedRoot
        }
        // Insert relative to the target row's top-level position; append when
        // the target is nested inside a group (helper returns nil).
        //
        // `moveResearchItems` removes the batch (here just `draggedId`) BEFORE
        // inserting, so the index must be POST-removal. `manifest.research` is
        // one flat array holding BOTH sections' top-level items, so a
        // pre-removal `firstIndex` drifts right by one whenever the dragged
        // top-level item precedes the target in that array — the same class
        // Task 8 fixed for multi-drag. `postRemovalInsertionIndex` filters the
        // moving id out first, matching the store's insertion list exactly.
        let atIndex = ResearchSelectionSync.postRemovalInsertionIndex(
            targetId: target.id, position: position,
            movingIds: [draggedId], siblings: store.manifest.research)
        try await store.moveResearchItems(
            ids: [draggedId], to: sectionTarget, atIndex: atIndex)
    }

    /// A multi-selection internal drag. The whole selection (possibly spanning
    /// both sections) routes through the batch mover: `.middle` on a group moves
    /// into that group; a drop beside a nested row moves into that row's parent
    /// group at the drop position; a drop beside a top-level row targets the
    /// drop's section root at the target's position. The store validates cycles
    /// and tolerates mixed source sections.
    ///
    /// Index semantics: `moveResearchItems` removes the whole batch BEFORE
    /// inserting at `atIndex`, so every index here is computed post-removal
    /// via `ResearchSelectionSync.postRemovalInsertionIndex` (nil = append).
    private func handleMultiDrop(
        movingIds: [String], position: DropIntent.Position,
        target: ResearchItem, targetSection: Scope
    ) async {
        do {
            if position == .middle && target.type == .group {
                try await store.moveResearchItems(
                    ids: movingIds, to: .group(target.id), atIndex: 0)
                return
            }
            if let toParentId = findParentId(of: target.id) {
                let groupChildren = TreeWalk.find(
                    id: toParentId, in: store.manifest.research)?.children ?? []
                let atIndex = ResearchSelectionSync.postRemovalInsertionIndex(
                    targetId: target.id, position: position,
                    movingIds: movingIds, siblings: groupChildren)
                try await store.moveResearchItems(
                    ids: movingIds, to: .group(toParentId), atIndex: atIndex)
                return
            }
            let atIndex = ResearchSelectionSync.postRemovalInsertionIndex(
                targetId: target.id, position: position,
                movingIds: movingIds, siblings: store.manifest.research)
            try await store.moveResearchItems(
                ids: movingIds, to: sectionRootTarget(targetSection), atIndex: atIndex)
        } catch ProjectStoreError.cycle {
            pendingError = "Can't move a group into one of its own descendants."
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func sectionRootTarget(_ scope: Scope) -> ResearchMoveTarget {
        if case .piece(let pieceId) = scope {
            return .piece(pieceId)
        }
        return .sharedRoot
    }

    /// An internal drag released on a section's header or empty area (not on a
    /// row) moves the dragged items to that section's root. Row-level
    /// `.dropDestination`s sit deeper in the hierarchy and win when the pointer
    /// is over a row; this section-level one catches header/whitespace releases.
    /// Rows drag exactly one id (a single-String Transferable payload), which
    /// is expanded to the whole selection when the drag began inside it, so
    /// releasing a multi-selection on a header moves all of them.
    private func moveToSection(ids: [String], scope: Scope) async {
        guard let draggedId = ids.first else { return }
        let movingIds = ResearchSelectionSync.expandedDragIds(
            draggedId: draggedId, selection: selection, in: store.manifest.research)
        do {
            try await store.moveResearchItems(ids: movingIds, to: sectionRootTarget(scope))
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
    /// classified by their own path (a nil path reads as `.shared`), but the
    /// root always carries a reliable path. The root-walk + path→scope mapping
    /// is extracted onto `ProjectStore` (`researchRootPath` +
    /// `researchScopePieceId`) so it's unit-testable; see `ResearchMoveTests`.
    private func sectionScope(ofItemId id: String) -> Scope {
        let rootPath = ProjectStore.researchRootPath(
            ofItemId: id, in: store.manifest.research)
        if let pieceId = store.researchScopePieceId(ofPath: rootPath) {
            return .piece(pieceId)
        }
        return .shared
    }
}
