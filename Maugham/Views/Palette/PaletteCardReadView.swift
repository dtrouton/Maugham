import SwiftUI
import MaughamCore

/// **One palette card, read-only** — pictures, swatches, sensory notes grouped
/// by sense, then the freeform body.
///
/// Extracted from `PalettePane` in M2 Plan 2 Task 5, when the assistant column
/// needed the same card. It is a straight lift: `PalettePane` keeps the card
/// PICKER and the manifest-change reload, and hands the drawing here. The
/// alternative — a second card layout in the column — is the shape this project
/// has paid for before (five block splitters, one shared parser), and it fails
/// quietly: two surfaces showing one card, differing in what they show of it.
///
/// **Images are handed in already loaded**, because who loads them is a
/// lifetime question and it differs between the two callers: `PalettePane`
/// reloads on the selected card's id, the column on the studied reference's.
/// A view that loaded them itself would decode inside a `body` (tripwire 4).
struct PaletteCardReadView: View {
    let card: PaletteCard
    let images: [NSImage]

    /// The sense glyphs stay `PalettePane`'s — this view names no symbol of its
    /// own, so the pane and the column cannot disagree about what "smell" looks
    /// like.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if !card.swatches.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(card.swatches, id: \.self) { hex in
                            if let rgb = PaletteCard.color(fromHex: hex) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b))
                                    .frame(width: 20, height: 20)
                                    .help(hex)
                            }
                        }
                    }
                }
                ForEach(Array(PalettePane.groupedNotes(card.notes).enumerated()),
                        id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            group.sense?.rawValue.capitalized ?? "Notes",
                            systemImage: group.sense.map(PalettePane.senseSymbol(for:))
                                ?? "ellipsis")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(group.notes.enumerated()), id: \.offset) { _, note in
                            Text(note.text).font(.callout)
                        }
                    }
                }
                if !card.body.isEmpty {
                    Divider()
                    Text(card.body).font(.callout)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
