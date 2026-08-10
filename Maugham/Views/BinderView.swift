import SwiftUI
import MaughamCore

struct BinderView: View {
    @Bindable var store: ProjectStore
    @Binding var selectedSubject: BinderSubject?
    /// **The Research and Palette sections' state, owned by the WINDOW**
    /// (stage-3a Task 4). It was `@State` here until the sections learned to be
    /// opened and closed: `ProjectWindow.openResearchItem` and its Show twin
    /// have to open the section a revealed item lives in, and a flag held
    /// privately by whichever tree happens to be mounted is a flag the window
    /// cannot reach. Taken rather than defaulted so the compiler asks every
    /// host — a default would allocate a fresh state per body pass and lose the
    /// writer's disclosure and selection on the next render.
    let treeState: BinderTreeSectionsState
    /// Threaded to `BinderTreeSections`' Palette header — see its own doc
    /// comment (stage 2b Task 5). Defaulted for the mounted-tree fixtures that
    /// do not care about the wall's door.
    var canOpenPaletteWall: Bool = true
    var onOpenPaletteWall: () -> Void = {}
    @State private var renamingItemId: String?
    @State private var pendingError: String?
    @State private var pendingTidyParentId: String?
    @State private var showingTidyConfirmation: Bool = false

    var body: some View {
        // One `List`, always — including when the structure is empty. The empty
        // state used to REPLACE the list, and with a project row at its head that
        // would mean deleting the last document takes the only remaining subject
        // away with it: no row to click, nothing selectable, and a window whose
        // project-scoped panes can never be pointed at anything again.
        //
        // **The empty state is an overlay, and the two obvious alternatives were
        // both measured and rejected** (macOS 26.5, `BinderProjectRowTests`):
        //
        // - *as a row, `selectionDisabled()`* — the row is selected anyway, and
        //   because it carries no `.tag` the List writes `nil` through the
        //   binding. Clicking "No documents yet" silently deselected the project.
        //   `selectionDisabled` did not refuse it: `table.selectedRow` was 1.
        // - *as a `Section` footer* — a `Section` costs a leading row of its own
        //   even with no header, so the project row stopped being row zero and
        //   every row index moved with it.
        //
        // An overlay is neither a row nor a selection, so it cannot become a
        // subject. It intercepts only its own glyphs and buttons — nothing gives
        // it a background — so the project row above it stays clickable.
        //
        // **The selection is a projection, not the binding itself** (stage-2a
        // Task 4): the sections below carry untagged placeholder rows when they
        // are empty, and the measurement above is exactly why one of those may
        // not reach the binding. `BinderTreeSelection` refuses the `nil`; every
        // tagged row still writes straight through.
        //
        // **And it is a SET** (stage-2b Task 3), because 2b deletes the panes
        // that hold the app's only batch verbs and the tree has to carry them.
        // The window still has exactly one subject: it is derived from the set,
        // and a write of one row goes through the very rule 2a shipped.
        List(selection: BinderTreeSelection.binding(
                subject: $selectedSubject, state: treeState, store: store)) {
            projectRow
            outline(items: store.manifest.structure)
            // Below everything the tree already had — the sections are furniture
            // at the foot of the column, and the project row stays row zero.
            BinderTreeSections(store: store, state: treeState,
                               selectedSubject: $selectedSubject,
                               canOpenPaletteWall: canOpenPaletteWall,
                               onOpenPaletteWall: onOpenPaletteWall)
        }
        .listStyle(.sidebar)
        .overlay {
            if store.manifest.structure.isEmpty { emptyState }
        }
        .binderTreeSections(store: store, state: treeState,
                            selectedSubject: $selectedSubject)
        // Root context menu — attached at the binder level so it's
        // available even when the structure is empty (right-clicking
        // a row gives the per-row menu instead, no overlap).
        .contextMenu {
            let ext = store.manifest.type == .screenplay ? "fountain" : "md"
            Button("New Document") {
                Task { await addItem(parent: nil, kind: .document(extension: ext)) }
            }
            Button("New Group") {
                Task { await addItem(parent: nil, kind: .group) }
            }
        }
        .alert("Couldn't update project",
               isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } }
               )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pendingError ?? "")
        }
        .alert("Renumber filenames?",
               isPresented: $showingTidyConfirmation,
               presenting: pendingTidyParentId
        ) { _ in
            Button("Renumber", role: .destructive) {
                if let parentId = pendingTidyParentId {
                    Task { await runTidy(parentId: parentId) }
                } else {
                    Task { await runTidy(parentId: nil) }
                }
                pendingTidyParentId = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTidyParentId = nil
            }
        } message: { _ in
            Text("Existing files will be moved to fix gaps in numbering. This change is visible to other apps that read this folder.")
        }
    }

    /// The row at the head of the tree naming the project itself (spec §3.3).
    ///
    /// **It is a row, not a control.** Its whole implementation is a label and a
    /// `.tag`, so `List(selection:)` matches it against the binding exactly as it
    /// matches every chapter — tripwire 9 is the reason it is not a `Button` and
    /// not an `.onTapGesture`: hit-testing for either is unreliable inside
    /// `List(.sidebar)`. It writes the selection through the same binding on the
    /// same synchronous path a chapter does, and does nothing else on the way
    /// (tripwire 3).
    ///
    /// Deliberately not renamable, not draggable, not a drop target, and with no
    /// context menu of its own: the binder's root `.contextMenu` hangs off this
    /// view, so right-clicking here offers New Document / New Group exactly as
    /// right-clicking empty space always has. A menu on the row would shadow it.
    private var projectRow: some View {
        ProjectRowLabel(title: store.manifest.title)
            .tag(BinderSubject.project)
    }

    /// `depth` exists ONLY to place `ProjectRowLabel.childIndent`, and only at
    /// the top level. Everything in this list sits under the project row, so the
    /// top level is inset once; a group's own children are already indented
    /// under it by `DisclosureGroup`, and adding the inset per level as the
    /// recursion descends would compound it into a staircase.
    ///
    /// The inset goes on the whole `DisclosureGroup` rather than on its label,
    /// so a group's children move with their group. Padding the label alone
    /// leaves the children at the un-inset base — sitting to the LEFT of the row
    /// they belong to, which is the opposite of what the indent is for.
    private func outline(items: [StructureItem], depth: Int = 0) -> some View {
        let indent = depth == 0 ? ProjectRowLabel.childIndent : 0
        return ForEach(items) { item in
            if item.type == .group, let children = item.children {
                DisclosureGroup {
                    AnyView(outline(items: children, depth: depth + 1))
                } label: {
                    row(for: item)
                }
                .padding(.leading, indent)
                .tag(BinderSubject.item(item.id))
            } else {
                documentEntry(for: item, indent: indent)
            }
        }
    }

    /// A document's row, and — when it has research of its own — the fold that
    /// research hangs in (stage-2a Task 6).
    ///
    /// **The chevron belongs to the piece row, and the piece row is unchanged.**
    /// `row(for:)` is the same `BinderRow` with the same context menu either
    /// way, so a chapter that unfolds is still draggable, still renamable, and
    /// still the subject when clicked. This is the shape the group branch above
    /// already uses — the `.tag` and the inset go on the `DisclosureGroup` so
    /// the children move with the row they belong to (see `outline`).
    ///
    /// **An empty fold gets no chevron** (`PieceFold.showsDisclosure`): a
    /// triangle onto nothing is noise on every chapter of a novel whose writer
    /// has linked nothing yet. The row is still where the first item lands —
    /// Task 7 makes it a drop target.
    ///
    /// **Derived per render, from the manifest** (tripwire 4): the fold is a
    /// manifest walk, never a read. Deliberately no cache — a parallel copy of
    /// the manifest is a second source of truth for what a chapter's research
    /// is, and `manifest.modified` is the key it would have to be built on if
    /// profiling ever asks for one.
    @ViewBuilder
    private func documentEntry(for item: StructureItem, indent: CGFloat) -> some View {
        let fold = TreeSectionDerivation.pieceFold(
            for: item,
            structure: store.manifest.structure,
            research: store.manifest.research,
            projectType: store.manifest.type)
        if fold.showsDisclosure {
            DisclosureGroup {
                BinderPieceFold(store: store, state: treeState,
                                selectedSubject: $selectedSubject,
                                documentId: item.id, fold: fold)
            } label: {
                row(for: item)
            }
            .padding(.leading, indent)
            .tag(BinderSubject.item(item.id))
        } else {
            row(for: item)
                .padding(.leading, indent)
                .tag(BinderSubject.item(item.id))
        }
    }

    private func row(for item: StructureItem) -> some View {
        BinderRow(
            item: item,
            renamingItemId: $renamingItemId,
            onRename: { id, newTitle in
                Task { await rename(id: id, to: newTitle) }
            },
            // **A manuscript row now receives two kinds of drag** (stage-2a
            // Task 7). A chapter dropped on a chapter is the binder's own
            // reorder, unchanged and still `handleDrop`'s; a research note
            // dropped on a chapter is a scope change, and what it means is
            // `TreeDropIntent`'s to say. The row returns whichever answer
            // comes back, so a chapter that cannot take a note bounces it.
            onDrop: { draggedId, position in
                treeVerbs.routePieceRowDrop(
                    draggedId: draggedId, documentId: item.id,
                    structureReorder: {
                        Task { await handleDrop(draggedId: draggedId,
                                                position: position,
                                                target: item) }
                    })
            },
            // **And a third kind, from outside the app** (stage-2b Task 4): a
            // file dropped on a chapter is that chapter's research, which in a
            // novel means shared-plus-a-link and in a group or a screenplay's
            // script means a bounce. `TreeDropIntent` says which.
            onExternalDrop: { providers, position in
                treeVerbs.routeExternalDrop(
                    providers: providers, position: position,
                    target: .pieceRow(item.id))
            }
        )
        .contextMenu {
            Button("New Document") {
                let ext = store.manifest.type == .screenplay ? "fountain" : "md"
                Task { await addItem(parent: item, kind: .document(extension: ext)) }
            }
            Button("New Group") {
                Task { await addItem(parent: item, kind: .group) }
            }
            Divider()
            Button("Duplicate") {
                Task { await duplicate(id: item.id) }
            }
            Button("Rename") { renamingItemId = item.id }
            Button("Delete", role: .destructive) {
                Task { await deleteItem(id: item.id) }
            }
            if item.type == .group {
                Divider()
                Button("Tidy Filenames") {
                    pendingTidyParentId = item.id
                    showingTidyConfirmation = true
                }
            }
        }
    }

    // MARK: - Actions

    /// The tree's research verbs, over this view's own section state — the same
    /// value the Research section and every fold act through, so a drop on a
    /// chapter row and a drop on a row inside its fold cannot come to disagree
    /// about what scope means. Built per access like `BinderTreeSections.verbs`:
    /// it is a handful of closures over the store, and nothing in it is state.
    private var treeVerbs: BinderTreeVerbs {
        BinderTreeVerbs(store: store, state: treeState,
                        selectedSubject: $selectedSubject)
    }

    private func addItem(parent: StructureItem?, kind: StructureItemKind) async {
        let parentId: String? = {
            guard let parent else { return nil }
            return parent.type == .group ? parent.id : findParentId(of: parent.id)
        }()
        let title: String
        switch kind {
        case .document: title = "New Document"
        case .group:    title = "New Group"
        }
        do {
            let item = try await store.addStructureItem(
                parentId: parentId, title: title, kind: kind)
            renamingItemId = item.id  // immediately go to rename mode
            selectedSubject = .item(item.id)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// Empty-state shown when `store.manifest.structure` has zero items —
    /// an OVERLAY on the list rather than a replacement for it, so the project
    /// row survives an empty binder (see `body` for the two shapes that did not
    /// work). The binder's root `.contextMenu` covers right-click; this view
    /// gives the writer a discoverable button-driven alternative.
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text("No documents yet")
                .font(.headline)
            Text(
                store.manifest.type == .screenplay
                ? "Add your first screenplay."
                : "Add your first chapter or scene.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            let ext = store.manifest.type == .screenplay ? "fountain" : "md"
            HStack(spacing: 8) {
                Button {
                    Task {
                        await addItem(
                            parent: nil, kind: .document(extension: ext))
                    }
                } label: {
                    Label("New Document", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Task { await addItem(parent: nil, kind: .group) }
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rename(id: String, to newTitle: String) async {
        do {
            try await store.renameStructureItem(id: id, newTitle: newTitle)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// **No subject repair here.** It used to clear `selectedSubject` when the
    /// deleted id WAS the subject, which is the right answer for a document and
    /// the wrong one for a group — `TreeWalk.remove` takes the group's children
    /// with it, and the selected child's id is not the group's, so the subject
    /// survived naming a row that was gone. It was also one of three callers of
    /// `deleteStructureItem` and the only one that repaired anything. The rule
    /// now watches the structure instead: `SubjectValidationModifier`.
    private func deleteItem(id: String) async {
        do {
            try await store.deleteStructureItem(id: id)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func handleDrop(
        draggedId: String,
        position: DropIntent.Position,
        target: StructureItem
    ) async {
        guard draggedId != target.id else { return }
        let intent = DropIntent.classify(position: position, target: target)
        let toParentId: String?
        let destIndex: Int
        switch intent {
        case .insertAbove(let targetId):
            toParentId = findParentId(of: targetId)
            destIndex = currentIndex(of: targetId, in: toParentId)
        case .insertBelow(let targetId):
            toParentId = findParentId(of: targetId)
            destIndex = currentIndex(of: targetId, in: toParentId) + 1
        case .insertChild(let parentId):
            toParentId = parentId
            destIndex = 0
        }
        do {
            try await store.moveStructureItem(
                id: draggedId, toParentId: toParentId, atIndex: destIndex)
        } catch ProjectStoreError.cycle {
            pendingError = "Can't move a group into one of its own descendants."
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func duplicate(id: String) async {
        do {
            let copy = try await store.duplicateStructureItem(id: id)
            renamingItemId = copy.id  // immediately offer rename
            selectedSubject = .item(copy.id)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func runTidy(parentId: String?) async {
        do {
            try await store.tidyFilenames(parentId: parentId)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func currentIndex(of id: String, in parentId: String?) -> Int {
        let siblings: [StructureItem]
        if let parentId,
           let parent = TreeWalk.find(id: parentId, in: store.manifest.structure) {
            siblings = parent.children ?? []
        } else {
            siblings = store.manifest.structure
        }
        return siblings.firstIndex(where: { $0.id == id }) ?? 0
    }

    /// Find the parent id of an item by id, or nil if at root.
    private func findParentId(of childId: String) -> String? {
        Self.findParent(childId: childId, in: store.manifest.structure, parent: nil)
    }

    private static func findParent(
        childId: String, in items: [StructureItem], parent: String?
    ) -> String? {
        for item in items {
            if item.id == childId { return parent }
            if let children = item.children {
                if let found = findParent(
                    childId: childId, in: children, parent: item.id) {
                    return found
                }
            }
        }
        return nil
    }
}
