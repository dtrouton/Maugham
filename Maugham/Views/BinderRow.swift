import SwiftUI
import MaughamCore
import UniformTypeIdentifiers

struct BinderRow: View {
    let item: StructureItem
    @Binding var renamingItemId: String?
    let onRename: (String, String) -> Void  // (id, newTitle)
    /// Called when a drop completes on this row. The closure receives the
    /// dragged item id and the vertical position within this row (top/middle/
    /// bottom). Caller (BinderView) routes it — a manuscript id is the binder's
    /// own reorder, a research id is a scope change (`TreeDropIntent`).
    ///
    /// **Returns whether the drop was ACCEPTED, and this row returns exactly
    /// that** (stage-2a Task 7). It used to return `true` unconditionally,
    /// which was harmless while every id this row could receive was a
    /// manuscript id — but the tree now carries research rows, so a note can be
    /// dragged onto a chapter that cannot take it (a screenplay's, a referenced
    /// piece's) and accepting it would animate the drag home and discard it.
    /// Same fix, same reason, as `ResearchRow`'s.
    let onDrop: (_ draggedId: String, _ position: DropIntent.Position) -> Bool
    /// Called when a Finder file or a browser image drag lands on this row
    /// (stage-2b Task 4). A chapter is a real destination for one: in a novel
    /// the file is imported to shared research and linked to this chapter, in a
    /// Collection it goes into the piece's own folder, and a row that can take
    /// neither refuses. Raw providers rather than URLs — a browser drag carries
    /// a rendered bitmap and no file URL at all, and `.dropDestination(for:
    /// URL.self)` drops it silently (`DropClassification`).
    ///
    /// Returns whether the drop was accepted — see `onDrop`.
    let onExternalDrop: (_ providers: [NSItemProvider], _ position: DropIntent.Position) -> Bool

    @State private var draftTitle: String = ""
    @FocusState private var isRenameFieldFocused: Bool

    var body: some View {
        // .draggable on the container intercepts pointer/keyboard input on
        // child controls, so split the rename branch into its own subtree
        // without drag/drop modifiers. Otherwise the TextField can't take
        // focus and Return doesn't commit.
        if renamingItemId == item.id {
            HStack(spacing: 6) {
                statusDot
                TextField("", text: $draftTitle, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .focused($isRenameFieldFocused)
                    .onAppear {
                        draftTitle = item.title
                        claimFocus()
                    }
                    // When `renamingItemId` flips to this row but the if-
                    // branch was already in place (e.g., the user invoked
                    // Rename from the context menu while this row was
                    // visible), `.onAppear` doesn't fire again. `.onChange`
                    // covers that path. The two paths are idempotent —
                    // either one alone wires focus correctly.
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
                statusDot
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The LABEL LEAF only (tripwire 9) — never the row's own
                    // `.contentShape(Rectangle())` below, which is what
                    // `.draggable` needs to keep dragging from anywhere in the
                    // row's interior. See TreeTravel.swift.
                    .treeTravelOnDoubleClick(.item(item.id))
                Spacer()
            }
            .contentShape(Rectangle())
            .draggable(item.id) {
                Text(item.title)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
            .dropDestination(for: String.self) { ids, location -> Bool in
                guard let droppedId = ids.first else { return false }
                let rowHeight: CGFloat = 22
                let position: DropIntent.Position
                if location.y < rowHeight / 3 { position = .top }
                else if location.y > (rowHeight * 2 / 3) { position = .bottom }
                else { position = .middle }
                // The caller's answer, never a literal — see `onDrop`.
                return onDrop(droppedId, position)
            }
            // **After the string destination, always** — `.onDrop(of:)` claims
            // the drag session on hover, before the payload is examined, so
            // mounted first it would leave the reorder above it dead and
            // silent. `ResearchRow` has always had this order; `TripwireGrepTests`
            // censuses it.
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers, location in
                guard !providers.isEmpty else { return false }
                let rowHeight: CGFloat = 22
                let position: DropIntent.Position
                if location.y < rowHeight / 3 { position = .top }
                else if location.y > (rowHeight * 2 / 3) { position = .bottom }
                else { position = .middle }
                // The caller's answer, never a literal — see `onDrop`.
                return onExternalDrop(providers, position)
            }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if item.type == .document {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
        } else {
            Image(systemName: "folder")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch item.status {
        case "revising": return .orange
        case "final":    return .green
        default:         return .secondary
        }
    }

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != item.title {
            onRename(item.id, trimmed)
        }
        renamingItemId = nil
    }

    /// Claim focus for the rename TextField with enough deferral that
    /// SwiftUI has installed the field in the responder chain AND
    /// `List(selection:)` has finished its own selection-claim pass.
    /// A single DispatchQueue.main.async tick wasn't always enough when
    /// the row had just been added by `addStructureItem`; the List's
    /// selection focus and the TextField's focus claim raced, and the
    /// selection claim sometimes won, leaving the user with a selected-
    /// but-not-editing row.
    private func claimFocus() {
        Task { @MainActor in
            // Two short hops give the responder chain time to settle.
            // The first yields back to the runloop; the second waits
            // out List(selection:)'s focus claim. Empirically reliable
            // across "add via context menu" and "add via menubar."
            try? await Task.sleep(for: .milliseconds(30))
            isRenameFieldFocused = true
        }
    }
}
