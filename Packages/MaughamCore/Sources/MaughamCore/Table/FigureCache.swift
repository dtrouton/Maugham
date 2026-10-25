import Foundation

/// Per-project in-memory cache of derived figure states, on
/// `DerivedManuscriptCache`'s token pattern: the sorted `(path, mtime, size)`
/// of the figure's op-log file set. An append, seal or sync changes a file's
/// size or mtime and so invalidates exactly that figure.
///
/// The read goes through `OpLogStore.loadSyncMerged` (the sanctioned closed-doc
/// read) with the manifest's `DocumentClass.Facts`, so a narrowed author's
/// figure lines are judged as `.figure`, not `.piece`. It never hand-rolls a
/// partition call (tripwire 45) and never reads `figures/<name>.csv`
/// (tripwire 20). The token does not cover `trust` or `facts`: a caller whose
/// either changed must `invalidateAll()`.
///
/// Main-actor only, one per project.
@MainActor
public final class FigureCache {

    private struct Line {
        let token: DerivedManuscriptCache.Token
        /// What the facts say about THIS figure: absent, or present with its piece.
        let facts: String
        let state: FigureState
    }

    private var lines: [String: Line] = [:]

    /// Number of times a derive actually ran (a cache miss); tests count it.
    public private(set) var deriveCount: Int = 0

    public init() {}

    /// The derived state of the figure's stream: cached while its op-log file
    /// set is unchanged, else loaded and folded afresh. Throws as
    /// `DerivedManuscript.derivedState` does (RULING-54).
    public func state(
        forFigureId figureId: String, in projectURL: URL, trust: TrustTable? = nil,
        facts: DocumentClass.Facts
    ) throws -> FigureState {
        let token = DerivedManuscriptCache.token(forDocId: figureId, in: projectURL)
        // A record appearing or its piece changing moves the figure's class, and so
        // the permit's judgement of its lines, with no op-log file moving.
        let fingerprint = facts.figures.first { $0.id == figureId }
            .map { "present:\($0.piece ?? "-")" } ?? "absent"
        if let line = lines[figureId], line.token == token, line.facts == fingerprint {
            return line.state
        }
        let ops = try OpLogStore.loadSyncMerged(
            forDocId: figureId, in: projectURL, trust: trust, facts: facts)
        let state = FigureDeriver.derive(ops)
        deriveCount &+= 1
        lines[figureId] = Line(token: token, facts: fingerprint, state: state)
        return state
    }

    /// Drop one figure's cached line (a guaranteed re-derive without racing mtime).
    public func invalidate(figureId: String) { lines[figureId] = nil }

    /// Drop every line whose figure is not in `keeping`.
    func evict(except keeping: Set<String>) {
        for id in lines.keys where !keeping.contains(id) { lines[id] = nil }
    }

    /// Drop everything, e.g. when trust or the registry changed.
    public func invalidateAll() { lines.removeAll() }
}

/// **Every figure's research pins, as the workbook reads them** (spec §4.3,
/// report plan 6b Task 9): per reading figure ("home"), the winning live pin
/// on each source cell — a Research item's or a parked figure's, by id and
/// 0-based position. Pins live per cell (`FigureState.pins`); which counts
/// and which wins is `FigurePinChoice`, the rule `FigurePins` uses too: a pin
/// from an earlier park of a figure is inert, and among the rest the later
/// `at`, then the earlier cell, then the greater hash wins.
public struct FigurePinIndex: ResearchPinSource {
    private var pinsByHome: [String: [CellKey: [FigureResearchPin]]] = [:]
    /// Each parked figure's current park cycle (`FigureParking.cycle`).
    private var parks: [String: String] = [:]
    private var winners: [String: [PinRead: FigureResearchPin]] = [:]

    public init() {}

    /// Figure `home`'s pins replaced by `pins`. Answers the sources whose pinned
    /// values moved, for `Workbook.pinsChanged`.
    @discardableResult
    public mutating func set(_ pins: [CellKey: [FigureResearchPin]], home: String) -> Set<String> {
        pinsByHome[home] = pins.isEmpty ? nil : pins
        return rechoose(home)
    }

    /// Figure `id` parked under `cycle`, or (nil) not parked. Answers the homes
    /// whose winning pins on it moved, for `Workbook.pinsChanged`.
    @discardableResult
    public mutating func setPark(_ cycle: String?, figure id: String) -> Set<String> {
        guard parks[id] != cycle else { return [] }
        parks[id] = cycle
        var homes = Set<String>()
        for (home, pins) in pinsByHome where pins.values.contains(where: { $0.contains { $0.research == id } }) {
            if rechoose(home).contains(id) { homes.insert(home) }
        }
        return homes
    }

    public func pinnedValue(home: String, research: String, row: Int, column: Int) -> CellValue? {
        winners[home]?[PinRead(source: research, row: row, column: column)]?.value
    }

    /// Recomputes `home`'s winners; answers the sources whose values moved.
    private mutating func rechoose(_ home: String) -> Set<String> {
        let old = winners[home] ?? [:]
        let next = FigurePinChoice.winners(pinsByHome[home] ?? [:], parks: parks).mapValues(\.pin)
        winners[home] = next.isEmpty ? nil : next
        var moved = Set<String>()
        for (key, pin) in next where old[key]?.value != pin.value { moved.insert(key.source) }
        for key in old.keys where next[key] == nil { moved.insert(key.source) }
        return moved
    }
}

/// **A book's figures as one `Workbook`**, keyed by each record's id (what a
/// formula stores, R-D1; `FormulaNames(records:tables:research:)` over its
/// `workbook.tables` gives each its current name). Holds every table
/// figure, a parked one from its parked state — the last values the figures
/// reading it keep while it sits in Research (R-D2) — and listed in `parked`, so
/// its readers can be flagged. Research refs, and refs into a parked figure,
/// read the reading figure's own pins (`FigurePinIndex`, spec §4.3). A figure whose stream cannot be read (RULING-54)
/// is absent, so a reference to it is `#REF!`, and is LISTED in `unreadable`.
public struct FigureWorkbook: Sendable {
    public var workbook: Workbook
    /// Every figure's research pins, as `workbook` reads them.
    public private(set) var pins = FigurePinIndex()
    public var unreadable: [(name: String, error: String)]

    /// The ids of the figures assembled from a parked state.
    public var parked: Set<String> { workbook.parked }

    @MainActor
    public static func assemble(
        for manifest: ProjectManifest, cache: FigureCache, projectURL: URL,
        trust: TrustTable? = nil
    ) -> FigureWorkbook {
        var unreadable: [(name: String, error: String)] = []
        let facts = DocumentClass.Facts(manifest)
        cache.evict(except: Set(facts.figures.map(\.id)))
        var states: [(String, FigureState)] = []
        var pins = FigurePinIndex()
        for record in facts.figures where record.kind == .table {
            do {
                let state = try cache.state(
                    forFigureId: record.id, in: projectURL, trust: trust, facts: facts)
                states.append((record.id, state))
            } catch {
                unreadable.append((record.name, String(describing: error)))
            }
        }
        for (id, state) in states {
            pins.setPark(state.parked?.cycle, figure: id)
            pins.set(state.pins, home: id)
        }
        var book = Workbook(pins: pins)
        for (id, state) in states where state.parked != nil { book.setParked(true, id: id) }
        for (id, state) in states { book.setTable(state.table, id: id) }
        return FigureWorkbook(workbook: book, pins: pins, unreadable: unreadable)
    }

    /// **Lay a fresher state of figure `id` over its read** — an open host's fold.
    /// Its table and pins replace the read ones and its parked status wins, so `parked` stays
    /// the one answer to "which figures are in Research" for whoever reads this book.
    public mutating func overlay(_ state: FigureState, id: String) {
        let readers = pins.setPark(state.parked?.cycle, figure: id)
        let moved = pins.set(state.pins, home: id)
        workbook.setPins(pins)
        workbook.setParked(state.parked != nil, id: id)
        workbook.setTable(state.table, id: id)
        for source in moved { workbook.pinsChanged(home: id, research: source) }
        // A new park cycle: the readers' pins from the last one went inert.
        for home in readers { workbook.pinsChanged(home: home, research: id) }
    }
}
