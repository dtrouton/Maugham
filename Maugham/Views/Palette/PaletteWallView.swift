import SwiftUI
import MaughamCore

/// The palette wall — center-pane surface for BinderSegment.palette.
/// Cards + thumbnails load once per manifest change (tripwire 4); tiles do
/// no I/O in body. Thumbnail file reads are UI image loads, not manuscript
/// text reads, so they don't cross the ADR-0018 boundary.
struct PaletteWallView: View {
    let store: ProjectStore
    @Binding var selectedCardId: String?

    @State private var cards: [PaletteCard] = []
    @State private var thumbnails: [String: NSImage] = [:]

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]
    private static let thumbnailMaxEdge: CGFloat = 320

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView(
                    "No palette cards",
                    systemImage: "paintpalette",
                    description: Text("Gather images, swatches, and sensory notes per location, character, or motif. Add a card from the sidebar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(cards) { card in
                            PaletteCardTile(
                                card: card,
                                thumbnail: thumbnails[card.id],
                                isSelected: selectedCardId == card.id,
                                onSelect: { selectedCardId = card.id })
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: store.manifest.modified) { await reload() }
    }

    private func reload() async {
        let loaded = store.loadPaletteCards()
        var thumbs: [String: NSImage] = [:]
        for card in loaded {
            guard let first = card.imagePaths.first else { continue }
            let url = store.url.appendingPathComponent(first)
            if let image = NSImage(contentsOf: url) {
                thumbs[card.id] = downscaled(image, maxEdge: Self.thumbnailMaxEdge)
            }
        }
        cards = loaded
        thumbnails = thumbs
    }

    private func downscaled(_ image: NSImage, maxEdge: CGFloat) -> NSImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let scale = maxEdge / longest
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let out = NSImage(size: target)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        out.unlockFocus()
        return out
    }
}
