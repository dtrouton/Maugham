import SwiftUI
import MaughamCore

/// Collection-specific binder shell. Mirrors BinderPaneToggle but uses
/// Collection panes for manuscript + research. Trash and Find are reused.
/// No Scenes segment — pieces are flat, scenes are per-piece.
struct CollectionBinderPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var segment: BinderSegment
    @Binding var selectedSubject: BinderSubject?
    @Binding var selectedResearchId: String?
    @Binding var selectedPaletteCardId: String?
    @Binding var findActive: Bool
    @Binding var renamingItemId: String?
    let activePiece: StructureItem?
    let onAddSharedNote: () -> Void
    let onAddPieceNote: () -> Void
    /// The window's working mode — decides which segments the picker offers.
    /// Coercion onto this persona's list happens once, centrally, in
    /// `PersonaModifier`; this view only renders.
    let persona: Persona

    var body: some View {
        VStack(spacing: 0) {
            // `.collection` is a constant here rather than a property: this
            // toggle exists only for collection projects, and passing it is
            // what makes the manuscript segment read "Pieces".
            BinderSegmentPicker(
                segment: $segment,
                persona: persona,
                projectType: .collection,
                hasTrash: !store.trashEntries.isEmpty,
                findActive: findActive)
            Divider()
            Group {
                switch segment {
                case .manuscript:
                    piecesTree
                case .tree:
                    // Plan's structure segment (spec §3.1). Routed through the
                    // same derivation `BinderPaneToggle` uses rather than
                    // rendering the pane directly: `projectType` is a constant
                    // `.collection` in this view, so there is nothing to derive
                    // here today — but a second toggle answering the question
                    // its own way is exactly how the 2026-07-02 bug shipped, and
                    // this is the second toggle.
                    switch BinderSegment.treePane(for: .collection) {
                    case .collectionPieces:
                        piecesTree
                    case .binder, .sceneNavigator:
                        // Cannot arrive. They share the arm rather than taking
                        // an `EmptyView` so a future mis-wiring shows a tree
                        // rather than a blank column; `BinderPaneToggle`'s
                        // `.tree` arm is the converse of this.
                        piecesTree
                    }
                case .research, .canvas:
                    // Spec §10 — see BinderPaneToggle for the reasoning.
                    CollectionResearchPane(
                        store: store,
                        selectedResearchId: $selectedResearchId,
                        activePiece: activePiece,
                        onAddSharedNote: onAddSharedNote,
                        onAddPieceNote: onAddPieceNote)
                case .palette:
                    PaletteBinderList(store: store, selectedCardId: $selectedPaletteCardId)
                case .trash:
                    TrashView(store: store)
                case .find:
                    ProjectSearchView(store: store, isActive: $findActive)
                case .scenes:
                    // Collections don't surface a Scenes segment at the binder
                    // level (scenes are per-piece, derived from the active
                    // screenplay piece in the editor). Fall back to Pieces.
                    piecesTree
                }
            }
            // Exports footer, shown only on the Pieces segment.
            if segment == .manuscript
                && PublishStarter.isInitialized(in: store.url) {
                Divider()
                ExportsListView(projectURL: store.url)
            }
        }
        .onChange(of: store.trashEntries.count) { _, newValue in
            if newValue == 0 && segment == .trash {
                segment = .manuscript
            }
        }
        .onChange(of: findActive) { _, newValue in
            if !newValue && segment == .find {
                segment = .manuscript
            }
        }
    }

    /// The Collection's tree, shared by `.manuscript`, `.tree` and the `.scenes`
    /// fallback. Extracted because three arms render it and a second literal is
    /// how they would come to differ.
    private var piecesTree: some View {
        CollectionPiecesPane(
            store: store,
            selectedSubject: $selectedSubject,
            renamingItemId: $renamingItemId)
    }
}
