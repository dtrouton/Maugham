import Foundation
import MaughamCore

/// **How wide the annotations queue is looking** (M3 P2 Task 7).
///
/// Window `@State` on `ProjectWindow`, threaded down — and deliberately NOT
/// persisted to `UIState`: a scope is a glance, not a home. A writer who
/// widened the queue once to find where the copyedit notes piled up should
/// reopen the project in the piece they were working on, not in a list of the
/// whole book.
///
/// `focusPiece` is the arriving half. It is set by Task 9's click-through from
/// the board's open-notes column — "these eleven notes, in this chapter" — and
/// scrolls that piece's section into view (the `TreeScrollTarget` shape). It is
/// not a filter: the queue still shows the whole project, because the writer
/// who clicked one chapter's count is one scroll from the next chapter's and
/// hiding it would make the widest scope the narrowest one.
enum AnnotationScope: Equatable {
    case document
    case project(focusPiece: String?)

    var isProject: Bool {
        if case .project = self { return true }
        return false
    }
}

/// The queue's cross-document rules, pure so RULING-35's no-dead-controls rule
/// and the ejection trap are both testable without mounting the pane
/// (`AnnotationScopeTests`).
enum AnnotationScopePolicy {

    /// **A row's verbs act only where a live `Document` exists.**
    ///
    /// The alternative — materialising a transient `Document` for a closed
    /// piece and mutating that — is worse than a disabled button in the one way
    /// that matters: the op would land, the writer's ⌘Z would not reach it, and
    /// no surface would be showing the piece it changed. So a closed piece's
    /// notes are READ here and acted on there, and clicking the row is what
    /// gets the writer there.
    static func verbsEnabled(documentIsOpen: Bool) -> Bool { documentIsOpen }

    /// Why they are off. RULING-35: a disabled control that cannot say why is
    /// the half that costs the writer the most — this one also says what to do
    /// about it, and the click that does it is the row itself.
    static let closedPieceReason = "Open this piece to act"

    /// What clicking a project-scope row means.
    enum Click: Equatable {
        /// The row belongs to the piece already centred: the existing
        /// paragraph/annotation navigation, exactly as document scope does it.
        case jump
        /// The row belongs to another piece, or to a figure: take the window
        /// there. A SUBJECT write and nothing else — Review's centre shows
        /// documents, so this navigation must never move the persona
        /// (`ManuscriptNavigation`, and the ejection trap the whole of M3 is
        /// written around).
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

    /// **Multiselect and the bulk bar are document-scope only.**
    ///
    /// `AnnotationBulkActions.perform` runs against ONE `Document`, and every
    /// count the bar shows ("All 23 shown", "12 will accept") is a promise
    /// about what the click will do. Across pieces those numbers would have to
    /// silently exclude every closed document — the bar would be honest only in
    /// the projects where it was useless. The honest cross-document version is
    /// a batch per document with an undo story of its own; it is not this task,
    /// and a writer who wants it can widen, travel to the piece, and use the bar
    /// there.
    static func showsBulkAffordances(_ scope: AnnotationScope) -> Bool {
        !scope.isProject
    }

    /// **A yielded piece's section says why its rows carry no verbs** (P3c
    /// plan 2 Task 8, controller ruling AJ).
    ///
    /// The root yields cooperatively on somebody else's piece (plan ruling R2):
    /// the posture hides every verb but `annotate`, so in the project-scope
    /// queue that piece's notes arrive with nothing to press and nothing saying
    /// why — and *Edit Anyway* lived only in the standing line over the editor,
    /// a surface this queue does not show. This is the section header's half:
    /// the reason, named as the standing line names it, and whether the header
    /// offers *Edit Anyway* (which calls `DocumentStore.overrideYield(docId:)`,
    /// the same verb as the line's). Nil for every other posture — a
    /// reviewer's or a pieces author's refusal is a permit, and a permit is
    /// the root's to change, not this window's to lift.
    ///
    /// Read from `Posture.reason` alone (tripwire 51): nothing here compares a
    /// rung or re-derives who writes the piece.
    struct YieldNotice: Equatable {
        /// *Sam's piece* — the rows' reason.
        let reason: String
        /// The document *Edit Anyway* lifts the yield on.
        let docId: String
    }

    static func yieldNotice(posture: Posture, docId: String) -> YieldNotice? {
        switch posture.reason {
        case .yielding(let name)?:
            return YieldNotice(reason: yieldReason(name), docId: docId)
        case .yieldingToItsStarter(let name)?:
            // Ruling U: the standing line's own sentence, so the header and
            // the line over the editor say one thing about one piece.
            return YieldNotice(
                reason: PostureStandingLine.startedByUnsettled(name), docId: docId)
        default:
            return nil
        }
    }

    /// *Sam's piece* — the header's words for a yield.
    static func yieldReason(_ name: String) -> String { "\(name)\u{2019}s piece" }

    /// The button's title — the standing line's own words.
    static let editAnywayTitle = "Edit Anyway"
}

/// **A queue row for a note on a table figure** (report plan 9c-1 Task 7):
/// where it points, what a suggestion proposes, and which of the row's verbs
/// work from the queue.
///
/// No `Document` holds a figure's notes, so the closed-piece gate
/// (`AnnotationScopePolicy.verbsEnabled`) never applies: Reject, Stet,
/// Archive, Reopen, *Got it*, a craft note's Accept and a query's Reply act
/// through the figure's own host (`FigureDocument`'s verbs, via
/// `DocumentStore.withFigureHost`), so the row is actable whether or not a
/// grid is open. A suggested change writes a cell, so it is accepted in the
/// grid only (plan ruling): its Accept is drawn disabled with
/// `acceptInTheTable`, and an accepted one's Revert with `revertInTheTable`.
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

    /// The reason a figure suggestion's Accept says (plan ruling, verbatim).
    static let acceptInTheTable = "Accept it in the table"
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
    /// (`FigureRecord.listTitle`), with the walk's `cells`.
    init(annotation: Annotation, figureId: String, figureTitle: String,
         cells: SuggestionDisplay.FigureCells?) {
        let inTheTable = FigureAnnotationOps.acceptsOnlyInTheTable(annotation, docId: figureId)
        self.init(
            anchorLine: SuggestionDisplay.figureAnchorLine(for: annotation, figureTitle: figureTitle),
            cells: annotation.kind == .suggestedChange ? cells : nil,
            acceptDisabledReason: inTheTable ? Self.acceptInTheTable : nil,
            revertDisabledReason: inTheTable ? Self.revertInTheTable : nil)
        self.reopensAnAccept = FigureAnnotationOps.reopensAnAccept(annotation, docId: figureId)
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

/// **The cross-document queue's sections** — the board's rows with the
/// un-annotated ones dropped, each annotated piece carrying its own notes in
/// its own queue order.
///
/// Pure by construction, in `ReviewBoardRows`' discipline: rows in, sections
/// out, no store and no disk, so the whole truth table is exercised with no
/// window and no project (`AnnotationScopeTests`).
///
/// **It CALLS `ReviewBoardRows.derive` rather than walking the manifest again**
/// (the caller does the derive and hands the rows in). Order and grouping are
/// one question and the board already answers it; a second walk here is how the
/// queue and the board come to disagree about where Part Two starts.
enum AnnotationScopeSections {

    /// One section. A `.piece` carries its notes; a `.group` is a header and
    /// carries none — a group is a place in the tree, never a thing notes are
    /// attached to.
    ///
    /// The notes are `[Annotation]` rather than `[ProjectAnnotation]`: a piece
    /// section IS one document, and `item.id` is that document's id, so
    /// re-carrying the doc id per row would be a second copy of a fact the
    /// section already states.
    struct Section: Equatable, Identifiable {
        enum Kind: Equatable {
            /// A group header. `depth` is `ReviewBoardRows`' own — 0 for a root
            /// group, incrementing per level of nesting.
            case group(depth: Int)
            case piece
        }

        let kind: Kind
        /// The document's id (a piece's, or a figure's stream), or a group's.
        let id: String
        /// What the header says: the piece's or group's title, or a figure's
        /// registry name (`FigureRecord.listTitle`).
        let title: String
        let annotations: [Annotation]

        init(kind: Kind, id: String, title: String, annotations: [Annotation]) {
            self.kind = kind
            self.id = id
            self.title = title
            self.annotations = annotations
        }

        init(kind: Kind, item: StructureItem, annotations: [Annotation]) {
            self.init(kind: kind, id: item.id, title: item.title, annotations: annotations)
        }
    }

    /// Group `annotations` by piece and drop everything with nothing in it.
    ///
    /// - Parameters:
    ///   - rows: `ReviewBoardRows.derive(structure:)`'s output — the order.
    ///   - annotations: the project-wide notes, ALREADY filtered by the pane
    ///     (kind, status, author, triage). Filtering before grouping is what
    ///     makes "a header only where there is something to show" mean *after
    ///     the filters*, which is the only reading that leaves no empty
    ///     headings when a writer narrows to Suggestions.
    ///   - sequences: `ProjectAnnotationsSnapshot.sequences` — each document's
    ///     paragraph order, so a piece's notes are sorted against ITS OWN
    ///     document order (the snapshot carries them precisely so a
    ///     cross-document sort never degrades to derive order for the closed
    ///     documents). A piece with no entry sorts into the queue's unanchored
    ///     tail rather than being dropped.
    ///   - figures: the manifest's figure registry. A figure's stream carries
    ///     notes too (report plan 6a), each figure titled by the registry
    ///     (`FigureRecord.listTitle`). **A piece's own figures follow its
    ///     section** (report plan 9c-1 Task 7): the board counts their notes
    ///     on the piece, so the count's click-through lands on them — and a
    ///     piece whose only notes are on its tables still has a section to
    ///     land on. Whole-book figures (and a figure whose piece is no row)
    ///     follow the board's rows under one "Figures" header.
    static func build(
        rows: [ReviewBoardRows.Row],
        annotations: [ProjectAnnotation],
        sequences: [String: [String]] = [:],
        figures: [FigureRecord] = []
    ) -> [Section] {
        guard !annotations.isEmpty else { return [] }

        var byDoc: [String: [Annotation]] = [:]
        for entry in annotations {
            byDoc[entry.docId, default: []].append(entry.annotation)
        }

        // A piece's own figures, by piece — only pieces the rows draw, so a
        // figure whose piece is gone still shows, under "Figures".
        let pieceIds = Set(rows.filter { $0.kind == .piece }.map(\.item.id))
        var owned: [String: [FigureRecord]] = [:]
        for figure in figures {
            if let piece = figure.piece, pieceIds.contains(piece) { owned[piece, default: []].append(figure) }
        }
        let annotatedFigures: (String) -> [FigureRecord] = { piece in
            (owned[piece] ?? []).filter { !(byDoc[$0.id] ?? []).isEmpty }
        }
        let figureSection: (FigureRecord) -> Section = { figure in
            Section(kind: .piece, id: figure.id, title: figure.listTitle,
                    annotations: AnnotationQueueOrder.sorted(byDoc[figure.id] ?? [], sequence: []))
        }

        var sections: [Section] = []
        for row in rows {
            switch row.kind {
            case .reference:
                // A Collection's reference piece points at another project;
                // its notes are adjudicated in ITS window, and a row here would
                // be a control over state this manifest does not own. P1's
                // board makes the same choice (`ReviewBoardRows.Row.reference`
                // carries no chips).
                continue
            case .piece:
                let notes = byDoc[row.item.id] ?? []
                let itsFigures = annotatedFigures(row.item.id)
                guard !notes.isEmpty || !itsFigures.isEmpty else { continue }
                sections.append(Section(
                    kind: .piece,
                    item: row.item,
                    annotations: AnnotationQueueOrder.sorted(
                        notes, sequence: sequences[row.item.id] ?? [])))
                sections.append(contentsOf: itsFigures.map(figureSection))
            case .group(let depth):
                guard hasAnnotatedDescendant(row.item, byDoc: byDoc,
                                             figuresOf: { !annotatedFigures($0).isEmpty })
                else { continue }
                sections.append(Section(
                    kind: .group(depth: depth), item: row.item, annotations: []))
            }
        }
        let shownWithAPiece = Set(owned.values.joined().map(\.id))
        let bookFigures = figures.filter {
            !shownWithAPiece.contains($0.id) && !(byDoc[$0.id] ?? []).isEmpty
        }
        if !bookFigures.isEmpty {
            sections.append(Section(
                kind: .group(depth: 0), id: figuresHeaderId,
                title: FigureRecord.listGroupTitle, annotations: []))
            sections.append(contentsOf: bookFigures.map(figureSection))
        }
        return sections
    }

    /// The figures header's section id — no document's.
    static let figuresHeaderId = "__figures__"

    /// Does anything under this group have notes?
    ///
    /// **Asked of the group's own subtree, not of the flat row list**, because
    /// the flat list cannot answer it: `ReviewBoardRows` carries depth on
    /// GROUPS alone (deliberately — see its doc comment), so a root-level piece
    /// following a nested group is indistinguishable from one inside it. The
    /// subtree is the honest source, and it is a containment question rather
    /// than an ordering one, so this is not the second walk the type doc
    /// forbids.
    private static func hasAnnotatedDescendant(
        _ item: StructureItem, byDoc: [String: [Annotation]],
        figuresOf: (String) -> Bool
    ) -> Bool {
        for child in item.children ?? [] {
            if child.type == .group {
                if hasAnnotatedDescendant(child, byDoc: byDoc, figuresOf: figuresOf) { return true }
            } else if child.pieceKind != .reference,
                      !(byDoc[child.id] ?? []).isEmpty || figuresOf(child.id) {
                return true
            }
        }
        return false
    }

    /// The footnote for pieces the project walk could not read.
    ///
    /// RULING-54's honesty half, at the queue's foot: the aggregation is
    /// lenient about an unreadable op log (it skips the document rather than
    /// throwing the whole read away) and NAMES what it skipped, so this surface
    /// can say "unknown" where a silent queue would be saying "none". Titles,
    /// in board order, because an id means nothing to the writer.
    static func unreadableNotice(
        unreadableDocIds: [String], rows: [ReviewBoardRows.Row],
        figures: [FigureRecord] = []
    ) -> String? {
        guard !unreadableDocIds.isEmpty else { return nil }
        let ids = Set(unreadableDocIds)
        let titles = rows.filter { ids.contains($0.item.id) }.map(\.item.title)
            + figures.filter { ids.contains($0.id) }.map(\.listTitle)
        guard !titles.isEmpty else { return nil }
        let named = titles.joined(separator: ", ")
        return titles.count == 1
            ? "Couldn\u{2019}t read \(named) — its notes are unknown, not none."
            : "Couldn\u{2019}t read \(named) — their notes are unknown, not none."
    }
}
