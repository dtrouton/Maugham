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
    /// Find, as an overlay of this column — see `BinderPaneToggle`, whose
    /// doc comment carries the whole reasoning and is not restated here.
    @Binding var treeFindActive: Bool
    @Binding var renamingItemId: String?
    let activePiece: StructureItem?
    let onAddSharedNote: () -> Void
    let onAddPieceNote: () -> Void
    /// The window's working mode — decides which segments the picker offers.
    /// Coercion onto this persona's list happens once, centrally, in
    /// `PersonaModifier`; this view only renders.
    let persona: Persona
    /// The foot disclosure's own expand/collapse flag — see
    /// `BinderPaneToggle`'s twin for the reasoning, not restated here.
    @State private var trashExpanded = false

    var body: some View {
        if treeFindActive {
            // The overlay replaces the column, strip included — see
            // `BinderPaneToggle` for why, which is not restated here.
            ProjectSearchView(store: store)
        } else {
            tree
        }
    }

    private var tree: some View {
        VStack(spacing: 0) {
            // `.collection` is a constant here rather than a property: this
            // toggle exists only for collection projects, and passing it is
            // what makes the manuscript segment read "Pieces".
            // The divider beneath the strip is the picker's own, not this
            // caller's — see `BinderSegmentPicker.body`'s fix-round-1 note.
            // Placing one here too is exactly the ghost-divider defect that
            // fix caught.
            // `hasTrash` is always `false` since stage 2b Task 2 — see
            // `BinderPaneToggle`'s twin call site for the reasoning.
            BinderSegmentPicker(
                segment: $segment,
                persona: persona,
                projectType: .collection,
                hasTrash: false)
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
                    // Unreachable since stage 2b Task 1 — see
                    // `BinderPaneToggle`'s arm, which carries the reasoning.
                    piecesTree
                case .scenes:
                    // Collections don't surface a Scenes segment at the binder
                    // level (scenes are per-piece, derived from the active
                    // screenplay piece in the editor). Fall back to Pieces.
                    piecesTree
                }
            }
            // Exports footer, shown only on the Pieces segment — asked through
            // the same helper `BinderPaneToggle` asks (see its note), so the two
            // toggles cannot come to disagree about which segment carries it.
            // `.collection` is the constant this view exists for, and its
            // document home is `.manuscript`, so the answer is unchanged.
            if segment == .documentHome(for: .collection)
                && PublishStarter.isInitialized(in: store.url) {
                Divider()
                ExportsListView(projectURL: store.url)
            }
            // The tree's foot — see `BinderPaneToggle` for the whole reasoning,
            // including why the transient-exit arm this replaced (and find's
            // twin of it) went with stage 2b.
            if !store.trashEntries.isEmpty {
                Divider()
                TrashDisclosure(store: store, isExpanded: $trashExpanded)
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
