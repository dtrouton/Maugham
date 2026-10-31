import Foundation
import MaughamCore

/// **The book's figures as one publish sees them** (report plan 9a Task 1,
/// spec §9) — taken once, before a source is built, and carried in
/// `PublishContext.figures` so every body of the compile reads the same
/// snapshot: each figure's state, the tables evaluated together, where each
/// pinned source stands, whose own Research source has moved on, and which
/// are parked in Research.
///
/// Plain values, `Sendable`, so it crosses into the compilers with the rest of
/// the context. Taken by `DocumentStore.publishFigures()`, never from
/// `figures/<name>.csv` (tripwire 20). Everything is keyed by figure id.
public struct PublishFigures: Sendable {
    /// The registry as read (`manifest.figures`).
    public var records: [FigureRecord]
    /// Each readable figure's state — an open host's fold, else the figure
    /// cache's read. A figure whose stream will not read is absent.
    public var states: [String: FigureState]
    /// The book's tables evaluated together; nil with no figures.
    public var workbook: Workbook?
    /// For each figure whose formulas read through a pin, where each source
    /// stands (`FigurePins.status(of:sources:)`), keyed by source id. A figure
    /// whose sources would not read is absent.
    public var pinStatus: [String: [String: PinStatus]]
    /// The figures whose own Research source has changed or is gone
    /// (`FigureSource.hasChanged(currentHash:)`).
    public var sourceChanged: Set<String>
    /// The figures parked in Research.
    public var parked: Set<String>

    public init(
        records: [FigureRecord],
        states: [String: FigureState],
        workbook: Workbook?,
        pinStatus: [String: [String: PinStatus]],
        sourceChanged: Set<String>,
        parked: Set<String>
    ) {
        self.records = records
        self.states = states
        self.workbook = workbook
        self.pinStatus = pinStatus
        self.sourceChanged = sourceChanged
        self.parked = parked
    }

    /// No figures: what a book without any, and a source with no project,
    /// answers.
    public static let none = PublishFigures(
        records: [], states: [:], workbook: nil, pinStatus: [:], sourceChanged: [], parked: [])
}

extension ProjectStore {
    /// **The figure snapshot a publish door takes before building its
    /// source** — the open window's `DocumentStore.publishFigures()`. Every
    /// production project is opened with its `DocumentStore`
    /// (`ProjectSession.open`); a bare `ProjectStore` with none (a test's
    /// fixture) has no figure host and answers `.none` — said in the log
    /// when the book does register figures, since every table-figure line
    /// then reads "points at no figure" and the log is the only clue why.
    func publishFigures() async -> PublishFigures {
        guard let documentStore else {
            if !(manifest.figures ?? []).isEmpty {
                projectStoreLog.error(
                    "a publish read no figure: the project has no DocumentStore, so its \((self.manifest.figures ?? []).count, privacy: .public) registered figures print as missing")
            }
            return .none
        }
        return await documentStore.publishFigures()
    }
}
