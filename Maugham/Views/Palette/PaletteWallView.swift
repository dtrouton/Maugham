import SwiftUI
import MaughamCore

/// The palette wall — the centre-column surface the Palette tree section's
/// "Open Wall" door opens (`ProjectWindow.showsPaletteWall`). It was a binder
/// segment's centre until shell-finish stage 2b Tasks 5 and 7.
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
        VStack(alignment: .leading, spacing: 0) {
            Text(store.paletteGroupDisplayTitle)
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
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

/// **The palette wall's own centre content** — the wall itself, or (once a
/// card is selected on it) that card's editor with a bar back to the wall
/// (stage 2b Task 5). **One door since Task 7** — `ProjectWindow.editorPane`'s
/// `showsPaletteWall`. It was written to serve that door and the `.palette`
/// segment arm alike so the two could not draw the wall differently; the
/// segment and its arm died with the strip, and the sentence naming them
/// outlived them by a task.
///
/// **A view of its own, not a `@ViewBuilder` method on `ProjectWindow`**,
/// because it needs `@FocusState` to make Escape reliable. `ProjectSearchView`
/// rides `.onExitCommand` off a query field that autofocuses on appear and
/// stays focused for essentially the overlay's whole life — its own doc
/// comment measures why `.onExitCommand` needs a real first responder to climb
/// from. Nothing here is a text responder, so without a claim of its own
/// `.onExitCommand` would have nothing to ride up from. The claim is deferred
/// the tripwire-16 way — a same-tick `.onAppear` focus write loses the race
/// with this view's own mount, the same race `BinderRow.claimFocus()` runs
/// into one directory over.
struct PaletteWallCentre: View {
    let store: ProjectStore
    @Binding var selectedPaletteCardId: String?
    let onClose: () -> Void
    /// The persona the wall is opened from, asked directly
    /// (`Persona.editsResearchInTheCentre`) by the card arm below rather than
    /// threaded as a pre-computed bool — shell-finish stage 3b Task 6, Denver's
    /// ruling that Review adjudicates and does not edit from its own columns.
    /// `ResearchSubjectCentre` reads the same predicate at its own mount; never
    /// `== .review` at either site.
    let persona: Persona

    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if let cardId = selectedPaletteCardId,
               store.paletteCardItems().contains(where: { $0.id == cardId }) {
                VStack(spacing: 0) {
                    HStack {
                        Button { selectedPaletteCardId = nil } label: {
                            Label("Wall", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    Divider()
                    if persona.editsResearchInTheCentre {
                        PaletteCardEditor(store: store, cardId: cardId)
                    } else {
                        PaletteCardReadHost(store: store, cardId: cardId)
                    }
                }
            } else {
                PaletteWallView(store: store, selectedCardId: $selectedPaletteCardId)
            }
        }
        .focusable()
        .focused($isFocused)
        .onExitCommand(perform: onClose)
        .onAppear { claimFocus() }
    }

    private func claimFocus() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            isFocused = true
        }
    }
}
