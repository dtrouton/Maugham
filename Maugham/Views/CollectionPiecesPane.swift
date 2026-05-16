import SwiftUI

/// The Pieces segment of a Collection binder. Flat list with kind icons.
struct CollectionPiecesPane: View {
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?
    let onAddPiece: () -> Void   // opens the new-piece menu (T15 wires this)

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
                        PieceRow(piece: piece)
                            .tag(piece.id as String?)
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
