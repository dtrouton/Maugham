import SwiftUI
import MaughamCore

/// **What can be done to a figure from outside its grid** (report plan 8a
/// Tasks 4 and 7): the ONE helper the tree row's context menu and the figure
/// inspector both call, so the two never drift — Open in Window, Send to
/// Research, Rename, and the inspector's Import from CSV and Refresh from
/// Research. A failure reaches `report` (the tree's alert, the inspector's
/// line).
///
/// - **Who may write** is the posture's one door (tripwires 47, 51:
///   `.editFigure`) and the window's own refusal (`windowRefusesWrites`: a
///   view-only share, ⌘⌥⇧R, the Review persona): either offers Open in
///   Window alone (Review Focus 5).
/// - **Import and Refresh act through the grid open on the figure**
///   (`FigureWindows.gridController(on:)`) — the centre's, an editor's in
///   place, or a figure window's — so their writes are that grid's own
///   steps, one ⌘Z each on its stack. With no grid open neither is offered:
///   nothing is written, so there is no ⌘Z to answer for.
@MainActor
struct FigureActions {
    let store: ProjectStore
    let figureWindows: FigureWindows?
    /// The editor's typography, handed to a window this opens.
    let typography: TypographySettings
    /// Whether the window refuses figure writes (`windowRefusesWrites`,
    /// asked when a menu is built).
    var windowRefusesWrites: () -> Bool = { false }
    let report: (String) -> Void

    // MARK: Who may write

    /// **Does the window itself refuse figure writes?** A view-only share,
    /// the explicit review toggle (⌘⌥⇧R), or a persona that edits no figures
    /// (Review) — what the centre grid opens read-only for
    /// (`FigureSubjectSurface`). ONE answer, read off the window's control
    /// plane, for the tree's row (through `FigureSectionWiring`) and the
    /// inspector alike.
    static func windowRefusesWrites(control: EditorControl, persona: Persona) -> Bool {
        control.shareIsReadOnly || control.isManualReviewMode || !persona.editsFigures
    }

    /// The posture's one door and the window's own refusal: Send to
    /// Research, Rename and Import are offered only when this answers true.
    func mayEdit(_ figureId: String) -> Bool {
        guard !windowRefusesWrites() else { return false }
        return store.documentStore?.posture(forDocId: figureId).allows(.editFigure) ?? false
    }

    /// The piece holding the figure's line, else the piece it was made in.
    func piece(of row: FigureListing.Row) -> String? {
        row.pieceOfLine ?? store.manifest.figures?.first { $0.id == row.figureId }?.piece
    }

    /// Where Send to Research may put the figure: the piece's Research when
    /// there is a piece, and Shared.
    func sendDestinations(for row: FigureListing.Row) -> [FigureResearchDestination] {
        piece(of: row) == nil ? [.shared] : [.piece, .shared]
    }

    // MARK: The verbs

    /// **Open in Window**: a window already open on the figure, or an
    /// editor's grid in place, comes front; else a window opens on it, handed
    /// the number and caption the listing gives — and the centre's hold,
    /// which gives way to a window, yields at once (plan 8a Task 6).
    func openInWindow(_ row: FigureListing.Row) {
        if let windows = figureWindows {
            if windows.focus(row.figureId, passingOverAYieldingHold: true) { return }
            windows.handOff(row.figureId, .init(number: row.number, caption: row.caption,
                                                piece: piece(of: row), typography: typography))
        }
        MaughamEvent.postOpenFigureWindow(figureId: row.figureId)
    }

    /// **Send to Research** (R7d-7): every grid on the figure folds and its
    /// writes land, then the park, which removes the figure's line from its
    /// piece. Not undoable (ruling P-8); a refusal is reported. Answers the
    /// work, which a test awaits; nil when the piece destination has no piece.
    @discardableResult
    func sendToResearch(_ row: FigureListing.Row,
                        to destination: FigureResearchDestination) -> Task<Void, Never>? {
        let scope: ResearchScope
        switch destination {
        case .piece:
            guard let piece = piece(of: row) else { return nil }
            scope = .document(piece)
        case .shared:
            scope = .shared
        }
        let windows = figureWindows, figureId = row.figureId, store = store
        return run {
            await windows?.foldGrids(on: figureId)
            _ = try await store.sendToResearch(figureId: figureId, scope: scope)
        }
    }

    /// Rename the figure (its registry name; formulas follow — the store's
    /// verb, which refuses a name another figure has). A refusal is reported.
    @discardableResult
    func rename(_ figureId: String, to name: String) -> Task<Void, Never> {
        let store = store
        return run { _ = try await store.renameFigure(id: figureId, to: name) }
    }

    /// The grid open on the figure, whose stack Import and Refresh write on.
    func openGrid(_ figureId: String) -> FigureGridController? {
        figureWindows?.gridController(on: figureId)
    }

    /// Whether a grid's visit is open on the figure — observed
    /// (`FigureWindows.hasGrid`), so a view offering Import or Refresh is
    /// redrawn when the grid mounts or goes.
    func hasGrid(_ figureId: String) -> Bool {
        figureWindows?.hasGrid(on: figureId) ?? false
    }

    /// The line said where Import or Refresh has no grid to act through.
    static let openTheTableFirst = "Open the table to import or refresh it."

    /// **Import from CSV…** through the grid open on the figure: its panel,
    /// its matching, one ⌘Z on its stack (R7d-8). With no grid open, nothing
    /// is asked and `openTheTableFirst` is reported; answers false.
    @discardableResult
    func importFromCSV(_ figureId: String) -> Bool {
        guard let grid = openGrid(figureId) else {
            report(Self.openTheTableFirst)
            return false
        }
        grid.performTableCommand(.importCSV)
        return true
    }

    /// **Refresh from Research** through the grid open on the figure: every
    /// pin re-read, one step on that grid's stack. Nil — nothing asked — with
    /// no grid open, or when the grid refused (its reason line says why).
    @discardableResult
    func refreshPins(_ figureId: String) -> Task<Void, Never>? {
        openGrid(figureId)?.refreshPinsFromResearch()
    }

    /// `BinderTreeVerbs.perform`'s shape — a failure reaches `report` —
    /// answering its task.
    private func run(_ work: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        let report = report
        return Task { @MainActor in
            do { try await work() }
            catch { report(error.localizedDescription) }
        }
    }
}
