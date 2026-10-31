import Foundation
import MaughamCore

/// **The table figures a set of pieces uses, and how far each is translated**
/// (report plan 9e-1 Task 6, spec §8, R7) — the ONE reader the coverage gate
/// (`TranslationCoverage.check`) and `EditionStatus` (the desk's language rows
/// and `translation_status`'s `figures`) share, so the cells the gate refuses
/// an edition over are the cells both surfaces count.
///
/// A figure is *used* when one of the pieces' source paragraphs is its line,
/// resolved by `FigureLineResolution.status` against the publish snapshot's
/// registry — the rule `PublishResolution` lays a table out by. Only prose
/// pieces (a screenplay prints no table), only table figures, never one parked
/// in Research, and each figure once however many pieces use it, in first-use
/// order. Its coverage is `FigureTranslationDeriver` over its translation
/// records, laid against the snapshot's table — the table the bodies print
/// (`PublishFigures.cellTranslations`) and the MCP tools hash against.
enum FigureUse {

    /// One piece's source text: its path (what a figure line resolves
    /// against) and its paragraphs in reading order.
    struct Piece: Equatable, Sendable {
        let path: String
        let sequence: [String]
        let paragraphs: [String: String]
    }

    /// A used table figure and the table it holds in the snapshot.
    struct Table: Sendable {
        let record: FigureRecord
        let table: FigureTable
    }

    /// The used, unparked table figures of `pieces`, each once in first-use
    /// order; `unreadable` lists a used table whose state the snapshot could
    /// not read (its bodies print it as unreadable; nothing is counted).
    nonisolated static func tables(
        in pieces: [Piece], figures: PublishFigures
    ) -> (readable: [Table], unreadable: [FigureRecord]) {
        guard !figures.records.isEmpty else { return ([], []) }
        let index = FigureLineResolution.Index(figures.records)
        var seen = Set<String>()
        var readable: [Table] = []
        var unreadable: [FigureRecord] = []
        for piece in pieces where !DocumentFormat.ofManuscript(path: piece.path).isScreenplay {
            for id in piece.sequence {
                guard let text = piece.paragraphs[id], text.contains("![") else { continue }
                for (block, _) in ManuscriptBlocks.parse(MarkdownDisplayFilter.stripAnchors(text)) {
                    // Only a line Publish prints as a table counts — a `.csv`
                    // line labelled `{#fig:}` takes the image arm (R7a-1).
                    guard case .figure(_, let path, let label) = block,
                          ManuscriptLabel.Kind.ofFigureLine(path: path, label: label) == .tbl,
                          case .figure(let record) = FigureLineResolution.status(
                            linePath: path, documentPath: piece.path, index: index),
                          seen.insert(record.id).inserted else { continue }
                    switch record.kind {
                    case .table: break
                    case .image, .unknown: continue
                    }
                    if figures.isParked(record.id) { continue }
                    if let state = figures.states[record.id], state.kind == .table {
                        readable.append(Table(record: record, table: state.table))
                    } else {
                        unreadable.append(record)
                    }
                }
            }
        }
        return (readable, unreadable)
    }

    /// **What a body in `language` prints for each table's text cells**
    /// (report plan 9e-1 Task 5): figure id → each FRESH translation
    /// (`FigureTranslatedTable.freshLabels`), for every unparked table in the
    /// snapshot with a translation file in that language, derived against the
    /// snapshot's table. Asked once per translated body at the one resolve
    /// door (`PublishProblemGate.resolve`), never by a snapshot every reader
    /// pays for. Throws for a present file that will not read (P2a D0) — the
    /// coverage gate, which reads the same files, has already refused.
    nonisolated static func freshLabels(
        language: String, figures: PublishFigures, projectURL: URL, trust: () throws -> TrustTable
    ) throws -> [String: [CellKey: String]] {
        guard !figures.records.isEmpty else { return [:] }
        let byDoc = TranslationStore.languagesByDocId(in: projectURL)
        var out: [String: [CellKey: String]] = [:]
        for record in figures.records where byDoc[record.id]?.contains(language) == true {
            switch record.kind {
            case .table: break
            case .image, .unknown: continue
            }
            guard !figures.isParked(record.id), let state = figures.states[record.id],
                  state.kind == .table else { continue }
            let labels = try coverage(
                of: Table(record: record, table: state.table), language: language,
                projectURL: projectURL, trust: try trust()).derived.freshLabels
            if !labels.isEmpty { out[record.id] = labels }
        }
        return out
    }

    /// One used table's translation in `language`: its merged records (empty
    /// with no file — every text cell then derives `missing`) and their
    /// derivation over the snapshot's table. Throws for a present translation
    /// file that will not read (P2a D0), as a piece's does.
    nonisolated static func coverage(
        of use: Table, language: String, projectURL: URL, trust: TrustTable
    ) throws -> (records: [TranslationRecord], derived: FigureTranslatedTable) {
        let records = try TranslationStore.loadMerged(
            forDocId: use.record.id, language: language, in: projectURL, trust: trust)
        return (records, FigureTranslationDeriver.derive(
            records: records, table: use.table, language: language))
    }
}
