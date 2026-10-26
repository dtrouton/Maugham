import Foundation
import MaughamCore

/// **The window's figure cards, in memory** (report plan 7a Task 3): one
/// `FigureCardModel` per registered figure, built from the book's computed
/// values. `EditorHost` owns one beside `ReferenceIndexHost`, the same way: a
/// plain reference, deliberately not observable (tripwire 6). The editor's
/// styler and card overlay read it synchronously; nothing here runs per
/// keystroke.
///
/// **Reads are memory only.** `model(forFigureId:)` and
/// `model(forLinePath:documentPath:)` never touch the disk or open a figure:
/// a figure not yet filled answers nil, and its line reserves the placeholder
/// height until the fill lands (ruling R7a-2).
///
/// **What fills it** (`invalidate()`): the host appearing (`attach`), the
/// registry changing (`EditorHost`'s manifest watch), and `DocumentStore`'s
/// figure triggers through `DocumentStore.figureCardCaches` — an open host
/// appending an op (`figureHostAppended`), the presenter's figure pass
/// (`applyPendingFigureChanges`, which a registry adoption also feeds) and a
/// trust change. Every trigger in one main-actor turn makes ONE fill, and a
/// trigger during a fill makes one more after it. A fill reads through
/// `Source.read` (production: `DocumentStore.figureCardInputs()`, the figure
/// cache and the open hosts' folds — never `figures/<name>.csv`, tripwire 20, and
/// never a host opened for it), then rebuilds every card, since a formula can
/// carry one figure's change into another's values.
///
/// **What changed** is only a version: each fill whose cards or registry
/// records differ from the last fill's (a figure that appeared or left
/// included) bumps `version` once and `onVersionChange` fires. The editor
/// then asks each figure line its room again and restyles only the lines
/// whose room moved (`EditorCoordinator.refreshFigureRooms`). The first
/// fill always bumps, even with nothing in it: lines that named no figure
/// stop being cache misses then.
///
/// **A figure brought back** (`readopt(figureId:)`, whole-branch review I2): a
/// fill that sees a figure leave the registry keeps its record and card among
/// the last few departed, in memory. A redo that brings the figure back
/// (`FigureBirthUndo`) writes its line before the store's restore lands, so it
/// asks for the departed card back at once — the line shows its table, not
/// "Figure removed", until the next fill says what the registry holds.
///
/// **Closing.** `attach(nil)` (the host's teardown) drops every card and
/// bumps the generation, so a fill still in flight lands nowhere.
@MainActor
final class FigureCardCache {

    /// How the cache reads the book. `EditorHost` builds it over its
    /// `DocumentStore`; tests hand in a closure.
    struct Source {
        /// One fill's inputs, off the typing path; nil when they did not read
        /// (the window closing, the registry unreadable), which leaves the
        /// cards as they were.
        var read: () async -> FigureCardInputs?
    }

    /// Bumps once per fill that changed a card (and on the first fill).
    private(set) var version = 0
    /// Called on the main actor with the new version after a fill changed a
    /// card. `EditorHost` writes it to the editor's control plane
    /// (`EditorControl.figureCardVersion`, plan 7a Task 4).
    var onVersionChange: ((Int) -> Void)?

    private var source: Source?
    private var models: [String: FigureCardModel] = [:]
    /// The registry as of the last fill: line lookups resolve against it, so
    /// what a line shows moves only with `version`.
    private var records: [FigureRecord] = []
    /// `records` keyed for line lookups, built once per fill.
    private var index = FigureLineResolution.Index([])
    /// The figures fills saw leave the registry, most recent last, with the
    /// card each had (`readopt(figureId:)`); at most `departedLimit`.
    private var departed: [(record: FigureRecord, model: FigureCardModel?)] = []
    static let departedLimit = 8
    private var hasFilled = false
    private var dirty = false
    private var filling: Task<Void, Never>?
    /// The fill `attach` last cut loose, kept only so `idle()` can wait it out.
    private var abandoned: Task<Void, Never>?
    /// Bumped by `attach`, so a fill started for an earlier project neither
    /// publishes into this one nor clears this one's `filling`.
    private var generation = 0

    init() {}

    /// Point the cache at a window's book (or at none, `nil`, which stops
    /// it and drops every card) and fill from scratch.
    func attach(_ source: Source?) {
        self.source = source
        generation += 1
        filling?.cancel()
        abandoned = filling ?? abandoned
        filling = nil
        dirty = false
        models.removeAll()
        records.removeAll()
        departed.removeAll()
        index = FigureLineResolution.Index([])
        hasFilled = false
        guard source != nil else { return }
        invalidate()
    }

    /// The book's figures may have changed: fill once this turn is over.
    func invalidate() {
        guard source != nil else { return }
        dirty = true
        guard filling == nil else { return }
        let generation = generation
        filling = Task { [weak self] in await self?.drain(generation) }
    }

    /// The card for figure `figureId`, or nil when no fill has built one
    /// (not filled yet, unreadable, or not registered). Memory only.
    func model(forFigureId figureId: String) -> FigureCardModel? {
        models[figureId]
    }

    /// **The card under a figure line**, resolved here so no caller resolves
    /// paths itself (`FigureLineResolution`, the rule Publish uses): nil
    /// before the first fill; a line naming no registered figure in
    /// `figures/` is `.removed`, two records sharing its path `.ambiguous`
    /// (ruling R7a-3); a line outside `figures/` (a picture in Research, or
    /// a path that is not local) is `.image`, today's thumbnail. Memory only.
    /// - Parameters:
    ///   - linePath: the path as written on the line.
    ///   - documentPath: the document's project-relative path.
    func model(forLinePath linePath: String, documentPath: String) -> FigureCardModel? {
        guard hasFilled else { return nil }
        switch index.record(forLinePath: linePath, documentPath: documentPath) {
        case .figure(let record): return models[record.id]
        case .ambiguous: return .placeholder(.ambiguous)
        case .none:
            guard case .inside(_, let root) = FigurePathRule.lexical(linePath, piecePath: documentPath),
                  root == [ProjectStore.figuresFolder] else { return .placeholder(.image) }
            return .placeholder(.removed)
        }
    }

    /// **What a figure line's path is** (the caption bar and diagnostics, report
    /// plan 7b): `FigureLineResolution.status` over the registry as of the last
    /// fill. Nil before the first fill; memory only, no card needed — so an image
    /// figure answers `.figure` too.
    func status(forLinePath linePath: String, documentPath: String) -> FigureLineResolution.Status? {
        guard hasFilled else { return nil }
        return FigureLineResolution.status(linePath: linePath, documentPath: documentPath, index: index)
    }

    /// **A departed figure is coming back** (a redo restoring it from the
    /// Trash, `FigureBirthUndo`): its last record and card return to the
    /// lookups now, synchronously, and the version bumps, so the line the redo
    /// just wrote resolves to its table instead of "Figure removed". The next
    /// fill replaces this with what the registry holds: a restore that lands
    /// changes the registry, which refills the cards; a refused one changes
    /// nothing, so `FigureBirthUndo` refills them itself, and the line then
    /// shows what it really names (re-review N1). Memory only; nothing when
    /// the figure is registered, never departed, or no fill has run.
    func readopt(figureId: String) {
        guard hasFilled, !records.contains(where: { $0.id == figureId }),
              let at = departed.lastIndex(where: { $0.record.id == figureId }) else { return }
        let back = departed.remove(at: at)
        records.append(back.record)
        models[figureId] = back.model
        index = FigureLineResolution.Index(records)
        version += 1
        onVersionChange?(version)
    }

    /// Returns once no fill is pending or running, an abandoned one included.
    /// Tests wait on it, and so does a command that has just made a figure
    /// before it writes the figure's line (`DocumentStore.settleFigureCards`,
    /// whole-branch review I2) — off the typing path; nothing per keystroke
    /// waits.
    func idle() async {
        await abandoned?.value
        while let task = filling { await task.value }
    }

    // MARK: - Filling

    private func drain(_ generation: Int) async {
        while dirty, generation == self.generation, let source {
            dirty = false
            let inputs = await source.read()
            guard generation == self.generation else { return }
            if let inputs { apply(inputs) }
        }
        if generation == self.generation { filling = nil }
    }

    private func apply(_ inputs: FigureCardInputs) {
        var next: [String: FigureCardModel] = [:]
        for record in inputs.records where next[record.id] == nil {
            guard let state = inputs.states[record.id] else { continue }
            let id = record.id, book = inputs.workbook
            next[id] = FigureCardModel.build(
                figureId: id, state: state,
                values: { book?.value(at: CellAddress(table: id, key: $0)) ?? .empty },
                locale: inputs.locale,
                // The source language: plan 9 passes an edition's, with its labels.
                language: nil, labelLookup: { _, _, _, _ in nil },
                pinChanged: inputs.pinChanged.contains(id))
        }
        let before = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(inputs.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let moved = next != models || after != before
        let first = !hasFilled
        for record in records where after[record.id] == nil {
            departed.append((record, models[record.id]))
        }
        departed.removeAll { after[$0.record.id] != nil }
        if departed.count > Self.departedLimit {
            departed.removeFirst(departed.count - Self.departedLimit)
        }
        models = next
        records = inputs.records
        index = FigureLineResolution.Index(inputs.records)
        hasFilled = true
        guard first || moved else { return }
        version += 1
        onVersionChange?(version)
    }
}
