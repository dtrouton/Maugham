import SwiftUI

/// One row in the Collection's Pieces segment: kind icon, title, status dot.
/// Supports inline rename when `renamingItemId == piece.id`.
/// Supports drag-reorder via `.draggable` + `.dropDestination` on the
/// non-rename branch, mirroring `BinderRow`'s pattern.
struct PieceRow: View {
    let piece: StructureItem
    @Binding var renamingItemId: String?
    let onRename: (String, String) -> Void   // (pieceId, newTitle)
    let onDrop: (_ draggedId: String, _ position: DropIntent.Position) -> Void

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
                        claimFocus()
                    }
                    // Cover the case where `renamingItemId` flips to this
                    // row while it was already visible (e.g., context-menu
                    // Rename). `.onAppear` only fires when the if-branch
                    // first creates the rename subtree; `.onChange` covers
                    // the in-place flip. Same belt-and-braces approach as
                    // BinderRow.
                    .onChange(of: renamingItemId) { _, new in
                        if new == piece.id {
                            draftTitle = piece.title
                            claimFocus()
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
            .draggable(piece.id) {
                Text(piece.title)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
            .dropDestination(for: String.self) { ids, location in
                guard let droppedId = ids.first, droppedId != piece.id else {
                    return false
                }
                // Top half = above this row; bottom half = below.
                let rowHeight: CGFloat = 22
                let position: DropIntent.Position =
                    location.y < rowHeight / 2 ? .top : .bottom
                onDrop(droppedId, position)
                return true
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

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != piece.title {
            onRename(piece.id, trimmed)
        }
        renamingItemId = nil
    }

    /// Claim TextField focus with enough deferral that SwiftUI has installed
    /// the field in the responder chain AND `List(selection:)` has finished
    /// its own selection-claim. A single `DispatchQueue.main.async` tick
    /// sometimes lost to the selection focus pass, leaving the new row
    /// selected but not editing. See BinderRow.claimFocus for the same fix.
    private func claimFocus() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            isRenameFieldFocused = true
        }
    }
}
