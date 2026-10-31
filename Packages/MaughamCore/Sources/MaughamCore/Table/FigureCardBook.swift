import Foundation

/// **The figure cards of one book, built once for both surfaces** (report plan
/// 9b Task 2; tripwire 19). The Mac's `FigureCardCache` and the phone's cards
/// hand in the registry, the folded states and the computed workbook; this is
/// the one loop that turns them into a `FigureCardModel` per figure, plus the
/// two sets the Mac's editor reads (which figures read Research, which labels
/// name a parked figure) and the line rule that says what sits under a figure
/// line. Pure: no disk, no clock.
public struct FigureCardBook: Equatable, Sendable {

    /// One card per registered figure that has a state, by figure id.
    public let models: [String: FigureCardModel]
    /// The unparked table figures whose formulas read a Research table or a
    /// parked figure (`FigurePins.reads`), pinned or not.
    public let researchReaders: Set<String>
    /// The reference labels of the parked figures (`FigureRecord.referenceLabel`).
    public let parkedLabels: Set<ManuscriptLabel>

    public init(models: [String: FigureCardModel], researchReaders: Set<String> = [],
                parkedLabels: Set<ManuscriptLabel> = []) {
        self.models = models
        self.researchReaders = researchReaders
        self.parkedLabels = parkedLabels
    }

    /// - Parameters:
    ///   - records: the registry, in order; the first record of an id wins.
    ///   - states: each figure's folded state; a record with none gets no card.
    ///   - workbook: the computed values; nil reads every cell as empty.
    ///   - locale: the number and date formatting.
    ///   - pinChanged / sourceChanged: ids to flag on their cards.
    ///   - openCellNotes: each figure's open live cell notes (`FigureCellNotes`), against
    ///     its state's table, for the card's dots and the strip's presence; a figure with
    ///     none is absent.
    public static func build(
        records: [FigureRecord], states: [String: FigureState], workbook: Workbook?,
        locale: TableLocale, pinChanged: Set<String>, sourceChanged: Set<String>,
        openCellNotes: [String: FigureCellNotes]
    ) -> FigureCardBook {
        var next: [String: FigureCardModel] = [:]
        var readers: Set<String> = []
        let tables = workbook?.tables ?? [:]
        let parked = states.reduce(into: [String: FigureTable]()) { out, entry in
            if entry.value.parked != nil, let table = tables[entry.key] { out[entry.key] = table }
        }
        for record in records where next[record.id] == nil {
            guard let state = states[record.id] else { continue }
            let id = record.id
            if state.parked == nil, state.kind == .table,
               !FigurePins.reads(of: state.table, parked: parked, tables: tables).isEmpty {
                readers.insert(id)
            }
            next[id] = FigureCardModel.build(
                figureId: id, state: state,
                values: { workbook?.value(at: CellAddress(table: id, key: $0)) ?? .empty },
                locale: locale,
                // The source language: plan 9 passes an edition's, with its labels.
                language: nil, labelLookup: { _, _, _, _ in nil },
                pinChanged: pinChanged.contains(id),
                sourceChanged: sourceChanged.contains(id),
                openCellNotes: openCellNotes[id] ?? .none)
        }
        let parkedNow = Set(records.compactMap { record in
            states[record.id]?.parked != nil ? record.referenceLabel : nil
        })
        return FigureCardBook(models: next, researchReaders: readers, parkedLabels: parkedNow)
    }

    /// **The card under a figure line** (`FigureLineResolution`, the rule
    /// Publish uses): a registered figure's own card (nil when it has none); two
    /// records sharing the path `.ambiguous`; a path naming nothing inside
    /// `figures/` `.removed`; anything else (a picture in Research, a path that
    /// is not local) `.image`.
    public func model(forLinePath linePath: String, documentPath: String,
                      index: FigureLineResolution.Index) -> FigureCardModel? {
        switch index.record(forLinePath: linePath, documentPath: documentPath) {
        case .figure(let record): return models[record.id]
        case .ambiguous: return .placeholder(.ambiguous)
        case .none:
            guard case .inside(_, let root) = FigurePathRule.lexical(linePath, piecePath: documentPath),
                  root == [FigurePathRule.figuresFolder] else { return .placeholder(.image) }
            return .placeholder(.removed)
        }
    }
}
