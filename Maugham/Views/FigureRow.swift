import SwiftUI
import MaughamCore

/// What a figure row's context menu offers and does (`FigureSectionVerbs`):
/// a value, so a test calls the action a menu item would.
struct FigureRowActions {
    /// The posture lets this Mac edit the figure (Send to Research, Rename).
    let mayEdit: Bool
    /// Send to Research's scopes, in menu order.
    let sendDestinations: [FigureResearchDestination]
    let openInWindow: () -> Void
    let sendToResearch: (FigureResearchDestination) -> Void
    let rename: (_ newName: String) -> Void
}

/// **One row of the tree's Figures section** (report plan 8a Task 4, spec
/// §7): the figure's number ("Table 2", or "—" when unused), its caption or
/// name, and its tags — **Research** (it holds a pin), **changed** (a pin's
/// source moved on), **unused** (no line uses it). Everything it shows is
/// the cached `FigureTreeRow` (tripwire 4).
///
/// A row is a `.tag(.figure(id))` the `List` selects, with
/// `.treeTravelOnDoubleClick` on the label leaf — never a tap gesture
/// (tripwire 9). It drags its bare id. Its rename branch is its own subtree
/// with no drag modifiers, its focus deferred from `.onAppear` and
/// `.onChange(of: renamingItemId)` (tripwire 16) — `BinderRow`'s shape.
struct FigureRow: View {
    let row: FigureTreeRow
    @Binding var renamingItemId: String?
    let actions: FigureRowActions

    @State private var draftName: String = ""
    @FocusState private var isRenameFieldFocused: Bool

    var body: some View {
        content
            .tag(BinderSubject.figure(row.id))
            .id(BinderSubject.figure(row.id))
    }

    @ViewBuilder
    private var content: some View {
        if renamingItemId == row.id {
            HStack(spacing: 6) {
                kindIcon
                TextField("", text: $draftName, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .focused($isRenameFieldFocused)
                    .onAppear {
                        draftName = row.listing.name
                        claimFocus()
                    }
                    // The in-place flip `.onAppear` misses — BinderRow's twin.
                    .onChange(of: renamingItemId) { _, new in
                        if new == row.id {
                            draftName = row.listing.name
                            claimFocus()
                        }
                    }
                    .onExitCommand { renamingItemId = nil }
                Spacer()
            }
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 6) {
                kindIcon
                Text(row.listing.number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The LABEL LEAF only, a mark rather than a gesture
                    // (tripwire 9) — see BinderRow's twin and TreeTravel.swift.
                    .treeTravelOnDoubleClick(.figure(row.id))
                Spacer(minLength: 4)
                ForEach(Self.tags(of: row), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(.quaternary, in: Capsule())
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
            // The bare id, as every tree row drags (D8-2 confirms the
            // Research drop in plan 8b).
            .draggable(row.id) {
                Text(row.title)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
            .contextMenu { menu }
        }
    }

    /// The row's tags, in the order drawn.
    static func tags(of row: FigureTreeRow) -> [String] {
        var tags: [String] = []
        if row.readsResearch { tags.append("Research") }
        if row.pinChanged { tags.append("changed") }
        if row.isUnused { tags.append("unused") }
        return tags
    }

    /// The inspector's actions minus Import (Task 7 shares them). A figure
    /// the posture will not let this Mac edit offers Open in Window alone.
    @ViewBuilder
    private var menu: some View {
        Button("Open in Window", action: actions.openInWindow)
        if actions.mayEdit {
            SwiftUI.Menu(FigureTableMenu.sendToResearchTitle) {
                ForEach(actions.sendDestinations, id: \.self) { destination in
                    Button(destination.title) { actions.sendToResearch(destination) }
                }
            }
            Divider()
            Button("Rename") { renamingItemId = row.id }
        }
    }

    private var kindIcon: some View {
        Image(systemName: row.listing.kind == .table ? "tablecells" : "photo")
            .imageScale(.small)
            .foregroundStyle(.secondary)
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != row.listing.name {
            actions.rename(trimmed)
        }
        renamingItemId = nil
    }

    /// BinderRow.claimFocus's deferral (tripwire 16): the field is installed
    /// and `List(selection:)` has finished its own focus claim first.
    private func claimFocus() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            isRenameFieldFocused = true
        }
    }
}

/// **A piece row's figure count** (D8-1): small secondary text that filters
/// the Figures section to the piece. A `Button(.plain)` — it selects nothing
/// (tripwire 9), so the row's own click still selects the piece.
struct FigureCountButton: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this piece\u{2019}s figures")
    }
}
