import SwiftUI
import MaughamCore

/// Palette-segment sidebar: card list + "+ New Card" kind menu. Cards load once
/// per manifest change (tripwire 4); rows do no I/O.
struct PaletteBinderList: View {
    let store: ProjectStore
    @Binding var selectedCardId: String?

    @State private var cards: [PaletteCard] = []

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedCardId) {
                Section(store.paletteGroupDisplayTitle) {
                    ForEach(cards) { card in
                        Label(card.title, systemImage: PaletteCardTile.kindSymbol(for: card.kind))
                            .tag(card.id)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Menu {
                ForEach(PaletteCard.Kind.allCases, id: \.self) { kind in
                    Button(kind.rawValue.capitalized) {
                        Task {
                            let item = try? await store.addPaletteCard(
                                title: "New \(kind.rawValue)", kind: kind)
                            selectedCardId = item?.id
                        }
                    }
                }
            } label: {
                Label("New Card", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .padding(8)
        }
        .task(id: store.manifest.modified) { cards = store.loadPaletteCards() }
    }
}
