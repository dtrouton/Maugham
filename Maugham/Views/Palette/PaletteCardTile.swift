import SwiftUI

/// One card on the palette wall. The pure helpers (`kindSymbol`, `snippet`) are
/// the tested surface; the body does NO I/O (thumbnails are pre-loaded by the
/// wall, tripwire 4) and is a plain `Button(.plain)` for click (tripwire 9).
struct PaletteCardTile: View {
    let card: PaletteCard
    let thumbnail: NSImage?
    let isSelected: Bool
    let onSelect: () -> Void

    /// What fills the 110pt wall-tile header. A thumbnail wins; failing that, a
    /// swatch-only card paints its swatches as colour bands rather than showing the
    /// bare kind-symbol placeholder; only a card with neither falls to the placeholder.
    enum HeaderMode: Equatable { case image, swatches, placeholder }

    nonisolated static func headerMode(hasThumbnail: Bool, swatchCount: Int) -> HeaderMode {
        if hasThumbnail { return .image }
        if swatchCount > 0 { return .swatches }
        return .placeholder
    }

    nonisolated static func kindSymbol(for kind: PaletteCard.Kind) -> String {
        switch kind {
        case .location: "mappin.and.ellipse"
        case .character: "person"
        case .motif: "sparkles"
        case .other: "square.grid.2x2"
        }
    }

    /// Tagged notes first (in order), then untagged, capped at `limit`. Tagged
    /// render as `"<sense>: <text>"`, untagged as bare text; joined with `\n`.
    nonisolated static func snippet(for notes: [PaletteCard.SensoryNote], limit: Int) -> String {
        let tagged = notes.filter { $0.sense != nil }
        let untagged = notes.filter { $0.sense == nil }
        return (tagged + untagged).prefix(limit).map { note in
            if let sense = note.sense { "\(sense.rawValue): \(note.text)" } else { note.text }
        }.joined(separator: "\n")
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                header
                HStack(spacing: 4) {
                    Image(systemName: Self.kindSymbol(for: card.kind))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(card.title).font(.headline).lineLimit(1)
                }
                if !card.swatches.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(card.swatches.prefix(8), id: \.self) { hex in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(swatchColor(hex)).frame(width: 16, height: 16)
                        }
                    }
                }
                let snippet = Self.snippet(for: card.notes, limit: 2)
                if !snippet.isEmpty {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var header: some View {
        switch Self.headerMode(hasThumbnail: thumbnail != nil, swatchCount: card.swatches.count) {
        case .image:
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(height: 110).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        case .swatches:
            HStack(spacing: 0) {
                ForEach(Array(card.swatches.prefix(6).enumerated()), id: \.offset) { _, hex in
                    Rectangle().fill(swatchColor(hex))
                }
            }
            .frame(height: 110)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .placeholder:
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(height: 110)
                .overlay(Image(systemName: Self.kindSymbol(for: card.kind))
                    .font(.title).foregroundStyle(.secondary))
        }
    }

    private func swatchColor(_ hex: String) -> Color {
        guard let rgb = PaletteCard.color(fromHex: hex) else { return .clear }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
