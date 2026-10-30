import SwiftUI
import AppKit
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
///   nothing is written, so there is no ⌘Z to answer for. **This window's
///   grid only** (final review M7): a grid open in another window is not
///   acted through from here — that window comes front and the line says
///   to do it there, so its refusal and its stack are where the writer is.
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
    /// The window this helper acts for (the inspector's project window); nil
    /// takes the grid wherever it is open.
    var window: NSWindow? = nil
    /// Where a success with something to say goes (*Use in Document*'s cells
    /// kept as text) — not an error; nil sends it to `report`.
    var notice: ((String) -> Void)? = nil

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
    /// piece. Not undoable (ruling P-8); a refusal is reported, and the
    /// centre's grid, folded for it, takes the figure again
    /// (`FigureWindows.sendRefused`). Answers the
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
        return park(row.figureId, scope: scope, then: nil)
    }

    /// **Send to Research by a drop** (report plan 8b Task 5): into `scope`,
    /// then — when the drop named a group — into `group` through the typed
    /// mover. A move that fails leaves the copy at the scope's root and says
    /// so, calling the figure `called` and the group `groupTitle` — its title
    /// at the drop, since a group that has gone has none to look up.
    @discardableResult
    func sendToResearch(figureId: String, scope: ResearchScope, intoGroup group: String?,
                        groupTitle: String?, called: String) -> Task<Void, Never> {
        let store = store
        return park(figureId, scope: scope, then: group.map { group in { copy in
            do { try await store.moveResearchItems(ids: [copy.id], to: .group(group)) } catch {
                let title = TreeWalk.find(id: group, in: store.manifest.research)?.title
                    ?? groupTitle ?? "its group"
                throw FigureGroupMoveFailed(called: called, group: title,
                                            reason: error.localizedDescription)
            }
        } })
    }

    /// The send itself: every grid on the figure folds, then the park; a
    /// refusal brings a folded grid back. `then` follows a park that landed.
    private func park(_ figureId: String, scope: ResearchScope,
                      then: (@MainActor (ResearchItem) async throws -> Void)?) -> Task<Void, Never> {
        let windows = figureWindows, store = store
        return run {
            await windows?.foldGrids(on: figureId)
            let copy: ResearchItem
            do { copy = try await store.sendToResearch(figureId: figureId, scope: scope) } catch {
                // Refused: the figure stays, and a grid folded for it comes back.
                windows?.sendRefused(figureId)
                throw error
            }
            try await then?(copy)
        }
    }

    /// The figure reached Research, but not the group it was dropped on.
    struct FigureGroupMoveFailed: LocalizedError {
        let called: String, group: String, reason: String
        var errorDescription: String? {
            "\(called) is in Research, but it couldn’t go into “\(group)”, so it is at the top: \(reason)"
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
    /// The line said where the figure's grid is open in another window.
    static let openInThatWindow = "The table is open in another window: import or refresh it there."

    /// **Where the grid open on a figure is**, seen from `window`: here
    /// (this window's — the centre's, an editor's in place, or any grid when
    /// the helper has no window), in another window, or nowhere. Observed,
    /// as `hasGrid` is.
    enum GridReach: Equatable { case here, inAnotherWindow, none }

    func gridReach(_ figureId: String) -> GridReach {
        guard let grid = openGrid(figureId) else { return .none }
        guard let window, let gridWindow = grid.gridView.window, gridWindow !== window else { return .here }
        return .inAnotherWindow
    }

    /// This window's grid on the figure; elsewhere, that window comes front
    /// and the line says so; nowhere, the line says to open it when
    /// `sayingNone`. Nil unless here.
    private func gridHere(_ figureId: String, sayingNone: Bool) -> FigureGridController? {
        switch gridReach(figureId) {
        case .here:
            return openGrid(figureId)
        case .inAnotherWindow:
            report(Self.openInThatWindow)
            figureWindows?.focus(figureId)
            return nil
        case .none:
            if sayingNone { report(Self.openTheTableFirst) }
            return nil
        }
    }

    /// **Import from CSV…** through this window's grid on the figure: its
    /// panel, its matching, one ⌘Z on its stack (R7d-8). Answers false — and
    /// asks nothing — with no grid open (`openTheTableFirst`) or one open in
    /// another window (`openInThatWindow`, which comes front).
    @discardableResult
    func importFromCSV(_ figureId: String) -> Bool {
        guard let grid = gridHere(figureId, sayingNone: true) else { return false }
        grid.performTableCommand(.importCSV)
        return true
    }

    /// **Refresh from Research** through this window's grid on the figure:
    /// every pin re-read, one step on that grid's stack. Nil — nothing asked —
    /// with no grid open (Compare offers no Refresh then), with the grid in
    /// another window (said as Import says it), or when the grid refused (its
    /// reason line says why).
    @discardableResult
    func refreshPins(_ figureId: String) -> Task<Void, Never>? {
        gridHere(figureId, sayingNone: false)?.refreshPinsFromResearch()
    }

    // MARK: From Research (report plan 8b Task 4)

    /// **What a Research item offers toward the Figures section**: *Use in
    /// Document* makes a new, unused figure from it (D8b-1: Insert ▸ Existing
    /// Figure places its line); a parked figure's working copy, which this
    /// Mac may edit, reads *Bring Back to Figures* — the same store verb,
    /// which routes it (`ProjectStore.figureToBringBack`).
    enum ResearchVerb: Equatable {
        case use
        case bringBack(figureId: String)

        var title: String {
            switch self {
            case .use: return "Use in Document"
            case .bringBack: return "Bring Back to Figures"
            }
        }
    }

    /// Whether a figure can be made from `item`: a table, picture or PDF —
    /// what the row menu offers the verb on and a drop on Figures accepts.
    nonisolated static func makesAFigure(_ item: ResearchItem) -> Bool {
        item.type == .asset && [.table, .image, .pdf].contains(item.kind)
    }

    /// The verb a Research item's row menu and inspector offer, or none: only
    /// a picture, table or PDF, in a project whose manuscript holds figures,
    /// in a window that does not refuse figure writes. `returning` is the
    /// store's cached answer (`BinderTreeSectionsState.figureReturns`).
    func researchVerb(for item: ResearchItem, returning figureId: String?) -> ResearchVerb? {
        guard Self.makesAFigure(item), store.manifest.type.holdsFigures,
              !windowRefusesWrites() else { return nil }
        return figureId.map { .bringBack(figureId: $0) } ?? .use
    }

    /// **Use in Document / Bring Back to Figures**: the store's verb, the
    /// figure's piece the one whose Research holds the item
    /// (`researchHomePiece`), else the whole book's. Its id goes to `reveal`;
    /// the cells the read kept as text and the late edits the copy replaced
    /// are said once (`readNotice`) through `notice`, a refusal through
    /// `report` — worded by the route the store takes
    /// (`figureToBringBack`, asked before the verb).
    @discardableResult
    func useInDocument(_ item: ResearchItem,
                       reveal: @escaping @MainActor (String) -> Void) -> Task<Void, Never> {
        let store = store, say = notice ?? report
        let piece = store.researchHomePiece(ofItemId: item.id)
        return run {
            let bringingBack = (try? await store.figureToBringBack(fromResearchItemId: item.id)) != nil
            let result: UseInDocumentResult
            do {
                result = try await store.useInDocument(researchItemId: item.id, piece: piece)
            } catch is FigureEditRefused {
                throw ResearchUseRefused(bringingBack: bringingBack)
            }
            reveal(result.record.id)
            if let notice = Self.readNotice(result) { say(notice) }
        }
    }

    /// What *Use in Document* says after it made or brought back a figure:
    /// the formulas the read kept as text, and the cells the copy's change
    /// replaced a late edit in; nil when neither.
    static func readNotice(_ result: UseInDocumentResult) -> String? {
        var parts: [String] = []
        if let problems = FigureIngest.convertedTableProblemsMessage(result.problems) {
            parts.append(problems)
        }
        let count = result.overwritten.count
        if count > 0 {
            let cells = count == 1 ? "One cell" : "\(count) cells"
            parts.append("\(cells) edited after the table was sent to Research "
                + (count == 1 ? "was" : "were") + " replaced by the copy’s change.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The new figure's door refused (`FigureEditRefused`, whose own words
    /// are about an edit): said as what did not happen.
    struct ResearchUseRefused: LocalizedError {
        let bringingBack: Bool
        var errorDescription: String? {
            bringingBack ? "This Mac may not change this figure, so it stays in Research."
                : "This Mac may not make a figure here, so nothing was made."
        }
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
