import SwiftUI
import MaughamCore
import AppKit
import UniformTypeIdentifiers

struct ResearchView: View {
    @Bindable var store: ProjectStore
    @Binding var selectedResearchId: String?

    @State private var renamingItemId: String?
    @State private var pendingRenameId: String?
    @State private var pendingError: String?
    @State private var showingAddLinkSheet: Bool = false
    @State private var addLinkParentId: String?
    @State private var selection = Set<String>()

    var body: some View {
        List(selection: $selection) {
            ForEach(store.manifest.research) { item in
                ResearchTreeNode(
                    item: item,
                    renamingItemId: $renamingItemId,
                    findParentId: { findParentId(of: $0) },
                    actions: treeActions,
                    tagFor: { $0.id })
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("New Note") {
                Task { await addResearchNote(parentId: nil) }
            }
            Button("New Group") {
                Task { await addGroup(parentId: nil) }
            }
            Button("Add File…") {
                Task { await runAddFile(parentId: nil) }
            }
            Button("Add Link…") {
                addLinkParentId = nil
                showingAddLinkSheet = true
            }
        }
        .sheet(isPresented: $showingAddLinkSheet) {
            AddResearchLinkSheet(
                onAdd: { title, url in
                    Task { await addLink(parentId: addLinkParentId, title: title, url: url) }
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
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            Task { await importExternal(providers, toParentId: nil) }
            return true
        }
        .onPasteCommand(of: ResearchPasteImporter.acceptedTypeIdentifiers) { items in
            Task { await handlePaste(items: items) }
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

    private func tryCommitPendingRename() {
        guard let id = pendingRenameId,
              TreeWalk.contains(id: id, in: store.manifest.research) else { return }
        renamingItemId = id
        pendingRenameId = nil
    }

    /// Not `private`: `BinderTreeSectionsTests` asks this bundle whether it
    /// accepts a drop, as the CONTROL for the binder tree's stubbed refusal —
    /// without a surface that really does accept, "the tree refuses" could pass
    /// on a type that refuses everywhere.
    var treeActions: ResearchTreeActions {
        ResearchTreeActions(
            rename: { id, newTitle in Task { await rename(id: id, to: newTitle) } },
            // Both accept: this pane's routing is built, and the drop's own
            // outcome is asynchronous — a refusal the store raises surfaces
            // through `pendingError`, not through the drag. `true` is the
            // behaviour this pane has always had; it is spelled here now
            // because the row asks rather than assuming (fix round 1).
            internalDrop: { draggedId, position, target in
                Task { await handleInternalDrop(
                    draggedId: draggedId, position: position, target: target) }
                return true
            },
            externalDrop: { providers, position, target in
                let parent = position == .middle && target.type == .group
                    ? target.id
                    : findParentId(of: target.id)
                Task { await importExternal(providers, toParentId: parent) }
                return true
            },
            newNote: { parentId in Task { await addResearchNote(parentId: parentId) } },
            newGroup: { parentId in Task { await addGroup(parentId: parentId) } },
            addFile: { parentId in Task { await runAddFile(parentId: parentId) } },
            addLink: { parentId in
                addLinkParentId = parentId
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
                    do {
                        try await store.deleteResearchItems(ids: ids)
                        pruneSelectionAfterDelete()
                    } catch { pendingError = error.localizedDescription }
                }
            })
    }

    private func handleInternalDrop(
        draggedId: String, position: DropIntent.Position, target: ResearchItem
    ) async {
        let movingIds = ResearchSelectionSync.expandedDragIds(
            draggedId: draggedId, selection: selection, in: store.manifest.research)
        // Dropping onto a row that is itself part of the moved batch is a
        // no-op (also covers dragged == target: movingIds always contains
        // draggedId).
        guard !movingIds.contains(target.id) else { return }
        let toParentId: String?
        let destIndex: Int
        switch position {
        case .top:
            toParentId = findParentId(of: target.id)
            destIndex = currentIndex(of: target.id, in: toParentId)
        case .bottom:
            toParentId = findParentId(of: target.id)
            destIndex = currentIndex(of: target.id, in: toParentId) + 1
        case .middle where target.type == .group:
            toParentId = target.id
            destIndex = 0
        case .middle:
            toParentId = findParentId(of: target.id)
            destIndex = currentIndex(of: target.id, in: toParentId) + 1
        }
        do {
            if movingIds.count == 1 {
                // Feed a POST-removal index: `moveResearchItem`'s same-parent
                // branch removes-then-inserts, so a pre-removal index drifts
                // ([A,B,C] drag A below B → [B,C,A] not [B,A,C]) — the same
                // math the multi-drag branch and the collection pane already
                // use. The middle-into-group case keeps its explicit index 0
                // (the target is the new parent, not a sibling).
                let atIndex: Int
                if position == .middle && target.type == .group {
                    atIndex = destIndex
                } else {
                    atIndex = ResearchSelectionSync.postRemovalInsertionIndex(
                        targetId: target.id, position: position,
                        movingIds: [draggedId],
                        siblings: siblingList(of: toParentId)) ?? destIndex
                }
                try await store.moveResearchItem(
                    id: draggedId, toParentId: toParentId, atIndex: atIndex)
            } else {
                let moveTarget: ResearchMoveTarget = toParentId.map {
                    ResearchMoveTarget.group($0)
                } ?? .sharedRoot
                // The batch mover removes all moving items BEFORE inserting,
                // so its atIndex is a post-removal index — compute it against
                // the destination siblings with the batch filtered out (nil
                // appends; only when target is nested elsewhere unexpectedly).
                let atIndex: Int?
                if position == .middle && target.type == .group {
                    atIndex = 0
                } else {
                    atIndex = ResearchSelectionSync.postRemovalInsertionIndex(
                        targetId: target.id, position: position,
                        movingIds: movingIds, siblings: siblingList(of: toParentId))
                }
                try await store.moveResearchItems(
                    ids: movingIds, to: moveTarget, atIndex: atIndex)
            }
        } catch ProjectStoreError.cycle {
            pendingError = "Can't move a group into one of its own descendants."
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func addGroup(parentId: String?) async {
        do {
            let g = try await store.addResearchItem(
                parentId: parentId, title: "Untitled Group", kind: nil)
            selectedResearchId = g.id
            pendingRenameId = g.id  // applied via .onChange when new row appears
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func addResearchNote(parentId: String?) async {
        do {
            let note = try await store.addResearchTextNote(parentId: parentId, title: "Untitled Note")
            selectedResearchId = note.id
            pendingRenameId = note.id  // applied via .onChange when new row appears
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func addLink(parentId: String?, title: String, url: String) async {
        do {
            let l = try await store.addResearchLink(
                parentId: parentId, title: title, url: url)
            selectedResearchId = l.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func runAddFile(parentId: String?) async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        await runImport(panel.urls, toParentId: parentId)
    }

    private func runImport(_ urls: [URL], toParentId: String?) async {
        do {
            _ = try await store.importResearchFiles(urls, toParentId: toParentId)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// Import a drop of raw providers (Finder files and/or browser image bitmaps)
    /// into `toParentId`. Browser drags carry rendered image data rather than a file
    /// URL, so `DropClassification` renders those to a temp PNG and everything imports
    /// through the same target-respecting path. See `DropClassification`.
    private func importExternal(_ providers: [NSItemProvider], toParentId: String?) async {
        let urls = await DropClassification.fileURLs(from: providers)
        guard !urls.isEmpty else { return }
        await runImport(urls, toParentId: toParentId)
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
            pruneSelectionAfterDelete()
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// Post-delete hygiene (2026-07-19 sweep W6): drop ids that no longer
    /// exist in the manifest from `selection`/`selectedResearchId` so
    /// `previewId(for:)` can't resolve to a ghost item.
    private func pruneSelectionAfterDelete() {
        selection = ResearchSelectionSync.pruned(
            selection, in: store.manifest.research)
        if let sel = selectedResearchId,
           TreeWalk.find(id: sel, in: store.manifest.research) == nil {
            selectedResearchId = nil
        }
    }

    // MARK: - Paste handling

    /// **The table itself moved to `ResearchPasteImporter`** (stage-2b Task 4),
    /// because the binder tree needs the same paste and stage 2b deletes this
    /// pane. Both surfaces call the one implementation, so there is no window
    /// in which a ⌘V here and a ⌘V in the tree can mean different things.
    ///
    /// **One arm of this pane's behaviour did change, and it changed from
    /// nothing to something**: a pasted URL arrives as `Data` rather than a
    /// `URL`, so the cast this table used to make returned nil and the paste
    /// silently did nothing at all. See `ResearchPasteImporter.url(from:)`.
    private func handlePaste(items: [NSItemProvider]) async {
        await ResearchPasteImporter(
            store: store,
            reportError: { pendingError = $0 }).paste(items)
    }

    // MARK: - Tree helpers

    private func findParentId(of childId: String) -> String? {
        findParentIdHelper(of: childId, in: store.manifest.research, parent: nil)
    }

    private func findParentIdHelper(
        of childId: String, in items: [ResearchItem], parent: String?
    ) -> String? {
        for item in items {
            if item.id == childId { return parent }
            if let children = item.children,
               let nested = findParentIdHelper(
                    of: childId, in: children, parent: item.id) {
                return nested
            }
        }
        return nil
    }

    private func siblingList(of parentId: String?) -> [ResearchItem] {
        if let parentId,
           let parent = TreeWalk.find(id: parentId, in: store.manifest.research) {
            return parent.children ?? []
        }
        return store.manifest.research
    }

    private func currentIndex(of id: String, in parentId: String?) -> Int {
        siblingList(of: parentId).firstIndex(where: { $0.id == id }) ?? 0
    }
}
