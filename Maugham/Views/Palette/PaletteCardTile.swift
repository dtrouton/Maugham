import SwiftUI

/// One card on the palette wall. The pure helpers (`kindSymbol`, `snippet`) are
/// the tested surface; the body does NO I/O (thumbnails are pre-loaded by the
/// wall, tripwire 4) and is a plain `Button(.plain)` for click (tripwire 9).
struct PaletteCardTile: View {
    let card: PaletteCard
    let thumbnail: NSImage?
    let isSelected: Bool
    let onSelect: () -> Void

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
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(height: 110).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(height: 110)
                        .overlay(Image(systemName: Self.kindSymbol(for: card.kind))
                            .font(.title).foregroundStyle(.secondary))
                }
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

    private func swatchColor(_ hex: String) -> Color {
        guard let rgb = PaletteCard.color(fromHex: hex) else { return .clear }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
