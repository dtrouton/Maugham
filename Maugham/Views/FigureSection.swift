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
    /// **changed**: a pin's source, or the Research item the figure was made
    /// from, moved on since it was taken (`FigureCardModel.changed`).
    let changed: Bool

    var id: String { listing.figureId }
    /// **unused**: no line in the book uses it, so its number is "—".
    var isUnused: Bool { listing.number == FigureListing.unusedNumber }
    /// What the row reads as: the caption the book gives it, else its name.
    var title: String { listing.caption.isEmpty ? listing.name : listing.caption }

    /// **What the tree draws of the row, and acts on** (final review M6):
    /// the listing less its line indexes — typing above a figure line moves
    /// those on every settle, and no row shows or uses one (the count and the
    /// filter ask which pieces, the menu the number, caption and piece).
    struct Drawn: Equatable {
        let figureId: String, kind: FigureKind, name: String, caption: String, number: String
        let pieces: [String]
        let pieceOfLine: String?
        let readsResearch: Bool, changed: Bool
    }

    var drawn: Drawn {
        Drawn(figureId: listing.figureId, kind: listing.kind, name: listing.name, caption: listing.caption,
              number: listing.number, pieces: listing.usedIn.map(\.docId), pieceOfLine: listing.pieceOfLine,
              readsResearch: readsResearch, changed: changed)
    }

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
                                 changed: model?.changed ?? false)
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

    /// Whether the section has a row for `figureId` — not parked, in a
    /// project that shows the section — whatever the piece filter hides: a
    /// figure note's click travels only to one (`AnnotationScopePolicy.click`),
    /// so it never lands on a subject the window would repair away, and a
    /// glance filter never makes the click dead (`revealFigure` lifts it).
    func drawsFigure(_ figureId: String, projectType: ProjectType) -> Bool {
        showsFigures(projectType: projectType) && figureRows.contains { $0.id == figureId }
    }

    /// **A figure subject arriving from outside the tree** (a note's click):
    /// the figure counterpart of `reveal` — a piece filter that hides it is
    /// lifted, the section opens, and the tree scrolls to its row. Only ever
    /// opens; a figure the section has no row for moves nothing.
    func revealFigure(_ figureId: String) {
        guard figureRows.contains(where: { $0.id == figureId }) else { return }
        if !drawnFigureRows.contains(where: { $0.id == figureId }) { pieceFilter = nil }
        figuresSectionExpanded = true
        scrollRequest = .row(.figure(figureId))
    }

    /// `revealFigure`, now or — for a figure just made, whose row the listing
    /// and cards have yet to bring — once its row is drawn, within
    /// `figureRevealWindow`; a row that has not drawn by then (the figure
    /// parked or removed meanwhile) is let go, so no later draw scrolls to it.
    /// Answers the wait, which a test awaits.
    @discardableResult
    func revealFigureWhenDrawn(_ figureId: String) -> Task<Void, Never>? {
        if figureRows.contains(where: { $0.id == figureId }) {
            pendingFigureReveal = nil
            revealFigure(figureId)
            return nil
        }
        pendingFigureReveal = figureId
        return Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.figureRevealWindow)
            if self?.pendingFigureReveal == figureId { self?.pendingFigureReveal = nil }
        }
    }

    /// How long a figure made from Research waits for its row to draw.
    static var figureRevealWindow: Duration = .seconds(10)

    /// Ask the store again which Research items bring a figure back.
    func refreshFigureReturns(store: ProjectStore?) async {
        guard let store, store.manifest.type.holdsFigures else {
            if !figureReturns.isEmpty { figureReturns = [:] }
            return
        }
        let next = await store.figuresToBringBack()
        guard !Task.isCancelled, next != figureReturns else { return }
        figureReturns = next
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
    func figureCardsChanged() {
        figureCardsVersion = figureCards.version
        rebuildFigureRows()
    }

    /// The window let its project go: the cards stop and drop what they held.
    func detachFigureCards() {
        figureCards.attach(nil)
        figureCardsStore?.detachFigureCardCache(figureCards)
        figureCardsStore = nil
        refreshFigureRows(listing: [])
    }

    private func rebuildFigureRows() {
        // Which figures are parked, as the cards say: what a Research item's
        // Bring Back answer turns on (`FigureSectionWiring`'s key).
        let parked = Set(figureListingRows.map(\.figureId).filter {
            figureCards.model(forFigureId: $0)?.kind == .parked
        })
        if parked != parkedFigureIds { parkedFigureIds = parked }
        let next = FigureTreeRow.build(listing: figureListingRows,
                                       card: figureCards.model(forFigureId:))
        // Only what a row draws: a line index moving redraws no tree.
        guard next.map(\.drawn) != figureRows.map(\.drawn) else { return }
        figureRows = next
        figureCounts = FigureCount.byPiece(next)
        // A piece that no longer uses a figure filters to nothing: let it go.
        if let piece = pieceFilter, figureCounts[piece] == nil { pieceFilter = nil }
        if let pending = pendingFigureReveal, figureRows.contains(where: { $0.id == pending }) {
            revealFigureWhenDrawn(pending)
        }
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

/// **What a figure row's menu does** (report plan 8a Task 4): the shared
/// `FigureActions` (Task 7 — the inspector calls the same helper), seen from
/// the tree — its figure windows, typography and share, a failure reaching
/// the tree's alert (`state.pendingError`).
@MainActor
struct FigureSectionVerbs {
    let store: ProjectStore
    let state: BinderTreeSectionsState

    /// The one helper, as the tree hands it what it knows.
    var shared: FigureActions {
        let state = state
        return FigureActions(
            store: store, figureWindows: state.figureWindows, typography: state.figureTypography,
            windowRefusesWrites: { state.figureWritesRefused },
            report: { state.pendingError = $0 },
            // A success with something to say is a notice, not the alert.
            notice: { [url = store.url] in MaughamEvent.postNotice($0, projectURL: url) })
    }

    /// The helper with `report` of the caller's own (the Research inspector's
    /// line) and the window's refusal as the caller observes it.
    func shared(report: @escaping (String) -> Void, notice: ((String) -> Void)? = nil,
                windowRefusesWrites: Bool) -> FigureActions {
        FigureActions(store: store, figureWindows: state.figureWindows, typography: state.figureTypography,
                      windowRefusesWrites: { windowRefusesWrites }, report: report, notice: notice)
    }

    /// A Research row's verb toward Figures (`FigureActions.researchVerb`).
    func researchVerb(for item: ResearchItem) -> FigureActions.ResearchVerb? {
        shared.researchVerb(for: item, returning: state.figureReturns[item.id])
    }

    /// The row's *Use in Document* / *Bring Back to Figures*: the figure's row
    /// is revealed once drawn; what goes wrong reaches the tree's alert.
    @discardableResult
    func useInDocument(_ item: ResearchItem) -> Task<Void, Never> {
        let state = state
        return shared.useInDocument(item, reveal: { state.revealFigureWhenDrawn($0) })
    }

    func actions(for row: FigureTreeRow) -> FigureRowActions {
        let shared = shared, listing = row.listing
        return FigureRowActions(
            mayEdit: { shared.mayEdit(listing.figureId) },
            sendDestinations: shared.sendDestinations(for: listing),
            openInWindow: { shared.openInWindow(listing) },
            sendToResearch: { _ = shared.sendToResearch(listing, to: $0) },
            rename: { _ = shared.rename(listing.figureId, to: $0) })
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
    /// The window's control plane (the share, ⌘⌥⇧R) and persona: the one
    /// answer to whether this window refuses figure writes, shared with the
    /// inspector (`FigureActions.windowRefusesWrites`).
    let control: EditorControl
    let persona: Persona

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
            // Research changing moves a pin's source (the **changed** and
            // **Research** tags) and a `research:` formula's value: refill.
            .onChange(of: store?.manifest.research) { _, _ in treeState.figureCards.invalidate() }
            .onChange(of: figureWindows.map(ObjectIdentifier.init), initial: true) { _, _ in
                treeState.figureWindows = figureWindows
            }
            .onChange(of: typography, initial: true) { _, next in treeState.figureTypography = next }
            .onChange(of: FigureActions.windowRefusesWrites(control: control, persona: persona),
                      initial: true) { _, refused in treeState.figureWritesRefused = refused }
            // Which Research items bring a parked figure back: asked again
            // when Research, the registry, the set of parked figures or the
            // posture moves — never per card fill; the newest asking wins.
            .task(id: ReturnsKey(research: store?.manifest.research, figures: store?.manifest.figures,
                                 parked: treeState.parkedFigureIds, posture: documentStore?.postureEpoch)) {
                await treeState.refreshFigureReturns(store: store)
            }
    }

    private struct ReturnsKey: Equatable {
        let research: [ResearchItem]?, figures: [FigureRecord]?, parked: Set<String>, posture: Int?
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
