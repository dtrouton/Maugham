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
            } else {
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
                            })
                            .tag(piece.id as String?)
                            .contextMenu {
                                Button("Rename") {
                                    renamingItemId = piece.id
                                }
                                if piece.pieceKind == .loose {
                                    Button("Promote to Standalone Project…") {
                                        NotificationCenter.default.post(
                                            name: .maughamPromotePiece,
                                            object: nil,
                                            userInfo: ["piece_id": piece.id])
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
        }
    }

    private var header: some View {
        HStack {
            Text("Pieces").font(.headline)
            Spacer()
            Menu {
                Button("New Prose Story") {
                    NotificationCenter.default.post(
                        name: .maughamAddLoosePiece, object: nil)
                }
                Button("New Screenplay") {
                    NotificationCenter.default.post(
                        name: .maughamAddScreenplayPiece, object: nil)
                }
                Button("Link Existing Project…") {
                    NotificationCenter.default.post(
                        name: .maughamLinkProject, object: nil)
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
