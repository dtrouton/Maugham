import Foundation
import MaughamCore

/// **What clicking a note row about another stream means** — moved from the
/// Annotations pane's scope policy when that pane was deleted (shell plan 2
/// Task 7). To resolve uses it for a figure's notes; a piece's note goes
/// through `ResolveNavigation`.
enum FigureNoteClick {
    /// What clicking the row means.
    enum Click: Equatable {
        /// The row belongs to the piece already centred: the existing
        /// paragraph/annotation navigation.
        case jump
        /// The row belongs to another piece, or to a figure: take the window
        /// there. A SUBJECT write and nothing else — the centre shows the piece
        /// with the list still beside it (`ManuscriptNavigation`, and the
        /// ejection trap the whole of M3 is written around).
        case travel(BinderSubject)
        /// A figure the tree's Figures section has no row for (parked, or a
        /// project that shows no section): nothing moves. A figure a piece
        /// filter hides still travels — the travel lifts the filter.
        /// Travelling there would land on a subject the window repairs to
        /// the project row, taking the writer off her piece.
        case stay
    }

    /// - Parameter drawsFigure: whether the tree's Figures section has a row
    ///   for a figure, filter aside (`BinderTreeSectionsState.drawsFigure`).
    static func click(rowDocId: String, activeDocId: String?,
                      drawsFigure: (String) -> Bool) -> Click {
        // A figure's stream id is a figure subject (report plan 8a), never a
        // piece and never a jump: no editor shows a figure's paragraphs.
        if DocumentClass.isFigureDocId(rowDocId) {
            return drawsFigure(rowDocId) ? .travel(.figure(rowDocId)) : .stay
        }
        return rowDocId == activeDocId ? .jump : .travel(.item(rowDocId))
    }
}

/// **A queue row for a note on a table figure** (report plan 9c-1 Task 7):
/// where it points, what a suggestion proposes, and which of the row's verbs
/// work from the queue.
///
/// No `Document` holds a figure's notes, so the open-piece gate
/// (`ResolveVerbGate`) never applies: Reject, Stet,
/// Archive, Reopen, *Got it*, a craft note's Accept and a query's Reply act
/// through the figure's own host (`FigureDocument`'s verbs, via
/// `DocumentStore.withFigureHost`), so the row is actable whether or not a
/// grid is open. A suggested change writes a cell, so it is accepted in the
/// grid only (plan ruling): its Accept opens the figure at its cell
/// (`acceptTravels`, report plan 9c-2 Task 7), where the strip offers the
/// real Accept — drawn disabled with `acceptCellDeleted` when the cell is
/// gone — and an accepted one's Revert is disabled with `revertInTheTable`.
/// The verbs that file elsewhere through a `Document` — *Answer as ruling…*,
/// *This is a choice*, *Keep as lesson…*, Edit and Delete — and the triage
/// mark have no figure-stream verb, so they are not drawn.
///
/// Pure, so the whole truth table is pinned without a window
/// (`FigureAnnotationRowTests`).
struct FigureRowGate: Equatable {
    /// "C3 · Table: Sales", "cells deleted · Table: Sales", or the title
    /// alone for a note on the whole figure (`SuggestionDisplay`).
    let anchorLine: String
    /// A suggestion's before and after as cell text (the walk's
    /// `ProjectAnnotationsSnapshot.figureCells`); nil for other kinds, and
    /// when the walk had no table to read them off.
    let cells: SuggestionDisplay.FigureCells?
    /// Why Accept is disabled, nil where it works.
    let acceptDisabledReason: String?
    /// Why an accepted suggestion's Revert is disabled, nil where none is drawn.
    let revertDisabledReason: String?
    /// Does an ACCEPTED note offer Reopen? True for a note that wrote no
    /// cell (a *Got it*, a Reply): `FigureDocument.reopenAnnotation` takes it
    /// back with a status-only revert, so an answer given from the queue is
    /// reversible from the row with no grid open. An accepted suggestion
    /// keeps its disabled Revert instead.
    var reopensAnAccept: Bool = false

    /// Does Accept open the figure at the note's cell rather than answer it?
    /// A live-anchored suggestion's does: the strip there writes the cell.
    var acceptTravels: Bool = false

    /// Why an orphaned figure suggestion's Accept is off: no cell to open.
    static let acceptCellDeleted = "Its cell has been deleted"
    /// Why a parked figure's suggestion Accept is off: the queue cannot
    /// travel to a figure the tree draws no row for.
    static let acceptInResearch = "In Research \u{2014} bring it back to accept"
    /// What a travelling Accept says it does.
    static let acceptOpensTheCell = "Open the table at its cell to accept it there"

    /// Accept's tooltip: why it is off, or where it takes the writer.
    var acceptHelp: String? { acceptDisabledReason ?? (acceptTravels ? Self.acceptOpensTheCell : nil) }
    /// The reason an accepted figure suggestion's Revert says: its cell is
    /// put back by changing it in the grid (or by the accept's own ⌘Z).
    static let revertInTheTable = "Change the cell back in the table"

    init(anchorLine: String, cells: SuggestionDisplay.FigureCells?,
         acceptDisabledReason: String?, revertDisabledReason: String?) {
        self.anchorLine = anchorLine
        self.cells = cells
        self.acceptDisabledReason = acceptDisabledReason
        self.revertDisabledReason = revertDisabledReason
    }

    /// The gate for `annotation` on figure `figureId`, titled `figureTitle`
    /// (`FigureRecord.listTitle`), with the walk's `cells`. `reachable`: the
    /// queue can travel to the figure (the tree draws its row,
    /// `FigureNoteClick.click`); a parked one's Accept has nowhere to go.
    init(annotation: Annotation, figureId: String, figureTitle: String,
         cells: SuggestionDisplay.FigureCells?, reachable: Bool = true) {
        let inTheTable = FigureAnnotationOps.acceptsOnlyInTheTable(annotation, docId: figureId)
        let hasCell = Self.cell(of: annotation) != nil
        let travels = inTheTable && hasCell && reachable
        let offReason: String? = !inTheTable || travels ? nil
            : hasCell ? Self.acceptInResearch : Self.acceptCellDeleted
        self.init(
            anchorLine: SuggestionDisplay.figureAnchorLine(for: annotation, figureTitle: figureTitle),
            cells: annotation.kind == .suggestedChange ? cells : nil,
            acceptDisabledReason: offReason,
            revertDisabledReason: inTheTable ? Self.revertInTheTable : nil)
        self.acceptTravels = travels
        self.reopensAnAccept = FigureAnnotationOps.reopensAnAccept(annotation, docId: figureId)
    }

    /// **The cell a figure note's travel selects**: its anchor's first
    /// corner, which a range's strip lookup also contains; nil for a note on
    /// the whole figure or one whose cell is gone.
    static func cell(of annotation: Annotation) -> CellKey? {
        guard !annotation.figureOrphaned, let anchor = annotation.figureAnchor else { return nil }
        return CellKey(row: anchor.row, column: anchor.column)
    }

    /// **The posture's verbs, narrowed to what a figure stream can write.**
    /// The posture still decides (asked of the FIGURE's own id, as every row
    /// asks its own document's); this only takes away the verbs with no
    /// figure-stream write behind them.
    static func verbs(_ offered: AnnotationRowVerbs) -> AnnotationRowVerbs {
        AnnotationRowVerbs(
            acceptOrReject: offered.acceptOrReject, dispose: offered.dispose,
            answerAsRuling: false, makeChoice: false, keepAsLesson: false, ownNote: false)
    }

    /// No triage mark on a figure note: no figure-stream verb writes one.
    static let drawsTriage = false
}
