import SwiftUI
import MaughamCore

/// **A figure whose source data changed** (shell p5 Task 3; ADR 0036's last
/// item kind): what To resolve and the tree's mark know of it, as plain
/// values. Built once per card fill or listing change by the tree's state
/// (`BinderTreeSectionsState.figureSourceChanges`) from the tree's own
/// figure cards (`FigureCardModel.changed`: a pin's source, or the Research
/// item the figure was made from, moved on) and the window's listing (where
/// the book places it). It reads no stream and opens no `FigureDocument`:
/// the cards already computed it (tripwire 4).
///
/// Durable: the item stands while the card says changed, and goes by itself
/// once the pin is current again (a refresh, a re-pin, the source put back).
/// No check replaces it.
struct ResolveFigureChange: Equatable, Sendable {
    let figureId: String
    /// "Table 2" in the book's words, or `FigureListing.unusedNumber`.
    let number: String
    /// What the tree's row reads as: the caption, else the name.
    let title: String
    /// A pin's source moved on (`FigureCardModel.pinChanged`): Compare has
    /// rows to show. A changed snapshot alone has none.
    let pinsChanged: Bool
    /// The first line placing the figure in each piece, in reading order;
    /// empty for an unused figure.
    let placements: [FigureListing.Use]

    /// **The changed figures, from the cards and the listing** — the listing's
    /// order. A parked figure (in Research, no row in the tree) and a figure
    /// with no card yet say nothing. Pure.
    static func of(listing: [FigureListing.Row],
                   card: (String) -> FigureCardModel?) -> [ResolveFigureChange] {
        listing.compactMap { row in
            guard let model = card(row.figureId), model.kind != .parked, model.changed else { return nil }
            var seen = Set<String>()
            let placements = row.usedIn.filter { seen.insert($0.docId).inserted }
            return ResolveFigureChange(
                figureId: row.figureId, number: row.number,
                title: row.caption.isEmpty ? row.name : row.caption,
                pinsChanged: model.pinChanged, placements: placements)
        }
    }

    /// **The row's sentence**: "Table 2’s source data changed"; an unused
    /// figure, which has no number, by what the tree calls it.
    var sentence: String {
        let name = number == FigureListing.unusedNumber ? title : number
        return "\(name)\u{2019}s source data changed"
    }

    /// The line beside the sentence: the caption or name, when the sentence
    /// named the figure by its number.
    var detail: String? {
        number == FigureListing.unusedNumber ? nil : title
    }

    /// The line index a keyed placement carries where no read places by its
    /// line (`keyed(_:for:)`): `FigureUseTravel.place` answers nil for it.
    static let unplacedLine = -1

    /// **What `scope`'s read is keyed on, and reads** (fix round 1, I2):
    /// every placement's piece, and a line only for a `.piece` scope's own
    /// piece — the one placement a read puts on a paragraph. A line moving
    /// anywhere else (typing above a changed figure while a Book, a Part or
    /// the presence read is keyed) moves no key, so it reads nothing.
    static func keyed(_ changes: [ResolveFigureChange], for scope: ResolveScope) -> [ResolveFigureChange] {
        var placing: String?
        if case .piece(let docId, _) = scope { placing = docId }
        return changes.map { change in
            ResolveFigureChange(
                figureId: change.figureId, number: change.number, title: change.title,
                pinsChanged: change.pinsChanged,
                placements: change.placements.map { use in
                    use.docId == placing ? use : FigureListing.Use(docId: use.docId, lineIndex: unplacedLine)
                })
        }
    }

    /// The line placing the figure in `docId`, nil where it places none.
    func placement(in docId: String) -> FigureListing.Use? {
        placements.first { $0.docId == docId }
    }
}

extension ResolveReader {

    /// **The changed figures as `scope`'s items**: one per figure per piece
    /// that places it, at its first line there — placed on that line's
    /// paragraph only where the read already holds the piece's text (a
    /// `.piece` scope's own; a Book or Part groups by piece and needs none),
    /// else on the piece as a whole. An unused figure's item is the Book's
    /// (`docId: nil`), listed where the scope holds the Book's level. At a
    /// figure's own scope, its one item sits in the figure's group (`docId`
    /// is the figure's id). An edition, or a piece read in a language, lists
    /// none: a figure's pin is the source's. Pure.
    static func figureSourceItems(scope: ResolveScope, changes: [ResolveFigureChange],
                                  sequences: [String: [String]],
                                  paragraphText: [String: String]) -> [ResolveItem] {
        guard scope.translationLanguage == nil, !changes.isEmpty else { return [] }
        if case .figure(let id) = scope {
            return changes.filter { $0.figureId == id }.map {
                .figureSourceChanged(figureId: $0.figureId, docId: $0.figureId, paragraphId: nil)
            }
        }
        let inScope = Set(scope.docIds)
        var textOf: String?
        if case .piece(let docId, _) = scope { textOf = docId }
        var items: [ResolveItem] = []
        for change in changes {
            if change.placements.isEmpty {
                if scope.includesBookLevel {
                    items.append(.figureSourceChanged(figureId: change.figureId, docId: nil, paragraphId: nil))
                }
                continue
            }
            for use in change.placements where inScope.contains(use.docId) {
                var paragraphId: String?
                if use.docId == textOf, let sequence = sequences[use.docId] {
                    paragraphId = FigureUseTravel.place(atLine: use.lineIndex, paragraphs: paragraphText,
                                                        sequence: sequence)?.paragraphId
                }
                items.append(.figureSourceChanged(figureId: change.figureId, docId: use.docId,
                                                  paragraphId: paragraphId))
            }
        }
        return items
    }
}

// MARK: - The row

/// **What a changed source's row offers** — pure, so the truth table is
/// pinned without a window. Every verb is a reading: Compare… shows the
/// details' own sheet (whose Refresh, the one edit, asks the figure's own
/// door — `FigureActions.mayEdit`, the posture and read-through — and names
/// its refusal: `FigureInspector.refusal`); Open takes the window to the
/// figure; the sentence goes to the line placing it. A verb that cannot act
/// is not drawn. Neither needs the piece open: a figure is not a manuscript.
struct ResolveFigureSourceOffers: Equatable {
    /// The sentence is a link to the figure's line in its piece.
    let goesToTheLine: Bool
    let compare: Bool
    let open: Bool

    /// - Parameters:
    ///   - docId: the item's (`ResolveItem.figureSourceChanged`).
    ///   - hasTree: a tree stands behind the list, whose figure helper the
    ///     sheet's Refresh acts through.
    ///   - drawsFigure: the tree has a row to travel to
    ///     (`BinderTreeSectionsState.drawsFigure`).
    ///   - atFigureScope: the list is the figure's own; it is already there.
    static func of(change: ResolveFigureChange?, figureId: String, docId: String?, hasTree: Bool,
                   drawsFigure: Bool, atFigureScope: Bool) -> ResolveFigureSourceOffers {
        let piece = docId.map { !DocumentClass.isFigureDocId($0) } ?? false
        return ResolveFigureSourceOffers(
            goesToTheLine: piece && change?.placement(in: docId ?? "") != nil,
            compare: hasTree && (change?.pinsChanged ?? false),
            open: drawsFigure && !atFigureScope)
    }
}

/// **A changed source's row**: the sentence ("Table 2's source data
/// changed"), the figure's caption or name under it, Compare… and Open.
struct ResolveFigureSourceRow: View {
    static let compareTitle = "Compare\u{2026}"
    static let openTitle = "Open"

    let sentence: String
    let detail: String?
    let offers: ResolveFigureSourceOffers
    let goToTheLine: () -> Void
    let compare: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if offers.goesToTheLine {
                Button(action: goToTheLine) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
            if offers.compare || offers.open {
                HStack(spacing: 6) {
                    if offers.compare {
                        Button(Self.compareTitle, action: compare)
                    }
                    if offers.open {
                        Button(Self.openTitle, action: open)
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sentence)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The figure a row's Compare… opens the sheet for.
struct ResolveFigureCompare: Identifiable, Equatable {
    let figureId: String
    var id: String { figureId }
}

/// **Compare, from To resolve**: the details' own sheet (`FigurePinsCompare`),
/// over a model of its own — its rows read when it opens, through the
/// figure's host, as the inspector's are — and the figure helper's Refresh,
/// refused by the same answer and words as the inspector's (`refusal`). A
/// failed Refresh is said here, in the sheet the writer is looking at (fix
/// round 1, M1): the helper reports into the sheet's own model, never the
/// tree's alert, which is silent with the sidebar hidden.
struct ResolveFigureCompareSheet: View {
    let figureId: String
    let store: ProjectStore
    let documentStore: DocumentStore
    /// The window's figure helper, reporting to `report`
    /// (`FigureSectionVerbs.shared(report:windowRefusesWrites:)`).
    let actions: (_ report: @escaping (String) -> Void) -> FigureActions
    /// The figure's grid in this window's centre
    /// (`ResolveFigureSourceVerbs.openTheTable`); nil where the tree draws no
    /// row for it.
    let openTheTable: (() -> Void)?
    let done: () -> Void

    @State private var model: FigureInspectorModel

    init(figureId: String, store: ProjectStore, documentStore: DocumentStore,
         actions: @escaping (_ report: @escaping (String) -> Void) -> FigureActions,
         openTheTable: (() -> Void)?, done: @escaping () -> Void) {
        self.figureId = figureId
        self.store = store
        self.documentStore = documentStore
        self.actions = actions
        self.openTheTable = openTheTable
        self.done = done
        _model = State(initialValue: FigureInspectorModel(figureId: figureId))
    }

    /// **Why Refresh is not offered**, nil when it is: this Mac may not edit
    /// the figure (the posture's `.editFigure`, a view-only share, a piece
    /// in read-through — named), else no grid on it in this window. Pure
    /// over the helper; the sheet draws exactly this.
    static func refusal(actions: FigureActions, figureId: String) -> String? {
        FigureInspector.refusal(mayEdit: actions.mayEdit(figureId), reach: actions.gridReach(figureId),
                                readThrough: actions.readThroughRefusal(of: figureId))
    }

    /// **Refresh needs the table open in this window** (fix round 1, M5;
    /// closing round B): a sheet refused for that alone offers the way there
    /// — the figure's grid in this centre (`subjectShowingTheTable`), after
    /// which Refresh acts. Refused for any other reason (who may write), it
    /// offers nothing more. Pure.
    static func offersOpenTheTable(refusal: String?) -> Bool {
        refusal == FigureActions.openTheTableFirst
    }

    static let openTheTableTitle = "Open the Table"

    var body: some View {
        let actions = actions { [weak model] in model?.message = $0 }
        let refusal = Self.refusal(actions: actions, figureId: figureId)
        VStack(alignment: .leading, spacing: 0) {
            FigurePinsCompare(
                model: model,
                refusal: refusal,
                load: { await model.loadComparisons(store: store, documentStore: documentStore) },
                refresh: {
                    model.message = nil
                    return actions.refreshPins(figureId)
                },
                done: done)
            if let openTheTable, Self.offersOpenTheTable(refusal: refusal) {
                Button(Self.openTheTableTitle) {
                    done()
                    openTheTable()
                }
                .padding([.horizontal, .bottom])
            }
            if let message = model.message {
                Text(message)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .bottom])
            }
        }
    }
}

// MARK: - The row's verbs (fix round 1, M4)

/// **Where a changed source's row takes the writer**, decided without a
/// view, so the closures `ResolvePane` hands the row are pinned without an
/// assistive client.
@MainActor
enum ResolveFigureSourceVerbs {

    /// The sentence's destination: a piece, its paragraph, and whether the
    /// piece opens inside the faces (a Book or Part list stays).
    struct Place: Equatable {
        let docId: String
        let paragraphId: String?
        let insideTheFaces: Bool
    }

    /// **The line placing the figure, in its piece** — on the paragraph the
    /// read placed it at, else the one `paragraphOfLine` finds the line in
    /// now (production: `FigureUseTravel.destination`, the open `Document`
    /// or the derived cache — never a load). Nil where the item names no
    /// piece: an unused figure's, or the figure's own list's.
    static func place(of item: ResolveItem, change: ResolveFigureChange?, scope: ResolveScope,
                      paragraphOfLine: (FigureListing.Use) -> String?) -> Place? {
        guard case .figureSourceChanged = item else { return nil }
        let docId = item.docId
        guard docId != ProjectStore.projectTasksDocId, !DocumentClass.isFigureDocId(docId),
              let use = change?.placement(in: docId) else { return nil }
        return Place(docId: docId, paragraphId: item.paragraphId ?? paragraphOfLine(use),
                     insideTheFaces: ResolveNavigation.opensInsideTheFaces(docId: docId, scope: scope))
    }

    /// Go there: the going-to-a-place path every row uses.
    static func go(to place: Place) {
        if place.insideTheFaces {
            ResolveNavigation.goInsideTheFaces(toDocId: place.docId, paragraphId: place.paragraphId)
        } else {
            ResolveNavigation.go(toDocId: place.docId, paragraphId: place.paragraphId)
        }
    }

    /// **Open**: the travel a figure note's click makes — the tree reveals
    /// its row, then the window's subject becomes the figure.
    static func open(_ figureId: String, reveal: (String) -> Void, travel: (BinderSubject) -> Void) {
        reveal(figureId)
        travel(.figure(figureId))
    }

    /// **Open the Table** (closing round B): the figure's grid in this
    /// window's centre, whatever the window showed — from the figure's own
    /// list too, where a travel to the figure already faced (or pulled up
    /// beside) changes nothing. The tree reveals its row wherever it now
    /// lives (a chapter's fold included), so it lands in sight. Pure.
    static func subjectShowingTheTable(_ figureId: String, current: WindowSubject) -> WindowSubject {
        var next = current
        next.open = .figure(figureId)
        next.faces = .figure(figureId)
        if next.beside?.treeSubject == .figure(figureId) { next.beside = nil }
        return next
    }

    /// Open the Table, as the sheet's button does it.
    static func openTheTable(_ figureId: String, reveal: (String) -> Void,
                             show: (_ figureId: String) -> Void) {
        reveal(figureId)
        show(figureId)
    }
}
