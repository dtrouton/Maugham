import SwiftUI
import AppKit
import MaughamCore

/// **The tree's window-level half** — what the tree's state needs served
/// while the tree itself is not mounted (find replaces the column; the
/// sidebar can be hidden): a piece row's sheets, which Brief's Details opens
/// too, the count of Claude's writes into a closed canvas, which the fold
/// and the pulled-up views both key on (`CanvasCardsRevision`), and a
/// Collection script's re-parses and arrivals (`PieceFoldIndexing`). Mounted
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
            // **The Editions rows' arrivals** (shell p5 Task 4a fix round 1):
            // a translation written, publishing set up, a proposed edition
            // brief each move the rows' key. They lived on the sections with
            // no window, and so never fired (`MaughamEvent.isLive(nil)`).
            .onProjectEvent(.maughamTranslationDidUpdate, url: url, window: window) { _ in
                state.translationRevision += 1
            }
            .onProjectEvent(.maughamPublishInitialized, url: url, window: window) { _ in
                state.translationRevision += 1
            }
            .onProjectEvent(.maughamStatementProposalsChanged, url: url, window: window) { _ in
                state.translationRevision += 1
            }
            // **A Collection script's Scenes** (`PieceFoldIndexing`): the
            // editor's re-parse moves their key; a peer's sync into a closed
            // script re-reads that script (shell p5 Task 4). Here, on the
            // window ProjectWindow resolved: a receiver with no live window
            // hears nothing (`MaughamEvent.isLive`).
            .onProjectEvent(.maughamScriptDidUpdate, url: url, window: window) { _ in
                state.scriptRevision += 1
            }
            .onProjectEvent(.maughamAnnotationsChanged, url: url, window: window) { note in
                guard let store else { return }
                PieceFoldIndexing.arrived(
                    docId: note.userInfo?[MaughamEvent.annotationDocIdKey] as? String,
                    store: store, state: state)
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
            // **A press ends the last drag's record** (M9): a drag begins with
            // a press and records its fold after it, so a cancelled drag, or
            // one from another window, never lends this window its source.
            .onAppear {
                guard state.pressMonitor == nil else { return }
                state.pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                    [weak state] event in
                    state?.pointerWentDown()
                    return event
                }
            }
            .onDisappear {
                if let monitor = state.pressMonitor { NSEvent.removeMonitor(monitor) }
                state.pressMonitor = nil
            }
            // Return / Space shows what it pulled up (`ProjectWindow.revealPulledUp`).
            .onChange(of: state.pulledUpRevealRequests) { _, _ in
                ProjectWindow.revealPulledUp(subject: subject,
                                             showInspector: &showInspector,
                                             position: &position)
            }
    }
}
