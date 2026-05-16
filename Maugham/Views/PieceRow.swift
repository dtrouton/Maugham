import SwiftUI

/// One row in the Collection's Pieces segment: kind icon, title, status dot.
/// Supports inline rename when `renamingItemId == piece.id`.
struct PieceRow: View {
    let piece: StructureItem
    @Binding var renamingItemId: String?
    let onRename: (String, String) -> Void   // (pieceId, newTitle)

    @State private var draftTitle: String = ""
    @FocusState private var isRenameFieldFocused: Bool

    var body: some View {
        if renamingItemId == piece.id {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .center)
                TextField("", text: $draftTitle, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .focused($isRenameFieldFocused)
                    .onAppear {
                        draftTitle = piece.title
                        DispatchQueue.main.async {
                            isRenameFieldFocused = true
                        }
                    }
                    .onExitCommand { renamingItemId = nil }
                Spacer()
            }
            .contentShape(Rectangle())
        } else {
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
            .contentShape(Rectangle())
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

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != piece.title {
            onRename(piece.id, trimmed)
        }
        renamingItemId = nil
    }
}
