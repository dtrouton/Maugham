import SwiftUI
import MaughamCore

/// Right-pane mode (⌘⌥P): pick a palette card and write against it — read-only
/// images, swatches, and sensory notes beside the editor. Cards load once per
/// manifest change (tripwire 4).
struct PalettePane: View {
    let store: ProjectStore

    @State private var cards: [PaletteCard] = []
    @State private var selectedCardId: String?
    @State private var images: [NSImage] = []

    nonisolated static func senseSymbol(for sense: PaletteCard.Sense) -> String {
        switch sense {
        case .sight: "eye"
        case .sound: "ear"
        case .smell: "nose"
        case .touch: "hand.raised"
        case .taste: "mouth"
        }
    }

    nonisolated static func groupedNotes(
        _ notes: [PaletteCard.SensoryNote]
    ) -> [(sense: PaletteCard.Sense?, notes: [PaletteCard.SensoryNote])] {
        var groups: [(sense: PaletteCard.Sense?, notes: [PaletteCard.SensoryNote])] = []
        for sense in PaletteCard.Sense.allCases {
            let matching = notes.filter { $0.sense == sense }
            if !matching.isEmpty { groups.append((sense, matching)) }
        }
        let untagged = notes.filter { $0.sense == nil }
        if !untagged.isEmpty { groups.append((nil, untagged)) }
        return groups
    }

    private var selectedCard: PaletteCard? {
        cards.first { $0.id == selectedCardId } ?? cards.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if cards.isEmpty {
                ContentUnavailableView(
                    "No palette cards",
                    systemImage: "paintpalette",
                    description: Text("Add cards from the Palette segment (binder)."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("Card", selection: Binding(
                    get: { selectedCard?.id ?? "" },
                    set: { selectedCardId = $0 })) {
                    ForEach(cards) { card in
                        Text(card.title).tag(card.id)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                Divider()
                if let card = selectedCard {
                    // The card itself is `PaletteCardReadView`'s, shared with
                    // the assistant column (M2 §6.2). This pane keeps the
                    // picker and the two reloads; the drawing has one home.
                    PaletteCardReadView(card: card, images: images)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: store.manifest.modified) { reloadCards() }
        .task(id: selectedCard?.id) { reloadImages() }
    }

    private func reloadCards() { cards = store.loadPaletteCards() }

    private func reloadImages() {
        guard let card = selectedCard else { images = []; return }
        images = card.imagePaths.compactMap {
            NSImage(contentsOf: store.url.appendingPathComponent($0))
        }
    }
}
