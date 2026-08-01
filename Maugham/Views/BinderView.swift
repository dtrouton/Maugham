import SwiftUI
import MaughamCore

struct BinderView: View {
    @Bindable var store: ProjectStore
    @Binding var selectedSubject: BinderSubject?
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
        List(selection: $selectedSubject) {
            projectRow
            outline(items: store.manifest.structure)
        }
        .listStyle(.sidebar)
        .overlay {
            if store.manifest.structure.isEmpty { emptyState }
        }
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
        HStack(spacing: 6) {
            Image(systemName: "books.vertical")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(store.manifest.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .contentShape(Rectangle())
        .tag(BinderSubject.project)
    }

    private func outline(items: [StructureItem]) -> some View {
        ForEach(items) { item in
            if item.type == .group, let children = item.children {
                DisclosureGroup {
                    AnyView(outline(items: children))
                } label: {
                    row(for: item)
                }
                .tag(BinderSubject.item(item.id))
            } else {
                row(for: item)
                    .tag(BinderSubject.item(item.id))
            }
        }
    }

    private func row(for item: StructureItem) -> some View {
        BinderRow(
            item: item,
            renamingItemId: $renamingItemId,
            onRename: { id, newTitle in
                Task { await rename(id: id, to: newTitle) }
            },
            onDrop: { draggedId, position in
                Task { await handleDrop(draggedId: draggedId,
                                        position: position,
                                        target: item) }
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

    private func deleteItem(id: String) async {
        do {
            try await store.deleteStructureItem(id: id)
            selectedSubject = Self.subject(selectedSubject, afterDeleting: id)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// What the window's subject becomes when `deletedId` leaves the structure.
    ///
    /// **Only the deleted item's own subject is cleared.** This is the one site
    /// in the app that sets the selection to `nil`, and with a project row above
    /// the tree it now has a value it must leave alone: `.project` names nothing
    /// in the structure, so no delete can invalidate it, and clearing it would
    /// silently move the window off a subject the writer chose while they were
    /// tidying up somewhere else.
    ///
    /// The `nil` it does still return is no longer a dead end — the project row
    /// is in the list even when the structure is empty, so deleting the last
    /// document leaves a subject one click away rather than a window with
    /// nothing selectable in it.
    static func subject(_ subject: BinderSubject?,
                        afterDeleting deletedId: String) -> BinderSubject? {
        subject == .item(deletedId) ? nil : subject
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
