import SwiftUI
import MaughamCore

struct ResearchRow: View {
    let item: ResearchItem
    @Binding var renamingItemId: String?
    let onRename: (String, String) -> Void
    /// Called when a drop completes on this row. The closure receives the
    /// dragged item id and the vertical position within this row (top/middle/
    /// bottom). Caller (ResearchBrowser) translates that to a DropIntent and
    /// invokes the appropriate ProjectStore mutator.
    let onDrop: (_ draggedId: String, _ position: DropIntent.Position) -> Void
    /// Called when external (Finder) URLs are dropped on this row. Caller
    /// translates location to "drop into group" or "drop near sibling" and
    /// invokes ProjectStore.importResearchFiles.
    let onExternalDrop: (_ urls: [URL], _ position: DropIntent.Position) -> Void

    @State private var draftTitle: String = ""
    @FocusState private var isRenameFieldFocused: Bool

    var body: some View {
        // .draggable on the container intercepts pointer/keyboard input on
        // child controls, so split the rename branch into its own subtree
        // without drag/drop modifiers. Otherwise the TextField can't take
        // focus and Return doesn't commit.
        if renamingItemId == item.id {
            HStack(spacing: 6) {
                icon
                TextField("", text: $draftTitle, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .focused($isRenameFieldFocused)
                    .onAppear {
                        draftTitle = item.title
                        claimFocus()
                    }
                    // Cover the context-menu Rename path where the row was
                    // already visible and the if-branch flips in place.
                    // `.onAppear` only fires when the rename subtree is
                    // freshly created (Add-new-item path); `.onChange`
                    // catches the in-place flip. Same belt-and-braces
                    // approach as BinderRow / PieceRow.
                    .onChange(of: renamingItemId) { _, new in
                        if new == item.id {
                            draftTitle = item.title
                            claimFocus()
                        }
                    }
                    .onExitCommand { renamingItemId = nil }
                Spacer()
            }
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 6) {
                icon
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .contentShape(Rectangle())
            .draggable(item.id) {
                Text(item.title)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
            .dropDestination(for: String.self) { ids, location in
                guard let droppedId = ids.first else { return false }
                let rowHeight: CGFloat = 22
                let position: DropIntent.Position
                if location.y < rowHeight / 3 { position = .top }
                else if location.y > (rowHeight * 2 / 3) { position = .bottom }
                else { position = .middle }
                onDrop(droppedId, position)
                return true
            }
            .dropDestination(for: URL.self) { urls, location in
                guard !urls.isEmpty else { return false }
                let rowHeight: CGFloat = 22
                let position: DropIntent.Position
                if location.y < rowHeight / 3 { position = .top }
                else if location.y > (rowHeight * 2 / 3) { position = .bottom }
                else { position = .middle }
                onExternalDrop(urls, position)
                return true
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if item.type == .group {
            Image(systemName: "folder")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: kindIconName)
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
    }

    private var kindIconName: String {
        switch item.kind {
        case .image:    return "photo"
        case .pdf:      return "doc.richtext"
        case .document: return "doc.text"
        case .audio:    return "speaker.wave.2"
        case .link:     return "link"
        case .none:     return "questionmark.circle"
        }
    }

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != item.title {
            onRename(item.id, trimmed)
        }
        renamingItemId = nil
    }

    /// Claim TextField focus with enough deferral that List(selection:)'s
    /// own focus-claim pass settles first. See BinderRow.claimFocus for
    /// the rationale — same fix applied to keep all three rename rows
    /// (BinderRow, PieceRow, ResearchRow) consistent.
    private func claimFocus() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            isRenameFieldFocused = true
        }
    }
}
