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

/// **A book's figures as one `Workbook`**, keyed by each record's id (what a
/// formula stores, R-D1; `FormulaNames(records:tables:research:)` over its
/// `workbook.tables` gives each its current name). Holds every table
/// figure, a parked one from its parked state — the last values the figures
/// reading it keep while it sits in Research (R-D2) — and listed in `parked`, so
/// its readers can be flagged. A figure whose stream cannot be read (RULING-54)
/// is absent, so a reference to it is `#REF!`, and is LISTED in `unreadable`.
public struct FigureWorkbook: Sendable {
    public var workbook: Workbook
    /// The ids of the figures assembled from a parked state.
    public var parked: Set<String>
    public var unreadable: [(name: String, error: String)]

    @MainActor
    public static func assemble(
        for manifest: ProjectManifest, cache: FigureCache, projectURL: URL,
        trust: TrustTable? = nil, pins: ResearchPinSource
    ) -> FigureWorkbook {
        var book = Workbook(pins: pins)
        var parked = Set<String>()
        var unreadable: [(name: String, error: String)] = []
        let facts = DocumentClass.Facts(manifest)
        cache.evict(except: Set(facts.figures.map(\.id)))
        for record in facts.figures where record.kind == .table {
            do {
                let state = try cache.state(
                    forFigureId: record.id, in: projectURL, trust: trust, facts: facts)
                if state.parked != nil { parked.insert(record.id) }
                book.setTable(state.table, id: record.id)
            } catch {
                unreadable.append((record.name, String(describing: error)))
            }
        }
        return FigureWorkbook(workbook: book, parked: parked, unreadable: unreadable)
    }
}
