import SwiftUI
import AppKit
import MaughamCore

// MARK: - The centre figure view (report plan 8a Task 6)
//
// A table figure selected in the tree is shown large: the figure window's grid
// (`FigureWindowGrid`, the same controller and panel) mounted in the centre
// column — or, in Plan, in the right column beside the canvas — against the
// project window's `DocumentStore`.

/// **The centre's hold on one figure's grid** (R7d-9: one grid per host,
/// anywhere). The centre takes the figure's in-place hold
/// (`FigureWindows.holdInPlace`), so a card elsewhere says "Editing in another
/// window" and brings this grid front; when another grid already has the
/// figure, the centre says where (`elsewhere`) and brings THAT grid front,
/// once, and takes the figure when it is let go. Leaving the subject finishes
/// the visit (an open edit committed, its writes landed — the next grid on the
/// figure begins after them, `releaseInPlace(_:visitEnding:)`).
@MainActor
@Observable
final class FigureCentreMount {
    let figureId: String
    /// The grid while the centre holds the figure; nil while another grid has
    /// it, or after the centre let it go.
    private(set) var grid: FigureWindowGrid?
    /// Where the figure's grid is open instead, while it is not here.
    private(set) var elsewhere: FigureWindows.Elsewhere?
    /// The centre left the figure (the subject moved on, or the grid sent it
    /// to Research): it never takes it again.
    private(set) var hasLeft = false
    /// The centre left for a send asked from outside it
    /// (`FigureWindows.foldGrids`), which may yet be refused.
    @ObservationIgnored private var leftForASend = false

    @ObservationIgnored private var hold: FigureWindows.InPlaceHold?
    @ObservationIgnored private var focusedTheHolder = false
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private let windows: FigureWindows
    @ObservationIgnored private let presence: FigureGridPresence
    @ObservationIgnored private weak var store: DocumentStore?
    @ObservationIgnored private weak var projectStore: ProjectStore?
    /// What the frame tells the gate, kept current by the view (`update`).
    @ObservationIgnored private(set) var line: (number: String, caption: String)
    @ObservationIgnored private(set) var piece: String?
    @ObservationIgnored private(set) var typography: TypographySettings
    @ObservationIgnored private(set) var isReviewMode: Bool
    @ObservationIgnored private(set) var shareIsReadOnly: Bool

    init(figureId: String, windows: FigureWindows, presence: FigureGridPresence,
         store: DocumentStore, projectStore: ProjectStore, line: (number: String, caption: String),
         piece: String?, typography: TypographySettings, isReviewMode: Bool, shareIsReadOnly: Bool) {
        self.figureId = figureId
        self.windows = windows
        self.presence = presence
        self.store = store
        self.projectStore = projectStore
        self.line = line
        self.piece = piece
        self.typography = typography
        self.isReviewMode = isReviewMode
        self.shareIsReadOnly = shareIsReadOnly
    }

    /// Does the centre hold the figure now?
    var holds: Bool { hold != nil }

    /// **Take the figure**, or say where it is being edited and bring that
    /// grid front (once per mount: a writer reading the tree is not pulled
    /// away twice).
    func take() {
        guard !hasLeft, grid == nil, let store, let projectStore else { return }
        guard let hold = windows.holdInPlace(figureId, focus: { [weak self] in self?.focus() },
                                             fold: { [weak self] in self?.leaveForASend() },
                                             yield: { [weak self] in self?.yieldToAWindow() },
                                             grid: { [weak self] in self?.grid?.controller }) else {
            heldElsewhere()
            if !focusedTheHolder {
                focusedTheHolder = true
                windows.focus(figureId)
            }
            return
        }
        self.hold = hold
        elsewhere = nil
        let grid = FigureWindowGrid(presence: presence)
        self.grid = grid
        let name = projectStore.manifest.figures?.first { $0.id == figureId }?.name ?? ElementWords.english.table
        grid.container.show(message: "Opening \(name)\u{2026}")
        let frame = FigureWindowGrid.Frame(
            number: line.number, caption: line.caption, piece: piece, typography: typography,
            isReviewMode: { [weak self] in self?.isReviewMode ?? true },
            shareIsReadOnly: { [weak self] in self?.shareIsReadOnly ?? true },
            takesTheKeysAtMount: false, offersDone: false, listensForTheLine: false,
            armsTheMenuOnlyWithTheKeys: true)
        // Send to Research from the grid: the centre lets the figure go first (R7d-7).
        grid.open(figureId: figureId, store: store, projectStore: projectStore, windows: windows,
                  frame: frame, close: { [weak self] in self?.leave() })
    }

    /// **The project's grids changed** (a figure window opened or closed, a
    /// grid expanded or folded in place anywhere): a window opened on the
    /// figure takes it from here (never two grids on one host); a figure let
    /// go elsewhere is taken.
    func reconsider() {
        guard !hasLeft else { return }
        if grid != nil {
            guard windows.isOpen(figureId) else { return }
            yieldToAWindow()
        } else if windows.isHeld(figureId) {
            heldElsewhere()
        } else {
            take()
        }
    }

    /// **A figure window is handed the figure, or registers on it**
    /// (`FigureWindows.handOff`/`opened`, synchronously, before its grid
    /// awaits `visitEnded`): the visit ends and the hold goes, so the
    /// window's grid begins after the centre's last write. The centre takes
    /// the figure back when the window lets it go.
    func yieldToAWindow() {
        guard !hasLeft, grid != nil else { return }
        release()
        heldElsewhere()
    }

    /// Another grid has the figure: say so, and — when only a window still
    /// opening holds it, which no observed value marks as it lapses — look
    /// again once its grace has passed, so a window that never comes does not
    /// leave the centre saying so for ever.
    private func heldElsewhere() {
        elsewhere = windows.heldElsewhere(figureId, besides: nil)
        guard elsewhere != nil, !windows.isOpen(figureId), windows.inPlaceHolds[figureId] == nil else { return }
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: FigureWindows.openingGrace + .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.reconsider()
        }
    }

    /// The holder comes front: the "Editing in another window" line's click.
    func goToTheHolder() {
        windows.focus(figureId)
    }

    /// **The centre leaves the figure** — the subject moved on, the window
    /// closed, the grid sent it to Research, or a send from outside folds it
    /// (`FigureWindows.foldGrids`). Once only.
    func leave() {
        leftForASend = false
        guard !hasLeft else { return }
        hasLeft = true
        retry?.cancel()
        release()
    }

    /// **The centre's grid folds for a send** (`FigureWindows.foldGrids`, a
    /// row's or the inspector's Send to Research; and the project's close,
    /// `closeAll`): it leaves as `leave` does, but a refused send brings it
    /// back (`sendWasRefused`).
    func leaveForASend() {
        guard !hasLeft else { return }
        leave()
        leftForASend = true
    }

    /// **The send the centre folded for was refused** (final review M4): the
    /// figure is still the subject, so the centre takes it again rather than
    /// staying blank — without pulling the keys from wherever they are.
    func sendWasRefused() {
        guard hasLeft, leftForASend else { return }
        hasLeft = false
        leftForASend = false
        focusedTheHolder = true
        take()
    }

    /// The grid finishes its visit and the hold goes, with the visit still
    /// ending: the next grid on the figure begins after its last write lands.
    private func release() {
        guard let grid else { return }
        grid.finish()
        if let hold {
            windows.releaseInPlace(hold, visitEnding: grid.finishing)
            self.hold = nil
        }
        self.grid = nil
    }

    /// The window comes front and the grid takes the keys (another surface
    /// asked for the figure).
    func focus() {
        guard let gridView = grid?.controller?.gridView, let window = gridView.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(gridView)
    }

    /// The view's inputs changed: the bottom bar follows the listing, the gate
    /// is asked again over the review and share answers.
    func update(line: (number: String, caption: String), piece: String?,
                isReviewMode: Bool, shareIsReadOnly: Bool) {
        if line != self.line {
            self.line = line
            grid?.refreshLine(number: line.number, caption: line.caption)
        }
        if piece != self.piece {
            self.piece = piece
            grid?.controller?.researchPiece = piece
        }
        if isReviewMode != self.isReviewMode || shareIsReadOnly != self.shareIsReadOnly {
            self.isReviewMode = isReviewMode
            self.shareIsReadOnly = shareIsReadOnly
            grid?.refreshAccess()
        }
    }

    /// **Format ▸ Table**, while the centre's grid has the keys (the grid
    /// itself refuses it otherwise: `armsTheMenuOnlyWithTheKeys`).
    func perform(_ command: FigureTableCommand) {
        grid?.perform?(command)
    }
}

/// **The centre figure view**: a table figure's grid in the centre column (or
/// Plan's right column), its bottom bar's number and caption from the window's
/// figure listing (the caption read-only, R7d-6; an unused figure shows its
/// name and "—"), the gate asked over the figure's posture, the share and
/// review (the window's ⌘⌥⇧R, or a persona that does not edit figures).
/// Mount it with `.id(figureId)`: one mount per figure.
struct FigureCentreGrid: View {
    let figureId: String
    let store: ProjectStore
    let documentStore: DocumentStore
    let figureWindows: FigureWindows
    /// The project window's presence, which Format ▸ Table reads.
    let presence: FigureGridPresence
    let listing: FigureListingModel
    let typography: TypographySettings
    let isReviewMode: Bool
    let shareIsReadOnly: Bool
    /// The project window, whose key-window posts reach this grid.
    let window: NSWindow?

    @State private var mount: FigureCentreMount?

    private var row: FigureListing.Row? { listing.row(forFigureId: figureId) }
    private var line: (number: String, caption: String) {
        (row?.number ?? FigureListing.unusedNumber, row?.caption ?? "")
    }
    private var piece: String? {
        row?.pieceOfLine ?? store.manifest.figures?.first { $0.id == figureId }?.piece
    }
    private var inputs: Inputs {
        Inputs(number: line.number, caption: line.caption, piece: piece,
               isReviewMode: isReviewMode, shareIsReadOnly: shareIsReadOnly)
    }
    private struct Inputs: Equatable {
        let number: String, caption: String, piece: String?
        let isReviewMode: Bool, shareIsReadOnly: Bool
    }
    /// What the project's grids look like for this figure, observed.
    private var holders: Holders {
        Holders(inWindow: figureWindows.isOpen(figureId), inPlace: figureWindows.inPlaceHolds[figureId])
    }
    private struct Holders: Equatable {
        let inWindow: Bool
        let inPlace: FigureWindows.InPlaceHold?
    }

    var body: some View {
        ZStack {
            if let grid = mount?.grid {
                FigureWindowGridHost(container: grid.container)
                    .id(ObjectIdentifier(grid))
            } else if let mount, mount.elsewhere != nil {
                // The card's words and the card's act: the click brings the
                // grid that has the figure front.
                Button(FigureThumbnailOverlay.editingInAnotherWindow) { mount.goToTheHolder() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let mount = FigureCentreMount(
                figureId: figureId, windows: figureWindows, presence: presence,
                store: documentStore, projectStore: store, line: line, piece: piece,
                typography: typography, isReviewMode: isReviewMode, shareIsReadOnly: shareIsReadOnly)
            self.mount = mount
            mount.take()
        }
        .onDisappear { mount?.leave() }
        .onChange(of: inputs) { _, next in
            mount?.update(line: (next.number, next.caption), piece: next.piece,
                          isReviewMode: next.isReviewMode, shareIsReadOnly: next.shareIsReadOnly)
        }
        .onChange(of: holders) { _, _ in mount?.reconsider() }
        .onChange(of: figureWindows.sendsRefused[figureId]) { _, _ in mount?.sendWasRefused() }
        // The close itself, as a figure window's: the visit ends (its open
        // edit committed, its writes tracked for the project's close) before
        // the window gives its borrow back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let window, note.object as? NSWindow === window else { return }
            mount?.leave()
        }
        .onKeyWindowCommand(.maughamFigureTableCommand, window: window) { note in
            guard let command = note.userInfo?[MaughamEvent.figureTableCommandKey] as? FigureTableCommand
            else { return }
            mount?.perform(command)
        }
    }
}
