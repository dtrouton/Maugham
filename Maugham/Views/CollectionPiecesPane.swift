import SwiftUI

/// The Pieces segment of a Collection binder. Flat list with kind icons,
/// inline rename support, and a right-click context menu.
struct CollectionPiecesPane: View {
    @Bindable var store: ProjectStore
    @Binding var selectedSubject: BinderSubject?
    @Binding var renamingItemId: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pieceList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The row at the head of the pieces list naming the Collection itself
    /// (spec §3.3), and in a Collection the **only** thing that constructs
    /// `BinderSubject.project`: `ProjectWindow.binderColumn` mounts `BinderView`
    /// — which carries the other one — for non-collection projects only.
    ///
    /// **It is a row, not a control**, for the same reason `BinderView`'s is:
    /// its whole implementation is a label and a `.tag`, so `List(selection:)`
    /// matches it against the binding exactly as it matches a piece. Tripwire 9
    /// is why it is neither a `Button` nor an `.onTapGesture` — hit-testing for
    /// either is unreliable inside `List(.sidebar)`.
    ///
    /// **Deliberately none of this pane's own row idioms.** A `PieceRow` is
    /// renamable inline (tripwire 16's focus dance), is a drag source and a drop
    /// target for reordering, and carries a context menu with Rename / Promote /
    /// Delete. The project row is a label: there is no piece order for it to
    /// take part in, and nothing a piece dropped on it could mean.
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

    /// One `List`, always — including when the Collection has no pieces.
    ///
    /// **The empty state is an OVERLAY, not a replacement.** It used to replace
    /// the list outright, and with a project row at the list's head that would
    /// mean a Collection with no pieces has no subject it can be given at all —
    /// which is not the rare deleted-the-last-one case it is in a novel:
    /// `ProjectFactory.createCollectionProject` writes an **empty structure**,
    /// so it is what every new Collection opens on, and project-scoped intent is
    /// exactly what a writer wants there first.
    ///
    /// `BinderView` measured the two obvious alternatives on macOS 26.5 and both
    /// failed — a `selectionDisabled()` message row is selected anyway and, with
    /// no `.tag`, writes `nil` through the binding; a `Section` costs a leading
    /// row that moves every index beneath it. Not re-spent here. What was
    /// measured here, because `ContentUnavailableView` is a system view chained
    /// to a full frame rather than `BinderView`'s hand-built `VStack` of glyphs:
    /// the overlay does not take the project row's clicks
    /// (`CollectionProjectRowTests.test_theEmptyStateOverlayDoesNotSwallowTheProjectRow`
    /// hit-tests it).
    private var pieceList: some View {
        List(selection: $selectedSubject) {
            projectRow
            ForEach(store.manifest.structure) { piece in
                PieceRow(
                    piece: piece,
                    renamingItemId: $renamingItemId,
                    onRename: { id, newTitle in
                        Task {
                            try? await store.renamePiece(
                                pieceId: id, newTitle: newTitle)
                        }
                    },
                    onDrop: { draggedId, position in
                        handleDrop(
                            draggedId: draggedId,
                            targetId: piece.id,
                            position: position)
                    })
                    .tag(BinderSubject.item(piece.id))
                    .contextMenu {
                        Button("Rename") {
                            renamingItemId = piece.id
                        }
                        if piece.pieceKind == .loose {
                            Button("Promote to Standalone Project…") {
                                MaughamEvent.post(.maughamPromotePiece, to: .keyWindow, payload: ["piece_id": piece.id])
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            Task {
                                try? await store.deleteStructureItem(id: piece.id)
                            }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.manifest.structure.isEmpty { emptyState }
        }
    }

    /// Shown when the Collection holds no pieces — an overlay on the list rather
    /// than a replacement for it (see `pieceList`). Tripwire 15: the full-frame
    /// chain is what stops SwiftUI sizing this to its intrinsic content.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No pieces yet", systemImage: "doc.text")
        } description: {
            Text("Add your first piece. Use the + button.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drag-reorder

    private func handleDrop(
        draggedId: String,
        targetId: String,
        position: DropIntent.Position
    ) {
        guard let sourceIdx = store.manifest.structure.firstIndex(where: { $0.id == draggedId }),
              let targetIdx = store.manifest.structure.firstIndex(where: { $0.id == targetId }) else {
            return
        }
        // .top = before target; .bottom/.middle = after target.
        // Pieces don't have children so .middle is treated as .top (just above).
        var destIdx = (position == .bottom) ? targetIdx + 1 : targetIdx
        // If the source is before the target, removing it shifts indices down
        // by 1, so the effective destination index decreases by 1.
        if sourceIdx < destIdx { destIdx -= 1 }
        Task {
            try? await store.movePiece(pieceId: draggedId, toIndex: destIdx)
        }
    }

    private var header: some View {
        HStack {
            Text("Pieces").font(.headline)
            Spacer()
            Menu {
                Button("New Prose Story") {
                    MaughamEvent.post(.maughamAddLoosePiece, to: .keyWindow)
                }
                Button("New Screenplay") {
                    MaughamEvent.post(.maughamAddScreenplayPiece, to: .keyWindow)
                }
                Button("Link Existing Project…") {
                    MaughamEvent.post(.maughamLinkProject, to: .keyWindow)
                }
            } label: {
                Image(systemName: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a piece")
        }
        .padding(8)
    }
}
