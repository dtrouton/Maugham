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
    /// The right column's visibility and position (shell p4 Task 10 fix
    /// round 1): a settled landing pulls up only where it shows the
    /// pulled-up position, and Return shows it (`TreeRowSettle`).
    @Binding var showInspector: Bool
    @Binding var position: RightColumnPosition

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
            // The Canvas row's dot goes when the canvas is opened: what the
            // row was handed is there, selected (`TreeCanvasRowDrop`).
            .onChange(of: subject.open) { _, open in
                if !TreeCanvasRowDrop.marksArrival(open: open), state.canvasHasArrivals {
                    state.canvasHasArrivals = false
                }
            }
            .onChange(of: TreeRowSettle.columnShowsPulledUp(showInspector: showInspector,
                                                           position: position),
                      initial: true) { _, shows in
                state.columnShowsPulledUp = shows
            }
            // **A landing settles** (the arrow ruling): the row the keys
            // landed on is pulled up after `TreeRowSettle.delay` with no
            // further landing — outside the `List`'s setter (tripwire 3), and
            // cancelled by the next landing (the key moves).
            .task(id: state.pendingSettle) {
                guard let pulled = state.pendingSettle else { return }
                try? await Task.sleep(for: TreeRowSettle.delay)
                guard !Task.isCancelled, state.pendingSettle == pulled else { return }
                state.pendingSettle = nil
                guard let next = TreeRowSettle.settled(
                    pulled, subject: subject, columnShowsPulledUp: state.columnShowsPulledUp)
                else { return }
                // The row stays the one drawn selected.
                state.record(selection: state.selection, subject: next,
                             foldRow: state.selectedFoldRow)
                subject = next
            }
            // Return / Space shows what it pulled up (`ProjectWindow.revealPulledUp`).
            .onChange(of: state.pulledUpRevealRequests) { _, _ in
                ProjectWindow.revealPulledUp(subject: subject,
                                             showInspector: &showInspector,
                                             position: &position)
            }
    }
}
