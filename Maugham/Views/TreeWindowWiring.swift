import SwiftUI
import AppKit
import MaughamCore

/// **The tree's window-level half** — what the tree's state needs served
/// while the tree itself is not mounted (find replaces the column; the
/// sidebar can be hidden): a piece row's sheets, which Brief's Details opens
/// too, and the count of Claude's writes into a closed canvas, which the
/// fold and the pulled-up views both key on (`CanvasCardsRevision`). Mounted
/// once on `ProjectWindow.body`: one presenter, one counter.
struct TreeWindowWiring: ViewModifier {
    let store: ProjectStore?
    let url: URL
    let window: NSWindow?
    @Bindable var state: BinderTreeSectionsState
    @Binding var subject: WindowSubject

    func body(content: Content) -> some View {
        content
            // **A piece row's Tags…, Add Link… and Publishing…** (shell p3
            // Task 8), from the row menu or Brief's Details.
            .sheet(item: $state.pieceRowSheet) { sheet in
                if let store {
                    PieceRowSheetView(
                        store: store, sheet: sheet,
                        perform: BinderTreeVerbs(
                            store: store, state: state, subject: $subject).perform,
                        onDone: { state.pieceRowSheet = nil })
                }
            }
            .onProjectEvent(.maughamCanvasNodesAdded, url: url, window: window) { _ in
                state.closedCanvasWrites += 1
            }
    }
}
