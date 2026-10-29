import SwiftUI
import MaughamCore

/// **One row of the tree's Figures section** (report plan 8a Task 4): the
/// window's `FigureListing` row with the tags its card gives it. A value,
/// cached on `BinderTreeSectionsState.figureRows` (tripwire 4) — a row reads
/// this and nothing else.
struct FigureTreeRow: Equatable, Identifiable {
    let listing: FigureListing.Row
    /// **Research**: the figure holds a research pin (`FigureCardModel.readsResearch`).
    let readsResearch: Bool
    /// **changed**: a pin's source moved on since it was taken (`pinChanged`).
    let pinChanged: Bool

    var id: String { listing.figureId }
    /// **unused**: no line in the book uses it, so its number is "—".
    var isUnused: Bool { listing.number == FigureListing.unusedNumber }
    /// What the row reads as: the caption the book gives it, else its name.
    var title: String { listing.caption.isEmpty ? listing.name : listing.caption }

    /// The listing's rows, in its order, tagged by each figure's card; a
    /// figure whose card says it is parked in Research is left out (D8-1). A
    /// figure with no card yet (the first fill not landed, or its stream
    /// unreadable) is drawn untagged.
    static func build(listing: [FigureListing.Row],
                      card: (String) -> FigureCardModel?) -> [FigureTreeRow] {
        listing.compactMap { row in
            let model = card(row.figureId)
            if model?.kind == .parked { return nil }
            return FigureTreeRow(listing: row, readsResearch: model?.readsResearch ?? false,
                                 pinChanged: model?.pinChanged ?? false)
        }
    }
}

/// **How many figures a piece's text uses** — the count a piece row shows
/// (D8-1): a figure counts once per piece that holds one of its lines.
struct FigureCount: Equatable {
    var tables = 0
    var figures = 0

    /// "3 tables", "1 figure", "2 tables, 1 figure"; nil at none.
    var text: String? {
        var parts: [String] = []
        if tables > 0 { parts.append(tables == 1 ? "1 table" : "\(tables) tables") }
        if figures > 0 { parts.append(figures == 1 ? "1 figure" : "\(figures) figures") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Each piece's count over `rows`, by document id; a piece holding none
    /// is absent.
    static func byPiece(_ rows: [FigureTreeRow]) -> [String: FigureCount] {
        var out: [String: FigureCount] = [:]
        for row in rows {
            for piece in Set(row.listing.usedIn.map(\.docId)) {
                switch row.listing.kind {
                case .table: out[piece, default: FigureCount()].tables += 1
                case .image, .unknown: out[piece, default: FigureCount()].figures += 1
                }
            }
        }
        return out
    }
}

// MARK: - The state's half

extension BinderTreeSectionsState {

    /// The section's rows as drawn: every row, or the filtered piece's.
    var drawnFigureRows: [FigureTreeRow] {
        guard let piece = pieceFilter else { return figureRows }
        return figureRows.filter { $0.listing.usedIn.contains { $0.docId == piece } }
    }

    /// **Does the tree show a Figures section?** Only where the project's
    /// manuscript holds figures (tripwire 55) and some figure is not parked
    /// (D8-1, the middle path).
    func showsFigures(projectType: ProjectType) -> Bool {
        projectType.holdsFigures && !figureRows.isEmpty
    }

    /// Whether the section draws a row for `figureId` now — a figure note's
    /// click travels only to one (`AnnotationScopePolicy.click`), so it never
    /// lands on a subject the window would repair away or the tree not show.
    func drawsFigure(_ figureId: String, projectType: ProjectType) -> Bool {
        showsFigures(projectType: projectType) && drawnFigureRows.contains { $0.id == figureId }
    }

    /// The count a piece row shows, nil at none or where the section is not shown.
    func figureCountText(forPiece documentId: String, projectType: ProjectType) -> String? {
        guard showsFigures(projectType: projectType) else { return nil }
        return figureCounts[documentId]?.text
    }

    /// **A piece row's count, pressed**: the section filters to that piece,
    /// opens, and scrolls into view. Selects nothing.
    func showFigures(inPiece documentId: String) {
        pieceFilter = documentId
        figuresSectionExpanded = true
        scrollRequest = .figuresHeader
    }

    /// The header chip's ×: every figure again.
    func clearFigureFilter() { pieceFilter = nil }

    /// The window's listing changed.
    func refreshFigureRows(listing: [FigureListing.Row]) {
        figureListingRows = listing
        rebuildFigureRows()
    }

    /// The tree's cards filled.
    func figureCardsChanged() { rebuildFigureRows() }

    /// The window let its project go: the cards stop and drop what they held.
    func detachFigureCards() {
        figureCards.attach(nil)
        figureCardsStore?.detachFigureCardCache(figureCards)
        figureCardsStore = nil
        refreshFigureRows(listing: [])
    }

    private func rebuildFigureRows() {
        let next = FigureTreeRow.build(listing: figureListingRows,
                                       card: figureCards.model(forFigureId:))
        guard next != figureRows else { return }
        figureRows = next
        figureCounts = FigureCount.byPiece(next)
        // A piece that no longer uses a figure filters to nothing: let it go.
        if let piece = pieceFilter, figureCounts[piece] == nil { pieceFilter = nil }
    }
}

// MARK: - The section

extension BinderTreeSections {

    /// **The Figures section** (report plan 8a Task 4, spec §7, D8-1): the
    /// book's numbered figures in reading order, then the unused ones, each
    /// a `FigureRow` tagged `.figure(id)`. Mounted first in `body`, so all
    /// three hosts draw it between their manuscript and Research; absent
    /// where `showsFigures` says so. A plain `Section` reading its flag, for
    /// `researchSection`'s reason (`sectionChevron`).
    @ViewBuilder
    var figuresSection: some View {
        if state.showsFigures(projectType: store.manifest.type) {
            Section {
                if state.figuresSectionExpanded {
                    let verbs = FigureSectionVerbs(store: store, state: state)
                    ForEach(state.drawnFigureRows) { row in
                        FigureRow(row: row, renamingItemId: $state.renamingItemId,
                                  actions: verbs.actions(for: row))
                    }
                }
            } header: {
                figuresHeader
                    .id(TreeScrollTarget.figuresHeader)
            }
        }
    }

    /// The chevron, the title and — while a piece filters the section — its
    /// chip, whose press clears the filter.
    private var figuresHeader: some View {
        HStack {
            HStack(spacing: 2) {
                sectionChevron("Figures", section: .figures)
                Text("Figures")
            }
            Spacer()
            if let piece = state.pieceFilter {
                Button {
                    state.clearFigureFilter()
                } label: {
                    Text("\(FigureSectionVerbs.pieceTitle(piece, in: store.manifest.structure)) \u{00D7}")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Show every figure")
                .accessibilityLabel("Clear the figure filter")
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - The verbs

/// **What a figure row's menu does** (report plan 8a Task 4): Open in Window,
/// Send to Research and Rename, through the store's verbs; a failure reaches
/// the tree's alert (`state.pendingError`). Task 7's inspector will share
/// these.
@MainActor
struct FigureSectionVerbs {
    let store: ProjectStore
    let state: BinderTreeSectionsState

    func actions(for row: FigureTreeRow) -> FigureRowActions {
        let id = row.id
        return FigureRowActions(
            mayEdit: mayEdit(id),
            sendDestinations: sendDestinations(for: row),
            openInWindow: { openInWindow(row) },
            sendToResearch: { _ = sendToResearch(row, to: $0) },
            rename: { _ = rename(id, to: $0) })
    }

    /// The posture's one door (tripwires 47, 51): a figure the Mac may not
    /// edit offers no Send to Research and no Rename.
    func mayEdit(_ figureId: String) -> Bool {
        store.documentStore?.posture(forDocId: figureId).allows(.editFigure) ?? false
    }

    /// Where Send to Research may put the figure: the piece holding its line
    /// (else the piece it was made in), when there is one, and shared.
    func sendDestinations(for row: FigureTreeRow) -> [FigureResearchDestination] {
        piece(of: row) == nil ? [.shared] : [.piece, .shared]
    }

    func piece(of row: FigureTreeRow) -> String? {
        row.listing.pieceOfLine
            ?? store.manifest.figures?.first { $0.id == row.id }?.piece
    }

    /// **Open in Window**: the grid that has the figure comes front; else a
    /// window opens on it, handed the number and caption the listing gives.
    func openInWindow(_ row: FigureTreeRow) {
        if let windows = state.figureWindows {
            if windows.focus(row.id) { return }
            windows.handOff(row.id, .init(number: row.listing.number, caption: row.listing.caption,
                                          piece: piece(of: row), typography: state.figureTypography))
        }
        MaughamEvent.postOpenFigureWindow(figureId: row.id)
    }

    /// **Send to Research** (R7d-7): every grid on the figure folds and its
    /// writes land first, then the park. Not undoable (ruling P-8); a
    /// refusal is said. Answers the work, which a test awaits.
    @discardableResult
    func sendToResearch(_ row: FigureTreeRow,
                        to destination: FigureResearchDestination) -> Task<Void, Never>? {
        let scope: ResearchScope
        switch destination {
        case .piece:
            guard let piece = piece(of: row) else { return nil }
            scope = .document(piece)
        case .shared:
            scope = .shared
        }
        let windows = state.figureWindows, figureId = row.id
        return run {
            await windows?.foldGrids(on: figureId)
            _ = try await store.sendToResearch(figureId: figureId, scope: scope)
        }
    }

    /// Rename the figure (its registry name; formulas follow, the store's verb).
    @discardableResult
    func rename(_ figureId: String, to name: String) -> Task<Void, Never> {
        run { _ = try await store.renameFigure(id: figureId, to: name) }
    }

    /// `BinderTreeVerbs.perform`'s shape — a failure reaches the tree's
    /// alert — answering its task.
    private func run(_ work: @escaping () async throws -> Void) -> Task<Void, Never> {
        let state = state
        return Task { @MainActor in
            do { try await work() }
            catch { state.pendingError = error.localizedDescription }
        }
    }

    /// A piece's title for the filter chip; its id when the binder has none.
    static func pieceTitle(_ documentId: String, in structure: [StructureItem]) -> String {
        TreeWalk.find(id: documentId, in: structure)?.title ?? documentId
    }
}

// MARK: - The window's wiring

/// **The tree's figures, wired** (report plan 8a Task 4): the window's
/// `FigureListingModel` rows reach `BinderTreeSectionsState` (which all three
/// tree hosts are handed), the tree's own `FigureCardCache` attaches to the
/// window's `DocumentStore` the way `FigureWindowGrid.watchTheBook()` does,
/// and the project's `FigureWindows` and the editor's typography are left
/// where a row's verbs find them.
///
/// Its own modifier because `ProjectWindow.body` has no type-check budget.
struct FigureSectionWiring: ViewModifier {
    let store: ProjectStore?
    let documentStore: DocumentStore?
    let listing: FigureListingModel
    let treeState: BinderTreeSectionsState
    let figureWindows: FigureWindows?
    let typography: TypographySettings

    func body(content: Content) -> some View {
        content
            .onChange(of: documentStore.map(ObjectIdentifier.init), initial: true) { _, _ in
                Self.attach(treeState, to: documentStore)
            }
            .onChange(of: listing.rows, initial: true) { _, rows in
                treeState.refreshFigureRows(listing: rows)
            }
            // A figure made, renamed or removed: the cards refill.
            .onChange(of: store?.manifest.figures) { _, _ in treeState.figureCards.invalidate() }
            .onChange(of: figureWindows.map(ObjectIdentifier.init), initial: true) { _, _ in
                treeState.figureWindows = figureWindows
            }
            .onChange(of: typography, initial: true) { _, next in treeState.figureTypography = next }
    }

    /// Point the tree's cards at `documentStore` (or at none), each fill
    /// rebuilding the rows. Not private: the wiring test drives it.
    static func attach(_ treeState: BinderTreeSectionsState, to documentStore: DocumentStore?) {
        let cards = treeState.figureCards
        if let previous = treeState.figureCardsStore, previous !== documentStore {
            previous.detachFigureCardCache(cards)
        }
        guard let documentStore else {
            treeState.detachFigureCards()
            return
        }
        treeState.figureCardsStore = documentStore
        cards.onVersionChange = { [weak treeState] _ in treeState?.figureCardsChanged() }
        documentStore.attachFigureCardCache(cards)
        cards.attach(FigureCardCache.Source(read: { [weak documentStore] in
            await documentStore?.figureCardInputs()
        }))
    }
}
