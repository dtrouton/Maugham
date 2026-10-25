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
/// figure triggers through `DocumentStore.figureCardCache` — an open host
/// appending an op (`figureHostAppended`), the presenter's figure pass
/// (`applyPendingFigureChanges`, which a registry adoption also feeds) and a
/// trust change. Every trigger in one main-actor turn makes ONE fill, and a
/// trigger during a fill makes one more after it. A fill reads through
/// `Source.read` (production: `DocumentStore.figureCardInputs()`, the figure
/// cache and the open hosts' folds — never `figures/<name>.csv`, tripwire 20, and
/// never a host opened for it), then rebuilds every card, since a formula can
/// carry one figure's change into another's values.
///
/// **What changed** is a drain: each fill that changes anything bumps
/// `version` once (`onVersionChange` fires) and adds to the set
/// `takeChanged()` hands back and clears — the ids whose card or whose
/// registry record differ from the last fill, including a figure that
/// appeared or left. The editor does not need it to re-lay out: on a new
/// version it asks each figure line its room again and restyles only the
/// lines whose room moved (`EditorCoordinator.refreshFigureRooms`). The
/// first fill always bumps, even with nothing in it: lines that named no
/// figure stop being cache misses then.
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
    private var hasFilled = false
    private var changed = Set<String>()
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
        changed.removeAll()
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
        switch FigureLineResolution.record(forLinePath: linePath, documentPath: documentPath, records: records) {
        case .figure(let record): return models[record.id]
        case .ambiguous: return .placeholder(.ambiguous)
        case .none:
            guard case .inside(_, let root) = FigurePathRule.lexical(linePath, piecePath: documentPath),
                  root == [ProjectStore.figuresFolder] else { return .placeholder(.image) }
            return .placeholder(.removed)
        }
    }

    /// The figure ids changed since the last call, and clears them.
    func takeChanged() -> Set<String> {
        defer { changed.removeAll() }
        return changed
    }

    /// Returns once no fill is pending or running, an abandoned one included
    /// (tests; a host never waits).
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
        var moved = Set<String>()
        for id in Set(next.keys).union(models.keys) where next[id] != models[id] { moved.insert(id) }
        for id in Set(after.keys).union(before.keys) where after[id] != before[id] { moved.insert(id) }
        let first = !hasFilled
        models = next
        records = inputs.records
        hasFilled = true
        guard first || !moved.isEmpty else { return }
        changed.formUnion(moved)
        version += 1
        onVersionChange?(version)
    }
}
