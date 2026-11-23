import SwiftUI
import MaughamCore
import UniformTypeIdentifiers

struct ResearchRow: View {
    let item: ResearchItem
    @Binding var renamingItemId: String?
    let onRename: (String, String) -> Void
    /// Called when a drop completes on this row. The closure receives the
    /// dragged item id and the vertical position within this row (top/middle/
    /// bottom). Caller (ResearchBrowser) translates that to a DropIntent and
    /// invokes the appropriate ProjectStore mutator.
    ///
    /// **Returns whether the drop was ACCEPTED, and this row returns exactly
    /// that** (fix round 1). It used to return `true` unconditionally, which
    /// made "accepted" a property of the row rather than of the caller — so a
    /// caller whose handler does nothing still got the accepted-drop animation
    /// and the writer's dragged note vanished. That is the silent no-op the
    /// publishing-namespace finding says to fail loudly on, and it is not
    /// hypothetical: the binder tree's handlers are stubs until stage-2a Task 7.
    /// A `Bool` here means the compiler asks every caller, and a new one cannot
    /// accept by accident.
    let onDrop: (_ draggedId: String, _ position: DropIntent.Position) -> Bool
    /// Called when external items (Finder files or browser image drags) are dropped
    /// on this row. The caller classifies the providers (file URL vs rendered image
    /// vs remote-URL-only) via `DropClassification` and imports to the location the
    /// position maps to. Passing raw providers — not pre-extracted URLs — is what lets
    /// browser image drags land; `.dropDestination(for: URL.self)` silently rejects them.
    ///
    /// Returns whether the drop was accepted — see `onDrop`.
    let onExternalDrop: (_ providers: [NSItemProvider], _ position: DropIntent.Position) -> Bool

    /// **What this row shows while a drag is over it** (shell p4 Task 10):
    /// its caller's answers at each drop position, decided by the same rules
    /// its drop performs (`BinderTreeVerbs.dropAnswers(on:)`).
    var dropAnswers: () -> TreeDropAnswers = { .none }
    @State private var internalDropTargeted = false
    @State private var externalDropTargeted = false
    /// The row's REAL height — what a drop's location is read against
    /// (`DropIntent.Position.of`), never an assumed 22 pt.
    @State private var rowHeight: CGFloat = 22

    /// **Where the row sits, beside its title** (shell p5 Task 4a): a fold's
    /// root whose group lives elsewhere names it ("World / Maps"), quiet and
    /// trailing; nil draws nothing.
    let caption: String?
    /// **The drag began** — called as the payload is asked for, which is when
    /// a drag starts (`.draggable`'s payload is an autoclosure): the tree
    /// records which fold the drag came out of (`researchDragSource`).
    let onDragStart: () -> Void

    @Environment(\.rowThumbnailRoot) private var thumbnailRoot
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
                    // The LABEL LEAF only (tripwire 9), and a mark rather than
                    // a gesture — see BinderRow's twin and TreeTravel.swift.
                    .treeTravelOnDoubleClick(.research(item.id))
                Spacer(minLength: 4)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(Self.captionAccessibilityLabel(caption))
                }
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
            .draggable(dragPayload()) {
                Text(item.title)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
            .dropDestination(for: String.self) { ids, location in
                guard let droppedId = ids.first else { return false }
                let position = DropIntent.Position.of(y: location.y, height: rowHeight)
                // The caller's answer, never a literal — see `onDrop`.
                return onDrop(droppedId, position)
            } isTargeted: { internalDropTargeted = $0 }
            .onDrop(of: [.fileURL, .image], isTargeted: $externalDropTargeted) { providers, location in
                guard !providers.isEmpty else { return false }
                let position = DropIntent.Position.of(y: location.y, height: rowHeight)
                // The caller's answer, never a literal — see `onDrop`.
                return onExternalDrop(providers, position)
            }
            // Its feedback, asked once as a drag arrives (`TreeDropHover`).
            .treeDropHover(internalTargeted: internalDropTargeted,
                           externalTargeted: externalDropTargeted, answers: dropAnswers)
        }
    }

    /// The drag's payload, the item's id — and the moment the drag began.
    private func dragPayload() -> String {
        onDragStart()
        return item.id
    }

    /// What VoiceOver reads for the row's place ("in World / Maps"). Pure.
    static func captionAccessibilityLabel(_ caption: String) -> String { "in \(caption)" }

    /// The kind's glyph, or an image's thumbnail in its place — in the same
    /// fixed box for every row, so titles align and a picture arriving moves
    /// nothing.
    private var icon: some View {
        RowThumbnail(
            source: thumbnailRoot.flatMap { root in
                Self.thumbnailPath(of: item).map { RowThumbnails.Source(path: $0, root: root) }
            },
            glyph: Self.glyphName(of: item), side: RowThumbnail.treeSide)
    }

    /// **Which research rows show a thumbnail**: an image asset, by its
    /// project-relative path. A group, a PDF, a note, a table, a recording
    /// and a link keep their glyph.
    static func thumbnailPath(of item: ResearchItem) -> String? {
        guard item.type != .group, item.kind == .image,
              let path = item.path, !path.isEmpty else { return nil }
        return path
    }

    static func glyphName(of item: ResearchItem) -> String {
        if item.type == .group { return "folder" }
        switch item.kind {
        case .image:    return "photo"
        case .pdf:      return "doc.richtext"
        case .document: return "doc.text"
        case .audio:    return "speaker.wave.2"
        case .link:     return "link"
        case .table:    return "tablecells"
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
