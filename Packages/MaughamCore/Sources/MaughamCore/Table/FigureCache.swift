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
        if let line = lines[figureId], line.token == token { return line.state }
        let ops = try OpLogStore.loadSyncMerged(
            forDocId: figureId, in: projectURL, trust: trust, facts: facts)
        let state = FigureDeriver.derive(ops)
        deriveCount &+= 1
        lines[figureId] = Line(token: token, state: state)
        return state
    }

    /// Drop one figure's cached line (a guaranteed re-derive without racing mtime).
    public func invalidate(figureId: String) { lines[figureId] = nil }

    /// Drop everything, e.g. when trust or the registry changed.
    public func invalidateAll() { lines.removeAll() }
}

/// **A book's figures as one `Workbook`**, keyed by each record's NAME (the
/// name a formula writes). Holds every table figure whose state is not parked;
/// a parked figure is absent, so a reference to it is `#REF!`. A figure whose
/// stream cannot be read is left out too, as a missing one is.
@MainActor
public func workbook(
    for manifest: ProjectManifest, cache: FigureCache, projectURL: URL,
    trust: TrustTable? = nil, pins: ResearchPinSource
) -> Workbook {
    var book = Workbook(pins: pins)
    let facts = DocumentClass.Facts(manifest)
    for record in manifest.figures ?? [] where record.kind == .table {
        guard let state = try? cache.state(
            forFigureId: record.id, in: projectURL, trust: trust, facts: facts),
              state.parked == nil else { continue }
        book.setTable(state.table, named: record.name)
    }
    return book
}
