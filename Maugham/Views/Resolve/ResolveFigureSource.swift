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
/// refused by the same answer and words as the inspector's.
struct ResolveFigureCompareSheet: View {
    let figureId: String
    let store: ProjectStore
    let documentStore: DocumentStore
    let actions: FigureActions
    let done: () -> Void

    @State private var model: FigureInspectorModel

    init(figureId: String, store: ProjectStore, documentStore: DocumentStore,
         actions: FigureActions, done: @escaping () -> Void) {
        self.figureId = figureId
        self.store = store
        self.documentStore = documentStore
        self.actions = actions
        self.done = done
        _model = State(initialValue: FigureInspectorModel(figureId: figureId))
    }

    var body: some View {
        FigurePinsCompare(
            model: model,
            refusal: FigureInspector.refusal(mayEdit: actions.mayEdit(figureId),
                                             reach: actions.gridReach(figureId),
                                             readThrough: actions.readThroughRefusal(of: figureId)),
            load: { await model.loadComparisons(store: store, documentStore: documentStore) },
            refresh: { actions.refreshPins(figureId) },
            done: done)
    }
}
