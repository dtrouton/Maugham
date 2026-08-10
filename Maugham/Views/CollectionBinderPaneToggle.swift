import SwiftUI
import MaughamCore

/// Collection-specific binder shell. Mirrors `BinderPaneToggle`, whose doc
/// comment carries the reasoning that is not restated here, and puts up the
/// Collection's own flat pieces tree instead of `BinderView`. No Scenes surface
/// — pieces are flat, scenes are per-piece.
struct CollectionBinderPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var selectedSubject: BinderSubject?
    /// Find, as an overlay of this column — see `BinderPaneToggle`.
    @Binding var treeFindActive: Bool
    @Binding var renamingItemId: String?
    /// The sections' state, on its way from the window to the pieces tree — see
    /// `BinderView.treeState` (stage-3a Task 4).
    let treeState: BinderTreeSectionsState
    /// The window's working mode — see `BinderPaneToggle`'s twin.
    let persona: Persona
    /// Opens the palette wall in the centre column — see `BinderPaneToggle`'s
    /// twin, whose doc comment carries the whole reasoning.
    var onOpenPaletteWall: () -> Void = {}
    /// A restore's report on its way to `ProjectWindow.restoreOutcome` — see
    /// `BinderPaneToggle`'s twin, whose comment carries the reasoning.
    var onRestoreOutcome: (String) -> Void = { _ in }
    /// The foot disclosure's own expand/collapse flag — see
    /// `BinderPaneToggle`'s twin for the reasoning, not restated here.
    @State private var trashExpanded = false

    var body: some View {
        if treeFindActive {
            // The overlay replaces the column — see `BinderPaneToggle` for why,
            // which is not restated here.
            ProjectSearchView(store: store)
        } else {
            tree
        }
    }

    private var tree: some View {
        VStack(spacing: 0) {
            Group {
                // Routed through the same derivation `BinderPaneToggle` uses
                // rather than rendering the pane directly: `projectType` is a
                // constant `.collection` in this view, so there is nothing to
                // derive here today — but a second toggle answering the question
                // its own way is exactly how the 2026-07-02 bug shipped, and
                // this is the second toggle.
                switch TreePane(for: .collection) {
                case .collectionPieces:
                    piecesTree
                case .binder, .sceneNavigator:
                    // Cannot arrive. They share the arm rather than taking an
                    // `EmptyView` so a future mis-wiring shows a tree rather
                    // than a blank column; `BinderPaneToggle`'s tree arm is the
                    // converse of this.
                    piecesTree
                }
            }
            // Exports footer — asked exactly as `BinderPaneToggle` asks it (see
            // its note, which carries the whole reasoning and is not restated
            // here), so the two toggles cannot come to disagree about when it
            // renders.
            if persona != .plan && PublishStarter.isInitialized(in: store.url) {
                Divider()
                ExportsListView(projectURL: store.url)
            }
            // The tree's foot — see `BinderPaneToggle` for the whole reasoning,
            // including why the transient-exit arm this replaced (and find's
            // twin of it) went with stage 2b.
            if !store.trashEntries.isEmpty {
                Divider()
                TrashDisclosure(store: store, isExpanded: $trashExpanded,
                                onRestoreOutcome: onRestoreOutcome)
            }
        }
    }

    /// The Collection's tree, shared by both arms of the switch above.
    private var piecesTree: some View {
        CollectionPiecesPane(
            store: store,
            selectedSubject: $selectedSubject,
            renamingItemId: $renamingItemId,
            treeState: treeState,
            canOpenPaletteWall: canOpenPaletteWall,
            onOpenPaletteWall: onOpenPaletteWall)
    }

    /// The wall's own door — see `BinderPaneToggle`'s twin, whose doc comment
    /// carries the whole reasoning.
    private var canOpenPaletteWall: Bool { persona != .plan }
}
