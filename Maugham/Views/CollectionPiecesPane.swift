import SwiftUI

/// The Pieces segment of a Collection binder. Flat list with kind icons,
/// inline rename support, and a right-click context menu.
struct CollectionPiecesPane: View {
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?
    @Binding var renamingItemId: String?
    let onAddPiece: () -> Void   // unused (Menu in header fires directly), kept for API compat

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.manifest.structure.isEmpty {
                ContentUnavailableView {
                    Label("No pieces yet", systemImage: "doc.text")
                } description: {
                    Text("Add your first piece. Use the + button.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                pieceList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var pieceList: some View {
        List(selection: $selectedItemId) {
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
                    .tag(piece.id as String?)
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
