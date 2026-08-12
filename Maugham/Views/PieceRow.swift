import SwiftUI
import MaughamCore
import UniformTypeIdentifiers

/// One row in the Collection's Pieces segment: kind icon, title, status dot.
/// Supports inline rename when `renamingItemId == piece.id`.
/// Supports drag-reorder via `.draggable` + `.dropDestination` on the
/// non-rename branch, mirroring `BinderRow`'s pattern.
struct PieceRow: View {
    let piece: StructureItem
    @Binding var renamingItemId: String?
    let onRename: (String, String) -> Void   // (pieceId, newTitle)
    /// Returns whether the drop was ACCEPTED, and this row returns exactly that
    /// (stage-2a Task 7) — the tree now carries research rows, so a piece can
    /// receive a note as well as another piece, and a drop it cannot route must
    /// bounce rather than animate home and vanish. See `BinderRow.onDrop`.
    let onDrop: (_ draggedId: String, _ position: DropIntent.Position) -> Bool
    /// A Finder file or a browser image drag landing on this piece (stage-2b
    /// Task 4): in a Collection that is an import into `pieces/<slug>/research/`,
    /// and a referenced piece — whose research lives in its own project —
    /// refuses. Raw providers, because a browser drag carries a rendered bitmap
    /// and no file URL (`DropClassification`). Returns whether it was accepted,
    /// like `onDrop`.
    let onExternalDrop: (_ providers: [NSItemProvider], _ position: DropIntent.Position) -> Bool

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
                    // The LABEL LEAF only (tripwire 9) — see BinderRow's twin
                    // and TreeTravel.swift.
                    .treeTravelOnDoubleClick(.item(piece.id))
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
            .dropDestination(for: String.self) { ids, location -> Bool in
                guard let droppedId = ids.first, droppedId != piece.id else {
                    return false
                }
                // Top half = above this row; bottom half = below.
                let rowHeight: CGFloat = 22
                let position: DropIntent.Position =
                    location.y < rowHeight / 2 ? .top : .bottom
                // The caller's answer, never a literal — see `onDrop`.
                return onDrop(droppedId, position)
            }
            // After the string destination, always: `.onDrop(of:)` claims the
            // drag session on hover and would leave the reorder above it dead
            // and silent (`TripwireGrepTests` censuses the ordering).
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers, location in
                guard !providers.isEmpty else { return false }
                let rowHeight: CGFloat = 22
                let position: DropIntent.Position =
                    location.y < rowHeight / 2 ? .top : .bottom
                // The caller's answer, never a literal — see `onDrop`.
                return onExternalDrop(providers, position)
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
