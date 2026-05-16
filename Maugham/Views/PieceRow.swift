import SwiftUI

/// One row in the Collection's Pieces segment: kind icon, title, status dot.
struct PieceRow: View {
    let piece: StructureItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
            Text(piece.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let status = piece.status, !status.isEmpty {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var iconName: String {
        switch piece.pieceKind {
        case .reference:
            return "link"
        case .loose, .none:
            if let path = piece.path, path.hasSuffix(".fountain") {
                return "film"
            }
            return "doc.text"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "draft":     return .gray
        case "revising":  return .orange
        case "final":     return .green
        default:          return .secondary
        }
    }
}
