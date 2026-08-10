import SwiftUI
import MaughamCore

/// **One palette card, read-only** — pictures, swatches, sensory notes grouped
/// by sense, then the freeform body.
///
/// Extracted from `PalettePane` in M2 Plan 2 Task 5, when the assistant column
/// needed the same card. It is a straight lift: `PalettePane` kept the card
/// PICKER and the manifest-change reload, and handed the drawing here. The
/// alternative — a second card layout in the column — is the shape this project
/// has paid for before (five block splitters, one shared parser), and it fails
/// quietly: two surfaces showing one card, differing in what they show of it.
///
/// **`PalettePane` itself is gone** (stage 3a Task 6 — its right-pane `⌘⌥P`
/// mount died with `DetailSegment.palette`; the tree's own Palette section,
/// stage 2a, is where a card is picked now). Its two sense-glyph statics
/// outlived it: `PaletteCardEditor` needs them independently of any pane, so
/// they moved here rather than to whichever caller happened to ask first —
/// this view is the one place both callers already agree a card's drawing
/// lives.
///
/// **Images are handed in already loaded**, because who loads them is a
/// lifetime question and it differs between callers: a card picker reloads on
/// the selected card's id, the assistant column on the studied reference's. A
/// view that loaded them itself would decode inside a `body` (tripwire 4).
struct PaletteCardReadView: View {
    let card: PaletteCard
    let images: [NSImage]

    /// Which SF Symbol stands for a sense. Kept beside `groupedNotes` below
    /// so the two callers (`PaletteCardEditor`'s sense picker, this view's own
    /// grouped-notes header) cannot disagree about what "smell" looks like.
    nonisolated static func senseSymbol(for sense: PaletteCard.Sense) -> String {
        switch sense {
        case .sight: "eye"
        case .sound: "ear"
        case .smell: "nose"
        case .touch: "hand.raised"
        case .taste: "mouth"
        }
    }

    /// Notes grouped by sense (in `PaletteCard.Sense.allCases` order), then the
    /// untagged notes last.
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
                ForEach(Array(Self.groupedNotes(card.notes).enumerated()),
                        id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            group.sense?.rawValue.capitalized ?? "Notes",
                            systemImage: group.sense.map(Self.senseSymbol(for:))
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
