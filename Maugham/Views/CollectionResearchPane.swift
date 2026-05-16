import SwiftUI

struct CollectionResearchPane: View {
    @Bindable var store: ProjectStore
    @Binding var selectedResearchId: String?
    let activePiece: StructureItem?
    let onAddSharedNote: () -> Void
    let onAddPieceNote: () -> Void

    var body: some View {
        List(selection: $selectedResearchId) {
            Section {
                ForEach(sharedItems()) { item in
                    Text(item.title).tag(item.id as String?)
                }
            } header: {
                HStack {
                    Text("Shared")
                    Spacer()
                    Button(action: onAddSharedNote) {
                        Image(systemName: "plus.circle")
                    }.buttonStyle(.plain)
                }
            }
            if let piece = activePiece, piece.pieceKind == .loose {
                Section {
                    let items = pieceItems(piece: piece)
                    if items.isEmpty {
                        Text("No research yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(items) { item in
                            Text(item.title).tag(item.id as String?)
                        }
                    }
                } header: {
                    HStack {
                        Text(piece.title)
                        Spacer()
                        Button(action: onAddPieceNote) {
                            Image(systemName: "plus.circle")
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

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
}
