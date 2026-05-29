import SwiftUI

/// Collection-specific binder shell. Mirrors BinderPaneToggle but uses
/// Collection panes for manuscript + research. Trash and Find are reused.
/// No Scenes segment — pieces are flat, scenes are per-piece.
struct CollectionBinderPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var segment: BinderSegment
    @Binding var selectedItemId: String?
    @Binding var selectedResearchId: String?
    @Binding var findActive: Bool
    @Binding var renamingItemId: String?
    let activePiece: StructureItem?
    let onAddPiece: () -> Void
    let onAddSharedNote: () -> Void
    let onAddPieceNote: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("Segment", selection: $segment) {
                Text("Pieces").tag(BinderSegment.manuscript)
                Text("Research").tag(BinderSegment.research)
                if !store.trashEntries.isEmpty {
                    Text("Trash").tag(BinderSegment.trash)
                }
                if findActive {
                    Text("Find").tag(BinderSegment.find)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            Group {
                switch segment {
                case .manuscript:
                    CollectionPiecesPane(
                        store: store,
                        selectedItemId: $selectedItemId,
                        renamingItemId: $renamingItemId,
                        onAddPiece: onAddPiece)
                case .research:
                    CollectionResearchPane(
                        store: store,
                        selectedResearchId: $selectedResearchId,
                        activePiece: activePiece,
                        onAddSharedNote: onAddSharedNote,
                        onAddPieceNote: onAddPieceNote)
                case .trash:
                    TrashView(store: store)
                case .find:
                    ProjectSearchView(store: store, isActive: $findActive)
                case .scenes:
                    // Collections don't surface a Scenes segment at the binder
                    // level (scenes are per-piece, derived from the active
                    // screenplay piece in the editor). Fall back to Pieces.
                    CollectionPiecesPane(
                        store: store,
                        selectedItemId: $selectedItemId,
                        renamingItemId: $renamingItemId,
                        onAddPiece: onAddPiece)
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
}
